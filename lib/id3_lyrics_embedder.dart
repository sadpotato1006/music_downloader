import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class Id3LyricsEmbedder {
  const Id3LyricsEmbedder._();

  /// Updates the supplied fields while preserving other ID3 frames.
  /// Null album, lyrics or cover preserves that field; empty text clears it.
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

    final existingTag = await _readId3Tag(file, forEditing: true);
    final tagBytes = embedMetadataBytes(
      existingTag,
      title: title,
      artist: artist,
      album: cleanedAlbum,
      lyrics: cleanedLyrics,
      cover: cover,
    );
    final sourceOffset = existingTag.length;
    final temporaryFile = File(
      '${file.path}.qingting-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );

    try {
      RandomAccessFile? input;
      RandomAccessFile? output;
      try {
        input = await file.open();
        output = await temporaryFile.open(mode: FileMode.write);
        await output.writeFrom(tagBytes);
        await input.setPosition(sourceOffset);
        while (true) {
          final chunk = await input.read(64 * 1024);
          if (chunk.isEmpty) {
            break;
          }
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        if (output != null) {
          await output.close();
        }
        if (input != null) {
          await input.close();
        }
      }
      await _replaceFile(file, temporaryFile);
      return true;
    } catch (_) {
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
      rethrow;
    }
  }

  static Future<Id3CoverImage?> extractCover(File file) async {
    if (!await file.exists()) {
      return null;
    }
    return extractCoverBytes(await _readId3Tag(file));
  }

  static Future<Id3Metadata> extractMetadata(File file) async {
    if (!await file.exists()) {
      return const Id3Metadata();
    }
    return extractMetadataBytes(await _readId3Tag(file));
  }

  static Id3Metadata extractMetadataBytes(List<int> bytes) {
    final source = Uint8List.fromList(bytes);
    String? title;
    String? artist;
    String? album;
    String? lyrics;
    Id3CoverImage? cover;

    for (final frame in _readId3Frames(source)) {
      switch (frame.id) {
        case 'TIT2':
        case 'TT2':
          title ??= _parseTextFrame(frame.payload);
          break;
        case 'TPE1':
        case 'TP1':
          artist ??= _parseTextFrame(frame.payload);
          break;
        case 'TALB':
        case 'TAL':
          album ??= _parseTextFrame(frame.payload);
          break;
        case 'USLT':
        case 'ULT':
          lyrics ??= _parseUnsynchronizedLyricsFrame(frame.payload);
          break;
        case 'SYLT':
        case 'SLT':
          lyrics ??= _parseSynchronizedLyricsFrame(frame.payload);
          break;
        case 'TXXX':
        case 'TXX':
          lyrics ??= _parseUserTextLyricsFrame(frame.payload);
          break;
        case 'COMM':
        case 'COM':
          lyrics ??= _parseCommentLyricsFrame(frame.payload);
          break;
        case 'APIC':
          cover ??= _parseAttachedPictureFrame(frame.payload);
          break;
        case 'PIC':
          cover ??= _parseAttachedPictureFrame(
            frame.payload,
            legacyPictureFrame: true,
          );
          break;
      }
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
    return extractLyricsBytes(await _readId3Tag(file));
  }

  static Id3CoverImage? extractCoverBytes(List<int> bytes) {
    final source = Uint8List.fromList(bytes);
    for (final frame in _readId3Frames(source)) {
      if (frame.id == 'APIC') {
        return _parseAttachedPictureFrame(frame.payload);
      }
      if (frame.id == 'PIC') {
        return _parseAttachedPictureFrame(
          frame.payload,
          legacyPictureFrame: true,
        );
      }
    }
    return null;
  }

  static String? extractLyricsBytes(List<int> bytes) {
    final source = Uint8List.fromList(bytes);
    for (final frame in _readId3Frames(source)) {
      if (frame.id == 'USLT' || frame.id == 'ULT') {
        final lyrics = _parseUnsynchronizedLyricsFrame(frame.payload);
        if (lyrics != null) {
          return lyrics;
        }
      }
      if (frame.id == 'SYLT' || frame.id == 'SLT') {
        final lyrics = _parseSynchronizedLyricsFrame(frame.payload);
        if (lyrics != null) {
          return lyrics;
        }
      }
      if (frame.id == 'TXXX' || frame.id == 'TXX') {
        final lyrics = _parseUserTextLyricsFrame(frame.payload);
        if (lyrics != null) {
          return lyrics;
        }
      }
      if (frame.id == 'COMM' || frame.id == 'COM') {
        final lyrics = _parseCommentLyricsFrame(frame.payload);
        if (lyrics != null) {
          return lyrics;
        }
      }
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
    final tag = _readTagForEditing(source);
    final audioBytes = source.sublist(tag.byteLength);
    final cleanedAlbum = album?.trim();
    final cleanedLyrics = lyrics?.trim();
    final body = BytesBuilder(copy: false);

    if (title.trim().isNotEmpty) {
      body.add(
        _textFrame('TIT2', title.trim(), majorVersion: tag.majorVersion),
      );
    }
    if (artist.trim().isNotEmpty) {
      body.add(
        _textFrame('TPE1', artist.trim(), majorVersion: tag.majorVersion),
      );
    }
    if (cleanedAlbum != null && cleanedAlbum.isNotEmpty) {
      body.add(
        _textFrame('TALB', cleanedAlbum, majorVersion: tag.majorVersion),
      );
    }
    if (cleanedLyrics != null && cleanedLyrics.isNotEmpty) {
      body.add(
        _unsynchronizedLyricsFrame(
          cleanedLyrics,
          majorVersion: tag.majorVersion,
        ),
      );
    }
    if (cover != null) {
      body.add(_attachedPictureFrame(cover, majorVersion: tag.majorVersion));
    }

    // Keep raw frames in their original ID3 version, including private,
    // compressed and encrypted frames that the metadata reader cannot decode.
    for (final frame in tag.frames) {
      if (_replacesFrame(
        frame,
        tag.majorVersion,
        album: album != null,
        lyrics: lyrics != null,
        cover: cover != null,
      )) {
        continue;
      }
      body.add(frame.bytes);
    }

    final bodyBytes = body.toBytes();
    final output = BytesBuilder(copy: false)
      ..add(ascii.encode('ID3'))
      ..add([tag.majorVersion, tag.revision, tag.flags])
      ..add(_writeSynchsafe(bodyBytes.length))
      ..add(bodyBytes)
      ..add(audioBytes);
    return output.toBytes();
  }

  static Future<Uint8List> _readId3Tag(
    File file, {
    bool forEditing = false,
  }) async {
    final input = await file.open();
    try {
      final fileLength = await input.length();
      final header = await input.read(10);
      final tagLength = _id3TagLengthFromHeader(header, fileLength);
      if (tagLength == 0) {
        if (forEditing && _hasId3Header(header)) {
          throw const FormatException('ID3 标签不完整，已保留原文件。');
        }
        return Uint8List(0);
      }
      await input.setPosition(0);
      return await input.read(tagLength);
    } finally {
      await input.close();
    }
  }

  static int _id3TagLengthFromHeader(Uint8List header, int fileLength) {
    if (header.length < 10 ||
        header[0] != 0x49 ||
        header[1] != 0x44 ||
        header[2] != 0x33) {
      return 0;
    }

    final majorVersion = header[3];
    final flags = header[5];
    var tagLength = 10 + _readSynchsafe(header, 6);
    if (majorVersion == 4 && (flags & 0x10) != 0) {
      tagLength += 10;
    }
    return tagLength <= fileLength ? tagLength : 0;
  }

  static Future<void> _replaceFile(File source, File replacement) async {
    final backup = File(
      '${source.path}.qingting-${DateTime.now().microsecondsSinceEpoch}.bak',
    );
    await source.rename(backup.path);
    try {
      await replacement.rename(source.path);
    } catch (_) {
      if (await backup.exists() && !await source.exists()) {
        await backup.rename(source.path);
      }
      rethrow;
    }

    try {
      if (await backup.exists()) {
        await backup.delete();
      }
    } catch (_) {
      // The replacement succeeded; a stale backup can be removed later.
    }
  }

  static bool _hasId3Header(Uint8List bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0x49 &&
      bytes[1] == 0x44 &&
      bytes[2] == 0x33;

  static _EditableId3Tag _readTagForEditing(Uint8List source) {
    if (!_hasId3Header(source)) {
      return const _EditableId3Tag(3, 0, 0, 0, []);
    }
    const invalid = FormatException('ID3 标签无法安全编辑，已保留原文件。');
    if (source.length < 10) throw invalid;
    final version = source[3];
    final flags = source[5];
    final allowedFlags = switch (version) {
      2 => 0x80,
      3 => 0xE0,
      4 => 0xF0,
      _ => -1,
    };
    if (allowedFlags < 0 ||
        source[4] == 0xFF ||
        (flags & ~allowedFlags) != 0 ||
        source.sublist(6, 10).any((byte) => byte >= 0x80)) {
      throw invalid;
    }
    final byteLength = _id3TagLengthFromHeader(source, source.length);
    if (byteLength == 0) throw invalid;
    final bodyEnd = 10 + _readSynchsafe(source, 6);
    if (version == 4 && (flags & 0x10) != 0) {
      const footerIdentifier = [0x33, 0x44, 0x49];
      for (var index = 0; index < 10; index++) {
        final expected = index < 3 ? footerIdentifier[index] : source[index];
        if (source[bodyEnd + index] != expected) throw invalid;
      }
    }
    var body = source.sublist(10, bodyEnd);
    // v2.2/v2.3 unsynchronisation applies before frame boundaries are read.
    if (version < 4 && (flags & 0x80) != 0) {
      body = _removeUnsynchronization(body);
    }
    var offset = 0;
    if ((flags & 0x40) != 0) {
      if (body.length < 4) throw invalid;
      offset = version == 3
          ? 4 + _readUint32(body, 0)
          : _readSynchsafe(body, 0);
      if (offset < (version == 3 ? 10 : 6) || offset > body.length) {
        throw invalid;
      }
      // Omit the optional extended header: its old CRC/padding is now stale.
    }
    final frames = <_RawId3Frame>[];
    final headerLength = version == 2 ? 6 : 10;
    while (offset < body.length) {
      if (body[offset] == 0 &&
          body.sublist(offset).every((byte) => byte == 0)) {
        break;
      }
      if (offset + headerLength > body.length) throw invalid;
      final id = ascii.decode(
        body.sublist(offset, offset + (version == 2 ? 3 : 4)),
        allowInvalid: true,
      );
      if (!_isValidFrameId(id)) throw invalid;
      if (version == 4 &&
          body.sublist(offset + 4, offset + 8).any((byte) => byte >= 0x80)) {
        throw invalid;
      }
      final size = switch (version) {
        2 => _readUint24(body, offset + 3),
        4 => _readSynchsafe(body, offset + 4),
        _ => _readUint32(body, offset + 4),
      };
      final end = offset + headerLength + size;
      if (size <= 0 || end > body.length) throw invalid;
      final bytes = body.sublist(offset, end);
      if (version == 4 && (flags & 0x80) != 0) {
        // Preserve global unsynchronisation as the equivalent per-frame flag.
        bytes[9] |= 0x02;
      }
      frames.add(_RawId3Frame(id, bytes));
      offset = end;
    }
    return _EditableId3Tag(
      version,
      source[4],
      version >= 3 ? flags & 0x20 : 0,
      byteLength,
      frames,
    );
  }

  static bool _replacesFrame(
    _RawId3Frame frame,
    int version, {
    required bool album,
    required bool lyrics,
    required bool cover,
  }) {
    if (const ['TIT2', 'TT2', 'TPE1', 'TP1'].contains(frame.id)) return true;
    if (album && const ['TALB', 'TAL'].contains(frame.id)) return true;
    if (cover && const ['APIC', 'PIC'].contains(frame.id)) return true;
    if (!lyrics) return false;
    if (const ['USLT', 'ULT', 'SYLT', 'SLT'].contains(frame.id)) return true;
    final isComment = const ['COMM', 'COM'].contains(frame.id);
    if (!isComment && !const ['TXXX', 'TXX'].contains(frame.id)) return false;
    final payload = _normalizeFramePayload(
      frame.bytes.sublist(version == 2 ? 6 : 10),
      majorVersion: version,
      formatFlags: version == 2 ? 0 : frame.bytes[9],
      tagUnsynchronized: false,
    );
    final start = isComment ? 4 : 1;
    if (payload == null || payload.length <= start) return false;
    final end = _indexOfTextTerminator(payload, payload[0], start);
    if (end < 0) return false;
    return _isLyricsDescription(
      _decodeId3Text(
        payload[0],
        payload.sublist(start, end),
      ).trim().toLowerCase(),
    );
  }

  static Iterable<_Id3Frame> _readId3Frames(Uint8List source) sync* {
    if (source.length < 10 ||
        source[0] != 0x49 ||
        source[1] != 0x44 ||
        source[2] != 0x33) {
      return;
    }

    final majorVersion = source[3];
    if (majorVersion < 2 || majorVersion > 4) {
      return;
    }

    final tagFlags = source[5];
    final tagBodySize = _readSynchsafe(source, 6);
    final tagEnd = (10 + tagBodySize).clamp(10, source.length).toInt();
    var offset = 10;

    if ((tagFlags & 0x40) != 0) {
      if (majorVersion == 3 && offset + 4 <= tagEnd) {
        offset += 4 + _readUint32(source, offset);
      } else if (majorVersion == 4 && offset + 4 <= tagEnd) {
        final extendedHeaderSize = _readSynchsafe(source, offset);
        offset += extendedHeaderSize <= 0 ? 4 : extendedHeaderSize;
      }
      if (offset >= tagEnd) {
        return;
      }
    }

    final tagUnsynchronized = (tagFlags & 0x80) != 0;
    while (offset + (majorVersion == 2 ? 6 : 10) <= tagEnd) {
      final idLength = majorVersion == 2 ? 3 : 4;
      final headerLength = majorVersion == 2 ? 6 : 10;
      final frameIdBytes = source.sublist(offset, offset + idLength);
      if (frameIdBytes.every((byte) => byte == 0)) {
        break;
      }

      final frameId = ascii.decode(frameIdBytes, allowInvalid: true);
      if (!_isValidFrameId(frameId)) {
        break;
      }

      final frameSize = switch (majorVersion) {
        2 => _readUint24(source, offset + 3),
        4 => _readSynchsafe(source, offset + 4),
        _ => _readUint32(source, offset + 4),
      };
      if (frameSize <= 0) {
        break;
      }

      final payloadStart = offset + headerLength;
      final payloadEnd = payloadStart + frameSize;
      if (payloadEnd > tagEnd) {
        break;
      }

      final formatFlags = majorVersion == 2 ? 0 : source[offset + 9];
      final payload = _normalizeFramePayload(
        source.sublist(payloadStart, payloadEnd),
        majorVersion: majorVersion,
        formatFlags: formatFlags,
        tagUnsynchronized: tagUnsynchronized,
      );
      if (payload != null) {
        yield _Id3Frame(frameId, payload);
      }
      offset = payloadEnd;
    }
  }

  static Uint8List? _normalizeFramePayload(
    Uint8List payload, {
    required int majorVersion,
    required int formatFlags,
    required bool tagUnsynchronized,
  }) {
    var cursor = 0;
    var frameUnsynchronized = false;

    if (majorVersion == 3) {
      if ((formatFlags & 0xC0) != 0) {
        return null;
      }
      if ((formatFlags & 0x20) != 0) {
        cursor += 1;
      }
    } else if (majorVersion == 4) {
      if ((formatFlags & 0x0C) != 0) {
        return null;
      }
      if ((formatFlags & 0x40) != 0) {
        cursor += 1;
      }
      if ((formatFlags & 0x01) != 0) {
        cursor += 4;
      }
      frameUnsynchronized = (formatFlags & 0x02) != 0;
    }

    if (cursor > payload.length) {
      return null;
    }

    final normalized = payload.sublist(cursor);
    return tagUnsynchronized || frameUnsynchronized
        ? _removeUnsynchronization(normalized)
        : normalized;
  }

  static bool _isValidFrameId(String frameId) {
    return RegExp(r'^[A-Z0-9]{3,4}$').hasMatch(frameId);
  }

  static Uint8List _removeUnsynchronization(Uint8List bytes) {
    final output = BytesBuilder(copy: false);
    for (var index = 0; index < bytes.length; index += 1) {
      final byte = bytes[index];
      output.addByte(byte);
      if (byte == 0xFF &&
          index + 1 < bytes.length &&
          bytes[index + 1] == 0x00) {
        index += 1;
      }
    }
    return output.toBytes();
  }

  static Uint8List _textFrame(String id, String value, {int majorVersion = 3}) {
    final payload = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(_utf16WithBom(value));
    return _frame(id, payload.toBytes(), majorVersion: majorVersion);
  }

  static Uint8List _unsynchronizedLyricsFrame(
    String lyrics, {
    int majorVersion = 3,
  }) {
    final payload = BytesBuilder(copy: false)
      ..addByte(1)
      ..add(ascii.encode('chi'))
      ..add(_utf16WithBom('QingTing'))
      ..add([0, 0])
      ..add(_utf16Le(lyrics));
    return _frame('USLT', payload.toBytes(), majorVersion: majorVersion);
  }

  static Uint8List _attachedPictureFrame(
    Id3CoverImage cover, {
    int majorVersion = 3,
  }) {
    final payload = BytesBuilder(copy: false)..addByte(0);
    if (majorVersion == 2) {
      final format = switch (cover.mimeType.toLowerCase()) {
        'image/jpeg' => 'JPG',
        'image/png' => 'PNG',
        'image/gif' => 'GIF',
        _ => throw const FormatException('该封面格式不能写入 ID3v2.2 标签。'),
      };
      payload.add(ascii.encode(format));
    } else {
      payload
        ..add(latin1.encode(cover.mimeType))
        ..addByte(0);
    }
    payload
      ..addByte(3)
      ..addByte(0)
      ..add(cover.bytes);
    return _frame('APIC', payload.toBytes(), majorVersion: majorVersion);
  }

  static Id3CoverImage? _parseAttachedPictureFrame(
    Uint8List payload, {
    bool legacyPictureFrame = false,
  }) {
    if (payload.length < 5) {
      return null;
    }

    final encoding = payload[0];
    if (legacyPictureFrame) {
      if (payload.length < 6) {
        return null;
      }
      final imageFormat = latin1
          .decode(payload.sublist(1, 4), allowInvalid: true)
          .trim()
          .toLowerCase();
      var legacyCursor = 5;
      final legacyDescriptionEnd = encoding == 1 || encoding == 2
          ? _indexOfDoubleZero(payload, legacyCursor)
          : _indexOfByte(payload, 0, legacyCursor);
      if (legacyDescriptionEnd == -1) {
        return null;
      }
      legacyCursor =
          legacyDescriptionEnd + ((encoding == 1 || encoding == 2) ? 2 : 1);
      if (legacyCursor >= payload.length) {
        return null;
      }
      final imageBytes = payload.sublist(legacyCursor);
      if (imageBytes.isEmpty) {
        return null;
      }
      return Id3CoverImage(
        mimeType: _legacyPictureMimeType(imageFormat),
        bytes: imageBytes,
      );
    }

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

  static String? _parseCommentLyricsFrame(Uint8List payload) {
    if (payload.length < 5) {
      return null;
    }
    final encoding = payload[0];
    var cursor = 4;
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
    if (_isLyricsDescription(description) || _looksLikeLyricsText(value)) {
      return value;
    }
    return null;
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
    if (_isLyricsDescription(description) || _looksLikeLyricsText(value)) {
      return value;
    }
    return null;
  }

  static bool _isLyricsDescription(String description) {
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
    return lyricDescriptions.contains(description) ||
        description.contains('lyric') ||
        description.contains('lrc') ||
        description.contains('歌词');
  }

  static bool _looksLikeLyricsText(String value) {
    final timedLineCount = RegExp(
      r'^\s*\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]',
      multiLine: true,
    ).allMatches(value).length;
    if (timedLineCount >= 2) {
      return true;
    }
    final nonEmptyLines = value
        .split(RegExp(r'[\r\n]+'))
        .where((line) => line.trim().isNotEmpty)
        .length;
    return nonEmptyLines >= 4;
  }

  static String _legacyPictureMimeType(String imageFormat) {
    return switch (imageFormat) {
      'png' => 'image/png',
      'jpg' || 'jpe' || 'jpeg' => 'image/jpeg',
      _ => 'image/${imageFormat.isEmpty ? 'jpeg' : imageFormat}',
    };
  }

  static Uint8List _frame(
    String id,
    Uint8List payload, {
    int majorVersion = 3,
  }) {
    if (majorVersion == 2) {
      final legacyId = const {
        'TIT2': 'TT2',
        'TPE1': 'TP1',
        'TALB': 'TAL',
        'USLT': 'ULT',
        'APIC': 'PIC',
      }[id]!;
      if (payload.length > 0xFFFFFF) {
        throw const FormatException('ID3v2.2 标签帧过大。');
      }
      return (BytesBuilder(copy: false)
            ..add(ascii.encode(legacyId))
            ..add(_writeUint32(payload.length).sublist(1))
            ..add(payload))
          .toBytes();
    }
    final frame = BytesBuilder(copy: false)
      ..add(ascii.encode(id))
      ..add(
        majorVersion == 4
            ? _writeSynchsafe(payload.length)
            : _writeUint32(payload.length),
      )
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

  static int _readUint24(Uint8List bytes, int offset) {
    return (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
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

class _Id3Frame {
  const _Id3Frame(this.id, this.payload);

  final String id;
  final Uint8List payload;
}

class _EditableId3Tag {
  const _EditableId3Tag(
    this.majorVersion,
    this.revision,
    this.flags,
    this.byteLength,
    this.frames,
  );
  final int majorVersion;
  final int revision;
  final int flags;
  final int byteLength;
  final List<_RawId3Frame> frames;
}

class _RawId3Frame {
  const _RawId3Frame(this.id, this.bytes);
  final String id;
  final Uint8List bytes;
}
