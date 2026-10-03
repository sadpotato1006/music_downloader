part of '../app_controller.dart';

extension AppControllerSongMetadataActions on AppController {
  DownloadedTrack _markMetadataEdit(
    DownloadedTrack original,
    DownloadedTrack updated,
    Set<String> fields, {
    bool fillOnly = false,
  }) {
    if (fields.isEmpty) return updated;
    final deviceId = original.metadataDeviceId.isEmpty
        ? newMetadataDeviceId()
        : original.metadataDeviceId;
    final sequence = original.metadataEditSequence + 1;
    final editId = '$deviceId:$sequence';
    return updated.copyWith(
      metadataEditId: editId,
      metadataDeviceId: deviceId,
      metadataEditSequence: sequence,
      metadataFieldEditIds: {
        ...original.metadataFieldEditIds,
        for (final field in fields) field: editId,
      },
      metadataDirtyFields: {...original.metadataDirtyFields, ...fields},
      metadataFillOnlyFields: fillOnly
          ? {
              ...original.metadataFillOnlyFields,
              ...fields.difference(original.metadataDirtyFields),
            }
          : original.metadataFillOnlyFields.difference(fields),
    );
  }

  Future<LocalSongMetadata> _localSongMetadata(DownloadedTrack track) async {
    final knownCover = track.syncedMetadata?.values;
    final reuseCover =
        knownCover != null && !track.metadataDirtyFields.contains('cover');
    final cover = track.coverFilePath == null || reuseCover
        ? null
        : await _loadCoverFromManualInput(track.coverFilePath!);
    if (track.coverFilePath != null && cover == null && !reuseCover) {
      throw const FileSystemException('歌曲封面缓存不可用');
    }
    final lyrics =
        track.metadataLyrics ??
        (track.format.toLowerCase() == 'mp3'
            ? await Id3LyricsEmbedder.extractLyrics(File(track.path))
            : await _readSidecarLyrics(File(track.path))) ??
        '';
    return LocalSongMetadata(
      values: SongMetadata(
        title: track.title,
        artist: track.artist,
        album: track.album,
        lyrics: lyrics,
        coverHash: reuseCover
            ? knownCover.coverHash
            : SongMetadata.hashCover(cover),
        coverMimeType: reuseCover ? knownCover.coverMimeType : cover?.mimeType,
      ),
      cover: cover,
      coverFilePath:
          track.coverFilePath != null &&
              await File(track.coverFilePath!).exists()
          ? track.coverFilePath
          : null,
      fields: track.metadataDirtyFields,
      fillOnly: track.metadataFillOnlyFields,
      editId: track.metadataEditId,
      fieldEditIds: track.metadataFieldEditIds,
      baseline: track.syncedMetadata,
      baselineRev: track.syncedMetadataRev,
      pendingFileWrite: track.metadataPendingFileWrite,
    );
  }

  Future<void> _applySyncedSongMetadata(
    Map<String, SyncedSongMetadata> updates,
  ) async {
    var changed = false;
    final oldCovers = <String?>{};
    for (final entry in updates.entries) {
      final current = _downloadedTrackByPath(entry.key);
      if (current == null) continue;
      final synced = entry.value,
          document = synced.document,
          values = document.values;
      final acknowledged =
          current.metadataEditId.isEmpty ||
          (current.metadataEditId == synced.acknowledgedEditId &&
              document.hasEdit(current.metadataEditId));
      // A download may finish while sync is running; keep its later edits.
      if (!acknowledged && current.metadataDirtyFields.isNotEmpty) continue;
      if (current.syncedMetadataRev == synced.metadataRev &&
          current.syncId == document.syncId &&
          current.metadataDirtyFields.isEmpty &&
          current.metadataPendingFileWrite == synced.pendingFileWrite &&
          current.title == values.title &&
          current.artist == values.artist &&
          current.album == values.album &&
          current.metadataLyrics == values.lyrics &&
          current.coverFilePath == synced.coverFilePath &&
          current.coverUrl == null) {
        continue;
      }
      String? coverPath;
      if (values.coverHash != null &&
          synced.coverFilePath == current.coverFilePath &&
          current.coverFilePath != null) {
        coverPath = current.coverFilePath;
      } else if (synced.cover != null || synced.coverFilePath != null) {
        final cover =
            synced.cover ??
            Id3CoverImage(
              mimeType: values.coverMimeType!,
              bytes: await File(synced.coverFilePath!).readAsBytes(),
            );
        if (SongMetadata.hashCover(cover) != values.coverHash) {
          throw const FormatException('同步封面校验失败');
        }
        coverPath = await storage.cacheCoverImage(
          cover,
          cacheKey: 'cloud-${document.syncId}-${values.coverHash}',
        );
      }
      final updated = current.copyWith(
        syncId: document.syncId,
        title: values.title,
        artist: values.artist,
        album: values.album,
        metadataLyrics: values.lyrics,
        coverFilePath: coverPath,
        clearCoverFilePath: coverPath == null,
        clearCoverUrl: true,
        syncedMetadata: document,
        syncedMetadataRev: synced.metadataRev,
        metadataEditId: acknowledged ? '' : current.metadataEditId,
        metadataFieldEditIds: acknowledged
            ? const {}
            : current.metadataFieldEditIds,
        metadataDirtyFields: acknowledged
            ? const {}
            : current.metadataDirtyFields,
        metadataFillOnlyFields: acknowledged
            ? const {}
            : current.metadataFillOnlyFields,
        metadataPendingFileWrite:
            synced.pendingFileWrite && current.format.toLowerCase() == 'mp3',
      );
      downloadedTracks = [
        for (final item in downloadedTracks)
          _trackPathKey(item.path) == _trackPathKey(current.path)
              ? updated
              : item,
      ];
      queue = [
        for (final item in queue)
          item.localPath != null &&
                  _trackPathKey(item.localPath!) == _trackPathKey(current.path)
              ? item.copyWith(
                  title: updated.title,
                  artist: updated.artist,
                  album: updated.album,
                  lyrics: values.lyrics,
                  coverFilePath: coverPath,
                  clearCoverFilePath: coverPath == null,
                  clearCoverUrl: true,
                )
              : item,
      ];
      _libraryLyricsSearch.update(updated, values.lyrics);
      if (updated.album.isNotEmpty ||
          document.manualFields.contains('album') ||
          updated.title != current.title ||
          updated.artist != current.artist) {
        _removePendingAlbumMatchForPath(current.path);
      }
      if (current.coverFilePath != coverPath) {
        oldCovers.add(current.coverFilePath);
      }
      changed = true;
    }
    if (!changed) return;
    await Future.wait([
      _saveDownloadedTracks(),
      _saveQueueState(),
      _savePendingAlbumMatches(),
    ]);
    for (final path in oldCovers) {
      await _deleteUnusedCachedCover(path);
    }
    _visibleDownloadedTracksSource = null;
    unawaited(_syncAndroidMediaControls(force: true));
    _notify();
  }

  void _scheduleMetadataTagWrites() {
    if (_isDisposed ||
        _preparingToExit ||
        _cloudSyncOwnsFiles ||
        _metadataTagWriteOperation != null ||
        !downloadedTracks.any(
          (track) =>
              track.metadataPendingFileWrite &&
              !_isTrackLoadedInPlayer(track.path),
        )) {
      return;
    }
    late final Future<void> operation;
    operation = _writePendingMetadataTags().whenComplete(() {
      if (identical(operation, _metadataTagWriteOperation)) {
        _metadataTagWriteOperation = null;
      }
    });
    _metadataTagWriteOperation = operation;
    unawaited(operation);
  }

  Future<void> _writePendingMetadataTags() async {
    await _playbackMutationQueue;
    for (final snapshot in downloadedTracks.toList()) {
      if (_isDisposed || _preparingToExit || _cloudSyncOwnsFiles) return;
      if (!snapshot.metadataPendingFileWrite ||
          _isTrackLoadedInPlayer(snapshot.path)) {
        continue;
      }
      final key = _trackPathKey(snapshot.path);
      if (!_tryBeginMetadataWrite(key)) continue;
      try {
        final current = _downloadedTrackByPath(snapshot.path);
        if (current == null || !current.metadataPendingFileWrite) continue;
        final metadata = await _localSongMetadata(current);
        await metadata.values.writeMp3(
          File(current.path),
          await metadata.loadCover(),
        );
        await File(current.path).setLastModified(current.downloadedAt);
        final latest = _downloadedTrackByPath(current.path);
        if (!identical(current, latest)) continue;
        downloadedTracks = [
          for (final track in downloadedTracks)
            _trackPathKey(track.path) == key
                ? track.copyWith(metadataPendingFileWrite: false)
                : track,
        ];
        await _saveDownloadedTracks();
      } catch (error, stackTrace) {
        AppLog.instance.error(
          'metadata',
          '歌曲标签待写入任务失败，保留待处理记录',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        _metadataWriteKeys.remove(key);
      }
    }
  }
}
