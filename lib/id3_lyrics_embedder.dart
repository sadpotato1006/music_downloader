import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Id3LyricsEmbedder {
  const Id3LyricsEmbedder._();

  static Future<bool> embedMetadata(
    File file, {
    required String title,
    required String artist,
    String? lyrics,
    Id3CoverImage? cover,
  }) async {
    final cleanedLyrics = lyrics?.trim();
    if ((cleanedLyrics == null || cleanedLyrics.isEmpty) && cover == null) {
      return false;
    }

    final bytes = await file.readAsBytes();
    final embedded = embedMetadataBytes(
      bytes,
      title: title,
      artist: artist,
      lyrics: cleanedLyrics,
      cover: cover,
    );
    await file.writeAsBytes(embedded, flush: true);
    return true;
  }

  static Future<bool> embedLyrics(
    File file, {
    required String lyrics,
    required String title,
    required String artist,
  }) async {
    return embedMetadata(file, title: title, artist: artist, lyrics: lyrics);
  }

  static Uint8List embedLyricsBytes(
    List<int> bytes, {
    required String lyrics,
    required String title,
    required String artist,
  }) {
    return embedMetadataBytes(
      bytes,
      title: title,
      artist: artist,
      lyrics: lyrics,
    );
  }

  static Uint8List embedMetadataBytes(
    List<int> bytes, {
    required String title,
    required String artist,
    String? lyrics,
    Id3CoverImage? cover,
  }) {
    final source = Uint8List.fromList(bytes);
    final audioBytes = _stripExistingTag(source);
    final cleanedLyrics = lyrics?.trim();
    final body = BytesBuilder(copy: false);

    if (title.trim().isNotEmpty) {
      body.add(_textFrame('TIT2', title.trim()));
    }
    if (artist.trim().isNotEmpty) {
      body.add(_textFrame('TPE1', artist.trim()));
    }
    if (cleanedLyrics != null && cleanedLyrics.isNotEmpty) {
      body.add(_unsynchronizedLyricsFrame(cleanedLyrics));
    }
    if (cover != null) {
      body.add(_attachedPictureFrame(cover));
    }

    final bodyBytes = body.toBytes();
    final output = BytesBuilder(copy: false)
      ..add(ascii.encode('ID3'))
      ..add([3, 0, 0])
      ..add(_writeSynchsafe(bodyBytes.length))
      ..add(bodyBytes)
      ..add(audioBytes);
    return output.toBytes();
  }

  static Uint8List _stripExistingTag(Uint8List bytes) {
    if (bytes.length < 10 ||
        bytes[0] != 0x49 ||
        bytes[1] != 0x44 ||
        bytes[2] != 0x33) {
      return bytes;
    }

    final majorVersion = bytes[3];
    final flags = bytes[5];
    final tagBodySize = _readSynchsafe(bytes, 6);
    var tagEnd = 10 + tagBodySize;
    if (majorVersion == 4 && (flags & 0x10) != 0) {
      tagEnd += 10;
    }
    if (tagEnd > bytes.length) {
      return bytes;
    }
    return bytes.sublist(tagEnd);
  }

  static Uint8List _textFrame(String id, String value) {
    final payload = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(_utf16WithBom(value));
    return _frame(id, payload.toBytes());
  }

  static Uint8List _unsynchronizedLyricsFrame(String lyrics) {
    final payload = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(ascii.encode('chi'))
      ..add(_utf16WithBom('QingTing'))
      ..add([0, 0])
      ..add(_utf16Le(lyrics));
    return _frame('USLT', payload.toBytes());
  }

  static Uint8List _attachedPictureFrame(Id3CoverImage cover) {
    final payload = BytesBuilder(copy: false)
      ..addByte(0)
      ..add(latin1.encode(cover.mimeType))
      ..addByte(0)
      ..addByte(3)
      ..addByte(0)
      ..add(cover.bytes);
    return _frame('APIC', payload.toBytes());
  }

  static Uint8List _frame(String id, Uint8List payload) {
    final frame = BytesBuilder(copy: false)
      ..add(ascii.encode(id))
      ..add(_writeUint32(payload.length))
      ..add([0, 0])
      ..add(payload);
    return frame.toBytes();
  }

  static int _readSynchsafe(Uint8List bytes, int offset) {
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static Uint8List _writeSynchsafe(int value) {
    return Uint8List.fromList([
      (value >> 21) & 0x7F,
      (value >> 14) & 0x7F,
      (value >> 7) & 0x7F,
      value & 0x7F,
    ]);
  }

  static Uint8List _writeUint32(int value) {
    return Uint8List.fromList([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  static Uint8List _utf16WithBom(String value) {
    final bytes = BytesBuilder(copy: false)
      ..add([0xFF, 0xFE])
      ..add(_utf16Le(value));
    return bytes.toBytes();
  }

  static Uint8List _utf16Le(String value) {
    final bytes = BytesBuilder(copy: false);
    for (final codeUnit in value.codeUnits) {
      bytes
        ..addByte(codeUnit & 0xFF)
        ..addByte((codeUnit >> 8) & 0xFF);
    }
    return bytes.toBytes();
  }
}

class Id3CoverImage {
  const Id3CoverImage({required this.mimeType, required this.bytes});

  final String mimeType;
  final Uint8List bytes;
}
