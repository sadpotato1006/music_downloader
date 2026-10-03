import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'anyshare_client.dart';
import 'app_log.dart';
import 'song_metadata.dart';

/// Shared hints for matching songs already present on two devices.
/// An entry is usable only while the cloud file's revision and size match.
class CloudHashIndex {
  CloudHashIndex._(this.client, this.folderId, this.workingFile);

  static const fileName = 'QingTing-sync-index.json';
  static const _maxBytes = 4 * 1024 * 1024;

  final AnyShareClient client;
  final String folderId;
  final File workingFile;
  final Map<String, _CloudHashEntry> _entries = {};
  final Map<String, _CloudHashEntry> _updates = {};
  final Map<String, CloudDeletionMarker> _deletions = {};
  final Map<String, CloudDeletionMarker> _deletionUpdates = {};
  bool _deletionPolicyEnabled = false;
  bool? _deletionPolicyUpdate;
  bool _enabled = true;
  bool get available => _enabled;
  bool get deletionPolicyEnabled =>
      _deletionPolicyUpdate ?? _deletionPolicyEnabled;

  static Future<CloudHashIndex> open({
    required AnyShareClient client,
    required String folderId,
    required File workingFile,
    AnyShareFile? remoteFile,
  }) async {
    final index = CloudHashIndex._(client, folderId, workingFile);
    if (remoteFile == null) return index;
    try {
      final data = await index._read(remoteFile);
      index._entries.addAll(data.entries);
      index._deletions.addAll(data.deletions);
      index._deletionPolicyEnabled = data.deletionPolicyEnabled;
    } catch (error) {
      index._enabled = false;
      AppLog.instance.warning(
        'cloud',
        '读取云端歌曲索引失败，已停止同步以保护删除记录',
        detail: '${error.runtimeType}',
      );
    }
    return index;
  }

  String? hashFor(AnyShareFile file) {
    if (!_enabled || file.rev.isEmpty || file.size < 0) return null;
    final entry = _updates[file.id] ?? _entries[file.id];
    if (entry == null || entry.rev != file.rev || entry.size != file.size) {
      return null;
    }
    return entry.sha256;
  }

  int? downloadedAtFor(AnyShareFile file) {
    if (hashFor(file) == null) return null;
    return (_updates[file.id] ?? _entries[file.id])?.downloadedAtMs;
  }

  int? originalDownloadedAt(String remoteId) =>
      (_updates[remoteId] ?? _entries[remoteId])?.downloadedAtMs;

  Iterable<CloudDeletionMarker> get deletions => [
    ..._deletions.values,
    ..._deletionUpdates.values,
  ];

  void rememberDeletion(CloudDeletionMarker marker) {
    if (!_enabled) throw const FormatException('云端删除记录不可用，已停止删除同步');
    _deletionUpdates[marker.remoteId] = marker;
  }

  void setDeletionPolicy(bool enabled) {
    if (!_enabled) throw const FormatException('云端同步设置无法读取，已停止修改');
    _deletionPolicyUpdate = enabled;
  }

  void remember(
    AnyShareFile file,
    String hash, {
    int? downloadedAtMs,
    bool preferLocalOrder = false,
  }) {
    if (!_enabled || file.rev.isEmpty || file.size < 0) return;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) return;
    if (downloadedAtMs != null && downloadedAtMs <= 0) {
      downloadedAtMs = null;
    }
    final previous = _updates[file.id] ?? _entries[file.id];
    final priorTime = previous?.downloadedAtMs;
    final pinned = previous?.orderRevision ?? 0;
    final force = preferLocalOrder && downloadedAtMs != null;
    final entry = _CloudHashEntry(
      file.rev,
      file.size,
      hash,
      downloadedAtMs: force
          ? downloadedAtMs
          : pinned > 0
          ? priorTime
          : priorTime == null
          ? downloadedAtMs
          : downloadedAtMs == null || priorTime <= downloadedAtMs
          ? priorTime
          : downloadedAtMs,
      orderRevision: force ? -1 : pinned,
    );
    if (_entries[file.id] != entry) _updates[file.id] = entry;
  }

  Future<void> flush({bool required = false}) async {
    if (!_enabled) {
      if (required) throw const FormatException('云端删除记录不可用，已停止删除同步');
      return;
    }
    if (_updates.isEmpty &&
        _deletionUpdates.isEmpty &&
        _deletionPolicyUpdate == null) {
      return;
    }
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final children = await client.listChildren(folderId);
          final matches = children.files
              .where((file) => file.name == fileName)
              .toList();
          if (matches.length > 1) {
            throw const FormatException('云端歌曲索引有多个同名文件');
          }
          final remoteFile = matches.isEmpty ? null : matches.single;
          final data = remoteFile == null
              ? _CloudIndexData({}, {}, false)
              : await _read(remoteFile);
          final latest = data.entries;
          final latestDeletions = data.deletions;
          final nextOrderRevision =
              latest.values.fold<int>(
                0,
                (highest, entry) => entry.orderRevision > highest
                    ? entry.orderRevision
                    : highest,
              ) +
              1;
          for (final update in _updates.entries) {
            final existing = latest[update.key];
            final baseline = _entries[update.key];
            final forced = update.value.orderRevision == -1;
            final proposed = forced
                ? update.value.withOrderRevision(nextOrderRevision)
                : update.value;
            // Preserve a newer revision written by another device. Replace
            // the revision we saw before this sync with our uploaded one.
            if (existing != null &&
                existing.rev == update.value.rev &&
                existing.size == update.value.size &&
                existing.sha256 == update.value.sha256) {
              if (forced) {
                latest[update.key] = proposed;
                continue;
              }
              if (existing.orderRevision > proposed.orderRevision) {
                continue;
              }
              if (proposed.orderRevision > existing.orderRevision) {
                latest[update.key] = proposed;
                continue;
              }
              if (existing.orderRevision > 0) continue;
              final oldTime = existing.downloadedAtMs;
              final newTime = proposed.downloadedAtMs;
              latest[update.key] = _CloudHashEntry(
                existing.rev,
                existing.size,
                existing.sha256,
                downloadedAtMs: oldTime == null
                    ? newTime
                    : newTime == null || oldTime <= newTime
                    ? oldTime
                    : newTime,
              );
            } else if (existing == null || existing.rev == baseline?.rev) {
              latest[update.key] = proposed;
            }
          }
          latestDeletions.addAll(_deletionUpdates);
          final deletionPolicyEnabled =
              _deletionPolicyUpdate ?? data.deletionPolicyEnabled;
          await workingFile.writeAsString(
            jsonEncode({
              'schema': 1,
              'deletionEnabled': deletionPolicyEnabled,
              'entries': latest.map(
                (id, entry) =>
                    MapEntry(id, entry.toJson()..['syncId'] = songSyncId(id)),
              ),
              'deletions': latestDeletions.map(
                (id, marker) => MapEntry(id, marker.toJson()),
              ),
            }),
            flush: true,
          );
          await client.uploadFile(
            workingFile,
            folderId,
            fileName,
            replace: remoteFile,
            ondup: 1,
          );
          _entries
            ..clear()
            ..addAll(latest);
          _updates.clear();
          _deletions
            ..clear()
            ..addAll(latestDeletions);
          _deletionUpdates.clear();
          _deletionPolicyEnabled = deletionPolicyEnabled;
          _deletionPolicyUpdate = null;
          return;
        } on DioException catch (error) {
          final status = error.response?.statusCode;
          if (attempt == 2 ||
              (status != 400 &&
                  status != 403 &&
                  status != 409 &&
                  status != 412)) {
            rethrow;
          }
        }
      }
    } catch (error) {
      if (required) rethrow;
      AppLog.instance.warning(
        'cloud',
        '保存云端歌曲索引失败；歌曲同步结果不受影响',
        detail: error is DioException
            ? 'HTTP ${error.response?.statusCode ?? '连接失败'}'
            : '${error.runtimeType}',
      );
    } finally {
      try {
        if (await workingFile.exists()) await workingFile.delete();
      } on FileSystemException {
        // The optional index must never turn a completed song sync into a failure.
      }
    }
  }

  Future<_CloudIndexData> _read(AnyShareFile remote) async {
    if (remote.size > _maxBytes) {
      throw const FormatException('云端歌曲索引过大');
    }
    try {
      await client.downloadFile(remote, workingFile);
      if (await workingFile.length() > _maxBytes) {
        throw const FormatException('云端歌曲索引过大');
      }
      final body = jsonDecode(await workingFile.readAsString());
      if (body is! Map || body['schema'] != 1 || body['entries'] is! Map) {
        throw const FormatException('云端歌曲索引格式不正确');
      }
      final result = <String, _CloudHashEntry>{};
      for (final record in (body['entries'] as Map).entries) {
        if (record.key is! String || record.value is! Map) {
          throw const FormatException('云端歌曲索引条目不正确');
        }
        result[record.key as String] = _CloudHashEntry.fromJson(
          record.value as Map,
        );
      }
      final deletions = <String, CloudDeletionMarker>{};
      final rawPolicy = body['deletionEnabled'];
      if (rawPolicy != null && rawPolicy is! bool) {
        throw const FormatException('云端同步删除设置格式不正确');
      }
      final rawDeletions = body['deletions'];
      if (rawDeletions != null && rawDeletions is! Map) {
        throw const FormatException('云端删除记录格式不正确');
      }
      for (final record in (rawDeletions as Map? ?? const {}).entries) {
        if (record.key is! String || record.value is! Map) {
          throw const FormatException('云端删除记录条目不正确');
        }
        final marker = CloudDeletionMarker.fromJson(record.value as Map);
        if (marker.remoteId != record.key) {
          throw const FormatException('云端删除记录标识不一致');
        }
        deletions[marker.remoteId] = marker;
      }
      return _CloudIndexData(result, deletions, rawPolicy == true);
    } finally {
      if (await workingFile.exists()) await workingFile.delete();
    }
  }
}

class _CloudIndexData {
  const _CloudIndexData(
    this.entries,
    this.deletions,
    this.deletionPolicyEnabled,
  );
  final Map<String, _CloudHashEntry> entries;
  final Map<String, CloudDeletionMarker> deletions;
  final bool deletionPolicyEnabled;
}

class CloudDeletionMarker {
  const CloudDeletionMarker({
    required this.remoteId,
    required this.rev,
    required this.path,
    required this.size,
    required this.sha256,
  });
  final String remoteId;
  final String rev;
  final String path;
  final int size;
  final String sha256;

  factory CloudDeletionMarker.fromJson(Map json) {
    final id = json['remoteId'];
    final rev = json['rev'];
    final path = json['path'];
    final size = json['size'];
    final hash = json['sha256'];
    if (id is! String ||
        id.isEmpty ||
        rev is! String ||
        path is! String ||
        path.isEmpty ||
        size is! int ||
        size < 0 ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('云端删除记录内容不正确');
    }
    return CloudDeletionMarker(
      remoteId: id,
      rev: rev,
      path: path,
      size: size,
      sha256: hash,
    );
  }

  Map<String, Object> toJson() => {
    'remoteId': remoteId,
    'rev': rev,
    'path': path,
    'size': size,
    'sha256': sha256,
  };
}

class _CloudHashEntry {
  const _CloudHashEntry(
    this.rev,
    this.size,
    this.sha256, {
    this.downloadedAtMs,
    this.orderRevision = 0,
  });

  final String rev;
  final int size;
  final String sha256;
  final int? downloadedAtMs;
  final int orderRevision;

  _CloudHashEntry withOrderRevision(int revision) => _CloudHashEntry(
    rev,
    size,
    sha256,
    downloadedAtMs: downloadedAtMs,
    orderRevision: revision,
  );

  factory _CloudHashEntry.fromJson(Map json) {
    final rev = json['rev'];
    final size = json['size'];
    final hash = json['sha256'];
    final downloadedAt = json['downloadedAtMs'];
    final orderRevision = json['orderRevision'] ?? 0;
    if (rev is! String ||
        size is! int ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        (downloadedAt != null && (downloadedAt is! int || downloadedAt <= 0)) ||
        orderRevision is! int ||
        orderRevision < 0) {
      throw const FormatException('云端歌曲索引哈希不正确');
    }
    return _CloudHashEntry(
      rev,
      size,
      hash,
      downloadedAtMs: downloadedAt,
      orderRevision: orderRevision,
    );
  }

  Map<String, Object> toJson() {
    final result = <String, Object>{'rev': rev, 'size': size, 'sha256': sha256};
    final time = downloadedAtMs;
    if (time != null) result['downloadedAtMs'] = time;
    if (orderRevision > 0) result['orderRevision'] = orderRevision;
    return result;
  }

  @override
  bool operator ==(Object other) =>
      other is _CloudHashEntry &&
      rev == other.rev &&
      size == other.size &&
      sha256 == other.sha256 &&
      downloadedAtMs == other.downloadedAtMs &&
      orderRevision == other.orderRevision;

  @override
  int get hashCode =>
      Object.hash(rev, size, sha256, downloadedAtMs, orderRevision);
}
