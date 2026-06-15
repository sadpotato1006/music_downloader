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

  test('embeds title and artist without lyrics or cover', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];

    final embedded = Id3LyricsEmbedder.embedMetadataBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
    );

    final text = latin1.decode(embedded, allowInvalid: true);
    expect(ascii.decode(embedded.sublist(0, 3)), 'ID3');
    expect(text, contains('TIT2'));
    expect(text, contains('TPE1'));
    expect(text, isNot(contains('USLT')));
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

  test('extracts an embedded id3 album cover frame', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];
    final coverBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    final embedded = Id3LyricsEmbedder.embedMetadataBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
      cover: Id3CoverImage(mimeType: 'image/png', bytes: coverBytes),
    );

    final cover = Id3LyricsEmbedder.extractCoverBytes(embedded);

    expect(cover?.mimeType, 'image/png');
    expect(cover?.bytes, coverBytes);
  });

  test('extracts embedded id3 lyrics', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];
    final lyrics = '[00:00.00]Song - Artist\n[00:01.00]line';
    final embedded = Id3LyricsEmbedder.embedMetadataBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
      lyrics: lyrics,
    );

    expect(Id3LyricsEmbedder.extractLyricsBytes(embedded), lyrics);
  });

  test('extracts embedded id3 title artist lyrics and cover metadata', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];
    final coverBytes = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
    final embedded = Id3LyricsEmbedder.embedMetadataBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
      lyrics: '[00:00.00]line',
      cover: Id3CoverImage(mimeType: 'image/jpeg', bytes: coverBytes),
    );

    final metadata = Id3LyricsEmbedder.extractMetadataBytes(embedded);

    expect(metadata.title, 'Song');
    expect(metadata.artist, 'Artist');
    expect(metadata.lyrics, '[00:00.00]line');
    expect(metadata.cover?.mimeType, 'image/jpeg');
    expect(metadata.cover?.bytes, coverBytes);
  });
}
