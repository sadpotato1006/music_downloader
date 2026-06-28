import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/album_metadata_service.dart';
import 'package:qingting/app_controller.dart';
import 'package:qingting/lyrics_service.dart';
import 'package:qingting/main.dart' as app;
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/player_service.dart';
import 'package:qingting/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('first play toggle opens a restored queue item', () async {
    final player = _FakePlaybackService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: player,
    );
    const item = PlayerItem(
      id: 'restored-track',
      title: 'Restored Track',
      artist: 'Artist',
      uri: 'https://example.test/audio.mp3',
    );
    controller.queue = [item];
    controller.currentQueueIndex = 0;

    await controller.togglePlayPause();

    expect(player.openCalls, 1);
    expect(player.playOrPauseCalls, 0);
    expect(player.openedItem, same(item));

    await controller.togglePlayPause();

    expect(player.openCalls, 1);
    expect(player.playOrPauseCalls, 1);

    controller.dispose();
  });

  test('switches music source and repeats the current search', () async {
    final sourceA = _SearchMusicSource('source-a', '来源 A');
    final sourceB = _SearchMusicSource('source-b', '来源 B');
    final controller = AppController(
      source: sourceA,
      sources: [sourceA, sourceB],
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );

    await controller.search('晴天');
    await controller.switchToNextSource();

    expect(controller.source, same(sourceB));
    expect(controller.searchResults.single.source, '来源 B');
    expect(sourceA.searchCalls, 1);
    expect(sourceB.searchCalls, 1);

    controller.dispose();
  });

  test('prevents adding the same track to the download queue twice', () async {
    final source = _PlayableMusicSource();
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    final result = source.result;
    controller.downloadTasks = [
      DownloadTask(
        id: 'existing-task',
        track: result,
        candidate: const AudioCandidate(
          url: 'https://example.test/song.mp3',
          format: 'mp3',
        ),
        status: DownloadStatus.downloading,
        progress: 0.5,
        savePath: 'song.mp3',
      ),
    ];

    final start = await controller.startDownload(result);

    expect(start.didFail, isTrue);
    expect(start.message, contains('已在下载队列中'));
    expect(source.loadCalls, 0);
    controller.dispose();
  });

  test('bootstrap restores a saved disabled shuffle mode', () async {
    const item = PlayerItem(
      id: 'saved-item',
      title: 'Saved Song',
      artist: 'Saved Artist',
      uri: 'https://example.test/saved.mp3',
    );
    final storage = _BootstrapStorageService(
      queue: const SavedPlayerQueue(
        items: [item],
        currentIndex: 0,
        shuffleEnabled: false,
      ),
    );
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: storage,
      player: _FakePlaybackService(),
    );

    await controller.bootstrap();

    expect(controller.shuffleEnabled, isFalse);
    controller.dispose();
  });

  test('bootstrap pauses an interrupted persisted download', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-restored-download-',
    );
    final savePath = '${directory.path}${Platform.pathSeparator}partial.m4a';
    await File(savePath).writeAsBytes(const [1, 2, 3]);
    final source = _AlbumDownloadMusicSource();
    final interrupted = DownloadTask(
      id: 'interrupted-task',
      track: source.result,
      candidate: const AudioCandidate(
        url: 'https://example.test/test.m4a',
        format: 'm4a',
      ),
      status: DownloadStatus.downloading,
      progress: 0.1,
      savePath: savePath,
      receivedBytes: 1,
      totalBytes: 6,
    );
    final storage = _BootstrapStorageService(tasks: [interrupted]);
    final controller = AppController(
      source: source,
      storage: storage,
      player: _FakePlaybackService(),
    );

    try {
      await controller.bootstrap();

      final restored = controller.downloadTasks.single;
      expect(restored.status, DownloadStatus.paused);
      expect(restored.receivedBytes, 3);
      expect(restored.progress, 0.5);
      expect(storage.savedTasks.single.status, DownloadStatus.paused);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('resume download appends a valid HTTP range response', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-range-download-',
    );
    final savePath = '${directory.path}${Platform.pathSeparator}resume.m4a';
    await File(savePath).writeAsBytes(const [1, 2, 3]);
    final source = _AlbumDownloadMusicSource();
    final adapter = _RangeAudioDownloadAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final controller = AppController(
      source: source,
      storage: _DownloadStorageService(savePath),
      player: _FakePlaybackService(),
      downloadDio: dio,
      albumMetadata: _RecordingAlbumMetadataService(),
    );
    controller.downloadTasks = [
      DownloadTask(
        id: 'range-task',
        track: source.result,
        candidate: const AudioCandidate(
          url: 'https://example.test/test.m4a',
          format: 'm4a',
        ),
        status: DownloadStatus.paused,
        progress: 0.5,
        savePath: savePath,
        receivedBytes: 3,
        totalBytes: 6,
      ),
    ];

    try {
      controller.retryDownload('range-task');
      for (var attempt = 0; attempt < 100; attempt += 1) {
        final status = controller.downloadTasks.single.status;
        if (status == DownloadStatus.completed ||
            status == DownloadStatus.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final task = controller.downloadTasks.single;
      expect(task.status, DownloadStatus.completed, reason: task.error);
      expect(adapter.rangeHeader, 'bytes=3-');
      expect(await File(savePath).readAsBytes(), const [1, 2, 3, 4, 5, 6]);
      expect(task.resumeValidator, '"range-etag"');
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('resume download overwrites when the server ignores range', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-range-fallback-',
    );
    final savePath = '${directory.path}${Platform.pathSeparator}fallback.m4a';
    await File(savePath).writeAsBytes(const [1, 2, 3]);
    final source = _AlbumDownloadMusicSource();
    final adapter = _RangeAudioDownloadAdapter(
      statusCode: 200,
      payload: const [7, 8],
      contentRange: null,
    );
    final controller = AppController(
      source: source,
      storage: _DownloadStorageService(savePath),
      player: _FakePlaybackService(),
      downloadDio: Dio()..httpClientAdapter = adapter,
      albumMetadata: _RecordingAlbumMetadataService(),
    );
    controller.downloadTasks = [
      DownloadTask(
        id: 'range-fallback-task',
        track: source.result,
        candidate: const AudioCandidate(
          url: 'https://example.test/test.m4a',
          format: 'm4a',
        ),
        status: DownloadStatus.paused,
        progress: 0.5,
        savePath: savePath,
        receivedBytes: 3,
        totalBytes: 6,
      ),
    ];

    try {
      controller.retryDownload('range-fallback-task');
      for (var attempt = 0; attempt < 100; attempt += 1) {
        final status = controller.downloadTasks.single.status;
        if (status == DownloadStatus.completed ||
            status == DownloadStatus.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final task = controller.downloadTasks.single;
      expect(task.status, DownloadStatus.completed, reason: task.error);
      expect(adapter.rangeHeader, 'bytes=3-');
      expect(await File(savePath).readAsBytes(), const [7, 8]);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test(
    'download replaces a source album with the default Apple match',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-album-match-',
      );
      final savePath =
          '${directory.path}${Platform.pathSeparator}album-match.m4a';
      final source = _AlbumDownloadMusicSource();
      final albumMetadata = _RecordingAlbumMetadataService();
      final dio = Dio()..httpClientAdapter = const _AudioDownloadAdapter();
      final controller = AppController(
        source: source,
        storage: _DownloadStorageService(savePath),
        player: _FakePlaybackService(),
        downloadDio: dio,
        albumMetadata: albumMetadata,
      );

      try {
        final start = await controller.startDownload(
          source.result,
          allowNonMp3: true,
        );
        expect(start.didStart, isTrue);

        for (var attempt = 0; attempt < 100; attempt += 1) {
          final status = controller.downloadTasks.single.status;
          if (status == DownloadStatus.completed ||
              status == DownloadStatus.failed) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final task = controller.downloadTasks.single;
        expect(task.status, DownloadStatus.completed, reason: task.error);
        expect(albumMetadata.calls, 1);
        expect(
          albumMetadata.receivedDuration,
          const Duration(minutes: 3, seconds: 20),
        );
        expect(task.album, 'Apple Album');
        expect(controller.downloadedTracks.single.album, 'Apple Album');
      } finally {
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('online playback resolves lyrics and reports playback state', () async {
    final source = _PlayableMusicSource();
    final player = _FakePlaybackService();
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: player,
      lyricsService: _FakeLyricsService(),
    );

    await controller.playSearchResult(source.result);

    expect(player.openCalls, 1);
    expect(player.openedItem?.uri, 'https://example.test/generated.mp3');
    expect(player.openedItem?.lyrics, contains('[00:01.00]测试歌词'));
    expect(controller.globalMessage, '已开始播放：测试歌曲');
    controller.dispose();
  });

  test('pauses only when bluetooth changes during playback', () async {
    final player = _FakePlaybackService()..isPlaying = true;
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: player,
    );

    await controller.handleBluetoothAudioRouteChanged();

    expect(player.pauseCalls, 1);
    expect(player.isPlaying, isFalse);

    await controller.handleBluetoothAudioRouteChanged();

    expect(player.pauseCalls, 1);
    controller.dispose();
  });

  testWidgets('clicking source search history starts a search', (tester) async {
    final source = _SearchMusicSource('source-a', '来源 A');
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    controller.settings = const AppSettings(
      downloadDirectory: '',
      sourceSearchHistory: ['晴天'],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.SearchPage(controller: controller)),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final historyItem = find.text('晴天');
    expect(historyItem, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(historyItem));
    await tester.pump();
    expect(historyItem, findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(source.searchCalls, 1);
    expect(source.lastKeyword, '晴天');
    controller.dispose();
  });
}

class _FakePlaybackService implements PlaybackService {
  final ValueNotifier<Duration> _positionListenable = ValueNotifier(
    Duration.zero,
  );

  @override
  VoidCallback? onChanged;

  @override
  VoidCallback? onCompleted;

  PlayerItem? openedItem;
  int openCalls = 0;
  int playOrPauseCalls = 0;
  int pauseCalls = 0;

  @override
  bool isPlaying = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = Duration.zero;

  @override
  ValueListenable<Duration> get positionListenable => _positionListenable;

  @override
  bool isOpened(PlayerItem item) {
    final opened = openedItem;
    return opened != null && opened.id == item.id && opened.uri == item.uri;
  }

  @override
  Future<void> open(PlayerItem item) async {
    openCalls += 1;
    openedItem = item;
    isPlaying = true;
  }

  @override
  Future<void> play() async {
    isPlaying = true;
  }

  @override
  Future<void> playOrPause() async {
    playOrPauseCalls += 1;
    isPlaying = !isPlaying;
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    isPlaying = false;
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
    _positionListenable.value = value;
  }

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> stop() async {
    isPlaying = false;
  }

  @override
  Future<void> dispose() async {
    _positionListenable.dispose();
  }
}

class _FakeStorageService extends StorageService {
  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {}

  @override
  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {}
}

class _BootstrapStorageService extends _FakeStorageService {
  _BootstrapStorageService({
    this.queue = const SavedPlayerQueue(items: [], currentIndex: -1),
    this.tasks = const [],
  });

  final SavedPlayerQueue queue;
  final List<DownloadTask> tasks;
  List<DownloadTask> savedTasks = const [];

  @override
  Future<AppSettings> loadSettings() async {
    return const AppSettings(downloadDirectory: '');
  }

  @override
  Future<MyMusicData> loadMyMusic() async => const MyMusicData();

  @override
  Future<List<DownloadedTrack>> loadDownloadedTracks() async => const [];

  @override
  Future<SavedPlayerQueue> loadPlayerQueue() async => queue;

  @override
  Future<List<DownloadTask>> loadDownloadTasks() async => tasks;

  @override
  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {
    savedTasks = List<DownloadTask>.from(tasks);
  }
}

class _DownloadStorageService extends _FakeStorageService {
  _DownloadStorageService(this.savePath);

  final String savePath;

  @override
  Future<String> uniqueSavePath({
    required String downloadDirectory,
    required String title,
    required String artist,
    required String format,
  }) async => savePath;

  @override
  Future<String?> cacheEmbeddedCover(
    File audioFile, {
    required String cacheKey,
  }) async => null;

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {}
}

class _RecordingAlbumMetadataService extends AlbumMetadataService {
  int calls = 0;
  Duration? receivedDuration;

  @override
  Future<AlbumMetadataMatch?> findBestAlbum({
    required String title,
    required String artist,
    String? lyrics,
    Duration? duration,
  }) async {
    calls += 1;
    receivedDuration = duration;
    return const AlbumMetadataMatch(
      album: 'Apple Album',
      recordingTitle: 'Test Song',
      recordingArtist: 'Test Artist',
      score: 96,
      recordingId: 'apple:track-1',
      releaseId: 'apple:album-1',
    );
  }
}

class _AudioDownloadAdapter implements HttpClientAdapter {
  const _AudioDownloadAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      Uint8List.fromList(const [0, 0, 0, 20, 102, 116, 121, 112]),
      200,
      headers: {
        Headers.contentLengthHeader: ['8'],
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RangeAudioDownloadAdapter implements HttpClientAdapter {
  _RangeAudioDownloadAdapter({
    this.statusCode = 206,
    this.payload = const [4, 5, 6],
    this.contentRange = 'bytes 3-5/6',
  });

  final int statusCode;
  final List<int> payload;
  final String? contentRange;
  String? rangeHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    rangeHeader = options.headers[HttpHeaders.rangeHeader]?.toString();
    return ResponseBody.fromBytes(
      Uint8List.fromList(payload),
      statusCode,
      headers: {
        Headers.contentLengthHeader: ['${payload.length}'],
        if (contentRange != null) 'content-range': [contentRange!],
        'etag': ['"range-etag"'],
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _AlbumDownloadMusicSource implements MusicSource {
  TrackSearchResult get result => const TrackSearchResult(
    id: 'album-download',
    title: 'Test Song',
    artist: 'Test Artist',
    source: 'album-download-source',
    detailUrl: 'https://example.test/detail',
    duration: '3:20',
    album: 'Site Album',
  );

  @override
  String get name => 'album-download-source';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    return [result];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    return TrackDetail(
      title: result.title,
      artist: result.artist,
      sourceUrl: result.detailUrl,
      candidates: const [],
      rawMetadata: const {},
      album: 'Site Album',
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    return const [
      AudioCandidate(url: 'https://example.test/test.m4a', format: 'm4a'),
    ];
  }
}

class _FakeMusicSource implements MusicSource {
  @override
  String get name => 'fake';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) {
    throw UnimplementedError();
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) {
    throw UnimplementedError();
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) {
    throw UnimplementedError();
  }
}

class _SearchMusicSource implements MusicSource {
  _SearchMusicSource(this.sourceId, this.name);

  final String sourceId;

  @override
  final String name;

  int searchCalls = 0;
  String? lastKeyword;

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    searchCalls += 1;
    lastKeyword = keyword;
    return [
      TrackSearchResult(
        id: '$sourceId-$keyword',
        title: keyword,
        artist: '测试歌手',
        source: name,
        detailUrl: 'https://example.test/$sourceId.mp3',
      ),
    ];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) {
    throw UnimplementedError();
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) {
    throw UnimplementedError();
  }
}

class _PlayableMusicSource implements MusicSource {
  int loadCalls = 0;

  TrackSearchResult get result => const TrackSearchResult(
    id: 'playable-track',
    title: '测试歌曲',
    artist: '测试歌手',
    source: 'playable',
    detailUrl: 'https://example.test/detail',
    duration: '3:20',
  );

  @override
  String get name => 'playable';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    return [result];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    loadCalls += 1;
    return TrackDetail(
      title: result.title,
      artist: result.artist,
      sourceUrl: result.detailUrl,
      candidates: const [],
      rawMetadata: const {},
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    return const [
      AudioCandidate(url: 'https://example.test/generated.mp3', format: 'mp3'),
    ];
  }
}

class _FakeLyricsService extends LyricsService {
  @override
  Future<String?> findLyrics({
    required String title,
    required String artist,
    Duration? duration,
  }) async {
    expect(duration, const Duration(minutes: 3, seconds: 20));
    return '[00:01.00]测试歌词';
  }
}
