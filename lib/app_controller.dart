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
import 'app_log.dart';
import 'audio_route_service.dart';
import 'id3_lyrics_embedder.dart';
import 'library_search.dart';
import 'lyrics_service.dart';
import 'models.dart';
import 'music_source.dart';
import 'player_service.dart';
import 'storage_service.dart';

part 'controller/search_controller.dart';
part 'controller/library_controller.dart';
part 'controller/playback_controller.dart';
part 'controller/download_controller.dart';
part 'controller/settings_controller.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.source,
    List<MusicSource>? sources,
    StorageService? storage,
    PlaybackService? player,
    Dio? downloadDio,
    AlbumMetadataService? albumMetadata,
    LyricsService? lyricsService,
  }) : sources = List<MusicSource>.unmodifiable(sources ?? [source]),
       storage = storage ?? StorageService(),
       player = player ?? PlayerService(),
       albumMetadata = albumMetadata ?? AlbumMetadataService(),
       lyricsService = lyricsService ?? LyricsService(),
       _downloadDio = downloadDio ?? Dio() {
    this.player.onChanged = _handlePlayerChanged;
    this.player.positionListenable.addListener(_handlePlayerPositionChanged);
    this.player.onCompleted = _handlePlaybackCompleted;
    AndroidMediaControlsService.setHandler(_handleAndroidMediaControl);
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
  final Dio _downloadDio;
  final Random _shuffleRandom = Random();
  final Map<String, CancelToken> _cancelTokens = {};
  final Set<String> _preparingDownloadKeys = {};
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
  bool _isDisposed = false;
  Future<void> _downloadedTracksSaveQueue = Future<void>.value();
  Future<void> _myMusicSaveQueue = Future<void>.value();
  Future<void> _downloadTasksSaveQueue = Future<void>.value();

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

  List<DownloadedTrack> downloadedTracks = [];
  MyMusicData myMusic = const MyMusicData();
  static const int maxRecentPlaybacks = 100;

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

  void _notify() => notifyListeners();

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
    final key = _trackPathKey(track.path);
    return myMusic.favoriteTrackPaths.any((path) => _trackPathKey(path) == key);
  }

  bool isTrackInPlaylist(String playlistId, DownloadedTrack track) {
    final playlist = playlistById(playlistId);
    if (playlist == null) {
      return false;
    }
    final key = _trackPathKey(track.path);
    return playlist.trackPaths.any((path) => _trackPathKey(path) == key);
  }

  List<DownloadedTrack> _tracksForPaths(Iterable<String> paths) {
    final tracksByPath = {
      for (final track in downloadedTracks) _trackPathKey(track.path): track,
    };
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

  Future<void> bootstrap() async {
    settings = await storage.loadSettings();
    myMusic = await storage.loadMyMusic();
    await player.setVolume(settings!.volume.clamp(0, 100).toDouble());
    downloadedTracks = await storage.loadDownloadedTracks();
    downloadTasks = await storage.loadDownloadTasks();
    await _restoreDownloadTasks();
    final savedQueue = await storage.loadPlayerQueue();
    queue = savedQueue.items;
    currentQueueIndex = savedQueue.normalizedCurrentIndex;
    shuffleEnabled = savedQueue.shuffleEnabled;
    selectedIndex = settings!.defaultStartupPageIndex == 2 ? 2 : 0;
    final startupItem = settings!.autoPlayOnStartup ? currentItem : null;
    isReady = true;
    AppLog.instance.info(
      'bootstrap',
      '应用数据加载完成',
      detail:
          'tracks=${downloadedTracks.length}, queue=${queue.length}, '
          'downloads=${downloadTasks.length}',
    );
    notifyListeners();
    unawaited(_syncAndroidMediaControls(force: true));
    unawaited(_hydrateDownloadedTracksInBackground());
    _scheduleDownloads();
    if (startupItem != null) {
      unawaited(player.open(startupItem));
    }
  }

  void _handlePlayerChanged() {
    unawaited(_syncAndroidMediaControls());
    notifyListeners();
  }

  void _handlePlayerPositionChanged() {
    unawaited(_syncAndroidMediaControls());
  }

  Future<void> _handleAndroidMediaControl(
    String action,
    Duration? position,
  ) async {
    switch (action) {
      case 'play':
        await _playCurrentItem();
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

  @visibleForTesting
  Future<void> handleBluetoothAudioRouteChanged() async {
    if (!player.isPlaying) {
      AppLog.instance.info('bluetooth', '蓝牙音频路由变化，当前未播放');
      return;
    }
    AppLog.instance.info('bluetooth', '蓝牙音频断开或切换，自动暂停播放');
    await player.pause();
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

  @override
  void dispose() {
    _isDisposed = true;
    for (final token in _cancelTokens.values) {
      token.cancel('disposed');
    }
    unawaited(_persistDownloadTasksBestEffort());
    AndroidMediaControlsService.setHandler(null);
    AudioRouteService.setBluetoothRouteChangedHandler(null);
    unawaited(AndroidMediaControlsService.hide());
    _settingsSaveDebounce?.cancel();
    player.onChanged = null;
    player.positionListenable.removeListener(_handlePlayerPositionChanged);
    player.onCompleted = null;
    _downloadProgressListenable.dispose();
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
