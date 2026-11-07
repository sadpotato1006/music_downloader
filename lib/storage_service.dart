import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'id3_lyrics_embedder.dart';
import 'app_log.dart';
import 'models.dart';
import 'pending_album_match.dart';
import 'storage_json_codec.dart';
import 'snapshot_delta.dart';

class StorageRecoveryException implements Exception {
  const StorageRecoveryException({
    required this.path,
    this.backupAvailable = false,
  });

  final String path;
  final bool backupAvailable;

  String get message => backupAvailable
      ? '找到了数据备份，但无法恢复主文件。已保留原文件并暂停保存，请检查存储权限后重试。\n$path'
      : '应用数据及其备份无法读取。已保留原文件并暂停保存，请恢复以下文件或其备份后重试。\n$path';

  @override
  String toString() => message;
}

class StorageService {
  StorageService({Directory? supportDirectory})
    : _supportDirectoryOverride = supportDirectory;

  static const _settingsFileName = 'settings.json';
  static const _libraryFileName = 'downloads.json';
  static const _queueFileName = 'queue.json';
  static const _myMusicFileName = 'my_music.json';
  static const _downloadTasksFileName = 'download_tasks.json';
  static const _pendingAlbumMatchesFileName = 'pending_album_matches.json';

  final Directory? _supportDirectoryOverride;
  Future<Directory> audioCacheDirectory() => _supportDirectory('audio_cache');
  final Map<String, Future<void>> _writeQueues = {};
  final Map<String, Future<void>> _snapshotWrites = {};
  final Map<String, String> _snapshotHashes = {};
  final Map<String, SnapshotBase> _snapshotBases = {};
  static const incrementalEntryThreshold = 512;
  static const maxDeltaBytes = 256 * 1024;
  final Map<String, StorageRecoveryException> _blockedJsonFiles = {};
  static const _jsonCodec = StorageJsonCodec();

  Future<AppSettings> loadSettings() async {
    final settings = await _loadJsonWithBackup(
      _settingsFileName,
      _decodeSettings,
    );
    return settings ??
        AppSettings(downloadDirectory: await defaultDownloadDirectory());
  }

  Future<void> saveSettings(AppSettings settings) async {
    await _saveJson(_settingsFileName, settings);
  }

  Future<List<DownloadedTrack>> loadDownloadedTracks() async {
    final base =
        await _loadJsonWithBackup(_libraryFileName, _decodeDownloadedTracks) ??
        const <DownloadedTrack>[];
    final hash = _snapshotHashes[_libraryFileName];
    if (hash == null) {
      await _checkMissingDeltaBase(_libraryFileName);
      return base;
    }
    final delta = await _loadJsonWithBackup(
      '$_libraryFileName.delta',
      _decodeLibraryDelta,
    );
    _snapshotBases[_libraryFileName] = SnapshotBase(hash, base);
    return delta?.hash == hash
        ? _applyDelta(_libraryFileName, delta!, base)
        : base;
  }

  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) {
    final snapshot = List<DownloadedTrack>.unmodifiable(tracks);
    return _saveSnapshot(
      _libraryFileName,
      snapshot,
      snapshot,
      const {},
      textCodeUnits: snapshot.fold<int>(
        0,
        (count, track) =>
            count +
            (track.metadataLyrics?.length ?? 0) +
            (track.syncedMetadata?.values.lyrics.length ?? 0),
      ),
    );
  }

  Future<MyMusicData> loadMyMusic() async {
    return await _loadJsonWithBackup(_myMusicFileName, _decodeMyMusic) ??
        const MyMusicData();
  }

  Future<void> saveMyMusic(MyMusicData data) async {
    final snapshot = MyMusicData(
      favoriteTrackPaths: List<String>.unmodifiable(data.favoriteTrackPaths),
      playlists: [
        for (final playlist in data.playlists)
          playlist.copyWith(
            trackPaths: List<String>.unmodifiable(playlist.trackPaths),
            pendingTracks: List.unmodifiable(playlist.pendingTracks),
          ),
      ],
      recentPlaybacks: List<RecentPlayback>.unmodifiable(data.recentPlaybacks),
    );
    await _saveJson(
      _myMusicFileName,
      snapshot,
      entries:
          data.favoriteTrackPaths.length +
          data.recentPlaybacks.length +
          data.playlists.fold<int>(
            0,
            (count, playlist) =>
                count +
                1 +
                playlist.trackPaths.length +
                playlist.pendingTracks.length,
          ),
    );
  }

  Future<SavedPlayerQueue> loadPlayerQueue() async {
    final base =
        await _loadJsonWithBackup(_queueFileName, _decodePlayerQueue) ??
        const SavedPlayerQueue(items: [], currentIndex: -1);
    final hash = _snapshotHashes[_queueFileName];
    if (hash == null) {
      await _checkMissingDeltaBase(_queueFileName);
      return base;
    }
    final delta = await _loadJsonWithBackup(
      '$_queueFileName.delta',
      _decodeQueueDelta,
    );
    _snapshotBases[_queueFileName] = SnapshotBase(hash, base.items);
    if (delta?.hash != hash) return base;
    return SavedPlayerQueue(
      items: _applyDelta(_queueFileName, delta!, base.items),
      currentIndex: delta.metadata['currentIndex'] as int,
      shuffleEnabled: delta.metadata['shuffleEnabled'] as bool,
    );
  }

  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) {
    final saved = SavedPlayerQueue(
      items: List<PlayerItem>.unmodifiable(items),
      currentIndex: items.isEmpty
          ? -1
          : currentIndex.clamp(0, items.length - 1),
      shuffleEnabled: shuffleEnabled,
    );
    return _saveSnapshot(
      _queueFileName,
      saved.items,
      saved,
      {'currentIndex': saved.currentIndex, 'shuffleEnabled': shuffleEnabled},
      textCodeUnits: items.fold<int>(
        0,
        (count, item) => count + (item.lyrics?.length ?? 0),
      ),
    );
  }

  Future<List<DownloadTask>> loadDownloadTasks() async {
    return await _loadJsonWithBackup(
          _downloadTasksFileName,
          _decodeDownloadTasks,
        ) ??
        const [];
  }

  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {
    await _saveJson(
      _downloadTasksFileName,
      List<DownloadTask>.unmodifiable(tasks),
      entries: tasks.length,
      textCodeUnits: tasks.fold<int>(
        0,
        (count, task) => count + (task.lyrics?.length ?? 0),
      ),
    );
  }

  Future<List<PendingAlbumMatch>> loadPendingAlbumMatches() async {
    return await _loadJsonWithBackup(
          _pendingAlbumMatchesFileName,
          _decodePendingAlbumMatches,
        ) ??
        const [];
  }

  Future<void> savePendingAlbumMatches(List<PendingAlbumMatch> matches) async {
    await _saveJson(
      _pendingAlbumMatchesFileName,
      List<PendingAlbumMatch>.unmodifiable(matches),
      entries: matches.fold<int>(
        0,
        (count, match) => count + 1 + match.candidates.length,
      ),
    );
  }

  Future<String?> ensureEmbeddedCoverCache(DownloadedTrack track) async {
    final cachedPath = track.coverFilePath?.trim();
    if (cachedPath != null &&
        cachedPath.isNotEmpty &&
        await File(cachedPath).exists()) {
      return cachedPath;
    }

    final audioFile = File(track.path);
    if (!await audioFile.exists() || track.format.toLowerCase() != 'mp3') {
      return null;
    }

    return cacheEmbeddedCover(
      audioFile,
      cacheKey: 'embedded-${_normalizedPath(track.path)}',
    );
  }

  Future<String?> cacheEmbeddedCover(
    File audioFile, {
    required String cacheKey,
  }) async {
    final cover = await Id3LyricsEmbedder.extractCover(audioFile);
    if (cover == null) {
      return null;
    }

    return cacheCoverImage(cover, cacheKey: cacheKey);
  }

  Future<String> cacheCoverImage(
    Id3CoverImage cover, {
    required String cacheKey,
  }) async {
    final directory = await _supportDirectory('covers');
    // Preserve the entire identity, including directory and long filenames.
    final safeKey = sha256.convert(utf8.encode(cacheKey)).toString();
    final file = File(
      p.join(directory.path, '$safeKey.${_coverExtension(cover.mimeType)}'),
    );
    await file.writeAsBytes(cover.bytes, flush: true);
    return file.path;
  }

  Future<bool> deleteCachedCover(String? path) async {
    final value = path?.trim();
    if (value == null || value.isEmpty) {
      return false;
    }
    final directory = await _supportDirectory('covers');
    final root = _normalizedPath(directory.path);
    final candidate = _normalizedPath(value);
    if (!p.isWithin(root, candidate)) {
      return false;
    }
    final file = File(value);
    if (!await file.exists()) {
      return false;
    }
    await file.delete();
    return true;
  }

  Future<int> cleanupCachedCovers(
    Iterable<String?> retainedPaths, {
    Duration minimumAge = const Duration(days: 1),
  }) async {
    final directory = await _supportDirectory('covers');
    final retained = {
      for (final path in retainedPaths)
        if (path != null && path.trim().isNotEmpty) _normalizedPath(path),
    };
    final cutoff = DateTime.now().subtract(minimumAge);
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || retained.contains(_normalizedPath(entity.path))) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(cutoff)) {
          continue;
        }
        await entity.delete();
        removed += 1;
      } catch (error, stackTrace) {
        AppLog.instance.warning(
          'storage',
          '清理封面缓存失败',
          detail: '${entity.path}\n$error\n$stackTrace',
        );
      }
    }
    return removed;
  }

  String _normalizedPath(String value) {
    final normalized = p.normalize(p.absolute(value));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<String> defaultDownloadDirectory() async {
    final downloads = await getDownloadsDirectory();
    final base = downloads ?? await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(base.path, 'QingTing'));
    await directory.create(recursive: true);
    return directory.path;
  }

  Future<String> uniqueSavePath({
    required String downloadDirectory,
    required String title,
    required String artist,
    required String format,
    Iterable<String> reservedPaths = const [],
  }) async {
    final directory = Directory(downloadDirectory);
    await directory.create(recursive: true);

    final extension = format.trim().isEmpty ? 'mp3' : format.toLowerCase();
    final baseName = safeTrackBaseName(title: title, artist: artist);
    final reserved = reservedPaths.map(_normalizedPath).toSet();
    var candidate = p.join(directory.path, '$baseName.$extension');
    var index = 1;
    while (reserved.contains(_normalizedPath(candidate)) ||
        await File(candidate).exists()) {
      candidate = p.join(directory.path, '$baseName ($index).$extension');
      index += 1;
    }
    return candidate;
  }

  static String safeTrackBaseName({
    required String title,
    required String artist,
  }) {
    final safeTitle = sanitizeFilePart(title).isEmpty
        ? '未知歌曲'
        : sanitizeFilePart(title);
    final safeArtist = sanitizeFilePart(artist).isEmpty
        ? '未知歌手'
        : sanitizeFilePart(artist);
    return '$safeArtist - $safeTitle';
  }

  static String sanitizeFilePart(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^\.+|\.+$'), '');
    return cleaned.length > 90 ? cleaned.substring(0, 90).trim() : cleaned;
  }

  Future<File> _supportFile(String fileName) async {
    final directory = await _supportDirectory();
    return File(p.join(directory.path, fileName));
  }

  Future<Directory> _supportDirectory([String? child]) async {
    final base =
        _supportDirectoryOverride ?? await getApplicationSupportDirectory();
    final directory = child == null
        ? base
        : Directory(p.join(base.path, child));
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _rememberSnapshotHash(String fileName, String content) async {
    if (fileName == _libraryFileName || fileName == _queueFileName) {
      _snapshotHashes[fileName] = await _snapshotDigest(content);
    }
  }

  Future<void> _checkMissingDeltaBase(String fileName) async {
    final delta = await _supportFile('$fileName.delta');
    if (await delta.exists() || await _backupFile(delta).exists()) {
      final failure = StorageRecoveryException(
        path: (await _supportFile(fileName)).path,
      );
      _blockedJsonFiles[fileName] = failure;
      throw failure;
    }
  }

  List<T> _applyDelta<T extends Object>(
    String fileName,
    SnapshotDelta<T> delta,
    List<T> base,
  ) {
    try {
      return delta.apply(base);
    } catch (_) {
      final failure = StorageRecoveryException(path: '$fileName.delta');
      _blockedJsonFiles['$fileName.delta'] = failure;
      throw failure;
    }
  }

  Future<void> _saveSnapshot(
    String fileName,
    List<Object> items,
    Object value,
    Map<String, Object?> metadata, {
    int textCodeUnits = 0,
  }) {
    final previous = _snapshotWrites[fileName];
    late final Future<void> operation;
    operation = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          /* A later edit can retry. */
        }
      }
      _ensureJsonWritesAllowed();
      final base = _snapshotBases[fileName];
      if (base != null &&
          base.items.length >= incrementalEntryThreshold &&
          items.length >= incrementalEntryThreshold) {
        final delta = base.diff(items, metadata);
        if (delta != null) {
          final content = await _jsonCodec.encode(
            delta,
            entries: delta.changed.length,
            textCodeUnits: _changedTextSize(delta.changed.values),
          );
          if (content.length <= maxDeltaBytes ~/ 3) {
            await _saveJson('$fileName.delta', delta, serialized: content);
            return;
          }
        }
      }
      final content = await _jsonCodec.encode(
        value,
        entries: items.length,
        textCodeUnits: textCodeUnits,
      );
      final hash = await _snapshotDigest(content);
      if (base != null &&
          base.hash == hash &&
          base.items.length >= incrementalEntryThreshold) {
        // Reverting to the exact checkpoint must first commit an empty overlay.
        // Otherwise a crash could replay an older delta over identical bytes.
        final reset = SnapshotDelta<Object>(
          hash: hash,
          baseLength: items.length,
          length: items.length,
          changed: const {},
          metadata: metadata,
        );
        await _saveJson('$fileName.delta', reset);
      } else {
        await _saveJson(fileName, value, serialized: content);
      }
      _snapshotBases[fileName] = SnapshotBase(hash, items);
    }();
    _snapshotWrites[fileName] = operation;
    return operation.whenComplete(() {
      if (identical(_snapshotWrites[fileName], operation)) {
        _snapshotWrites.remove(fileName);
      }
    });
  }

  Future<T?> _loadJsonWithBackup<T>(
    String fileName,
    T Function(Object? json) decode,
  ) async {
    final file = await _supportFile(fileName);
    final backup = _backupFile(file);
    final primaryExists = await file.exists();
    final backupExists = await backup.exists();
    if (!primaryExists && !backupExists) {
      _blockedJsonFiles.remove(fileName);
      _snapshotHashes.remove(fileName);
      _snapshotBases.remove(fileName);
      return null;
    }
    if (primaryExists) {
      try {
        final content = await file.readAsString();
        final value = await _jsonCodec.decode(content, decode);
        await _rememberSnapshotHash(fileName, content);
        _blockedJsonFiles.remove(fileName);
        return value;
      } catch (error, stackTrace) {
        AppLog.instance.warning(
          'storage',
          '$fileName 主文件读取失败，尝试备份',
          detail: '$error\n$stackTrace',
        );
        // Try the last known-good generation below.
      }
    }

    late final String content;
    late final T value;
    try {
      if (!backupExists) throw const FormatException('数据备份不存在');
      content = await backup.readAsString();
      value = await _jsonCodec.decode(content, decode);
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'storage',
        '$fileName 主文件和备份均不可用',
        error: error,
        stackTrace: stackTrace,
      );
      final failure = StorageRecoveryException(path: file.path);
      _blockedJsonFiles[fileName] = failure;
      throw failure;
    }
    try {
      await _restorePrimaryFromBackup(file, content);
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'storage',
        '$fileName 备份可读，但恢复主文件失败',
        error: error,
        stackTrace: stackTrace,
      );
      final failure = StorageRecoveryException(
        path: file.path,
        backupAvailable: true,
      );
      _blockedJsonFiles[fileName] = failure;
      throw failure;
    }
    _blockedJsonFiles.remove(fileName);
    await _rememberSnapshotHash(fileName, content);
    AppLog.instance.info('storage', '$fileName 已从备份恢复，损坏主文件已另存');
    return value;
  }

  Future<void> _saveJson(
    String fileName,
    Object? value, {
    int entries = 0,
    int textCodeUnits = 0,
    String? serialized,
  }) async {
    final previous = _writeQueues[fileName];
    late final Future<void> operation;
    operation = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A failed generation must not block a newer save.
        }
      }
      _ensureJsonWritesAllowed();
      final content =
          serialized ??
          await _jsonCodec.encode(
            value,
            entries: entries,
            textCodeUnits: textCodeUnits,
          );
      // A parallel bootstrap read may discover corruption during encoding.
      _ensureJsonWritesAllowed();
      final file = await _supportFile(fileName);
      await _atomicWrite(file, content);
      await _rememberSnapshotHash(fileName, content);
    }();
    // Register before the first filesystem await so an immediate flush sees it.
    _writeQueues[fileName] = operation;
    try {
      await operation;
    } finally {
      if (identical(_writeQueues[fileName], operation)) {
        _writeQueues.remove(fileName);
      }
    }
  }

  void _ensureJsonWritesAllowed() {
    if (_blockedJsonFiles.isNotEmpty) throw _blockedJsonFiles.values.first;
  }

  Future<void> flushPendingWrites() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    while (_writeQueues.isNotEmpty || _snapshotWrites.isNotEmpty) {
      try {
        await Future.wait([..._writeQueues.values, ..._snapshotWrites.values]);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _atomicWrite(File file, String content) async {
    final temporary = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    final backup = _backupFile(file);
    var originalMoved = false;
    await temporary.writeAsString(content, flush: true);
    try {
      if (await file.exists()) {
        if (await backup.exists()) {
          await backup.delete();
        }
        await file.rename(backup.path);
        originalMoved = true;
      }
      await temporary.rename(file.path);
      if (!await _isValidJsonFile(backup)) {
        try {
          if (await backup.exists()) {
            await backup.delete();
          }
          await file.copy(backup.path);
        } catch (_) {
          // The primary generation is valid; a later save can recreate backup.
        }
      }
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'storage',
        '${p.basename(file.path)} 原子写入失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (!await file.exists() && originalMoved && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<void> _restorePrimaryFromBackup(File file, String content) async {
    final temporary = File(
      '${file.path}.restore-${DateTime.now().microsecondsSinceEpoch}',
    );
    File? preserved;
    try {
      await temporary.writeAsString(content, flush: true);
      if (await file.exists()) {
        final corrupt = File(
          '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}',
        );
        await file.rename(corrupt.path);
        preserved = corrupt;
      }
      await temporary.rename(file.path);
    } catch (_) {
      if (preserved != null && !await file.exists()) {
        await preserved.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  File _backupFile(File file) => File('${file.path}.bak');

  Future<bool> _isValidJsonFile(File file) async {
    if (!await file.exists()) {
      return false;
    }
    try {
      return await _jsonCodec.decode(await file.readAsString(), _acceptJson);
    } catch (_) {
      return false;
    }
  }

  String _coverExtension(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
  }
}

bool _acceptJson(Object? json) => true;

AppSettings _decodeSettings(Object? json) =>
    AppSettings.fromJson(Map<String, dynamic>.from(json as Map));

List<DownloadedTrack> _decodeDownloadedTracks(Object? json) =>
    (json as List<dynamic>)
        .map(
          (item) =>
              DownloadedTrack.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();

MyMusicData _decodeMyMusic(Object? json) {
  final data = Map<String, dynamic>.from(json as Map);
  _validateMapRecords(data['playlists']);
  _validateMapRecords(data['recentPlaybacks']);
  return MyMusicData.fromJson(data);
}

SavedPlayerQueue _decodePlayerQueue(Object? json) {
  final data = Map<String, dynamic>.from(json as Map);
  _validateMapRecords(data['items']);
  final saved = SavedPlayerQueue.fromJson(data);
  return SavedPlayerQueue(
    items: saved.items,
    currentIndex: saved.normalizedCurrentIndex,
    shuffleEnabled: saved.shuffleEnabled,
  );
}

void _validateMapRecords(Object? records) {
  if (records == null) return;
  if ((records as List).any((record) => record is! Map)) {
    throw const FormatException('数据记录格式错误');
  }
}

List<DownloadTask> _decodeDownloadTasks(Object? json) => (json as List<dynamic>)
    .map(
      (item) => DownloadTask.fromJson(Map<String, dynamic>.from(item as Map)),
    )
    .toList();

List<PendingAlbumMatch> _decodePendingAlbumMatches(Object? json) =>
    (json as List<dynamic>)
        .map(
          (item) => PendingAlbumMatch.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .where(
          (item) =>
              item.trackPath.trim().isNotEmpty &&
              item.title.trim().isNotEmpty &&
              item.candidates.isNotEmpty,
        )
        .toList();

SnapshotDelta<DownloadedTrack> _decodeLibraryDelta(Object? json) =>
    SnapshotDelta.decode(
      json,
      (value) => _decodeDownloadedTracks([value]).single,
      queue: false,
    );
SnapshotDelta<PlayerItem> _decodeQueueDelta(Object? json) =>
    SnapshotDelta.decode(
      json,
      (value) => _decodePlayerQueue({
        'items': [value],
        'currentIndex': 0,
      }).items.single,
      queue: true,
    );

int _changedTextSize(Iterable<Object> items) => items.fold(
  0,
  (count, item) =>
      count +
      switch (item) {
        DownloadedTrack track =>
          (track.metadataLyrics?.length ?? 0) +
              (track.syncedMetadata?.values.lyrics.length ?? 0),
        PlayerItem item => item.lyrics?.length ?? 0,
        _ => 0,
      },
);
Future<String> _snapshotDigest(String content) async {
  if (content.length < StorageJsonCodec.backgroundTextThreshold) {
    return sha256.convert(utf8.encode(content)).toString();
  }
  return Isolate.run(() => sha256.convert(utf8.encode(content)).toString());
}
