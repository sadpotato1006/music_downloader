import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/app_controller.dart';
import 'package:qingting/id3_lyrics_embedder.dart';
import 'package:qingting/main.dart' as app;
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/player_service.dart';
import 'package:qingting/playlist_file_service.dart';
import 'package:qingting/playlist_track_reference.dart';
import 'package:qingting/playlist_transfer_service.dart';
import 'package:qingting/storage_service.dart';

DownloadedTrack song(
  String title, {
  String? path,
  String artist = '歌手',
  String album = '专辑',
  String syncId = '',
  String source = '',
  int? duration,
}) => DownloadedTrack(
  id: title,
  title: title,
  artist: artist,
  album: album,
  path: path ?? '/music/$title.mp3',
  format: 'mp3',
  sourceUrl: source,
  syncId: syncId,
  durationMs: duration,
  downloadedAt: DateTime(2026, 10, 21),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Storage storage;
  late AppController controller;
  final a = song('甲');
  final b = song('乙');
  final c = song('丙');
  final portable = PortablePlaylist(
    name: '通勤',
    tracks: [
      PlaylistTransferService.reference(a),
      PlaylistTransferService.reference(b),
      PlaylistTransferService.reference(c),
    ],
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qingting-playlist-transfer-');
    storage = _Storage(Directory('${root.path}/state'));
    controller = AppController(
      source: _Source(),
      storage: storage,
      player: _Player(),
    );
    controller.downloadedTracks = [a, c];
  });
  tearDown(() async {
    await controller.flushPendingWrites();
    controller.dispose();
    await root.delete(recursive: true);
  });

  test(
    'portable file round trips Chinese, empty playlists, and missing entries',
    () {
      final encoded = PlaylistTransferService.encode([
        portable,
        const PortablePlaylist(name: '空歌单', tracks: []),
      ]);
      final restored = PlaylistTransferService.decode('\uFEFF$encoded');
      expect(restored.map((p) => p.name), ['通勤', '空歌单']);
      expect(restored.first.tracks.map((s) => s.title), ['甲', '乙', '丙']);
      expect(restored.last.tracks, isEmpty);
      expect(encoded, isNot(contains('metadataLyrics')));
    },
  );

  test(
    'invalid type, version, malformed records, and oversize fail before mutation',
    () {
      for (final bad in [
        '[]',
        '{}',
        '{',
        '{"format":"qingting-playlists","version":2,"playlists":[]}',
        '{"format":"qingting-playlists","version":1,"playlists":[{"name":"x","tracks":[3]}]}',
        '{"format":"qingting-playlists","version":1,"playlists":[{"name":"x","tracks":[{"title":""}]}]}',
        ' ' * (PlaylistTransferService.maxFileBytes + 1),
      ]) {
        expect(
          () => PlaylistTransferService.decode(bad),
          throwsFormatException,
        );
      }
      expect(controller.myMusic.playlists, isEmpty);
    },
  );

  test(
    'matches moved files across all three path styles by stable identity',
    () {
      final matcher = PlaylistTrackMatcher([
        song('新标题', path: '/storage/emulated/0/Music/a.mp3', syncId: 'stable'),
        song(
          '源歌曲',
          path: r'C:\Music\b.mp3',
          source: 'https://example.com/song/2',
        ),
        song('普通歌曲', path: '/home/music/c.mp3'),
      ]);
      final resolved = matcher.resolve(const [
        PlaylistTrackReference(
          title: '旧标题',
          originalPath: r'C:\Old\a.mp3',
          syncId: 'stable',
        ),
        PlaylistTrackReference(
          title: '源歌曲',
          originalPath: '/home/old/b.mp3',
          sourceUrl: 'https://example.com/song/2',
        ),
        PlaylistTrackReference(
          title: '普通歌曲',
          artist: '歌手',
          originalPath: '/storage/old/c.mp3',
        ),
      ]);
      expect(resolved.paths, hasLength(3));
      expect(resolved.pending, isEmpty);
    },
  );

  test(
    'does not guess ambiguous versions, mismatched albums or occupied paths',
    () {
      final matcher = PlaylistTrackMatcher([
        a,
        a.copyWith(path: '/other/a.mp3'),
        song('现场版', album: '现场'),
        song('另一首', path: b.path),
      ]);
      final result = matcher.resolve([
        const PlaylistTrackReference(title: '甲', artist: '歌手'),
        const PlaylistTrackReference(title: '现场版', artist: '歌手', album: '录音室'),
        PlaylistTransferService.reference(b),
        const PlaylistTrackReference(title: '甲'),
      ]);
      expect(result.paths, isEmpty);
      expect(result.pending, hasLength(4));
    },
  );

  test(
    'exact local identity retains a chosen version among duplicate songs',
    () {
      final matcher = PlaylistTrackMatcher([
        a,
        a.copyWith(path: '/other/a.mp3'),
      ]);
      expect(matcher.match(PlaylistTransferService.reference(a))?.path, a.path);
    },
  );

  test(
    'import retains missing entries, order and persists them across restart',
    () async {
      final result = await controller.importPlaylists([
        PlaylistImportRequest(portable),
      ]);
      expect(result.matched, 2);
      expect(result.pending, 1);
      final restored = (await storage.loadMyMusic()).playlists.single;
      expect(restored.trackPaths, [a.path, c.path]);
      expect(restored.pendingTracks.single.title, '乙');
      expect(restored.pendingTracks.single.position, 1);
      final exported = PlaylistTransferService.decode(
        controller.exportPlaylists(),
      ).single;
      expect(exported.tracks.map((s) => s.title), ['甲', '乙', '丙']);
      expect(
        MusicPlaylist.fromJson(restored.toJson()).pendingTracks.single.title,
        '乙',
      );
    },
  );

  test(
    'repeated merge deduplicates matched and missing songs and preserves order',
    () async {
      await controller.importPlaylists([PlaylistImportRequest(portable)]);
      final id = controller.myMusic.playlists.single.id;
      await controller.importPlaylists([
        PlaylistImportRequest(portable, targetPlaylistId: id),
        PlaylistImportRequest(portable, targetPlaylistId: id),
      ]);
      expect(controller.myMusic.playlists, hasLength(1));
      final playlist = controller.myMusic.playlists.single;
      expect(playlist.trackPaths, [a.path, c.path]);
      expect(playlist.pendingTracks, hasLength(1));
      expect(
        PlaylistTransferService.decode(
          controller.exportPlaylists(),
        ).single.tracks,
        hasLength(3),
      );
    },
  );

  test(
    'new import renames collisions and invalid targets leave all data intact',
    () async {
      await controller.importPlaylists([
        PlaylistImportRequest(portable),
        PlaylistImportRequest(portable),
      ]);
      expect(controller.myMusic.playlists.map((p) => p.name), ['通勤', '通勤 (2)']);
      final before = controller.myMusic;
      await expectLater(
        controller.importPlaylists([
          PlaylistImportRequest(portable),
          PlaylistImportRequest(portable, targetPlaylistId: 'gone'),
        ]),
        throwsStateError,
      );
      expect(controller.myMusic, same(before));
    },
  );

  test('failed persistence restores the previous collections', () async {
    final before = controller.myMusic;
    storage.failSave = true;
    await expectLater(
      controller.importPlaylists([PlaylistImportRequest(portable)]),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.myMusic, same(before));
    storage.failSave = false;
  });

  test(
    'pending song keeps its position after a preceding song is removed',
    () async {
      await controller.importPlaylists([PlaylistImportRequest(portable)]);
      final id = controller.myMusic.playlists.single.id;
      await controller.setTracksInPlaylist(id, [a], included: false);
      final playlist = controller.myMusic.playlists.single;
      expect(playlist.pendingTracks.single.position, 0);
      expect(
        PlaylistTransferService.decode(
          controller.exportPlaylists(),
        ).single.tracks.map((t) => t.title),
        ['乙', '丙'],
      );
    },
  );

  test(
    'prepending a new song shifts pending entries without changing their order',
    () async {
      await controller.importPlaylists([PlaylistImportRequest(portable)]);
      final d = song('丁');
      controller.downloadedTracks = [a, c, d];
      final id = controller.myMusic.playlists.single.id;
      await controller.setTrackInPlaylist(id, d, included: true);
      expect(
        controller.myMusic.playlists.single.pendingTracks.single.position,
        2,
      );
      expect(
        PlaylistTransferService.decode(
          controller.exportPlaylists(),
        ).single.tracks.map((s) => s.title),
        ['丁', '甲', '乙', '丙'],
      );
    },
  );

  test(
    'a later directory scan resolves and persists pending songs in original order',
    () async {
      await controller.importPlaylists([PlaylistImportRequest(portable)]);
      final file = await File('${root.path}/later.mp3').writeAsBytes([1, 2, 3]);
      await Id3LyricsEmbedder.embedMetadata(
        file,
        title: '乙',
        artist: '歌手',
        album: '专辑',
      );
      controller.settings = AppSettings(downloadDirectory: root.path);
      expect(await controller.scanCurrentDownloadDirectory(), 1);
      final restored = (await storage.loadMyMusic()).playlists.single;
      expect(restored.pendingTracks, isEmpty);
      expect(
        restored.trackPaths.map(PlaylistTransferService.pathKey),
        [a.path, file.path, c.path].map(PlaylistTransferService.pathKey),
      );
      expect(controller.tracksForPlaylist(restored.id).map((t) => t.title), [
        '甲',
        '乙',
        '丙',
      ]);
    },
  );

  Future<void> pump(
    WidgetTester tester,
    _Files files, {
    Size size = const Size(390, 844),
  }) async {
    storage.memoryOnly = true;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (_, _) => Scaffold(
            body: app.LibraryPage(controller: controller, playlistFiles: files),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mobile imports with preview, shows missing songs and exports all',
    (tester) async {
      final files = _Files()
        ..content = PlaylistTransferService.encode([portable]);
      await pump(tester, files);
      await tester.tap(find.widgetWithText(ChoiceChip, '歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('导入歌单'));
      await tester.pumpAndSettle();
      expect(find.text('2 首已匹配 · 1 首待匹配'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '导入'));
      await tester.pumpAndSettle();
      expect(find.text('通勤'), findsOneWidget);
      await tester.tap(find.byTooltip('导出全部歌单'));
      await tester.pumpAndSettle();
      expect(
        PlaylistTransferService.decode(files.saved!).single.tracks,
        hasLength(3),
      );
      await tester.tap(find.text('通勤'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('歌单设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出歌单'));
      await tester.pumpAndSettle();
      expect(PlaylistTransferService.decode(files.saved!).single.name, '通勤');
      await tester.tap(find.text('1 首歌曲待匹配 · 查看'));
      await tester.pumpAndSettle();
      expect(find.text('乙'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('desktop import can merge and cancellation makes no changes', (
    tester,
  ) async {
    storage.memoryOnly = true;
    final target = await controller.createPlaylist('已有歌单');
    final files = _Files()
      ..content = PlaylistTransferService.encode([portable]);
    await pump(tester, files, size: const Size(1200, 800));
    await tester.tap(find.widgetWithText(ChoiceChip, '歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('导入歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.myMusic.playlists.single.trackPaths, isEmpty);
    await tester.tap(find.byTooltip('导入歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建歌单').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并到：已有歌单').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(controller.myMusic.playlists.single.id, target!.id);
    expect(controller.myMusic.playlists.single.trackPaths, [a.path, c.path]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'multi-select has direct add-to-playlist action on a narrow screen',
    (tester) async {
      storage.memoryOnly = true;
      final target = await controller.createPlaylist('目标');
      await pump(tester, _Files(), size: const Size(320, 700));
      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('加入歌单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('目标'));
      await tester.pumpAndSettle();
      expect(controller.tracksForPlaylist(target!.id), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  group('system file adapter', () {
    late FilePickerPlatform original;
    late _Picker picker;
    setUp(() {
      original = FilePickerPlatform.instance;
      picker = _Picker();
      FilePickerPlatform.instance = picker;
    });
    tearDown(() => FilePickerPlatform.instance = original);

    test('cancellation returns without reading or writing', () async {
      expect(await const PlaylistFileService().open(), isNull);
      expect(await const PlaylistFileService().save('通勤', '{}'), isFalse);
    });
    test('reads UTF-8 without relying on a local path', () async {
      picker.selected = _Picked('歌曲歌单', reportedSize: null);
      expect(await const PlaylistFileService().open(), '歌曲歌单');
    });
    test(
      'rejects large content even if the provider reports an incorrect length',
      () async {
        picker.selected = _Picked(
          'x' * (PlaylistTransferService.maxFileBytes + 1),
          reportedSize: 1,
        );
        await expectLater(
          const PlaylistFileService().open(),
          throwsFormatException,
        );
      },
    );
    test(
      'passes UTF-8 bytes to the native save operation on all URI styles',
      () async {
        for (final uri in [
          'content://provider/export',
          'file:///C:/Music/export.json',
          'file:///home/music/export.json',
        ]) {
          picker.output = Uri.parse(uri);
          expect(await const PlaylistFileService().save('通勤/测试', '中文'), isTrue);
          expect(utf8.decode(picker.bytes!), '中文');
          expect(picker.fileName, '通勤_测试.qingting.json');
        }
      },
    );
  });
}

class _Storage extends StorageService {
  _Storage(Directory root) : super(supportDirectory: root);
  bool failSave = false;
  bool memoryOnly = false;
  @override
  Future<void> saveMyMusic(MyMusicData data) async {
    if (failSave) throw const FileSystemException('disk full');
    if (memoryOnly) return;
    await super.saveMyMusic(data);
  }

  @override
  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {}
}

class _Source implements MusicSource {
  @override
  String get name => 'test';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements PlaybackService {
  @override
  VoidCallback? onChanged;
  @override
  VoidCallback? onCompleted;
  @override
  final ValueNotifier<Duration> positionListenable = ValueNotifier(
    Duration.zero,
  );
  @override
  bool get isPlaying => false;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  bool isOpened(PlayerItem item) => false;
  @override
  Future<void> dispose() async => positionListenable.dispose();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Files extends PlaylistFileService {
  String? content;
  String? saved;
  @override
  Future<String?> open() async => content;
  @override
  Future<bool> save(String name, String content) async {
    saved = content;
    return true;
  }
}

class _Picker extends FilePickerPlatform {
  PlatformFile? selected;
  Uri? output;
  Uint8List? bytes;
  String? fileName;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => selected;
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    this.bytes = bytes;
    this.fileName = fileName;
    return output;
  }
}

final class _Picked extends PlatformFile {
  _Picked(this.content, {this.reportedSize});
  final String content;
  final int? reportedSize;
  @override
  String get name => '歌单.json';
  @override
  Uri get uri => Uri.parse('content://provider/playlist');
  @override
  int? lengthSync() => reportedSize;
  @override
  Future<int?> length() async => reportedSize;
  @override
  Future<Uint8List> readAsBytes() async =>
      Uint8List.fromList(utf8.encode(content));
  @override
  Stream<Uint8List> readAsByteStream() async* {
    yield await readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
