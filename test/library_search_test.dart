import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/library_search.dart';
import 'package:qingting/models.dart';

void main() {
  final track = DownloadedTrack(
    id: 'local-1',
    title: '富士山下',
    artist: '陈奕迅',
    path: 'C:/Music/fushi.mp3',
    format: 'mp3',
    downloadedAt: DateTime(2026, 6, 19),
    sourceUrl: 'file:///C:/Music/fushi.mp3',
    album: "What's Going On...?",
  );

  test('matches title artist and album text', () {
    expect(LibrarySearch.matchesDownloadedTrack(track, '富士'), isTrue);
    expect(LibrarySearch.matchesDownloadedTrack(track, '陈奕迅'), isTrue);
    expect(LibrarySearch.matchesDownloadedTrack(track, 'whatsgoing'), isTrue);
  });

  test('matches embedded or sidecar lyrics text', () {
    expect(
      LibrarySearch.matchesDownloadedTrack(
        track,
        '悲哀',
        lyrics: '[03:20.00]何不把悲哀感觉假设是来自你虚构',
      ),
      isTrue,
    );
  });

  test('matches pinyin initials and full pinyin', () {
    expect(LibrarySearch.matchesDownloadedTrack(track, 'fssx'), isTrue);
    expect(LibrarySearch.matchesDownloadedTrack(track, 'fjx'), isTrue);
    expect(LibrarySearch.matchesDownloadedTrack(track, 'fushishanxia'), isTrue);
    expect(LibrarySearch.matchesDownloadedTrack(track, 'cyx'), isTrue);
  });

  test('ignores spacing and punctuation in query and fields', () {
    expect(LibrarySearch.matchesDownloadedTrack(track, 'what s going'), isTrue);
    expect(LibrarySearch.matchesDownloadedTrack(track, 'not-found'), isFalse);
  });

  test('reused index keeps folded and fuzzy pinyin matching boundaries', () {
    final index = LibrarySearchIndex.fromTrack(track);
    for (var read = 0; read < 3; read += 1) {
      for (final query in ['fssx', 'fsx', 'fjx', 'cyx', 'fushishanxia']) {
        expect(index.matchesNormalizedQuery(query), isTrue, reason: query);
      }
      for (final query in ['fjz', 'fa', 'f9x', '富虚', 'nonexistent']) {
        expect(index.matchesNormalizedQuery(query), isFalse, reason: query);
      }
    }
  });

  test(
    'normalization removes mixed whitespace and punctuation in one pass',
    () {
      expect(
        LibrarySearch.normalize('  WHAT\tS\nGOING\r\nON\u00a0...?\u3000'),
        'whatsgoingon',
      );
      expect(LibrarySearch.normalize('《富 士-山_下》'), '富士山下');
    },
  );

  test(
    'empty metadata can still match lyrics without spurious pinyin matches',
    () {
      final index = LibrarySearchIndex.fromTrack(
        track.copyWith(title: '', artist: '', album: ''),
        lyrics: '何不把悲哀感觉假设是来自你虚构',
      );
      expect(index.matchesNormalizedQuery(''), isTrue);
      expect(index.matchesNormalizedQuery('悲哀'), isTrue);
      expect(index.matchesNormalizedQuery('fjx'), isFalse);
    },
  );
}
