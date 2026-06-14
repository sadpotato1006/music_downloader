import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/id3_lyrics_embedder.dart';

void main() {
  test('embeds lrc lyrics into an id3 uslt frame', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];

    final embedded = Id3LyricsEmbedder.embedLyricsBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
      lyrics: '[00:00.00]Song - Artist\n[00:01.00]line',
    );

    expect(ascii.decode(embedded.sublist(0, 3)), 'ID3');
    expect(latin1.decode(embedded, allowInvalid: true), contains('USLT'));
    expect(embedded.sublist(embedded.length - sourceMp3.length), sourceMp3);
  });

  test('replaces an existing lyrics frame instead of stacking frames', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];
    final once = Id3LyricsEmbedder.embedLyricsBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
      lyrics: '[00:00.00]first',
    );

    final twice = Id3LyricsEmbedder.embedLyricsBytes(
      once,
      title: 'Song',
      artist: 'Artist',
      lyrics: '[00:00.00]second',
    );

    final text = latin1.decode(twice, allowInvalid: true);
    expect(RegExp('USLT').allMatches(text), hasLength(1));
  });

  test('embeds and replaces an id3 album cover frame', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];
    final once = Id3LyricsEmbedder.embedMetadataBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
      cover: Id3CoverImage(
        mimeType: 'image/jpeg',
        bytes: Uint8List.fromList(List<int>.filled(16, 0xAB)),
      ),
    );

    final twice = Id3LyricsEmbedder.embedMetadataBytes(
      once,
      title: 'Song',
      artist: 'Artist',
      cover: Id3CoverImage(
        mimeType: 'image/png',
        bytes: Uint8List.fromList(List<int>.filled(16, 0xCD)),
      ),
    );

    final text = latin1.decode(twice, allowInvalid: true);
    expect(RegExp('APIC').allMatches(text), hasLength(1));
    expect(text, contains('image/png'));
    expect(text, isNot(contains('image/jpeg')));
  });
}
