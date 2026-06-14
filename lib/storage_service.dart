import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class StorageService {
  static const _settingsFileName = 'settings.json';
  static const _libraryFileName = 'downloads.json';

  Future<AppSettings> loadSettings() async {
    final file = await _supportFile(_settingsFileName);
    if (!await file.exists()) {
      return AppSettings(downloadDirectory: await defaultDownloadDirectory());
    }

    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
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
          .map((item) => DownloadedTrack.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    final file = await _supportFile(_libraryFileName);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(tracks.map((track) => track.toJson()).toList()),
    );
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
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File(p.join(directory.path, fileName));
  }
}
