import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'id3_lyrics_embedder.dart';

const songMetadataFields = {'title', 'artist', 'album', 'lyrics', 'cover'};

String songSyncId(String remoteId) =>
    sha256.convert(utf8.encode(remoteId)).toString();
String newMetadataEditId() =>
    '${DateTime.now().microsecondsSinceEpoch}-'
    '${Random.secure().nextInt(0x7fffffff).toRadixString(16)}';
String newMetadataDeviceId() =>
    sha256.convert(utf8.encode(newMetadataEditId())).toString();

({String device, int sequence})? _metadataEditClock(String id) {
  final match = RegExp(r'^([0-9a-f]{64}):([1-9][0-9]*)$').firstMatch(id);
  final sequence = match == null ? null : int.tryParse(match.group(2)!);
  return sequence == null
      ? null
      : (device: match!.group(1)!, sequence: sequence);
}

class SongMetadata {
  const SongMetadata({
    required this.title,
    required this.artist,
    this.album = '',
    this.lyrics = '',
    this.coverHash,
    this.coverMimeType,
  });

  final String title, artist, album, lyrics;
  final String? coverHash, coverMimeType;

  factory SongMetadata.fromJson(Map json) {
    for (final field in ['title', 'artist', 'album', 'lyrics']) {
      if (json[field] is! String) throw const FormatException('歌曲信息字段格式不正确');
    }
    if ((json['lyrics'] as String).length > 1024 * 1024 ||
        [
          'title',
          'artist',
          'album',
        ].any((key) => (json[key] as String).length > 8192)) {
      throw const FormatException('歌曲信息过大');
    }
    final cover = json['cover'];
    if (cover != null &&
        (cover is! Map ||
            cover['hash'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(cover['hash'] as String) ||
            !const [
              'image/jpeg',
              'image/png',
              'image/webp',
              'image/gif',
            ].contains(cover['mimeType']))) {
      throw const FormatException('歌曲封面信息格式不正确');
    }
    return SongMetadata(
      title: json['title'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String,
      lyrics: json['lyrics'] as String,
      coverHash: cover == null ? null : cover['hash'] as String,
      coverMimeType: cover == null ? null : cover['mimeType'] as String,
    );
  }

  Map<String, Object?> toJson() => {
    'title': title,
    'artist': artist,
    'album': album,
    'lyrics': lyrics,
    'cover': coverHash == null
        ? null
        : {'hash': coverHash, 'mimeType': coverMimeType},
  };

  SongMetadata merge(SongMetadata changes, Set<String> fields) {
    final values = toJson();
    final proposed = changes.toJson();
    for (final field in fields) {
      if (songMetadataFields.contains(field)) values[field] = proposed[field];
    }
    return SongMetadata.fromJson(values);
  }

  bool sameField(SongMetadata other, String field) =>
      jsonEncode(toJson()[field]) == jsonEncode(other.toJson()[field]);
  bool emptyField(String field) => field == 'cover'
      ? coverHash == null
      : (toJson()[field] as String).isEmpty;

  static String? hashCover(Id3CoverImage? cover) =>
      cover == null ? null : sha256.convert(cover.bytes).toString();

  static Future<(SongMetadata, Id3CoverImage?)> readFile(File file) async {
    final embedded = await Id3LyricsEmbedder.extractMetadata(file);
    return (
      SongMetadata(
        title: embedded.title ?? '',
        artist: embedded.artist ?? '',
        album: embedded.album ?? '',
        lyrics: embedded.lyrics ?? '',
        coverHash: hashCover(embedded.cover),
        coverMimeType: embedded.cover?.mimeType,
      ),
      embedded.cover,
    );
  }

  Future<bool> writeMp3(File file, Id3CoverImage? cover) async {
    final (existing, _) = await readFile(file);
    if (songMetadataFields.every((field) => sameField(existing, field))) {
      return false;
    }
    if (coverHash != null && hashCover(cover) != coverHash) {
      throw const FormatException('歌曲封面校验失败');
    }
    await Id3LyricsEmbedder.embedMetadata(
      file,
      title: title,
      artist: artist,
      album: album,
      lyrics: lyrics,
      cover: cover,
      removeCover: coverHash == null,
    );
    return true;
  }
}

class SongMetadataDocument {
  const SongMetadataDocument({
    required this.syncId,
    required this.version,
    required this.values,
    this.manualFields = const {},
    this.editIds = const [],
    this.deviceSequences = const {},
    this.taggedVersion = 0,
    this.taggedRev = '',
  });
  final String syncId;
  final int version, taggedVersion;
  final String taggedRev;
  final SongMetadata values;
  final Set<String> manualFields;
  final List<String> editIds;
  final Map<String, int> deviceSequences;

  factory SongMetadataDocument.fromJson(Map json) {
    if (json['schema'] != 1 ||
        json['syncId'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['syncId'] as String) ||
        json['version'] is! int ||
        (json['version'] as int) < 1 ||
        json['values'] is! Map ||
        json['manualFields'] is! List ||
        json['editIds'] is! List ||
        (json['manualFields'] as List).any(
          (v) => !songMetadataFields.contains(v),
        ) ||
        (json['editIds'] as List).any((v) => v is! String || v.length > 128) ||
        (json['editIds'] as List).length > 128 ||
        (json['taggedVersion'] != null &&
            (json['taggedVersion'] is! int ||
                (json['taggedVersion'] as int) < 0)) ||
        (json['taggedRev'] != null && json['taggedRev'] is! String)) {
      throw const FormatException('云端歌曲信息记录不正确');
    }
    final sequences = json['deviceSequences'] ?? const {};
    if (sequences is! Map ||
        sequences.entries.any(
          (entry) =>
              entry.key is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key as String) ||
              entry.value is! int ||
              (entry.value as int) < 1,
        )) {
      throw const FormatException('云端修改确认序号不正确');
    }
    return SongMetadataDocument(
      syncId: json['syncId'] as String,
      version: json['version'] as int,
      values: SongMetadata.fromJson(json['values'] as Map),
      manualFields: Set<String>.from(json['manualFields'] as List),
      editIds: List<String>.from(json['editIds'] as List),
      deviceSequences: Map<String, int>.from(sequences),
      taggedVersion: json['taggedVersion'] as int? ?? 0,
      taggedRev: json['taggedRev'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() => {
    'schema': 1,
    'syncId': syncId,
    'version': version,
    'values': values.toJson(),
    'manualFields': manualFields.toList()..sort(),
    'editIds': editIds,
    'deviceSequences': deviceSequences,
    'taggedVersion': taggedVersion,
    'taggedRev': taggedRev,
  };

  bool hasEdit(String id) {
    final clock = _metadataEditClock(id);
    return editIds.contains(id) ||
        (clock != null &&
            (deviceSequences[clock.device] ?? 0) >= clock.sequence);
  }

  SongMetadataDocument apply(LocalSongMetadata? local) {
    if (local == null ||
        local.editId.isEmpty ||
        local.fields.isEmpty ||
        hasEdit(local.editId)) {
      return this;
    }
    final accepted = local.fields
        .where(
          (field) =>
              !hasEdit(local.fieldEditIds[field] ?? local.editId) &&
              (!local.fillOnly.contains(field) ||
                  (values.emptyField(field) && !manualFields.contains(field))),
        )
        .toSet();
    final ids = {
      ...editIds,
      ...local.fieldEditIds.values,
      local.editId,
    }.toList();
    final sequences = Map<String, int>.from(deviceSequences);
    for (final id in {...local.fieldEditIds.values, local.editId}) {
      final clock = _metadataEditClock(id);
      if (clock != null) {
        sequences[clock.device] = max(
          sequences[clock.device] ?? 0,
          clock.sequence,
        );
      }
    }
    return SongMetadataDocument(
      syncId: syncId,
      version: version + 1,
      values: values.merge(local.values, accepted),
      manualFields: {...manualFields, ...accepted.difference(local.fillOnly)},
      editIds: ids.length > 128 ? ids.sublist(ids.length - 128) : ids,
      deviceSequences: sequences,
      taggedVersion: taggedVersion,
      taggedRev: taggedRev,
    );
  }

  SongMetadataDocument tagged(String rev) => SongMetadataDocument(
    syncId: syncId,
    version: version,
    values: values,
    manualFields: manualFields,
    editIds: editIds,
    deviceSequences: deviceSequences,
    taggedVersion: version,
    taggedRev: rev,
  );
}

class LocalSongMetadata {
  const LocalSongMetadata({
    required this.values,
    this.cover,
    this.coverFilePath,
    this.fields = const {},
    this.fillOnly = const {},
    this.editId = '',
    this.fieldEditIds = const {},
    this.baseline,
    this.baselineRev = '',
    this.pendingFileWrite = false,
  });
  final SongMetadata values;
  final Id3CoverImage? cover;
  final String? coverFilePath;
  final Set<String> fields, fillOnly;
  final String editId, baselineRev;
  final Map<String, String> fieldEditIds;
  final SongMetadataDocument? baseline;
  final bool pendingFileWrite;

  Future<Id3CoverImage?> loadCover() async {
    if (cover != null || values.coverHash == null) return cover;
    if (coverFilePath == null) return null;
    final file = File(coverFilePath!);
    if (await file.length() > 5 * 1024 * 1024) {
      throw const FormatException('歌曲封面过大');
    }
    final image = Id3CoverImage(
      mimeType: values.coverMimeType!,
      bytes: await file.readAsBytes(),
    );
    if (SongMetadata.hashCover(image) != values.coverHash) {
      throw const FormatException('本地歌曲封面校验失败');
    }
    return image;
  }
}

class SyncedSongMetadata {
  const SyncedSongMetadata({
    required this.document,
    required this.metadataRev,
    this.cover,
    this.coverFilePath,
    this.acknowledgedEditId = '',
    this.pendingFileWrite = false,
  });
  final SongMetadataDocument document;
  final String metadataRev, acknowledgedEditId;
  final Id3CoverImage? cover;
  final String? coverFilePath;
  final bool pendingFileWrite;
}

/// Hash the MPEG payload separately so tag edits cannot create audio conflicts.
Future<String> mp3AudioHash(File file) async {
  final input = await file.open();
  int start = 0, end = await input.length();
  try {
    final header = await input.read(10);
    if (header.length == 10 &&
        header[0] == 0x49 &&
        header[1] == 0x44 &&
        header[2] == 0x33) {
      if (header[3] < 2 ||
          header[3] > 4 ||
          header.sublist(6, 10).any((v) => v >= 128)) {
        throw const FormatException('MP3 标签头不正确');
      }
      start =
          10 +
          ((header[6] << 21) |
              (header[7] << 14) |
              (header[8] << 7) |
              header[9]);
      if (header[3] == 4 && header[5] & 0x10 != 0) start += 10;
      if (start > end) throw const FormatException('MP3 标签不完整');
    }
    if (end - start >= 128) {
      await input.setPosition(end - 128);
      final tail = await input.read(3);
      if (tail.length == 3 &&
          tail[0] == 0x54 &&
          tail[1] == 0x41 &&
          tail[2] == 0x47) {
        end -= 128;
      }
    }
  } finally {
    await input.close();
  }
  return (await sha256.bind(file.openRead(start, end)).first).toString();
}
