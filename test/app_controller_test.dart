import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/app_controller.dart';
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
