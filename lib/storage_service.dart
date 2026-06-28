import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'id3_lyrics_embedder.dart';
import 'models.dart';

class StorageService {
  StorageService({Directory? supportDirectory})
    : _supportDirectoryOverride = supportDirectory;

  static const _settingsFileName = 'settings.json';
  static const _libraryFileName = 'downloads.json';
  static const _queueFileName = 'queue.json';
  static const _myMusicFileName = 'my_music.json';
  static const _downloadTasksFileName = 'download_tasks.json';

  final Directory? _supportDirectoryOverride;
  final Map<String, Future<void>> _writeQueues = {};

  Future<AppSettings> loadSettings() async {
    final file = await _supportFile(_settingsFileName);
    if (!await file.exists() && !await _backupFile(file).exists()) {
      return AppSettings(downloadDirectory: await defaultDownloadDirectory());
    }

    final settings = await _loadJsonWithBackup(
      _settingsFileName,
      (json) => AppSettings.fromJson(Map<String, dynamic>.from(json as Map)),
    );
    return settings ??
        AppSettings(downloadDirectory: await defaultDownloadDirectory());
  }

  Future<void> saveSettings(AppSettings settings) async {
    await _saveJson(_settingsFileName, settings.toJson());
  }

  Future<List<DownloadedTrack>> loadDownloadedTracks() async {
    final file = await _supportFile(_libraryFileName);
    if (!await file.exists() && !await _backupFile(file).exists()) {
      return const [];
    }

    return await _loadJsonWithBackup(
          _libraryFileName,
          (json) => (json as List<dynamic>)
              .whereType<Map>()
              .map(
                (item) =>
                    DownloadedTrack.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList(),
        ) ??
        const [];
  }

  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    await _saveJson(
      _libraryFileName,
      tracks.map((track) => track.toJson()).toList(),
    );
  }

  Future<MyMusicData> loadMyMusic() async {
    final file = await _supportFile(_myMusicFileName);
    if (!await file.exists() && !await _backupFile(file).exists()) {
      return const MyMusicData();
    }

    return await _loadJsonWithBackup(
          _myMusicFileName,
          (json) =>
              MyMusicData.fromJson(Map<String, dynamic>.from(json as Map)),
        ) ??
        const MyMusicData();
  }

  Future<void> saveMyMusic(MyMusicData data) async {
    await _saveJson(_myMusicFileName, data.toJson());
  }

  Future<SavedPlayerQueue> loadPlayerQueue() async {
    final file = await _supportFile(_queueFileName);
    if (!await file.exists() && !await _backupFile(file).exists()) {
      return const SavedPlayerQueue(items: [], currentIndex: -1);
    }

    return await _loadJsonWithBackup(_queueFileName, (json) {
          final saved = SavedPlayerQueue.fromJson(
            Map<String, dynamic>.from(json as Map),
          );
          return SavedPlayerQueue(
            items: saved.items,
            currentIndex: saved.normalizedCurrentIndex,
            shuffleEnabled: saved.shuffleEnabled,
          );
        }) ??
        const SavedPlayerQueue(items: [], currentIndex: -1);
  }

  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {
    final saved = SavedPlayerQueue(
      items: items,
      currentIndex: items.isEmpty
          ? -1
          : currentIndex.clamp(0, items.length - 1).toInt(),
      shuffleEnabled: shuffleEnabled,
    );
    await _saveJson(_queueFileName, saved.toJson());
  }

  Future<List<DownloadTask>> loadDownloadTasks() async {
    final file = await _supportFile(_downloadTasksFileName);
    if (!await file.exists() && !await _backupFile(file).exists()) {
      return const [];
    }
    return await _loadJsonWithBackup(
          _downloadTasksFileName,
          (json) => (json as List<dynamic>)
              .whereType<Map>()
              .map(
                (item) =>
                    DownloadTask.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList(),
        ) ??
        const [];
  }

  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {
    await _saveJson(
      _downloadTasksFileName,
      tasks.map((task) => task.toJson()).toList(),
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
      cacheKey: '${track.id}-${p.basenameWithoutExtension(track.path)}',
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
    final safeKey = sanitizeFilePart(cacheKey).isEmpty
        ? 'cover'
        : sanitizeFilePart(cacheKey);
    final file = File(
      p.join(directory.path, '$safeKey.${_coverExtension(cover.mimeType)}'),
    );
    await file.writeAsBytes(cover.bytes, flush: true);
    return file.path;
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
  }) async {
    final directory = Directory(downloadDirectory);
    await directory.create(recursive: true);

    final extension = format.trim().isEmpty ? 'mp3' : format.toLowerCase();
    final baseName = safeTrackBaseName(title: title, artist: artist);
    var candidate = p.join(directory.path, '$baseName.$extension');
    var index = 1;
    while (await File(candidate).exists()) {
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

  Future<T?> _loadJsonWithBackup<T>(
    String fileName,
    T Function(Object? json) decode,
  ) async {
    final file = await _supportFile(fileName);
    if (await file.exists()) {
      try {
        return decode(jsonDecode(await file.readAsString()));
      } catch (_) {
        // Try the last known-good generation below.
      }
    }

    final backup = _backupFile(file);
    if (!await backup.exists()) {
      return null;
    }
    try {
      final content = await backup.readAsString();
      final value = decode(jsonDecode(content));
      await _restorePrimaryFromBackup(file, content);
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveJson(String fileName, Object? value) async {
    final file = await _supportFile(fileName);
    final content = const JsonEncoder.withIndent('  ').convert(value);
    final previous = _writeQueues[file.path];
    late final Future<void> operation;
    operation = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A failed generation must not block a newer save.
        }
      }
      await _atomicWrite(file, content);
    }();
    _writeQueues[file.path] = operation;
    try {
      await operation;
    } finally {
      if (identical(_writeQueues[file.path], operation)) {
        _writeQueues.remove(file.path);
      }
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
    } catch (_) {
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
    await temporary.writeAsString(content, flush: true);
    try {
      if (await file.exists()) {
        await file.delete();
      }
      await temporary.rename(file.path);
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
      jsonDecode(await file.readAsString());
      return true;
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
