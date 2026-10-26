part of '../app_controller.dart';

extension AppControllerDownloadActions on AppController {
  Future<DownloadStartResult> startDownload(
    TrackSearchResult result, {
    bool allowNonMp3 = false,
  }) async {
    final activeSettings = settings;
    if (activeSettings == null) {
      return const DownloadStartResult.failed('应用还没有准备好。');
    }

    if (_isTrackDownloaded(result)) {
      return DownloadStartResult.failed('“${result.title}”已经下载过了。');
    }
    if (_hasActiveDownloadTask(result)) {
      return DownloadStartResult.failed('“${result.title}”已在下载队列中。');
    }
    final downloadKey = _downloadKey(result);
    if (!_preparingDownloadKeys.add(downloadKey)) {
      return DownloadStartResult.failed('“${result.title}”已在准备下载。');
    }

    preparingDownloadId = result.id;
    globalMessage = null;
    _notify();

    try {
      final requestSource = _sourceForName(result.source);
      final (detail, candidates) = await _runSourceRequest('下载', () async {
        final detail = await requestSource.loadDetail(result);
        final candidates = requestSource is DownloadMusicSource
            ? await (requestSource as DownloadMusicSource)
                  .resolveDownloadCandidates(detail)
            : await requestSource.resolveCandidates(detail);
        return (detail, candidates);
      });
      final candidate = _pickPreferredCandidate(candidates, allowNonMp3: true);
      if (candidate == null) {
        return const DownloadStartResult.failed('这个歌曲页面没有找到可下载的公开音频链接。');
      }
      if (!candidate.isMp3 && !allowNonMp3) {
        return DownloadStartResult.requiresConfirmation(candidate);
      }

      final track = TrackSearchResult(
        id: result.id,
        title: detail.title,
        artist: detail.artist,
        source: result.source,
        detailUrl: detail.sourceUrl,
        duration: result.duration,
        coverUrl: detail.coverUrl ?? result.coverUrl,
        album: detail.album,
      );
      final savePath = await _reserveDownloadSavePath(
        downloadDirectory: activeSettings.downloadDirectory,
        title: detail.title,
        artist: detail.artist,
        format: candidate.format,
      );
      final task = DownloadTask(
        id: '${result.id}-${DateTime.now().microsecondsSinceEpoch}',
        track: track,
        candidate: candidate,
        status: DownloadStatus.queued,
        progress: 0,
        savePath: savePath,
        lyrics: detail.lyrics,
        album: detail.album,
      );
      downloadTasks = [task, ...downloadTasks];
      try {
        await _saveDownloadTasks();
      } catch (_) {
        downloadTasks = [
          for (final current in downloadTasks)
            if (current.id != task.id) current,
        ];
        downloads.releasePath(savePath);
        rethrow;
      }
      // The task itself now reserves this path. Keep the temporary
      // reservation only while the task is being created and persisted.
      downloads.releasePath(savePath);
      _scheduleDownloads();
      return const DownloadStartResult.started();
    } on MusicSourceException catch (error) {
      return DownloadStartResult.failed(error.message);
    } catch (error) {
      return DownloadStartResult.failed(
        '创建下载任务失败：${_friendlyUnexpectedError(error)}',
      );
    } finally {
      _preparingDownloadKeys.remove(downloadKey);
      preparingDownloadId = null;
      _notify();
    }
  }

  String _downloadKey(TrackSearchResult result) =>
      '${result.source}\u0000${result.id}';

  Future<String> _reserveDownloadSavePath({
    required String downloadDirectory,
    required String title,
    required String artist,
    required String format,
  }) => downloads.reservePath(
    directory: downloadDirectory,
    title: title,
    artist: artist,
    format: format,
    libraryPaths: () => downloadedTracks.map((track) => track.path),
  );

  bool _isTrackDownloaded(TrackSearchResult result) {
    return downloadedTracks.any((track) => track.id == result.id);
  }

  bool _hasActiveDownloadTask(TrackSearchResult result) {
    return downloadTasks.any(
      (task) =>
          task.track.id == result.id &&
          task.track.source == result.source &&
          (task.status == DownloadStatus.queued ||
              task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.paused ||
              task.libraryPending),
    );
  }

  void pauseDownload(String taskId) => downloads.pause(taskId);

  void cancelDownload(String taskId) => downloads.cancel(taskId);

  void retryDownload(String taskId) {
    final task = downloads.taskById(taskId);
    if (task?.status == DownloadStatus.completed && task!.libraryPending) {
      unawaited(_importCompletedDownload(taskId));
    } else {
      downloads.retry(taskId);
    }
  }

  Future<T> _runSourceRequest<T>(
    String action,
    Future<T> Function() request, {
    bool Function()? shouldRun,
  }) async {
    try {
      return await _sourceRequests.run(request, shouldRun: shouldRun);
    } on ObsoleteSourceRequest {
      rethrow;
    } on MusicSourceException catch (error) {
      AppLog.instance.warning(
        'source',
        '${source.name} $action失败',
        detail: error.message,
      );
      throw MusicSourceException(
        _friendlySourceMessage(error.message, action, source.name),
      );
    } catch (error) {
      AppLog.instance.error(
        'source',
        '${source.name} $action发生异常',
        error: error,
      );
      throw MusicSourceException(
        '$action失败：${_friendlyUnexpectedError(error)}',
      );
    } finally {
      _notify();
    }
  }

  String _friendlySourceMessage(
    String message,
    String action,
    String sourceName,
  ) {
    final lower = message.toLowerCase();
    if (lower.contains('520')) {
      return '$sourceName 返回 HTTP 520，网站可能临时异常或拦截了请求。请检查网络后重试。';
    }
    if (lower.contains('403') || lower.contains('拒绝')) {
      final status = lower.contains('403') ? '（HTTP 403）' : '';
      return '$sourceName 拒绝了这次$action请求$status。如浏览器能正常访问，请检查青听与浏览器的代理设置及网络出口是否一致；也可能是网站限制了程序访问。';
    }
    if (lower.contains('429') || lower.contains('频繁')) {
      final status = lower.contains('429') ? '（HTTP 429）' : '';
      return '$sourceName 提示请求太频繁$status，请稍后重试。';
    }
    if (lower.contains('验证')) {
      return '$sourceName 要求验证后才能继续，青听不会绕过验证。请稍后重试。';
    }
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return '$action超时，请检查网络后重试。';
    }
    return message;
  }

  String _friendlyUnexpectedError(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status != null) {
        return '网络返回 HTTP $status';
      }
      return switch (error.type) {
        DioExceptionType.connectionTimeout => '连接超时',
        DioExceptionType.sendTimeout => '发送请求超时',
        DioExceptionType.receiveTimeout => '接收数据超时',
        DioExceptionType.connectionError => '网络连接失败',
        DioExceptionType.cancel => '请求已取消',
        _ => error.message ?? '网络请求失败',
      };
    }
    return error.toString();
  }

  Future<void> _restoreDownloadTasks() => downloads.restore();
  Future<void> _saveDownloadTasks() => downloads.save();
  Future<void> _persistDownloadTasksBestEffort() =>
      downloads.persistBestEffort();
  void _scheduleDownloads() => downloads.schedule();

  Future<void> _runDownload(String taskId, CancelToken token) async {
    final task = _taskById(taskId);
    if (task == null || task.status != DownloadStatus.downloading) {
      return;
    }

    _replaceTask(
      taskId,
      (task) => task.copyWith(
        status: DownloadStatus.downloading,
        progress: task.progress,
        error: null,
      ),
    );
    unawaited(_persistDownloadTasksBestEffort());
    _notify();

    try {
      var activeTask = task;
      final lyricsFuture = _lyricsForTrack(
        existingLyrics: task.lyrics,
        title: task.track.title,
        artist: task.track.artist,
        durationText: task.track.duration,
      );
      final taskSource = _sourceForName(task.track.source);
      if (taskSource is DeferredDownloadMusicSource) {
        final candidate = await (taskSource as DeferredDownloadMusicSource)
            .prepareDownloadCandidate(activeTask.candidate);
        activeTask = activeTask.copyWith(candidate: candidate);
        _replaceTask(
          taskId,
          (current) => current.copyWith(candidate: candidate),
        );
        unawaited(_persistDownloadTasksBestEffort());
      }
      final lyrics = await lyricsFuture;
      final currentTask = _taskById(taskId);
      if (_downloadShouldStop(currentTask, token)) {
        return;
      }
      final resumableTask = currentTask!;
      activeTask = resumableTask.copyWith(
        candidate: activeTask.candidate,
        lyrics: lyrics ?? resumableTask.lyrics,
      );
      _replaceTask(taskId, (_) => activeTask);

      await _transferWithFreshLink(activeTask, token);

      var completedTask = _taskById(taskId);
      if (_downloadShouldStop(completedTask, token)) {
        return;
      }
      completedTask = await _matchAlbumForDownloadTask(completedTask!);
      final latestTask = _taskById(taskId);
      if (_downloadShouldStop(latestTask, token)) {
        return;
      }
      completedTask = latestTask!.copyWith(album: completedTask.album);
      _replaceTask(taskId, (_) => completedTask!);
      await _embedMetadataIfPossible(completedTask, token);
      if (_downloadShouldStop(_taskById(taskId), token)) {
        return;
      }
      _replaceTask(
        taskId,
        (task) => task.copyWith(
          status: DownloadStatus.completed,
          progress: 1,
          libraryPending: true,
        ),
      );
      // Checkpoint the finished file before any fallible library/cache writes.
      await _persistDownloadTasksBestEffort();
      await _importCompletedDownload(taskId);
      AppLog.instance.info(
        'download',
        '下载完成',
        detail:
            '${completedTask.track.title}, bytes=${completedTask.receivedBytes}',
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        AppLog.instance.info('download', '下载连接已中止', detail: task.track.title);
        return;
      }
      final message = _downloadErrorMessage(
        error,
        sourceName: task.track.source,
      );
      _replaceTask(
        taskId,
        (task) => task.copyWith(status: DownloadStatus.failed, error: message),
      );
      await _persistDownloadTasksBestEffort();
      AppLog.instance.error(
        'download',
        '下载网络失败：${task.track.title}',
        error: error,
        stackTrace: error.stackTrace,
      );
      globalMessage = '下载失败：${task.track.title}。$message';
    } catch (error, stackTrace) {
      if (_downloadShouldStop(_taskById(taskId), token)) {
        AppLog.instance.info('download', '下载处理已中止', detail: task.track.title);
        return;
      }
      final message = '$error';
      _replaceTask(
        taskId,
        (task) => task.copyWith(status: DownloadStatus.failed, error: message),
      );
      await _persistDownloadTasksBestEffort();
      AppLog.instance.error(
        'download',
        '下载处理失败：${task.track.title}',
        error: error,
        stackTrace: stackTrace,
      );
      globalMessage = '下载失败：${task.track.title}。$message';
    } finally {
      _notify();
    }
  }

  bool isImportingDownload(String taskId) =>
      _downloadImportOperations.containsKey(taskId);

  Future<void> _importCompletedDownload(String taskId) {
    final active = _downloadImportOperations[taskId];
    if (active != null) return active;
    final task = _taskById(taskId);
    if (_isDisposed || task == null || !task.libraryPending) {
      return Future<void>.value();
    }
    late final Future<void> operation;
    operation = _runDownloadImport(task).whenComplete(() {
      _downloadImportOperations.remove(taskId);
      _notify();
    });
    _downloadImportOperations[taskId] = operation;
    _notify();
    return operation;
  }

  Future<void> _runDownloadImport(DownloadTask task) async {
    _replaceTask(task.id, (current) => current.copyWith(error: null));
    var readHeld = false;
    var needsAlbumMatch = false;
    try {
      // Import only reads the finished download. Its album writer waits for
      // the running sync, so importing a new song does not require its lock.
      readHeld = _tryBeginMetadataRead(task.savePath, completedDownload: true);
      if (!readHeld) {
        throw const FileSystemException('歌曲正在编辑或删除，请稍后重试保存。');
      }
      if (!await File(task.savePath).exists()) {
        _replaceTask(
          task.id,
          (current) => current.copyWith(
            status: DownloadStatus.failed,
            libraryPending: false,
            error: '已下载文件不存在，请重新下载。',
          ),
        );
        await _persistDownloadTasksBestEffort();
        return;
      }
      await _addDownloadedTrack(task);
      needsAlbumMatch =
          _downloadedTrackByPath(task.savePath)?.album.trim().isEmpty == true;
      _replaceTask(
        task.id,
        (current) => current.copyWith(libraryPending: false),
      );
      globalMessage = '下载完成：${task.track.title}';
    } catch (error, stackTrace) {
      const message = '音频已下载，保存到曲库失败，可重试保存。';
      _replaceTask(task.id, (current) => current.copyWith(error: message));
      globalMessage = '${task.track.title}：$message';
      AppLog.instance.error(
        'storage',
        '下载文件已保留，曲库入库待重试',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (readHeld) _endMetadataRead(task.savePath);
    }
    await _persistDownloadTasksBestEffort();
    if (needsAlbumMatch) _queueAutomaticAlbumMatch(task.savePath);
  }

  void _queueAutomaticAlbumMatch(String path) {
    final key = _trackPathKey(path);
    if (!_queuedAutomaticAlbumPaths.add(key)) return;
    _automaticAlbumMatchQueue = _automaticAlbumMatchQueue
        .then((_) async {
          await _runAutomaticAlbumWork(() async {
            await matchMissingDownloadedAlbums(onlyPaths: {path});
          });
        })
        .catchError((Object error, StackTrace stackTrace) {
          AppLog.instance.error(
            'album',
            '下载后自动匹配专辑失败',
            error: error,
            stackTrace: stackTrace,
          );
        })
        .whenComplete(() => _queuedAutomaticAlbumPaths.remove(key));
  }

  Future<void> _runAutomaticAlbumWork(Future<void> Function() action) async {
    // Queued work waits for sync; sync waits only for work already active.
    while (!_isDisposed && !_preparingToExit) {
      final runningSync = _cloudSyncOperation;
      if (runningSync != null) {
        await runningSync;
        continue;
      }
      final active = _albumMatchCompletion;
      if (active != null) {
        await active;
        continue;
      }
      break;
    }
    if (_isDisposed || _preparingToExit) return;
    final completion = Completer<void>();
    _activeAutomaticAlbumMatch = completion.future;
    try {
      await action();
    } finally {
      _activeAutomaticAlbumMatch = null;
      completion.complete();
    }
  }

  Future<void> _transferWithFreshLink(
    DownloadTask task,
    CancelToken token,
  ) async {
    try {
      await downloads.transfer(task, token);
      return;
    } catch (error) {
      if (token.isCancelled) rethrow;
      final rejected =
          error is DioException &&
          const {401, 403, 404, 410}.contains(error.response?.statusCode);
      if (!rejected && error is! InvalidAudioResponse) rethrow;
      if (_downloadShouldStop(_taskById(task.id), token)) return;
      final source = _sourceForName(task.track.source);
      final AudioCandidate? candidate;
      if (source is RefreshableDownloadMusicSource) {
        candidate = await _runSourceRequest(
          '刷新下载链接',
          () => (source as RefreshableDownloadMusicSource)
              .refreshDownloadCandidate(task.track, task.candidate),
          shouldRun: () => !_downloadShouldStop(_taskById(task.id), token),
        );
      } else {
        candidate = await _runSourceRequest('刷新下载链接', () async {
          final detail = await source.loadDetail(task.track);
          final candidates = source is DownloadMusicSource
              ? await (source as DownloadMusicSource).resolveDownloadCandidates(
                  detail,
                )
              : await source.resolveCandidates(detail);
          var selected = candidates
              .where(
                (value) =>
                    value.format.toLowerCase() ==
                    task.candidate.format.toLowerCase(),
              )
              .firstOrNull;
          if (selected != null && source is DeferredDownloadMusicSource) {
            selected = await (source as DeferredDownloadMusicSource)
                .prepareDownloadCandidate(selected);
          }
          return selected;
        }, shouldRun: () => !_downloadShouldStop(_taskById(task.id), token));
      }
      if (_downloadShouldStop(_taskById(task.id), token)) return;
      if (candidate == null ||
          candidate.format.toLowerCase() !=
              task.candidate.format.toLowerCase()) {
        throw const MusicSourceException('刷新后没有相同格式的音频，请重新创建下载任务。');
      }
      // Without a validator, bytes from different URLs cannot safely be joined.
      if (candidate.url != task.candidate.url &&
          (task.resumeValidator?.isEmpty ?? true)) {
        final file = File(task.savePath);
        if (await file.exists()) await file.delete();
      }
      _replaceTask(
        task.id,
        (current) => current.copyWith(candidate: candidate),
      );
      await _persistDownloadTasksBestEffort();
      if (_downloadShouldStop(_taskById(task.id), token)) return;
      // Exactly one fresh resolution per attempt; repeated rejection remains visible.
      await downloads.transfer(_taskById(task.id)!, token);
    }
  }

  MusicSource _sourceForName(String sourceName) {
    for (final item in sources) {
      if (item.name == sourceName) {
        return item;
      }
    }
    return source;
  }

  Future<String?> _lyricsForTrack({
    required String? existingLyrics,
    required String title,
    required String artist,
    required String? durationText,
  }) async {
    final existing = existingLyrics?.trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    return lyricsService.findLyrics(
      title: title,
      artist: artist,
      duration: _parseTrackDuration(durationText),
    );
  }

  Duration? _parseTrackDuration(String? value) {
    final parts = value
        ?.trim()
        .split(':')
        .map(int.tryParse)
        .toList(growable: false);
    if (parts == null ||
        parts.isEmpty ||
        parts.any((part) => part == null) ||
        parts.length > 3) {
      return null;
    }
    var seconds = 0;
    for (final part in parts) {
      seconds = seconds * 60 + part!;
    }
    return Duration(seconds: seconds);
  }

  Future<DownloadTask> _matchAlbumForDownloadTask(DownloadTask task) async {
    final existingAlbum = task.album.trim();
    try {
      final match = await albumMetadata.findBestAlbum(
        title: task.track.title,
        artist: task.track.artist,
        lyrics: task.lyrics,
        duration: _parseTrackDuration(task.track.duration),
      );
      final album = match?.album.trim();
      if (album == null || album.isEmpty) {
        return task.copyWith(album: existingAlbum);
      }
      return task.copyWith(album: album);
    } catch (_) {
      return task.copyWith(album: existingAlbum);
    }
  }

  bool _downloadShouldStop(DownloadTask? task, CancelToken token) {
    return token.isCancelled || task?.status != DownloadStatus.downloading;
  }

  Future<void> _embedMetadataIfPossible(
    DownloadTask task,
    CancelToken token,
  ) async {
    final lyrics = task.lyrics?.trim();
    if (!task.candidate.isMp3) {
      return;
    }

    final cover = await _downloadCoverImage(
      task.track.coverUrl,
      referer: task.track.detailUrl,
      cancelToken: token,
    );
    if (_downloadShouldStop(_taskById(task.id), token)) {
      return;
    }

    try {
      await Id3LyricsEmbedder.embedMetadata(
        File(task.savePath),
        lyrics: lyrics,
        title: task.track.title,
        artist: task.track.artist,
        album: task.album,
        cover: cover,
      );
    } catch (error) {
      throw Exception('歌曲信息写入歌曲文件失败：$error');
    }
  }

  Future<Id3CoverImage?> _downloadCoverImage(
    String? coverUrl, {
    required String referer,
    CancelToken? cancelToken,
  }) => _artwork.download(coverUrl, referer: referer, cancelToken: cancelToken);
  Future<Id3CoverImage?> _loadCoverFromManualInput(String input) =>
      _artwork.loadManual(input);

  String _downloadErrorMessage(
    DioException error, {
    required String sourceName,
  }) {
    final status = error.response?.statusCode;
    if (status == 403) {
      return '下载链接被拒绝访问。可能是 $sourceName 临时拦截、下载地址过期，或该资源不允许公开下载。';
    }
    if (status == 404) {
      return '下载链接不存在或已经失效。请重新搜索后再试。';
    }
    if (status == 429 || status == 520) {
      return '$sourceName 返回 HTTP $status，可能是请求太频繁或网站临时异常。请稍后重试。';
    }
    if (status != null) {
      return '下载失败：HTTP $status。';
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout => '下载失败：连接超时。',
      DioExceptionType.receiveTimeout => '下载失败：接收数据超时。',
      DioExceptionType.connectionError => '下载失败：网络连接异常。',
      DioExceptionType.cancel => '下载已取消。',
      _ => '下载失败：${error.message ?? error.type.name}',
    };
  }

  AudioCandidate? _pickPreferredCandidate(
    List<AudioCandidate> candidates, {
    required bool allowNonMp3,
  }) {
    if (candidates.isEmpty) {
      return null;
    }
    for (final candidate in candidates) {
      if (candidate.isMp3) {
        return candidate;
      }
    }
    return allowNonMp3 ? candidates.first : null;
  }

  DownloadTask? _taskById(String taskId) => downloads.taskById(taskId);
  void _replaceTask(
    String taskId,
    DownloadTask Function(DownloadTask) update,
  ) => downloads.update(taskId, update);

  int _compareText(String left, String right) {
    return left.toLowerCase().compareTo(right.toLowerCase());
  }

  String _trackPathKey(String value) {
    final normalized = p.normalize(value.trim());
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _normalizeManualDownloadPath(String value) {
    return value
        .trim()
        .replaceAll('\\', Platform.pathSeparator)
        .replaceFirstMapped(
          RegExp(r'[，,]+([/\\])?$'),
          (match) => match.group(1) ?? '',
        )
        .trim();
  }

  void _debouncedSaveSettings() {
    if (settings != null) _settingsPersistence.schedule();
  }

  Future<void> _flushPendingSettings() => _settingsPersistence.flush();
}
