import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qingting/anyshare_auth.dart';
import 'package:qingting/anyshare_client.dart';
import 'package:qingting/cloud_hash_index.dart';
import 'package:qingting/cloud_sync_service.dart';
import 'package:qingting/song_metadata.dart';
import 'package:qingting/id3_lyrics_embedder.dart';

class _FakeCloudClient extends AnyShareClient {
  _FakeCloudClient() : super(auth: AnyShareAuth());

  final Map<String, List<int>> content = {};
  final Map<String, AnyShareFile> files = {};
  final Map<String, String> fileParents = {};
  final Map<String, AnyShareFolder> folders = {};
  final Map<String, String> folderParents = {};
  var nextId = 1;
  var nextFolderId = 1;
  var nextRev = 1;
  var audioDownloads = 0;
  final downloadsByName = <String, int>{};
  Future<void> Function(File, String, String, AnyShareFile?)? beforeUpload;
  bool failAudioOnce = false;
  bool loseMetadataReplyOnce = false;
  AnyShareDeleteStatus deleteStatus = AnyShareDeleteStatus.deleted;
  bool deferDeletion = false;
  int deleteRequests = 0;

  @override
  Future<AnyShareChildren> listChildren(String folderId) async =>
      AnyShareChildren(
        folders: folders.values
            .where((folder) => folderParents[folder.id] == folderId)
            .toList(),
        files: files.values
            .where((file) => fileParents[file.id] == folderId)
            .toList(),
      );

  @override
  Future<AnyShareFolder> createFolder(String parentId, String name) async {
    final existing = folders.values.where(
      (folder) => folderParents[folder.id] == parentId && folder.name == name,
    );
    if (existing.isNotEmpty) return existing.single;
    final folder = AnyShareFolder(id: 'folder-${nextFolderId++}', name: name);
    folders[folder.id] = folder;
    folderParents[folder.id] = parentId;
    return folder;
  }

  @override
  Future<AnyShareFile> uploadFile(
    File file,
    String parentId,
    String name, {
    AnyShareFile? replace,
    int ondup = 2,
    void Function(int, int)? onProgress,
  }) async {
    await beforeUpload?.call(file, parentId, name, replace);
    if (failAudioOnce && name.endsWith('.mp3')) {
      failAudioOnce = false;
      throw StateError('interrupted audio upload');
    }
    if (replace != null && files[replace.id]?.rev != replace.rev) {
      throw DioException(
        requestOptions: RequestOptions(path: name),
        response: Response(
          requestOptions: RequestOptions(path: name),
          statusCode: 412,
        ),
      );
    }
    if (replace == null &&
        ondup == 1 &&
        files.values.any(
          (file) => fileParents[file.id] == parentId && file.name == name,
        )) {
      throw DioException(
        requestOptions: RequestOptions(path: name),
        response: Response(
          requestOptions: RequestOptions(path: name),
          statusCode: 409,
        ),
      );
    }
    final id = replace?.id ?? 'file-${nextId++}';
    final bytes = await file.readAsBytes();
    final result = AnyShareFile(
      id: id,
      name: name,
      rev: 'rev-${nextRev++}',
      size: bytes.length,
    );
    files[id] = result;
    content[id] = bytes;
    fileParents[id] = replace == null ? parentId : fileParents[id]!;
    if (loseMetadataReplyOnce &&
        name.endsWith('.json') &&
        name != CloudHashIndex.fileName) {
      loseMetadataReplyOnce = false;
      throw StateError('metadata committed but reply was lost');
    }
    return result;
  }

  @override
  Future<void> downloadFile(
    AnyShareFile remote,
    File destination, {
    void Function(int, int)? onProgress,
  }) async {
    if (remote.name.endsWith('.mp3')) audioDownloads++;
    downloadsByName.update(remote.name, (n) => n + 1, ifAbsent: () => 1);
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(content[remote.id]!);
  }

  @override
  Future<AnyShareDeleteStatus> deleteFile(AnyShareFile remote) async {
    deleteRequests++;
    if (deleteStatus == AnyShareDeleteStatus.deleted && !deferDeletion) {
      confirmDeletion(remote.id);
    }
    return deleteStatus;
  }

  void confirmDeletion(String id) {
    files.remove(id);
    content.remove(id);
    fileParents.remove(id);
  }

  void putRemote(String name, String value, {String id = 'remote'}) {
    final songs = folders.values.where(
      (folder) =>
          folderParents[folder.id] == 'root' &&
          folder.name == CloudSyncService.songsFolderName,
    );
    final songFolder = songs.isEmpty
        ? AnyShareFolder(
            id: 'folder-${nextFolderId++}',
            name: CloudSyncService.songsFolderName,
          )
        : songs.single;
    folders[songFolder.id] = songFolder;
    folderParents[songFolder.id] = 'root';
    if (!folders.values.any(
      (folder) =>
          folderParents[folder.id] == 'root' &&
          folder.name == CloudSyncService.dataFolderName,
    )) {
      final dataFolder = AnyShareFolder(
        id: 'folder-${nextFolderId++}',
        name: CloudSyncService.dataFolderName,
      );
      folders[dataFolder.id] = dataFolder;
      folderParents[dataFolder.id] = 'root';
    }
    final bytes = value.codeUnits;
    content[id] = bytes;
    files[id] = AnyShareFile(
      id: id,
      name: name,
      rev: 'rev-${nextRev++}',
      size: bytes.length,
    );
    fileParents[id] = songFolder.id;
  }
}

class _ObservedCloudClient extends _FakeCloudClient {
  final uploads = <String>[];
  final downloads = <String>[];
  final folderCreations = <String>[];
  final failedUploads = <String>{};
  final failedDownloads = <String>{};
  final failedDeletions = <String>{};
  final twoTransfersStarted = Completer<void>();
  Completer<void>? transferGate;
  int active = 0;
  int maxActive = 0;

  Future<T> _transfer<T>(
    String name,
    int size,
    void Function(int, int)? onProgress,
    Future<T> Function() action,
  ) async {
    active++;
    if (active > maxActive) maxActive = active;
    if (active == 2 && !twoTransfersStarted.isCompleted) {
      twoTransfersStarted.complete();
    }
    try {
      onProgress?.call(size ~/ 2, size);
      if (transferGate != null) await transferGate!.future;
      await Future<void>.delayed(const Duration(milliseconds: 110));
      onProgress?.call(size ~/ 2, size);
      final result = await action();
      onProgress?.call(size, size);
      return result;
    } finally {
      active--;
    }
  }

  @override
  Future<AnyShareFolder> createFolder(String parentId, String name) async {
    folderCreations.add(name);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return super.createFolder(parentId, name);
  }

  @override
  Future<AnyShareFile> uploadFile(
    File file,
    String parentId,
    String name, {
    AnyShareFile? replace,
    int ondup = 2,
    void Function(int, int)? onProgress,
  }) async {
    if (!name.endsWith('.mp3')) {
      return super.uploadFile(file, parentId, name, replace: replace);
    }
    uploads.add(name);
    return _transfer(name, await file.length(), onProgress, () async {
      if (failedUploads.contains(name)) {
        throw const FileSystemException('模拟上传失败');
      }
      return super.uploadFile(file, parentId, name, replace: replace);
    });
  }

  @override
  Future<void> downloadFile(
    AnyShareFile remote,
    File destination, {
    void Function(int, int)? onProgress,
  }) async {
    if (!remote.name.endsWith('.mp3')) {
      return super.downloadFile(remote, destination);
    }
    downloads.add(remote.name);
    return _transfer(remote.name, remote.size, onProgress, () async {
      if (failedDownloads.contains(remote.name)) {
        throw const FileSystemException('模拟下载失败');
      }
      await super.downloadFile(remote, destination);
    });
  }

  @override
  Future<AnyShareDeleteStatus> deleteFile(AnyShareFile remote) async {
    if (failedDeletions.contains(remote.name)) {
      throw const FileSystemException('模拟删除失败');
    }
    return super.deleteFile(remote);
  }
}

class _MetadataDevice {
  _MetadataDevice(this.local, this.service);
  final Directory local;
  final CloudSyncService service;
  final snapshots = <String, LocalSongMetadata>{};
  final times = <String, DateTime>{};
  static Future<_MetadataDevice> create(
    Directory root,
    String name,
    AnyShareClient client,
  ) async {
    final directory = await Directory(p.join(root.path, name)).create();
    return _MetadataDevice(
      directory,
      CloudSyncService(
        client: client,
        stateDirectory: Directory(p.join(root.path, '$name-state')),
      ),
    );
  }

  Future<void> add(
    String name,
    SongMetadata values,
    DateTime time, {
    Id3CoverImage? cover,
  }) async {
    final file = File(p.join(local.path, name));
    await file.writeAsBytes(List<int>.generate(512, (i) => i % 256));
    if (name.endsWith('.mp3')) await values.writeMp3(file, cover);
    snapshots[name] = LocalSongMetadata(values: values, cover: cover);
    times[name] = time;
  }

  Future<void> edit(
    String name,
    SongMetadata values,
    Set<String> fields, {
    Id3CoverImage? cover,
    Set<String> fillOnly = const {},
  }) async {
    final previous = snapshots[name]!;
    final editId = newMetadataEditId();
    snapshots[name] = LocalSongMetadata(
      values: values,
      cover: fields.contains('cover') ? cover : previous.cover,
      coverFilePath: fields.contains('cover') ? null : previous.coverFilePath,
      fields: {...previous.fields, ...fields},
      fillOnly: fillOnly,
      editId: editId,
      fieldEditIds: {
        ...previous.fieldEditIds,
        for (final field in fields) field: editId,
      },
      baseline: previous.baseline,
      baselineRev: previous.baselineRev,
    );
    if (name.endsWith('.mp3')) {
      await values.writeMp3(
        File(p.join(local.path, name)),
        await snapshots[name]!.loadCover(),
      );
    }
  }

  Future<CloudSyncResult> sync({Set<String> defer = const {}}) async {
    final result = await service.sync(
      cloudFolderId: 'root',
      localDirectory: local,
      downloadedAtByPath: times,
      readLocalMetadata: (path) async => snapshots[path],
      deferFilePaths: {for (final path in defer) p.join(local.path, path)},
    );
    for (final entry in result.metadataByPath.entries) {
      final name = p.relative(entry.key, from: local.path),
          synced = entry.value;
      snapshots[name] = LocalSongMetadata(
        values: synced.document.values,
        cover: synced.cover,
        coverFilePath: synced.coverFilePath,
        baseline: synced.document,
        baselineRev: synced.metadataRev,
      );
    }
    for (final entry in result.downloadedAtByPath.entries) {
      times[p.relative(entry.key, from: local.path)] = entry.value;
    }
    return result;
  }
}

void main() {
  test(
    'a newly selected cloud folder gets a new identity and preserves information and time',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-metadata-folder-',
      );
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final device = await _MetadataDevice.create(root, 'device', client);
      await device.add(
        'song.mp3',
        const SongMetadata(title: 'Song', artist: 'Artist', album: 'Album'),
        DateTime(2020),
      );
      await device.sync();
      await device.edit(
        'song.mp3',
        const SongMetadata(title: 'Song', artist: 'Artist', album: ''),
        {'album'},
      );
      await device.sync();
      final previous = device.snapshots['song.mp3']!;
      final result = await device.service.sync(
        cloudFolderId: 'another-root',
        localDirectory: device.local,
        downloadedAtByPath: device.times,
        readLocalMetadata: (path) async => device.snapshots[path],
      );
      expect(result.failures, isEmpty);
      final synced = result.metadataByPath.values.single;
      expect(synced.document.syncId, isNot(previous.baseline!.syncId));
      expect(synced.document.values.album, '');
      expect(synced.document.manualFields, contains('album'));
      expect(synced.document.values.title, 'Song');
      expect(device.times['song.mp3'], DateTime(2020));
    },
  );

  test(
    'editing another field after a lost reply does not replay a committed old field',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-metadata-reedit-',
      );
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final a = await _MetadataDevice.create(root, 'a', client),
          b = await _MetadataDevice.create(root, 'b', client);
      const initial = SongMetadata(
        title: 'Song',
        artist: 'Artist',
        album: 'Old',
        lyrics: 'old',
      );
      await a.add('song.mp3', initial, DateTime(2020));
      await a.sync();
      await b.sync();
      await a.edit(
        'song.mp3',
        initial.merge(
          const SongMetadata(title: '', artist: '', album: 'First'),
          {'album'},
        ),
        {'album'},
      );
      client.loseMetadataReplyOnce = true;
      expect((await a.sync()).failures, hasLength(1));
      await b.edit(
        'song.mp3',
        initial.merge(
          const SongMetadata(title: '', artist: '', album: 'Last'),
          {'album'},
        ),
        {'album'},
      );
      expect((await b.sync()).failures, isEmpty);
      await a.edit(
        'song.mp3',
        a.snapshots['song.mp3']!.values.merge(
          const SongMetadata(title: '', artist: '', lyrics: 'New lyrics'),
          {'lyrics'},
        ),
        {'lyrics'},
      );
      expect((await a.sync()).failures, isEmpty);
      await b.sync();
      expect(b.snapshots['song.mp3']!.values.album, 'Last');
      expect(b.snapshots['song.mp3']!.values.lyrics, 'New lyrics');
    },
  );

  test(
    'first metadata upload failure preserves the uploaded identity and non-MP3 information',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-metadata-initial-',
      );
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final a = await _MetadataDevice.create(root, 'a', client),
          b = await _MetadataDevice.create(root, 'b', client);
      const initial = SongMetadata(
        title: 'Real title',
        artist: 'Real artist',
        album: 'Album',
        lyrics: 'Lyrics',
      );
      await a.add('song.flac', initial, DateTime(2020));
      var failed = false;
      client.beforeUpload = (file, parent, name, replace) async {
        if (!failed &&
            name.endsWith('.json') &&
            name != CloudHashIndex.fileName) {
          failed = true;
          throw StateError('metadata upload unavailable');
        }
      };
      expect((await a.sync()).failures, hasLength(1));
      final uploaded = client.files.values.singleWhere(
        (file) => file.name == 'song.flac',
      );
      final restarted = _MetadataDevice(
        a.local,
        CloudSyncService(
          client: client,
          stateDirectory: Directory(p.join(root.path, 'a-state')),
        ),
      );
      restarted.snapshots.addAll(a.snapshots);
      restarted.times.addAll(a.times);
      expect((await restarted.sync()).failures, isEmpty);
      expect((await b.sync()).failures, isEmpty);
      expect(b.snapshots['song.flac']!.values.toJson(), initial.toJson());
      expect(
        b.snapshots['song.flac']!.baseline!.syncId,
        songSyncId(uploaded.id),
      );
      expect(b.times['song.flac'], DateTime(2020));
      expect(
        client.files.values.where((file) => file.name.endsWith('.flac')),
        hasLength(1),
      );
    },
  );

  test(
    'conditional metadata retry merges a simultaneous edit and repairs tags',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-metadata-cas-',
      );
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final a = await _MetadataDevice.create(root, 'a', client),
          b = await _MetadataDevice.create(root, 'b', client);
      const initial = SongMetadata(
        title: 'Song',
        artist: 'Artist',
        album: 'Old',
        lyrics: 'old',
      );
      await a.add('song.mp3', initial, DateTime(2020));
      await a.sync();
      await b.sync();
      await a.edit(
        'song.mp3',
        initial.merge(
          const SongMetadata(title: '', artist: '', album: 'Album A'),
          {'album'},
        ),
        {'album'},
      );
      await b.edit(
        'song.mp3',
        initial.merge(
          const SongMetadata(title: '', artist: '', lyrics: 'Lyrics B'),
          {'lyrics'},
        ),
        {'lyrics'},
      );
      var raced = false;
      client.beforeUpload = (file, parent, name, replace) async {
        if (!raced &&
            name.endsWith('.json') &&
            name != CloudHashIndex.fileName) {
          raced = true;
          expect((await b.sync()).failures, isEmpty);
        }
      };
      expect((await a.sync()).failures, isEmpty);
      await b.sync();
      expect(raced, isTrue);
      expect(b.snapshots['song.mp3']!.values.album, 'Album A');
      expect(b.snapshots['song.mp3']!.values.lyrics, 'Lyrics B');
      expect(
        (await SongMetadata.readFile(
          File(p.join(b.local.path, 'song.mp3')),
        )).$1.toJson(),
        b.snapshots['song.mp3']!.values.toJson(),
      );
      expect(
        client.files.values.where((file) => file.name.endsWith('.mp3')),
        hasLength(1),
      );
    },
  );

  for (final lostReply in [false, true]) {
    test(
      'a restarted retry never overwrites a later committed edit (lost reply=$lostReply)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'qingting-metadata-retry-',
        );
        addTearDown(() => root.delete(recursive: true));
        final client = _FakeCloudClient();
        final a = await _MetadataDevice.create(root, 'a', client),
            b = await _MetadataDevice.create(root, 'b', client);
        const initial = SongMetadata(
          title: 'Song',
          artist: 'Artist',
          album: 'Old',
        );
        await a.add('song.mp3', initial, DateTime(2020));
        await a.sync();
        await b.sync();
        await a.edit(
          'song.mp3',
          initial.merge(
            const SongMetadata(title: '', artist: '', album: 'First'),
            {'album'},
          ),
          {'album'},
        );
        final pending = a.snapshots['song.mp3']!;
        client.failAudioOnce = !lostReply;
        client.loseMetadataReplyOnce = lostReply;
        expect((await a.sync()).failures, hasLength(1));
        expect(a.snapshots['song.mp3']!.editId, pending.editId);
        await b.edit(
          'song.mp3',
          initial.merge(
            const SongMetadata(title: '', artist: '', album: 'Last'),
            {'album'},
          ),
          {'album'},
        );
        expect((await b.sync()).failures, isEmpty);
        final restarted = _MetadataDevice(
          a.local,
          CloudSyncService(
            client: client,
            stateDirectory: Directory(p.join(root.path, 'a-state')),
          ),
        );
        restarted.snapshots.addAll(a.snapshots);
        restarted.times.addAll(a.times);
        expect((await restarted.sync()).failures, isEmpty);
        expect(restarted.snapshots['song.mp3']!.values.album, 'Last');
        expect(
          (await SongMetadata.readFile(
            File(p.join(a.local.path, 'song.mp3')),
          )).$1.album,
          'Last',
        );
        expect(restarted.times['song.mp3'], DateTime(2020));
      },
    );
  }

  test(
    'first matching audio with different tags adopts identity and unchanged sync avoids payload reads',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-metadata-first-',
      );
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final a = await _MetadataDevice.create(root, 'a', client),
          b = await _MetadataDevice.create(root, 'b', client);
      final cover = Id3CoverImage(
        mimeType: 'image/png',
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a/YsAAAAASUVORK5CYII=',
        ),
      );
      await a.add(
        'song.mp3',
        SongMetadata(
          title: 'Cloud title',
          artist: 'Artist',
          coverHash: SongMetadata.hashCover(cover),
          coverMimeType: cover.mimeType,
        ),
        DateTime(2020),
        cover: cover,
      );
      await b.add(
        'song.mp3',
        const SongMetadata(title: 'Local title', artist: 'Artist'),
        DateTime(2021),
      );
      await a.sync();
      expect((await b.sync()).failures, isEmpty);
      expect(
        b.snapshots['song.mp3']!.baseline!.syncId,
        a.snapshots['song.mp3']!.baseline!.syncId,
      );
      expect(
        client.files.values.where((file) => file.name.endsWith('.mp3')),
        hasLength(1),
      );
      expect(b.times['song.mp3'], DateTime(2020));
      final before = Map<String, int>.from(client.downloadsByName);
      final result = await b.sync();
      expect(result.failures, isEmpty);
      expect(result.metadataUpdated, 0);
      for (final file in client.files.values.where(
        (file) => file.name != CloudHashIndex.fileName,
      )) {
        expect(client.downloadsByName[file.name], before[file.name]);
      }
    },
  );

  test(
    'metadata edits update both files and keep identity and original order',
    () async {
      final root = await Directory.systemTemp.createTemp('qingting-metadata-');
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final first = await _MetadataDevice.create(root, 'first', client);
      final second = await _MetadataDevice.create(root, 'second', client);
      final time = DateTime(2024, 2, 3);
      await first.add(
        'song.mp3',
        const SongMetadata(
          title: 'Original',
          artist: 'Artist',
          album: 'Old',
          lyrics: '[00:01]old',
        ),
        time,
      );
      await first.sync();
      await second.sync();
      final id = first.snapshots['song.mp3']!.baseline!.syncId;
      final audio = await mp3AudioHash(
        File(p.join(first.local.path, 'song.mp3')),
      );
      final cover = Id3CoverImage(
        mimeType: 'image/png',
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a/YsAAAAASUVORK5CYII=',
        ),
      );
      final values = SongMetadata(
        title: 'Renamed',
        artist: 'New artist',
        album: 'New album',
        lyrics: '[00:01]new lyrics',
        coverHash: SongMetadata.hashCover(cover),
        coverMimeType: cover.mimeType,
      );
      await first.edit('song.mp3', values, songMetadataFields, cover: cover);
      expect((await first.sync()).failures, isEmpty);
      final result = await second.sync();
      expect(result.failures, isEmpty);
      expect(second.snapshots['song.mp3']!.baseline!.syncId, id);
      expect(
        result.downloadedAtByPath[p.join(second.local.path, 'song.mp3')],
        time,
      );
      final read = await SongMetadata.readFile(
        File(p.join(second.local.path, 'song.mp3')),
      );
      expect(read.$1.toJson(), values.toJson());
      expect(
        await mp3AudioHash(File(p.join(second.local.path, 'song.mp3'))),
        audio,
      );
      expect(
        client.files.values.where((file) => file.name.endsWith('.mp3')),
        hasLength(1),
      );
      expect(
        (await second.local.list().toList()).whereType<File>().where(
          (f) => f.path.endsWith('.mp3'),
        ),
        hasLength(1),
      );
      expect(
        client.folders.values.map((f) => f.name),
        containsAll(['歌曲信息', '封面']),
      );
    },
  );

  test(
    'different fields merge and the last committed edit of one field wins',
    () async {
      final root = await Directory.systemTemp.createTemp('qingting-metadata-');
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final a = await _MetadataDevice.create(root, 'a', client),
          b = await _MetadataDevice.create(root, 'b', client);
      const initial = SongMetadata(
        title: 'Song',
        artist: 'Artist',
        album: 'Old',
        lyrics: 'old',
      );
      await a.add('song.mp3', initial, DateTime(2023));
      await a.sync();
      await b.sync();
      await a.edit(
        'song.mp3',
        initial.merge(
          const SongMetadata(title: '', artist: '', album: 'Album A'),
          {'album'},
        ),
        {'album'},
      );
      await b.edit(
        'song.mp3',
        initial.merge(
          const SongMetadata(title: '', artist: '', lyrics: 'Lyrics B'),
          {'lyrics'},
        ),
        {'lyrics'},
      );
      expect((await a.sync()).failures, isEmpty);
      expect((await b.sync()).failures, isEmpty);
      await a.sync();
      expect(a.snapshots['song.mp3']!.values.album, 'Album A');
      expect(a.snapshots['song.mp3']!.values.lyrics, 'Lyrics B');
      final base = a.snapshots['song.mp3']!.values;
      await a.edit(
        'song.mp3',
        base.merge(const SongMetadata(title: '', artist: '', album: 'First'), {
          'album',
        }),
        {'album'},
      );
      await b.edit(
        'song.mp3',
        base.merge(const SongMetadata(title: '', artist: '', album: 'Last'), {
          'album',
        }),
        {'album'},
      );
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.snapshots['song.mp3']!.values.album, 'Last');
      expect(
        client.files.values.where((file) => file.name.endsWith('.mp3')),
        hasLength(1),
      );
    },
  );

  test(
    'cleared text and cover sync explicitly and automatic fills preserve manual clears',
    () async {
      final root = await Directory.systemTemp.createTemp('qingting-metadata-');
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final a = await _MetadataDevice.create(root, 'a', client),
          b = await _MetadataDevice.create(root, 'b', client);
      final cover = Id3CoverImage(
        mimeType: 'image/png',
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a/YsAAAAASUVORK5CYII=',
        ),
      );
      await a.add(
        'song.mp3',
        SongMetadata(
          title: 'Song',
          artist: 'Artist',
          album: 'Old',
          lyrics: 'old',
          coverHash: SongMetadata.hashCover(cover),
          coverMimeType: cover.mimeType,
        ),
        DateTime(2023),
        cover: cover,
      );
      await a.sync();
      await b.sync();
      await a.edit(
        'song.mp3',
        const SongMetadata(title: 'Song', artist: '', album: '', lyrics: ''),
        {'artist', 'album', 'lyrics', 'cover'},
      );
      await a.sync();
      await b.sync();
      final cleared = await SongMetadata.readFile(
        File(p.join(b.local.path, 'song.mp3')),
      );
      expect(cleared.$1.artist, '');
      expect(cleared.$1.album, '');
      expect(cleared.$1.lyrics, '');
      expect(cleared.$2, isNull);
      await b.edit(
        'song.mp3',
        cleared.$1.merge(
          const SongMetadata(title: '', artist: '', album: 'Auto'),
          {'album'},
        ),
        {'album'},
        fillOnly: {'album'},
      );
      await b.sync();
      expect(b.snapshots['song.mp3']!.values.album, '');
    },
  );

  test(
    'non-MP3 information syncs without replacing audio and playing files are deferred',
    () async {
      final root = await Directory.systemTemp.createTemp('qingting-metadata-');
      addTearDown(() => root.delete(recursive: true));
      final client = _FakeCloudClient();
      final a = await _MetadataDevice.create(root, 'a', client),
          b = await _MetadataDevice.create(root, 'b', client);
      await a.add(
        'song.flac',
        const SongMetadata(title: 'Song', artist: 'Artist'),
        DateTime(2023),
      );
      await a.add(
        'playing.mp3',
        const SongMetadata(title: 'Playing', artist: 'Artist', album: 'Old'),
        DateTime(2024),
      );
      await a.sync();
      await b.sync();
      final bytes = await File(p.join(b.local.path, 'song.flac')).readAsBytes();
      await a.edit(
        'song.flac',
        const SongMetadata(
          title: 'Changed',
          artist: 'Artist',
          album: 'Album',
          lyrics: 'Lyrics',
        ),
        {'title', 'album', 'lyrics'},
      );
      await a.edit(
        'playing.mp3',
        const SongMetadata(title: 'Playing', artist: 'Artist', album: 'New'),
        {'album'},
      );
      await a.sync();
      final original = await File(
        p.join(b.local.path, 'playing.mp3'),
      ).readAsBytes();
      final deferred = await b.sync(defer: {'playing.mp3'});
      expect(deferred.failures, isEmpty);
      expect(b.snapshots['song.flac']!.values.album, 'Album');
      expect(
        await File(p.join(b.local.path, 'song.flac')).readAsBytes(),
        bytes,
      );
      expect(
        deferred
            .metadataByPath[p.join(b.local.path, 'playing.mp3')]!
            .pendingFileWrite,
        isTrue,
      );
      expect(
        await File(p.join(b.local.path, 'playing.mp3')).readAsBytes(),
        original,
      );
      await b.sync();
      expect(
        (await SongMetadata.readFile(
          File(p.join(b.local.path, 'playing.mp3')),
        )).$1.album,
        'New',
      );
    },
  );
  test(
    'exit finishes active transfers and checkpoints before skipping remaining songs',
    () async {
      final root = await Directory.systemTemp.createTemp('qingting-exit-');
      addTearDown(() => root.delete(recursive: true));
      final local = await Directory(p.join(root.path, 'songs')).create();
      final client = _ObservedCloudClient()..transferGate = Completer<void>();
      final sync = CloudSyncService(
        client: client,
        stateDirectory: Directory(p.join(root.path, 'state')),
      );
      for (final name in ['first.mp3', 'second.mp3', 'third.mp3']) {
        await File(p.join(local.path, name)).writeAsString('song $name');
      }
      var exiting = false;
      final operation = sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
        shouldStop: () => exiting,
      );
      await client.twoTransfersStarted.future.timeout(
        const Duration(seconds: 5),
      );
      exiting = true;
      client.transferGate!.complete();
      final result = await operation;
      expect(result.uploaded, 2);
      expect(client.uploads.length, 2);
      client.uploads.clear();
      final resumed = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(resumed.uploaded, 1);
      expect(client.uploads.length, 1);
      expect(
        client.files.values.where((file) => file.name.endsWith('.mp3')).length,
        3,
      );
      expect(resumed.failures, isEmpty);
    },
  );

  test(
    'two parallel uploads share parent creation and persist every record',
    () async {
      final root = await Directory.systemTemp.createTemp('qingting-parallel-');
      addTearDown(() => root.delete(recursive: true));
      final local = await Directory(p.join(root.path, 'songs')).create();
      final state = Directory(p.join(root.path, 'state'));
      final client = _ObservedCloudClient()..transferGate = Completer<void>();
      final sync = CloudSyncService(client: client, stateDirectory: state);
      await Directory(p.join(local.path, 'artist')).create();
      for (final name in ['first.mp3', 'second.mp3', 'third.mp3']) {
        await File(
          p.join(local.path, 'artist', name),
        ).writeAsString('song bytes');
      }
      final progress = <CloudSyncProgress>[];
      final operation = sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
        onProgress: progress.add,
      );
      await client.twoTransfersStarted.future.timeout(
        const Duration(seconds: 3),
      );
      expect(client.active, 2);
      expect(client.uploads, hasLength(2));
      client.transferGate!.complete();
      final result = await operation;
      expect(result.uploaded, 3);
      expect(result.failures, isEmpty);
      expect(client.maxActive, 2);
      expect(
        client.folderCreations.where((name) => name == 'artist'),
        hasLength(1),
      );
      expect(progress.any((value) => value.transfers.length == 2), isTrue);
      expect(
        progress.any(
          (value) => value.transfers.any(
            (transfer) =>
                transfer.fraction == 0.5 && transfer.bytesPerSecond > 0,
          ),
        ),
        isTrue,
      );
      expect(
        progress.map((value) => value.stage),
        containsAll([
          CloudSyncStage.readingCloud,
          CloudSyncStage.scanningLocal,
          CloudSyncStage.comparing,
          CloudSyncStage.hashing,
          CloudSyncStage.complete,
        ]),
      );
      expect(progress.last.completed, 3);
      expect(progress.last.total, 3);
      final manifest =
          (await state
                      .list()
                      .where(
                        (entry) =>
                            p.basename(entry.path).startsWith('cloud_sync_') &&
                            entry.path.endsWith('.json'),
                      )
                      .toList())
                  .single
              as File;
      expect(jsonDecode(await manifest.readAsString()), hasLength(3));
      final oldTime = DateTime(2024);
      await manifest.setLastModified(oldTime);
      client.uploads.clear();
      final unchanged = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(unchanged.skipped, 3);
      expect(client.uploads, isEmpty);
      expect((await manifest.stat()).modified, oldTime);
    },
  );

  for (final uploading in [true, false]) {
    test(
      '${uploading ? 'upload' : 'download'} failures continue and retry only failed paths',
      () async {
        final root = await Directory.systemTemp.createTemp('qingting-retry-');
        addTearDown(() => root.delete(recursive: true));
        final local = await Directory(p.join(root.path, 'songs')).create();
        final client = _ObservedCloudClient();
        final sync = CloudSyncService(
          client: client,
          stateDirectory: Directory(p.join(root.path, 'state')),
        );
        for (final name in ['failed.mp3', 'good.mp3']) {
          if (uploading) {
            await File(p.join(local.path, name)).writeAsString('song');
          } else {
            client.putRemote(name, 'song', id: name);
          }
        }
        (uploading ? client.failedUploads : client.failedDownloads).add(
          'failed.mp3',
        );
        final first = await sync.sync(
          cloudFolderId: 'root',
          localDirectory: local,
        );
        expect(uploading ? first.uploaded : first.downloaded, 1);
        expect(first.failures.single.path, 'failed.mp3');
        expect(
          first.failures.single.stage,
          uploading ? CloudSyncStage.uploading : CloudSyncStage.downloading,
        );
        await File(
          p.join(local.path, 'unrelated.mp3'),
        ).writeAsString('new song');
        client.failedUploads.clear();
        client.failedDownloads.clear();
        client.uploads.clear();
        client.downloads.clear();
        final retry = await sync.sync(
          cloudFolderId: 'root',
          localDirectory: local,
          onlyPaths: {first.failures.single.path},
        );
        expect(retry.failures, isEmpty);
        expect(uploading ? retry.uploaded : retry.downloaded, 1);
        expect(uploading ? client.uploads : client.downloads, ['failed.mp3']);
        expect(
          client.files.values.any((file) => file.name == 'unrelated.mp3'),
          isFalse,
        );
        expect(
          await File(p.join(local.path, 'failed.mp3')).readAsString(),
          'song',
        );
      },
    );
  }

  test(
    'failed cloud deletion cannot redownload and other songs continue',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-delete-failure-',
      );
      addTearDown(() => root.delete(recursive: true));
      final local = await Directory(p.join(root.path, 'songs')).create();
      final client = _ObservedCloudClient();
      final sync = CloudSyncService(
        client: client,
        stateDirectory: Directory(p.join(root.path, 'state')),
      );
      final removed = await File(
        p.join(local.path, 'removed.mp3'),
      ).writeAsString('old');
      await sync.setDeletionPolicy('root', true);
      await sync.sync(cloudFolderId: 'root', localDirectory: local);
      await removed.delete();
      await File(p.join(local.path, 'new.mp3')).writeAsString('new');
      client.failedDeletions.add('removed.mp3');
      final failed = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(failed.uploaded, 1);
      expect(failed.failures.single.path, 'removed.mp3');
      expect(failed.failures.single.stage, CloudSyncStage.applyingDeletions);
      expect(await removed.exists(), isFalse);
      client.failedDeletions.clear();
      final retry = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
        onlyPaths: {'removed.mp3'},
      );
      expect(retry.failures, isEmpty);
      expect(
        client.files.values.any((file) => file.name == 'removed.mp3'),
        isFalse,
      );
      expect(await removed.exists(), isFalse);
    },
  );
  test('songs and sync data use separate managed cloud folders', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    final client = _FakeCloudClient();
    final sync = CloudSyncService(
      client: client,
      stateDirectory: Directory('${root.path}${Platform.pathSeparator}state'),
    );
    try {
      await Directory(
        '${local.path}${Platform.pathSeparator}artist',
      ).create(recursive: true);
      await File(
        '${local.path}${Platform.pathSeparator}artist'
        '${Platform.pathSeparator}track.mp3',
      ).writeAsString('song');
      client.files['unrelated'] = const AnyShareFile(
        id: 'unrelated',
        name: 'unrelated.mp3',
        rev: 'rev-unrelated',
        size: 7,
      );
      client.content['unrelated'] = 'outside'.codeUnits;
      client.fileParents['unrelated'] = 'root';

      final result = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(result.uploaded, 1);
      expect(
        await File(
          '${local.path}${Platform.pathSeparator}unrelated.mp3',
        ).exists(),
        isFalse,
      );
      final songs = client.folders.values.singleWhere(
        (folder) => folder.name == CloudSyncService.songsFolderName,
      );
      final data = client.folders.values.singleWhere(
        (folder) => folder.name == CloudSyncService.dataFolderName,
      );
      expect(client.folderParents[songs.id], 'root');
      expect(client.folderParents[data.id], 'root');
      final artist = client.folders.values.singleWhere(
        (folder) => folder.name == 'artist',
      );
      expect(client.folderParents[artist.id], songs.id);
      final song = client.files.values.singleWhere(
        (file) => file.name == 'track.mp3',
      );
      expect(client.fileParents[song.id], artist.id);
      final index = client.files.values.singleWhere(
        (file) => file.name == CloudHashIndex.fileName,
      );
      expect(client.fileParents[index.id], data.id);
      expect(client.fileParents['unrelated'], 'root');
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('a missing managed songs folder does not delete local songs', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    final client = _FakeCloudClient();
    final sync = CloudSyncService(
      client: client,
      stateDirectory: Directory('${root.path}${Platform.pathSeparator}state'),
    );
    try {
      await local.create();
      final song = File('${local.path}${Platform.pathSeparator}song.mp3');
      await song.writeAsString('song');
      await sync.setDeletionPolicy('root', true);
      await sync.sync(cloudFolderId: 'root', localDirectory: local);
      final songs = client.folders.values.singleWhere(
        (folder) => folder.name == CloudSyncService.songsFolderName,
      );
      client.folders.remove(songs.id);
      client.folderParents.remove(songs.id);

      await expectLater(
        sync.sync(cloudFolderId: 'root', localDirectory: local),
        throwsA(isA<FormatException>()),
      );
      expect(await song.readAsString(), 'song');
      expect(client.deleteRequests, 0);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('local and remote deletions do not propagate', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    final state = Directory('${root.path}${Platform.pathSeparator}state');
    final client = _FakeCloudClient();
    final sync = CloudSyncService(client: client, stateDirectory: state);
    try {
      await local.create();
      final song = File('${local.path}${Platform.pathSeparator}song.mp3');
      await song.writeAsString('original');
      expect(
        (await sync.sync(
          cloudFolderId: 'root',
          localDirectory: local,
        )).uploaded,
        1,
      );
      await song.delete();
      expect(
        (await sync.sync(
          cloudFolderId: 'root',
          localDirectory: local,
        )).downloaded,
        1,
      );
      expect(await song.readAsString(), 'original');
      client.files.clear();
      client.content.clear();
      await sync.sync(cloudFolderId: 'root', localDirectory: local);
      expect(await song.exists(), isTrue);
      expect(
        client.files.values
            .where((file) => file.name.endsWith('.mp3'))
            .single
            .name,
        'song.mp3',
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('simultaneous edits preserve both song versions', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    final state = Directory('${root.path}${Platform.pathSeparator}state');
    final client = _FakeCloudClient()..putRemote('song.mp3', 'base');
    final sync = CloudSyncService(client: client, stateDirectory: state);
    try {
      await local.create();
      await sync.sync(cloudFolderId: 'root', localDirectory: local);
      final song = File('${local.path}${Platform.pathSeparator}song.mp3');
      await song.writeAsString('local revision');
      client.putRemote('song.mp3', 'cloud revision');
      final result = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(result.downloaded, 1);
      expect(result.uploaded, 1);
      expect(await song.readAsString(), 'cloud revision');
      final conflict = File(
        '${local.path}${Platform.pathSeparator}'
        'song (本地冲突).mp3',
      );
      expect(await conflict.readAsString(), 'local revision');
      expect(
        client.files.values.where((file) => file.name.endsWith('.mp3')),
        hasLength(2),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('recovers a corrupt sync record from its backup', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    final state = Directory('${root.path}${Platform.pathSeparator}state');
    final client = _FakeCloudClient()..putRemote('song.mp3', 'saved song');
    final sync = CloudSyncService(client: client, stateDirectory: state);
    try {
      await local.create();
      await sync.sync(cloudFolderId: 'root', localDirectory: local);
      final manifest = await state
          .list()
          .where((item) => item is File)
          .cast<File>()
          .first;
      await manifest.copy('${manifest.path}.bak');
      await manifest.writeAsString('{broken');
      final result = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(result.skipped, 1);
      expect(await manifest.readAsString(), isNot('{broken'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('a second device matches a song using the shared cloud hash', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient()..putRemote('song.mp3', 'same song');
    final first = Directory('${root.path}${Platform.pathSeparator}first');
    final second = Directory('${root.path}${Platform.pathSeparator}second');
    try {
      await first.create();
      await second.create();
      await File(
        '${first.path}${Platform.pathSeparator}song.mp3',
      ).writeAsString('same song');
      await File(
        '${second.path}${Platform.pathSeparator}song.mp3',
      ).writeAsString('same song');
      final firstSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state1',
        ),
      );
      final secondSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state2',
        ),
      );

      expect(
        (await firstSync.sync(
          cloudFolderId: 'root',
          localDirectory: first,
        )).skipped,
        1,
      );
      expect(client.audioDownloads, 1);
      expect(
        client.files.values.any(
          (file) => file.name == 'QingTing-sync-index.json',
        ),
        isTrue,
      );

      expect(
        (await secondSync.sync(
          cloudFolderId: 'root',
          localDirectory: second,
        )).skipped,
        1,
      );
      expect(client.audioDownloads, 1);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('a changed cloud revision ignores an old shared hash', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient()..putRemote('song.mp3', 'old song');
    final first = Directory('${root.path}${Platform.pathSeparator}first');
    final second = Directory('${root.path}${Platform.pathSeparator}second');
    try {
      await first.create();
      await second.create();
      await File(
        '${first.path}${Platform.pathSeparator}song.mp3',
      ).writeAsString('old song');
      await File(
        '${second.path}${Platform.pathSeparator}song.mp3',
      ).writeAsString('old song');
      await CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state1',
        ),
      ).sync(cloudFolderId: 'root', localDirectory: first);
      client.putRemote('song.mp3', 'new song');

      final result = await CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state2',
        ),
      ).sync(cloudFolderId: 'root', localDirectory: second);
      expect(result.downloaded, 1);
      expect(client.audioDownloads, 2);
      expect(
        await File(
          '${second.path}${Platform.pathSeparator}song.mp3',
        ).readAsString(),
        'new song',
      );
      expect(
        await File(
          '${second.path}${Platform.pathSeparator}'
          'song (本地冲突).mp3',
        ).readAsString(),
        'old song',
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('cloud hash updates from two devices are merged', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient();
    const firstSong = AnyShareFile(
      id: 'first',
      name: 'first.mp3',
      rev: 'first-rev',
      size: 1,
    );
    const secondSong = AnyShareFile(
      id: 'second',
      name: 'second.mp3',
      rev: 'second-rev',
      size: 1,
    );
    final firstHash = sha256.convert([1]).toString();
    final secondHash = sha256.convert([2]).toString();
    try {
      final firstIndex = await CloudHashIndex.open(
        client: client,
        folderId: 'root',
        workingFile: File('${root.path}${Platform.pathSeparator}first.json'),
      );
      final secondIndex = await CloudHashIndex.open(
        client: client,
        folderId: 'root',
        workingFile: File('${root.path}${Platform.pathSeparator}second.json'),
      );
      firstIndex.remember(firstSong, firstHash);
      firstIndex.setDeletionPolicy(true);
      secondIndex.remember(secondSong, secondHash);
      await firstIndex.flush();
      await secondIndex.flush();

      final remoteIndex = client.files.values.singleWhere(
        (file) => file.name == CloudHashIndex.fileName,
      );
      final restored = await CloudHashIndex.open(
        client: client,
        folderId: 'root',
        workingFile: File('${root.path}${Platform.pathSeparator}third.json'),
        remoteFile: remoteIndex,
      );
      expect(restored.hashFor(firstSong), firstHash);
      expect(restored.hashFor(secondSong), secondHash);
      expect(restored.deletionPolicyEnabled, isTrue);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'local deletion writes a tombstone and removes the other copy',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-cloud-test-',
      );
      final client = _FakeCloudClient();
      final first = Directory('${root.path}${Platform.pathSeparator}first');
      final second = Directory('${root.path}${Platform.pathSeparator}second');
      try {
        await first.create();
        await second.create();
        final firstFile = File(
          '${first.path}${Platform.pathSeparator}song.mp3',
        );
        final secondFile = File(
          '${second.path}${Platform.pathSeparator}song.mp3',
        );
        await firstFile.writeAsString('same song');
        final firstSync = CloudSyncService(
          client: client,
          stateDirectory: Directory(
            '${root.path}${Platform.pathSeparator}state1',
          ),
        );
        final secondSync = CloudSyncService(
          client: client,
          stateDirectory: Directory(
            '${root.path}${Platform.pathSeparator}state2',
          ),
        );
        await firstSync.setDeletionPolicy('root', true);
        await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
        await secondSync.sync(cloudFolderId: 'root', localDirectory: second);
        expect(await secondFile.exists(), isTrue);
        await firstFile.delete();
        await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
        expect(client.files.values.where((f) => f.name == 'song.mp3'), isEmpty);
        final result = await secondSync.sync(
          cloudFolderId: 'root',
          localDirectory: second,
        );
        expect(await secondFile.exists(), isFalse);
        expect(result.deletedLocalPaths, contains(secondFile.path));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'an old deletion still applies after the shared switch is off',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-cloud-test-',
      );
      final client = _FakeCloudClient();
      final first = Directory('${root.path}${Platform.pathSeparator}first');
      final second = Directory('${root.path}${Platform.pathSeparator}second');
      final firstSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state1',
        ),
      );
      final secondSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state2',
        ),
      );
      try {
        await first.create();
        await second.create();
        final source = File('${first.path}${Platform.pathSeparator}song.mp3');
        final copy = File('${second.path}${Platform.pathSeparator}song.mp3');
        await source.writeAsString('same song');
        await firstSync.setDeletionPolicy('root', true);
        expect(await secondSync.readDeletionPolicy('root'), isTrue);
        await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
        await secondSync.sync(cloudFolderId: 'root', localDirectory: second);
        await source.delete();
        await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
        await firstSync.setDeletionPolicy('root', false);
        expect(await secondSync.readDeletionPolicy('root'), isFalse);

        final result = await secondSync.sync(
          cloudFolderId: 'root',
          localDirectory: second,
        );
        expect(result.deletionPolicyEnabled, isFalse);
        expect(result.deletedLocalPaths, contains(copy.path));
        expect(await copy.exists(), isFalse);
        expect(client.files.values.where((f) => f.name == 'song.mp3'), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('switching off stops new deletion records', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient();
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    final sync = CloudSyncService(
      client: client,
      stateDirectory: Directory('${root.path}${Platform.pathSeparator}state'),
    );
    try {
      await local.create();
      final song = File('${local.path}${Platform.pathSeparator}song.mp3');
      await song.writeAsString('song');
      await sync.setDeletionPolicy('root', true);
      await sync.sync(cloudFolderId: 'root', localDirectory: local);
      await sync.setDeletionPolicy('root', false);
      await song.delete();
      final result = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(result.downloaded, 1);
      expect(await song.readAsString(), 'song');
      expect(client.deleteRequests, 0);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('a missing protected index stops uploads', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient();
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    final sync = CloudSyncService(
      client: client,
      stateDirectory: Directory('${root.path}${Platform.pathSeparator}state'),
    );
    try {
      await local.create();
      await sync.setDeletionPolicy('root', true);
      final index = client.files.values.singleWhere(
        (file) => file.name == CloudHashIndex.fileName,
      );
      client.confirmDeletion(index.id);
      await File(
        '${local.path}${Platform.pathSeparator}song.mp3',
      ).writeAsString('song');
      await expectLater(
        sync.sync(cloudFolderId: 'root', localDirectory: local),
        throwsA(isA<FormatException>()),
      );
      expect(
        client.files.values.where((file) => file.name == 'song.mp3'),
        isEmpty,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('a deletion marker keeps a changed local song', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient();
    final first = Directory('${root.path}${Platform.pathSeparator}first');
    final second = Directory('${root.path}${Platform.pathSeparator}second');
    try {
      await first.create();
      await second.create();
      final firstFile = File('${first.path}${Platform.pathSeparator}song.mp3');
      final secondFile = File(
        '${second.path}${Platform.pathSeparator}song.mp3',
      );
      await firstFile.writeAsString('same song');
      final firstSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state1',
        ),
      );
      final secondSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state2',
        ),
      );
      await firstSync.setDeletionPolicy('root', true);
      await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
      await secondSync.sync(cloudFolderId: 'root', localDirectory: second);
      await secondFile.writeAsString('changed local song');
      await firstFile.delete();
      await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
      await secondSync.sync(cloudFolderId: 'root', localDirectory: second);
      expect(await secondFile.readAsString(), 'changed local song');
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'a cloud deletion removes a known local copy and publishes a marker',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-cloud-test-',
      );
      final client = _FakeCloudClient();
      final first = Directory('${root.path}${Platform.pathSeparator}first');
      final second = Directory('${root.path}${Platform.pathSeparator}second');
      try {
        await first.create();
        await second.create();
        final firstFile = File(
          '${first.path}${Platform.pathSeparator}song.mp3',
        );
        final secondFile = File(
          '${second.path}${Platform.pathSeparator}song.mp3',
        );
        await firstFile.writeAsString('same song');
        await secondFile.writeAsString('same song');
        final firstSync = CloudSyncService(
          client: client,
          stateDirectory: Directory(
            '${root.path}${Platform.pathSeparator}state1',
          ),
        );
        final secondSync = CloudSyncService(
          client: client,
          stateDirectory: Directory(
            '${root.path}${Platform.pathSeparator}state2',
          ),
        );
        await firstSync.setDeletionPolicy('root', true);
        await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
        final remoteSong = client.files.values.singleWhere(
          (file) => file.name == 'song.mp3',
        );
        await client.deleteFile(remoteSong);
        final firstResult = await firstSync.sync(
          cloudFolderId: 'root',
          localDirectory: first,
        );
        expect(await firstFile.exists(), isFalse);
        expect(firstResult.deletedLocalPaths, contains(firstFile.path));
        final secondResult = await secondSync.sync(
          cloudFolderId: 'root',
          localDirectory: second,
        );
        expect(await secondFile.exists(), isFalse);
        expect(secondResult.deletedLocalPaths, contains(secondFile.path));
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('a downloaded song retains its original download time', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient();
    final first = Directory('${root.path}${Platform.pathSeparator}first');
    final second = Directory('${root.path}${Platform.pathSeparator}second');
    final original = DateTime(2025, 2, 3, 4, 5);
    try {
      await first.create();
      await second.create();
      final song = File('${first.path}${Platform.pathSeparator}song.mp3');
      await song.writeAsString('song');
      await CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state1',
        ),
      ).sync(
        cloudFolderId: 'root',
        localDirectory: first,
        downloadedAtByPath: {'song.mp3': original},
      );
      final result = await CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state2',
        ),
      ).sync(cloudFolderId: 'root', localDirectory: second);
      final copy = File('${second.path}${Platform.pathSeparator}song.mp3');
      expect(
        (await copy.stat()).modified.millisecondsSinceEpoch,
        original.millisecondsSinceEpoch,
      );
      expect(result.downloadedAtByPath[copy.path], original);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'a 202 deletion waits for cloud removal before deleting another device',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'qingting-cloud-test-',
      );
      final client = _FakeCloudClient();
      final first = Directory('${root.path}${Platform.pathSeparator}first');
      final second = Directory('${root.path}${Platform.pathSeparator}second');
      try {
        await first.create();
        await second.create();
        final source = File('${first.path}${Platform.pathSeparator}song.mp3');
        final other = File('${second.path}${Platform.pathSeparator}song.mp3');
        await source.writeAsString('song');
        final firstSync = CloudSyncService(
          client: client,
          stateDirectory: Directory(
            '${root.path}${Platform.pathSeparator}state1',
          ),
        );
        final secondSync = CloudSyncService(
          client: client,
          stateDirectory: Directory(
            '${root.path}${Platform.pathSeparator}state2',
          ),
        );
        await firstSync.setDeletionPolicy('root', true);
        await firstSync.sync(cloudFolderId: 'root', localDirectory: first);
        await secondSync.sync(cloudFolderId: 'root', localDirectory: second);
        final remoteId = client.files.values
            .singleWhere((file) => file.name == 'song.mp3')
            .id;
        client.deleteStatus = AnyShareDeleteStatus.pendingApproval;
        await source.delete();
        final pending = await firstSync.sync(
          cloudFolderId: 'root',
          localDirectory: first,
        );
        expect(pending.pendingApproval, 1);
        expect(client.deleteRequests, 1);
        expect(client.files.containsKey(remoteId), isTrue);
        await secondSync.sync(cloudFolderId: 'root', localDirectory: second);
        expect(await other.exists(), isTrue);
        final resumedSync = CloudSyncService(
          client: client,
          stateDirectory: Directory(
            '${root.path}${Platform.pathSeparator}state1',
          ),
        );
        await resumedSync.sync(cloudFolderId: 'root', localDirectory: first);
        expect(client.deleteRequests, 1);
        expect(await source.exists(), isFalse);

        client.confirmDeletion(remoteId);
        final confirmed = await resumedSync.sync(
          cloudFolderId: 'root',
          localDirectory: first,
        );
        expect(confirmed.pendingApproval, 0);
        await secondSync.sync(cloudFolderId: 'root', localDirectory: second);
        expect(await other.exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('a 200 deletion waits while the cloud still lists the file', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient()..deferDeletion = true;
    final local = Directory('${root.path}${Platform.pathSeparator}songs');
    try {
      await local.create();
      final song = File('${local.path}${Platform.pathSeparator}song.mp3');
      await song.writeAsString('song');
      final sync = CloudSyncService(
        client: client,
        stateDirectory: Directory('${root.path}${Platform.pathSeparator}state'),
      );
      await sync.setDeletionPolicy('root', true);
      await sync.sync(cloudFolderId: 'root', localDirectory: local);
      await song.delete();
      final pending = await sync.sync(
        cloudFolderId: 'root',
        localDirectory: local,
      );
      expect(pending.pendingRemoval, 1);
      expect(
        client.files.values.any((file) => file.name == 'song.mp3'),
        isTrue,
      );
      expect(await song.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('explicit local order overrides earlier order and stays pinned', () async {
    final root = await Directory.systemTemp.createTemp('qingting-cloud-test-');
    final client = _FakeCloudClient();
    final desktop = Directory('${root.path}${Platform.pathSeparator}desktop');
    final phone = Directory('${root.path}${Platform.pathSeparator}phone');
    final desktopFirst = DateTime(2024, 1, 1);
    final desktopSecond = DateTime(2024, 1, 2);
    final phoneFirst = DateTime(2025, 1, 2);
    final phoneSecond = DateTime(2025, 1, 1);
    try {
      await desktop.create();
      await phone.create();
      for (final folder in [desktop, phone]) {
        await File(
          '${folder.path}${Platform.pathSeparator}first.mp3',
        ).writeAsString('first');
        await File(
          '${folder.path}${Platform.pathSeparator}second.mp3',
        ).writeAsString('second');
      }
      final desktopSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state1',
        ),
      );
      final phoneSync = CloudSyncService(
        client: client,
        stateDirectory: Directory(
          '${root.path}${Platform.pathSeparator}state2',
        ),
      );
      final desktopTimes = {
        'first.mp3': desktopFirst,
        'second.mp3': desktopSecond,
      };
      final phoneTimes = {'first.mp3': phoneFirst, 'second.mp3': phoneSecond};
      await desktopSync.sync(
        cloudFolderId: 'root',
        localDirectory: desktop,
        downloadedAtByPath: desktopTimes,
      );
      final chosen = await phoneSync.sync(
        cloudFolderId: 'root',
        localDirectory: phone,
        downloadedAtByPath: phoneTimes,
        preferLocalOrder: true,
      );
      expect(chosen.orderPublished, 2);
      final desktopResult = await desktopSync.sync(
        cloudFolderId: 'root',
        localDirectory: desktop,
        downloadedAtByPath: desktopTimes,
      );
      expect(
        desktopResult
            .downloadedAtByPath['${desktop.path}${Platform.pathSeparator}first.mp3'],
        phoneFirst,
      );
      expect(
        desktopResult
            .downloadedAtByPath['${desktop.path}${Platform.pathSeparator}second.mp3'],
        phoneSecond,
      );
      final reselected = await desktopSync.sync(
        cloudFolderId: 'root',
        localDirectory: desktop,
        downloadedAtByPath: desktopTimes,
        preferLocalOrder: true,
      );
      expect(reselected.orderPublished, 2);
      final phoneResult = await phoneSync.sync(
        cloudFolderId: 'root',
        localDirectory: phone,
        downloadedAtByPath: phoneTimes,
      );
      expect(
        phoneResult
            .downloadedAtByPath['${phone.path}${Platform.pathSeparator}first.mp3'],
        desktopFirst,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
