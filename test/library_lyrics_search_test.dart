import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/library_lyrics_search.dart';
import 'package:qingting/models.dart';

void main() {
  test('bounded workers publish matches before slow files finish', () async {
    final tracks = List.generate(6, _track);
    final releases = List.generate(6, (_) => Completer<String?>());
    final started = <int>[];
    var active = 0;
    var peak = 0;
    var notifications = 0;
    final search = LibraryLyricsSearch(
      readLyrics: (track) async {
        final index = int.parse(track.id);
        started.add(index);
        active++;
        if (active > peak) peak = active;
        try {
          return await releases[index].future;
        } finally {
          active--;
        }
      },
      trackKey: (track) => track.path,
      isCurrent: tracks.contains,
      matchesMetadata: (_, _) => false,
      onChanged: () => notifications++,
      refreshInterval: const Duration(milliseconds: 5),
    );
    addTearDown(search.dispose);
    final pending = search.search('needle', tracks);
    await _until(() => started.length == 3);
    releases[0].complete('needle');
    await _until(() => notifications > 0);
    expect(search.matches(tracks[0], 'needle'), isTrue);
    expect(active, 3);
    expect(releases[1].isCompleted, isFalse);
    for (final release in releases) {
      if (!release.isCompleted) release.complete('unrelated');
    }
    await pending;
    expect(peak, 3);
  });

  test('a new query shares the pool and discards old query matches', () async {
    final tracks = List.generate(5, _track);
    final releases = List.generate(5, (_) => Completer<String?>());
    final calls = <String>[];
    final search = LibraryLyricsSearch(
      readLyrics: (track) {
        calls.add(track.id);
        return releases[int.parse(track.id)].future;
      },
      trackKey: (track) => track.path,
      isCurrent: tracks.contains,
      matchesMetadata: (_, _) => false,
      onChanged: () {},
    );
    addTearDown(search.dispose);
    final first = search.search('old', tracks);
    await _until(() => calls.length == 3);
    final latest = search.search('new', tracks);
    releases[0].complete('old');
    releases[1].complete('new');
    releases[2].complete('old');
    releases[3].complete('new');
    releases[4].complete('new');
    await Future.wait([first, latest]);
    expect(calls.toSet().length, 5);
    expect(
      calls.length,
      5,
      reason: 'in-flight reads are reused across queries',
    );
    expect(search.matches(tracks[0], 'new'), isFalse);
    expect(search.matches(tracks[1], 'new'), isTrue);
    expect(search.matches(tracks[4], 'new'), isTrue);
  });

  test(
    'evicting cached lyrics preserves every match in the current query',
    () async {
      final tracks = List.generate(10, _track);
      final search = LibraryLyricsSearch(
        readLyrics: (_) async => 'matching lyrics',
        trackKey: (track) => track.path,
        isCurrent: tracks.contains,
        matchesMetadata: (_, _) => false,
        onChanged: () {},
        maxCacheEntries: 3,
        maxCacheCodeUnits: 30,
      );
      addTearDown(search.dispose);
      await search.search('matching', tracks);
      expect(search.cachedEntries, lessThanOrEqualTo(3));
      expect(search.cachedCodeUnits, lessThanOrEqualTo(30));
      expect(
        tracks.every((track) => search.matches(track, 'matching')),
        isTrue,
      );
      await search.search('absent', tracks);
      expect(tracks.any((track) => search.matches(track, 'absent')), isFalse);
    },
  );

  test('late reads cannot overwrite edits or restore removed tracks', () async {
    final original = _track(0);
    var current = <DownloadedTrack>[original];
    final started = Completer<void>();
    final release = Completer<String?>();
    final search = LibraryLyricsSearch(
      readLyrics: (_) {
        started.complete();
        return release.future;
      },
      trackKey: (track) => track.path,
      isCurrent: (track) => current.contains(track),
      matchesMetadata: (_, _) => false,
      onChanged: () {},
    );
    addTearDown(search.dispose);
    final pending = search.search('new', current);
    await started.future;
    final updated = original.copyWith(title: 'Edited');
    current = [updated];
    search.update(updated, 'new');
    release.complete('old');
    await pending;
    expect(search.matches(updated, 'new'), isTrue);
    search.remove(updated);
    current = [];
    expect(search.matches(updated, 'new'), isFalse);
    expect(search.cachedEntries, 0);
  });

  test('one unreadable file does not abort other matches', () async {
    final tracks = List.generate(4, _track);
    var errors = 0;
    final search = LibraryLyricsSearch(
      readLyrics: (track) async {
        if (track.id == '0') throw StateError('unreadable');
        return 'needle';
      },
      trackKey: (track) => track.path,
      isCurrent: tracks.contains,
      matchesMetadata: (_, _) => false,
      onChanged: () {},
      onError: (_, _) => errors++,
    );
    addTearDown(search.dispose);
    await search.search('needle', tracks);
    expect(errors, 1);
    expect(
      tracks.skip(1).every((track) => search.matches(track, 'needle')),
      isTrue,
    );
  });

  test(
    'metadata updates keep lyric matches until lyrics themselves change',
    () async {
      var current = _track(0);
      final search = LibraryLyricsSearch(
        readLyrics: (_) async => 'needle',
        trackKey: (track) => track.path,
        isCurrent: (track) => identical(track, current),
        matchesMetadata: (_, _) => false,
        onChanged: () {},
      );
      addTearDown(search.dispose);
      await search.search('needle', [current]);
      current = current.copyWith(album: 'Updated album', durationMs: 200000);
      expect(search.matches(current, 'needle'), isTrue);
      search.update(current, 'replaced lyrics');
      expect(search.matches(current, 'needle'), isFalse);
    },
  );

  test(
    'clearing a query or disposing stops scheduling further reads',
    () async {
      for (final dispose in [false, true]) {
        final tracks = List.generate(6, _track);
        final release = Completer<String?>();
        var calls = 0;
        var notifications = 0;
        final search = LibraryLyricsSearch(
          readLyrics: (_) {
            calls++;
            return release.future;
          },
          trackKey: (track) => track.path,
          isCurrent: tracks.contains,
          matchesMetadata: (_, _) => false,
          onChanged: () => notifications++,
        );
        final pending = search.search('needle', tracks);
        await _until(() => calls == 3);
        if (dispose) {
          search.dispose();
        } else {
          unawaited(search.search('', tracks));
        }
        release.complete('needle');
        await pending;
        expect(calls, 3);
        expect(notifications, 0);
        search.dispose();
      }
    },
  );
}

DownloadedTrack _track(int index) => DownloadedTrack(
  id: '$index',
  title: 'Song $index',
  artist: '',
  path: '$index.mp3',
  format: 'mp3',
  downloadedAt: DateTime(2026),
  sourceUrl: '',
);

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for search');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
