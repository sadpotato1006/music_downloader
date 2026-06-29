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
      final detail = await _runSourceRequest(
        '下载',
        () => requestSource.loadDetail(result),
      );
      final candidates = requestSource is DownloadMusicSource
          ? await (requestSource as DownloadMusicSource)
                .resolveDownloadCandidates(detail)
          : await requestSource.resolveCandidates(detail);
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
      final savePath = await storage.uniqueSavePath(
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
      await _saveDownloadTasks();
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
              task.status == DownloadStatus.paused),
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
    _replaceTask(
      taskId,
      (task) => task.copyWith(status: DownloadStatus.canceled),
    );
    _cancelTokens[taskId]?.cancel('canceled');
    if (task != null) {
      AppLog.instance.info('download', '下载已取消', detail: task.track.title);
      unawaited(_deletePartialFile(task.savePath));
    }
    unawaited(_persistDownloadTasksBestEffort());
    _notify();
    _scheduleDownloads();
  }

  void retryDownload(String taskId) {
    final current = _taskById(taskId);
    _replaceTask(
      taskId,
      (task) => task.copyWith(status: DownloadStatus.queued, error: null),
    );
    unawaited(_persistDownloadTasksBestEffort());
    if (current != null) {
      AppLog.instance.info('download', '下载重新进入队列', detail: current.track.title);
    }
    _notify();
    _scheduleDownloads();
  }

  Future<T> _runSourceRequest<T>(
    String action,
    Future<T> Function() request,
  ) async {
    final previous = _sourceRequestQueue;
    final completer = Completer<void>();
    _sourceRequestQueue = previous.whenComplete(() => completer.future);
    await previous;

    try {
      _throwIfSourceCoolingDown();
      await _waitForSourceGap();
      final result = await request();
      _lastSourceRequestAt = DateTime.now();
      _clearExpiredCooldown();
      return result;
    } on MusicSourceException catch (error) {
      _activateCooldownIfNeeded(error.message);
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

  void _throwIfSourceCoolingDown() {
    final remaining = sourceCooldownRemaining;
    if (remaining <= Duration.zero) {
      _clearExpiredCooldown();
      return;
    }
    throw MusicSourceException(
      '${sourceCooldownReason ?? '请求太频繁'}，青听已暂停访问 ${source.name} ${_formatCooldown(remaining)}。',
    );
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

  void _activateCooldownIfNeeded(String message) {
    final lower = message.toLowerCase();
    Duration? cooldown;
    String? reason;
    if (lower.contains('520') ||
        lower.contains('521') ||
        lower.contains('522') ||
        lower.contains('523') ||
        lower.contains('524')) {
      cooldown = AppController._cooldown520;
      reason = '${source.name} 临时拦截或异常返回';
    } else if (lower.contains('429') || lower.contains('频繁')) {
      cooldown = AppController._cooldown429;
      reason = '请求太频繁';
    } else if (lower.contains('403') ||
        lower.contains('拒绝') ||
        lower.contains('验证')) {
      cooldown = AppController._cooldown403;
      reason = '${source.name} 拒绝访问';
    }
    if (cooldown == null) {
      return;
    }
    sourceCooldownUntil = DateTime.now().add(cooldown);
    sourceCooldownReason = reason;
  }

  void _clearExpiredCooldown() {
    if (sourceCooldownUntil == null ||
        sourceCooldownUntil!.isAfter(DateTime.now())) {
      return;
    }
    sourceCooldownUntil = null;
    sourceCooldownReason = null;
  }

  String _friendlySourceMessage(
    String message,
    String action,
    String sourceName,
  ) {
    final lower = message.toLowerCase();
    if (lower.contains('520')) {
      return '$sourceName 返回 HTTP 520，通常是短时间请求太多或被网站临时拦截。青听已自动冷却几分钟，稍后再试。';
    }
    if (lower.contains('403') || lower.contains('拒绝')) {
      return '$sourceName 拒绝了这次$action请求。可能是访问太频繁、链接过期，或该页面不允许程序读取。';
    }
    if (lower.contains('429') || lower.contains('频繁')) {
      return '请求太频繁，青听已暂停访问 $sourceName 一会儿，稍后再试。';
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

  String _formatCooldown(Duration duration) {
    final totalSeconds = duration.inSeconds <= 0 ? 1 : duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (minutes <= 0) {
      return '$seconds 秒';
    }
    return '$minutes 分 $seconds 秒';
  }

  Future<void> _restoreDownloadTasks() async {
    if (downloadTasks.isEmpty) {
      return;
    }
    var changed = false;
    final restored = <DownloadTask>[];
    for (final task in downloadTasks) {
      if (task.status == DownloadStatus.completed ||
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
            task.status != DownloadStatus.completed &&
            task.status != DownloadStatus.canceled,
      ),
    );
    final previousSave = _downloadTasksSaveQueue;
    final operation = () async {
      try {
        await previousSave;
      } catch (_) {
        // A failed save must not prevent newer task state from persisting.
      }
      await storage.saveDownloadTasks(snapshot);
    }();
    _downloadTasksSaveQueue = operation;
    return operation;
  }

  Future<void> _persistDownloadTasksBestEffort() async {
    try {
      await _saveDownloadTasks();
    } catch (_) {
      // The current transfer can continue; a later state change will retry.
    }
  }

  void _scheduleDownloads() {
    final limit = settings?.concurrentDownloads ?? 1;
    while (_activeDownloads < limit) {
      DownloadTask? next;
      for (final task in downloadTasks) {
        if (task.status == DownloadStatus.queued) {
          next = task;
          break;
        }
      }
      if (next == null) {
        break;
      }
      _replaceTask(
        next.id,
        (task) => task.copyWith(status: DownloadStatus.downloading),
      );
      _activeDownloads += 1;
      unawaited(
        _runDownload(next.id).whenComplete(() {
          if (_activeDownloads > 0) {
            _activeDownloads -= 1;
          }
          _scheduleDownloads();
        }),
      );
    }
  }

  Future<void> _runDownload(String taskId) async {
    final task = _taskById(taskId);
    if (task == null || task.status == DownloadStatus.canceled) {
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
      if (currentTask == null ||
          currentTask.status == DownloadStatus.canceled ||
          currentTask.status == DownloadStatus.paused) {
        return;
      }
      activeTask = currentTask.copyWith(
        candidate: activeTask.candidate,
        lyrics: lyrics ?? currentTask.lyrics,
      );
      _replaceTask(taskId, (_) => activeTask);

      await _downloadTaskFile(activeTask, token);

      var completedTask = _taskById(taskId);
      if (completedTask == null ||
          completedTask.status == DownloadStatus.canceled) {
        return;
      }
      completedTask = await _matchAlbumForDownloadTask(completedTask);
      final latestTask = _taskById(taskId);
      if (latestTask == null || latestTask.status == DownloadStatus.canceled) {
        return;
      }
      completedTask = latestTask.copyWith(album: completedTask.album);
      _replaceTask(taskId, (_) => completedTask!);
      await _embedMetadataIfPossible(completedTask);
      _replaceTask(
        taskId,
        (task) => task.copyWith(status: DownloadStatus.completed, progress: 1),
      );
      await _addDownloadedTrack(completedTask);
      await _saveDownloadTasks();
      AppLog.instance.info(
        'download',
        '下载完成',
        detail:
            '${completedTask.track.title}, bytes=${completedTask.receivedBytes}',
      );
      globalMessage = '下载完成：${completedTask.track.title}';
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
      _cancelTokens.remove(taskId);
      _lastDownloadProgressUpdateMillis.remove(taskId);
      if (!_isDisposed) {
        _notify();
      }
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
    if (status == 416) {
      await body.stream.drain();
      if (existingBytes > 0 &&
          rangeTotal != null &&
          existingBytes >= rangeTotal) {
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
    final validator =
        response.headers.value(HttpHeaders.etagHeader) ??
        response.headers.value(HttpHeaders.lastModifiedHeader) ??
        '';
    _replaceTask(
      task.id,
      (current) => current.copyWith(
        receivedBytes: baseBytes,
        totalBytes: totalBytes,
        progress: totalBytes != null && totalBytes > 0
            ? baseBytes / totalBytes
            : current.progress,
        resumeValidator: validator,
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

  Future<void> _embedMetadataIfPossible(DownloadTask task) async {
    final lyrics = task.lyrics?.trim();
    if (!task.candidate.isMp3) {
      return;
    }

    final cover = await _downloadCoverImage(
      task.track.coverUrl,
      referer: task.track.detailUrl,
    );

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
  }) async {
    if (coverUrl == null || coverUrl.trim().isEmpty) {
      return null;
    }

    Response<List<int>>? response;
    for (final headers in [
      {
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        'Referer': referer,
        'User-Agent': 'QingTing/1.3.3 (+personal-use)',
      },
      {
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        'User-Agent': 'QingTing/1.3.3 (+personal-use)',
      },
    ]) {
      try {
        response = await _downloadDio.get<List<int>>(
          coverUrl,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(seconds: 12),
            headers: headers,
          ),
        );
        break;
      } catch (_) {
        response = null;
      }
    }

    try {
      if (response == null) {
        return null;
      }
      final status = response.statusCode ?? 0;
      final bytes = response.data;
      if (status >= 400 || bytes == null || bytes.isEmpty) {
        return null;
      }
      if (bytes.length > 5 * 1024 * 1024) {
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
      return Id3CoverImage(
        mimeType: mimeType,
        bytes: Uint8List.fromList(bytes),
      );
    } catch (_) {
      return null;
    }
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
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
        return null;
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
      if (sourceName == source.name) {
        _activateCooldownIfNeeded('HTTP $status');
      }
      return '$sourceName 返回 HTTP $status，可能是请求太频繁。青听已自动冷却，稍后再试。';
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
    _settingsSaveDebounce?.cancel();
    _settingsSaveDebounce = Timer(const Duration(milliseconds: 350), () {
      final latest = settings;
      if (latest != null) {
        unawaited(storage.saveSettings(latest));
      }
    });
  }
}
