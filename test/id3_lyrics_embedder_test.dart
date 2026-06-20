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

  test('embeds title artist and album without lyrics or cover', () {
    final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];

    final embedded = Id3LyricsEmbedder.embedMetadataBytes(
      sourceMp3,
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
    );

    final text = latin1.decode(embedded, allowInvalid: true);
    expect(ascii.decode(embedded.sublist(0, 3)), 'ID3');
    expect(text, contains('TIT2'));
    expect(text, contains('TPE1'));
    expect(text, contains('TALB'));
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

  test('extracts lyrics from a user text lyrics frame', () {
    final embedded = _id3WithFrames([
      _id3Frame('TXXX', [
        3,
        ...utf8.encode('LYRICS'),
        0,
        ...utf8.encode('[00:00.00]line'),
      ]),
    ]);

    expect(Id3LyricsEmbedder.extractLyricsBytes(embedded), '[00:00.00]line');
  });

  test('extracts lyrics from an id3v2.2 unsynchronized lyrics frame', () {
    final embedded = _id3v22WithFrames([
      _id3v22Frame('ULT', [
        3,
        ...ascii.encode('eng'),
        0,
        ...utf8.encode('[00:00.00]line one\n[00:01.00]line two'),
      ]),
    ]);

    expect(
      Id3LyricsEmbedder.extractLyricsBytes(embedded),
      '[00:00.00]line one\n[00:01.00]line two',
    );
  });

  test('skips an id3v2.3 extended header before reading lyrics', () {
    final embedded = _id3v23WithExtendedHeader([
      _id3Frame('USLT', [
        3,
        ...ascii.encode('eng'),
        0,
        ...utf8.encode('[00:00.00]line one\n[00:01.00]line two'),
      ]),
    ]);

    expect(
      Id3LyricsEmbedder.extractLyricsBytes(embedded),
      '[00:00.00]line one\n[00:01.00]line two',
    );
  });

  test('extracts lyrics from an id3 comment frame', () {
    final embedded = _id3WithFrames([
      _id3Frame('COMM', [
        3,
        ...ascii.encode('eng'),
        ...utf8.encode('Lyrics'),
        0,
        ...utf8.encode('first line\nsecond line\nthird line\nfourth line'),
      ]),
    ]);

    expect(
      Id3LyricsEmbedder.extractLyricsBytes(embedded),
      'first line\nsecond line\nthird line\nfourth line',
    );
  });

  test('extracts synchronized id3 lyrics as lrc text', () {
    final embedded = _id3WithFrames([
      _id3Frame('SYLT', [
        3,
        ...ascii.encode('eng'),
        2,
        1,
        0,
        ...utf8.encode('line'),
        0,
        ..._uint32(1200),
      ]),
    ]);

    expect(Id3LyricsEmbedder.extractLyricsBytes(embedded), '[00:01.20]line');
  });

  test(
    'extracts embedded id3 title artist album lyrics and cover metadata',
    () {
      final sourceMp3 = <int>[0xFF, 0xFB, 0x90, 0x64, 0x00];
      final coverBytes = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
      final embedded = Id3LyricsEmbedder.embedMetadataBytes(
        sourceMp3,
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        lyrics: '[00:00.00]line',
        cover: Id3CoverImage(mimeType: 'image/jpeg', bytes: coverBytes),
      );

      final metadata = Id3LyricsEmbedder.extractMetadataBytes(embedded);

      expect(metadata.title, 'Song');
      expect(metadata.artist, 'Artist');
      expect(metadata.album, 'Album');
      expect(metadata.lyrics, '[00:00.00]line');
      expect(metadata.cover?.mimeType, 'image/jpeg');
      expect(metadata.cover?.bytes, coverBytes);
    },
  );
}

Uint8List _id3WithFrames(List<Uint8List> frames) {
  final tagBody = BytesBuilder(copy: false);
  for (final frame in frames) {
    tagBody.add(frame);
  }
  final tagBodyBytes = tagBody.toBytes();
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode('ID3'))
    ..add([4, 0, 0])
    ..add(_synchsafe(tagBodyBytes.length))
    ..add(tagBodyBytes)
    ..add([0xFF, 0xFB, 0x90, 0x64, 0x00]);
  return output.toBytes();
}

Uint8List _id3v23WithExtendedHeader(List<Uint8List> frames) {
  final tagBody = BytesBuilder(copy: false)
    ..add(_uint32(6))
    ..add([0, 0])
    ..add(_uint32(0));
  for (final frame in frames) {
    tagBody.add(frame);
  }
  final tagBodyBytes = tagBody.toBytes();
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode('ID3'))
    ..add([3, 0, 0x40])
    ..add(_synchsafe(tagBodyBytes.length))
    ..add(tagBodyBytes)
    ..add([0xFF, 0xFB, 0x90, 0x64, 0x00]);
  return output.toBytes();
}

Uint8List _id3v22WithFrames(List<Uint8List> frames) {
  final tagBody = BytesBuilder(copy: false);
  for (final frame in frames) {
    tagBody.add(frame);
  }
  final tagBodyBytes = tagBody.toBytes();
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode('ID3'))
    ..add([2, 0, 0])
    ..add(_synchsafe(tagBodyBytes.length))
    ..add(tagBodyBytes)
    ..add([0xFF, 0xFB, 0x90, 0x64, 0x00]);
  return output.toBytes();
}

Uint8List _id3Frame(String id, List<int> payload) {
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode(id))
    ..add(_uint32(payload.length))
    ..add([0, 0])
    ..add(payload);
  return output.toBytes();
}

Uint8List _id3v22Frame(String id, List<int> payload) {
  final output = BytesBuilder(copy: false)
    ..add(ascii.encode(id))
    ..add(_uint24(payload.length))
    ..add(payload);
  return output.toBytes();
}

Uint8List _uint32(int value) {
  return Uint8List.fromList([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
}

Uint8List _uint24(int value) {
  return Uint8List.fromList([
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
}

Uint8List _synchsafe(int value) {
  return Uint8List.fromList([
    (value >> 21) & 0x7F,
    (value >> 14) & 0x7F,
    (value >> 7) & 0x7F,
    value & 0x7F,
  ]);
}
