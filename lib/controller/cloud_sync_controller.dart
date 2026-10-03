part of '../app_controller.dart';

extension AppControllerCloudSyncActions on AppController {
  Future<void> _restoreCloudAndSync() async {
    try {
      cloudConnected = await cloudAuth.restore();
      if (_preparingToExit) return;
      _notify();
      if (cloudConnected &&
          settings?.cloudSyncEnabled == true &&
          settings!.cloudFolderId.isNotEmpty) {
        await syncCloud();
      }
    } catch (error, stackTrace) {
      cloudSyncError = '云盘登录状态恢复失败：$error';
      AppLog.instance.error(
        'cloud',
        '恢复云盘登录失败',
        error: error,
        stackTrace: stackTrace,
      );
      _notify();
    }
  }

  Future<Uri> beginCloudLogin() => cloudAuth.beginLogin();

  Future<void> finishCloudLogin(Uri callback) async {
    await cloudAuth.finishLogin(callback);
    cloudConnected = true;
    cloudSyncError = null;
    cloudSyncNotice = null;
    cloudSyncFailures = const [];
    cloudDeletionPolicyEnabled = null;
    _notify();
  }

  Future<List<AnyShareFolder>> cloudRootFolders() => cloudClient.ownedFolders();

  Future<AnyShareChildren> cloudFolderChildren(String id) =>
      cloudClient.listChildren(id);

  Future<void> selectCloudFolder(AnyShareFolder folder) async {
    final running = _cloudSyncOperation;
    if (running != null) await running;
    final current = settings;
    if (current == null) return;
    settings = current.copyWith(
      cloudFolderId: folder.id,
      cloudFolderName: folder.name,
      cloudSyncEnabled: true,
    );
    cloudDeletionPolicyEnabled = null;
    cloudSyncFailures = const [];
    await storage.saveSettings(settings!);
    _notify();
    unawaited(syncCloud());
  }

  Future<void> setCloudSyncEnabled(bool enabled) async {
    final current = settings;
    if (current == null) return;
    settings = current.copyWith(cloudSyncEnabled: enabled);
    await storage.saveSettings(settings!);
    _notify();
    if (enabled) unawaited(syncCloud());
  }

  Future<void> setCloudSyncDeletionsEnabled(bool enabled) async {
    final current = settings;
    if (current == null ||
        !cloudConnected ||
        current.cloudFolderId.isEmpty ||
        isCloudPolicyLoading) {
      return;
    }
    final running = _cloudSyncOperation;
    if (running != null) await running;
    isCloudPolicyLoading = true;
    cloudSyncError = null;
    _notify();
    try {
      cloudDeletionPolicyEnabled = await cloudSyncService.setDeletionPolicy(
        current.cloudFolderId,
        enabled,
      );
    } catch (error, stackTrace) {
      cloudSyncError = error is DioException
          ? _describeCloudRequestError(error)
          : '$error';
      AppLog.instance.error(
        'cloud',
        '修改云盘同步删除设置失败',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      isCloudPolicyLoading = false;
      _notify();
    }
  }

  Future<void> refreshCloudDeletionPolicy() async {
    final current = settings;
    if (current == null ||
        !cloudConnected ||
        current.cloudFolderId.isEmpty ||
        isCloudPolicyLoading ||
        isCloudSyncing) {
      return;
    }
    isCloudPolicyLoading = true;
    _notify();
    try {
      cloudDeletionPolicyEnabled = await cloudSyncService.readDeletionPolicy(
        current.cloudFolderId,
      );
      cloudSyncError = null;
    } catch (error, stackTrace) {
      cloudDeletionPolicyEnabled = null;
      cloudSyncError = error is DioException
          ? _describeCloudRequestError(error)
          : '$error';
      AppLog.instance.error(
        'cloud',
        '读取云盘同步删除设置失败',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      isCloudPolicyLoading = false;
      _notify();
    }
  }

  Future<void> disconnectCloud() async {
    final running = _cloudSyncOperation;
    if (running != null) await running;
    await cloudAuth.logout();
    cloudConnected = false;
    cloudDeletionPolicyEnabled = null;
    final current = settings;
    if (current != null) {
      settings = current.copyWith(
        cloudFolderId: '',
        cloudFolderName: '',
        cloudSyncEnabled: false,
      );
      await storage.saveSettings(settings!);
    }
    cloudSyncError = null;
    cloudSyncNotice = null;
    cloudSyncFailures = const [];
    _notify();
  }

  Future<CloudSyncResult?> retryFailedCloudSongs() => cloudSyncFailures.isEmpty
      ? Future<CloudSyncResult?>.value()
      : syncCloud(onlyPaths: {for (final item in cloudSyncFailures) item.path});

  Future<CloudSyncResult?> syncCloud({
    bool preferLocalOrder = false,
    Set<String>? onlyPaths,
  }) {
    final running = _cloudSyncOperation;
    if (running != null) return running;
    late final Future<CloudSyncResult?> operation;
    operation =
        _runCloudSync(
          preferLocalOrder: preferLocalOrder,
          onlyPaths: onlyPaths,
        ).whenComplete(() {
          if (identical(_cloudSyncOperation, operation)) {
            _cloudSyncOperation = null;
          }
        });
    _cloudSyncOperation = operation;
    return operation;
  }

  Future<CloudSyncResult?> _runCloudSync({
    bool preferLocalOrder = false,
    Set<String>? onlyPaths,
  }) async {
    final batch = _libraryBatchOperation;
    if (batch != null) await batch;
    final current = settings;
    if (current == null || !cloudConnected || current.cloudFolderId.isEmpty) {
      cloudSyncError = '请先登录北科云盘并选择歌曲文件夹';
      _notify();
      return null;
    }
    if (current.downloadDirectory.isEmpty) {
      cloudSyncError = '请先设置本地下载目录';
      _notify();
      return null;
    }
    isCloudSyncing = true;
    cloudSyncError = null;
    cloudSyncNotice = null;
    if (onlyPaths == null) cloudSyncFailures = const [];
    cloudSyncProgress = const CloudSyncProgress(
      completed: 0,
      total: 0,
      uploaded: 0,
      downloaded: 0,
      current: '',
      stage: CloudSyncStage.preparing,
    );
    _notify();
    try {
      final albumMatch = _activeAutomaticAlbumMatch;
      if (albumMatch != null) {
        cloudSyncProgress = const CloudSyncProgress(
          completed: 0,
          total: 0,
          uploaded: 0,
          downloaded: 0,
          current: '等待新歌专辑处理',
          stage: CloudSyncStage.waitingForAlbums,
        );
        _notify();
        await albumMatch;
      }
      _cloudSyncOwnsFiles = true;
      while (_metadataWriteKeys.isNotEmpty || _metadataReadCounts.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final metadataTracks = {
        for (final track in downloadedTracks)
          if (p.isWithin(current.downloadDirectory, track.path))
            p.relative(track.path, from: current.downloadDirectory): track,
      };
      final result = await cloudSyncService.sync(
        shouldStop: () => _preparingToExit,
        cloudFolderId: current.cloudFolderId,
        localDirectory: Directory(current.downloadDirectory),
        skipPaths: _unfinishedDownloadPaths(),
        preferLocalOrder: preferLocalOrder,
        onlyPaths: onlyPaths,
        readLocalMetadata: (path) async {
          final track =
              metadataTracks[path] ??
              _downloadedTrackByPath(p.join(current.downloadDirectory, path));
          return track == null ? null : await _localSongMetadata(track);
        },
        deferFilePaths: {
          for (final track in metadataTracks.values)
            if (_isTrackLoadedInPlayer(track.path)) track.path,
        },
        downloadedAtByPath: {
          for (final track in downloadedTracks)
            if (p.isWithin(current.downloadDirectory, track.path))
              p.relative(track.path, from: current.downloadDirectory):
                  track.downloadedAt,
        },
        onProgress: (value) {
          cloudSyncProgress = value;
          _notify();
        },
        onDeletionPolicyLoaded: (enabled) {
          cloudDeletionPolicyEnabled = enabled;
          _notify();
        },
      );
      cloudDeletionPolicyEnabled = result.deletionPolicyEnabled;
      cloudSyncFailures = result.failures;
      await _applyCloudDeletedTracks(result.deletedLocalPaths);
      final notices = <String>[
        '已上传 ${result.uploaded} 首，下载 ${result.downloaded} 首，'
            '跳过 ${result.skipped} 首，失败 ${result.failures.length} 首。',
        if (result.metadataUpdated > 0) '已更新 ${result.metadataUpdated} 首歌曲的信息。',
        if (result.pendingApproval > 0)
          '${result.pendingApproval} 首歌曲的云盘删除请求待审核；确认前不会删除其他设备上的歌曲。',
        if (result.pendingRemoval > 0)
          '${result.pendingRemoval} 首歌曲等待云盘确认删除；确认前不会删除其他设备上的歌曲。',
        if (preferLocalOrder)
          result.orderPublished > 0
              ? '已把 ${result.orderPublished} 首歌曲的本机下载顺序写入云盘。'
              : '没有找到可写入顺序的已同步歌曲。',
      ];
      cloudSyncNotice = notices.isEmpty ? null : notices.join('\n');
      lastCloudSyncAt = DateTime.now();
      final progress = cloudSyncProgress;
      cloudSyncProgress = CloudSyncProgress(
        completed: progress?.completed ?? 0,
        total: progress?.total ?? 0,
        uploaded: result.uploaded,
        downloaded: result.downloaded,
        current: '扫描当前下载目录',
        stage: CloudSyncStage.scanningLibrary,
        failed: result.failures.length,
      );
      _notify();
      await scanCurrentDownloadDirectory();
      await _applySyncedSongMetadata(result.metadataByPath);
      final restoredTimes = result.downloadedAtByPath.map(
        (path, time) => MapEntry(_trackPathKey(path), time),
      );
      if (restoredTimes.isNotEmpty) {
        var changed = false;
        downloadedTracks = downloadedTracks.map((track) {
          final time = restoredTimes[_trackPathKey(track.path)];
          if (time == null || track.downloadedAt == time) return track;
          changed = true;
          return track.copyWith(downloadedAt: time);
        }).toList();
        if (changed) {
          await _saveDownloadedTracks();
          _notify();
        }
      }
      cloudSyncProgress = CloudSyncProgress(
        completed: progress?.completed ?? 0,
        total: progress?.total ?? 0,
        uploaded: result.uploaded,
        downloaded: result.downloaded,
        current: '完成',
        stage: CloudSyncStage.complete,
        failed: result.failures.length,
      );
      return result;
    } catch (error, stackTrace) {
      cloudSyncNotice = null;
      cloudSyncError = error is DioException
          ? _describeCloudRequestError(error)
          : '$error';
      AppLog.instance.error(
        'cloud',
        '歌曲同步失败',
        error: error,
        stackTrace: stackTrace,
      );
      _notify();
      return null;
    } finally {
      _cloudSyncOwnsFiles = false;
      isCloudSyncing = false;
      _notify();
      _scheduleDeferredAlbumWrites();
      _scheduleMetadataTagWrites();
    }
  }

  Future<void> _applyCloudDeletedTracks(Set<String> paths) async {
    if (paths.isEmpty) return;
    final keys = paths.map(_trackPathKey).toSet();
    final affected = downloadedTracks
        .where((track) => keys.contains(_trackPathKey(track.path)))
        .toList();
    if (affected.isEmpty) return;
    var queueChanged = false;
    for (final track in affected) {
      if (currentItem?.localPath != null &&
          _trackPathKey(currentItem!.localPath!) == _trackPathKey(track.path)) {
        await _stopPlayback();
      }
      queueChanged =
          _removeDeletedTrackFromQueue(track.path).changed || queueChanged;
      _removeDownloadedRecordInMemory(track);
    }
    await _persistDeletedTrackState(saveQueue: queueChanged);
    _notify();
  }

  String _describeCloudRequestError(DioException error) {
    final path = error.requestOptions.uri.path;
    final method = error.requestOptions.method.toUpperCase();
    final stage = switch (path) {
      _ when path.endsWith('/osbeginupload') => '申请上传地址',
      _ when path.endsWith('/osendupload') => '确认上传结果',
      _ when path.endsWith('/osdownload') => '申请下载地址',
      _ when method == 'PUT' => '上传歌曲数据',
      _
          when method == 'GET' &&
              !path.endsWith('/sub_objects') &&
              !path.endsWith('/owned-doc-lib') =>
        '下载歌曲数据',
      _ => '读取云盘目录',
    };
    final status = error.response?.statusCode;
    return status == null
        ? '$stage失败：${error.message ?? '连接中断'}'
        : '$stage失败（HTTP $status）。请稍后重试；若持续失败，请提供“诊断与日志”中的同步错误。';
  }
}
