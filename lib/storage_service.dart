import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'id3_lyrics_embedder.dart';
import 'models.dart';

class StorageService {
  static const _settingsFileName = 'settings.json';
  static const _libraryFileName = 'downloads.json';
  static const _queueFileName = 'queue.json';
  static const _myMusicFileName = 'my_music.json';

  Future<AppSettings> loadSettings() async {
    final file = await _supportFile(_settingsFileName);
    if (!await file.exists()) {
      return AppSettings(downloadDirectory: await defaultDownloadDirectory());
    }

    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return AppSettings.fromJson(json);
    } catch (_) {
      return AppSettings(downloadDirectory: await defaultDownloadDirectory());
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    final file = await _supportFile(_settingsFileName);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }

  Future<List<DownloadedTrack>> loadDownloadedTracks() async {
    final file = await _supportFile(_libraryFileName);
    if (!await file.exists()) {
      return const [];
    }

    try {
      final json = jsonDecode(await file.readAsString()) as List<dynamic>;
      return json
          .whereType<Map>()
          .map(
            (item) => DownloadedTrack.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    final file = await _supportFile(_libraryFileName);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(tracks.map((track) => track.toJson()).toList()),
    );
  }

  Future<MyMusicData> loadMyMusic() async {
    final file = await _supportFile(_myMusicFileName);
    if (!await file.exists()) {
      return const MyMusicData();
    }

    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return MyMusicData.fromJson(json);
    } catch (_) {
      return const MyMusicData();
    }
  }

  Future<void> saveMyMusic(MyMusicData data) async {
    final file = await _supportFile(_myMusicFileName);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data.toJson()),
    );
  }

  Future<SavedPlayerQueue> loadPlayerQueue() async {
    final file = await _supportFile(_queueFileName);
    if (!await file.exists()) {
      return const SavedPlayerQueue(items: [], currentIndex: -1);
    }

    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final saved = SavedPlayerQueue.fromJson(json);
      return SavedPlayerQueue(
        items: saved.items,
        currentIndex: saved.normalizedCurrentIndex,
        shuffleEnabled: saved.shuffleEnabled,
      );
    } catch (_) {
      return const SavedPlayerQueue(items: [], currentIndex: -1);
    }
  }

  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {
    final file = await _supportFile(_queueFileName);
    final saved = SavedPlayerQueue(
      items: items,
      currentIndex: items.isEmpty
          ? -1
          : currentIndex.clamp(0, items.length - 1).toInt(),
      shuffleEnabled: shuffleEnabled,
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(saved.toJson()),
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
    final base = await getApplicationSupportDirectory();
    final directory = child == null
        ? base
        : Directory(p.join(base.path, child));
    await directory.create(recursive: true);
    return directory;
  }

  String _coverExtension(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
  }
}
