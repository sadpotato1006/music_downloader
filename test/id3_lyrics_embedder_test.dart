import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/id3_lyrics_embedder.dart';

void main() {
  for (final version in [2, 3, 4]) {
    test(
      'editing ID3v2.$version preserves unrelated frames and audio',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qingting-preserve-id3-',
        );
        final file = File('${directory.path}/song.mp3');
        final extras = [
          _versionedFrame(version, version == 2 ? 'TRK' : 'TRCK', [
            0,
            ...ascii.encode('7/12'),
          ]),
          _versionedFrame(
            version,
            version == 2
                ? 'TYE'
                : version == 3
                ? 'TYER'
                : 'TDRC',
            [0, ...ascii.encode('2024')],
          ),
          _versionedFrame(version, version == 2 ? 'TCO' : 'TCON', [
            0,
            ...ascii.encode('Rock'),
          ]),
          _versionedFrame(version, version == 2 ? 'TXX' : 'TXXX', [
            0,
            ...ascii.encode('REPLAYGAIN_TRACK_GAIN'),
            0,
            ...ascii.encode('-3.5 dB'),
          ]),
          _versionedFrame(
            version,
            version == 2 ? 'XYZ' : 'XTRA',
            List.generate(160, (index) => index),
          ),
        ];
        final original = _versionedTag(version, extras);
        await file.writeAsBytes(original);
        try {
          await Id3LyricsEmbedder.embedMetadata(
            file,
            title: '新歌名',
            artist: '歌手',
            album: '专辑',
            lyrics: '[00:01.00]歌词',
          );
          final updated = await file.readAsBytes();
          expect(updated[3], version);
          final raw = latin1.decode(updated);
          for (final frame in extras) {
            expect(raw, contains(latin1.decode(frame)));
          }
          expect(
            updated.sublist(updated.length - 5),
            original.sublist(original.length - 5),
          );
          final metadata = await Id3LyricsEmbedder.extractMetadata(file);
          expect(metadata.title, '新歌名');
          expect(metadata.artist, '歌手');
          expect(metadata.album, '专辑');
          expect(metadata.lyrics, '[00:01.00]歌词');
        } finally {
          await file.delete();
          await directory.delete();
        }
      },
    );
  }

  for (final version in [2, 4]) {
    test('writes large lyrics and cover frames in ID3v2.$version format', () {
      final lyrics = List.filled(50, '[00:01.00]歌词').join('\n');
      final cover = Uint8List.fromList(List.generate(200, (index) => index));
      final original = _versionedTag(version, [
        _versionedFrame(version, version == 2 ? 'TRK' : 'TRCK', [0, 55]),
      ]);
      final updated = Id3LyricsEmbedder.embedMetadataBytes(
        original,
        title: 'Song',
        artist: 'Artist',
        lyrics: lyrics,
        cover: Id3CoverImage(mimeType: 'image/png', bytes: cover),
      );
      final metadata = Id3LyricsEmbedder.extractMetadataBytes(updated);
      expect(metadata.lyrics, lyrics);
      expect(metadata.cover?.mimeType, 'image/png');
      expect(metadata.cover?.bytes, cover);
      expect(updated[3], version);
    });
  }

  test('omitted metadata is preserved and explicit empty values clear it', () {
    final original = Id3LyricsEmbedder.embedMetadataBytes(
      [255, 251, 144, 100, 0],
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      lyrics: 'Lyrics',
      cover: Id3CoverImage(
        mimeType: 'image/png',
        bytes: Uint8List.fromList([1, 2, 3]),
      ),
    );
    final updated = Id3LyricsEmbedder.embedLyricsBytes(
      original,
      title: 'Song',
      artist: 'Artist',
      lyrics: 'New lyrics',
    );
    final metadata = Id3LyricsEmbedder.extractMetadataBytes(updated);
    expect(metadata.album, 'Album');
    expect(metadata.cover?.bytes, [1, 2, 3]);
    expect(metadata.lyrics, 'New lyrics');
    final cleared = Id3LyricsEmbedder.embedMetadataBytes(
      updated,
      title: 'Song',
      artist: 'Artist',
      album: '',
      lyrics: '',
    );
    expect(Id3LyricsEmbedder.extractMetadataBytes(cleared).album, isNull);
    expect(Id3LyricsEmbedder.extractLyricsBytes(cleared), isNull);
    expect(Id3LyricsEmbedder.extractCoverBytes(cleared)?.bytes, [1, 2, 3]);
  });

  test(
    'replacing lyrics preserves unrelated user text and multiline comments',
    () {
      final comment = _versionedFrame(3, 'COMM', [
        0,
        ...ascii.encode('eng'),
        0,
        ...ascii.encode('one\ntwo\nthree\nfour'),
      ]);
      final replayGain = _versionedFrame(3, 'TXXX', [
        0,
        ...ascii.encode('REPLAYGAIN_TRACK_GAIN'),
        0,
        ...ascii.encode('-3 dB'),
      ]);
      final lyrics = _versionedFrame(3, 'TXXX', [
        0,
        ...ascii.encode('LYRICS'),
        0,
        ...ascii.encode('old lyrics'),
      ]);
      final updated = Id3LyricsEmbedder.embedMetadataBytes(
        _versionedTag(3, [comment, replayGain, lyrics]),
        title: 'Song',
        artist: 'Artist',
        lyrics: 'New lyrics',
      );
      final raw = latin1.decode(updated);
      expect(raw, contains(latin1.decode(comment)));
      expect(raw, contains(latin1.decode(replayGain)));
      expect(raw, isNot(contains(latin1.decode(lyrics))));
      expect(Id3LyricsEmbedder.extractLyricsBytes(updated), 'New lyrics');
    },
  );

  test('editing preserves compressed and encrypted frame bytes', () {
    for (final version in [3, 4]) {
      final frame = _versionedFrame(version, 'XTRA', [0, 0, 0, 4, 1, 2, 3, 4]);
      frame[9] = version == 3 ? 0xC0 : 0x0C;
      final updated = Id3LyricsEmbedder.embedMetadataBytes(
        _versionedTag(version, [frame]),
        title: 'Song',
        artist: 'Artist',
      );
      expect(latin1.decode(updated), contains(latin1.decode(frame)));
    }
  });

  test(
    'editing unsynchronised v2.3 preserves raw frame payload boundaries',
    () {
      final frame = _versionedFrame(3, 'XTRA', [1, 255, 224, 2, 255, 0, 3]);
      final body = <int>[];
      for (var index = 0; index < frame.length; index++) {
        body.add(frame[index]);
        if (frame[index] == 255 &&
            index + 1 < frame.length &&
            (frame[index + 1] == 0 || frame[index + 1] >= 224)) {
          body.add(0);
        }
      }
      final source = Uint8List.fromList([
        ...ascii.encode('ID3'),
        3,
        0,
        0x80,
        ..._synchsafe(body.length),
        ...body,
        255,
        251,
        144,
        100,
        0,
      ]);
      final updated = Id3LyricsEmbedder.embedMetadataBytes(
        source,
        title: 'Song',
        artist: 'Artist',
      );
      expect(latin1.decode(updated), contains(latin1.decode(frame)));
      expect(updated[5] & 0x80, 0);
    },
  );

  test(
    'editing v2.4 preserves frame unsynchronisation and removes old footer',
    () {
      final frame = _versionedFrame(4, 'XTRA', [1, 255, 0, 224, 2]);
      final header = [
        ...ascii.encode('ID3'),
        4,
        0,
        0x90,
        ..._synchsafe(frame.length),
      ];
      final source = [
        ...header,
        ...frame,
        ...ascii.encode('3DI'),
        ...header.sublist(3),
        255,
        251,
        144,
        100,
        0,
      ];
      final updated = Id3LyricsEmbedder.embedMetadataBytes(
        source,
        title: 'Song',
        artist: 'Artist',
      );
      final expectedFrame = Uint8List.fromList(frame)..[9] = 0x02;
      expect(latin1.decode(updated), contains(latin1.decode(expectedFrame)));
      expect(updated[5] & 0x90, 0);
      expect(updated.sublist(updated.length - 5), [255, 251, 144, 100, 0]);
      expect(Id3LyricsEmbedder.extractMetadataBytes(updated).title, 'Song');
    },
  );

  test('editing an extended header preserves unrelated frames', () {
    final frame = _versionedFrame(3, 'TRCK', [0, 55]);
    final updated = Id3LyricsEmbedder.embedMetadataBytes(
      _id3v23WithExtendedHeader([frame]),
      title: 'Song',
      artist: 'Artist',
    );
    expect(latin1.decode(updated), contains(latin1.decode(frame)));
    expect(updated[5] & 0x40, 0);
  });

  test('malformed or unsupported tags are not modified on disk', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-invalid-id3-',
    );
    final file = File('${directory.path}/song.mp3');
    try {
      for (final bytes in [
        [73, 68, 51, 3],
        [73, 68, 51, 3, 0, 0, 0, 0, 1, 0],
        _versionedTag(5, []),
        [73, 68, 51, 2, 0, 0x40, 0, 0, 0, 1, 1],
        _versionedTag(3, [
          Uint8List.fromList([
            ...ascii.encode('TRCK'),
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            55,
          ]),
        ]),
      ]) {
        await file.writeAsBytes(bytes);
        await expectLater(
          Id3LyricsEmbedder.embedMetadata(
            file,
            title: 'Song',
            artist: 'Artist',
          ),
          throwsFormatException,
        );
        expect(await file.readAsBytes(), bytes);
      }
    } finally {
      await file.delete();
      await directory.delete();
    }
  });

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

  test('file APIs replace tags while preserving the audio payload', () async {
    final directory = await Directory.systemTemp.createTemp('qingting-id3-');
    final file = File('${directory.path}/song.bin');
    final audioBytes = Uint8List.fromList(
      List<int>.generate(128 * 1024, (index) => index % 251),
    );
    await file.writeAsBytes(audioBytes);

    try {
      final embedded = await Id3LyricsEmbedder.embedMetadata(
        file,
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        lyrics: '[00:00.00]line',
      );
      expect(embedded, isTrue);

      final metadata = await Id3LyricsEmbedder.extractMetadata(file);
      expect(metadata.title, 'Song');
      expect(metadata.artist, 'Artist');
      expect(metadata.album, 'Album');
      expect(metadata.lyrics, '[00:00.00]line');

      await Id3LyricsEmbedder.embedMetadata(
        file,
        title: 'Updated Song',
        artist: 'Artist',
        album: 'Updated Album',
      );

      final updated = await file.readAsBytes();
      expect(updated.sublist(updated.length - audioBytes.length), audioBytes);
      final text = latin1.decode(updated, allowInvalid: true);
      expect(RegExp('TIT2').allMatches(text), hasLength(1));
      expect(RegExp('TALB').allMatches(text), hasLength(1));
    } finally {
      await directory.delete(recursive: true);
    }
  });
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

Uint8List _versionedFrame(int version, String id, List<int> payload) =>
    Uint8List.fromList([
      ...ascii.encode(id),
      ...(version == 2
          ? _uint24(payload.length)
          : version == 4
          ? _synchsafe(payload.length)
          : _uint32(payload.length)),
      if (version != 2) ...[0, 0],
      ...payload,
    ]);

Uint8List _versionedTag(int version, List<Uint8List> frames) {
  final body = frames.expand((frame) => frame).toList();
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    version,
    0,
    0,
    ..._synchsafe(body.length),
    ...body,
    255,
    251,
    144,
    100,
    0,
  ]);
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
