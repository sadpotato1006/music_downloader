import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'anyshare_client.dart';
import 'app_log.dart';
import 'async_utils.dart';
import 'cloud_hash_index.dart';
import 'coalescing_write_queue.dart';
import 'cloud_song_metadata.dart';
import 'song_metadata.dart';
import 'id3_lyrics_embedder.dart';

const cloudAudioExtensions = {'mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg'};

enum CloudSyncStage {
  preparing('准备同步'),
  readingCloud('读取云盘目录'),
  scanningLocal('读取本地目录'),
  applyingDeletions('处理同步删除'),
  comparing('比较歌曲文件'),
  hashing('计算歌曲哈希'),
  transferring('同步歌曲'),
  uploading('上传'),
  downloading('下载'),
  savingIndex('保存同步记录'),
  scanningLibrary('扫描当前下载目录'),
  waitingForAlbums('等待专辑写入'),
  syncingMetadata('同步歌曲信息'),
  complete('同步完成');

  const CloudSyncStage(this.label);
  final String label;
}

class CloudSyncTransferProgress {
  const CloudSyncTransferProgress({
    required this.path,
    required this.stage,
    required this.bytes,
    required this.totalBytes,
    required this.bytesPerSecond,
  });
  final String path;
  final CloudSyncStage stage;
  final int bytes;
  final int totalBytes;
  final double bytesPerSecond;
  double? get fraction =>
      totalBytes <= 0 ? null : (bytes / totalBytes).clamp(0.0, 1.0);
}

class CloudSyncFailure {
  const CloudSyncFailure({
    required this.path,
    required this.stage,
    required this.message,
  });
  final String path;
  final CloudSyncStage stage;
  final String message;
}

class CloudSyncProgress {
  const CloudSyncProgress({
    required this.completed,
    required this.total,
    required this.uploaded,
    required this.downloaded,
    required this.current,
    this.stage = CloudSyncStage.comparing,
    this.failed = 0,
    this.transfers = const [],
  });
  final int completed;
  final int total;
  final int uploaded;
  final int downloaded;
  final String current;
  final CloudSyncStage stage;
  final int failed;
  final List<CloudSyncTransferProgress> transfers;
}

class CloudSyncResult {
  const CloudSyncResult({
    required this.uploaded,
    required this.downloaded,
    required this.skipped,
    this.deletedLocalPaths = const {},
    this.downloadedAtByPath = const {},
    this.pendingApproval = 0,
    this.pendingRemoval = 0,
    this.orderPublished = 0,
    this.deletionPolicyEnabled = false,
    this.failures = const [],
    this.metadataByPath = const {},
    this.metadataUpdated = 0,
  });
  final int uploaded;
  final int downloaded;
  final int skipped;
  final Set<String> deletedLocalPaths;
  final Map<String, DateTime> downloadedAtByPath;
  final int pendingApproval;
  final int pendingRemoval;
  final int orderPublished;
  final bool deletionPolicyEnabled;
  final List<CloudSyncFailure> failures;
  final Map<String, SyncedSongMetadata> metadataByPath;
  final int metadataUpdated;
}

class CloudSyncService {
  static const songsFolderName = '青听歌曲';
  static const dataFolderName = '青听数据';

  CloudSyncService({required this.client, Directory? stateDirectory})
    : _stateDirectoryOverride = stateDirectory;

  final AnyShareClient client;
  final Directory? _stateDirectoryOverride;

  Future<bool> readDeletionPolicy(String cloudFolderId) async =>
      (await _openPolicyIndex(cloudFolderId)).deletionPolicyEnabled;

  Future<bool> setDeletionPolicy(String cloudFolderId, bool enabled) async {
    final index = await _openPolicyIndex(cloudFolderId);
    index.setDeletionPolicy(enabled);
    await index.flush(required: true);
    final saved = await readDeletionPolicy(cloudFolderId);
    if (saved != enabled) {
      throw StateError('云盘同步删除设置被其他设备同时修改，请重试');
    }
    if (enabled) await _markDeletionProtected(cloudFolderId);
    return saved;
  }

  Future<CloudHashIndex> _openPolicyIndex(
    String folderId, {
    AnyShareFolder? dataFolder,
  }) async {
    dataFolder ??= (await _prepareCloudLayout(folderId)).data;
    final children = await client.listChildren(dataFolder.id);
    final matches = children.files
        .where((file) => file.name == CloudHashIndex.fileName)
        .toList();
    if (matches.length > 1) {
      throw const FormatException('云端歌曲索引有多个同名文件，已停止同步');
    }
    if (matches.isEmpty && await _deletionProtectionExists(folderId)) {
      throw const FormatException('云端删除记录消失，已停止同步以保护歌曲');
    }
    final directory =
        _stateDirectoryOverride ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final index = await CloudHashIndex.open(
      client: client,
      folderId: dataFolder.id,
      workingFile: File(
        p.join(directory.path, 'cloud_policy_${_folderKey(folderId)}.part'),
      ),
      remoteFile: matches.firstOrNull,
    );
    if (!index.available) {
      throw const FormatException('云端同步设置无法读取，已停止同步以保护歌曲');
    }
    if (index.deletionPolicyEnabled || index.deletions.isNotEmpty) {
      await _markDeletionProtected(folderId);
    }
    return index;
  }

  String _folderKey(String folderId) =>
      sha256.convert(utf8.encode(folderId)).toString();

  Future<({AnyShareFolder songs, AnyShareFolder data})> _prepareCloudLayout(
    String rootId,
  ) async {
    final root = await client.listChildren(rootId);
    AnyShareFolder? existing(String name) {
      if (root.files.any((file) => file.name == name)) {
        throw FormatException('云盘已有同名文件“$name”，无法创建同步目录');
      }
      final matches = root.folders
          .where((folder) => folder.name == name)
          .toList();
      if (matches.length > 1) {
        throw FormatException('云盘存在多个“$name”文件夹，已停止同步');
      }
      return matches.firstOrNull;
    }

    final existingSongs = existing(songsFolderName);
    final existingData = existing(dataFolderName);
    if (existingSongs == null && existingData != null) {
      throw const FormatException('云盘“青听歌曲”目录消失，已停止同步以保护歌曲');
    }
    if (existingSongs != null && existingData == null) {
      throw const FormatException('云盘“青听数据”目录消失，已停止同步以保护删除记录');
    }
    final songs =
        existingSongs ?? await _ensureManagedFolder(rootId, songsFolderName);
    final data =
        existingData ?? await _ensureManagedFolder(rootId, dataFolderName);
    return (songs: songs, data: data);
  }

  Future<AnyShareFolder> _ensureManagedFolder(
    String parentId,
    String name,
  ) async {
    Future<AnyShareFolder?> findExisting() async {
      final children = await client.listChildren(parentId);
      if (children.files.any((file) => file.name == name)) {
        throw FormatException('云盘已有同名文件“$name”，无法创建同步目录');
      }
      final matches = children.folders
          .where((folder) => folder.name == name)
          .toList();
      if (matches.length > 1) {
        throw FormatException('云盘存在多个“$name”文件夹，已停止同步');
      }
      return matches.firstOrNull;
    }

    final existing = await findExisting();
    if (existing != null) return existing;
    try {
      return await client.createFolder(parentId, name);
    } on DioException catch (error) {
      if (error.response?.statusCode != 400 &&
          error.response?.statusCode != 409 &&
          error.response?.statusCode != 412) {
        rethrow;
      }
      final createdElsewhere = await findExisting();
      if (createdElsewhere != null) return createdElsewhere;
      rethrow;
    }
  }

  Future<File> _deletionProtectionFile(String folderId) async {
    final directory =
        _stateDirectoryOverride ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File(
      p.join(
        directory.path,
        'cloud_deletion_v2_${_folderKey(folderId)}.marker',
      ),
    );
  }

  Future<bool> _deletionProtectionExists(String folderId) async =>
      (await _deletionProtectionFile(folderId)).exists();

  Future<void> _markDeletionProtected(String folderId) async {
    await (await _deletionProtectionFile(
      folderId,
    )).writeAsString('1', flush: true);
  }

  Future<CloudSyncResult> sync({
    required String cloudFolderId,
    required Directory localDirectory,
    Set<String> skipPaths = const {},
    Map<String, DateTime> downloadedAtByPath = const {},
    bool preferLocalOrder = false,
    Set<String>? onlyPaths,
    void Function(CloudSyncProgress progress)? onProgress,
    void Function(bool enabled)? onDeletionPolicyLoaded,
    bool Function()? shouldStop,
    Future<LocalSongMetadata?> Function(String relativePath)? readLocalMetadata,
    Set<String> deferFilePaths = const {},
  }) async {
    final progress = _CloudSyncReporter(onProgress);
    progress.status(CloudSyncStage.preparing);
    if (!await localDirectory.exists()) {
      throw FileSystemException('本地歌曲目录不存在', localDirectory.path);
    }
    final manifestFile = await _manifestFile(
      cloudFolderId,
      localDirectory.path,
    );
    final records = await _loadManifest(manifestFile);
    progress.status(CloudSyncStage.readingCloud);
    final layout = await _prepareCloudLayout(cloudFolderId);
    final songsFolder = layout.songs;
    final hashIndex = await _openPolicyIndex(
      cloudFolderId,
      dataFolder: layout.data,
    );
    final remote = <String, AnyShareFile>{};
    final folders = <String, String>{'': songsFolder.id};
    await _walkCloud(songsFolder.id, '', remote, folders);
    onDeletionPolicyLoaded?.call(hashIndex.deletionPolicyEnabled);
    progress.status(CloudSyncStage.scanningLocal);
    final local = await _scanLocal(localDirectory, skipPaths);
    CloudSongMetadataStore? metadataStore;
    if (readLocalMetadata != null) {
      final metadataFolder = await _ensureManagedFolder(
        layout.data.id,
        CloudSongMetadataStore.metadataFolderName,
      );
      final coverFolder = await _ensureManagedFolder(
        layout.data.id,
        CloudSongMetadataStore.coverFolderName,
      );
      metadataStore = CloudSongMetadataStore(
        client: client,
        metadataFolder: metadataFolder.id,
        coverFolder: coverFolder.id,
        workingDirectory: Directory(
          p.join(
            manifestFile.parent.path,
            'cloud_metadata_${_folderKey('$cloudFolderId|${localDirectory.path}')}',
          ),
        ),
      );
      await metadataStore.open();
    }
    final syncedMetadata = <String, SyncedSongMetadata>{};
    final changedMetadataPaths = <String>{};
    final deferredKeys = deferFilePaths
        .map((path) => p.normalize(path))
        .toSet();
    final skippedKeys = skipPaths
        .map((path) => p.normalize(path).toLowerCase())
        .toSet();
    final recordByRemoteId = {
      for (final entry in records.entries) entry.value.remoteId: entry.key,
    };
    final handledLocal = <String>{};
    final deletedLocalPaths = <String>{};
    final pendingRemoteIds = <String>{};
    final cloudDownloadTimes = <String, DateTime>{};
    final publishedOrderPaths = <String>{};
    bool useLocalOrder(String path) =>
        preferLocalOrder && downloadedAtByPath.containsKey(path);
    final selectedKeys = onlyPaths
        ?.map((path) => p.normalize(path).toLowerCase())
        .toSet();
    bool selected(String path) =>
        selectedKeys == null ||
        selectedKeys.contains(p.normalize(path).toLowerCase());
    progress.status(CloudSyncStage.applyingDeletions);
    await _applyDeletions(
      localDirectory: localDirectory,
      local: local,
      remote: remote,
      folders: folders,
      records: records,
      hashIndex: hashIndex,
      manifestFile: manifestFile,
      skippedKeys: skippedKeys,
      handledLocal: handledLocal,
      deletedLocalPaths: deletedLocalPaths,
      pendingRemoteIds: pendingRemoteIds,
      allowNewDeletions: hashIndex.deletionPolicyEnabled,
      shouldStop: shouldStop,
      onlyPaths: selectedKeys,
      onStep: (path) => progress.status(CloudSyncStage.applyingDeletions, path),
      onFailure: (path, error, stackTrace) {
        progress.fail(path, error);
        AppLog.instance.error(
          'cloud',
          '歌曲同步删除失败：$path',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
    final remoteEntries = remote.entries
        .where(
          (entry) =>
              selected(entry.key) ||
              selected(recordByRemoteId[entry.value.id] ?? entry.key),
        )
        .toList();
    final remoteLocalKeys = remoteEntries
        .map(
          (entry) => p
              .normalize(recordByRemoteId[entry.value.id] ?? entry.key)
              .toLowerCase(),
        )
        .toSet();
    progress.total =
        remoteEntries.length +
        local.keys
            .where(
              (path) =>
                  selected(path) &&
                  !handledLocal.contains(path) &&
                  !remoteLocalKeys.contains(p.normalize(path).toLowerCase()),
            )
            .length;
    final reservedPaths = {
      for (final path in [...local.keys, ...remote.keys, ...records.keys])
        p.normalize(path).toLowerCase(),
    };
    final creatingFolders = <String, Future<String>>{};
    final writes = CoalescingWriteQueue();
    Future<void> checkpoint() {
      final snapshot = Map<String, _SyncRecord>.from(records);
      return writes.enqueue(() => _saveManifest(manifestFile, snapshot));
    }

    final pathOperations = <String, Future<void>>{};
    Future<void> runJob(String path, Future<void> Function() action) async {
      final key = p.normalize(path).toLowerCase();
      final previous = pathOperations[key] ?? Future<void>.value();
      final operation = () async {
        await previous;
        if (shouldStop?.call() == true) return;
        final before = records[path];
        Object? failure;
        StackTrace? failureStack;
        progress.status(CloudSyncStage.comparing, path);
        try {
          await action();
        } catch (error, stackTrace) {
          failure = error;
          failureStack = stackTrace;
        }
        if (!identical(before, records[path])) {
          try {
            await checkpoint();
          } catch (error, stackTrace) {
            failure ??= error;
            failureStack ??= stackTrace;
          }
        }
        if (failure != null) {
          syncedMetadata.remove(p.join(localDirectory.path, path));
          changedMetadataPaths.remove(p.join(localDirectory.path, path));
          progress.fail(path, failure);
          AppLog.instance.error(
            'cloud',
            '歌曲同步失败：$path',
            error: failure,
            stackTrace: failureStack,
          );
        }
        progress.completed++;
        progress.emit(force: true);
      }();
      pathOperations[key] = operation;
      await operation;
      if (identical(pathOperations[key], operation)) pathOperations.remove(key);
    }

    Future<AnyShareFile> upload(
      File file,
      String parent,
      String name,
      String path, {
      AnyShareFile? replace,
    }) async => progress.transfer(
      path,
      CloudSyncStage.uploading,
      await file.length(),
      (onBytes) => client.uploadFile(
        file,
        parent,
        name,
        replace: replace,
        onProgress: onBytes,
      ),
    );
    Future<void> download(
      AnyShareFile remote,
      File target,
      String path, {
      bool replace = false,
      bool atomic = true,
    }) => progress.transfer(
      path,
      CloudSyncStage.downloading,
      remote.size,
      (onBytes) => atomic
          ? _downloadAtomically(
              remote,
              target,
              replace: replace,
              onProgress: onBytes,
            )
          : client.downloadFile(remote, target, onProgress: onBytes),
    );
    Future<String> hash(File file, String path) {
      progress.status(CloudSyncStage.hashing, path);
      return _hashFile(file);
    }

    Future<(AnyShareFile, CloudSongMetadataRecord, Id3CoverImage?)>
    prepareMetadata(
      AnyShareFile cloudFile,
      String remotePath,
      String localPath,
      LocalSongMetadata? snapshot, {
      bool newUpload = false,
    }) async {
      final store = metadataStore!;
      progress.status(CloudSyncStage.syncingMetadata, localPath);
      final id = songSyncId(cloudFile.id);
      final temporary = File(
        p.join(store.workingDirectory.path, '$id.song.part'),
      );
      SongMetadata seed =
          snapshot?.values ??
          SongMetadata(
            title: p.basenameWithoutExtension(remotePath),
            artist: '',
          );
      Id3CoverImage? seedCover = snapshot?.cover;
      final mp3 = p.extension(remotePath).toLowerCase() == '.mp3';
      var song = cloudFile;
      try {
        if (newUpload && snapshot == null && mp3) {
          final parsed = await SongMetadata.readFile(
            File(p.join(localDirectory.path, localPath)),
          );
          seed = parsed.$1;
          seedCover = parsed.$2;
        }
        if (!newUpload && !store.hasDocument(id)) {
          await download(song, temporary, localPath, atomic: false);
          if (mp3) {
            final parsed = await SongMetadata.readFile(temporary);
            seed = parsed.$1.title.isEmpty
                ? parsed.$1.merge(
                    SongMetadata(
                      title: p.basenameWithoutExtension(remotePath),
                      artist: parsed.$1.artist,
                    ),
                    {'title'},
                  )
                : parsed.$1;
            seedCover = parsed.$2;
          }
        }
        var record = await store.merge(
          id,
          seed,
          snapshot,
          seedCover: seedCover,
        );
        var cover = snapshot?.cover ?? seedCover;
        if (record.document.taggedVersion != record.document.version ||
            record.document.taggedRev != song.rev ||
            snapshot?.values.coverHash != record.document.values.coverHash ||
            snapshot?.coverFilePath == null) {
          cover = await store.readCover(
            record.document.values,
            local:
                snapshot?.values.coverHash == record.document.values.coverHash
                ? await snapshot?.loadCover()
                : cover,
          );
        }
        for (var attempt = 0; attempt < 4; attempt++) {
          final document = record.document;
          if (document.taggedVersion == document.version &&
              document.taggedRev == song.rev) {
            return (song, record, cover);
          }
          if (mp3) {
            if (!await temporary.exists()) {
              await download(song, temporary, localPath, atomic: false);
            }
            if (await document.values.writeMp3(temporary, cover)) {
              try {
                song = await upload(
                  temporary,
                  _parentId(remotePath, folders),
                  p.basename(remotePath),
                  localPath,
                  replace: song,
                );
              } on DioException catch (error) {
                if (attempt == 3 ||
                    !const [
                      400,
                      403,
                      409,
                      412,
                    ].contains(error.response?.statusCode)) {
                  rethrow;
                }
                final children = await client.listChildren(
                  _parentId(remotePath, folders),
                );
                final latest = children.files
                    .where((file) => file.id == song.id)
                    .firstOrNull;
                if (latest == null) rethrow;
                song = latest;
                await temporary.delete();
                continue;
              }
              progress.uploaded++;
              await _rememberHash(
                hashIndex,
                song,
                temporary,
                downloadedAtMs:
                    hashIndex.originalDownloadedAt(song.id) ??
                    downloadedAtByPath[localPath]?.millisecondsSinceEpoch,
              );
            }
          }
          record = await store.acknowledgeTags(record, song.rev);
          if (record.document.version == document.version) {
            return (song, record, cover);
          }
          cover = await store.readCover(record.document.values, local: cover);
        }
        throw StateError('歌曲信息被其他设备持续修改，请重试');
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }

    Future<SyncedSongMetadata> metadataResult(
      CloudSongMetadataRecord record,
      Id3CoverImage? cover,
      LocalSongMetadata? snapshot, {
      bool deferred = false,
      String acknowledgedEditId = '',
    }) async {
      String? coverPath;
      if (record.document.values.coverHash != null) {
        if (snapshot?.coverFilePath != null &&
            snapshot?.values.coverHash == record.document.values.coverHash) {
          coverPath = snapshot!.coverFilePath;
        } else if (cover != null) {
          final cached = File(
            p.join(
              metadataStore!.workingDirectory.path,
              '${record.document.values.coverHash}.cover.cache',
            ),
          );
          if (!await cached.exists()) {
            await cached.writeAsBytes(cover.bytes, flush: true);
          }
          coverPath = cached.path;
        } else {
          throw const FormatException('同步歌曲封面不可用');
        }
      }
      return SyncedSongMetadata(
        document: record.document,
        metadataRev: record.file.rev,
        coverFilePath: coverPath,
        acknowledgedEditId: acknowledgedEditId,
        pendingFileWrite: deferred,
      );
    }

    Future<AnyShareFile?> mergeMp3(
      File file,
      AnyShareFile cloudFile,
      String remotePath,
      String localPath,
      String? baselineAudio,
      SongMetadata values,
      Id3CoverImage? cover,
    ) async {
      final temporary = File('${file.path}.qingting-metadata-merge.part');
      try {
        await download(cloudFile, temporary, localPath, atomic: false);
        final localAudio = await mp3AudioHash(file),
            remoteAudio = await mp3AudioHash(temporary);
        AnyShareFile result;
        if (localAudio == remoteAudio ||
            (baselineAudio != null && localAudio == baselineAudio)) {
          // The cloud file carries the newest tags, and possibly newer audio.
          await _installDownloadedFile(temporary, file, replace: true);
          result = cloudFile;
          progress.downloaded++;
        } else if (baselineAudio != null && remoteAudio == baselineAudio) {
          await values.writeMp3(file, cover);
          result = await upload(
            file,
            _parentId(remotePath, folders),
            p.basename(remotePath),
            localPath,
            replace: cloudFile,
          );
          progress.uploaded++;
        } else {
          return null;
        }
        await _restoreDownloadTime(
          file,
          hashIndex.originalDownloadedAt(result.id),
        );
        records[localPath] = _SyncRecord.fromFile(
          remote: result,
          remotePath: remotePath,
          stat: await file.stat(),
        );
        await _rememberHash(
          hashIndex,
          result,
          file,
          downloadedAtMs: _downloadTime(downloadedAtByPath, localPath, file),
        );
        return result;
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }

    await mapWithConcurrency(remoteEntries, (entry) async {
      final remotePath = entry.key;
      var cloudFile = entry.value;
      var localPath = recordByRemoteId[cloudFile.id] ?? remotePath;
      final originalPath = localPath;
      handledLocal.add(localPath);
      await runJob(localPath, () async {
        if (skippedKeys.contains(
          p.normalize(p.join(localDirectory.path, localPath)).toLowerCase(),
        )) {
          progress.skipped++;
          return;
        }
        final mapped = records[localPath];
        if (pendingRemoteIds.contains(cloudFile.id) ||
            (mapped?.remoteId == cloudFile.id && mapped?.deleteState != null)) {
          progress.skipped++;
          return;
        }
        final file = local[localPath];
        final originalAudioHash = mapped?.audioHash;
        LocalSongMetadata? localMetadata;
        CloudSongMetadataRecord? metadataRecord;
        Id3CoverImage? metadataCover;
        if (metadataStore != null) {
          localMetadata = await readLocalMetadata!(localPath);
          // An unmapped same-named file may be a different song. Its edits
          // belong to the conflict copy until a shared identity is established.
          final applicable =
              mapped?.remoteId == cloudFile.id ||
                  localMetadata?.baseline?.syncId == songSyncId(cloudFile.id)
              ? localMetadata
              : null;
          final prepared = await prepareMetadata(
            cloudFile,
            remotePath,
            localPath,
            applicable,
          );
          cloudFile = prepared.$1;
          metadataRecord = prepared.$2;
          metadataCover = prepared.$3;
          remote[remotePath] = cloudFile;
          if (localMetadata?.baseline?.version !=
              metadataRecord.document.version) {
            changedMetadataPaths.add(p.join(localDirectory.path, localPath));
          }
          if (deferredKeys.contains(
            p.normalize(p.join(localDirectory.path, localPath)),
          )) {
            final cloudTime = hashIndex.originalDownloadedAt(cloudFile.id);
            if (cloudTime != null) {
              cloudDownloadTimes[p.join(localDirectory.path, localPath)] =
                  DateTime.fromMillisecondsSinceEpoch(cloudTime);
            }
            syncedMetadata[p.join(
              localDirectory.path,
              localPath,
            )] = await metadataResult(
              metadataRecord,
              metadataCover,
              localMetadata,
              acknowledgedEditId: applicable?.editId ?? '',
              deferred:
                  localMetadata?.pendingFileWrite == true ||
                  mapped?.remoteRev != cloudFile.rev ||
                  localMetadata?.baseline?.version !=
                      metadataRecord.document.version,
            );
            progress.skipped++;
            return;
          }
        }
        if (file == null) {
          if (await File(p.join(localDirectory.path, localPath)).exists()) {
            localPath = await _uniqueRelative(
              localDirectory,
              localPath,
              '云端',
              reservedPaths: reservedPaths,
            );
          }
          final target = File(p.join(localDirectory.path, localPath));
          await download(cloudFile, target, originalPath);
          await _restoreDownloadTime(
            target,
            hashIndex.downloadedAtFor(cloudFile),
          );
          final stat = await target.stat();
          records[localPath] = _SyncRecord.fromFile(
            remote: cloudFile,
            remotePath: remotePath,
            stat: stat,
          );
          await _rememberHash(
            hashIndex,
            cloudFile,
            target,
            downloadedAtMs: _downloadTime(
              downloadedAtByPath,
              localPath,
              target,
            ),
            onHash: () => progress.status(CloudSyncStage.hashing, originalPath),
          );
          progress.downloaded++;
        } else if (mapped != null && mapped.remoteId == cloudFile.id) {
          final stat = await file.stat();
          final localChanged = !_sameLocal(stat, mapped);
          final remoteChanged = mapped.remoteRev != cloudFile.rev;
          if (localChanged &&
              metadataRecord?.document.values.coverHash != null &&
              metadataCover == null) {
            metadataCover = await metadataStore!.readCover(
              metadataRecord!.document.values,
              local: await localMetadata?.loadCover(),
            );
          }
          final mergedFile =
              localChanged &&
                  remoteChanged &&
                  metadataRecord != null &&
                  p.extension(localPath).toLowerCase() == '.mp3'
              ? await mergeMp3(
                  file,
                  cloudFile,
                  remotePath,
                  localPath,
                  originalAudioHash,
                  metadataRecord.document.values,
                  metadataCover,
                )
              : null;
          if (!localChanged && !remoteChanged) {
            final knownHash = hashIndex.hashFor(cloudFile);
            if (knownHash == null) {
              await _rememberHash(
                hashIndex,
                cloudFile,
                file,
                downloadedAtMs: _downloadTime(
                  downloadedAtByPath,
                  localPath,
                  file,
                ),
                preferLocalOrder: useLocalOrder(localPath),
                onHash: () =>
                    progress.status(CloudSyncStage.hashing, originalPath),
              );
            } else if (downloadedAtByPath[localPath] != null) {
              hashIndex.remember(
                cloudFile,
                knownHash,
                downloadedAtMs:
                    downloadedAtByPath[localPath]!.millisecondsSinceEpoch,
                preferLocalOrder: useLocalOrder(localPath),
              );
            }
            if (useLocalOrder(localPath)) publishedOrderPaths.add(localPath);
            progress.skipped++;
          } else if (localChanged && !remoteChanged) {
            if (metadataRecord != null &&
                p.extension(localPath).toLowerCase() == '.mp3') {
              await metadataRecord.document.values.writeMp3(
                file,
                metadataCover,
              );
            }
            final updated = await upload(
              file,
              _parentId(remotePath, folders),
              p.basename(remotePath),
              originalPath,
              replace: cloudFile,
            );
            cloudFile = remote[remotePath] = updated;
            records[localPath] = _SyncRecord.fromFile(
              remote: updated,
              remotePath: remotePath,
              stat: await file.stat(),
            );
            await _rememberHash(
              hashIndex,
              updated,
              file,
              downloadedAtMs: _downloadTime(
                downloadedAtByPath,
                localPath,
                file,
              ),
              preferLocalOrder: useLocalOrder(localPath),
              onHash: () =>
                  progress.status(CloudSyncStage.hashing, originalPath),
            );
            if (useLocalOrder(localPath)) publishedOrderPaths.add(localPath);
            progress.uploaded++;
          } else if (!localChanged && remoteChanged) {
            await download(cloudFile, file, originalPath, replace: true);
            await _restoreDownloadTime(
              file,
              hashIndex.downloadedAtFor(cloudFile),
            );
            records[localPath] = _SyncRecord.fromFile(
              remote: cloudFile,
              remotePath: remotePath,
              stat: await file.stat(),
            );
            await _rememberHash(
              hashIndex,
              cloudFile,
              file,
              downloadedAtMs: _downloadTime(
                downloadedAtByPath,
                localPath,
                file,
              ),
              onHash: () =>
                  progress.status(CloudSyncStage.hashing, originalPath),
            );
            progress.downloaded++;
          } else if (mergedFile != null) {
            cloudFile = remote[remotePath] = mergedFile;
          } else {
            final conflictPath = await _uniqueRelative(
              localDirectory,
              localPath,
              '本地冲突',
              reservedPaths: reservedPaths,
            );
            final conflictFile = File(
              p.join(localDirectory.path, conflictPath),
            );
            await conflictFile.parent.create(recursive: true);
            await file.rename(conflictFile.path);
            local.remove(localPath);
            local[conflictPath] = conflictFile;
            records.remove(localPath);
            await download(cloudFile, file, originalPath);
            await _restoreDownloadTime(
              file,
              hashIndex.downloadedAtFor(cloudFile),
            );
            records[localPath] = _SyncRecord.fromFile(
              remote: cloudFile,
              remotePath: remotePath,
              stat: await file.stat(),
            );
            await _rememberHash(
              hashIndex,
              cloudFile,
              file,
              downloadedAtMs: _downloadTime(
                downloadedAtByPath,
                localPath,
                file,
              ),
              onHash: () =>
                  progress.status(CloudSyncStage.hashing, originalPath),
            );
            progress.downloaded++;
          }
        } else {
          // A cloud hash bound to the current revision avoids downloading a
          // same-named song just to compare it with the local copy.
          final knownHash = hashIndex.hashFor(cloudFile);
          File? comparison;
          String remoteHash;
          bool same;
          if (knownHash != null) {
            remoteHash = knownHash;
            same =
                await file.length() == cloudFile.size &&
                await hash(file, originalPath) == knownHash;
          } else {
            comparison = File('${file.path}.qingting-compare.part');
            await download(cloudFile, comparison, originalPath, atomic: false);
            remoteHash = await hash(comparison, originalPath);
            same =
                await file.length() == await comparison.length() &&
                await hash(file, originalPath) == remoteHash;
          }
          if (!same &&
              metadataRecord != null &&
              p.extension(localPath).toLowerCase() == '.mp3') {
            comparison ??= File('${file.path}.qingting-compare.part');
            if (!await comparison.exists()) {
              await download(
                cloudFile,
                comparison,
                originalPath,
                atomic: false,
              );
            }
            if (await mp3AudioHash(file) == await mp3AudioHash(comparison)) {
              // A first sync can encounter the same audio with different tags.
              // Adopt its cloud identity without creating a conflict copy.
              remoteHash = await hash(comparison, originalPath);
              await _installDownloadedFile(comparison, file, replace: true);
              await _restoreDownloadTime(
                file,
                hashIndex.originalDownloadedAt(cloudFile.id),
              );
              comparison = null;
              same = true;
              progress.downloaded++;
            }
          }
          if (same) {
            if (comparison != null) await comparison.delete();
            records[localPath] = _SyncRecord.fromFile(
              remote: cloudFile,
              remotePath: remotePath,
              stat: await file.stat(),
            );
            progress.skipped++;
          } else {
            final conflictPath = await _uniqueRelative(
              localDirectory,
              localPath,
              '本地冲突',
              reservedPaths: reservedPaths,
            );
            final conflictFile = File(
              p.join(localDirectory.path, conflictPath),
            );
            await conflictFile.parent.create(recursive: true);
            await file.rename(conflictFile.path);
            local.remove(localPath);
            local[conflictPath] = conflictFile;
            if (comparison == null) {
              await download(cloudFile, file, originalPath);
              remoteHash = await hash(file, originalPath);
            } else {
              await comparison.rename(file.path);
            }
            await _restoreDownloadTime(
              file,
              hashIndex.downloadedAtFor(cloudFile),
            );
            records[localPath] = _SyncRecord.fromFile(
              remote: cloudFile,
              remotePath: remotePath,
              stat: await file.stat(),
            );
            progress.downloaded++;
          }
          hashIndex.remember(
            cloudFile,
            remoteHash,
            downloadedAtMs: _downloadTime(downloadedAtByPath, localPath, file),
            preferLocalOrder: same && useLocalOrder(localPath),
          );
          if (same && useLocalOrder(localPath)) {
            publishedOrderPaths.add(localPath);
          }
        }
        final cloudTime = hashIndex.downloadedAtFor(cloudFile);
        if (cloudTime != null) {
          cloudDownloadTimes[p.join(localDirectory.path, localPath)] =
              DateTime.fromMillisecondsSinceEpoch(cloudTime);
        }
        handledLocal.add(localPath);
        if (metadataRecord != null) {
          final finalFile = remote[remotePath] ?? cloudFile;
          final record = records[localPath];
          // Normal uploads may have replaced the prepared file once more.
          final expectedVersion = metadataRecord.document.version;
          metadataRecord = await metadataStore!.acknowledgeTags(
            metadataRecord,
            finalFile.rev,
          );
          if (metadataRecord.document.version != expectedVersion) {
            throw StateError('云端歌曲信息已更新，请重试同步');
          }
          if (record != null &&
              p.extension(localPath).toLowerCase() == '.mp3') {
            final audio =
                record.audioHash ??
                await mp3AudioHash(
                  File(p.join(localDirectory.path, localPath)),
                );
            if (record.audioHash == null) {
              records[localPath] = record.withAudioHash(audio);
            }
          }
          syncedMetadata[p.join(
            localDirectory.path,
            localPath,
          )] = await metadataResult(
            metadataRecord,
            metadataCover,
            localMetadata,
            acknowledgedEditId: localMetadata?.editId ?? '',
          );
        }
        if (localPath != originalPath) await checkpoint();
      });
      return true;
    }, maxConcurrent: 2);

    final localEntries = local.entries
        .where(
          (entry) => selected(entry.key) && !handledLocal.contains(entry.key),
        )
        .toList();
    progress.total = progress.completed + localEntries.length;
    await mapWithConcurrency(localEntries, (entry) async {
      final relative = entry.key;
      final file = entry.value;
      await runJob(relative, () async {
        if (!await file.exists()) {
          progress.skipped++;
          return;
        }
        final parentId = await _ensureCloudParent(
          relative,
          songsFolder.id,
          folders,
          creatingFolders,
        );
        final snapshot = readLocalMetadata == null
            ? null
            : await readLocalMetadata(relative);
        if (snapshot != null &&
            p.extension(relative).toLowerCase() == '.mp3' &&
            !deferredKeys.contains(p.normalize(file.path))) {
          await snapshot.values.writeMp3(file, await snapshot.loadCover());
        }
        var uploadedFile = await upload(
          file,
          parentId,
          p.basename(relative),
          relative,
        );
        // Save the uploaded identity before the independent information write.
        // A failed metadata commit must keep this upload mapped on restart.
        records[relative] = _SyncRecord.fromFile(
          remote: uploadedFile,
          remotePath: relative,
          stat: await file.stat(),
        );
        await _rememberHash(
          hashIndex,
          uploadedFile,
          file,
          downloadedAtMs: _downloadTime(downloadedAtByPath, relative, file),
        );
        await checkpoint();
        if (metadataStore != null) {
          final prepared = await prepareMetadata(
            uploadedFile,
            relative,
            relative,
            snapshot,
            newUpload: true,
          );
          uploadedFile = prepared.$1;
          changedMetadataPaths.add(file.path);
          syncedMetadata[file.path] = await metadataResult(
            prepared.$2,
            prepared.$3,
            snapshot,
            acknowledgedEditId: snapshot?.editId ?? '',
            deferred: deferredKeys.contains(p.normalize(file.path)),
          );
        }
        records[relative] = _SyncRecord.fromFile(
          remote: uploadedFile,
          remotePath: p.join(
            p.dirname(relative) == '.' ? '' : p.dirname(relative),
            uploadedFile.name,
          ),
          stat: await file.stat(),
        );
        if (metadataStore != null &&
            p.extension(relative).toLowerCase() == '.mp3') {
          records[relative] = records[relative]!.withAudioHash(
            await mp3AudioHash(file),
          );
        }
        if (!deferredKeys.contains(p.normalize(file.path)) ||
            hashIndex.hashFor(uploadedFile) == null) {
          await _rememberHash(
            hashIndex,
            uploadedFile,
            file,
            downloadedAtMs: _downloadTime(downloadedAtByPath, relative, file),
            preferLocalOrder: useLocalOrder(relative),
            onHash: () => progress.status(CloudSyncStage.hashing, relative),
          );
        }
        if (useLocalOrder(relative)) publishedOrderPaths.add(relative);
        progress.uploaded++;
      });
      return true;
    }, maxConcurrent: 2);
    progress.status(CloudSyncStage.savingIndex);
    await writes.flush();
    await hashIndex.flush(required: preferLocalOrder);
    progress.status(CloudSyncStage.complete, '完成');
    return CloudSyncResult(
      uploaded: progress.uploaded,
      downloaded: progress.downloaded,
      skipped: progress.skipped,
      failures: List.unmodifiable(progress.failures.values),
      metadataByPath: syncedMetadata,
      metadataUpdated: changedMetadataPaths.length,
      deletedLocalPaths: deletedLocalPaths,
      downloadedAtByPath: cloudDownloadTimes,
      pendingApproval: records.values
          .where(
            (record) =>
                record.deleteState == _DeleteRequestState.awaitingApproval,
          )
          .length,
      pendingRemoval: records.values
          .where(
            (record) =>
                record.deleteState == _DeleteRequestState.awaitingRemoval,
          )
          .length,
      orderPublished: publishedOrderPaths.length,
      deletionPolicyEnabled: hashIndex.deletionPolicyEnabled,
    );
  }

  int _downloadTime(Map<String, DateTime> times, String path, File file) =>
      (times[path] ?? file.statSync().modified).millisecondsSinceEpoch;

  Future<void> _restoreDownloadTime(File file, int? milliseconds) async {
    if (milliseconds != null) {
      await file.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(milliseconds),
      );
    }
  }

  Future<void> _applyDeletions({
    required Directory localDirectory,
    required Map<String, File> local,
    required Map<String, AnyShareFile> remote,
    required Map<String, String> folders,
    required Map<String, _SyncRecord> records,
    required CloudHashIndex hashIndex,
    required File manifestFile,
    required Set<String> skippedKeys,
    required Set<String> handledLocal,
    required Set<String> deletedLocalPaths,
    required Set<String> pendingRemoteIds,
    required bool allowNewDeletions,
    bool Function()? shouldStop,
    Set<String>? onlyPaths,
    required void Function(String) onStep,
    required void Function(String, Object, StackTrace) onFailure,
  }) async {
    final remoteById = {for (final file in remote.values) file.id: file};
    for (final marker in hashIndex.deletions) {
      if (shouldStop?.call() == true) break;
      final cloudPath = p.posix.normalize(marker.path.replaceAll('\\', '/'));
      final segments = p.posix.split(cloudPath);
      if (p.posix.isAbsolute(cloudPath) ||
          cloudPath == '.' ||
          segments.any((segment) => segment == '..' || !_validName(segment)) ||
          !_isAudio(cloudPath)) {
        continue;
      }
      final relative = p.joinAll(segments);
      if (onlyPaths != null &&
          !onlyPaths.contains(p.normalize(relative).toLowerCase())) {
        continue;
      }
      final absolute = p.normalize(p.join(localDirectory.path, relative));
      if (skippedKeys.contains(absolute.toLowerCase())) continue;
      onStep(relative);
      try {
        final samePathRemote = remote[relative];
        if (samePathRemote != null && samePathRemote.id != marker.remoteId) {
          continue;
        }
        final sameIdRemote = remoteById[marker.remoteId];
        if (sameIdRemote != null && sameIdRemote.rev != marker.rev) continue;
        // Older clients could publish a marker before the server completed a
        // deletion. Do not apply it while that exact cloud file still exists.
        if (sameIdRemote != null) {
          pendingRemoteIds.add(marker.remoteId);
          final record = records[relative];
          if (record != null && record.deleteState == null) {
            records[relative] = record.withDeleteRequest(
              _DeleteRequestState.queued,
              hash: marker.sha256,
              size: marker.size,
            );
            await _saveManifest(manifestFile, records);
          }
          continue;
        }
        final file = local[relative];
        if (file != null &&
            await file.length() == marker.size &&
            await _hashFile(file) == marker.sha256) {
          await file.delete();
          local.remove(relative);
          records.remove(relative);
          deletedLocalPaths.add(absolute);
          await _saveManifest(manifestFile, records);
        } else if (file == null &&
            records[relative]?.remoteId == marker.remoteId) {
          records.remove(relative);
          await _saveManifest(manifestFile, records);
        }
        handledLocal.add(relative);
      } catch (error, stackTrace) {
        handledLocal.add(relative);
        pendingRemoteIds.add(marker.remoteId);
        onFailure(relative, error, stackTrace);
      }
    }

    for (final entry in records.entries.toList()) {
      if (shouldStop?.call() == true) break;
      final relative = entry.key;
      final record = entry.value;
      if (onlyPaths != null &&
          !onlyPaths.contains(p.normalize(relative).toLowerCase()) &&
          !onlyPaths.contains(p.normalize(record.remotePath).toLowerCase())) {
        continue;
      }
      final absolute = p.normalize(p.join(localDirectory.path, relative));
      if (skippedKeys.contains(absolute.toLowerCase()) ||
          handledLocal.contains(relative)) {
        continue;
      }
      if (!allowNewDeletions && record.deleteState == null) continue;
      onStep(relative);
      try {
        final cloudFile = remote.values
            .where((file) => file.id == record.remoteId)
            .firstOrNull;
        final file = local[relative];
        if (cloudFile == null && remote.containsKey(record.remotePath)) {
          continue;
        }
        if (cloudFile != null && file != null && record.deleteState == null) {
          continue;
        }
        if (cloudFile == null &&
            file != null &&
            !_sameLocal(await file.stat(), record)) {
          handledLocal.add(relative);
          continue;
        }
        String? hash = record.pendingDeleteHash;
        var size = record.pendingDeleteSize ?? record.localSize;
        if (cloudFile != null) {
          if (cloudFile.rev != record.remoteRev) {
            if (record.deleteState != null) {
              records[relative] = record.clearDeleteRequest();
              await _saveManifest(manifestFile, records);
            }
            handledLocal.add(relative);
            continue;
          }
          hash ??= hashIndex.hashFor(cloudFile);
          if (hash == null) {
            final temp = File('${manifestFile.path}.delete-compare.part');
            try {
              await client.downloadFile(cloudFile, temp);
              hash = await _hashFile(temp);
            } finally {
              if (await temp.exists()) await temp.delete();
            }
          }
          size = cloudFile.size;
          if (record.deleteState == null) {
            records[relative] = record.withDeleteRequest(
              _DeleteRequestState.queued,
              hash: hash,
              size: size,
            );
            await _saveManifest(manifestFile, records);
          }
          if (records[relative]!.deleteState == _DeleteRequestState.queued) {
            final status = await client.deleteFile(cloudFile);
            records[relative] = records[relative]!.withDeleteState(
              status == AnyShareDeleteStatus.pendingApproval
                  ? _DeleteRequestState.awaitingApproval
                  : _DeleteRequestState.awaitingRemoval,
            );
            await _saveManifest(manifestFile, records);
            if (status == AnyShareDeleteStatus.deleted) {
              final children = await client.listChildren(
                _parentId(record.remotePath, folders),
              );
              if (!children.files.any((item) => item.id == cloudFile.id)) {
                remote.removeWhere((_, value) => value.id == cloudFile.id);
              }
            }
          }
          if (remote.values.any((item) => item.id == cloudFile.id)) {
            pendingRemoteIds.add(cloudFile.id);
            handledLocal.add(relative);
            continue;
          }
        } else if (file != null) {
          hash ??= await _hashFile(file);
        }
        if (hash == null) {
          handledLocal.add(relative);
          continue;
        }
        final marker = CloudDeletionMarker(
          remoteId: record.remoteId,
          rev: record.remoteRev,
          path: record.remotePath.replaceAll('\\', '/'),
          size: size,
          sha256: hash,
        );
        hashIndex.rememberDeletion(marker);
        await hashIndex.flush(required: true);
        if (file != null &&
            await file.length() == marker.size &&
            await _hashFile(file) == marker.sha256) {
          await file.delete();
          local.remove(relative);
          deletedLocalPaths.add(absolute);
        }
        records.remove(relative);
        handledLocal.add(relative);
        await _saveManifest(manifestFile, records);
      } catch (error, stackTrace) {
        handledLocal.add(relative);
        pendingRemoteIds.add(record.remoteId);
        onFailure(relative, error, stackTrace);
      }
    }
  }

  Future<void> _walkCloud(
    String folderId,
    String relative,
    Map<String, AnyShareFile> files,
    Map<String, String> folders,
  ) async {
    final children = await client.listChildren(folderId);
    for (final file in children.files) {
      if (!_validName(file.name) || !_isAudio(file.name)) continue;
      files[p.join(relative, file.name)] = file;
    }
    for (final folder in children.folders) {
      if (!_validName(folder.name)) continue;
      final path = p.join(relative, folder.name);
      folders[path] = folder.id;
      await _walkCloud(folder.id, path, files, folders);
    }
  }

  Future<Map<String, File>> _scanLocal(
    Directory root,
    Set<String> skipped,
  ) async {
    final result = <String, File>{};
    final skippedKeys = skipped
        .map((x) => p.normalize(x).toLowerCase())
        .toSet();
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          !_isAudio(entity.path) ||
          skippedKeys.contains(p.normalize(entity.path).toLowerCase())) {
        continue;
      }
      final relative = p.relative(entity.path, from: root.path);
      if (p.split(relative).every(_validName)) result[relative] = entity;
    }
    return result;
  }

  Future<String> _ensureCloudParent(
    String relative,
    String rootId,
    Map<String, String> folders,
    Map<String, Future<String>> creatingFolders,
  ) async {
    final parent = p.dirname(relative);
    if (parent == '.') return rootId;
    var currentPath = '';
    var currentId = rootId;
    for (final segment in p.split(parent)) {
      currentPath = p.join(currentPath, segment);
      final known = folders[currentPath];
      if (known != null) {
        currentId = known;
      } else {
        final folderPath = currentPath;
        final parentId = currentId;
        final creation = creatingFolders.putIfAbsent(folderPath, () async {
          try {
            final created = await client.createFolder(parentId, segment);
            folders[folderPath] = created.id;
            return created.id;
          } finally {
            creatingFolders.remove(folderPath);
          }
        });
        currentId = await creation;
      }
    }
    return currentId;
  }

  String _parentId(String remotePath, Map<String, String> folders) =>
      folders[p.dirname(remotePath) == '.' ? '' : p.dirname(remotePath)]!;

  Future<void> _downloadAtomically(
    AnyShareFile remote,
    File target, {
    bool replace = false,
    void Function(int, int)? onProgress,
  }) async {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.qingting-sync.part');
    await client.downloadFile(remote, temp, onProgress: onProgress);
    await _installDownloadedFile(temp, target, replace: replace);
  }

  Future<void> _installDownloadedFile(
    File temp,
    File target, {
    bool replace = false,
  }) async {
    if (!replace || !await target.exists()) {
      await temp.rename(target.path);
      return;
    }
    final backup = File('${target.path}.qingting-sync.bak');
    if (await backup.exists()) await backup.delete();
    await target.rename(backup.path);
    try {
      await temp.rename(target.path);
      await backup.delete();
    } catch (_) {
      if (await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  Future<String> _hashFile(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _rememberHash(
    CloudHashIndex index,
    AnyShareFile remote,
    File file, {
    int? downloadedAtMs,
    bool preferLocalOrder = false,
    void Function()? onHash,
  }) async {
    try {
      onHash?.call();
      index.remember(
        remote,
        await _hashFile(file),
        downloadedAtMs: downloadedAtMs,
        preferLocalOrder: preferLocalOrder,
      );
    } on FileSystemException {
      AppLog.instance.warning('cloud', '读取歌曲哈希失败，已跳过云端索引');
    }
  }

  bool _sameLocal(FileStat stat, _SyncRecord record) =>
      stat.size == record.localSize &&
      stat.modified.millisecondsSinceEpoch == record.localModifiedMs;

  bool _isAudio(String name) => cloudAudioExtensions.contains(
    p.extension(name).toLowerCase().replaceFirst('.', ''),
  );

  bool _validName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(name) &&
      !name.endsWith('.') &&
      !name.endsWith(' ') &&
      !RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
        caseSensitive: false,
      ).hasMatch(p.basenameWithoutExtension(name));

  Future<String> _uniqueRelative(
    Directory root,
    String original,
    String label, {
    Set<String>? reservedPaths,
  }) async {
    final base = p.withoutExtension(original);
    final extension = p.extension(original);
    for (var index = 1; ; index++) {
      final suffix = index == 1 ? ' ($label)' : ' ($label $index)';
      final candidate = '$base$suffix$extension';
      if (!await File(p.join(root.path, candidate)).exists() &&
          (reservedPaths == null ||
              reservedPaths.add(p.normalize(candidate).toLowerCase()))) {
        return candidate;
      }
    }
  }

  Future<File> _manifestFile(String cloudId, String localPath) async {
    final directory =
        _stateDirectoryOverride ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final key = sha256.convert(
      utf8.encode('$cloudId\n${p.normalize(localPath)}'),
    );
    return File(p.join(directory.path, 'cloud_sync_$key.json'));
  }

  Future<Map<String, _SyncRecord>> _loadManifest(File file) async {
    final backup = File('${file.path}.bak');
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    if (!await file.exists()) return {};
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return data.map(
        (key, value) => MapEntry(
          key,
          _SyncRecord.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } catch (_) {
      if (await backup.exists()) {
        try {
          final data =
              jsonDecode(await backup.readAsString()) as Map<String, dynamic>;
          final restored = data.map(
            (key, value) => MapEntry(
              key,
              _SyncRecord.fromJson(Map<String, dynamic>.from(value as Map)),
            ),
          );
          await file.delete();
          await backup.rename(file.path);
          return restored;
        } catch (_) {
          // Both copies are unusable; do not guess which files are linked.
        }
      }
      throw const FormatException('同步记录损坏，请先备份本地歌曲再重试');
    }
  }

  Future<void> _saveManifest(
    File file,
    Map<String, _SyncRecord> records,
  ) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      jsonEncode(records.map((key, value) => MapEntry(key, value.toJson()))),
      flush: true,
    );
    final backup = File('${file.path}.bak');
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temp.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }
}

class _CloudSyncReporter {
  _CloudSyncReporter(this.onProgress);
  final void Function(CloudSyncProgress)? onProgress;
  final _clock = Stopwatch()..start();
  final _active = <String, _CloudActiveTransfer>{};
  final _lastStages = <String, CloudSyncStage>{};
  final failures = <String, CloudSyncFailure>{};
  var stage = CloudSyncStage.preparing;
  var current = '';
  var completed = 0;
  var total = 0;
  var uploaded = 0;
  var downloaded = 0;
  var skipped = 0;
  var _lastEmission = -100;

  void status(CloudSyncStage value, [String path = '']) {
    stage = value;
    current = path;
    if (path.isNotEmpty) _lastStages[path] = value;
    emit(force: true);
  }

  Future<T> transfer<T>(
    String path,
    CloudSyncStage direction,
    int size,
    Future<T> Function(void Function(int, int)) action,
  ) async {
    final transfer = _CloudActiveTransfer(path, direction, size);
    _active[path] = transfer;
    status(direction, path);
    try {
      return await action((bytes, totalBytes) {
        transfer.bytes = bytes;
        if (totalBytes > 0) transfer.totalBytes = totalBytes;
        emit();
      });
    } finally {
      _active.remove(path);
      emit(force: true);
    }
  }

  void fail(String path, Object error) {
    final message = switch (error) {
      DioException() =>
        error.response?.statusCode == null
            ? '网络请求失败，请稍后重试'
            : '云盘请求失败（HTTP ${error.response!.statusCode}）',
      FileSystemException() => error.message,
      FormatException() => error.message,
      _ => '歌曲处理失败（${error.runtimeType}）',
    };
    failures[path] = CloudSyncFailure(
      path: path,
      stage: _lastStages[path] ?? CloudSyncStage.comparing,
      message: message,
    );
  }

  void emit({bool force = false}) {
    if (onProgress == null) return;
    final now = _clock.elapsedMilliseconds;
    if (!force && now - _lastEmission < 100) return;
    _lastEmission = now;
    onProgress!(
      CloudSyncProgress(
        completed: completed,
        total: total,
        uploaded: uploaded,
        downloaded: downloaded,
        failed: failures.length,
        stage: _active.isEmpty ? stage : CloudSyncStage.transferring,
        current: current,
        transfers: List.unmodifiable(
          _active.values.map((value) => value.snapshot),
        ),
      ),
    );
  }
}

class _CloudActiveTransfer {
  _CloudActiveTransfer(this.path, this.stage, this.totalBytes);
  final String path;
  final CloudSyncStage stage;
  final _clock = Stopwatch()..start();
  int bytes = 0;
  int totalBytes;
  CloudSyncTransferProgress get snapshot => CloudSyncTransferProgress(
    path: path,
    stage: stage,
    bytes: bytes,
    totalBytes: totalBytes,
    bytesPerSecond: _clock.elapsedMicroseconds <= 0
        ? 0
        : bytes * 1000000 / _clock.elapsedMicroseconds,
  );
}

class _SyncRecord {
  const _SyncRecord({
    required this.remoteId,
    required this.remoteRev,
    required this.remotePath,
    required this.localSize,
    required this.localModifiedMs,
    this.deleteState,
    this.pendingDeleteHash,
    this.pendingDeleteSize,
    this.audioHash,
  });
  final String remoteId;
  final String remoteRev;
  final String remotePath;
  final int localSize;
  final int localModifiedMs;
  final _DeleteRequestState? deleteState;
  final String? pendingDeleteHash;
  final int? pendingDeleteSize;
  final String? audioHash;

  _SyncRecord withAudioHash(String hash) => _SyncRecord(
    remoteId: remoteId,
    remoteRev: remoteRev,
    remotePath: remotePath,
    localSize: localSize,
    localModifiedMs: localModifiedMs,
    audioHash: hash,
    deleteState: deleteState,
    pendingDeleteHash: pendingDeleteHash,
    pendingDeleteSize: pendingDeleteSize,
  );

  _SyncRecord withDeleteRequest(
    _DeleteRequestState state, {
    required String hash,
    required int size,
  }) => _SyncRecord(
    remoteId: remoteId,
    remoteRev: remoteRev,
    remotePath: remotePath,
    localSize: localSize,
    localModifiedMs: localModifiedMs,
    deleteState: state,
    pendingDeleteHash: hash,
    pendingDeleteSize: size,
    audioHash: audioHash,
  );

  _SyncRecord withDeleteState(_DeleteRequestState state) => withDeleteRequest(
    state,
    hash: pendingDeleteHash!,
    size: pendingDeleteSize!,
  );

  _SyncRecord clearDeleteRequest() => _SyncRecord(
    remoteId: remoteId,
    remoteRev: remoteRev,
    remotePath: remotePath,
    localSize: localSize,
    localModifiedMs: localModifiedMs,
    audioHash: audioHash,
  );

  factory _SyncRecord.fromFile({
    required AnyShareFile remote,
    required String remotePath,
    required FileStat stat,
  }) => _SyncRecord(
    remoteId: remote.id,
    remoteRev: remote.rev,
    remotePath: remotePath,
    localSize: stat.size,
    localModifiedMs: stat.modified.millisecondsSinceEpoch,
  );

  Map<String, dynamic> toJson() => {
    'remoteId': remoteId,
    'remoteRev': remoteRev,
    'remotePath': remotePath,
    'localSize': localSize,
    'localModifiedMs': localModifiedMs,
    if (audioHash != null) 'audioHash': audioHash,
    if (deleteState != null) 'deleteState': deleteState!.name,
    if (pendingDeleteHash != null) 'pendingDeleteHash': pendingDeleteHash,
    if (pendingDeleteSize != null) 'pendingDeleteSize': pendingDeleteSize,
  };
  factory _SyncRecord.fromJson(Map<String, dynamic> json) {
    final stateName = json['deleteState'];
    final state = stateName == null
        ? null
        : _DeleteRequestState.values.singleWhere(
            (item) => item.name == stateName,
          );
    final hash = json['pendingDeleteHash'];
    final size = json['pendingDeleteSize'];
    if (state != null &&
        (hash is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
            size is! int ||
            size < 0)) {
      throw const FormatException('待确认删除记录损坏');
    }
    return _SyncRecord(
      remoteId: json['remoteId'] as String,
      remoteRev: json['remoteRev'] as String,
      remotePath: json['remotePath'] as String,
      localSize: json['localSize'] as int,
      localModifiedMs: json['localModifiedMs'] as int,
      deleteState: state,
      pendingDeleteHash: hash as String?,
      pendingDeleteSize: size as int?,
      audioHash: json['audioHash'] as String?,
    );
  }
}

enum _DeleteRequestState { queued, awaitingApproval, awaitingRemoval }
