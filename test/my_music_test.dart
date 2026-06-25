import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/app_controller.dart';
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/player_service.dart';
import 'package:qingting/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('serializes favorites playlists and recent playback', () {
    final data = MyMusicData(
      favoriteTrackPaths: const ['C:\\Music\\favorite.mp3'],
      playlists: [
        MusicPlaylist(
          id: 'playlist-1',
          name: '通勤',
          trackPaths: const ['C:\\Music\\favorite.mp3'],
          createdAt: DateTime(2026, 6, 24),
        ),
      ],
      recentPlaybacks: [
        RecentPlayback(
          trackPath: 'C:\\Music\\favorite.mp3',
          playedAt: DateTime(2026, 6, 24, 20, 30),
        ),
      ],
    );

    final restored = MyMusicData.fromJson(data.toJson());

    expect(restored.favoriteTrackPaths, data.favoriteTrackPaths);
    expect(restored.playlists.single.name, '通勤');
    expect(restored.playlists.single.trackPaths, data.favoriteTrackPaths);
    expect(
      restored.recentPlaybacks.single.trackPath,
      data.favoriteTrackPaths.single,
    );
  });

  test('manages favorites playlists and recent playback together', () async {
    final storage = _FakeStorageService();
    final player = _FakePlaybackService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: storage,
      player: player,
    );
    final track = DownloadedTrack(
      id: 'song-1',
      title: 'Song',
      artist: 'Artist',
      path: 'C:\\Music\\song.mp3',
      format: 'mp3',
      downloadedAt: DateTime(2026, 6, 24),
      sourceUrl: '',
    );
    controller.downloadedTracks = [track];

    await controller.toggleFavorite(track);
    expect(controller.globalMessage, '已添加到我喜欢：Song');
    final playlist = await controller.createPlaylist('通勤');
    expect(controller.globalMessage, '已创建歌单：通勤');
    await controller.setTrackInPlaylist(playlist!.id, track, included: true);
    expect(controller.globalMessage, '已将“Song”加入歌单“通勤”');
    controller.queue = [
      const PlayerItem(
        id: 'song-1',
        title: 'Song',
        artist: 'Artist',
        uri: 'file:///C:/Music/song.mp3',
        localPath: 'C:\\Music\\song.mp3',
      ),
    ];

    await controller.playQueueAt(0);

    expect(controller.favoriteTracks, [track]);
    expect(controller.tracksForPlaylist(playlist.id), [track]);
    expect(controller.recentTracks, [track]);
    expect(storage.savedMyMusic.recentPlaybacks, hasLength(1));

    await controller.removeDownloadedRecord(track);

    expect(controller.favoriteTracks, isEmpty);
    expect(controller.tracksForPlaylist(playlist.id), isEmpty);
    expect(controller.recentTracks, isEmpty);

    controller.dispose();
  });

  test('uses a readable Chinese fallback for unnamed playlists', () {
    final playlist = MusicPlaylist.fromJson({
      'id': 'playlist-unnamed',
      'trackPaths': <String>[],
    });

    expect(playlist.name, '未命名歌单');
  });
}

class _FakeStorageService extends StorageService {
  MyMusicData savedMyMusic = const MyMusicData();

  @override
  Future<void> saveMyMusic(MyMusicData data) async {
    savedMyMusic = data;
  }

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {}

  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {}
}

class _FakePlaybackService implements PlaybackService {
  final ValueNotifier<Duration> _positionListenable = ValueNotifier(
    Duration.zero,
  );

  @override
  VoidCallback? onChanged;

  @override
  VoidCallback? onCompleted;

  @override
  bool isPlaying = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = Duration.zero;

  @override
  ValueListenable<Duration> get positionListenable => _positionListenable;

  @override
  bool isOpened(PlayerItem item) => false;

  @override
  Future<void> open(PlayerItem item) async {
    isPlaying = true;
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
  }

  @override
  Future<void> play() async {
    isPlaying = true;
  }

  @override
  Future<void> playOrPause() async {
    isPlaying = !isPlaying;
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

class _FakeMusicSource implements MusicSource {
  @override
  String get name => 'fake';

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) {
    throw UnimplementedError();
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) {
    throw UnimplementedError();
  }

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) {
    throw UnimplementedError();
  }
}
