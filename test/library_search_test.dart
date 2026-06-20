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
}
