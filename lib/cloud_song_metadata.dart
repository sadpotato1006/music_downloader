import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'anyshare_client.dart';
import 'id3_lyrics_embedder.dart';
import 'song_metadata.dart';

class CloudSongMetadataRecord {
  const CloudSongMetadataRecord(this.document, this.file);
  final SongMetadataDocument document;
  final AnyShareFile file;
}

/// Each song has a separate conditional-write document. Lyrics never enlarge
/// the shared hash index, and a failed acknowledgement can be retried safely.
class CloudSongMetadataStore {
  CloudSongMetadataStore({
    required this.client,
    required this.metadataFolder,
    required this.coverFolder,
    required this.workingDirectory,
  });
  static const metadataFolderName = '歌曲信息';
  static const coverFolderName = '封面';
  static const maxCoverBytes = 5 * 1024 * 1024;
  static const maxDocumentBytes = 2 * 1024 * 1024;
  final AnyShareClient client;
  final String metadataFolder, coverFolder;
  final Directory workingDirectory;
  final Map<String, AnyShareFile> _documents = {}, _covers = {};
  final Map<String, Future<void>> _coverUploads = {};

  Future<void> open() async {
    final children = await Future.wait([
      client.listChildren(metadataFolder),
      client.listChildren(coverFolder),
    ]);
    for (var i = 0; i < children.length; i++) {
      final target = i == 0 ? _documents : _covers;
      for (final file in children[i].files) {
        if (target.containsKey(file.name)) {
          throw const FormatException('云端歌曲信息存在同名记录');
        }
        target[file.name] = file;
      }
    }
    await workingDirectory.create(recursive: true);
  }

  bool hasDocument(String id) => _documents.containsKey('$id.json');
  bool hasCover(SongMetadata values) =>
      values.coverHash == null || _covers.containsKey(_coverName(values));

  Future<CloudSongMetadataRecord> merge(
    String id,
    SongMetadata seed,
    LocalSongMetadata? local, {
    Id3CoverImage? seedCover,
  }) async {
    final name = '$id.json';
    final baseline = local?.baseline?.syncId == id ? local?.baseline : null;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final remote = _documents[name];
        if (remote == null && baseline != null) {
          throw const FormatException('云端歌曲信息记录消失，已保留本地修改');
        }
        final previous = remote == null
            ? null
            : await _read(
                remote,
                cached: baseline,
                cachedRev: baseline == null ? null : local?.baselineRev,
              );
        var next =
            previous ??
            SongMetadataDocument(
              syncId: id,
              version: 1,
              values: seed,
              manualFields: local?.baseline?.manualFields ?? const {},
            );
        if (next.syncId != id) throw const FormatException('云端歌曲信息标识不一致');
        next = next.apply(local);
        if (identical(next, previous)) {
          return CloudSongMetadataRecord(next, remote!);
        }
        if (!hasCover(next.values)) {
          await ensureCover(
            next.values,
            local?.values.coverHash == next.values.coverHash
                ? await local?.loadCover()
                : seedCover,
          );
        }
        final file = await _write(next, remote);
        return CloudSongMetadataRecord(next, file);
      } on DioException catch (error) {
        if (attempt == 3 || !_conflict(error)) rethrow;
        await _refresh(name);
      }
    }
    throw StateError('歌曲信息被其他设备持续修改，请重试');
  }

  Future<CloudSongMetadataRecord> acknowledgeTags(
    CloudSongMetadataRecord record,
    String songRev,
  ) async {
    final id = record.document.syncId, name = '${record.document.syncId}.json';
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        final latest = _documents[name]!;
        final document = await _read(
          latest,
          cached: record.document,
          cachedRev: record.file.rev,
        );
        if (document.version != record.document.version) {
          return CloudSongMetadataRecord(document, latest);
        }
        if (document.taggedVersion == document.version &&
            document.taggedRev == songRev) {
          return CloudSongMetadataRecord(document, latest);
        }
        final next = document.tagged(songRev);
        return CloudSongMetadataRecord(next, await _write(next, latest));
      } on DioException catch (error) {
        if (attempt == 3 || !_conflict(error)) rethrow;
        await _refresh(name);
        if (!_documents.containsKey(name)) {
          throw FormatException('歌曲 $id 的云端信息记录消失');
        }
      }
    }
    throw StateError('歌曲标签状态保存失败');
  }

  Future<void> ensureCover(SongMetadata values, Id3CoverImage? cover) async {
    final hash = values.coverHash;
    if (hash == null || _covers.containsKey(_coverName(values))) return;
    if (cover == null ||
        cover.bytes.length > maxCoverBytes ||
        SongMetadata.hashCover(cover) != hash ||
        cover.mimeType != values.coverMimeType) {
      throw const FormatException('待同步歌曲封面不可用');
    }
    final active = _coverUploads[hash];
    if (active != null) {
      await active;
      return;
    }
    final operation = () async {
      final name = _coverName(values),
          temporary = File(p.join(workingDirectory.path, '$hash.cover.part'));
      try {
        await temporary.writeAsBytes(cover.bytes, flush: true);
        try {
          _covers[name] = await client.uploadFile(
            temporary,
            coverFolder,
            name,
            ondup: 1,
          );
        } on DioException catch (error) {
          if (!_conflict(error)) rethrow;
          final children = await client.listChildren(coverFolder);
          final matches = children.files
              .where((file) => file.name == name)
              .toList();
          if (matches.length != 1) rethrow;
          _covers[name] = matches.single;
          await readCover(values);
        }
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }();
    _coverUploads[hash] = operation;
    try {
      await operation;
    } finally {
      _coverUploads.remove(hash);
    }
  }

  Future<Id3CoverImage?> readCover(
    SongMetadata values, {
    Id3CoverImage? local,
  }) async {
    if (values.coverHash == null) return null;
    if (local != null &&
        local.bytes.length <= maxCoverBytes &&
        local.mimeType == values.coverMimeType &&
        SongMetadata.hashCover(local) == values.coverHash) {
      return local;
    }
    final cached = File(
      p.join(workingDirectory.path, '${values.coverHash}.cover.cache'),
    );
    if (await cached.exists() && await cached.length() <= maxCoverBytes) {
      final cover = Id3CoverImage(
        mimeType: values.coverMimeType!,
        bytes: await cached.readAsBytes(),
      );
      if (SongMetadata.hashCover(cover) == values.coverHash) return cover;
    }
    final remote = _covers[_coverName(values)];
    if (remote == null || remote.size > maxCoverBytes || remote.size < 0) {
      throw const FormatException('云端封面缺失或过大');
    }
    final target = File(
      p.join(
        workingDirectory.path,
        '${values.coverHash}.${newMetadataEditId()}.download.part',
      ),
    );
    try {
      await client.downloadFile(remote, target);
      if (await target.length() > maxCoverBytes) {
        throw const FormatException('云端封面过大');
      }
      final cover = Id3CoverImage(
        mimeType: values.coverMimeType!,
        bytes: await target.readAsBytes(),
      );
      if (SongMetadata.hashCover(cover) != values.coverHash) {
        throw const FormatException('云端封面校验失败');
      }
      await cached.writeAsBytes(cover.bytes, flush: true);
      return cover;
    } finally {
      if (await target.exists()) await target.delete();
    }
  }

  Future<SongMetadataDocument> _read(
    AnyShareFile file, {
    SongMetadataDocument? cached,
    String? cachedRev,
  }) async {
    if (cached != null && cachedRev == file.rev) return cached;
    if (file.size > maxDocumentBytes || file.size < 0) {
      throw const FormatException('云端歌曲信息过大');
    }
    final target = File(
      p.join(workingDirectory.path, '${file.name}.read.part'),
    );
    try {
      await client.downloadFile(file, target);
      if (await target.length() > maxDocumentBytes) {
        throw const FormatException('云端歌曲信息过大');
      }
      final body = jsonDecode(await target.readAsString());
      if (body is! Map) throw const FormatException('云端歌曲信息格式不正确');
      return SongMetadataDocument.fromJson(body);
    } finally {
      if (await target.exists()) await target.delete();
    }
  }

  Future<AnyShareFile> _write(
    SongMetadataDocument document,
    AnyShareFile? replace,
  ) async {
    final name = '${document.syncId}.json',
        target = File(p.join(workingDirectory.path, '$name.write.part'));
    try {
      final bytes = utf8.encode(jsonEncode(document.toJson()));
      if (bytes.length > maxDocumentBytes) {
        throw const FormatException('歌曲信息过大');
      }
      await target.writeAsBytes(bytes, flush: true);
      final file = await client.uploadFile(
        target,
        metadataFolder,
        name,
        replace: replace,
        ondup: 1,
      );
      _documents[name] = file;
      return file;
    } finally {
      if (await target.exists()) await target.delete();
    }
  }

  Future<void> _refresh(String name) async {
    final children = await client.listChildren(metadataFolder);
    final matches = children.files.where((file) => file.name == name).toList();
    if (matches.length > 1) throw const FormatException('云端歌曲信息存在同名记录');
    if (matches.isEmpty) {
      _documents.remove(name);
    } else {
      _documents[name] = matches.single;
    }
  }

  String _coverName(SongMetadata values) =>
      '${values.coverHash}.${switch (values.coverMimeType) {
        'image/png' => 'png',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        _ => 'jpg',
      }}';
  bool _conflict(DioException error) =>
      const [400, 403, 409, 412].contains(error.response?.statusCode);
}
