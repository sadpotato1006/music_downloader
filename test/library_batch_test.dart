import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/app_controller.dart';
import 'package:qingting/file_deletion_service.dart';
import 'package:qingting/id3_lyrics_embedder.dart';
import 'package:qingting/main.dart' as app;
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/pending_album_match.dart';
import 'package:qingting/player_service.dart';
import 'package:qingting/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _BatchStorage storage;
  late _BatchPlayer player;
  late _BatchDeletion deletion;
  late AppController controller;
  late List<DownloadedTrack> tracks;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qingting-batch-test-');
    storage = _BatchStorage(Directory('${root.path}/state'));
    player = _BatchPlayer();
    deletion = _BatchDeletion();
    controller = AppController(
      source: _BatchSource(),
      storage: storage,
      player: player,
      fileDeletionService: deletion,
    );
    tracks = [];
    for (var i = 0; i < 3; i++) {
      final file = await File(
        '${root.path}/song-$i.mp3',
      ).writeAsBytes([1, 2, 3, i]);
      await Id3LyricsEmbedder.embedMetadata(
        file,
        title: '歌曲$i',
        artist: '歌手$i',
        album: '旧专辑',
        lyrics: '[00:01.00]歌词$i',
        cover: Id3CoverImage(
          mimeType: 'image/png',
          bytes: Uint8List.fromList([1, 2, 3, i]),
        ),
      );
      tracks.add(
        DownloadedTrack(
          id: 'song-$i',
          title: '歌曲$i',
          artist: '歌手$i',
          album: '旧专辑',
          path: file.path,
          format: 'mp3',
          sourceUrl: '',
          downloadedAt: DateTime(2026, 10, 1, 0, i),
        ),
      );
    }
    controller.downloadedTracks = [...tracks];
    controller.settings = AppSettings(downloadDirectory: root.path);
  });

  tearDown(() async {
    await controller.flushPendingWrites();
    controller.dispose();
    await controller.flushPendingWrites();
    await root.delete(recursive: true);
  });

  test('bulk favorites deduplicate paths and persist one snapshot', () async {
    controller.myMusic = MyMusicData(favoriteTrackPaths: [tracks[1].path]);
    final result = await controller.setFavoritesForTracks([
      tracks[0],
      tracks[0].copyWith(path: '${root.path}/./song-0.mp3'),
      tracks[1],
    ], favorite: true);
    expect(result.completedPaths, hasLength(2));
    expect(controller.favoriteTracks, [tracks[1], tracks[0]]);
    expect(storage.myMusicWrites, 1);
    expect(
      (await storage.loadMyMusic()).favoriteTrackPaths,
      controller.myMusic.favoriteTrackPaths,
    );
    await controller.setFavoritesForTracks(tracks.take(2), favorite: false);
    expect(controller.favoriteTracks, isEmpty);
  });

  test('bulk playlist add preserves order and supports removal', () async {
    final playlist = await controller.createPlaylist('通勤');
    await controller.setTrackInPlaylist(
      playlist!.id,
      tracks[1],
      included: true,
    );
    final writes = storage.myMusicWrites;
    await controller.setTracksInPlaylist(playlist.id, [
      tracks[0],
      tracks[1],
      tracks[2],
    ], included: true);
    expect(controller.tracksForPlaylist(playlist.id), [
      tracks[1],
      tracks[0],
      tracks[2],
    ]);
    expect(storage.myMusicWrites, writes + 1);
    await controller.setTracksInPlaylist(playlist.id, [
      tracks[1],
      tracks[2],
    ], included: false);
    expect(controller.tracksForPlaylist(playlist.id), [tracks[0]]);
  });

  test(
    'stale records fail individually and other favorites still save',
    () async {
      controller.downloadedTracks = [
        tracks[0],
        tracks[2].copyWith(id: 'replacement'),
      ];
      final result = await controller.setFavoritesForTracks(
        tracks,
        favorite: true,
      );
      expect(result.completedPaths, [tracks[0].path]);
      expect(result.failures.map((f) => f.track.path), [
        tracks[1].path,
        tracks[2].path,
      ]);
      expect(controller.favoriteTracks, [tracks[0]]);
    },
  );

  test(
    'batch album edits preserve lyrics artwork audio and ordering',
    () async {
      await Id3LyricsEmbedder.embedMetadata(
        File(tracks[0].path),
        title: '文件内的歌名',
        artist: '文件内的歌手',
      );
      final before = await File(tracks[0].path).readAsBytes();
      controller.queue = [for (final track in tracks) _item(track)];
      final result = await controller.setAlbumsForTracks(tracks, '  新专辑  ');
      expect(result.failures, isEmpty);
      expect(storage.libraryWrites, 1);
      expect(storage.queueWrites, 1);
      for (var i = 0; i < tracks.length; i++) {
        final metadata = await Id3LyricsEmbedder.extractMetadata(
          File(tracks[i].path),
        );
        expect(metadata.album, '新专辑');
        expect(metadata.lyrics, '[00:01.00]歌词$i');
        expect(metadata.cover!.bytes, [1, 2, 3, i]);
        expect(metadata.title, i == 0 ? '文件内的歌名' : '歌曲$i');
        expect(metadata.artist, i == 0 ? '文件内的歌手' : '歌手$i');
        final updated = controller.downloadedTracks[i];
        expect(updated.id, tracks[i].id);
        expect(updated.downloadedAt, tracks[i].downloadedAt);
        expect(updated.metadataDirtyFields, {'album'});
        expect(controller.queue[i].album, '新专辑');
      }
      final after = await File(tracks[0].path).readAsBytes();
      expect(
        after.sublist(after.length - 4),
        before.sublist(before.length - 4),
      );
      await controller.setAlbumsForTracks(controller.downloadedTracks, '');
      expect(controller.downloadedTracks.every((t) => t.album.isEmpty), isTrue);
      expect(
        (await Id3LyricsEmbedder.extractMetadata(File(tracks[0].path))).album,
        isNull,
      );
      expect(controller.downloadedTracks.first.metadataFillOnlyFields, isEmpty);
    },
  );

  test(
    'loaded MP3 updates immediately and defers tags until released',
    () async {
      controller.queue = [_item(tracks[0]), _item(tracks[2])];
      await controller.playQueueAt(0);
      await controller.flushPendingWrites();
      final result = await controller.setAlbumsForTracks(
        tracks.take(2),
        '播放中的新专辑',
      );
      expect(result.failures, isEmpty);
      expect(controller.currentItem!.album, '播放中的新专辑');
      expect(controller.downloadedTracks[0].metadataPendingFileWrite, isTrue);
      expect(
        (await storage.loadDownloadedTracks())[0].metadataPendingFileWrite,
        isTrue,
      );
      expect(
        (await Id3LyricsEmbedder.extractMetadata(File(tracks[0].path))).album,
        '旧专辑',
      );
      await controller.playQueueAt(1);
      await controller.flushPendingWrites();
      expect(
        (await Id3LyricsEmbedder.extractMetadata(File(tracks[0].path))).album,
        '播放中的新专辑',
      );
      expect(controller.downloadedTracks[0].metadataPendingFileWrite, isFalse);
      final written = await Id3LyricsEmbedder.extractMetadata(
        File(tracks[0].path),
      );
      expect(written.cover!.bytes, [1, 2, 3, 0]);
      expect(written.lyrics, '[00:01.00]歌词0');
    },
  );

  test('album file failure is isolated and sync blocks file changes', () async {
    await File(tracks[1].path).delete();
    final result = await controller.setAlbumsForTracks(tracks, '新专辑');
    expect(result.completedPaths, [tracks[0].path, tracks[2].path]);
    expect(result.failures.single.track, tracks[1]);
    controller.isCloudSyncing = true;
    final blocked = await controller.setAlbumsForTracks(
      controller.downloadedTracks,
      '禁止写入',
    );
    expect(blocked.failures, hasLength(3));
    expect(controller.downloadedTracks.first.album, '新专辑');
  });

  test('bulk deletion removes selected queue items and resumes once', () async {
    controller.queue = [
      for (final track in tracks) _item(track),
      _item(tracks[0]),
    ];
    await controller.playQueueAt(0);
    await controller.flushPendingWrites();
    final result = await controller.deleteDownloadedTracks(tracks.take(2));
    expect(result.failures, isEmpty);
    expect(deletion.calls, [tracks[0].path, tracks[1].path]);
    expect(controller.downloadedTracks.map((t) => t.id), [tracks[2].id]);
    expect(controller.queue.map((t) => t.id), [tracks[2].id]);
    expect(player.opens, [tracks[0].id, tracks[2].id]);
    expect(player.isPlaying, isTrue);
  });

  test(
    'deletion continues after a failed file and preserves its collections',
    () async {
      deletion.failedPaths.add(tracks[1].path);
      controller.myMusic = MyMusicData(
        favoriteTrackPaths: tracks.map((t) => t.path).toList(),
      );
      final result = await controller.deleteDownloadedTracks(tracks);
      expect(result.completedPaths, [tracks[0].path, tracks[2].path]);
      expect(result.failures.single.track.path, tracks[1].path);
      expect(controller.favoriteTracks, [tracks[1]]);
      expect(await File(tracks[1].path).exists(), isTrue);
    },
  );

  test('record-only removal preserves files and queue', () async {
    controller.queue = tracks.map(_item).toList();
    controller.myMusic = MyMusicData(
      favoriteTrackPaths: tracks.map((t) => t.path).toList(),
    );
    final result = await controller.removeDownloadedRecords(tracks.take(2));
    expect(result.failures, isEmpty);
    expect(controller.downloadedTracks, [tracks[2]]);
    expect(controller.favoriteTracks, [tracks[2]]);
    expect(controller.queue, hasLength(3));
    expect(deletion.calls, isEmpty);
    expect(tracks.every((t) => File(t.path).existsSync()), isTrue);
    expect(storage.libraryWrites, 1);
  });

  test(
    'overlapping batches are rejected and shutdown and sync await the batch',
    () async {
      deletion.gate = Completer<void>();
      final running = controller.deleteDownloadedTracks(tracks.take(2));
      await Future<void>.delayed(Duration.zero);
      expect(controller.isLibraryBatchRunning, isTrue);
      final overlapping = await controller.setFavoritesForTracks(
        tracks,
        favorite: true,
      );
      expect(overlapping.failures, hasLength(3));
      var flushed = false, synced = false;
      final flush = controller.flushPendingWrites().then((_) => flushed = true);
      final sync = controller.syncCloud().then((_) => synced = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      expect(synced, isFalse);
      deletion.gate!.complete();
      await running;
      await Future.wait([flush, sync]);
      expect(controller.isLibraryBatchRunning, isFalse);
      expect(controller.libraryBatchCompleted, 2);
    },
  );

  test(
    'transient saves retry and persistent failures remain visible',
    () async {
      storage.failedMusicWrites = 1;
      final recovered = await controller.setFavoritesForTracks(
        tracks,
        favorite: true,
      );
      expect(recovered.warnings, isEmpty);
      expect(storage.myMusicWrites, 2);
      storage.failedMusicWrites = 2;
      final failed = await controller.setFavoritesForTracks(
        tracks,
        favorite: false,
      );
      expect(failed.warnings.single, contains('保存失败'));
      expect(controller.globalMessage, contains('保存失败'));
    },
  );

  Future<void> pumpLibrary(
    WidgetTester tester, {
    Size size = const Size(390, 760),
  }) async {
    storage.persist = false;
    if (const bool.fromEnvironment('BATCH_SCREENSHOT')) {
      await tester.runAsync(() async {
        final chinese = File('C:/Windows/Fonts/msyh.ttc');
        if (await chinese.exists()) {
          final loader = FontLoader('BatchPreview')
            ..addFont(
              chinese.readAsBytes().then(
                (bytes) => ByteData.sublistView(bytes),
              ),
            );
          await loader.load();
        }
        final icons = File(
            '.tooling/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        );
        if (await icons.exists()) {
          final loader = FontLoader('MaterialIcons')
            ..addFont(
              icons.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
          await loader.load();
        }
      });
    }
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: const bool.fromEnvironment('BATCH_SCREENSHOT')
              ? 'BatchPreview'
              : null,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8FD9A8)),
        ),
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('batch-preview'),
              child: ColoredBox(
                color: const Color(0xFFF7FAF8),
                child: app.LibraryPage(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  Future<void> settleBatch(WidgetTester tester) async {
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && controller.isLibraryBatchRunning; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(controller.isLibraryBatchRunning, isFalse);
  }

  Future<void> chooseAction(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await settleBatch(tester);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mobile multi-select never plays songs and select-all can be reversed',
    (tester) async {
      await pumpLibrary(tester);
      await tester.longPress(find.text('歌曲0'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 首'), findsOneWidget);
      await tester.tap(find.text('歌曲1'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 首'), findsOneWidget);
      expect(player.opens, isEmpty);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 首'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('BATCH_SCREENSHOT')) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('batch-preview')),
          );
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.tooling/library-batch-mobile.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 首'), findsOneWidget);
      await tester.tap(find.byTooltip('退出多选'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
    },
  );

  testWidgets(
    'filtered selection only affects visible tracks and switching sections clears it',
    (tester) async {
      controller.commitLibrarySearch('歌曲0');
      await pumpLibrary(tester);
      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await chooseAction(tester, '添加到我喜欢');
      expect(controller.favoriteTracks, [tracks[0]]);
      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌曲0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我喜欢'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
    },
  );

  testWidgets('desktop selection adds songs to a chosen playlist', (
    tester,
  ) async {
    storage.persist = false;
    final playlist = await controller.createPlaylist('通勤');
    await pumpLibrary(tester, size: const Size(1200, 800));
    await tester.tap(find.byTooltip('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await chooseAction(tester, '加入歌单');
    await tester.tap(find.text('通勤'));
    await tester.pumpAndSettle();
    expect(
      controller.tracksForPlaylist(playlist!.id),
      tracks.reversed.toList(),
    );
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album dialog changes only selected songs', (tester) async {
    await pumpLibrary(tester);
    await tester.longPress(find.text('歌曲0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('歌曲1'));
    await tester.pumpAndSettle();
    await chooseAction(tester, '修改专辑');
    await tester.enterText(find.byType(TextField), '合并专辑');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settleBatch(tester);
    await tester.pumpAndSettle();
    expect(controller.downloadedTracks.map((t) => t.album), [
      '合并专辑',
      '合并专辑',
      '旧专辑',
    ]);
  });

  testWidgets(
    'batch deletion warns before touching files and retains failed selection',
    (tester) async {
      deletion.failedPaths.add(tracks[1].path);
      controller.cloudDeletionPolicyEnabled = true;
      controller.settings = controller.settings!.copyWith(
        cloudFolderId: 'cloud-folder',
      );
      await pumpLibrary(tester);
      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await chooseAction(tester, '删除歌曲');
      expect(find.textContaining('移入回收站'), findsWidgets);
      expect(find.textContaining('其他设备'), findsOneWidget);
      expect(deletion.calls, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.text('已选 3 首'), findsOneWidget);
      await chooseAction(tester, '删除歌曲');
      await tester.tap(find.widgetWithText(TextButton, '移入回收站'));
      await settleBatch(tester);
      await tester.pumpAndSettle();
      expect(find.text('批量操作结果'), findsOneWidget);
      expect(find.textContaining('失败的歌曲仍保留选中'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 首'), findsOneWidget);
      expect(controller.downloadedTracks, [tracks[1]]);
      deletion.failedPaths.clear();
      await chooseAction(tester, '删除歌曲');
      await tester.tap(find.widgetWithText(TextButton, '移入回收站'));
      await settleBatch(tester);
      await tester.pumpAndSettle();
      expect(controller.downloadedTracks, isEmpty);
    },
  );

  testWidgets('playlist supports bulk removal without deleting files', (
    tester,
  ) async {
    storage.persist = false;
    final playlist = await controller.createPlaylist('通勤');
    await controller.setTracksInPlaylist(playlist!.id, tracks, included: true);
    await pumpLibrary(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通勤'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('多选').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await chooseAction(tester, '从当前歌单移除');
    expect(controller.tracksForPlaylist(playlist.id), isEmpty);
    expect(controller.downloadedTracks, tracks);
    expect(deletion.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

PlayerItem _item(DownloadedTrack track) => PlayerItem(
  id: track.id,
  title: track.title,
  artist: track.artist,
  album: track.album,
  uri: Uri.file(track.path).toString(),
  localPath: track.path,
);

class _BatchStorage extends StorageService {
  _BatchStorage(Directory directory) : super(supportDirectory: directory);
  bool persist = true;
  int myMusicWrites = 0,
      libraryWrites = 0,
      queueWrites = 0,
      failedMusicWrites = 0;
  @override
  Future<void> saveMyMusic(MyMusicData data) async {
    myMusicWrites++;
    if (failedMusicWrites > 0) {
      failedMusicWrites--;
      throw const FileSystemException('simulated save failure');
    }
    if (persist) await super.saveMyMusic(data);
  }

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    libraryWrites++;
    if (persist) await super.saveDownloadedTracks(tracks);
  }

  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {
    queueWrites++;
    if (persist) {
      await super.savePlayerQueue(
        items,
        currentIndex,
        shuffleEnabled: shuffleEnabled,
      );
    }
  }

  @override
  Future<void> savePendingAlbumMatches(List<PendingAlbumMatch> matches) async {
    if (persist) await super.savePendingAlbumMatches(matches);
  }

  @override
  Future<void> saveSettings(AppSettings settings) async {
    if (persist) await super.saveSettings(settings);
  }
}

class _BatchDeletion implements FileDeletionService {
  @override
  bool movesFilesToRecycleBin = true;
  final calls = <String>[];
  final failedPaths = <String>{};
  Completer<void>? gate;
  @override
  Future<bool> deleteFile(String path) async {
    calls.add(path);
    await gate?.future;
    if (failedPaths.contains(path)) {
      throw const FileSystemException('simulated trash failure');
    }
    final file = File(path);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }
}

class _BatchPlayer implements PlaybackService {
  final opens = <String>[];
  PlayerItem? opened;
  @override
  VoidCallback? onChanged;
  @override
  VoidCallback? onCompleted;
  @override
  bool isPlaying = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(minutes: 3);
  @override
  final ValueNotifier<Duration> positionListenable = ValueNotifier(
    Duration.zero,
  );
  @override
  bool isOpened(PlayerItem item) => opened?.uri == item.uri;
  @override
  Future<void> open(PlayerItem item) async {
    opened = item;
    opens.add(item.id);
    isPlaying = true;
  }

  @override
  Future<void> play() async {
    isPlaying = true;
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
  }

  @override
  Future<void> playOrPause() async {
    isPlaying = !isPlaying;
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> stop() async {
    opened = null;
    isPlaying = false;
  }

  @override
  Future<void> dispose() async {
    positionListenable.dispose();
  }
}

class _BatchSource implements MusicSource {
  @override
  String get name => 'test';
  @override
  Future<List<TrackSearchResult>> search(
    String keyword, {
    int page = 1,
  }) async => [];
  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) =>
      throw UnimplementedError();
  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) =>
      throw UnimplementedError();
}
