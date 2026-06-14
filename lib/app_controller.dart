import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';

import 'android_storage_access.dart';
import 'id3_lyrics_embedder.dart';
import 'models.dart';
import 'music_source.dart';
import 'player_service.dart';
import 'storage_service.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.source,
    StorageService? storage,
    PlayerService? player,
    Dio? downloadDio,
  }) : storage = storage ?? StorageService(),
       player = player ?? PlayerService(),
       _downloadDio = downloadDio ?? Dio() {
    this.player.onChanged = notifyListeners;
    this.player.onCompleted = _handlePlaybackCompleted;
  }

  final MusicSource source;
  final StorageService storage;
  final PlayerService player;
  final Dio _downloadDio;
  final Map<String, CancelToken> _cancelTokens = {};

  AppSettings? settings;
  bool isReady = false;
  int selectedIndex = 0;

  String searchQuery = '';
  bool isSearching = false;
  String? searchError;
  List<TrackSearchResult> searchResults = [];

  String? resolvingPlayId;
  String? preparingDownloadId;
  String? globalMessage;

  List<DownloadTask> downloadTasks = [];
  int _activeDownloads = 0;

  List<DownloadedTrack> downloadedTracks = [];
  bool lastDirectoryNeedsAllFilesAccess = false;

  List<PlayerItem> queue = [];
  int currentQueueIndex = -1;
  RepeatMode repeatMode = RepeatMode.none;

  PlayerItem? get currentItem {
    if (currentQueueIndex < 0 || currentQueueIndex >= queue.length) {
      return null;
    }
    return queue[currentQueueIndex];
  }

  Future<void> bootstrap() async {
    settings = await storage.loadSettings();
    downloadedTracks = await storage.loadDownloadedTracks();
    isReady = true;
    notifyListeners();
  }

  void selectIndex(int index) {
    selectedIndex = index;
    notifyListeners();
  }

  Future<void> search(String value) async {
    final keyword = value.trim();
    searchQuery = keyword;
    if (keyword.isEmpty) {
      searchResults = [];
      searchError = null;
      notifyListeners();
      return;
    }

    isSearching = true;
    searchError = null;
    notifyListeners();

    try {
      searchResults = await source.search(keyword);
      if (searchResults.isEmpty) {
        searchError = '没有找到公开可解析的搜索结果。';
      }
    } on MusicSourceException catch (error) {
      searchResults = [];
      searchError = error.message;
    } catch (error) {
      searchResults = [];
      searchError = '搜索失败：$error';
    } finally {
      isSearching = false;
      notifyListeners();
    }
  }

  Future<void> playSearchResult(TrackSearchResult result) async {
    resolvingPlayId = result.id;
    globalMessage = null;
    notifyListeners();

    try {
      final detail = await source.loadDetail(result);
      final candidate = _pickPreferredCandidate(
        await source.resolveCandidates(detail),
        allowNonMp3: true,
      );
      if (candidate == null) {
        throw const MusicSourceException('这个歌曲页面没有找到可播放的公开音频链接。');
      }
      final item = PlayerItem(
        id: result.id,
        title: detail.title,
        artist: detail.artist,
        uri: candidate.url,
        headers: candidate.headers,
        coverUrl: detail.coverUrl ?? result.coverUrl,
      );
      await _enqueueAndPlay(item);
    } on MusicSourceException catch (error) {
      globalMessage = error.message;
    } catch (error) {
      globalMessage = '播放失败：$error';
    } finally {
      resolvingPlayId = null;
      notifyListeners();
    }
  }

  Future<void> playDownloaded(DownloadedTrack track) async {
    final file = File(track.path);
    if (!await file.exists()) {
      globalMessage = '本地文件不存在：${track.path}';
      notifyListeners();
      return;
    }

    final item = PlayerItem(
      id: track.id,
      title: track.title,
      artist: track.artist,
      uri: file.uri.toString(),
      localPath: track.path,
      coverUrl: track.coverUrl,
    );
    await _enqueueAndPlay(item);
  }

  Future<void> playQueueAt(int index) async {
    if (index < 0 || index >= queue.length) {
      return;
    }
    currentQueueIndex = index;
    notifyListeners();
    await player.open(queue[index]);
  }

  Future<void> playNext() async {
    if (queue.isEmpty) {
      return;
    }
    if (currentQueueIndex < queue.length - 1) {
      await playQueueAt(currentQueueIndex + 1);
    } else if (repeatMode == RepeatMode.all) {
      await playQueueAt(0);
    }
  }

  Future<void> playPrevious() async {
    if (queue.isEmpty) {
      return;
    }
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
      return;
    }
    if (currentQueueIndex > 0) {
      await playQueueAt(currentQueueIndex - 1);
    } else if (repeatMode == RepeatMode.all) {
      await playQueueAt(queue.length - 1);
    }
  }

  Future<void> togglePlayPause() => player.playOrPause();

  Future<void> seekTo(Duration value) => player.seek(value);

  Future<void> setVolume(double value) => player.setVolume(value);

  void cycleRepeatMode() {
    repeatMode = switch (repeatMode) {
      RepeatMode.none => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.none,
    };
    notifyListeners();
  }

  Future<DownloadStartResult> startDownload(
    TrackSearchResult result, {
    bool allowNonMp3 = false,
  }) async {
    final activeSettings = settings;
    if (activeSettings == null) {
      return const DownloadStartResult.failed('应用还没有准备好。');
    }

    preparingDownloadId = result.id;
    globalMessage = null;
    notifyListeners();

    try {
      final detail = await source.loadDetail(result);
      final candidates = await source.resolveCandidates(detail);
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
      );
      downloadTasks = [task, ...downloadTasks];
      _scheduleDownloads();
      return const DownloadStartResult.started();
    } on MusicSourceException catch (error) {
      return DownloadStartResult.failed(error.message);
    } catch (error) {
      return DownloadStartResult.failed('创建下载任务失败：$error');
    } finally {
      preparingDownloadId = null;
      notifyListeners();
    }
  }

  void pauseDownload(String taskId) {
    _replaceTask(
      taskId,
      (task) => task.status == DownloadStatus.queued
          ? task.copyWith(status: DownloadStatus.paused)
          : task.copyWith(status: DownloadStatus.paused),
    );
    _cancelTokens[taskId]?.cancel('paused');
    notifyListeners();
  }

  void cancelDownload(String taskId) {
    final task = _taskById(taskId);
    _replaceTask(
      taskId,
      (task) => task.copyWith(status: DownloadStatus.canceled),
    );
    _cancelTokens[taskId]?.cancel('canceled');
    if (task != null) {
      unawaited(_deletePartialFile(task.savePath));
    }
    notifyListeners();
    _scheduleDownloads();
  }

  void retryDownload(String taskId) {
    _replaceTask(
      taskId,
      (task) => task.copyWith(
        status: DownloadStatus.queued,
        progress: 0,
        error: null,
        receivedBytes: 0,
        totalBytes: null,
      ),
    );
    notifyListeners();
    _scheduleDownloads();
  }

  Future<bool> setDownloadDirectory(String selected) async {
    lastDirectoryNeedsAllFilesAccess = false;
    final trimmed = _normalizeManualDownloadPath(selected);
    if (trimmed.isEmpty || settings == null) {
      return false;
    }
    try {
      final directory = Directory(trimmed);
      await directory.create(recursive: true);
      final probe = File(
        '${directory.path}${Platform.pathSeparator}.qingting_write_test',
      );
      await probe.writeAsString('ok');
      if (await probe.exists()) {
        await probe.delete();
      }
    } catch (_) {
      if (AndroidStorageAccess.isAndroid &&
          AndroidStorageAccess.isPublicExternalPath(trimmed) &&
          !await AndroidStorageAccess.hasAllFilesAccess()) {
        lastDirectoryNeedsAllFilesAccess = true;
      }
      return false;
    }
    settings = settings!.copyWith(downloadDirectory: trimmed);
    await storage.saveSettings(settings!);
    notifyListeners();
    return true;
  }

  Future<void> openAllFilesAccessSettings() {
    return AndroidStorageAccess.openAllFilesAccessSettings();
  }

  Future<bool> openProjectRepository() {
    return AndroidStorageAccess.openUrl(
      'https://github.com/sadpotato1006/music_downloader',
    );
  }

  Future<void> setConcurrentDownloads(int value) async {
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(concurrentDownloads: value.clamp(1, 4));
    await storage.saveSettings(settings!);
    notifyListeners();
    _scheduleDownloads();
  }

  Future<void> openDownloadedFile(DownloadedTrack track) async {
    if (!await File(track.path).exists()) {
      globalMessage = '本地文件不存在：${track.path}';
      notifyListeners();
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
    await storage.saveDownloadedTracks(downloadedTracks);
    notifyListeners();
  }

  void clearGlobalMessage() {
    globalMessage = null;
    notifyListeners();
  }

  Future<void> _enqueueAndPlay(PlayerItem item) async {
    final existingIndex = queue.indexWhere((queued) => queued.id == item.id);
    if (existingIndex >= 0) {
      queue[existingIndex] = item;
      await playQueueAt(existingIndex);
      return;
    }

    queue = [...queue, item];
    await playQueueAt(queue.length - 1);
  }

  void _handlePlaybackCompleted() {
    unawaited(() async {
      if (repeatMode == RepeatMode.one && currentItem != null) {
        await playQueueAt(currentQueueIndex);
      } else {
        await playNext();
      }
    }());
  }

  void _scheduleDownloads() {
    final limit = settings?.concurrentDownloads ?? 2;
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
    notifyListeners();

    try {
      await _downloadDio.download(
        task.candidate.url,
        task.savePath,
        cancelToken: token,
        options: Options(headers: task.candidate.headers),
        onReceiveProgress: (received, total) {
          _replaceTask(
            taskId,
            (task) => task.copyWith(
              progress: total > 0 ? received / total : task.progress,
              receivedBytes: received,
              totalBytes: total > 0 ? total : null,
            ),
          );
          notifyListeners();
        },
      );

      final completedTask = _taskById(taskId);
      if (completedTask == null ||
          completedTask.status == DownloadStatus.canceled) {
        return;
      }
      await _embedMetadataIfPossible(completedTask);
      _replaceTask(
        taskId,
        (task) => task.copyWith(status: DownloadStatus.completed, progress: 1),
      );
      await _addDownloadedTrack(completedTask);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        return;
      }
      _replaceTask(
        taskId,
        (task) => task.copyWith(
          status: DownloadStatus.failed,
          error: _downloadErrorMessage(error),
        ),
      );
    } catch (error) {
      _replaceTask(
        taskId,
        (task) => task.copyWith(status: DownloadStatus.failed, error: '$error'),
      );
    } finally {
      _cancelTokens.remove(taskId);
      notifyListeners();
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
    if ((lyrics == null || lyrics.isEmpty) && cover == null) {
      return;
    }

    try {
      await Id3LyricsEmbedder.embedMetadata(
        File(task.savePath),
        lyrics: lyrics,
        title: task.track.title,
        artist: task.track.artist,
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
        'User-Agent': 'QingTing/1.0 (+personal-use)',
      },
      {
        'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
        'User-Agent': 'QingTing/1.0 (+personal-use)',
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

  Future<void> _addDownloadedTrack(DownloadTask task) async {
    final item = DownloadedTrack(
      id: task.track.id,
      title: task.track.title,
      artist: task.track.artist,
      path: task.savePath,
      format: task.candidate.format,
      downloadedAt: DateTime.now(),
      sourceUrl: task.track.detailUrl,
      coverUrl: task.track.coverUrl,
    );
    downloadedTracks = [
      item,
      ...downloadedTracks.where((track) => track.path != item.path),
    ];
    await storage.saveDownloadedTracks(downloadedTracks);
  }

  String _downloadErrorMessage(DioException error) {
    final status = error.response?.statusCode;
    if (status == 403) {
      return '下载链接被拒绝访问。';
    }
    if (status != null) {
      return '下载失败：HTTP $status';
    }
    return '下载失败：${error.message ?? error.type.name}';
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

  @override
  void dispose() {
    player.onChanged = null;
    player.onCompleted = null;
    unawaited(player.dispose());
    super.dispose();
  }
}
