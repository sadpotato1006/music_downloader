import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import 'android_storage_access.dart';
import 'android_media_controls_service.dart';
import 'album_metadata_service.dart';
import 'id3_lyrics_embedder.dart';
import 'library_search.dart';
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
    AlbumMetadataService? albumMetadata,
  }) : storage = storage ?? StorageService(),
       player = player ?? PlayerService(),
       albumMetadata = albumMetadata ?? AlbumMetadataService(),
       _downloadDio = downloadDio ?? Dio() {
    this.player.onChanged = _handlePlayerChanged;
    this.player.onCompleted = _handlePlaybackCompleted;
    AndroidMediaControlsService.setHandler(_handleAndroidMediaControl);
  }

  final MusicSource source;
  final StorageService storage;
  final PlayerService player;
  final AlbumMetadataService albumMetadata;
  final Dio _downloadDio;
  final Random _shuffleRandom = Random();
  final Map<String, CancelToken> _cancelTokens = {};
  static const _sourceRequestGap = Duration(seconds: 2);
  static const _cooldown520 = Duration(minutes: 3);
  static const _cooldown403 = Duration(minutes: 10);
  static const _cooldown429 = Duration(minutes: 5);

  AppSettings? settings = const AppSettings(downloadDirectory: '');
  bool isReady = false;
  int selectedIndex = 0;
  DateTime? sourceCooldownUntil;
  String? sourceCooldownReason;
  Future<void> _sourceRequestQueue = Future<void>.value();
  DateTime? _lastSourceRequestAt;
  Timer? _settingsSaveDebounce;
  String? _lastMediaControlsSignature;

  String searchQuery = '';
  bool isSearching = false;
  String? searchError;
  List<TrackSearchResult> searchResults = [];

  String? resolvingPlayId;
  String? preparingDownloadId;
  String? preparingQueueNextId;
  String? globalMessage;

  List<DownloadTask> downloadTasks = [];
  int _activeDownloads = 0;

  List<DownloadedTrack> downloadedTracks = [];
  bool lastDirectoryNeedsAllFilesAccess = false;
  bool isScanningDownloadDirectory = false;
  bool isMatchingLocalAlbums = false;
  String? matchingAlbumTrackId;
  String libraryQuery = '';
  LibrarySortMode librarySortMode = LibrarySortMode.downloadedAtDesc;
  final Map<String, String> _libraryLyricsSearchCache = {};
  final Map<String, LibrarySearchIndex> _librarySearchIndexCache = {};
  final Set<String> _loadingLibraryLyricsKeys = {};
  int _libraryLyricsSearchGeneration = 0;

  List<PlayerItem> queue = [];
  int currentQueueIndex = -1;
  RepeatMode repeatMode = RepeatMode.none;
  bool shuffleEnabled = true;

  PlayerItem? get currentItem {
    if (currentQueueIndex < 0 || currentQueueIndex >= queue.length) {
      return null;
    }
    return queue[currentQueueIndex];
  }

  bool get isSourceCoolingDown => sourceCooldownRemaining > Duration.zero;

  Duration get sourceCooldownRemaining {
    final until = sourceCooldownUntil;
    if (until == null) {
      return Duration.zero;
    }
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  String? get sourceCooldownText {
    final remaining = sourceCooldownRemaining;
    if (remaining <= Duration.zero) {
      return null;
    }
    return '${sourceCooldownReason ?? '请求太频繁'}，请等待 ${_formatCooldown(remaining)} 后再试。';
  }

  List<DownloadedTrack> get visibleDownloadedTracks {
    final normalizedQuery = LibrarySearch.normalize(libraryQuery);
    final filtered = normalizedQuery.isEmpty
        ? List<DownloadedTrack>.from(downloadedTracks)
        : downloadedTracks.where((track) {
            return _librarySearchIndexFor(
              track,
            ).matchesNormalizedQuery(normalizedQuery);
          }).toList();

    filtered.sort((a, b) {
      return switch (librarySortMode) {
        LibrarySortMode.downloadedAtDesc => b.downloadedAt.compareTo(
          a.downloadedAt,
        ),
        LibrarySortMode.titleAsc => _compareText(a.title, b.title),
        LibrarySortMode.artistAsc => _compareText(
          a.artist.isEmpty ? '未知歌手' : a.artist,
          b.artist.isEmpty ? '未知歌手' : b.artist,
        ),
      };
    });
    return filtered;
  }

  Future<void> bootstrap() async {
    settings = await storage.loadSettings();
    await player.setVolume(settings!.volume.clamp(0, 100).toDouble());
    downloadedTracks = await _hydrateDownloadedCoverCaches(
      await storage.loadDownloadedTracks(),
    );
    final savedQueue = await storage.loadPlayerQueue();
    queue = savedQueue.items;
    currentQueueIndex = savedQueue.normalizedCurrentIndex;
    shuffleEnabled = savedQueue.items.isEmpty
        ? savedQueue.shuffleEnabled
        : true;
    selectedIndex = settings!.defaultStartupPageIndex == 2 ? 2 : 0;
    final startupItem = settings!.autoPlayOnStartup ? currentItem : null;
    isReady = true;
    notifyListeners();
    unawaited(_syncAndroidMediaControls(force: true));
    if (startupItem != null) {
      unawaited(player.open(startupItem));
    }
  }

  void _handlePlayerChanged() {
    unawaited(_syncAndroidMediaControls());
    notifyListeners();
  }

  Future<void> _handleAndroidMediaControl(
    String action,
    Duration? position,
  ) async {
    switch (action) {
      case 'play':
        if (currentItem != null) {
          await player.play();
        }
        break;
      case 'pause':
        await player.pause();
        break;
      case 'toggle':
        await togglePlayPause();
        break;
      case 'previous':
        await playPrevious();
        break;
      case 'next':
        await playNext();
        break;
      case 'seek':
        if (position != null) {
          await seekTo(position);
        }
        break;
    }
    await _syncAndroidMediaControls(force: true);
  }

  Future<void> _syncAndroidMediaControls({bool force = false}) async {
    if (!AndroidMediaControlsService.isSupported) {
      return;
    }
    final item = currentItem;
    if (item == null) {
      if (_lastMediaControlsSignature != 'hidden' || force) {
        _lastMediaControlsSignature = 'hidden';
        await AndroidMediaControlsService.hide();
      }
      return;
    }

    final positionBucket = player.isPlaying
        ? player.position.inSeconds ~/ 5
        : player.position.inSeconds;
    final canPlayPrevious =
        queue.length > 1 &&
        (currentQueueIndex > 0 || repeatMode == RepeatMode.all);
    final canPlayNext =
        queue.length > 1 &&
        (currentQueueIndex < queue.length - 1 || repeatMode == RepeatMode.all);
    final signature = [
      item.id,
      item.title,
      item.artist,
      item.album,
      item.coverFilePath ?? '',
      player.isPlaying,
      player.duration.inMilliseconds,
      positionBucket,
      canPlayPrevious,
      canPlayNext,
    ].join('|');
    if (!force && signature == _lastMediaControlsSignature) {
      return;
    }
    _lastMediaControlsSignature = signature;
    await AndroidMediaControlsService.update(
      item: item,
      isPlaying: player.isPlaying,
      position: player.position,
      duration: player.duration,
      canPlayPrevious: canPlayPrevious,
      canPlayNext: canPlayNext,
    );
  }

  void selectIndex(int index) {
    if (index < 0 || index > 3 || selectedIndex == index) {
      return;
    }
    selectedIndex = index;
    notifyListeners();
  }

  void setLibraryQuery(String value) {
    _setLibraryQuery(value);
    notifyListeners();
  }

  void commitLibrarySearch(String value) {
    final keyword = value.trim();
    _setLibraryQuery(keyword);
    if (keyword.isNotEmpty) {
      _rememberLibrarySearch(keyword);
    }
    notifyListeners();
  }

  void _setLibraryQuery(String value) {
    libraryQuery = value.trim();
    if (LibrarySearch.normalize(libraryQuery).isNotEmpty) {
      unawaited(_ensureLibraryLyricsForQuery(libraryQuery));
    } else {
      _libraryLyricsSearchGeneration += 1;
    }
  }

  Future<void> _ensureLibraryLyricsForQuery(String query) async {
    final normalizedQuery = LibrarySearch.normalize(query);
    if (normalizedQuery.isEmpty) {
      return;
    }
    final generation = ++_libraryLyricsSearchGeneration;
    var changed = false;

    for (final track in List<DownloadedTrack>.from(downloadedTracks)) {
      if (generation != _libraryLyricsSearchGeneration ||
          LibrarySearch.normalize(libraryQuery) != normalizedQuery) {
        return;
      }

      if (_librarySearchIndexFor(
        track,
        includeCachedLyrics: false,
      ).matchesNormalizedQuery(normalizedQuery)) {
        continue;
      }

      final key = _libraryLyricsCacheKey(track);
      if (_libraryLyricsSearchCache.containsKey(key) ||
          !_loadingLibraryLyricsKeys.add(key)) {
        continue;
      }

      try {
        await Future<void>.delayed(Duration.zero);
        _libraryLyricsSearchCache[key] =
            (await readDownloadedLyrics(track))?.trim() ?? '';
        changed = true;
      } finally {
        _loadingLibraryLyricsKeys.remove(key);
      }
    }

    if (changed &&
        generation == _libraryLyricsSearchGeneration &&
        LibrarySearch.normalize(libraryQuery) == normalizedQuery) {
      notifyListeners();
    }
  }

  void setLibrarySortMode(LibrarySortMode mode) {
    if (librarySortMode == mode) {
      return;
    }
    librarySortMode = mode;
    notifyListeners();
  }

  void showMessage(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }
    globalMessage = trimmed;
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

    _rememberSourceSearch(keyword);
    isSearching = true;
    searchError = null;
    notifyListeners();

    try {
      searchResults = await _runSourceRequest(
        '搜索',
        () => source.search(keyword),
      );
      if (searchResults.isEmpty) {
        searchError = '没有找到公开可解析的搜索结果。';
      }
    } on MusicSourceException catch (error) {
      searchResults = [];
      searchError = error.message;
    } catch (error) {
      searchResults = [];
      searchError = '搜索失败：${_friendlyUnexpectedError(error)}';
    } finally {
      isSearching = false;
      notifyListeners();
    }
  }

  void _rememberSourceSearch(String keyword) {
    final activeSettings = settings;
    if (activeSettings == null) {
      return;
    }
    final updated = _updatedSearchHistory(
      activeSettings.sourceSearchHistory,
      keyword,
    );
    if (listEquals(updated, activeSettings.sourceSearchHistory)) {
      return;
    }
    settings = activeSettings.copyWith(sourceSearchHistory: updated);
    _debouncedSaveSettings();
  }

  void _rememberLibrarySearch(String keyword) {
    final activeSettings = settings;
    if (activeSettings == null) {
      return;
    }
    final updated = _updatedSearchHistory(
      activeSettings.librarySearchHistory,
      keyword,
    );
    if (listEquals(updated, activeSettings.librarySearchHistory)) {
      return;
    }
    settings = activeSettings.copyWith(librarySearchHistory: updated);
    _debouncedSaveSettings();
  }

  List<String> _updatedSearchHistory(List<String> current, String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return current;
    }
    return normalizeSearchHistory([
      trimmed,
      ...current.where(
        (item) => item.trim().toLowerCase() != trimmed.toLowerCase(),
      ),
    ]);
  }

  Future<void> playSearchResult(TrackSearchResult result) async {
    resolvingPlayId = result.id;
    globalMessage = null;
    notifyListeners();

    try {
      final item = await _resolveSearchResultPlayerItem(result, '播放');
      await _enqueueAndPlay(item);
    } on MusicSourceException catch (error) {
      globalMessage = error.message;
    } catch (error) {
      globalMessage = '播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      resolvingPlayId = null;
      notifyListeners();
    }
  }

  Future<void> queueSearchResultNext(TrackSearchResult result) async {
    preparingQueueNextId = result.id;
    globalMessage = null;
    notifyListeners();

    try {
      final item = await _resolveSearchResultPlayerItem(result, '下一首播放');
      final started = await _enqueueNextOrPlayWhenIdle(item);
      globalMessage = started
          ? '已开始播放：${item.title}'
          : '已加入下一首播放：${item.title}';
    } on MusicSourceException catch (error) {
      globalMessage = error.message;
    } catch (error) {
      globalMessage = '加入下一首播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      preparingQueueNextId = null;
      notifyListeners();
    }
  }

  Future<void> playDownloaded(DownloadedTrack track) async {
    final item = await _playerItemFromDownloadedTrack(track);
    if (item == null) {
      return;
    }
    await _enqueueAndPlay(item);
  }

  Future<void> queueDownloadedNext(DownloadedTrack track) async {
    preparingQueueNextId = track.id;
    globalMessage = null;
    notifyListeners();

    try {
      final item = await _playerItemFromDownloadedTrack(track);
      if (item == null) {
        return;
      }
      final started = await _enqueueNextOrPlayWhenIdle(item);
      globalMessage = started
          ? '已开始播放：${item.title}'
          : '已加入下一首播放：${item.title}';
    } catch (error) {
      globalMessage = '加入下一首播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      preparingQueueNextId = null;
      notifyListeners();
    }
  }

  Future<void> playQueueAt(int index) async {
    if (index < 0 || index >= queue.length) {
      return;
    }
    final item = await _hydrateQueueItemForPlayback(queue[index]);
    if (item.id != queue[index].id ||
        item.lyrics != queue[index].lyrics ||
        item.album != queue[index].album ||
        item.coverFilePath != queue[index].coverFilePath) {
      queue[index] = item;
    }
    currentQueueIndex = index;
    await _saveQueueState();
    notifyListeners();
    unawaited(_syncAndroidMediaControls(force: true));
    await player.open(item);
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

  Future<void> setVolume(double value) async {
    final normalized = value.clamp(0, 100).toDouble();
    await player.setVolume(normalized);
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(volume: normalized);
    _debouncedSaveSettings();
    notifyListeners();
  }

  void cycleRepeatMode() {
    repeatMode = switch (repeatMode) {
      RepeatMode.none => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.none,
    };
    unawaited(_syncAndroidMediaControls(force: true));
    notifyListeners();
  }

  void toggleShuffleMode() {
    shuffleEnabled = !shuffleEnabled;
    unawaited(_saveQueueState());
    notifyListeners();
  }

  bool get isSingleLoopMode => repeatMode == RepeatMode.one;

  void toggleSingleLoopMode() {
    if (isSingleLoopMode) {
      repeatMode = RepeatMode.none;
    } else {
      repeatMode = RepeatMode.one;
    }
    notifyListeners();
  }

  bool get canReshuffleUpcomingQueue {
    return queue.length - _upcomingQueueStartIndex > 1;
  }

  Future<void> startRandomLibraryPlayback() async {
    if (downloadedTracks.isEmpty) {
      globalMessage = '本地列表为空，请先下载歌曲或扫描下载目录。';
      notifyListeners();
      return;
    }

    final shuffledTracks = List<DownloadedTrack>.from(downloadedTracks)
      ..shuffle(_shuffleRandom);
    final items = <PlayerItem>[];
    for (final track in shuffledTracks) {
      final item = await _playerItemFromDownloadedTrack(
        track,
        includeLyrics: false,
        showMissingMessage: false,
      );
      if (item != null) {
        items.add(item);
      }
    }

    if (items.isEmpty) {
      globalMessage = '没有找到可播放的本地文件，请重新扫描下载目录。';
      notifyListeners();
      return;
    }

    queue = items;
    currentQueueIndex = 0;
    shuffleEnabled = true;
    await playQueueAt(0);
  }

  Future<void> reshuffleUpcomingQueue() async {
    final startIndex = _upcomingQueueStartIndex;
    final upcomingCount = queue.length - startIndex;
    if (upcomingCount < 2) {
      globalMessage = '后面没有足够的歌曲可以重新随机。';
      notifyListeners();
      return;
    }

    final upcoming = queue.sublist(startIndex)..shuffle(_shuffleRandom);
    if (_sameQueueOrder(upcoming, queue.sublist(startIndex))) {
      upcoming.add(upcoming.removeAt(0));
    }

    queue = [...queue.take(startIndex), ...upcoming];
    shuffleEnabled = true;
    await _saveQueueState();
    globalMessage = '已重新随机接下来的 $upcomingCount 首歌。';
    notifyListeners();
  }

  int get _upcomingQueueStartIndex {
    if (currentQueueIndex < 0 || currentQueueIndex >= queue.length) {
      return 0;
    }
    return currentQueueIndex + 1;
  }

  bool _sameQueueOrder(List<PlayerItem> left, List<PlayerItem> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index].id != right[index].id ||
          left[index].uri != right[index].uri) {
        return false;
      }
    }
    return true;
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
      final detail = await _runSourceRequest(
        '下载',
        () => source.loadDetail(result),
      );
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
      _scheduleDownloads();
      return const DownloadStartResult.started();
    } on MusicSourceException catch (error) {
      return DownloadStartResult.failed(error.message);
    } catch (error) {
      return DownloadStartResult.failed(
        '创建下载任务失败：${_friendlyUnexpectedError(error)}',
      );
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

  Future<String?> pickDownloadDirectory() async {
    if (!Platform.isWindows) {
      return null;
    }
    final initialDirectory = settings?.downloadDirectory ?? '';
    final script =
        '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
\$dialog.Description = '选择青听下载目录'
\$dialog.ShowNewFolderButton = \$true
\$initial = '${_escapePowerShellSingleQuoted(initialDirectory)}'
if (\$initial -and [System.IO.Directory]::Exists(\$initial)) {
  \$dialog.SelectedPath = \$initial
}
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  Write-Output \$dialog.SelectedPath
}
''';
    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-Command', script],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
      if (result.exitCode != 0) {
        return null;
      }
      final selected = result.stdout.toString().trim();
      return selected.isEmpty ? null : selected;
    } catch (_) {
      return null;
    }
  }

  String _escapePowerShellSingleQuoted(String value) {
    return value.replaceAll("'", "''");
  }

  Future<void> openAllFilesAccessSettings() {
    return AndroidStorageAccess.openAllFilesAccessSettings();
  }

  Future<bool> openProjectRepository() {
    return openExternalUrl('https://github.com/sadpotato1006/music_downloader');
  }

  Future<bool> openExternalUrl(String url) async {
    if (AndroidStorageAccess.isAndroid) {
      return AndroidStorageAccess.openUrl(url);
    }
    if (Platform.isWindows) {
      try {
        await Process.start('rundll32.exe', [
          'url.dll,FileProtocolHandler',
          url,
        ]);
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<void> setConcurrentDownloads(int value) async {
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(
      concurrentDownloads: value.clamp(1, 4).toInt(),
    );
    await storage.saveSettings(settings!);
    notifyListeners();
    _scheduleDownloads();
  }

  Future<void> setAutoPlayOnStartup(bool enabled) async {
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(autoPlayOnStartup: enabled);
    await storage.saveSettings(settings!);
    notifyListeners();
  }

  Future<void> setDefaultStartupPageIndex(int index) async {
    if (settings == null) {
      return;
    }
    final normalized = index == 2 ? 2 : 0;
    settings = settings!.copyWith(defaultStartupPageIndex: normalized);
    await storage.saveSettings(settings!);
    notifyListeners();
  }

  void setDesktopLyricsSettings(DesktopLyricsSettings value) {
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(desktopLyrics: value);
    _debouncedSaveSettings();
    notifyListeners();
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
    final key = _libraryLyricsCacheKey(track);
    _libraryLyricsSearchCache.remove(key);
    _loadingLibraryLyricsKeys.remove(key);
    await storage.saveDownloadedTracks(downloadedTracks);
    notifyListeners();
  }

  Future<int> scanCurrentDownloadDirectory() async {
    final activeSettings = settings;
    if (activeSettings == null || isScanningDownloadDirectory) {
      return 0;
    }

    final directory = Directory(activeSettings.downloadDirectory);
    isScanningDownloadDirectory = true;
    globalMessage = null;
    notifyListeners();

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
        await storage.saveDownloadedTracks(downloadedTracks);
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
      notifyListeners();
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
      notifyListeners();
      return false;
    }

    Id3CoverImage? manualCover;
    if (coverInput.trim().isNotEmpty) {
      manualCover = await _loadCoverFromManualInput(coverInput.trim());
      if (manualCover == null) {
        globalMessage = '封面图片不可用，请检查图片路径或网址。';
        notifyListeners();
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
        notifyListeners();
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
    await storage.saveDownloadedTracks(downloadedTracks);
    await _saveQueueState();
    globalMessage = null;
    unawaited(_syncAndroidMediaControls(force: true));
    notifyListeners();
    return true;
  }

  Future<List<AlbumMetadataMatch>> findDownloadedAlbumCandidates(
    DownloadedTrack track,
  ) async {
    if (isMatchingLocalAlbums) {
      globalMessage = '正在匹配专辑名称，请稍后再试。';
      notifyListeners();
      return const [];
    }

    isMatchingLocalAlbums = true;
    matchingAlbumTrackId = track.id;
    globalMessage = null;
    notifyListeners();

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
      notifyListeners();
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
    notifyListeners();
    return true;
  }

  Future<int> matchMissingDownloadedAlbums() async {
    if (isMatchingLocalAlbums) {
      return 0;
    }

    isMatchingLocalAlbums = true;
    matchingAlbumTrackId = null;
    globalMessage = null;
    notifyListeners();

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
        notifyListeners();

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
      notifyListeners();
    }
  }

  Future<void> removeQueueAt(int index) async {
    if (index < 0 || index >= queue.length) {
      return;
    }
    final removingCurrent = index == currentQueueIndex;
    queue = [
      for (var i = 0; i < queue.length; i += 1)
        if (i != index) queue[i],
    ];
    if (queue.isEmpty) {
      currentQueueIndex = -1;
      await player.stop();
    } else if (index < currentQueueIndex) {
      currentQueueIndex -= 1;
    } else if (removingCurrent) {
      currentQueueIndex = currentQueueIndex.clamp(0, queue.length - 1).toInt();
      await player.open(queue[currentQueueIndex]);
    }
    await _saveQueueState();
    unawaited(_syncAndroidMediaControls(force: true));
    notifyListeners();
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= queue.length) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0 || newIndex >= queue.length || oldIndex == newIndex) {
      return;
    }
    final moving = queue[oldIndex];
    final updatedQueue = List<PlayerItem>.from(queue)
      ..removeAt(oldIndex)
      ..insert(newIndex, moving);

    if (currentQueueIndex == oldIndex) {
      currentQueueIndex = newIndex;
    } else if (oldIndex < currentQueueIndex && newIndex >= currentQueueIndex) {
      currentQueueIndex -= 1;
    } else if (oldIndex > currentQueueIndex && newIndex <= currentQueueIndex) {
      currentQueueIndex += 1;
    }
    queue = updatedQueue;
    unawaited(_saveQueueState());
    unawaited(_syncAndroidMediaControls(force: true));
    notifyListeners();
  }

  void moveQueueItemTo(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= queue.length ||
        newIndex < 0 ||
        newIndex >= queue.length ||
        oldIndex == newIndex) {
      return;
    }
    final moving = queue[oldIndex];
    final updatedQueue = List<PlayerItem>.from(queue)
      ..removeAt(oldIndex)
      ..insert(newIndex, moving);

    if (currentQueueIndex == oldIndex) {
      currentQueueIndex = newIndex;
    } else if (oldIndex < currentQueueIndex && newIndex >= currentQueueIndex) {
      currentQueueIndex -= 1;
    } else if (oldIndex > currentQueueIndex && newIndex <= currentQueueIndex) {
      currentQueueIndex += 1;
    }
    queue = updatedQueue;
    unawaited(_saveQueueState());
    unawaited(_syncAndroidMediaControls(force: true));
    notifyListeners();
  }

  Future<void> clearQueue() async {
    queue = [];
    currentQueueIndex = -1;
    await player.stop();
    await _saveQueueState();
    unawaited(_syncAndroidMediaControls(force: true));
    notifyListeners();
  }

  void clearGlobalMessage() {
    globalMessage = null;
    notifyListeners();
  }

  void showGlobalMessage(String message) {
    globalMessage = message;
    notifyListeners();
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
      throw MusicSourceException(_friendlySourceMessage(error.message, action));
    } catch (error) {
      throw MusicSourceException(
        '$action失败：${_friendlyUnexpectedError(error)}',
      );
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      notifyListeners();
    }
  }

  void _throwIfSourceCoolingDown() {
    final remaining = sourceCooldownRemaining;
    if (remaining <= Duration.zero) {
      _clearExpiredCooldown();
      return;
    }
    throw MusicSourceException(
      '${sourceCooldownReason ?? '请求太频繁'}，青听已暂停访问歌曲宝 ${_formatCooldown(remaining)}。',
    );
  }

  Future<void> _waitForSourceGap() async {
    final last = _lastSourceRequestAt;
    if (last == null) {
      return;
    }
    final elapsed = DateTime.now().difference(last);
    if (elapsed < _sourceRequestGap) {
      await Future<void>.delayed(_sourceRequestGap - elapsed);
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
      cooldown = _cooldown520;
      reason = '歌曲宝临时拦截或异常返回';
    } else if (lower.contains('429') || lower.contains('频繁')) {
      cooldown = _cooldown429;
      reason = '请求太频繁';
    } else if (lower.contains('403') ||
        lower.contains('拒绝') ||
        lower.contains('验证')) {
      cooldown = _cooldown403;
      reason = '歌曲宝拒绝访问';
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

  String _friendlySourceMessage(String message, String action) {
    final lower = message.toLowerCase();
    if (lower.contains('520')) {
      return '歌曲宝返回 HTTP 520，通常是短时间请求太多或被网站临时拦截。青听已自动冷却几分钟，稍后再试。';
    }
    if (lower.contains('403') || lower.contains('拒绝')) {
      return '歌曲宝拒绝了这次$action请求。可能是访问太频繁、链接过期，或该页面不允许程序读取。';
    }
    if (lower.contains('429') || lower.contains('频繁')) {
      return '请求太频繁，青听已暂停访问歌曲宝一会儿，稍后再试。';
    }
    if (lower.contains('验证')) {
      return '歌曲宝要求验证后才能继续，青听不会绕过验证。请稍后重试。';
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

  Future<void> _enqueueNext(PlayerItem item) async {
    final updatedQueue = List<PlayerItem>.from(queue);
    var insertionIndex = currentQueueIndex >= 0
        ? currentQueueIndex + 1
        : updatedQueue.length;
    final existingIndex = updatedQueue.indexWhere(
      (queued) => queued.id == item.id,
    );

    if (existingIndex >= 0) {
      if (existingIndex == currentQueueIndex) {
        updatedQueue[existingIndex] = item;
        queue = updatedQueue;
        await _saveQueueState();
        notifyListeners();
        return;
      }
      updatedQueue.removeAt(existingIndex);
      if (existingIndex < currentQueueIndex) {
        currentQueueIndex -= 1;
      }
      insertionIndex = currentQueueIndex >= 0
          ? currentQueueIndex + 1
          : updatedQueue.length;
    }

    final clampedIndex = insertionIndex.clamp(0, updatedQueue.length).toInt();
    updatedQueue.insert(clampedIndex, item);
    queue = updatedQueue;
    await _saveQueueState();
    notifyListeners();
  }

  Future<bool> _enqueueNextOrPlayWhenIdle(PlayerItem item) async {
    if (!player.isPlaying) {
      await _enqueueAndPlay(item);
      return true;
    }

    await _enqueueNext(item);
    return false;
  }

  Future<PlayerItem> _hydrateQueueItemForPlayback(PlayerItem item) async {
    final localPath = item.localPath;
    if (localPath == null || localPath.trim().isEmpty) {
      return item;
    }
    final file = File(localPath);
    if (!await file.exists()) {
      return item;
    }
    Id3Metadata metadata = const Id3Metadata();
    try {
      metadata = await Id3LyricsEmbedder.extractMetadata(file);
    } catch (_) {
      metadata = const Id3Metadata();
    }
    var lyrics = item.lyrics;
    if (lyrics == null || lyrics.trim().isEmpty) {
      lyrics = metadata.lyrics ?? await _readSidecarLyrics(file);
    }
    final embeddedAlbum = metadata.album?.trim();
    final album =
        item.album.trim().isEmpty &&
            embeddedAlbum != null &&
            embeddedAlbum.isNotEmpty
        ? embeddedAlbum
        : item.album;
    return item.copyWith(lyrics: lyrics, album: album);
  }

  Future<PlayerItem> _resolveSearchResultPlayerItem(
    TrackSearchResult result,
    String action,
  ) async {
    final detail = await _runSourceRequest(
      action,
      () => source.loadDetail(result),
    );
    final candidate = _pickPreferredCandidate(
      await source.resolveCandidates(detail),
      allowNonMp3: true,
    );
    if (candidate == null) {
      throw const MusicSourceException('这个歌曲页面没有找到可播放的公开音频链接。');
    }
    return PlayerItem(
      id: result.id,
      title: detail.title,
      artist: detail.artist,
      uri: candidate.url,
      headers: candidate.headers,
      coverUrl: detail.coverUrl ?? result.coverUrl,
      lyrics: detail.lyrics,
      album: detail.album,
    );
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
        notifyListeners();
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
    await storage.saveDownloadedTracks(downloadedTracks);
    await _saveQueueState();
    notifyListeners();
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
        notifyListeners();
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
          notifyListeners();
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
    await storage.saveDownloadedTracks(downloadedTracks);
    await _saveQueueState();
    if (notify) {
      notifyListeners();
    }
    return true;
  }

  Future<void> _saveQueueState() {
    return storage.savePlayerQueue(
      queue,
      currentQueueIndex,
      shuffleEnabled: shuffleEnabled,
    );
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

  Future<DownloadTask> _matchAlbumForDownloadTask(DownloadTask task) async {
    final existingAlbum = task.album.trim();
    if (existingAlbum.isNotEmpty) {
      return task.copyWith(album: existingAlbum);
    }

    try {
      final match = await albumMetadata.findBestAlbum(
        title: task.track.title,
        artist: task.track.artist,
        lyrics: task.lyrics,
      );
      final album = match?.album.trim();
      if (album == null || album.isEmpty) {
        return task;
      }
      return task.copyWith(album: album);
    } catch (_) {
      return task;
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
    await storage.saveDownloadedTracks(downloadedTracks);
    if (LibrarySearch.normalize(libraryQuery).isNotEmpty) {
      unawaited(_ensureLibraryLyricsForQuery(libraryQuery));
    }
  }

  Future<List<DownloadedTrack>> _hydrateDownloadedCoverCaches(
    List<DownloadedTrack> tracks,
  ) async {
    var changed = false;
    final hydrated = <DownloadedTrack>[];
    for (final track in tracks) {
      var hydratedTrack = track;
      final coverFilePath = await storage.ensureEmbeddedCoverCache(track);
      if (coverFilePath != null && coverFilePath != track.coverFilePath) {
        hydratedTrack = hydratedTrack.copyWith(coverFilePath: coverFilePath);
        changed = true;
      }
      if (hydratedTrack.format.toLowerCase() == 'mp3' &&
          hydratedTrack.album.trim().isEmpty) {
        try {
          final metadata = await Id3LyricsEmbedder.extractMetadata(
            File(hydratedTrack.path),
          );
          final album = metadata.album?.trim();
          if (album != null && album.isNotEmpty) {
            hydratedTrack = hydratedTrack.copyWith(album: album);
            changed = true;
          }
        } catch (_) {
          // Keep the saved record if the file cannot be read.
        }
      }
      hydrated.add(hydratedTrack);
    }
    if (changed) {
      await storage.saveDownloadedTracks(hydrated);
    }
    return hydrated;
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

  String _downloadErrorMessage(DioException error) {
    final status = error.response?.statusCode;
    if (status == 403) {
      return '下载链接被拒绝访问。可能是歌曲宝临时拦截、下载地址过期，或该资源不允许公开下载。';
    }
    if (status == 404) {
      return '下载链接不存在或已经失效。请重新搜索后再试。';
    }
    if (status == 429 || status == 520) {
      _activateCooldownIfNeeded('HTTP $status');
      return '歌曲宝返回 HTTP $status，可能是请求太频繁。青听已自动冷却，稍后再试。';
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

  @override
  void dispose() {
    AndroidMediaControlsService.setHandler(null);
    unawaited(AndroidMediaControlsService.hide());
    _settingsSaveDebounce?.cancel();
    player.onChanged = null;
    player.onCompleted = null;
    unawaited(player.dispose());
    super.dispose();
  }
}

class _LocalAudioMetadata {
  const _LocalAudioMetadata({
    this.title,
    this.artist,
    this.album,
    this.coverFilePath,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? coverFilePath;
}

class _ParsedTrackFileName {
  const _ParsedTrackFileName({required this.title, required this.artist});

  final String title;
  final String artist;
}
