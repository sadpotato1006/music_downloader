part of '../app_controller.dart';

extension AppControllerLibraryActions on AppController {
  bool _tryBeginMetadataRead(String path) {
    final pathKey = _trackPathKey(path);
    if (_deletingTrackKeys.contains(pathKey) ||
        _metadataWriteKeys.contains(pathKey)) {
      return false;
    }
    _metadataReadCounts[pathKey] = (_metadataReadCounts[pathKey] ?? 0) + 1;
    return true;
  }

  Future<bool> _beginMetadataReadWhenAvailable(String path) async {
    final pathKey = _trackPathKey(path);
    while (!_isDisposed) {
      if (_deletingTrackKeys.contains(pathKey)) {
        return false;
      }
      if (_tryBeginMetadataRead(path)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  void _endMetadataRead(String path) {
    final pathKey = _trackPathKey(path);
    final count = _metadataReadCounts[pathKey] ?? 0;
    if (count <= 1) {
      _metadataReadCounts.remove(pathKey);
    } else {
      _metadataReadCounts[pathKey] = count - 1;
    }
  }

  bool _metadataReadInProgress(String pathKey) =>
      (_metadataReadCounts[pathKey] ?? 0) > 0;

  bool _tryBeginMetadataWrite(String pathKey) {
    if (_deletingTrackKeys.contains(pathKey) ||
        _metadataReadInProgress(pathKey)) {
      return false;
    }
    return _metadataWriteKeys.add(pathKey);
  }

  Future<void> _captureCurrentTrackDuration() {
    final activeOperation = _durationCaptureOperation;
    if (activeOperation != null) {
      _durationCaptureRetryRequested = true;
      return activeOperation;
    }
    late final Future<void> operation;
    operation = _captureCurrentTrackDurationInternal().whenComplete(() {
      if (identical(_durationCaptureOperation, operation)) {
        _durationCaptureOperation = null;
        if (_durationCaptureRetryRequested && !_isDisposed) {
          _durationCaptureRetryRequested = false;
          unawaited(_retryCaptureCurrentTrackDuration());
        }
      }
    });
    _durationCaptureOperation = operation;
    return operation;
  }

  Future<void> _retryCaptureCurrentTrackDuration() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!_isDisposed) {
      await _captureCurrentTrackDuration();
    }
  }

  Future<void> _captureCurrentTrackDurationInternal() async {
    final localPath = currentItem?.localPath;
    final durationMs = player.duration.inMilliseconds;
    if (localPath == null || durationMs < 1000) {
      return;
    }
    final pathKey = _trackPathKey(localPath);
    if (!_tryBeginMetadataWrite(pathKey)) {
      _durationCaptureRetryRequested = true;
      return;
    }
    try {
      final track = _downloadedTrackByPath(localPath);
      if (track == null ||
          (track.durationMs != null &&
              (track.durationMs! - durationMs).abs() < 1500)) {
        return;
      }
      final updated = track.copyWith(durationMs: durationMs);
      downloadedTracks = [
        for (final item in downloadedTracks)
          _trackPathKey(item.path) == pathKey ? updated : item,
      ];
      await _saveDownloadedTracks();
    } catch (error, stackTrace) {
      AppLog.instance.warning(
        'library',
        '保存歌曲时长失败：${currentItem?.title ?? localPath}',
        detail: '$error\n$stackTrace',
      );
    } finally {
      _metadataWriteKeys.remove(pathKey);
    }
  }

  Future<void> toggleFavorite(DownloadedTrack track) async {
    final key = _trackPathKey(track.path);
    final wasFavorite = isFavorite(track);
    final updated = wasFavorite
        ? myMusic.favoriteTrackPaths
              .where((path) => _trackPathKey(path) != key)
              .toList()
        : [
            track.path,
            ...myMusic.favoriteTrackPaths.where(
              (path) => _trackPathKey(path) != key,
            ),
          ];
    myMusic = myMusic.copyWith(favoriteTrackPaths: updated);
    await _saveMyMusic();
    globalMessage = wasFavorite
        ? '已取消喜欢：${track.title}'
        : '已添加到我喜欢：${track.title}';
    _notify();
  }

  Future<MusicPlaylist?> createPlaylist(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      globalMessage = '歌单名称不能为空';
      _notify();
      return null;
    }
    if (myMusic.playlists.any(
      (playlist) => playlist.name.trim().toLowerCase() == trimmed.toLowerCase(),
    )) {
      globalMessage = '已存在同名歌单';
      _notify();
      return null;
    }

    final now = DateTime.now();
    final playlist = MusicPlaylist(
      id: 'playlist-${now.microsecondsSinceEpoch}',
      name: trimmed,
      trackPaths: const [],
      createdAt: now,
    );
    myMusic = myMusic.copyWith(playlists: [playlist, ...myMusic.playlists]);
    await _saveMyMusic();
    globalMessage = '已创建歌单：$trimmed';
    _notify();
    return playlist;
  }

  Future<bool> renamePlaylist(String playlistId, String name) async {
    final trimmed = name.trim();
    final current = playlistById(playlistId);
    if (current == null || trimmed.isEmpty) {
      return false;
    }
    if (myMusic.playlists.any(
      (playlist) =>
          playlist.id != playlistId &&
          playlist.name.trim().toLowerCase() == trimmed.toLowerCase(),
    )) {
      globalMessage = '已存在同名歌单';
      _notify();
      return false;
    }
    myMusic = myMusic.copyWith(
      playlists: [
        for (final playlist in myMusic.playlists)
          playlist.id == playlistId
              ? playlist.copyWith(name: trimmed)
              : playlist,
      ],
    );
    await _saveMyMusic();
    globalMessage = '已重命名歌单：$trimmed';
    _notify();
    return true;
  }

  Future<void> deletePlaylist(String playlistId) async {
    final playlist = playlistById(playlistId);
    if (playlist == null) {
      return;
    }
    myMusic = myMusic.copyWith(
      playlists: myMusic.playlists
          .where((item) => item.id != playlistId)
          .toList(),
    );
    await _saveMyMusic();
    globalMessage = '已删除歌单：${playlist.name}';
    _notify();
  }

  Future<bool> setTrackInPlaylist(
    String playlistId,
    DownloadedTrack track, {
    required bool included,
  }) async {
    final playlist = playlistById(playlistId);
    if (playlist == null) {
      return false;
    }
    final key = _trackPathKey(track.path);
    final alreadyIncluded = playlist.trackPaths.any(
      (path) => _trackPathKey(path) == key,
    );
    if (alreadyIncluded == included) {
      return true;
    }
    final paths = included
        ? [track.path, ...playlist.trackPaths]
        : playlist.trackPaths
              .where((path) => _trackPathKey(path) != key)
              .toList();
    myMusic = myMusic.copyWith(
      playlists: [
        for (final item in myMusic.playlists)
          item.id == playlistId ? item.copyWith(trackPaths: paths) : item,
      ],
    );
    await _saveMyMusic();
    globalMessage = included
        ? '已将“${track.title}”加入歌单“${playlist.name}”'
        : '已从歌单“${playlist.name}”移除“${track.title}”';
    _notify();
    return true;
  }

  Future<void> clearRecentPlaybacks() async {
    if (myMusic.recentPlaybacks.isEmpty) {
      return;
    }
    myMusic = myMusic.copyWith(recentPlaybacks: const []);
    await _saveMyMusic();
    globalMessage = '已清空最近播放';
    _notify();
  }

  Future<void> openDownloadedFile(DownloadedTrack track) async {
    if (!await File(track.path).exists()) {
      globalMessage = '本地文件不存在：${track.path}';
      _notify();
      return;
    }
    await OpenFilex.open(track.path);
  }

  Future<void> revealDownloadedFile(DownloadedTrack track) async {
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['/select,', track.path]);
    } else {
      await openDownloadedFile(track);
    }
  }

  Future<void> removeDownloadedRecord(DownloadedTrack track) async {
    final trackPathKey = _trackPathKey(track.path);
    if (_metadataWriteKeys.contains(trackPathKey) ||
        _metadataReadInProgress(trackPathKey)) {
      globalMessage = '正在更新“${track.title}”的歌曲信息，请稍候。';
      _notify();
      return;
    }
    await _removeDownloadedRecord(track);
    globalMessage = '已删除歌曲记录，歌曲文件仍保留在原位置。';
    _notify();
  }

  bool get movesDeletedFilesToRecycleBin =>
      fileDeletionService.movesFilesToRecycleBin;

  bool isDeletingDownloadedTrack(DownloadedTrack track) =>
      _deletingTrackKeys.contains(_trackPathKey(track.path));

  Future<bool> deleteDownloadedTrack(DownloadedTrack track) async {
    final trackPathKey = _trackPathKey(track.path);
    if (_metadataWriteKeys.contains(trackPathKey) ||
        _metadataReadInProgress(trackPathKey)) {
      globalMessage = '正在更新“${track.title}”的歌曲信息，请稍候。';
      _notify();
      return false;
    }
    if (!_deletingTrackKeys.add(trackPathKey)) {
      globalMessage = '正在删除“${track.title}”，请稍候。';
      _notify();
      return false;
    }
    _notify();
    try {
      return await _deleteDownloadedTrack(track, trackPathKey);
    } finally {
      _deletingTrackKeys.remove(trackPathKey);
      _notify();
    }
  }

  Future<bool> _deleteDownloadedTrack(
    DownloadedTrack track,
    String trackPathKey,
  ) async {
    final activeItem = currentItem;
    final deletingCurrentItem =
        activeItem?.localPath != null &&
        _trackPathKey(activeItem!.localPath!) == trackPathKey;
    final currentWasPlaying = deletingCurrentItem && player.isPlaying;
    var fileExisted = false;
    try {
      if (deletingCurrentItem) {
        await _stopPlayback();
      }
      fileExisted = await fileDeletionService.deleteFile(track.path);
    } catch (error) {
      if (currentWasPlaying) {
        try {
          await _playCurrentItem();
        } catch (_) {
          // Keep the original file-operation error visible to the user.
        }
      }
      final operation = movesDeletedFilesToRecycleBin ? '移入回收站' : '删除';
      globalMessage = '歌曲文件$operation失败：$error';
      _notify();
      return false;
    }

    final queueUpdate = _removeDeletedTrackFromQueue(track.path);
    _removeDownloadedRecordInMemory(track);
    final persistenceFailures = await _persistDeletedTrackState(
      saveQueue: queueUpdate.changed,
    );
    await _deleteUnusedCachedCover(track.coverFilePath);
    var playbackFailed = false;
    if (queueUpdate.removedCurrent && currentWasPlaying && queue.isNotEmpty) {
      try {
        playbackFailed = !await _openCurrentItemForPlayback();
      } catch (error, stackTrace) {
        playbackFailed = true;
        AppLog.instance.error(
          'library',
          '删除歌曲后接续播放失败：${track.title}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    unawaited(_syncAndroidMediaControls(force: true));

    final fileResult = !fileExisted
        ? '歌曲文件已不存在'
        : movesDeletedFilesToRecycleBin
        ? '已将歌曲文件移入回收站'
        : '已删除歌曲文件';
    if (persistenceFailures.isEmpty) {
      globalMessage = '$fileResult，并移除歌曲记录和播放队列项目。';
    } else {
      globalMessage =
          '$fileResult；当前界面已移除歌曲记录和播放队列项目，但${persistenceFailures.join('、')}保存失败。';
    }
    if (playbackFailed) {
      globalMessage = '${globalMessage!} 自动接续播放下一首失败，请手动选择歌曲。';
    }
    _notify();
    return true;
  }

  ({bool changed, bool removedCurrent}) _removeDeletedTrackFromQueue(
    String trackPath,
  ) {
    final pathKey = _trackPathKey(trackPath);
    final originalCurrentIndex = currentQueueIndex;
    final matchingIndexes = <int>[];
    for (var index = 0; index < queue.length; index += 1) {
      final localPath = queue[index].localPath;
      if (localPath != null && _trackPathKey(localPath) == pathKey) {
        matchingIndexes.add(index);
      }
    }
    if (matchingIndexes.isEmpty) {
      return (changed: false, removedCurrent: false);
    }

    final removingCurrent = matchingIndexes.contains(originalCurrentIndex);
    final removedBeforeCurrent = matchingIndexes
        .where((index) => index < originalCurrentIndex)
        .length;
    final matchingSet = matchingIndexes.toSet();
    queue = [
      for (var index = 0; index < queue.length; index += 1)
        if (!matchingSet.contains(index)) queue[index],
    ];

    if (queue.isEmpty) {
      currentQueueIndex = -1;
    } else if (removingCurrent) {
      currentQueueIndex = (originalCurrentIndex - removedBeforeCurrent)
          .clamp(0, queue.length - 1)
          .toInt();
    } else if (originalCurrentIndex >= 0) {
      currentQueueIndex = originalCurrentIndex - removedBeforeCurrent;
    }

    return (changed: true, removedCurrent: removingCurrent);
  }

  Future<void> _removeDownloadedRecord(DownloadedTrack track) async {
    _removeDownloadedRecordInMemory(track);
    await Future.wait<void>([
      _saveMyMusic(),
      _saveDownloadedTracks(),
      _savePendingAlbumMatches(),
    ]);
    await _deleteUnusedCachedCover(track.coverFilePath);
  }

  void _removeDownloadedRecordInMemory(DownloadedTrack track) {
    downloadedTracks = downloadedTracks
        .where((item) => item.id != track.id || item.path != track.path)
        .toList();
    final key = _libraryLyricsCacheKey(track);
    _libraryLyricsSearchCache.remove(key);
    _loadingLibraryLyricsKeys.remove(key);
    _removePendingAlbumMatchForPath(track.path);
    _removeTrackFromMyMusicInMemory(track.path);
  }

  Future<List<String>> _persistDeletedTrackState({
    required bool saveQueue,
  }) async {
    final failures = <String>[];

    Future<void> persist(String label, Future<void> Function() save) async {
      Object? lastError;
      StackTrace? lastStackTrace;
      for (var attempt = 0; attempt < 2; attempt += 1) {
        try {
          await save();
          return;
        } catch (error, stackTrace) {
          lastError = error;
          lastStackTrace = stackTrace;
        }
      }
      failures.add(label);
      AppLog.instance.error(
        'library',
        '删除歌曲后保存$label失败',
        error: lastError,
        stackTrace: lastStackTrace,
      );
    }

    if (saveQueue) {
      await persist('播放队列', _saveQueueState);
    }
    await persist('我的音乐', _saveMyMusic);
    await persist('本地曲库', _saveDownloadedTracks);
    await persist('待确认专辑', _savePendingAlbumMatches);
    return failures;
  }

  Set<String> _unfinishedDownloadPaths() => {
    for (final task in downloadTasks)
      if (task.status != DownloadStatus.completed ||
          _runningDownloadIds.contains(task.id) ||
          _pendingDownloadCleanupIds.contains(task.id))
        _trackPathKey(task.savePath),
    for (final path in _reservedDownloadSavePaths) _trackPathKey(path),
  };

  Future<int> scanCurrentDownloadDirectory() async {
    final activeSettings = settings;
    if (activeSettings == null || isScanningDownloadDirectory) {
      return 0;
    }

    final directory = Directory(activeSettings.downloadDirectory);
    isScanningDownloadDirectory = true;
    globalMessage = null;
    _notify();

    try {
      if (!await directory.exists()) {
        globalMessage = '当前下载目录不存在，请先在设置里重新选择下载目录。';
        return 0;
      }

      final knownPaths = {
        for (final track in downloadedTracks) _trackPathKey(track.path): track,
      };
      final unfinishedPaths = _unfinishedDownloadPaths();
      final newAudioFiles = <({File file, String format})>[];

      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }

        final format = _supportedLocalAudioFormat(entity.path);
        if (format == null) {
          continue;
        }

        final normalizedPath = _trackPathKey(entity.path);
        if (knownPaths.containsKey(normalizedPath) ||
            unfinishedPaths.contains(normalizedPath)) {
          continue;
        }
        newAudioFiles.add((file: entity, format: format));
      }

      final parsed = await mapWithConcurrency(newAudioFiles, (input) async {
        try {
          final entity = input.file;
          final stat = await entity.stat();
          final metadata = await _readLocalAudioMetadata(entity, input.format);
          final fileName = _parseTrackNameFromFile(entity.path);
          return DownloadedTrack(
            id: _localTrackId(entity.path, stat),
            title: _firstNonEmpty([
              metadata.title,
              fileName.title,
              p.basenameWithoutExtension(entity.path),
            ]),
            artist: _firstNonEmpty([metadata.artist, fileName.artist]),
            path: entity.path,
            format: input.format,
            downloadedAt: stat.modified,
            sourceUrl: entity.uri.toString(),
            album: _firstNonEmpty([metadata.album]),
            coverFilePath: metadata.coverFilePath,
          );
        } catch (_) {
          // Ignore a single unreadable file and keep scanning the directory.
          return null;
        }
      }, maxConcurrent: 4);
      // Downloads can start or finish while metadata is being read. Recheck
      // before committing, and never replace a record added by a download.
      final excludedPaths = {
        ...unfinishedPaths,
        ..._unfinishedDownloadPaths(),
        for (final track in downloadedTracks) _trackPathKey(track.path),
      };
      final imported = parsed
          .whereType<DownloadedTrack>()
          .where((track) => !excludedPaths.contains(_trackPathKey(track.path)))
          .toList();

      if (imported.isNotEmpty) {
        downloadedTracks = [...imported, ...downloadedTracks];
        await _saveDownloadedTracks();
        if (LibrarySearch.normalize(libraryQuery).isNotEmpty) {
          unawaited(_ensureLibraryLyricsForQuery(libraryQuery));
        }
      }

      globalMessage = imported.isEmpty
          ? '扫描完成，没有发现新的本地歌曲。'
          : '扫描完成，已导入 ${imported.length} 首本地歌曲。';
      return imported.length;
    } on FileSystemException {
      globalMessage = '无法访问当前下载目录，请检查存储权限或重新选择目录。';
      return 0;
    } catch (error) {
      globalMessage = '扫描下载目录失败：${_friendlyUnexpectedError(error)}';
      return 0;
    } finally {
      isScanningDownloadDirectory = false;
      _notify();
    }
  }

  Future<String?> readDownloadedLyrics(DownloadedTrack track) async {
    if (!await _beginMetadataReadWhenAvailable(track.path)) {
      return null;
    }
    try {
      final file = File(track.path);
      if (!await file.exists()) {
        return null;
      }
      if (track.format.toLowerCase() == 'mp3') {
        try {
          final lyrics = await Id3LyricsEmbedder.extractLyrics(file);
          if (lyrics != null && lyrics.trim().isNotEmpty) {
            return lyrics;
          }
        } catch (_) {
          // Fall through to sidecar lyrics.
        }
      }
      return _readSidecarLyrics(file);
    } finally {
      _endMetadataRead(track.path);
    }
  }

  Future<bool> updateDownloadedTrack(
    DownloadedTrack track, {
    required String title,
    required String artist,
    required String album,
    required String lyrics,
    required String coverInput,
  }) async {
    final trackPathKey = _trackPathKey(track.path);
    if (!_tryBeginMetadataWrite(trackPathKey)) {
      globalMessage = '正在处理“${track.title}”，请稍候。';
      _notify();
      return false;
    }
    try {
      return await _updateDownloadedTrackUnlocked(
        track,
        title: title,
        artist: artist,
        album: album,
        lyrics: lyrics,
        coverInput: coverInput,
      );
    } finally {
      _metadataWriteKeys.remove(trackPathKey);
    }
  }

  Future<bool> _updateDownloadedTrackUnlocked(
    DownloadedTrack track, {
    required String title,
    required String artist,
    required String album,
    required String lyrics,
    required String coverInput,
  }) async {
    final trimmedTitle = title.trim().isEmpty ? track.title : title.trim();
    final trimmedArtist = artist.trim();
    final trimmedAlbum = album.trim();
    final trimmedLyrics = lyrics.trim();
    final file = File(track.path);
    if (!await file.exists()) {
      globalMessage = '本地文件不存在：${track.path}';
      _notify();
      return false;
    }

    Id3CoverImage? manualCover;
    if (coverInput.trim().isNotEmpty) {
      manualCover = await _loadCoverFromManualInput(coverInput.trim());
      if (manualCover == null) {
        globalMessage = '封面图片不可用，请检查图片路径或网址。';
        _notify();
        return false;
      }
    }

    String? coverFilePath = track.coverFilePath;
    if (track.format.toLowerCase() == 'mp3') {
      try {
        final existingCover =
            manualCover ?? await Id3LyricsEmbedder.extractCover(file);
        await Id3LyricsEmbedder.embedMetadata(
          file,
          title: trimmedTitle,
          artist: trimmedArtist,
          album: trimmedAlbum,
          lyrics: trimmedLyrics,
          cover: existingCover,
        );
        coverFilePath = await storage.cacheEmbeddedCover(
          file,
          cacheKey: '${track.id}-${DateTime.now().microsecondsSinceEpoch}',
        );
      } catch (error) {
        globalMessage = '写入歌曲信息失败：${_friendlyUnexpectedError(error)}';
        _notify();
        return false;
      }
    } else if (manualCover != null) {
      coverFilePath = await storage.cacheCoverImage(
        manualCover,
        cacheKey: '${track.id}-${DateTime.now().microsecondsSinceEpoch}',
      );
    }

    final updated = track.copyWith(
      title: trimmedTitle,
      artist: trimmedArtist,
      album: trimmedAlbum,
      coverFilePath: coverFilePath,
    );
    if (trimmedAlbum.isNotEmpty ||
        trimmedTitle != track.title ||
        trimmedArtist != track.artist) {
      _removePendingAlbumMatchForPath(track.path);
    }
    downloadedTracks = [
      for (final item in downloadedTracks)
        item.id == track.id && item.path == track.path ? updated : item,
    ];
    _libraryLyricsSearchCache[_libraryLyricsCacheKey(updated)] = trimmedLyrics;
    queue = [
      for (final item in queue)
        item.localPath != null &&
                _trackPathKey(item.localPath!) == _trackPathKey(track.path)
            ? item.copyWith(
                title: trimmedTitle,
                artist: trimmedArtist,
                album: trimmedAlbum,
                coverFilePath: coverFilePath,
                lyrics: trimmedLyrics,
              )
            : item,
    ];
    await _saveDownloadedTracks();
    await _saveQueueState();
    await _savePendingAlbumMatches();
    if (track.coverFilePath != coverFilePath) {
      await _deleteUnusedCachedCover(track.coverFilePath);
    }
    globalMessage = null;
    unawaited(_syncAndroidMediaControls(force: true));
    _notify();
    return true;
  }

  Future<List<AlbumMetadataMatch>> findDownloadedAlbumCandidates(
    DownloadedTrack track,
  ) async {
    if (isMatchingLocalAlbums) {
      globalMessage = '正在匹配专辑名称，请稍后再试。';
      _notify();
      return const [];
    }

    isMatchingLocalAlbums = true;
    matchingAlbumTrackPath = track.path;
    matchingAlbumTrackTitle = track.artist.trim().isEmpty
        ? track.title
        : '${track.artist} - ${track.title}';
    albumMatchProcessed = 0;
    albumMatchTotal = 1;
    albumMatchUpdated = 0;
    albumMatchNotFound = 0;
    albumMatchFailed = 0;
    _albumMatchCancelRequested = false;
    globalMessage = null;
    _notify();

    try {
      final current = _downloadedTrackByPath(track.path);
      if (current == null) {
        globalMessage = '歌曲记录已不存在，无法获取专辑候选。';
        return const [];
      }
      final candidates = await albumMetadata.findAlbumCandidates(
        title: current.title,
        artist: current.artist,
        lyricsLoader: () => readDownloadedLyrics(current),
        isCancelled: () => _albumMatchCancelRequested,
        duration: current.durationMs == null
            ? null
            : Duration(milliseconds: current.durationMs!),
        limit: 5,
      );
      if (_albumMatchCancelRequested) {
        return const [];
      }
      final latest = _downloadedTrackByPath(current.path);
      if (latest == null ||
          latest.title != current.title ||
          latest.artist != current.artist ||
          latest.album != current.album) {
        globalMessage = '歌曲信息已经变化，请重新获取专辑候选。';
        return const [];
      }
      if (candidates.isEmpty) {
        albumMatchNotFound = 1;
        globalMessage = '没有找到可用的专辑候选。';
      }
      return candidates;
    } catch (error) {
      albumMatchFailed = 1;
      globalMessage = '获取专辑名称失败：${_friendlyUnexpectedError(error)}';
      return const [];
    } finally {
      albumMatchProcessed = 1;
      isMatchingLocalAlbums = false;
      matchingAlbumTrackPath = null;
      matchingAlbumTrackTitle = null;
      _notify();
    }
  }

  bool get isAlbumMatchCancellationRequested => _albumMatchCancelRequested;

  bool isMatchingAlbumForTrack(DownloadedTrack track) =>
      isMatchingLocalAlbums &&
      matchingAlbumTrackPath != null &&
      _trackPathKey(matchingAlbumTrackPath!) == _trackPathKey(track.path);

  int get albumMatchPending => pendingAlbumMatches.length;

  List<PendingAlbumMatch> _validRestoredPendingAlbumMatches(
    List<PendingAlbumMatch> restored,
  ) {
    final tracksByPath = {
      for (final track in downloadedTracks) _trackPathKey(track.path): track,
    };
    final seenPaths = <String>{};
    final valid = <PendingAlbumMatch>[];
    for (final pending in restored) {
      final pathKey = _trackPathKey(pending.trackPath);
      final track = tracksByPath[pathKey];
      if (track != null &&
          seenPaths.add(pathKey) &&
          track.album.trim().isEmpty &&
          track.title == pending.title &&
          track.artist == pending.artist &&
          pending.candidates.isNotEmpty) {
        valid.add(pending);
      }
    }
    return valid;
  }

  int get missingAlbumCount =>
      downloadedTracks.where((track) => track.album.trim().isEmpty).length;

  int get eligibleAlbumMatchCount {
    final pendingPaths = {
      for (final item in pendingAlbumMatches) _trackPathKey(item.trackPath),
    };
    return downloadedTracks
        .where(
          (track) =>
              track.album.trim().isEmpty &&
              !pendingPaths.contains(_trackPathKey(track.path)),
        )
        .length;
  }

  void cancelAlbumMatching() {
    if (!isMatchingLocalAlbums || _albumMatchCancelRequested) {
      return;
    }
    _albumMatchCancelRequested = true;
    _notify();
  }

  void skipPendingAlbumMatch(PendingAlbumMatch pending) {
    if (!_removePendingAlbumMatchForPath(pending.trackPath)) {
      return;
    }
    unawaited(_savePendingAlbumMatchesBestEffort());
    _notify();
  }

  bool _removePendingAlbumMatchForPath(String path) {
    final pathKey = _trackPathKey(path);
    final updated = [
      for (final item in pendingAlbumMatches)
        if (_trackPathKey(item.trackPath) != pathKey) item,
    ];
    if (updated.length == pendingAlbumMatches.length) {
      return false;
    }
    pendingAlbumMatches = updated;
    return true;
  }

  Future<bool> applyPendingAlbumMatch(
    PendingAlbumMatch pending,
    AlbumMetadataMatch candidate,
  ) async {
    if (!pendingAlbumMatches.contains(pending) ||
        !pending.candidates.contains(candidate)) {
      globalMessage = '选择的专辑候选已经失效，请重新审阅。';
      _notify();
      return false;
    }
    final current = _downloadedTrackByPath(pending.trackPath);
    if (current == null) {
      skipPendingAlbumMatch(pending);
      globalMessage = '歌曲记录已不存在，已从待确认列表移除。';
      _notify();
      return false;
    }
    if (current.title != pending.title || current.artist != pending.artist) {
      skipPendingAlbumMatch(pending);
      globalMessage = '歌曲信息已经变化，请重新获取专辑候选。';
      _notify();
      return false;
    }
    if (current.album.trim().isNotEmpty) {
      skipPendingAlbumMatch(pending);
      globalMessage = '这首歌曲已经有专辑名称，已跳过旧候选。';
      _notify();
      return false;
    }
    if (current.format.toLowerCase() == 'mp3' &&
        _isTrackLoadedInPlayer(current.path)) {
      globalMessage = '请先切换到其他歌曲，再写入当前歌曲的专辑信息。';
      _notify();
      return false;
    }
    final success = await _applyAlbumToDownloadedTrack(
      current,
      candidate.album,
      notify: false,
      requireAlbumMissing: true,
      expectedTitle: pending.title,
      expectedArtist: pending.artist,
    );
    if (success) {
      skipPendingAlbumMatch(pending);
      globalMessage = '已设置专辑名称：${candidate.album}';
      _notify();
    } else {
      globalMessage = '专辑名称写入失败，请检查文件是否可写后重试。';
      _notify();
    }
    return success;
  }

  Future<bool> applyDownloadedAlbumName(
    DownloadedTrack track,
    String album,
  ) async {
    final success = await _applyAlbumToDownloadedTrack(
      track,
      album.trim(),
      notify: false,
      expectedTitle: track.title,
      expectedArtist: track.artist,
      expectedAlbum: track.album,
    );
    if (!success) {
      return false;
    }
    if (_removePendingAlbumMatchForPath(track.path)) {
      await _savePendingAlbumMatches();
    }
    _notify();
    return true;
  }

  Future<int> matchMissingDownloadedAlbums() async {
    if (isMatchingLocalAlbums) {
      return 0;
    }
    final completion = Completer<void>();
    final completionFuture = completion.future;
    _albumMatchCompletion = completionFuture;

    final pendingPaths = {
      for (final item in pendingAlbumMatches) _trackPathKey(item.trackPath),
    };
    final targets = downloadedTracks
        .where(
          (track) =>
              track.album.trim().isEmpty &&
              !pendingPaths.contains(_trackPathKey(track.path)),
        )
        .toList(growable: false);
    isMatchingLocalAlbums = true;
    matchingAlbumTrackPath = null;
    matchingAlbumTrackTitle = null;
    albumMatchProcessed = 0;
    albumMatchTotal = targets.length;
    albumMatchUpdated = 0;
    albumMatchNotFound = 0;
    albumMatchFailed = 0;
    _albumMatchCancelRequested = false;
    globalMessage = null;
    _notify();

    var unsavedChanges = 0;
    try {
      for (final target in targets) {
        if (_albumMatchCancelRequested) {
          break;
        }
        final current = _downloadedTrackByPath(target.path);
        if (current == null || current.album.trim().isNotEmpty) {
          albumMatchProcessed += 1;
          continue;
        }

        matchingAlbumTrackPath = current.path;
        matchingAlbumTrackTitle = current.artist.trim().isEmpty
            ? current.title
            : '${current.artist} - ${current.title}';
        _notify();

        try {
          final candidates = await albumMetadata.findAlbumCandidates(
            title: current.title,
            artist: current.artist,
            lyricsLoader: () => readDownloadedLyrics(current),
            isCancelled: () => _albumMatchCancelRequested,
            duration: current.durationMs == null
                ? null
                : Duration(milliseconds: current.durationMs!),
            limit: 5,
          );
          if (_albumMatchCancelRequested) {
            break;
          }
          final latest = _downloadedTrackByPath(current.path);
          if (latest == null ||
              latest.album.trim().isNotEmpty ||
              latest.title != current.title ||
              latest.artist != current.artist) {
            continue;
          }
          if (candidates.isEmpty) {
            albumMatchNotFound += 1;
          } else {
            final automatic = AlbumMetadataService.selectAutomaticMatch(
              candidates,
              hasArtist: current.artist.trim().isNotEmpty,
              hasDuration: current.durationMs != null,
            );
            if (automatic == null) {
              _upsertPendingAlbumMatch(latest, candidates);
              unsavedChanges += 1;
            } else if (latest.format.toLowerCase() == 'mp3' &&
                _isTrackLoadedInPlayer(latest.path)) {
              _upsertPendingAlbumMatch(latest, candidates);
              unsavedChanges += 1;
            } else {
              final didUpdate = await _applyAlbumToDownloadedTrack(
                latest,
                automatic.album,
                notify: false,
                persist: false,
                requireAlbumMissing: true,
                expectedTitle: latest.title,
                expectedArtist: latest.artist,
              );
              if (didUpdate) {
                albumMatchUpdated += 1;
                unsavedChanges += 1;
              } else {
                albumMatchFailed += 1;
              }
            }
            if (unsavedChanges >= 8) {
              await _saveAlbumMatchCheckpoint();
              unsavedChanges = 0;
            }
          }
        } on AlbumMetadataNetworkException catch (error, stackTrace) {
          albumMatchFailed += 1;
          _albumMatchCancelRequested = true;
          AppLog.instance.warning(
            'album',
            '专辑元数据服务不可用，已停止批量匹配',
            detail: '$error\n$stackTrace',
          );
        } catch (error, stackTrace) {
          albumMatchFailed += 1;
          AppLog.instance.warning(
            'album',
            '匹配本地歌曲专辑失败：${current.title}',
            detail: '$error\n$stackTrace',
          );
        } finally {
          albumMatchProcessed += 1;
          _notify();
        }
      }

      if (unsavedChanges > 0) {
        await _saveAlbumMatchCheckpoint();
      }
      final stopped = _albumMatchCancelRequested ? '已停止。' : '已完成。';
      globalMessage =
          '专辑匹配$stopped 已更新 $albumMatchUpdated 首，'
          '待确认 $albumMatchPending 首，未找到 $albumMatchNotFound 首，'
          '失败 $albumMatchFailed 首。';
      return albumMatchUpdated;
    } catch (error) {
      globalMessage = '专辑匹配失败：${_friendlyUnexpectedError(error)}';
      return albumMatchUpdated;
    } finally {
      isMatchingLocalAlbums = false;
      matchingAlbumTrackPath = null;
      matchingAlbumTrackTitle = null;
      if (!completion.isCompleted) {
        completion.complete();
      }
      if (identical(_albumMatchCompletion, completionFuture)) {
        _albumMatchCompletion = null;
      }
      _notify();
    }
  }

  void _upsertPendingAlbumMatch(
    DownloadedTrack track,
    List<AlbumMetadataMatch> candidates,
  ) {
    final pathKey = _trackPathKey(track.path);
    final pending = PendingAlbumMatch(
      trackId: track.id,
      trackPath: track.path,
      title: track.title,
      artist: track.artist,
      candidates: List<AlbumMetadataMatch>.unmodifiable(candidates),
    );
    pendingAlbumMatches = [
      for (final item in pendingAlbumMatches)
        if (_trackPathKey(item.trackPath) != pathKey) item,
      pending,
    ];
  }

  DownloadedTrack? _downloadedTrackByPath(String path) {
    return _downloadedTracksByPath[_trackPathKey(path)];
  }

  bool _isTrackLoadedInPlayer(String path) {
    final item = currentItem;
    final localPath = item?.localPath;
    return item != null &&
        localPath != null &&
        _trackPathKey(localPath) == _trackPathKey(path) &&
        (player.isPlaying || player.isOpened(item));
  }

  Future<void> _saveAlbumMatchCheckpoint() async {
    await Future.wait<void>([
      _saveDownloadedTracks(),
      _saveQueueState(),
      _savePendingAlbumMatches(),
    ]);
  }

  Future<PlayerItem?> _playerItemFromDownloadedTrack(
    DownloadedTrack track, {
    bool includeLyrics = true,
    bool includeMetadata = true,
    bool showMissingMessage = true,
    bool metadataReadHeld = false,
  }) async {
    final acquiredRead = metadataReadHeld
        ? true
        : _tryBeginMetadataRead(track.path);
    if (!acquiredRead) {
      if (showMissingMessage) {
        globalMessage = '正在更新“${track.title}”的歌曲信息，请稍候再播放。';
        _notify();
      }
      return null;
    }
    try {
      final file = File(track.path);
      if (!await file.exists()) {
        if (showMissingMessage) {
          globalMessage = '本地文件不存在：${track.path}';
          _notify();
        }
        return null;
      }

      Id3Metadata metadata = const Id3Metadata();
      if (includeMetadata && (includeLyrics || track.album.trim().isEmpty)) {
        try {
          metadata = await Id3LyricsEmbedder.extractMetadata(file);
        } catch (_) {
          metadata = const Id3Metadata();
        }
      }
      var lyrics = includeLyrics ? metadata.lyrics : null;
      if (includeLyrics && (lyrics == null || lyrics.trim().isEmpty)) {
        lyrics = await _readSidecarLyrics(file);
      }
      var album = track.album;
      final embeddedAlbum = metadata.album?.trim();
      if (album.trim().isEmpty &&
          embeddedAlbum != null &&
          embeddedAlbum.isNotEmpty) {
        album = embeddedAlbum;
        await _updateDownloadedTrackMetadata(
          track,
          track.copyWith(album: embeddedAlbum),
        );
      }

      return PlayerItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        uri: file.uri.toString(),
        localPath: track.path,
        coverFilePath: track.coverFilePath,
        lyrics: lyrics,
        album: album,
      );
    } finally {
      if (!metadataReadHeld) {
        _endMetadataRead(track.path);
      }
    }
  }

  Future<String?> _readSidecarLyrics(File audioFile) async {
    final basePath = p.withoutExtension(audioFile.path);
    for (final path in ['$basePath.lrc', '$basePath.LRC']) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final lyrics = await file.readAsString();
          final trimmed = lyrics.trim();
          if (trimmed.isNotEmpty) {
            return trimmed;
          }
        }
      } catch (_) {
        // Ignore unreadable sidecar lyrics and keep trying metadata.
      }
    }
    return null;
  }

  Future<void> _updateDownloadedTrackMetadata(
    DownloadedTrack original,
    DownloadedTrack updated,
  ) async {
    final current = _downloadedTrackByPath(original.path);
    final embeddedAlbum = updated.album.trim();
    if (current == null ||
        current.album.trim().isNotEmpty ||
        embeddedAlbum.isEmpty ||
        current.title != original.title ||
        current.artist != original.artist) {
      return;
    }
    final currentUpdated = current.copyWith(album: embeddedAlbum);
    final removedPending = _removePendingAlbumMatchForPath(current.path);
    downloadedTracks = [
      for (final item in downloadedTracks)
        _trackPathKey(item.path) == _trackPathKey(current.path)
            ? currentUpdated
            : item,
    ];
    queue = [
      for (final item in queue)
        item.localPath != null &&
                _trackPathKey(item.localPath!) == _trackPathKey(current.path)
            ? item.copyWith(album: embeddedAlbum)
            : item,
    ];
    await _saveDownloadedTracks();
    await _saveQueueState();
    if (removedPending) {
      await _savePendingAlbumMatches();
    }
    _notify();
  }

  Future<bool> _applyAlbumToDownloadedTrack(
    DownloadedTrack track,
    String album, {
    bool notify = true,
    bool persist = true,
    bool requireAlbumMissing = false,
    String? expectedTitle,
    String? expectedArtist,
    String? expectedAlbum,
  }) async {
    final trackPathKey = _trackPathKey(track.path);
    if (!_tryBeginMetadataWrite(trackPathKey)) {
      if (notify) {
        globalMessage = '正在处理“${track.title}”，请稍候。';
        _notify();
      }
      return false;
    }
    try {
      DownloadedTrack? current;
      for (final item in downloadedTracks) {
        if (_trackPathKey(item.path) == trackPathKey) {
          current = item;
          break;
        }
      }
      if (current == null ||
          (requireAlbumMissing && current.album.trim().isNotEmpty) ||
          (expectedTitle != null && current.title != expectedTitle) ||
          (expectedArtist != null && current.artist != expectedArtist) ||
          (expectedAlbum != null && current.album != expectedAlbum)) {
        return false;
      }
      if (current.format.toLowerCase() == 'mp3' &&
          _isTrackLoadedInPlayer(current.path)) {
        if (notify) {
          globalMessage = '请先切换到其他歌曲，再写入当前歌曲的专辑信息。';
          _notify();
        }
        return false;
      }
      return await _applyAlbumToDownloadedTrackUnlocked(
        current,
        album,
        notify: notify,
        persist: persist,
      );
    } finally {
      _metadataWriteKeys.remove(trackPathKey);
    }
  }

  Future<bool> _applyAlbumToDownloadedTrackUnlocked(
    DownloadedTrack track,
    String album, {
    required bool notify,
    required bool persist,
  }) async {
    final trimmedAlbum = album.trim();
    final file = File(track.path);
    if (!await file.exists()) {
      if (notify) {
        globalMessage = '本地文件不存在：${track.path}';
        _notify();
      }
      return false;
    }

    if (track.format.toLowerCase() == 'mp3') {
      try {
        final metadata = await Id3LyricsEmbedder.extractMetadata(file);
        final lyrics = metadata.lyrics ?? await _readSidecarLyrics(file);
        await Id3LyricsEmbedder.embedMetadata(
          file,
          title: track.title,
          artist: track.artist,
          album: trimmedAlbum,
          lyrics: lyrics,
          cover: metadata.cover,
        );
      } catch (error) {
        if (notify) {
          globalMessage = '写入专辑信息失败：${_friendlyUnexpectedError(error)}';
          _notify();
        }
        return false;
      }
    }

    final updated = track.copyWith(album: trimmedAlbum);
    downloadedTracks = [
      for (final item in downloadedTracks)
        item.id == track.id && item.path == track.path ? updated : item,
    ];
    queue = [
      for (final item in queue)
        item.localPath != null &&
                _trackPathKey(item.localPath!) == _trackPathKey(track.path)
            ? item.copyWith(album: trimmedAlbum)
            : item,
    ];
    if (persist) {
      await _saveDownloadedTracks();
      await _saveQueueState();
    }
    if (notify) {
      _notify();
    }
    return true;
  }

  Future<void> _recordRecentPlayback(PlayerItem item) async {
    final localPath = item.localPath?.trim();
    if (localPath == null || localPath.isEmpty) {
      return;
    }
    final key = _trackPathKey(localPath);
    if (!_downloadedTracksByPath.containsKey(key)) {
      return;
    }
    final updated = <RecentPlayback>[
      RecentPlayback(trackPath: localPath, playedAt: DateTime.now()),
      ...myMusic.recentPlaybacks.where(
        (playback) => _trackPathKey(playback.trackPath) != key,
      ),
    ];
    myMusic = myMusic.copyWith(
      recentPlaybacks: updated.take(AppController.maxRecentPlaybacks).toList(),
    );
    await _saveMyMusic();
    _notify();
  }

  void _removeTrackFromMyMusicInMemory(String trackPath) {
    final key = _trackPathKey(trackPath);
    myMusic = myMusic.copyWith(
      favoriteTrackPaths: myMusic.favoriteTrackPaths
          .where((path) => _trackPathKey(path) != key)
          .toList(),
      playlists: [
        for (final playlist in myMusic.playlists)
          playlist.copyWith(
            trackPaths: playlist.trackPaths
                .where((path) => _trackPathKey(path) != key)
                .toList(),
          ),
      ],
      recentPlaybacks: myMusic.recentPlaybacks
          .where((playback) => _trackPathKey(playback.trackPath) != key)
          .toList(),
    );
  }

  Future<void> _saveMyMusic() {
    final snapshot = MyMusicData(
      favoriteTrackPaths: List<String>.unmodifiable(myMusic.favoriteTrackPaths),
      playlists: [
        for (final playlist in myMusic.playlists)
          playlist.copyWith(
            trackPaths: List<String>.unmodifiable(playlist.trackPaths),
          ),
      ],
      recentPlaybacks: List<RecentPlayback>.unmodifiable(
        myMusic.recentPlaybacks,
      ),
    );
    return _myMusicSaveQueue.enqueue(() => storage.saveMyMusic(snapshot));
  }

  Future<void> _saveDownloadedTracks() {
    final snapshot = List<DownloadedTrack>.unmodifiable(downloadedTracks);
    return _downloadedTracksSaveQueue.enqueue(
      () => storage.saveDownloadedTracks(snapshot),
    );
  }

  Future<void> _savePendingAlbumMatches() {
    final snapshot = List<PendingAlbumMatch>.unmodifiable(pendingAlbumMatches);
    return _pendingAlbumMatchesSaveQueue.enqueue(
      () => storage.savePendingAlbumMatches(snapshot),
    );
  }

  Future<void> _savePendingAlbumMatchesBestEffort() async {
    try {
      await _savePendingAlbumMatches();
    } catch (error, stackTrace) {
      AppLog.instance.warning(
        'storage',
        '保存待确认专辑失败',
        detail: '$error\n$stackTrace',
      );
    }
  }

  Future<void> _addDownloadedTrack(DownloadTask task) async {
    DownloadedTrack? replacedTrack;
    for (final track in downloadedTracks) {
      if (track.path == task.savePath) {
        replacedTrack = track;
        break;
      }
    }
    final coverFilePath = await storage.cacheEmbeddedCover(
      File(task.savePath),
      cacheKey: '${task.track.id}-${DateTime.now().microsecondsSinceEpoch}',
    );
    final item = DownloadedTrack(
      id: task.track.id,
      title: task.track.title,
      artist: task.track.artist,
      path: task.savePath,
      format: task.candidate.format,
      downloadedAt: DateTime.now(),
      sourceUrl: task.track.detailUrl,
      album: task.album,
      coverUrl: task.track.coverUrl,
      coverFilePath: coverFilePath,
      durationMs: _parseTrackDuration(task.track.duration)?.inMilliseconds,
    );
    downloadedTracks = [
      item,
      ...downloadedTracks.where((track) => track.path != item.path),
    ];
    _libraryLyricsSearchCache.remove(_libraryLyricsCacheKey(item));
    final removedPending = _removePendingAlbumMatchForPath(item.path);
    await Future.wait<void>([
      _saveDownloadedTracks(),
      if (removedPending) _savePendingAlbumMatches(),
    ]);
    if (replacedTrack?.coverFilePath != coverFilePath) {
      await _deleteUnusedCachedCover(replacedTrack?.coverFilePath);
    }
    if (LibrarySearch.normalize(libraryQuery).isNotEmpty) {
      unawaited(_ensureLibraryLyricsForQuery(libraryQuery));
    }
  }

  Future<void> _hydrateDownloadedTracksInBackground() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (_isDisposed) return;
    final hydrated = await mapWithConcurrency(
      List<DownloadedTrack>.from(downloadedTracks),
      (track) async {
        if (_isDisposed) {
          return null;
        }
        final result = await _hydrateDownloadedTrack(track);
        await Future<void>.delayed(Duration.zero);
        return result;
      },
      maxConcurrent: 3,
    );

    if (_isDisposed) return;
    final updates = {
      for (final result in hydrated.whereType<_HydratedTrack>())
        _trackPathKey(result.original.path): result,
    };
    final changedPaths = <String>{};
    // Merge once against the live collection. Edits, removals and reimports
    // during I/O take precedence over a background snapshot.
    final merged = downloadedTracks.map((track) {
      final key = _trackPathKey(track.path);
      final result = updates[key];
      if (result == null || !identical(track, result.original)) return track;
      changedPaths.add(key);
      return result.updated;
    }).toList();
    if (changedPaths.isNotEmpty) {
      downloadedTracks = merged;
      pendingAlbumMatches = [
        for (final pending in pendingAlbumMatches)
          if (!changedPaths.contains(_trackPathKey(pending.trackPath)) ||
              updates[_trackPathKey(pending.trackPath)]!.updated.album
                  .trim()
                  .isEmpty)
            pending,
      ];
      _notify();
      try {
        await Future.wait<void>([
          _saveDownloadedTracks(),
          _savePendingAlbumMatches(),
        ]);
      } catch (_) {
        // Background hydration is best-effort and can retry next launch.
      }
    }
    await _cleanupCoverCacheBestEffort();
  }

  Future<void> _cleanupCoverCacheBestEffort() async {
    try {
      final removed = await storage.cleanupCachedCovers([
        for (final track in downloadedTracks) track.coverFilePath,
        for (final item in queue) item.coverFilePath,
      ]);
      if (removed > 0) {
        AppLog.instance.info('storage', '已清理 $removed 个未使用的封面缓存');
      }
    } catch (error, stackTrace) {
      AppLog.instance.warning(
        'storage',
        '清理未使用封面缓存失败',
        detail: '$error\n$stackTrace',
      );
    }
  }

  Future<void> _deleteUnusedCachedCover(String? coverPath) async {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) {
      return;
    }
    final key = _trackPathKey(value);
    final stillReferenced =
        downloadedTracks.any(
          (track) =>
              track.coverFilePath != null &&
              _trackPathKey(track.coverFilePath!) == key,
        ) ||
        queue.any(
          (item) =>
              item.coverFilePath != null &&
              _trackPathKey(item.coverFilePath!) == key,
        );
    if (stillReferenced) {
      return;
    }
    try {
      await storage.deleteCachedCover(value);
    } catch (error, stackTrace) {
      AppLog.instance.warning(
        'storage',
        '删除旧封面缓存失败',
        detail: '$value\n$error\n$stackTrace',
      );
    }
  }

  Future<_HydratedTrack?> _hydrateDownloadedTrack(
    DownloadedTrack snapshot,
  ) async {
    final trackPathKey = _trackPathKey(snapshot.path);
    if (!_tryBeginMetadataWrite(trackPathKey)) {
      return null;
    }
    try {
      return await _hydrateDownloadedTrackUnlocked(snapshot);
    } finally {
      _metadataWriteKeys.remove(trackPathKey);
    }
  }

  Future<_HydratedTrack?> _hydrateDownloadedTrackUnlocked(
    DownloadedTrack snapshot,
  ) async {
    final current = _downloadedTrackByPath(snapshot.path);
    if (!identical(current, snapshot) ||
        current == null ||
        current.format.toLowerCase() != 'mp3') {
      return null;
    }

    final currentCoverPath = current.coverFilePath?.trim();
    final hasCover =
        currentCoverPath != null &&
        currentCoverPath.isNotEmpty &&
        await File(currentCoverPath).exists();
    if (hasCover && current.album.trim().isNotEmpty) {
      return null;
    }

    try {
      final metadata = await Id3LyricsEmbedder.extractMetadata(
        File(current.path),
      );
      String? hydratedCoverPath;
      if (!hasCover && metadata.cover != null) {
        hydratedCoverPath = await storage.cacheCoverImage(
          metadata.cover!,
          cacheKey: 'startup-${_trackPathKey(p.absolute(current.path))}',
        );
      }
      final hydratedAlbum = metadata.album?.trim();

      if (_isDisposed ||
          !identical(_downloadedTrackByPath(snapshot.path), snapshot)) {
        return null;
      }

      var updated = current;
      var changed = false;
      if (!hasCover && hydratedCoverPath != null) {
        updated = updated.copyWith(coverFilePath: hydratedCoverPath);
        changed = true;
      }
      if (updated.album.trim().isEmpty &&
          hydratedAlbum != null &&
          hydratedAlbum.isNotEmpty) {
        updated = updated.copyWith(album: hydratedAlbum);
        changed = true;
      }
      if (!changed) {
        return null;
      }
      return _HydratedTrack(original: current, updated: updated);
    } catch (_) {
      return null;
    }
  }

  Future<_LocalAudioMetadata> _readLocalAudioMetadata(
    File file,
    String format,
  ) async {
    if (format != 'mp3') {
      return const _LocalAudioMetadata();
    }

    final metadata = await Id3LyricsEmbedder.extractMetadata(file);
    String? coverFilePath;
    if (metadata.cover != null) {
      coverFilePath = await storage.cacheCoverImage(
        metadata.cover!,
        cacheKey: 'scan-${_trackPathKey(p.absolute(file.path))}',
      );
    }
    return _LocalAudioMetadata(
      title: metadata.title,
      artist: metadata.artist,
      album: metadata.album,
      coverFilePath: coverFilePath,
    );
  }

  _ParsedTrackFileName _parseTrackNameFromFile(String path) {
    final name = p.basenameWithoutExtension(path).trim();
    final separators = [' - ', '-', ' – ', ' — '];
    for (final separator in separators) {
      final index = name.indexOf(separator);
      if (index > 0 && index + separator.length < name.length) {
        final artist = name.substring(0, index).trim();
        final title = name.substring(index + separator.length).trim();
        if (title.isNotEmpty) {
          return _ParsedTrackFileName(title: title, artist: artist);
        }
      }
    }
    return _ParsedTrackFileName(title: name, artist: '');
  }

  String? _supportedLocalAudioFormat(String path) {
    final extension = p.extension(path).toLowerCase().replaceFirst('.', '');
    return switch (extension) {
      'mp3' || 'flac' || 'm4a' || 'aac' || 'wav' || 'ogg' => extension,
      _ => null,
    };
  }

  String _localTrackId(String path, FileStat stat) {
    final safeName = StorageService.sanitizeFilePart(
      p.basenameWithoutExtension(path),
    );
    return 'local-${safeName.isEmpty ? 'track' : safeName}-${stat.size}-${stat.modified.millisecondsSinceEpoch}';
  }

  String _libraryLyricsCacheKey(DownloadedTrack track) {
    return p.normalize(track.path).toLowerCase();
  }

  LibrarySearchIndex _librarySearchIndexFor(
    DownloadedTrack track, {
    bool includeCachedLyrics = true,
  }) {
    final lyrics = includeCachedLyrics
        ? _libraryLyricsSearchCache[_libraryLyricsCacheKey(track)] ?? ''
        : '';
    final key = [
      p.normalize(track.path).toLowerCase(),
      track.title,
      track.artist,
      track.album,
      lyrics.hashCode,
    ].join('\u0001');
    final maxCacheEntries = max(256, downloadedTracks.length * 2);
    if (_librarySearchIndexCache.length >= maxCacheEntries &&
        !_librarySearchIndexCache.containsKey(key)) {
      _librarySearchIndexCache.clear();
    }
    return _librarySearchIndexCache.putIfAbsent(
      key,
      () => LibrarySearchIndex.fromTrack(track, lyrics: lyrics),
    );
  }

  String _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return '';
  }
}
