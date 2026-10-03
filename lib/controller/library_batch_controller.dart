part of '../app_controller.dart';

class LibraryBatchFailure {
  const LibraryBatchFailure(this.track, this.message);
  final DownloadedTrack track;
  final String message;
}

class LibraryBatchResult {
  const LibraryBatchResult({
    this.completedPaths = const [],
    this.failures = const [],
    this.warnings = const [],
  });
  final List<String> completedPaths;
  final List<LibraryBatchFailure> failures;
  final List<String> warnings;
}

extension AppControllerLibraryBatchActions on AppController {
  Future<LibraryBatchResult> setFavoritesForTracks(
    Iterable<DownloadedTrack> tracks, {
    required bool favorite,
  }) => _runLibraryBatch(
    favorite ? '批量收藏' : '批量取消收藏',
    tracks,
    apply: (track) async {
      final key = _trackPathKey(track.path);
      if (favorite && isFavorite(track)) return;
      final paths = myMusic.favoriteTrackPaths
          .where((path) => _trackPathKey(path) != key)
          .toList();
      myMusic = myMusic.copyWith(
        favoriteTrackPaths: favorite ? [...paths, track.path] : paths,
      );
    },
    save: _saveMyMusic,
  );

  Future<LibraryBatchResult> setTracksInPlaylist(
    String playlistId,
    Iterable<DownloadedTrack> tracks, {
    required bool included,
  }) => _runLibraryBatch(
    included ? '批量加入歌单' : '批量移出歌单',
    tracks,
    apply: (track) async {
      final playlist = playlistById(playlistId);
      if (playlist == null) throw StateError('歌单已不存在');
      final key = _trackPathKey(track.path);
      final paths = playlist.trackPaths
          .where((path) => _trackPathKey(path) != key)
          .toList();
      // Already included songs keep their position; repeated adds are idempotent.
      final next =
          included &&
              playlist.trackPaths.any((path) => _trackPathKey(path) == key)
          ? playlist.trackPaths
          : included
          ? [...paths, track.path]
          : paths;
      myMusic = myMusic.copyWith(
        playlists: [
          for (final item in myMusic.playlists)
            item.id == playlistId ? item.copyWith(trackPaths: next) : item,
        ],
      );
    },
    save: _saveMyMusic,
  );

  Future<LibraryBatchResult> setAlbumsForTracks(
    Iterable<DownloadedTrack> tracks,
    String album,
  ) => _runLibraryBatch(
    '批量修改专辑',
    tracks,
    needsFiles: true,
    apply: (track) => _setBatchAlbum(track, album.trim()),
    save: () async {
      await Future.wait([
        _saveDownloadedTracks(),
        _saveQueueState(),
        _savePendingAlbumMatches(),
      ]);
      unawaited(_syncAndroidMediaControls(force: true));
      _scheduleMetadataTagWrites();
    },
  );

  Future<void> _setBatchAlbum(DownloadedTrack track, String album) async {
    final key = _trackPathKey(track.path);
    if (!_tryBeginMetadataWrite(key)) throw StateError('歌曲正在处理中，请稍后重试');
    try {
      final file = File(track.path);
      if (!await file.exists()) throw const FileSystemException('本地歌曲文件不存在');
      if (track.album == album &&
          track.metadataDirtyFields.contains('album') &&
          !track.metadataFillOnlyFields.contains('album')) {
        return;
      }
      final deferTags =
          track.format.toLowerCase() == 'mp3' &&
          _isTrackLoadedInPlayer(track.path);
      final embedded = deferTags
          ? await Id3LyricsEmbedder.extractMetadata(file)
          : null;
      var coverPath = track.coverFilePath;
      if (deferTags &&
          coverPath == null &&
          embedded?.cover != null &&
          !track.metadataDirtyFields.contains('cover')) {
        coverPath = await storage.cacheCoverImage(
          embedded!.cover!,
          cacheKey: 'batch-album-${_trackPathKey(track.path)}',
        );
      }
      if (track.format.toLowerCase() == 'mp3' && !deferTags) {
        // Null lyrics and cover preserve the existing frames verbatim.
        await Id3LyricsEmbedder.embedMetadata(file, album: album);
        await file.setLastModified(track.downloadedAt);
      }
      final updated = _markMetadataEdit(
        track,
        track.copyWith(
          album: album,
          metadataLyrics: track.metadataLyrics ?? embedded?.lyrics,
          coverFilePath: coverPath,
          metadataPendingFileWrite: deferTags || track.metadataPendingFileWrite,
        ),
        {'album'},
      );
      downloadedTracks = [
        for (final item in downloadedTracks)
          _trackPathKey(item.path) == key ? updated : item,
      ];
      queue = [
        for (final item in queue)
          item.localPath != null && _trackPathKey(item.localPath!) == key
              ? item.copyWith(album: album, coverFilePath: coverPath)
              : item,
      ];
      _removePendingAlbumMatchForPath(track.path);
      _visibleDownloadedTracksSource = null;
    } finally {
      _metadataWriteKeys.remove(key);
    }
  }

  Future<LibraryBatchResult> removeDownloadedRecords(
    Iterable<DownloadedTrack> tracks,
  ) => _runLibraryBatch(
    '批量删除记录',
    tracks,
    apply: (track) async {
      final key = _trackPathKey(track.path);
      if (_metadataWriteKeys.contains(key) ||
          _metadataReadInProgress(key) ||
          _deletingTrackKeys.contains(key)) {
        throw StateError('歌曲正在处理中，请稍后重试');
      }
      _removeDownloadedRecordInMemory(track);
      await _deleteUnusedCachedCover(track.coverFilePath);
    },
    save: () async {
      await Future.wait([
        _saveMyMusic(),
        _saveDownloadedTracks(),
        _savePendingAlbumMatches(),
      ]);
    },
  );

  Future<LibraryBatchResult> deleteDownloadedTracks(
    Iterable<DownloadedTrack> tracks,
  ) {
    final originalItem = currentItem;
    final wasPlaying = player.isPlaying;
    var removedCurrent = false;
    final warnings = <String>[];
    return _runLibraryBatch(
      '批量删除歌曲',
      tracks,
      needsFiles: true,
      warnings: warnings,
      apply: (track) async {
        final deletingCurrent =
            originalItem?.localPath != null &&
            _trackPathKey(originalItem!.localPath!) ==
                _trackPathKey(track.path);
        if (!await deleteDownloadedTrack(track, resumePlayback: false)) {
          throw StateError(globalMessage ?? '歌曲删除失败');
        }
        removedCurrent = removedCurrent || deletingCurrent;
        if (globalMessage?.contains('保存失败') == true) {
          warnings.add('${track.title}：$globalMessage');
        }
      },
      save: () async {
        if (removedCurrent &&
            wasPlaying &&
            queue.isNotEmpty &&
            !_isDisposed &&
            !_preparingToExit &&
            currentItem?.uri != originalItem?.uri &&
            !player.isPlaying) {
          try {
            if (!await _openCurrentItemForPlayback()) {
              warnings.add('自动接续播放失败，请手动选择歌曲。');
            }
          } catch (_) {
            warnings.add('自动接续播放失败，请手动选择歌曲。');
          }
        }
      },
    );
  }

  Future<LibraryBatchResult> _runLibraryBatch(
    String label,
    Iterable<DownloadedTrack> tracks, {
    required Future<void> Function(DownloadedTrack) apply,
    required Future<void> Function() save,
    bool needsFiles = false,
    List<String>? warnings,
  }) async {
    final unique = <String, DownloadedTrack>{
      for (final track in tracks) _trackPathKey(track.path): track,
    }.values.toList();
    if (unique.isEmpty) return const LibraryBatchResult();
    final blocked = isLibraryBatchRunning
        ? '已有批量操作正在进行，请稍候。'
        : _isDisposed || _preparingToExit
        ? '应用正在退出，未开始批量操作。'
        : needsFiles && (isCloudSyncing || _cloudSyncOperation != null)
        ? '云盘正在同步，请同步完成后再操作。'
        : null;
    if (blocked != null) {
      showMessage(blocked);
      return LibraryBatchResult(
        failures: [
          for (final track in unique) LibraryBatchFailure(track, blocked),
        ],
      );
    }
    isLibraryBatchRunning = true;
    libraryBatchCompleted = 0;
    libraryBatchTotal = unique.length;
    _notify();
    final operation = _processLibraryBatch(
      label,
      unique,
      apply: apply,
      save: save,
      warnings: warnings ?? [],
    );
    _libraryBatchOperation = operation;
    try {
      return await operation;
    } finally {
      _libraryBatchOperation = null;
      isLibraryBatchRunning = false;
      _notify();
    }
  }

  Future<LibraryBatchResult> _processLibraryBatch(
    String label,
    List<DownloadedTrack> tracks, {
    required Future<void> Function(DownloadedTrack) apply,
    required Future<void> Function() save,
    required List<String> warnings,
  }) async {
    final completed = <String>[];
    final failures = <LibraryBatchFailure>[];
    for (final snapshot in tracks) {
      try {
        if (_isDisposed || _preparingToExit) throw StateError('应用退出，未处理此歌曲');
        final latest = _downloadedTrackByPath(snapshot.path);
        if (latest == null || latest.id != snapshot.id) {
          throw StateError('歌曲记录已不存在或已被替换');
        }
        await apply(latest);
        completed.add(snapshot.path);
      } catch (error, stackTrace) {
        failures.add(
          LibraryBatchFailure(snapshot, _friendlyUnexpectedError(error)),
        );
        AppLog.instance.warning(
          'library',
          '$label失败：${snapshot.title}',
          detail: '$error\n$stackTrace',
        );
      }
      libraryBatchCompleted++;
      _notify();
    }
    try {
      try {
        await save();
      } catch (_) {
        await save();
      }
    } catch (error, stackTrace) {
      warnings.add('当前界面已更新，但保存失败：${_friendlyUnexpectedError(error)}');
      AppLog.instance.error(
        'library',
        '$label保存失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
    globalMessage =
        '$label完成：成功 ${completed.length} 首，失败 ${failures.length} 首。'
        '${warnings.isEmpty ? '' : ' ${warnings.join(' ')}'}';
    _notify();
    return LibraryBatchResult(
      completedPaths: List.unmodifiable(completed),
      failures: List.unmodifiable(failures),
      warnings: List.unmodifiable(warnings),
    );
  }
}
