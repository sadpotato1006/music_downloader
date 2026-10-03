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
        _reservedDownloadSavePaths.remove(savePath);
        rethrow;
      }
      // The task itself now reserves this path. Keep the temporary
      // reservation only while the task is being created and persisted.
      _reservedDownloadSavePaths.remove(savePath);
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
  }) async {
    final previous = _downloadPathReservationQueue;
    final completer = Completer<void>();
    _downloadPathReservationQueue = previous.whenComplete(
      () => completer.future,
    );
    await previous;

    try {
      final savePath = await storage.uniqueSavePath(
        downloadDirectory: downloadDirectory,
        title: title,
        artist: artist,
        format: format,
        reservedPaths: [
          ..._reservedDownloadSavePaths,
          for (final task in downloadTasks) task.savePath,
          for (final track in downloadedTracks) track.path,
        ],
      );
      _reservedDownloadSavePaths.add(savePath);
      return savePath;
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

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

  void pauseDownload(String taskId) {
    final current = _taskById(taskId);
    if (current == null ||
        current.status == DownloadStatus.completed ||
        current.status == DownloadStatus.canceled) {
      return;
    }
    _replaceTask(
      taskId,
      (task) => task.copyWith(status: DownloadStatus.paused),
    );
    _cancelTokens[taskId]?.cancel('paused');
    AppLog.instance.info('download', '下载已暂停', detail: current.track.title);
    unawaited(_persistDownloadTasksBestEffort());
    _notify();
  }

  void cancelDownload(String taskId) {
    final task = _taskById(taskId);
    if (task == null ||
        task.status == DownloadStatus.completed ||
        task.status == DownloadStatus.canceled) {
      return;
    }
    _replaceTask(
      taskId,
      (task) => task.copyWith(status: DownloadStatus.canceled),
    );
    _cancelTokens[taskId]?.cancel('canceled');
    AppLog.instance.info('download', '下载已取消', detail: task.track.title);
    if (!_runningDownloadIds.contains(taskId)) {
      _scheduleCanceledDownloadCleanup(task);
    }
    unawaited(_persistDownloadTasksBestEffort());
    _notify();
    _scheduleDownloads();
  }

  void retryDownload(String taskId) {
    final current = _taskById(taskId);
    if (current?.status == DownloadStatus.completed &&
        current!.libraryPending) {
      unawaited(_importCompletedDownload(taskId));
      return;
    }
    if (current == null ||
        current.status == DownloadStatus.queued ||
        current.status == DownloadStatus.downloading ||
        current.status == DownloadStatus.completed) {
      return;
    }
    _replaceTask(
      taskId,
      (task) => task.copyWith(status: DownloadStatus.queued, error: null),
    );
    unawaited(_persistDownloadTasksBestEffort());
    AppLog.instance.info('download', '下载重新进入队列', detail: current.track.title);
    _notify();
    _scheduleDownloads();
  }

  Future<T> _runSourceRequest<T>(
    String action,
    Future<T> Function() request, {
    bool Function()? shouldRun,
  }) async {
    final previous = _sourceRequestQueue;
    final completer = Completer<void>();
    _sourceRequestQueue = previous.whenComplete(() => completer.future);
    await previous;

    try {
      if (shouldRun != null && !shouldRun()) {
        throw const _ObsoleteSourceRequest();
      }
      await _waitForSourceGap();
      // A newer search can arrive while this request waits for the rate limit.
      if (shouldRun != null && !shouldRun()) {
        throw const _ObsoleteSourceRequest();
      }
      final result = await request();
      _lastSourceRequestAt = DateTime.now();
      return result;
    } on _ObsoleteSourceRequest {
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
      if (!completer.isCompleted) {
        completer.complete();
      }
      _notify();
    }
  }

  Future<void> _waitForSourceGap() async {
    final last = _lastSourceRequestAt;
    if (last == null) {
      return;
    }
    final elapsed = DateTime.now().difference(last);
    if (elapsed < AppController._sourceRequestGap) {
      await Future<void>.delayed(AppController._sourceRequestGap - elapsed);
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

  Future<void> _restoreDownloadTasks() async {
    if (downloadTasks.isEmpty) {
      return;
    }
    var changed = false;
    final restored = <DownloadTask>[];
    for (final task in downloadTasks) {
      if ((task.status == DownloadStatus.completed && !task.libraryPending) ||
          task.status == DownloadStatus.canceled) {
        changed = true;
      }
      final file = File(task.savePath);
      final exists = await file.exists();
      final receivedBytes = exists ? await file.length() : 0;
      var status = task.status;
      var error = task.error;
      if (status == DownloadStatus.downloading) {
        status = DownloadStatus.paused;
        changed = true;
      } else if (status == DownloadStatus.completed && !exists) {
        status = DownloadStatus.failed;
        error = '已下载文件不存在，请重新下载。';
        changed = true;
      }
      final totalBytes = task.totalBytes;
      final progress = status == DownloadStatus.completed && exists
          ? 1.0
          : totalBytes != null && totalBytes > 0
          ? (receivedBytes / totalBytes).clamp(0, 1).toDouble()
          : receivedBytes > 0
          ? task.progress
          : 0.0;
      if (receivedBytes != task.receivedBytes || progress != task.progress) {
        changed = true;
      }
      restored.add(
        task.copyWith(
          status: status,
          progress: progress,
          error: error,
          receivedBytes: receivedBytes,
          libraryPending: task.libraryPending && exists,
        ),
      );
    }
    downloadTasks = restored;
    if (changed) {
      await _saveDownloadTasks();
    }
  }

  Future<void> _saveDownloadTasks() {
    final snapshot = List<DownloadTask>.unmodifiable(
      downloadTasks.where(
        (task) =>
            (task.status != DownloadStatus.completed || task.libraryPending) &&
            task.status != DownloadStatus.canceled,
      ),
    );
    return _downloadTasksSaveQueue.enqueue(
      () => storage.saveDownloadTasks(snapshot),
    );
  }

  Future<void> _persistDownloadTasksBestEffort() async {
    try {
      await _saveDownloadTasks();
    } catch (error, stackTrace) {
      // The current transfer can continue; a later state change will retry.
      AppLog.instance.warning(
        'storage',
        '保存下载任务失败',
        detail: '$error\n$stackTrace',
      );
    }
  }

  void _scheduleDownloads() {
    if (_isDisposed || _preparingToExit) {
      return;
    }
    final limit = settings?.concurrentDownloads ?? 1;
    while (_activeDownloads < limit) {
      DownloadTask? next;
      for (final task in downloadTasks) {
        if (task.status == DownloadStatus.queued &&
            !_runningDownloadIds.contains(task.id) &&
            !_pendingDownloadCleanupIds.contains(task.id)) {
          next = task;
          break;
        }
      }
      if (next == null) {
        break;
      }
      final taskId = next.id;
      _replaceTask(
        taskId,
        (task) => task.copyWith(status: DownloadStatus.downloading),
      );
      _runningDownloadIds.add(taskId);
      _activeDownloads += 1;
      unawaited(
        _runDownload(taskId).whenComplete(() {
          if (_runningDownloadIds.remove(taskId) && _activeDownloads > 0) {
            _activeDownloads -= 1;
          }
          _scheduleDownloads();
        }),
      );
    }
  }

  Future<void> _runDownload(String taskId) async {
    final task = _taskById(taskId);
    if (task == null || task.status != DownloadStatus.downloading) {
      return;
    }

    final token = CancelToken();
    _cancelTokens[taskId] = token;
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

      await _downloadTaskFile(activeTask, token);

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
      if (identical(_cancelTokens[taskId], token)) {
        _cancelTokens.remove(taskId);
      }
      if (_taskById(taskId)?.status == DownloadStatus.canceled) {
        await _cleanupCanceledDownloadFile(task);
      }
      _lastDownloadProgressUpdateMillis.remove(taskId);
      if (!_isDisposed) {
        _notify();
      }
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

  Future<void> _downloadTaskFile(
    DownloadTask task,
    CancelToken token, {
    bool allowResume = true,
  }) async {
    final file = File(task.savePath);
    await file.parent.create(recursive: true);
    final existingBytes = allowResume && await file.exists()
        ? await file.length()
        : 0;
    final headers = <String, dynamic>{...task.candidate.headers}
      ..removeWhere(
        (key, _) =>
            key.toLowerCase() == HttpHeaders.rangeHeader ||
            key.toLowerCase() == HttpHeaders.ifRangeHeader,
      );
    if (existingBytes > 0) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$existingBytes-';
      final validator = task.resumeValidator?.trim();
      if (validator != null && validator.isNotEmpty) {
        headers[HttpHeaders.ifRangeHeader] = validator;
      }
    }

    final response = await _downloadDio.getUri<ResponseBody>(
      Uri.parse(task.candidate.url),
      cancelToken: token,
      options: Options(
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (status) =>
            status != null &&
            ((status >= 200 && status < 300) || status == 416),
      ),
    );
    final body = response.data;
    if (body == null) {
      throw const FileSystemException('下载响应没有可写入的数据。');
    }

    final status = response.statusCode ?? 0;
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final rangeTotal = _contentRangeTotal(contentRange);
    final responseValidator = _resumeValidator(response.headers);
    if (status == 416) {
      await body.stream.drain();
      if (existingBytes > 0 &&
          rangeTotal != null &&
          existingBytes == rangeTotal) {
        AppLog.instance.info(
          'download',
          '服务器确认本地断点文件已完整',
          detail: 'bytes=$existingBytes',
        );
        _updateDownloadProgress(task.id, rangeTotal, rangeTotal, force: true);
        return;
      }
      if (allowResume) {
        AppLog.instance.warning(
          'download',
          '断点位置失效，回退为完整下载',
          detail: 'status=416, bytes=$existingBytes',
        );
        if (await file.exists()) {
          await file.delete();
        }
        await _downloadTaskFile(task, token, allowResume: false);
        return;
      }
      throw const FileSystemException('服务器拒绝了断点续传请求。');
    }

    if (status == 206 &&
        existingBytes > 0 &&
        _contentRangeStart(contentRange) != existingBytes) {
      await body.stream.drain();
      if (await file.exists()) {
        await file.delete();
      }
      if (allowResume) {
        AppLog.instance.warning(
          'download',
          '服务器返回无效断点，回退为完整下载',
          detail: 'expected=$existingBytes, contentRange=$contentRange',
        );
        await _downloadTaskFile(task, token, allowResume: false);
        return;
      }
      throw const FileSystemException('服务器返回了无效的断点位置。');
    }

    final requestedValidator = task.resumeValidator?.trim();
    if (status == 206 &&
        existingBytes > 0 &&
        requestedValidator != null &&
        requestedValidator.isNotEmpty &&
        responseValidator.isNotEmpty &&
        responseValidator != requestedValidator) {
      await body.stream.drain();
      if (await file.exists()) {
        await file.delete();
      }
      if (allowResume) {
        AppLog.instance.warning(
          'download',
          '断点文件版本已变化，回退为完整下载',
          detail: 'expected=$requestedValidator, actual=$responseValidator',
        );
        await _downloadTaskFile(task, token, allowResume: false);
        return;
      }
      throw const FileSystemException('服务器返回了不同版本的断点文件。');
    }

    final isPartialResponse = status == 206 && existingBytes > 0;
    if (isPartialResponse) {
      AppLog.instance.info(
        'download',
        '服务器接受断点续传',
        detail: 'offset=$existingBytes',
      );
    } else if (existingBytes > 0) {
      AppLog.instance.warning(
        'download',
        '服务器忽略 Range，已安全覆盖重新下载',
        detail: 'status=$status, previousBytes=$existingBytes',
      );
    }
    final baseBytes = isPartialResponse ? existingBytes : 0;
    final responseLength = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    final totalBytes =
        rangeTotal ??
        (responseLength == null ? null : baseBytes + responseLength);
    _replaceTask(
      task.id,
      (current) => current.copyWith(
        receivedBytes: baseBytes,
        totalBytes: totalBytes,
        progress: totalBytes != null && totalBytes > 0
            ? baseBytes / totalBytes
            : current.progress,
        resumeValidator: responseValidator,
      ),
    );
    unawaited(_persistDownloadTasksBestEffort());

    final output = await file.open(
      mode: isPartialResponse ? FileMode.append : FileMode.write,
    );
    var receivedBytes = baseBytes;
    try {
      await for (final chunk in body.stream) {
        if (token.isCancelled) {
          throw token.cancelError!;
        }
        await output.writeFrom(chunk);
        receivedBytes += chunk.length;
        _updateDownloadProgress(task.id, receivedBytes, totalBytes);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (totalBytes != null && receivedBytes != totalBytes) {
      if (receivedBytes > totalBytes && await file.exists()) {
        await file.delete();
      }
      throw FileSystemException(
        receivedBytes < totalBytes
            ? '下载响应提前结束：应接收 $totalBytes 字节，实际收到 $receivedBytes 字节。'
            : '下载响应超过声明长度：应接收 $totalBytes 字节，实际收到 $receivedBytes 字节。',
        task.savePath,
      );
    }
    _updateDownloadProgress(
      task.id,
      receivedBytes,
      totalBytes ?? receivedBytes,
      force: true,
    );
  }

  void _updateDownloadProgress(
    String taskId,
    int received,
    int? total, {
    bool force = false,
  }) {
    if (_isDisposed) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastUpdate = _lastDownloadProgressUpdateMillis[taskId];
    final isComplete = total != null && total > 0 && received >= total;
    if (!force &&
        !isComplete &&
        lastUpdate != null &&
        now - lastUpdate <
            AppController._downloadProgressUpdateInterval.inMilliseconds) {
      return;
    }
    _lastDownloadProgressUpdateMillis[taskId] = now;
    _replaceTask(
      taskId,
      (task) => task.copyWith(
        progress: total != null && total > 0
            ? (received / total).clamp(0, 1).toDouble()
            : task.progress,
        receivedBytes: received,
        totalBytes: total != null && total > 0 ? total : null,
      ),
    );
    _downloadProgressListenable.value += 1;
  }

  int? _contentRangeTotal(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(r'/(\d+)$').firstMatch(value.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  int? _contentRangeStart(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(
      r'^bytes\s+(\d+)-',
      caseSensitive: false,
    ).firstMatch(value.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  String _resumeValidator(Headers headers) {
    return (headers.value(HttpHeaders.etagHeader) ??
            headers.value(HttpHeaders.lastModifiedHeader) ??
            '')
        .trim();
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
  }) async {
    if (coverUrl == null || coverUrl.trim().isEmpty) {
      return null;
    }

    for (final headers in [
      {
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        'Referer': referer,
        'User-Agent': appUserAgent,
      },
      {
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        'User-Agent': appUserAgent,
      },
    ]) {
      final coverRequestToken = CancelToken();
      final activeDownloadToken = cancelToken;
      if (activeDownloadToken != null) {
        if (activeDownloadToken.isCancelled) {
          coverRequestToken.cancel(activeDownloadToken.cancelError);
        } else {
          unawaited(
            activeDownloadToken.whenCancel.then((error) {
              if (!coverRequestToken.isCancelled) {
                coverRequestToken.cancel(error);
              }
            }),
          );
        }
      }
      try {
        final response = await _downloadDio.getUri<ResponseBody>(
          Uri.parse(coverUrl),
          cancelToken: coverRequestToken,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: const Duration(seconds: 12),
            headers: headers,
          ),
        );
        final status = response.statusCode ?? 0;
        final body = response.data;
        if (status >= 400 || body == null) {
          return null;
        }
        final bytes = await _readResponseBytes(
          body,
          maxBytes: AppController._maxEmbeddedCoverBytes,
          advertisedLength: int.tryParse(
            response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
          ),
          requestToken: coverRequestToken,
        );
        if (bytes == null || bytes.isEmpty) {
          return null;
        }
        final mimeType = _coverMimeType(
          bytes,
          contentType: response.headers.value(Headers.contentTypeHeader),
          url: coverUrl,
        );
        if (mimeType == null) {
          return null;
        }
        return Id3CoverImage(mimeType: mimeType, bytes: bytes);
      } on DioException catch (error) {
        if (activeDownloadToken?.isCancelled ?? false) {
          rethrow;
        }
        if (CancelToken.isCancel(error) && coverRequestToken.isCancelled) {
          return null;
        }
      } catch (_) {
        // Retry once without the Referer header below.
      }
    }
    return null;
  }

  Future<Uint8List?> _readResponseBytes(
    ResponseBody body, {
    required int maxBytes,
    required int? advertisedLength,
    required CancelToken requestToken,
  }) async {
    if (advertisedLength != null && advertisedLength > maxBytes) {
      final subscription = body.stream.listen(null, onError: (_) {});
      requestToken.cancel('cover response exceeds $maxBytes bytes');
      await subscription.cancel();
      return null;
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (builder.length + chunk.length > maxBytes) {
        requestToken.cancel('cover response exceeds $maxBytes bytes');
        return null;
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<Id3CoverImage?> _loadCoverFromManualInput(String input) async {
    final uri = Uri.tryParse(input);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
      return _downloadCoverImage(input, referer: 'https://www.gequbao.com/');
    }

    try {
      final file = File(input);
      if (!await file.exists()) {
        return null;
      }
      final coverFile = await file.open();
      late final Uint8List bytes;
      try {
        final length = await coverFile.length();
        if (length == 0 || length > AppController._maxEmbeddedCoverBytes) {
          return null;
        }
        // Bound the read as well as checking length, including growing files.
        bytes = await coverFile.read(AppController._maxEmbeddedCoverBytes + 1);
        if (bytes.isEmpty ||
            bytes.length > AppController._maxEmbeddedCoverBytes) {
          return null;
        }
      } finally {
        await coverFile.close();
      }
      final mimeType = _coverMimeType(bytes, contentType: null, url: input);
      if (mimeType == null) {
        return null;
      }
      return Id3CoverImage(
        mimeType: mimeType,
        bytes: Uint8List.fromList(bytes),
      );
    } catch (_) {
      return null;
    }
  }

  String? _coverMimeType(
    List<int> bytes, {
    required String? contentType,
    required String url,
  }) {
    final normalizedContentType = contentType
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (normalizedContentType == 'image/jpeg' ||
        normalizedContentType == 'image/png' ||
        normalizedContentType == 'image/webp') {
      return normalizedContentType;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }

    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (path.endsWith('.png')) {
      return 'image/png';
    }
    if (path.endsWith('.webp')) {
      return 'image/webp';
    }
    return null;
  }

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

  DownloadTask? _taskById(String taskId) {
    for (final task in downloadTasks) {
      if (task.id == taskId) {
        return task;
      }
    }
    return null;
  }

  void _replaceTask(String taskId, DownloadTask Function(DownloadTask) update) {
    downloadTasks = [
      for (final task in downloadTasks) task.id == taskId ? update(task) : task,
    ];
  }

  Future<void> _deletePartialFile(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  void _scheduleCanceledDownloadCleanup(DownloadTask task) {
    if (!_pendingDownloadCleanupIds.add(task.id)) {
      return;
    }
    unawaited(
      _cleanupCanceledDownloadFile(task).whenComplete(() {
        _pendingDownloadCleanupIds.remove(task.id);
        if (!_isDisposed) {
          _scheduleDownloads();
          _notify();
        }
      }),
    );
  }

  Future<void> _cleanupCanceledDownloadFile(DownloadTask task) async {
    try {
      await _deletePartialFile(task.savePath);
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'download',
        '清理已取消的下载文件失败：${task.track.title}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

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
    if (settings == null) {
      return;
    }
    _settingsSavePending = true;
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_flushPendingSettings());
    });
  }

  Future<void> _flushPendingSettings() async {
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = null;
    if (!_settingsSavePending) {
      return;
    }
    final latest = settings;
    if (latest == null) {
      return;
    }
    _settingsSavePending = false;
    try {
      await storage.saveSettings(latest);
    } catch (_) {
      _settingsSavePending = true;
      rethrow;
    }
  }
}

class _ObsoleteSourceRequest implements Exception {
  const _ObsoleteSourceRequest();
}
