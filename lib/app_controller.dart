import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import 'android_storage_access.dart';
import 'android_media_controls_service.dart';
import 'album_metadata_service.dart';
import 'anyshare_auth.dart';
import 'anyshare_client.dart';
import 'app_info.dart';
import 'app_log.dart';
import 'async_utils.dart';
import 'audio_route_service.dart';
import 'coalescing_write_queue.dart';
import 'cloud_sync_service.dart';
import 'file_deletion_service.dart';
import 'id3_lyrics_embedder.dart';
import 'library_search.dart';
import 'library_lyrics_search.dart';
import 'linux_desktop_service.dart';
import 'lyrics_service.dart';
import 'models.dart';
import 'music_source.dart';
import 'player_service.dart';
import 'pending_album_match.dart';
import 'song_metadata.dart';
import 'storage_service.dart';

part 'controller/search_controller.dart';
part 'controller/library_controller.dart';
part 'controller/library_batch_controller.dart';
part 'controller/playback_controller.dart';
part 'controller/download_controller.dart';
part 'controller/settings_controller.dart';
part 'controller/cloud_sync_controller.dart';
part 'controller/song_metadata_controller.dart';

enum AppBootstrapStatus { loading, ready, error }

class AppController extends ChangeNotifier {
  AppController({
    required this.source,
    List<MusicSource>? sources,
    StorageService? storage,
    PlaybackService? player,
    Dio? downloadDio,
    AlbumMetadataService? albumMetadata,
    LyricsService? lyricsService,
    FileDeletionService? fileDeletionService,
    CloudSyncService? cloudSyncService,
  }) : sources = List<MusicSource>.unmodifiable(sources ?? [source]),
       storage = storage ?? StorageService(),
       player = player ?? PlayerService(),
       albumMetadata = albumMetadata ?? AlbumMetadataService(),
       lyricsService = lyricsService ?? LyricsService(),
       fileDeletionService =
           fileDeletionService ?? PlatformFileDeletionService(),
       _cloudSyncServiceOverride = cloudSyncService,
       _ownsDownloadDio = downloadDio == null,
       _downloadDio =
           downloadDio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               sendTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
             ),
           ) {
    this.player.onChanged = _handlePlayerChanged;
    this.player.positionListenable.addListener(_handlePlayerPositionChanged);
    this.player.onCompleted = _handlePlaybackCompleted;
    AndroidMediaControlsService.setHandler(_handleAndroidMediaControl);
    AndroidMediaControlsService.setPropertyHandler(_handleMediaProperty);
    AudioRouteService.setBluetoothRouteChangedHandler(
      handleBluetoothAudioRouteChanged,
    );
  }

  final List<MusicSource> sources;
  MusicSource source;
  final StorageService storage;
  final PlaybackService player;
  final AlbumMetadataService albumMetadata;
  final LyricsService lyricsService;
  final FileDeletionService fileDeletionService;
  final CloudSyncService? _cloudSyncServiceOverride;
  final bool _ownsDownloadDio;
  final Dio _downloadDio;
  final Random _shuffleRandom = Random();
  final Map<String, CancelToken> _cancelTokens = {};
  final Set<String> _runningDownloadIds = {};
  final Set<String> _pendingDownloadCleanupIds = {};
  final Set<String> _preparingDownloadKeys = {};
  bool _preparingToExit = false;
  bool _cloudSyncOwnsFiles = false;
  Future<void>? _metadataTagWriteOperation;
  final Set<String> _deletingTrackKeys = {};
  final Set<String> _metadataWriteKeys = {};
  final Map<String, int> _metadataReadCounts = {};
  static const _sourceRequestGap = Duration(seconds: 2);

  AppSettings? settings = const AppSettings(downloadDirectory: '');
  AppBootstrapStatus bootstrapStatus = AppBootstrapStatus.loading;
  String? bootstrapError;
  int selectedIndex = 0;
  Future<void> _sourceRequestQueue = Future<void>.value();
  DateTime? _lastSourceRequestAt;
  Timer? _settingsSaveDebounce;
  bool _settingsSavePending = false;
  Future<void>? _bootstrapOperation;
  String? _lastMediaControlsSignature;
  bool _isDisposed = false;
  int _sourceSearchGeneration = 0;
  final _downloadedTracksSaveQueue = CoalescingWriteQueue();
  final _myMusicSaveQueue = CoalescingWriteQueue();
  final _downloadTasksSaveQueue = CoalescingWriteQueue();
  final _playerQueueSaveQueue = CoalescingWriteQueue();
  Future<void> _downloadPathReservationQueue = Future<void>.value();
  final Set<String> _reservedDownloadSavePaths = {};
  final _pendingAlbumMatchesSaveQueue = CoalescingWriteQueue();
  late final AnyShareAuth cloudAuth = AnyShareAuth();
  late final AnyShareClient cloudClient = AnyShareClient(auth: cloudAuth);
  late final CloudSyncService cloudSyncService =
      _cloudSyncServiceOverride ?? CloudSyncService(client: cloudClient);
  bool cloudConnected = false;
  bool isCloudSyncing = false;
  CloudSyncProgress? cloudSyncProgress;
  String? cloudSyncError;
  String? cloudSyncNotice;
  List<CloudSyncFailure> cloudSyncFailures = const [];
  bool? cloudDeletionPolicyEnabled;
  bool isCloudPolicyLoading = false;
  DateTime? lastCloudSyncAt;
  Future<CloudSyncResult?>? _cloudSyncOperation;
  Future<void>? _playNextOperation;
  int _playbackRequestGeneration = 0;
  int _queueNextRequestGeneration = 0;
  Future<void> _playbackMutationQueue = Future<void>.value();
  Future<void>? _playbackCompletionOperation;
  Future<void>? _durationCaptureOperation;
  bool _durationCaptureRetryRequested = false;
  Future<void>? _albumMatchCompletion;
  Future<void> _automaticAlbumMatchQueue = Future<void>.value();
  Future<void>? _activeAutomaticAlbumMatch;
  final Set<String> _queuedAutomaticAlbumPaths = {};
  bool _deferredAlbumWritesScheduled = false;
  final Map<String, Future<void>> _downloadImportOperations = {};

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
  final ValueNotifier<int> _downloadProgressListenable = ValueNotifier(0);
  final Map<String, int> _lastDownloadProgressUpdateMillis = {};
  static const _downloadProgressUpdateInterval = Duration(milliseconds: 100);
  static const _maxEmbeddedCoverBytes = 5 * 1024 * 1024;

  List<DownloadedTrack> downloadedTracks = [];
  MyMusicData myMusic = const MyMusicData();
  static const int maxRecentPlaybacks = 100;
  List<DownloadedTrack>? _downloadedTracksByPathSource;
  Map<String, DownloadedTrack> _downloadedTracksByPathCache = const {};
  List<String>? _favoriteTrackPathsSource;
  Set<String> _favoriteTrackPathKeys = const {};

  bool lastDirectoryNeedsAllFilesAccess = false;
  bool isScanningDownloadDirectory = false;
  bool isLibraryBatchRunning = false;
  int libraryBatchCompleted = 0;
  int libraryBatchTotal = 0;
  Future<LibraryBatchResult>? _libraryBatchOperation;
  bool isMatchingLocalAlbums = false;
  String? matchingAlbumTrackPath;
  String? matchingAlbumTrackTitle;
  int albumMatchProcessed = 0;
  int albumMatchTotal = 0;
  int albumMatchUpdated = 0;
  int albumMatchNotFound = 0;
  int albumMatchFailed = 0;
  bool _albumMatchCancelRequested = false;
  List<PendingAlbumMatch> pendingAlbumMatches = const [];
  String libraryQuery = '';
  LibrarySortMode librarySortMode = LibrarySortMode.downloadedAtDesc;
  final Map<String, LibrarySearchIndex> _librarySearchIndexCache = {};
  late final _libraryLyricsSearch = LibraryLyricsSearch(
    readLyrics: readDownloadedLyrics,
    trackKey: (track) => _trackPathKey(track.path),
    isCurrent: (track) => identical(_downloadedTrackByPath(track.path), track),
    matchesMetadata: (track, query) =>
        _librarySearchIndexFor(track).matchesNormalizedQuery(query),
    onChanged: () {
      _visibleDownloadedTracksSource = null;
      _notify();
    },
    onError: (error, stackTrace) => AppLog.instance.warning(
      'library',
      '读取搜索歌词失败，继续搜索其他歌曲',
      detail: '$error\n$stackTrace',
    ),
  );
  List<DownloadedTrack>? _visibleDownloadedTracksSource;
  String _visibleDownloadedTracksQuery = '';
  LibrarySortMode? _visibleDownloadedTracksSortMode;
  List<DownloadedTrack> _visibleDownloadedTracksCache = const [];

  List<PlayerItem> queue = [];
  int currentQueueIndex = -1;
  RepeatMode repeatMode = RepeatMode.none;
  bool shuffleEnabled = true;

  ValueListenable<int> get downloadProgressListenable =>
      _downloadProgressListenable;

  bool get isReady => bootstrapStatus == AppBootstrapStatus.ready;

  void _notify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  PlayerItem? get currentItem {
    if (currentQueueIndex < 0 || currentQueueIndex >= queue.length) {
      return null;
    }
    return queue[currentQueueIndex];
  }

  bool get canSwitchSource => sources.length > 1;

  List<DownloadedTrack> get visibleDownloadedTracks {
    final normalizedQuery = LibrarySearch.normalize(libraryQuery);
    if (identical(_visibleDownloadedTracksSource, downloadedTracks) &&
        _visibleDownloadedTracksQuery == normalizedQuery &&
        _visibleDownloadedTracksSortMode == librarySortMode) {
      return _visibleDownloadedTracksCache;
    }

    final filtered = normalizedQuery.isEmpty
        ? List<DownloadedTrack>.from(downloadedTracks)
        : downloadedTracks.where((track) {
            return _librarySearchIndexFor(
                  track,
                ).matchesNormalizedQuery(normalizedQuery) ||
                _libraryLyricsSearch.matches(track, normalizedQuery);
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

    _visibleDownloadedTracksSource = downloadedTracks;
    _visibleDownloadedTracksQuery = normalizedQuery;
    _visibleDownloadedTracksSortMode = librarySortMode;
    _visibleDownloadedTracksCache = List<DownloadedTrack>.unmodifiable(
      filtered,
    );
    return _visibleDownloadedTracksCache;
  }

  List<DownloadedTrack> get favoriteTracks =>
      _tracksForPaths(myMusic.favoriteTrackPaths);

  List<DownloadedTrack> get recentTracks => _tracksForPaths(
    myMusic.recentPlaybacks.map((playback) => playback.trackPath),
  );

  List<DownloadedTrack> tracksForPlaylist(String playlistId) {
    final playlist = playlistById(playlistId);
    return playlist == null
        ? const <DownloadedTrack>[]
        : _tracksForPaths(playlist.trackPaths);
  }

  MusicPlaylist? playlistById(String playlistId) {
    for (final playlist in myMusic.playlists) {
      if (playlist.id == playlistId) {
        return playlist;
      }
    }
    return null;
  }

  bool isFavorite(DownloadedTrack track) {
    final paths = myMusic.favoriteTrackPaths;
    if (!identical(_favoriteTrackPathsSource, paths)) {
      _favoriteTrackPathKeys = paths.map(_trackPathKey).toSet();
      _favoriteTrackPathsSource = paths;
    }
    return _favoriteTrackPathKeys.contains(_trackPathKey(track.path));
  }

  bool isTrackInPlaylist(String playlistId, DownloadedTrack track) {
    final playlist = playlistById(playlistId);
    if (playlist == null) {
      return false;
    }
    final key = _trackPathKey(track.path);
    return playlist.trackPaths.any((path) => _trackPathKey(path) == key);
  }

  Map<String, DownloadedTrack> get _downloadedTracksByPath {
    // Library edits replace the list, as with the visible-tracks cache.
    if (!identical(_downloadedTracksByPathSource, downloadedTracks)) {
      _downloadedTracksByPathCache = {
        for (final track in downloadedTracks) _trackPathKey(track.path): track,
      };
      _downloadedTracksByPathSource = downloadedTracks;
    }
    return _downloadedTracksByPathCache;
  }

  List<DownloadedTrack> _tracksForPaths(Iterable<String> paths) {
    final tracksByPath = _downloadedTracksByPath;
    final result = <DownloadedTrack>[];
    final seen = <String>{};
    for (final path in paths) {
      final key = _trackPathKey(path);
      final track = tracksByPath[key];
      if (track != null && seen.add(key)) {
        result.add(track);
      }
    }
    return List<DownloadedTrack>.unmodifiable(result);
  }

  Future<void> bootstrap() {
    if (_isDisposed || isReady) {
      return Future<void>.value();
    }
    final activeOperation = _bootstrapOperation;
    if (activeOperation != null) {
      return activeOperation;
    }

    late final Future<void> operation;
    operation = _runBootstrap().whenComplete(() {
      if (identical(_bootstrapOperation, operation)) {
        _bootstrapOperation = null;
      }
    });
    _bootstrapOperation = operation;
    return operation;
  }

  Future<void> _runBootstrap() async {
    bootstrapStatus = AppBootstrapStatus.loading;
    bootstrapError = null;
    _notify();
    try {
      settings = await storage.loadSettings();
      if (_isDisposed) {
        return;
      }
      await player.setVolume(settings!.volume.clamp(0, 100).toDouble());
      if (_isDisposed) {
        return;
      }
      final restoredData = await Future.wait<Object>([
        storage.loadMyMusic(),
        storage.loadDownloadedTracks(),
        storage.loadDownloadTasks(),
        storage.loadPlayerQueue(),
        storage.loadPendingAlbumMatches(),
      ]);
      if (_isDisposed) {
        return;
      }
      myMusic = restoredData[0] as MyMusicData;
      downloadedTracks = restoredData[1] as List<DownloadedTrack>;
      downloadTasks = restoredData[2] as List<DownloadTask>;
      final savedQueue = restoredData[3] as SavedPlayerQueue;
      final restoredPendingMatches = restoredData[4] as List<PendingAlbumMatch>;
      pendingAlbumMatches = _validRestoredPendingAlbumMatches(
        restoredPendingMatches,
      );
      final removedStalePendingMatches =
          pendingAlbumMatches.length != restoredPendingMatches.length;
      await _restoreDownloadTasks();
      if (_isDisposed) {
        return;
      }
      queue = savedQueue.items;
      currentQueueIndex = savedQueue.normalizedCurrentIndex;
      shuffleEnabled = savedQueue.shuffleEnabled;
      selectedIndex = settings!.defaultStartupPageIndex == 2 ? 2 : 0;
      final startupItem = settings!.autoPlayOnStartup ? currentItem : null;
      bootstrapStatus = AppBootstrapStatus.ready;
      AppLog.instance.info(
        'bootstrap',
        '应用数据加载完成',
        detail:
            'tracks=${downloadedTracks.length}, queue=${queue.length}, '
            'downloads=${downloadTasks.length}, '
            'pendingAlbums=${pendingAlbumMatches.length}',
      );
      _notify();
      if (removedStalePendingMatches) {
        unawaited(_savePendingAlbumMatchesBestEffort());
      }
      unawaited(_syncAndroidMediaControls(force: true));
      if (_preparingToExit) return;
      unawaited(_hydrateDownloadedTracksInBackground());
      _scheduleDownloads();
      _scheduleDeferredAlbumWrites();
      _scheduleMetadataTagWrites();
      unawaited(_restoreCloudAndSync());
      for (final task in downloadTasks) {
        if (task.status == DownloadStatus.completed && task.libraryPending) {
          unawaited(_importCompletedDownload(task.id));
        }
      }
      if (startupItem != null) {
        unawaited(_openCurrentItemForPlayback());
      }
    } catch (error, stackTrace) {
      if (_isDisposed) {
        return;
      }
      bootstrapStatus = AppBootstrapStatus.error;
      bootstrapError = '应用数据加载失败，请检查存储权限后重试。';
      AppLog.instance.error(
        'bootstrap',
        '应用初始化失败',
        error: error,
        stackTrace: stackTrace,
      );
      _notify();
    }
  }

  Future<void> prepareForExit() async {
    _preparingToExit = true;
    _albumMatchCancelRequested = true;
    await player.pause();
    await _bootstrapOperation;
    for (final task in downloadTasks.toList()) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        pauseDownload(task.id);
      }
    }
    await _cloudSyncOperation;
    await flushPendingWrites();
  }

  Future<void> flushPendingWrites() async {
    final batch = _libraryBatchOperation;
    if (batch != null) await batch;
    await Future.wait(_downloadImportOperations.values.toList());
    final albumMatchCompletion = _albumMatchCompletion;
    if (albumMatchCompletion != null) {
      _albumMatchCancelRequested = true;
      try {
        await albumMatchCompletion;
      } catch (error, stackTrace) {
        AppLog.instance.error(
          'storage',
          '退出前停止专辑匹配失败',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (_isDisposed) {
      await _automaticAlbumMatchQueue;
    }
    final automaticAlbumWork = _activeAutomaticAlbumMatch;
    if (automaticAlbumWork != null) await automaticAlbumWork;
    try {
      await _flushPendingSettings();
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'storage',
        '退出前保存设置失败',
        error: error,
        stackTrace: stackTrace,
      );
    }

    final pendingWrites = <Future<void>>[
      ?_metadataTagWriteOperation,
      _downloadedTracksSaveQueue.flush(),
      _myMusicSaveQueue.flush(),
      _downloadTasksSaveQueue.flush(),
      _pendingAlbumMatchesSaveQueue.flush(),
      _playerQueueSaveQueue.flush(),
    ];
    await Future.wait(
      pendingWrites.map((write) async {
        try {
          await write;
        } catch (error, stackTrace) {
          AppLog.instance.error(
            'storage',
            '等待待处理数据写入失败',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }),
    );
    try {
      // Also wait for direct settings saves already running in StorageService.
      await storage.flushPendingWrites();
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'storage',
        '等待存储写入失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await AppLog.instance.flush();
  }

  void _handlePlayerChanged() {
    unawaited(_captureCurrentTrackDuration());
    unawaited(_syncAndroidMediaControls());
    _notify();
    _scheduleDeferredAlbumWrites();
    _scheduleMetadataTagWrites();
  }

  void _handlePlayerPositionChanged() {
    unawaited(_syncAndroidMediaControls());
  }

  Future<void> _handleAndroidMediaControl(
    String action,
    Duration? position,
  ) async {
    if (_isDisposed || _preparingToExit) return;
    await bootstrap();
    if (_isDisposed || _preparingToExit || !isReady) return;
    switch (action) {
      case 'play':
        await _playCurrentItem();
        break;
      case 'pause':
        await player.pause();
        break;
      case 'stop':
        await _stopPlayback();
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

  @visibleForTesting
  Future<void> handleBluetoothAudioRouteChanged() async {
    if (!player.isPlaying) {
      AppLog.instance.info('bluetooth', '蓝牙音频路由变化，当前未播放');
      return;
    }
    AppLog.instance.info('bluetooth', '蓝牙音频断开或切换，自动暂停播放');
    await player.pause();
  }

  Future<void> _handleMediaProperty(String property, Object value) async {
    if (_isDisposed || _preparingToExit) return;
    await bootstrap();
    if (_isDisposed || _preparingToExit || !isReady) return;
    switch (property) {
      case 'Volume':
        await setVolume((value as num).toDouble() * 100);
        break;
      case 'Shuffle':
        if (shuffleEnabled != value) toggleShuffleMode();
        break;
      case 'LoopStatus':
        repeatMode = switch (value) {
          'Track' => RepeatMode.one,
          'Playlist' => RepeatMode.all,
          _ => RepeatMode.none,
        };
        _notify();
        break;
    }
    await _syncAndroidMediaControls(force: true);
  }

  Future<void> _syncAndroidMediaControls({bool force = false}) async {
    if (_isDisposed || !AndroidMediaControlsService.isSupported) {
      return;
    }
    final item = currentItem;
    if (item == null) {
      if (_lastMediaControlsSignature != 'hidden' || force) {
        _lastMediaControlsSignature = 'hidden';
        await AndroidMediaControlsService.hide();
      }
      await AndroidMediaControlsService.updateState(
        volume: settings?.volume ?? 100,
        shuffle: shuffleEnabled,
        loopStatus: switch (repeatMode) {
          RepeatMode.one => 'Track',
          RepeatMode.all => 'Playlist',
          RepeatMode.none => 'None',
        },
      );
      return;
    }

    final positionBucket = player.isPlaying
        ? player.position.inSeconds ~/ 5
        : player.position.inSeconds;
    final canPlayPrevious =
        queue.length > 1 &&
        (currentQueueIndex > 0 || repeatMode == RepeatMode.all);
    final canPlayNext = queue.isNotEmpty;
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
      settings?.volume ?? 100,
      shuffleEnabled,
      repeatMode,
      player.isOpened(item),
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
      volume: settings?.volume ?? 100,
      shuffle: shuffleEnabled,
      loopStatus: switch (repeatMode) {
        RepeatMode.one => 'Track',
        RepeatMode.all => 'Playlist',
        RepeatMode.none => 'None',
      },
      isOpened: player.isOpened(item),
    );
  }

  @override
  void dispose() {
    unawaited(_persistDownloadTasksBestEffort());
    unawaited(flushPendingWrites());
    _isDisposed = true;
    _libraryLyricsSearch.dispose();
    _albumMatchCancelRequested = true;
    for (final token in _cancelTokens.values) {
      token.cancel('disposed');
    }
    AndroidMediaControlsService.setHandler(null);
    AndroidMediaControlsService.setPropertyHandler(null);
    AudioRouteService.setBluetoothRouteChangedHandler(null);
    unawaited(AndroidMediaControlsService.hide());
    _settingsSaveDebounce?.cancel();
    player.onChanged = null;
    player.positionListenable.removeListener(_handlePlayerPositionChanged);
    player.onCompleted = null;
    _downloadProgressListenable.dispose();
    if (_ownsDownloadDio) {
      _downloadDio.close(force: true);
    }
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

class _HydratedTrack {
  const _HydratedTrack({required this.original, required this.updated});

  final DownloadedTrack original;
  final DownloadedTrack updated;
}

class _ParsedTrackFileName {
  const _ParsedTrackFileName({required this.title, required this.artist});

  final String title;
  final String artist;
}
