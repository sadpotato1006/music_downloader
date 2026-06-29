part of '../app_controller.dart';

extension AppControllerLibraryActions on AppController {
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
    downloadedTracks = downloadedTracks
        .where((item) => item.id != track.id || item.path != track.path)
        .toList();
    final key = _libraryLyricsCacheKey(track);
    _libraryLyricsSearchCache.remove(key);
    _loadingLibraryLyricsKeys.remove(key);
    await _removeTrackFromMyMusic(track.path);
    await _saveDownloadedTracks();
    _notify();
  }

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
        for (final track in downloadedTracks) p.normalize(track.path): track,
      };
      final imported = <DownloadedTrack>[];

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

        final normalizedPath = p.normalize(entity.path);
        if (knownPaths.containsKey(normalizedPath)) {
          continue;
        }

        try {
          final stat = await entity.stat();
          final metadata = await _readLocalAudioMetadata(entity, format);
          final fileName = _parseTrackNameFromFile(entity.path);
          final title = _firstNonEmpty([
            metadata.title,
            fileName.title,
            p.basenameWithoutExtension(entity.path),
          ]);
          final artist = _firstNonEmpty([metadata.artist, fileName.artist]);
          final album = _firstNonEmpty([metadata.album]);
          final coverFilePath = metadata.coverFilePath;

          final item = DownloadedTrack(
            id: _localTrackId(entity.path, stat),
            title: title,
            artist: artist,
            path: entity.path,
            format: format,
            downloadedAt: stat.modified,
            sourceUrl: entity.uri.toString(),
            album: album,
            coverFilePath: coverFilePath,
          );
          imported.add(item);
          knownPaths[normalizedPath] = item;
        } catch (_) {
          // Ignore a single unreadable file and keep scanning the directory.
        }
      }

      if (imported.isNotEmpty) {
        downloadedTracks = [
          ...imported,
          ...downloadedTracks.where(
            (track) => !imported.any(
              (item) => p.normalize(item.path) == p.normalize(track.path),
            ),
          ),
        ];
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
  }

  Future<bool> updateDownloadedTrack(
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
          lyrics: trimmedLyrics.isEmpty ? null : trimmedLyrics,
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
    downloadedTracks = [
      for (final item in downloadedTracks)
        item.id == track.id && item.path == track.path ? updated : item,
    ];
    _libraryLyricsSearchCache[_libraryLyricsCacheKey(updated)] = trimmedLyrics;
    queue = [
      for (final item in queue)
        item.localPath == track.path
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
    matchingAlbumTrackId = track.id;
    globalMessage = null;
    _notify();

    try {
      final current = downloadedTracks.firstWhere(
        (item) => item.id == track.id && item.path == track.path,
        orElse: () => track,
      );
      final lyrics = current.format.toLowerCase() == 'mp3'
          ? await readDownloadedLyrics(current)
          : null;
      final candidates = await albumMetadata.findAlbumCandidates(
        title: current.title,
        artist: current.artist,
        lyrics: lyrics,
        limit: 5,
      );
      if (candidates.isEmpty) {
        globalMessage = '没有找到可用的专辑候选。';
      }
      return candidates;
    } catch (error) {
      globalMessage = '获取专辑名称失败：${_friendlyUnexpectedError(error)}';
      return const [];
    } finally {
      isMatchingLocalAlbums = false;
      matchingAlbumTrackId = null;
      _notify();
    }
  }

  Future<bool> applyDownloadedAlbumName(
    DownloadedTrack track,
    String album,
  ) async {
    final success = await _applyAlbumToDownloadedTrack(
      track,
      album.trim(),
      notify: false,
    );
    if (!success) {
      return false;
    }
    _notify();
    return true;
  }

  Future<int> matchMissingDownloadedAlbums() async {
    if (isMatchingLocalAlbums) {
      return 0;
    }

    isMatchingLocalAlbums = true;
    matchingAlbumTrackId = null;
    globalMessage = null;
    _notify();

    var updatedCount = 0;
    try {
      final targets = downloadedTracks
          .where((track) => track.album.trim().isEmpty)
          .toList(growable: false);
      for (final target in targets) {
        final current = downloadedTracks.firstWhere(
          (track) => track.id == target.id && track.path == target.path,
          orElse: () => target,
        );
        if (current.album.trim().isNotEmpty) {
          continue;
        }

        matchingAlbumTrackId = current.id;
        _notify();

        final lyrics = current.format.toLowerCase() == 'mp3'
            ? await readDownloadedLyrics(current)
            : null;
        final match = await albumMetadata.findBestAlbum(
          title: current.title,
          artist: current.artist,
          lyrics: lyrics,
        );
        final album = match?.album.trim();
        if (album == null || album.isEmpty) {
          continue;
        }

        final didUpdate = await _applyAlbumToDownloadedTrack(
          current,
          album,
          notify: false,
        );
        if (didUpdate) {
          updatedCount += 1;
        }
      }

      globalMessage = updatedCount == 0
          ? '专辑匹配完成，没有发现可更新的专辑名称。'
          : '专辑匹配完成，已更新 $updatedCount 首歌曲。';
      return updatedCount;
    } catch (error) {
      globalMessage = '专辑匹配失败：${_friendlyUnexpectedError(error)}';
      return updatedCount;
    } finally {
      isMatchingLocalAlbums = false;
      matchingAlbumTrackId = null;
      _notify();
    }
  }

  Future<PlayerItem?> _playerItemFromDownloadedTrack(
    DownloadedTrack track, {
    bool includeLyrics = true,
    bool showMissingMessage = true,
  }) async {
    final file = File(track.path);
    if (!await file.exists()) {
      if (showMissingMessage) {
        globalMessage = '本地文件不存在：${track.path}';
        _notify();
      }
      return null;
    }

    Id3Metadata metadata = const Id3Metadata();
    if (includeLyrics || track.album.trim().isEmpty) {
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
    downloadedTracks = [
      for (final item in downloadedTracks)
        item.id == original.id && item.path == original.path ? updated : item,
    ];
    queue = [
      for (final item in queue)
        item.localPath == original.path
            ? item.copyWith(album: updated.album)
            : item,
    ];
    await _saveDownloadedTracks();
    await _saveQueueState();
    _notify();
  }

  Future<bool> _applyAlbumToDownloadedTrack(
    DownloadedTrack track,
    String album, {
    bool notify = true,
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
        item.localPath == track.path
            ? item.copyWith(album: trimmedAlbum)
            : item,
    ];
    await _saveDownloadedTracks();
    await _saveQueueState();
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
    if (!downloadedTracks.any((track) => _trackPathKey(track.path) == key)) {
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

  Future<void> _removeTrackFromMyMusic(String trackPath) async {
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
    await _saveMyMusic();
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
    final previousSave = _myMusicSaveQueue;
    final operation = () async {
      try {
        await previousSave;
      } catch (_) {
        // A failed save must not prevent newer collection state from saving.
      }
      await storage.saveMyMusic(snapshot);
    }();
    _myMusicSaveQueue = operation;
    return operation;
  }

  Future<void> _saveDownloadedTracks() {
    final snapshot = List<DownloadedTrack>.unmodifiable(downloadedTracks);
    final previousSave = _downloadedTracksSaveQueue;
    final operation = () async {
      try {
        await previousSave;
      } catch (_) {
        // A failed save must not prevent newer library state from persisting.
      }
      await storage.saveDownloadedTracks(snapshot);
    }();
    _downloadedTracksSaveQueue = operation;
    return operation;
  }

  Future<void> _addDownloadedTrack(DownloadTask task) async {
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
    );
    downloadedTracks = [
      item,
      ...downloadedTracks.where((track) => track.path != item.path),
    ];
    _libraryLyricsSearchCache.remove(_libraryLyricsCacheKey(item));
    await _saveDownloadedTracks();
    if (LibrarySearch.normalize(libraryQuery).isNotEmpty) {
      unawaited(_ensureLibraryLyricsForQuery(libraryQuery));
    }
  }

  Future<void> _hydrateDownloadedTracksInBackground() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    var pendingChanges = 0;
    var hasChanges = false;

    for (final track in List<DownloadedTrack>.from(downloadedTracks)) {
      if (_isDisposed) {
        break;
      }
      if (await _hydrateDownloadedTrack(track)) {
        pendingChanges += 1;
        hasChanges = true;
      }
      if (pendingChanges >= 8) {
        if (!_isDisposed) {
          _notify();
        }
        pendingChanges = 0;
      }
      await Future<void>.delayed(Duration.zero);
    }

    if (hasChanges) {
      try {
        await _saveDownloadedTracks();
      } catch (_) {
        // Background hydration is best-effort and can retry next launch.
      }
    }
    if (pendingChanges > 0 && !_isDisposed) {
      _notify();
    }
  }

  Future<bool> _hydrateDownloadedTrack(DownloadedTrack snapshot) async {
    final snapshotKey = _libraryLyricsCacheKey(snapshot);
    var current = _downloadedTrackByKey(snapshotKey);
    if (current == null || current.format.toLowerCase() != 'mp3') {
      return false;
    }

    final currentCoverPath = current.coverFilePath?.trim();
    final hasCover =
        currentCoverPath != null &&
        currentCoverPath.isNotEmpty &&
        await File(currentCoverPath).exists();
    if (hasCover && current.album.trim().isNotEmpty) {
      return false;
    }

    try {
      final metadata = await Id3LyricsEmbedder.extractMetadata(
        File(current.path),
      );
      String? hydratedCoverPath;
      if (!hasCover && metadata.cover != null) {
        hydratedCoverPath = await storage.cacheCoverImage(
          metadata.cover!,
          cacheKey:
              'startup-${current.id}-${p.basenameWithoutExtension(current.path)}',
        );
      }
      final hydratedAlbum = metadata.album?.trim();

      current = _downloadedTrackByKey(snapshotKey);
      if (current == null) {
        return false;
      }

      var updated = current;
      var changed = false;
      final latestCoverPath = current.coverFilePath?.trim();
      final latestHasCover =
          latestCoverPath != null &&
          latestCoverPath.isNotEmpty &&
          await File(latestCoverPath).exists();
      if (!latestHasCover && hydratedCoverPath != null) {
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
        return false;
      }

      downloadedTracks = [
        for (final track in downloadedTracks)
          _libraryLyricsCacheKey(track) == snapshotKey ? updated : track,
      ];
      return true;
    } catch (_) {
      return false;
    }
  }

  DownloadedTrack? _downloadedTrackByKey(String key) {
    for (final track in downloadedTracks) {
      if (_libraryLyricsCacheKey(track) == key) {
        return track;
      }
    }
    return null;
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
        cacheKey: 'scan-${p.basenameWithoutExtension(file.path)}',
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
