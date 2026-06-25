import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
