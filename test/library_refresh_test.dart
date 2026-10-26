import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qingting/anyshare_auth.dart';
import 'package:qingting/anyshare_client.dart';
import 'package:qingting/app_controller.dart';
import 'package:qingting/cloud_sync_service.dart';
import 'package:qingting/id3_lyrics_embedder.dart';
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/pending_album_match.dart';
import 'package:qingting/player_service.dart';
import 'package:qingting/song_metadata.dart';
import 'package:qingting/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory music;
  late StorageService storage;
  late _Player player;
  late AppController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qingting-library-refresh-');
    music = await Directory(p.join(root.path, 'music')).create();
    storage = StorageService(
      supportDirectory: Directory(p.join(root.path, 'data')),
    );
    player = _Player();
  });
  tearDown(() async {
    controller.dispose();
    await controller.flushPendingWrites();
    await root.delete(recursive: true);
  });

  AppController create({
    CloudSyncService? cloud,
    StorageService? customStorage,
  }) {
    controller = AppController(
      source: _Source(),
      storage: customStorage ?? storage,
      player: player,
      cloudSyncService: cloud,
    );
    controller.settings = AppSettings(
      downloadDirectory: music.path,
      cloudFolderId: 'root',
    );
    controller.cloudConnected = true;
    return controller;
  }

  DownloadedTrack track(String name, {String? path}) => DownloadedTrack(
    id: name,
    title: name,
    artist: 'Artist',
    path: path ?? p.join(music.path, '$name.m4a'),
    format: 'm4a',
    downloadedAt: DateTime(2026),
    sourceUrl: 'https://example.test/$name',
  );
  PlayerItem item(DownloadedTrack track) => PlayerItem(
    id: track.id,
    title: track.title,
    artist: track.artist,
    uri: File(track.path).uri.toString(),
    localPath: track.path,
  );

  test(
    'scan removes missing records and collection references even with no new songs',
    () async {
      create();
      final keep = track('keep'), gone = track('gone');
      final outside = track(
        'outside',
        path: p.join(root.path, 'other', 'outside.m4a'),
      );
      await File(keep.path).writeAsBytes([1, 2, 3]);
      controller.downloadedTracks = [gone, keep, outside];
      controller.myMusic = MyMusicData(
        favoriteTrackPaths: [gone.path, keep.path],
        playlists: [
          MusicPlaylist(
            id: 'playlist',
            name: 'Playlist',
            trackPaths: [gone.path, keep.path],
            createdAt: DateTime(2026),
          ),
        ],
        recentPlaybacks: [
          RecentPlayback(trackPath: gone.path, playedAt: DateTime(2026)),
        ],
      );
      controller.pendingAlbumMatches = [
        PendingAlbumMatch(
          trackId: gone.id,
          trackPath: gone.path,
          title: gone.title,
          artist: gone.artist,
          candidates: [],
        ),
      ];
      controller.queue = [item(gone), item(keep)];
      controller.currentQueueIndex = 0;
      player.isPlaying = true;
      controller.libraryQuery = 'gone';
      expect(controller.visibleDownloadedTracks, [gone]);
      expect(controller.favoriteTracks, [gone, keep]);

      expect(await controller.scanCurrentDownloadDirectory(), 0);
      expect(controller.downloadedTracks, [keep, outside]);
      expect(controller.visibleDownloadedTracks, isEmpty);
      expect(controller.favoriteTracks, [keep]);
      expect(controller.tracksForPlaylist('playlist'), [keep]);
      expect(controller.recentTracks, isEmpty);
      expect(controller.pendingAlbumMatches, isEmpty);
      expect(controller.queue.single.localPath, keep.path);
      expect(controller.currentQueueIndex, 0);
      expect(player.stops, 1);
      expect((await storage.loadDownloadedTracks()).map((track) => track.id), [
        'keep',
        'outside',
      ]);
      expect((await storage.loadMyMusic()).favoriteTrackPaths, [keep.path]);
      expect(
        (await storage.loadPlayerQueue()).items.single.localPath,
        keep.path,
      );
      expect(controller.globalMessage, contains('清理 1 首'));
    },
  );

  test(
    'scan imports additions and removes deleted files in one refresh',
    () async {
      create();
      controller.downloadedTracks = [track('gone')];
      final added = await File(
        p.join(music.path, 'Artist - added.m4a'),
      ).writeAsBytes([1]);
      expect(await controller.scanCurrentDownloadDirectory(), 1);
      expect(controller.downloadedTracks.single.path, added.path);
      expect((await storage.loadDownloadedTracks()).single.path, added.path);
    },
  );

  test(
    'a scan with no file changes still refreshes cached views and notifies completion',
    () async {
      create();
      final keep = track('keep');
      await File(keep.path).writeAsBytes([1]);
      controller.downloadedTracks = [keep];
      final before = controller.visibleDownloadedTracks;
      var completed = false;
      controller.addListener(() {
        if (!controller.isScanningDownloadDirectory) completed = true;
      });
      expect(await controller.scanCurrentDownloadDirectory(), 0);
      expect(controller.visibleDownloadedTracks, [keep]);
      expect(identical(before, controller.visibleDownloadedTracks), isFalse);
      expect(completed, isTrue);
    },
  );

  test(
    'an unavailable download directory does not erase library records',
    () async {
      create();
      final keep = track('keep');
      controller.downloadedTracks = [keep];
      await music.delete();
      expect(await controller.scanCurrentDownloadDirectory(), 0);
      expect(controller.downloadedTracks, [keep]);
      expect(controller.globalMessage, contains('目录不存在'));
    },
  );

  test(
    'scan retains a record whose missing file belongs to an unfinished download',
    () async {
      create();
      final pending = track('pending');
      controller.downloadedTracks = [pending];
      controller.downloadTasks = [
        DownloadTask(
          id: 'pending',
          track: pending.toTrackResult(),
          candidate: const AudioCandidate(
            url: 'https://example.test/song.m4a',
            format: 'm4a',
          ),
          status: DownloadStatus.paused,
          progress: 0,
          savePath: pending.path,
        ),
      ];
      expect(await controller.scanCurrentDownloadDirectory(), 0);
      expect(controller.downloadedTracks, [pending]);
    },
  );

  for (final fails in [false, true]) {
    test(
      'sync refreshes stale local records even when its deletion list is empty (failure=$fails)',
      () async {
        final cloud = _Cloud();
        create(cloud: cloud);
        final gone = track('gone');
        await File(gone.path).writeAsBytes([1]);
        controller.downloadedTracks = [gone];
        expect(controller.visibleDownloadedTracks, [gone]);
        final syncing = controller.syncCloud();
        await cloud.started.future;
        await File(gone.path).delete();
        if (fails) {
          cloud.result.completeError(
            StateError('sync interrupted after deletion'),
          );
        } else {
          cloud.result.complete(
            const CloudSyncResult(uploaded: 0, downloaded: 0, skipped: 0),
          );
        }
        await syncing;
        expect(controller.downloadedTracks, isEmpty);
        expect(controller.visibleDownloadedTracks, isEmpty);
        expect(await storage.loadDownloadedTracks(), isEmpty);
        expect(controller.isCloudSyncing, isFalse);
        expect(
          controller.cloudSyncError,
          fails ? contains('sync interrupted') : isNull,
        );
      },
    );
  }

  test(
    'flushing writes waits for a pending directory scan to save its result',
    () async {
      final blocked = _BlockedStorage(Directory(p.join(root.path, 'data')));
      create(customStorage: blocked);
      final file = File(p.join(music.path, 'covered.mp3'));
      await file.writeAsBytes(
        Id3LyricsEmbedder.embedMetadataBytes(
          [255, 251, 144, 100],
          cover: Id3CoverImage(
            mimeType: 'image/png',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
      );
      final scanning = controller.scanCurrentDownloadDirectory();
      await blocked.started.future;
      var flushed = false;
      final flushing = controller.flushPendingWrites().then(
        (_) => flushed = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      blocked.release.complete();
      await scanning;
      await flushing;
      expect((await blocked.loadDownloadedTracks()).single.path, file.path);
    },
  );

  test(
    'sync waits for an earlier manual scan and then scans the completed sync again',
    () async {
      final blocked = _BlockedStorage(Directory(p.join(root.path, 'data')));
      final cloud = _Cloud();
      create(cloud: cloud, customStorage: blocked);
      final gone = track('gone');
      await File(gone.path).writeAsBytes([1]);
      controller.downloadedTracks = [gone];
      final covered = File(p.join(music.path, 'covered.mp3'));
      await covered.writeAsBytes(
        Id3LyricsEmbedder.embedMetadataBytes(
          [255, 251, 144, 100],
          cover: Id3CoverImage(
            mimeType: 'image/png',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
      );
      final scanning = controller.scanCurrentDownloadDirectory();
      await blocked.started.future;
      final syncing = controller.syncCloud();
      await cloud.started.future;
      await File(gone.path).delete();
      final added = await File(
        p.join(music.path, 'cloud.m4a'),
      ).writeAsBytes([1]);
      cloud.result.complete(
        const CloudSyncResult(uploaded: 0, downloaded: 1, skipped: 0),
      );
      blocked.release.complete();
      await scanning;
      await syncing;
      expect(
        controller.downloadedTracks.map((track) => track.path),
        unorderedEquals([covered.path, added.path]),
      );
      expect(controller.isScanningDownloadDirectory, isFalse);
      expect(controller.isCloudSyncing, isFalse);
    },
  );
}

class _Player extends Fake implements PlaybackService {
  final _position = ValueNotifier(Duration.zero);
  @override
  VoidCallback? onChanged;
  @override
  VoidCallback? onCompleted;
  @override
  bool isPlaying = false;
  int stops = 0;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  ValueListenable<Duration> get positionListenable => _position;
  @override
  bool isOpened(PlayerItem item) => false;
  @override
  Future<void> stop() async {
    stops++;
    isPlaying = false;
  }

  @override
  Future<void> dispose() async => _position.dispose();
}

class _Source extends Fake implements MusicSource {
  @override
  String get name => 'test';
}

class _Cloud extends CloudSyncService {
  _Cloud() : super(client: AnyShareClient(auth: AnyShareAuth()));
  final started = Completer<void>();
  final result = Completer<CloudSyncResult>();
  @override
  Future<CloudSyncResult> sync({
    required String cloudFolderId,
    required Directory localDirectory,
    Set<String> skipPaths = const {},
    Map<String, DateTime> downloadedAtByPath = const {},
    bool preferLocalOrder = false,
    Set<String>? onlyPaths,
    void Function(CloudSyncProgress)? onProgress,
    void Function(bool)? onDeletionPolicyLoaded,
    bool Function()? shouldStop,
    Future<LocalSongMetadata?> Function(String)? readLocalMetadata,
    Set<String> deferFilePaths = const {},
  }) {
    started.complete();
    return result.future;
  }
}

class _BlockedStorage extends StorageService {
  _BlockedStorage(Directory support) : super(supportDirectory: support);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String> cacheCoverImage(
    Id3CoverImage cover, {
    required String cacheKey,
  }) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return super.cacheCoverImage(cover, cacheKey: cacheKey);
  }
}
