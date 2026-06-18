import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Id3LyricsEmbedder {
  const Id3LyricsEmbedder._();

  static Future<bool> embedMetadata(
    File file, {
    required String title,
    required String artist,
    String? album,
    String? lyrics,
    Id3CoverImage? cover,
  }) async {
    final cleanedAlbum = album?.trim();
    final cleanedLyrics = lyrics?.trim();
    if (title.trim().isEmpty &&
        artist.trim().isEmpty &&
        (cleanedAlbum == null || cleanedAlbum.isEmpty) &&
        (cleanedLyrics == null || cleanedLyrics.isEmpty) &&
        cover == null) {
      return false;
    }

    final bytes = await file.readAsBytes();
    final embedded = embedMetadataBytes(
      bytes,
      title: title,
      artist: artist,
      album: cleanedAlbum,
      lyrics: cleanedLyrics,
      cover: cover,
    );
    await file.writeAsBytes(embedded, flush: true);
    return true;
  }

  static Future<Id3CoverImage?> extractCover(File file) async {
    if (!await file.exists()) {
      return null;
    }
    return extractCoverBytes(await file.readAsBytes());
  }

  static Future<Id3Metadata> extractMetadata(File file) async {
    if (!await file.exists()) {
      return const Id3Metadata();
    }
    return extractMetadataBytes(await file.readAsBytes());
  }

  static Id3Metadata extractMetadataBytes(List<int> bytes) {
    final source = Uint8List.fromList(bytes);
    if (source.length < 10 ||
        source[0] != 0x49 ||
        source[1] != 0x44 ||
        source[2] != 0x33) {
      return const Id3Metadata();
    }

    final majorVersion = source[3];
    if (majorVersion < 3 || majorVersion > 4) {
      return const Id3Metadata();
    }

    final tagBodySize = _readSynchsafe(source, 6);
    final tagEnd = (10 + tagBodySize).clamp(10, source.length);
    var offset = 10;
    String? title;
    String? artist;
    String? album;
    String? lyrics;
    Id3CoverImage? cover;

    while (offset + 10 <= tagEnd) {
      final frameIdBytes = source.sublist(offset, offset + 4);
      if (frameIdBytes.every((byte) => byte == 0)) {
        break;
      }

      final frameId = ascii.decode(frameIdBytes, allowInvalid: true);
      final frameSize = majorVersion == 4
          ? _readSynchsafe(source, offset + 4)
          : _readUint32(source, offset + 4);
      if (frameSize <= 0 || offset + 10 + frameSize > tagEnd) {
        break;
      }

      final payloadStart = offset + 10;
      final payloadEnd = payloadStart + frameSize;
      final payload = source.sublist(payloadStart, payloadEnd);
      switch (frameId) {
        case 'TIT2':
          title ??= _parseTextFrame(payload);
          break;
        case 'TPE1':
          artist ??= _parseTextFrame(payload);
          break;
        case 'TALB':
          album ??= _parseTextFrame(payload);
          break;
        case 'USLT':
          lyrics ??= _parseUnsynchronizedLyricsFrame(payload);
          break;
        case 'SYLT':
          lyrics ??= _parseSynchronizedLyricsFrame(payload);
          break;
        case 'TXXX':
          lyrics ??= _parseUserTextLyricsFrame(payload);
          break;
        case 'APIC':
          cover ??= _parseAttachedPictureFrame(payload);
          break;
      }
      offset = payloadEnd;
    }

    return Id3Metadata(
      title: title,
      artist: artist,
      album: album,
      lyrics: lyrics,
      cover: cover,
    );
  }

  static Future<String?> extractLyrics(File file) async {
    if (!await file.exists()) {
      return null;
    }
    return extractLyricsBytes(await file.readAsBytes());
  }

  static Id3CoverImage? extractCoverBytes(List<int> bytes) {
    final source = Uint8List.fromList(bytes);
    if (source.length < 10 ||
        source[0] != 0x49 ||
        source[1] != 0x44 ||
        source[2] != 0x33) {
      return null;
    }

    final majorVersion = source[3];
    if (majorVersion < 3 || majorVersion > 4) {
      return null;
    }

    final tagBodySize = _readSynchsafe(source, 6);
    final tagEnd = (10 + tagBodySize).clamp(10, source.length);
    var offset = 10;

    while (offset + 10 <= tagEnd) {
      final frameIdBytes = source.sublist(offset, offset + 4);
      if (frameIdBytes.every((byte) => byte == 0)) {
        break;
      }

      final frameId = ascii.decode(frameIdBytes, allowInvalid: true);
      final frameSize = majorVersion == 4
          ? _readSynchsafe(source, offset + 4)
          : _readUint32(source, offset + 4);
      if (frameSize <= 0 || offset + 10 + frameSize > tagEnd) {
        break;
      }

      final payloadStart = offset + 10;
      final payloadEnd = payloadStart + frameSize;
      if (frameId == 'APIC') {
        return _parseAttachedPictureFrame(
          source.sublist(payloadStart, payloadEnd),
        );
      }
      offset = payloadEnd;
    }
    return null;
  }

  static String? extractLyricsBytes(List<int> bytes) {
    final source = Uint8List.fromList(bytes);
    if (source.length < 10 ||
        source[0] != 0x49 ||
        source[1] != 0x44 ||
        source[2] != 0x33) {
      return null;
    }

    final majorVersion = source[3];
    if (majorVersion < 3 || majorVersion > 4) {
      return null;
    }

    final tagBodySize = _readSynchsafe(source, 6);
    final tagEnd = (10 + tagBodySize).clamp(10, source.length);
    var offset = 10;

    while (offset + 10 <= tagEnd) {
      final frameIdBytes = source.sublist(offset, offset + 4);
      if (frameIdBytes.every((byte) => byte == 0)) {
        break;
      }

      final frameId = ascii.decode(frameIdBytes, allowInvalid: true);
      final frameSize = majorVersion == 4
          ? _readSynchsafe(source, offset + 4)
          : _readUint32(source, offset + 4);
      if (frameSize <= 0 || offset + 10 + frameSize > tagEnd) {
        break;
      }

      final payloadStart = offset + 10;
      final payloadEnd = payloadStart + frameSize;
      final payload = source.sublist(payloadStart, payloadEnd);
      if (frameId == 'USLT') {
        final lyrics = _parseUnsynchronizedLyricsFrame(payload);
        if (lyrics != null) {
          return lyrics;
        }
      }
      if (frameId == 'SYLT') {
        final lyrics = _parseSynchronizedLyricsFrame(payload);
        if (lyrics != null) {
          return lyrics;
        }
      }
      if (frameId == 'TXXX') {
        final lyrics = _parseUserTextLyricsFrame(payload);
        if (lyrics != null) {
          return lyrics;
        }
      }
      offset = payloadEnd;
    }
    return null;
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
    String? album,
    String? lyrics,
    Id3CoverImage? cover,
  }) {
    final source = Uint8List.fromList(bytes);
    final audioBytes = _stripExistingTag(source);
    final cleanedAlbum = album?.trim();
    final cleanedLyrics = lyrics?.trim();
    final body = BytesBuilder(copy: false);

    if (title.trim().isNotEmpty) {
      body.add(_textFrame('TIT2', title.trim()));
    }
    if (artist.trim().isNotEmpty) {
      body.add(_textFrame('TPE1', artist.trim()));
    }
    if (cleanedAlbum != null && cleanedAlbum.isNotEmpty) {
      body.add(_textFrame('TALB', cleanedAlbum));
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

  static Id3CoverImage? _parseAttachedPictureFrame(Uint8List payload) {
    if (payload.length < 5) {
      return null;
    }

    final encoding = payload[0];
    var cursor = 1;
    final mimeEnd = _indexOfByte(payload, 0, cursor);
    if (mimeEnd == -1 || mimeEnd + 2 >= payload.length) {
      return null;
    }
    final mimeType = latin1
        .decode(payload.sublist(cursor, mimeEnd), allowInvalid: true)
        .trim()
        .toLowerCase();
    cursor = mimeEnd + 1;

    cursor += 1;
    final descriptionEnd = encoding == 1 || encoding == 2
        ? _indexOfDoubleZero(payload, cursor)
        : _indexOfByte(payload, 0, cursor);
    if (descriptionEnd == -1) {
      return null;
    }
    cursor = descriptionEnd + ((encoding == 1 || encoding == 2) ? 2 : 1);
    if (cursor >= payload.length) {
      return null;
    }

    final imageBytes = payload.sublist(cursor);
    if (imageBytes.isEmpty) {
      return null;
    }
    return Id3CoverImage(
      mimeType: mimeType.isEmpty ? 'image/jpeg' : mimeType,
      bytes: imageBytes,
    );
  }

  static String? _parseTextFrame(Uint8List payload) {
    if (payload.isEmpty) {
      return null;
    }
    final value = _decodeId3Text(
      payload[0],
      payload.sublist(1),
    ).replaceAll('\u0000', '').trim();
    return value.isEmpty ? null : value;
  }

  static String? _parseUnsynchronizedLyricsFrame(Uint8List payload) {
    if (payload.length < 5) {
      return null;
    }

    final encoding = payload[0];
    var cursor = 4;
    final descriptionEnd = encoding == 1 || encoding == 2
        ? _indexOfDoubleZero(payload, cursor)
        : _indexOfByte(payload, 0, cursor);
    if (descriptionEnd == -1) {
      return null;
    }

    cursor = descriptionEnd + ((encoding == 1 || encoding == 2) ? 2 : 1);
    if (cursor >= payload.length) {
      return null;
    }

    final lyrics = _decodeId3Text(encoding, payload.sublist(cursor)).trim();
    return lyrics.isEmpty ? null : lyrics;
  }

  static String? _parseSynchronizedLyricsFrame(Uint8List payload) {
    if (payload.length < 7) {
      return null;
    }

    final encoding = payload[0];
    final timestampFormat = payload[4];
    var cursor = 6;
    final descriptionEnd = _indexOfTextTerminator(payload, encoding, cursor);
    if (descriptionEnd == -1) {
      return null;
    }
    cursor = descriptionEnd + _textTerminatorLength(encoding);

    final lines = <String>[];
    while (cursor < payload.length) {
      final textEnd = _indexOfTextTerminator(payload, encoding, cursor);
      if (textEnd == -1) {
        break;
      }
      final text = _decodeId3Text(
        encoding,
        payload.sublist(cursor, textEnd),
      ).trim();
      cursor = textEnd + _textTerminatorLength(encoding);
      if (cursor + 4 > payload.length) {
        break;
      }
      final timestamp = _readUint32(payload, cursor);
      cursor += 4;
      if (text.isEmpty) {
        continue;
      }
      final duration = Duration(
        milliseconds: timestampFormat == 2 ? timestamp : timestamp,
      );
      lines.add('${_formatLrcTimestamp(duration)}$text');
    }

    if (lines.isEmpty) {
      return null;
    }
    return lines.join('\n');
  }

  static String? _parseUserTextLyricsFrame(Uint8List payload) {
    if (payload.isEmpty) {
      return null;
    }
    final encoding = payload[0];
    var cursor = 1;
    final descriptionEnd = _indexOfTextTerminator(payload, encoding, cursor);
    if (descriptionEnd == -1) {
      return null;
    }
    final description = _decodeId3Text(
      encoding,
      payload.sublist(cursor, descriptionEnd),
    ).trim().toLowerCase();
    cursor = descriptionEnd + _textTerminatorLength(encoding);
    if (cursor >= payload.length) {
      return null;
    }
    final value = _decodeId3Text(encoding, payload.sublist(cursor)).trim();
    if (value.isEmpty) {
      return null;
    }
    const lyricDescriptions = {
      'lyrics',
      'lyric',
      'syncedlyrics',
      'unsyncedlyrics',
      'unsynchronised lyrics',
      'unsynchronized lyrics',
      'lrc',
      '歌词',
    };
    if (lyricDescriptions.contains(description) ||
        description.contains('lyric') ||
        description.contains('歌词')) {
      return value;
    }
    return null;
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

  static int _readUint32(Uint8List bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
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

  static String _decodeId3Text(int encoding, Uint8List bytes) {
    if (bytes.isEmpty) {
      return '';
    }
    return switch (encoding) {
      0 => latin1.decode(bytes, allowInvalid: true),
      1 => _decodeUtf16WithOptionalBom(bytes),
      2 => _decodeUtf16(bytes, littleEndian: false),
      3 => utf8.decode(bytes, allowMalformed: true),
      _ => latin1.decode(bytes, allowInvalid: true),
    };
  }

  static String _decodeUtf16WithOptionalBom(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    return _decodeUtf16(bytes, littleEndian: true);
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final codeUnits = <int>[];
    for (var index = 0; index + 1 < bytes.length; index += 2) {
      final first = bytes[index];
      final second = bytes[index + 1];
      codeUnits.add(
        littleEndian ? first | (second << 8) : (first << 8) | second,
      );
    }
    return String.fromCharCodes(codeUnits);
  }

  static int _textTerminatorLength(int encoding) {
    return encoding == 1 || encoding == 2 ? 2 : 1;
  }

  static int _indexOfTextTerminator(Uint8List bytes, int encoding, int start) {
    return encoding == 1 || encoding == 2
        ? _indexOfDoubleZero(bytes, start)
        : _indexOfByte(bytes, 0, start);
  }

  static String _formatLrcTimestamp(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    final centiseconds = (duration.inMilliseconds.remainder(1000) / 10).floor();
    return '[${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}.'
        '${centiseconds.toString().padLeft(2, '0')}]';
  }

  static int _indexOfByte(Uint8List bytes, int value, int start) {
    for (var index = start; index < bytes.length; index += 1) {
      if (bytes[index] == value) {
        return index;
      }
    }
    return -1;
  }

  static int _indexOfDoubleZero(Uint8List bytes, int start) {
    for (var index = start; index + 1 < bytes.length; index += 2) {
      if (bytes[index] == 0 && bytes[index + 1] == 0) {
        return index;
      }
    }
    return -1;
  }
}

class Id3CoverImage {
  const Id3CoverImage({required this.mimeType, required this.bytes});

  final String mimeType;
  final Uint8List bytes;
}

class Id3Metadata {
  const Id3Metadata({
    this.title,
    this.artist,
    this.album,
    this.lyrics,
    this.cover,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? lyrics;
  final Id3CoverImage? cover;
}
