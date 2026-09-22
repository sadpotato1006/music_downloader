import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qingting/app_controller.dart';
import 'package:qingting/id3_lyrics_embedder.dart';
import 'package:qingting/lyrics_service.dart';
import 'package:qingting/main.dart' as app;
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/pending_album_match.dart';
import 'package:qingting/player_service.dart';
import 'package:qingting/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _RegressionStorage storage;
  late _FakePlaybackService player;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qingting-optimization-');
    storage = _RegressionStorage(directory);
    player = _FakePlaybackService();
    addTearDown(() async {
      await storage.flushPendingWrites();
      await directory.delete(recursive: true);
    });
  });

  AppController controllerFor({MusicSource? source, LyricsService? lyrics}) {
    final controller = AppController(
      source: source ?? _ControlledSource(),
      storage: storage,
      player: player,
      lyricsService: lyrics,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  for (final action in ['queue', 'local', 'collection', 'clear']) {
    test('pending online playback cannot undo $action', () async {
      final source = _ControlledSource(blockDetails: true);
      final controller = controllerFor(source: source);
      final pending = controller.playSearchResult(_result('a'));
      await source.firstStarted.future;
      final file = await File('${directory.path}/local.m4a').writeAsBytes([1]);
      final track = _track(file.path, format: 'm4a');
      if (action == 'queue') {
        controller.queue = [_item('b')];
        await controller.playQueueAt(0);
      } else if (action == 'local') {
        await controller.playDownloaded(track);
      } else if (action == 'collection') {
        await controller.playDownloadedCollection([track]);
      } else {
        await controller.clearQueue();
      }
      final selected = controller.currentItem;
      source.release.complete();
      await pending;
      expect(controller.currentItem, same(selected));
      expect(controller.queue.any((item) => item.id == 'a'), isFalse);
      expect(source.resolveCalls, 0);
      expect(controller.resolvingPlayId, isNull);
    });
  }

  test(
    'a newer online selection owns the preparation state and result',
    () async {
      final source = _ControlledSource(blockDetails: true);
      final controller = controllerFor(source: source);
      final first = controller.playSearchResult(_result('a'));
      await source.firstStarted.future;
      final second = controller.playSearchResult(_result('b'));
      expect(controller.resolvingPlayId, 'b');
      source.release.complete();
      await Future.wait([first, second]);
      expect(player.openCalls, 1);
      expect(player.openedItem?.id, 'b');
      expect(controller.queue.map((item) => item.id), ['b']);
      expect(controller.globalMessage, '已开始播放：Song b');
    },
  );

  test('a stale online failure does not overwrite a newer message', () async {
    final source = _ControlledSource(blockDetails: true);
    final controller = controllerFor(source: source);
    final pending = controller.playSearchResult(_result('a'));
    await source.firstStarted.future;
    await controller.clearQueue();
    controller.showMessage('New message');
    source.release.completeError(StateError('late failure'));
    await pending;
    expect(controller.globalMessage, 'New message');
    expect(player.openCalls, 0);
  });

  for (final outcome in ['success', 'switch', 'clear', 'failure']) {
    test('online audio starts before lyrics; handles $outcome', () async {
      final lyrics = _ControlledLyrics();
      final controller = controllerFor(
        source: _ControlledSource(embeddedLyrics: false),
        lyrics: lyrics,
      );
      await controller
          .playSearchResult(_result('a'))
          .timeout(const Duration(seconds: 2));
      await lyrics.started.future;
      expect(player.openCalls, 1);
      expect(player.isPlaying, isTrue);
      expect(player.openedItem?.lyrics, isNull);
      expect(lyrics.duration, const Duration(minutes: 3, seconds: 20));
      if (outcome == 'switch') {
        controller.queue = [...controller.queue, _item('b')];
        await controller.playQueueAt(1);
      } else if (outcome == 'clear') {
        await controller.clearQueue();
      }
      if (outcome == 'failure') {
        lyrics.release.completeError(StateError('lyrics offline'));
      } else {
        lyrics.release.complete('[00:01]Loaded lyrics');
      }
      await Future<void>.delayed(Duration.zero);
      await controller.flushPendingWrites();
      if (outcome == 'success') {
        expect(controller.currentItem?.lyrics, '[00:01]Loaded lyrics');
        expect(storage.savedQueue.single.lyrics, '[00:01]Loaded lyrics');
      } else {
        expect(controller.queue.every((item) => item.lyrics == null), isTrue);
      }
      expect(player.openCalls, outcome == 'switch' ? 2 : 1);
    });
  }

  test(
    'removing a queued song prevents late lyrics from restoring it',
    () async {
      final lyrics = _ControlledLyrics();
      final controller = controllerFor(
        source: _ControlledSource(embeddedLyrics: false),
        lyrics: lyrics,
      );
      controller.queue = [_item('existing')];
      controller.currentQueueIndex = 0;
      player.isPlaying = true;
      await controller
          .queueSearchResultNext(_result('a'))
          .timeout(const Duration(seconds: 2));
      await lyrics.started.future;
      await controller.removeQueueAt(1);
      lyrics.release.complete('[00:01]Removed lyrics');
      await Future<void>.delayed(Duration.zero);
      expect(controller.queue.map((item) => item.id), ['existing']);
      expect(controller.currentItem?.lyrics, isNull);
    },
  );

  test(
    'recursive scan preserves different covers for same filenames',
    () async {
      final first = await _audioFile(directory, 'one/same.mp3', marker: 11);
      final second = await _audioFile(directory, 'two/same.mp3', marker: 22);
      final controller = controllerFor();
      controller.settings = AppSettings(downloadDirectory: directory.path);
      expect(await controller.scanCurrentDownloadDirectory(), 2);
      final tracks = controller.downloadedTracks;
      expect(tracks.map((track) => track.coverFilePath).toSet(), hasLength(2));
      for (final track in tracks) {
        final marker = p.equals(track.path, first.path) ? 11 : 22;
        expect(
          [first.path, second.path].any((path) => p.equals(path, track.path)),
          isTrue,
        );
        expect(await File(track.coverFilePath!).readAsBytes(), [
          0xff,
          0xd8,
          marker,
          0xff,
          0xd9,
        ]);
      }
    },
  );

  test('cover cache keys retain long names and punctuation identity', () async {
    final prefix = 'x' * 150;
    final first = await storage.cacheCoverImage(
      _cover(11),
      cacheKey: '$prefix/a?',
    );
    final second = await storage.cacheCoverImage(
      _cover(22),
      cacheKey: '$prefix/a*',
    );
    expect(first, isNot(second));
    expect(await File(first).readAsBytes(), _cover(11).bytes);
    expect(await File(second).readAsBytes(), _cover(22).bytes);
  });

  test(
    'startup hydration uses linear collection access and one merge',
    () async {
      const count = 240;
      final tracks = _CountingTracks([
        for (var index = 0; index < count; index++)
          _track('${directory.path}/$index.m4a', format: 'm4a'),
      ]);
      storage.tracks = tracks;
      final controller = controllerFor();
      await controller.bootstrap();
      await storage.cleaned.future.timeout(const Duration(seconds: 5));
      expect(tracks.reads, lessThan(count * 12));
      expect(controller.downloadedTracks, same(tracks));
      expect(storage.librarySaves, 0);
    },
  );

  test(
    'startup hydration merges metadata and saves the collection once',
    () async {
      storage.tracks = [
        for (var index = 0; index < 12; index++)
          _track(
            (await _audioFile(directory, '$index.mp3', marker: index)).path,
          ),
      ];
      final controller = controllerFor();
      await controller.bootstrap();
      await storage.cleaned.future.timeout(const Duration(seconds: 5));
      expect(storage.librarySaves, 1);
      expect(
        controller.downloadedTracks.every(
          (track) => track.album == 'Embedded album',
        ),
        isTrue,
      );
      expect(
        controller.downloadedTracks.every(
          (track) => track.coverFilePath != null,
        ),
        isTrue,
      );
    },
  );

  for (final action in ['edit', 'remove', 'reimport']) {
    test('startup hydration preserves a concurrent $action', () async {
      storage.blockCover = true;
      final file = await _audioFile(directory, 'hydrated.mp3');
      final original = _track(file.path);
      storage.tracks = [original];
      final controller = controllerFor();
      await controller.bootstrap();
      await storage.coverStarted.future;
      controller.downloadedTracks = switch (action) {
        'edit' => [original.copyWith(album: 'Manual album')],
        'remove' => [],
        _ => [original.copyWith(id: 'reimported')],
      };
      final expected = controller.downloadedTracks;
      storage.coverRelease.complete();
      await storage.cleaned.future.timeout(const Duration(seconds: 5));
      expect(controller.downloadedTracks, same(expected));
      expect(storage.librarySaves, 0);
    });
  }

  testWidgets(
    'lyrics progress updates without rebuilding the same lyric line',
    (tester) async {
      final controller = controllerFor();
      const item = PlayerItem(
        id: 'lyrics',
        title: 'Timed song',
        artist: 'Artist',
        uri: 'https://example.test/lyrics.mp3',
        lyrics: '[00:00]First line\n[00:10]Second line',
      );
      controller.queue = [item];
      controller.currentQueueIndex = 0;
      player.openedItem = item;
      player.duration = const Duration(minutes: 3);
      await tester.pumpWidget(
        MaterialApp(home: app.HomeShell(controller: controller)),
      );
      await tester.tap(find.text('Timed song'));
      await tester.pumpAndSettle();
      final firstLineFinder = find.descendant(
        of: find.byType(ListView),
        matching: find.text('First line'),
      );
      final firstLine = tester.widget<Text>(firstLineFinder);
      await player.seek(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(firstLineFinder), same(firstLine));
      expect(
        tester
            .widgetList<Slider>(find.byType(Slider))
            .any((slider) => slider.value == 5000),
        isTrue,
      );
      await player.seek(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      final style = tester.widget<AnimatedDefaultTextStyle>(
        find
            .ancestor(
              of: find.descendant(
                of: find.byType(ListView),
                matching: find.text('Second line'),
              ),
              matching: find.byType(AnimatedDefaultTextStyle),
            )
            .first,
      );
      expect(style.style.fontWeight, FontWeight.w800);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

TrackSearchResult _result(String id) => TrackSearchResult(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  source: 'controlled',
  detailUrl: 'https://example.test/$id',
  duration: '3:20',
);

PlayerItem _item(String id) => PlayerItem(
  id: id,
  title: 'Song $id',
  artist: 'Artist',
  uri: 'https://example.test/$id.mp3',
);

DownloadedTrack _track(String path, {String format = 'mp3'}) => DownloadedTrack(
  id: path,
  title: 'Song',
  artist: 'Artist',
  path: path,
  format: format,
  downloadedAt: DateTime(2026),
  sourceUrl: '',
);

Id3CoverImage _cover(int marker) => Id3CoverImage(
  mimeType: 'image/jpeg',
  bytes: Uint8List.fromList([0xff, 0xd8, marker, 0xff, 0xd9]),
);

Future<File> _audioFile(
  Directory directory,
  String name, {
  int marker = 11,
}) async {
  final file = File('${directory.path}/$name');
  await file.parent.create(recursive: true);
  return file.writeAsBytes(
    Id3LyricsEmbedder.embedMetadataBytes(
      [0xff, 0xfb, 0x90, 0],
      title: 'Song',
      artist: 'Artist',
      album: 'Embedded album',
      cover: _cover(marker),
    ),
  );
}

class _ControlledSource implements MusicSource {
  _ControlledSource({this.blockDetails = false, this.embeddedLyrics = true});
  final bool blockDetails;
  final bool embeddedLyrics;
  final firstStarted = Completer<void>();
  final release = Completer<void>();
  int resolveCalls = 0;
  @override
  String get name => 'controlled';
  @override
  Future<List<TrackSearchResult>> search(
    String keyword, {
    int page = 1,
  }) async => [];
  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    if (!firstStarted.isCompleted) {
      firstStarted.complete();
      if (blockDetails) await release.future;
    }
    return TrackDetail(
      title: result.title,
      artist: result.artist,
      sourceUrl: result.detailUrl,
      candidates: const [],
      rawMetadata: const {},
      lyrics: embeddedLyrics ? '[00:01]Ready' : null,
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    resolveCalls++;
    return [AudioCandidate(url: '${detail.sourceUrl}.mp3', format: 'mp3')];
  }
}

class _ControlledLyrics extends LyricsService {
  final started = Completer<void>();
  final release = Completer<String?>();
  Duration? duration;
  @override
  Future<String?> findLyrics({
    required String title,
    required String artist,
    Duration? duration,
  }) {
    this.duration = duration;
    started.complete();
    return release.future;
  }
}

class _RegressionStorage extends StorageService {
  _RegressionStorage(Directory directory)
    : super(supportDirectory: Directory('${directory.path}/support'));
  List<DownloadedTrack> tracks = [];
  List<PlayerItem> savedQueue = [];
  int librarySaves = 0;
  bool blockCover = false;
  final cleaned = Completer<void>();
  final coverStarted = Completer<void>();
  final coverRelease = Completer<void>();
  @override
  Future<AppSettings> loadSettings() async =>
      const AppSettings(downloadDirectory: '');
  @override
  Future<MyMusicData> loadMyMusic() async => const MyMusicData();
  @override
  Future<List<DownloadedTrack>> loadDownloadedTracks() async => tracks;
  @override
  Future<List<DownloadTask>> loadDownloadTasks() async => [];
  @override
  Future<SavedPlayerQueue> loadPlayerQueue() async =>
      const SavedPlayerQueue(items: [], currentIndex: -1);
  @override
  Future<List<PendingAlbumMatch>> loadPendingAlbumMatches() async => [];
  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {
    savedQueue = items;
  }

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    librarySaves++;
  }

  @override
  Future<void> saveMyMusic(MyMusicData data) async {}
  @override
  Future<void> savePendingAlbumMatches(List<PendingAlbumMatch> matches) async {}
  @override
  Future<void> saveSettings(AppSettings settings) async {}
  @override
  Future<String> cacheCoverImage(
    Id3CoverImage cover, {
    required String cacheKey,
  }) async {
    final result = await super.cacheCoverImage(cover, cacheKey: cacheKey);
    if (blockCover) {
      coverStarted.complete();
      await coverRelease.future;
    }
    return result;
  }

  @override
  Future<int> cleanupCachedCovers(
    Iterable<String?> retainedPaths, {
    Duration minimumAge = const Duration(days: 1),
  }) async {
    if (!cleaned.isCompleted) cleaned.complete();
    return 0;
  }
}

class _CountingTracks extends ListBase<DownloadedTrack> {
  _CountingTracks(this.values);
  final List<DownloadedTrack> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => values.length = value;
  @override
  DownloadedTrack operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, DownloadedTrack value) => values[index] = value;
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
  final List<Duration> seekCalls = [];

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
    seekCalls.add(value);
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
