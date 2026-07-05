import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/app_controller.dart';
import 'package:qingting/file_deletion_service.dart';
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

  test('deleting a downloaded track removes its file and record', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-delete-track-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
    await file.writeAsBytes(const [1, 2, 3]);
    final storage = _FakeStorageService();
    final fileDeletion = _FakeFileDeletionService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: storage,
      player: _FakePlaybackService(),
      fileDeletionService: fileDeletion,
    );
    final track = DownloadedTrack(
      id: 'delete-song',
      title: 'Song',
      artist: 'Artist',
      path: file.path,
      format: 'mp3',
      downloadedAt: DateTime(2026, 6, 30),
      sourceUrl: '',
    );
    controller.downloadedTracks = [track];

    try {
      final deleted = await controller.deleteDownloadedTrack(track);

      expect(deleted, isTrue);
      expect(fileDeletion.deletedPaths, [file.path]);
      expect(await file.exists(), isFalse);
      expect(controller.downloadedTracks, isEmpty);
      expect(controller.globalMessage, contains('已删除歌曲文件'));
    } finally {
      controller.dispose();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test(
    'deleting the playing song stops it and advances the persisted queue',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-delete-playing-track-',
      );
      final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
      await file.writeAsBytes(const [1, 2, 3]);
      final storage = _FakeStorageService();
      final player = _FakePlaybackService();
      final fileDeletion = _FakeFileDeletionService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: player,
        fileDeletionService: fileDeletion,
      );
      final track = DownloadedTrack(
        id: 'playing-song',
        title: 'Playing Song',
        artist: 'Artist',
        path: file.path,
        format: 'mp3',
        downloadedAt: DateTime(2026, 7, 2),
        sourceUrl: '',
      );
      final playingItem = PlayerItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        uri: file.uri.toString(),
        localPath: file.path,
      );
      const nextItem = PlayerItem(
        id: 'next-song',
        title: 'Next Song',
        artist: 'Artist',
        uri: 'https://example.test/next.mp3',
      );
      controller.downloadedTracks = [track];
      controller.queue = [playingItem, nextItem, playingItem];
      controller.currentQueueIndex = 0;
      player.openedItem = playingItem;
      player.isPlaying = true;

      try {
        final deleted = await controller.deleteDownloadedTrack(track);

        expect(deleted, isTrue);
        expect(player.stopCalls, 1);
        expect(controller.queue, [nextItem]);
        expect(controller.currentQueueIndex, 0);
        expect(player.openedItem, nextItem);
        expect(player.isPlaying, isTrue);
        expect(storage.savedQueue, [nextItem]);
        expect(storage.savedQueueIndex, 0);
      } finally {
        controller.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test(
    'playback failure after deletion does not block library cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-delete-playback-failure-',
      );
      final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
      await file.writeAsBytes(const [1, 2, 3]);
      final storage = _FakeStorageService();
      final player = _FakePlaybackService()..failOpen = true;
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: player,
        fileDeletionService: _FakeFileDeletionService(),
      );
      final track = DownloadedTrack(
        id: 'playback-failure-song',
        title: 'Playback Failure Song',
        artist: 'Artist',
        path: file.path,
        format: 'mp3',
        downloadedAt: DateTime(2026, 7, 4),
        sourceUrl: '',
      );
      final playingItem = PlayerItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        uri: file.uri.toString(),
        localPath: file.path,
      );
      const nextItem = PlayerItem(
        id: 'unplayable-next',
        title: 'Unplayable Next',
        artist: 'Artist',
        uri: 'https://example.test/unplayable.mp3',
      );
      controller.downloadedTracks = [track];
      controller.myMusic = MyMusicData(favoriteTrackPaths: [file.path]);
      controller.queue = [playingItem, nextItem];
      controller.currentQueueIndex = 0;
      player.openedItem = playingItem;
      player.isPlaying = true;

      try {
        final deleted = await controller.deleteDownloadedTrack(track);

        expect(deleted, isTrue);
        expect(controller.downloadedTracks, isEmpty);
        expect(controller.myMusic.favoriteTrackPaths, isEmpty);
        expect(storage.savedDownloadedTracks, isEmpty);
        expect(storage.downloadedTrackSaveCalls, greaterThan(0));
        expect(storage.savedMyMusic.favoriteTrackPaths, isEmpty);
        expect(controller.queue, [nextItem]);
        expect(storage.savedQueue, [nextItem]);
        expect(controller.globalMessage, contains('自动接续播放下一首失败'));
      } finally {
        controller.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );

  test(
    'queue save failure does not block deleted record persistence',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-delete-queue-save-failure-',
      );
      final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
      await file.writeAsBytes(const [1, 2, 3]);
      final storage = _FailingQueueStorageService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: _FakePlaybackService(),
        fileDeletionService: _FakeFileDeletionService(),
      );
      final track = DownloadedTrack(
        id: 'queue-save-failure-song',
        title: 'Queue Save Failure Song',
        artist: 'Artist',
        path: file.path,
        format: 'mp3',
        downloadedAt: DateTime(2026, 7, 4),
        sourceUrl: '',
      );
      final item = PlayerItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        uri: file.uri.toString(),
        localPath: file.path,
      );
      controller.downloadedTracks = [track];
      controller.myMusic = MyMusicData(favoriteTrackPaths: [file.path]);
      controller.queue = [item];
      controller.currentQueueIndex = 0;

      try {
        final deleted = await controller.deleteDownloadedTrack(track);

        expect(deleted, isTrue);
        expect(storage.queueSaveCalls, 2);
        expect(controller.queue, isEmpty);
        expect(controller.downloadedTracks, isEmpty);
        expect(storage.downloadedTrackSaveCalls, greaterThan(0));
        expect(storage.savedDownloadedTracks, isEmpty);
        expect(storage.savedMyMusic.favoriteTrackPaths, isEmpty);
        expect(controller.globalMessage, contains('播放队列保存失败'));
      } finally {
        controller.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );
}

class _FakeStorageService extends StorageService {
  MyMusicData savedMyMusic = const MyMusicData();
  List<PlayerItem> savedQueue = const [];
  List<DownloadedTrack> savedDownloadedTracks = const [];
  int savedQueueIndex = -1;
  int downloadedTrackSaveCalls = 0;

  @override
  Future<void> saveMyMusic(MyMusicData data) async {
    savedMyMusic = data;
  }

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    downloadedTrackSaveCalls += 1;
    savedDownloadedTracks = List<DownloadedTrack>.from(tracks);
  }

  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {
    savedQueue = List<PlayerItem>.from(items);
    savedQueueIndex = currentIndex;
  }
}

class _FailingQueueStorageService extends _FakeStorageService {
  int queueSaveCalls = 0;

  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {
    queueSaveCalls += 1;
    throw const FileSystemException('queue save failed');
  }
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

  PlayerItem? openedItem;
  int stopCalls = 0;
  bool failOpen = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = Duration.zero;

  @override
  ValueListenable<Duration> get positionListenable => _positionListenable;

  @override
  bool isOpened(PlayerItem item) =>
      openedItem?.id == item.id && openedItem?.uri == item.uri;

  @override
  Future<void> open(PlayerItem item) async {
    if (failOpen) {
      throw StateError('player cannot open the next item');
    }
    openedItem = item;
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
    stopCalls += 1;
    isPlaying = false;
  }

  @override
  Future<void> dispose() async {
    _positionListenable.dispose();
  }
}

class _FakeFileDeletionService implements FileDeletionService {
  @override
  bool get movesFilesToRecycleBin => false;

  final List<String> deletedPaths = [];

  @override
  Future<bool> deleteFile(String path) async {
    deletedPaths.add(path);
    final file = File(path);
    if (!await file.exists()) {
      return false;
    }
    await file.delete();
    return true;
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
