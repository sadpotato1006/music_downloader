import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/models.dart';
import 'package:qingting/storage_service.dart';

void main() {
  late Directory directory;
  late StorageService storage;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('qingting-delta-test-');
    storage = StorageService(supportDirectory: directory);
  });
  tearDown(() async => directory.delete(recursive: true));
  File file(String name) => File('${directory.path}/$name');
  StorageService restart() => StorageService(supportDirectory: directory);

  test(
    'an edit after reopening retains previously committed delta entries',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      tracks[0] = tracks[0].copyWith(title: 'before restart');
      await storage.saveDownloadedTracks(tracks);
      final reopened = restart();
      final restored = (await reopened.loadDownloadedTracks()).toList();
      restored[1] = restored[1].copyWith(title: 'after restart');
      await reopened.saveDownloadedTracks(restored);
      final result = await restart().loadDownloadedTracks();
      expect(result[0].title, 'before restart');
      expect(result[1].title, 'after restart');
    },
  );

  test(
    'append and truncation overlays keep order and remove deleted entries',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      final base = await file('downloads.json').readAsString();
      tracks.add(
        tracks.first.copyWith(title: 'appended', path: 'appended.mp3'),
      );
      await storage.saveDownloadedTracks(tracks);
      expect((await restart().loadDownloadedTracks()).last.title, 'appended');
      await storage.saveDownloadedTracks(tracks.take(550).toList());
      final result = await restart().loadDownloadedTracks();
      expect(result, hasLength(550));
      expect(result.last.title, 'song 549');
      expect(await file('downloads.json').readAsString(), base);
    },
  );

  test(
    'base backup recovery still replays the matching committed overlay',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      tracks[0] = tracks[0].copyWith(title: 'committed');
      await storage.saveDownloadedTracks(tracks);
      await file('downloads.json').writeAsString('{broken');
      expect((await restart().loadDownloadedTracks()).first.title, 'committed');
    },
  );

  test(
    'single-song edits leave the checkpoint intact and survive restart',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      final base = await file('downloads.json').readAsString();
      tracks[2] = tracks[2].copyWith(title: 'edited');
      await storage.saveDownloadedTracks(tracks);
      tracks[8] = tracks[8].copyWith(album: 'album');
      await storage.saveDownloadedTracks(tracks);
      expect(await file('downloads.json').readAsString(), base);
      final delta = await file('downloads.json.delta').readAsString();
      expect(
        utf8.encode(delta).length,
        lessThan(utf8.encode(base).length ~/ 20),
      );
      expect((jsonDecode(delta)['changed'] as Map).length, 2);
      final restored = await restart().loadDownloadedTracks();
      expect(restored[2].title, 'edited');
      expect(restored[8].album, 'album');
      expect(restored.last.id, tracks.last.id);
    },
  );

  test(
    'queue cursor and shuffle changes persist without writing song payloads',
    () async {
      final items = List.generate(
        600,
        (i) => PlayerItem(
          id: '$i',
          title: 'song $i',
          artist: 'artist',
          uri: 'https://example.test/$i.mp3',
          lyrics: 'lyrics ' * 300,
        ),
      );
      await storage.savePlayerQueue(items, 0, shuffleEnabled: true);
      final base = await file('queue.json').readAsString();
      for (var i = 1; i <= 4; i++) {
        await storage.savePlayerQueue(items, i, shuffleEnabled: false);
      }
      expect(await file('queue.json').readAsString(), base);
      final delta = await file('queue.json.delta').readAsString();
      expect(delta.length, lessThan(512));
      expect(jsonDecode(delta)['changed'], isEmpty);
      final restored = await restart().loadPlayerQueue();
      expect(restored.currentIndex, 4);
      expect(restored.shuffleEnabled, isFalse);
      expect(restored.items.last.lyrics, items.last.lyrics);
    },
  );

  test(
    'large changes checkpoint and ignore an older overlay after interruption',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      tracks[0] = tracks[0].copyWith(title: 'first edit');
      await storage.saveDownloadedTracks(tracks);
      final oldDelta = await file('downloads.json.delta').readAsString();
      for (var i = 0; i < 140; i++) {
        tracks[i] = tracks[i].copyWith(title: 'changed $i');
      }
      await storage.saveDownloadedTracks(tracks);
      // A crash after checkpoint commit can leave this old overlay behind.
      expect(await file('downloads.json.delta').readAsString(), oldDelta);
      final restored = await restart().loadDownloadedTracks();
      expect(restored[0].title, 'changed 0');
      expect(restored[139].title, 'changed 139');
      tracks[200] = tracks[200].copyWith(title: 'next edit');
      await storage.saveDownloadedTracks(tracks);
      expect((await restart().loadDownloadedTracks())[200].title, 'next edit');
    },
  );

  test(
    'reconstructed original snapshot cannot replay a previous edit',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      tracks[0] = tracks[0].copyWith(title: 'temporary');
      await storage.saveDownloadedTracks(tracks);
      await storage.saveDownloadedTracks(_tracks());
      expect((await restart().loadDownloadedTracks()).first.title, 'song 0');
    },
  );

  test('corrupt overlay recovers its last valid generation', () async {
    final tracks = _tracks();
    await storage.saveDownloadedTracks(tracks);
    tracks[0] = tracks[0].copyWith(title: 'first');
    await storage.saveDownloadedTracks(tracks);
    tracks[0] = tracks[0].copyWith(title: 'second');
    await storage.saveDownloadedTracks(tracks);
    await file('downloads.json.delta').writeAsString('{broken');
    expect((await restart().loadDownloadedTracks()).first.title, 'first');
    expect(
      await directory.list().any((entry) => entry.path.contains('.corrupt-')),
      isTrue,
    );
  });

  test(
    'corrupt overlay and backup block later writes and preserve files',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      tracks[0] = tracks[0].copyWith(title: 'edited');
      await storage.saveDownloadedTracks(tracks);
      await file('downloads.json.delta').writeAsString('{broken');
      await file('downloads.json.delta.bak').writeAsString('{also broken');
      final reopened = restart();
      await expectLater(
        reopened.loadDownloadedTracks(),
        throwsA(isA<StorageRecoveryException>()),
      );
      await expectLater(
        reopened.saveDownloadedTracks([]),
        throwsA(isA<StorageRecoveryException>()),
      );
      expect(await file('downloads.json.delta').readAsString(), '{broken');
    },
  );

  test(
    'missing base with an existing overlay is not treated as first launch',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      tracks[0] = tracks[0].copyWith(title: 'edited');
      await storage.saveDownloadedTracks(tracks);
      await file('downloads.json').delete();
      await file('downloads.json.bak').delete();
      await expectLater(
        restart().loadDownloadedTracks(),
        throwsA(isA<StorageRecoveryException>()),
      );
    },
  );

  test(
    'failed delta write leaves the checkpoint usable and can be retried',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      final blocker = Directory(file('downloads.json.delta').path);
      await blocker.create();
      tracks[0] = tracks[0].copyWith(title: 'retry');
      await expectLater(
        storage.saveDownloadedTracks(tracks),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      expect((await restart().loadDownloadedTracks()).first.title, 'song 0');
      await storage.saveDownloadedTracks(tracks);
      expect((await restart().loadDownloadedTracks()).first.title, 'retry');
    },
  );

  test(
    'shrinking below the threshold removes old entries without replay',
    () async {
      final tracks = _tracks();
      await storage.saveDownloadedTracks(tracks);
      tracks[0] = tracks[0].copyWith(title: 'edited');
      await storage.saveDownloadedTracks(tracks);
      await storage.saveDownloadedTracks(tracks.take(10).toList());
      final restored = await restart().loadDownloadedTracks();
      expect(restored, hasLength(10));
      expect(restored.first.title, 'edited');
    },
  );
}

List<DownloadedTrack> _tracks() => List.generate(
  600,
  (i) => DownloadedTrack(
    id: '$i',
    title: 'song $i',
    artist: 'artist',
    path: 'song-$i.mp3',
    format: 'mp3',
    downloadedAt: DateTime(2026, 10, 31),
    sourceUrl: '',
    metadataLyrics: 'lyrics ' * 80,
  ),
);
