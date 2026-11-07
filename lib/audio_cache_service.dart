import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'download_transfer_service.dart';
import 'models.dart';

/// Owns the original audio bytes, independently of mpv's demuxer cache.
/// A loopback endpoint lets playback read the growing file without waiting for
/// the whole song. Downloads share that request and copy its validated result.
class AudioCacheService {
  AudioCacheService({
    required this.directory,
    required Dio dio,
    this.maxBytes = 512 * 1024 * 1024,
    this.maxAge = const Duration(days: 7),
  }) : _transfer = DownloadTransferService(dio);

  final Future<Directory> Function() directory;
  final DownloadTransferService _transfer;
  final int maxBytes;
  final Duration maxAge;
  final _entries = <String, _CacheEntry>{};
  final _evictions = <String, Future<void>>{};
  final _requests = <Future<void>>{};
  final _secret = List.generate(
    24,
    (_) => Random.secure().nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  Future<HttpServer>? _server;
  Future<Directory>? _root;
  Future<void>? _pruning;
  String? _playingKey;
  bool _disposed = false;

  // Signed URLs can change between playback and download. Match the source's
  // track and selected rendition, never just the title or an unscoped ID.
  static String trackKey(TrackSearchResult track, AudioCandidate candidate) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                track.source,
                track.id,
                candidate.format.toLowerCase(),
                candidate.bitrate,
                candidate.sizeBytes,
                candidate.qualityLabel,
              ]),
            ),
          )
          .toString();

  Future<Directory> _getRoot() => _root ??= directory();

  Future<Uri> playbackUri(String key, AudioCandidate candidate) async {
    _checkKey(key);
    if (_disposed) throw StateError('音频缓存已关闭。');
    _playingKey = key;
    for (final entry in _entries.values) {
      _cancelUnused(entry);
    }
    await _evictions[key];
    final entry = _entries.putIfAbsent(key, () => _CacheEntry(key, candidate));
    if (entry.operation == null || entry.error != null) {
      entry.candidate = candidate;
    }
    final held = await _acquire(key, candidate);
    _release(held);
    final server = await (_server ??= _bind());
    return Uri.parse('http://127.0.0.1:${server.port}/$_secret/$key');
  }

  void releasePlayback() {
    _playingKey = null;
    for (final entry in _entries.values) {
      _cancelUnused(entry);
    }
    unawaited(_pruneBestEffort());
  }

  Future<HttpServer> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_disposed) {
      await server.close(force: true);
      throw StateError('音频缓存已关闭。');
    }
    server.listen((request) {
      final operation = _serve(request);
      _requests.add(operation);
      unawaited(operation.whenComplete(() => _requests.remove(operation)));
    });
    return server;
  }

  Future<_CacheEntry> _acquire(String key, AudioCandidate candidate) async {
    _checkKey(key);
    if (_disposed) throw StateError('音频缓存已关闭。');
    final eviction = _evictions[key];
    if (eviction != null) {
      await eviction;
      return _acquire(key, candidate);
    }
    final entry = _entries.putIfAbsent(key, () => _CacheEntry(key, candidate));
    entry.users++;
    try {
      await (entry.loading ??= _load(entry));
      if (entry.token?.isCancelled ?? false) await entry.operation;
      if (_disposed) throw StateError('音频缓存已关闭。');
      return entry;
    } catch (_) {
      entry.users--;
      rethrow;
    }
  }

  Future<void> _load(_CacheEntry entry) async {
    final root = await _getRoot();
    await root.create(recursive: true);
    entry.file = File(p.join(root.path, '${entry.key}.audio'));
    entry.marker = File(p.join(root.path, '${entry.key}.json'));
    try {
      final metadata = jsonDecode(await entry.marker.readAsString()) as Map;
      final stat = await entry.marker.stat();
      final length = await entry.file.length();
      if (metadata['length'] == length &&
          length > 0 &&
          DateTime.now().difference(stat.modified) <= maxAge) {
        await DownloadTransferService.validateFile(entry.file);
        await entry.marker.setLastModified(DateTime.now());
        entry.received = length;
        entry.total = length;
        entry.complete = true;
        entry.ready = true;
        return;
      }
    } on Object {
      // Missing, interrupted or damaged cache entries are disposable.
    }
    if (await entry.file.exists()) await entry.file.delete();
    if (await entry.marker.exists()) await entry.marker.delete();
  }

  void _start(_CacheEntry entry) {
    if (entry.complete || entry.operation != null) return;
    entry.error = null;
    entry.token = CancelToken();
    entry.operation = _fetch(entry);
  }

  Future<void> _fetch(_CacheEntry entry) async {
    try {
      // A failed transfer starts fresh: no unverified partial cache is reused.
      await _transfer.download(
        DownloadTask(
          id: entry.key,
          track: const TrackSearchResult(
            id: '',
            title: '',
            artist: '',
            source: '',
            detailUrl: '',
          ),
          candidate: entry.candidate,
          status: DownloadStatus.downloading,
          progress: 0,
          savePath: entry.file.path,
        ),
        entry.token!,
        allowResume: false,
        onResponse: (_, total, _) {
          entry.total = total;
        },
        onProgress: (received, total) {
          entry.received = received;
          entry.total = total;
          entry.ready = true;
          entry.signal();
        },
      );
      entry.total = entry.received;
      await entry.marker.writeAsString(
        jsonEncode({'length': entry.received}),
        flush: true,
      );
      entry.complete = true;
    } catch (error) {
      entry.error = error;
    } finally {
      entry.signal();
      unawaited(_pruneBestEffort());
    }
  }

  /// Returns false on a cache miss, preserving the regular downloader's
  /// resumable transfer and cancellation behavior. A hit shares an active fetch.
  Future<bool> copyIfAvailable(
    DownloadTask task,
    CancelToken token, {
    required void Function(int, int?) onProgress,
    required void Function(int, int?, String?) onResponse,
  }) async {
    final key = trackKey(task.track, task.candidate);
    final root = await _getRoot();
    if (!_entries.containsKey(key) &&
        !await File(p.join(root.path, '$key.json')).exists()) {
      return false;
    }
    final entry = await _acquire(key, task.candidate);
    try {
      if (entry.error != null || (!entry.complete && entry.operation == null)) {
        return false;
      }
      while (!entry.complete) {
        if (token.isCancelled) throw token.cancelError!;
        onProgress(entry.received, entry.total);
        if (entry.error != null) return false;
        await Future.any([entry.changed.future, token.whenCancel]);
      }
      if (token.isCancelled) throw token.cancelError!;
      final target = File(task.savePath);
      await target.parent.create(recursive: true);
      final output = await target.open(mode: FileMode.write);
      var received = 0;
      try {
        onResponse(0, entry.received, null);
        await for (final chunk in entry.file.openRead()) {
          if (token.isCancelled) throw token.cancelError!;
          await output.writeFrom(chunk);
          received += chunk.length;
          onProgress(received, entry.received);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (token.isCancelled) throw token.cancelError!;
      return true;
    } finally {
      _release(entry);
    }
  }

  Future<void> _serve(HttpRequest request) async {
    _CacheEntry? held;
    try {
      final parts = request.uri.pathSegments;
      var entry = parts.length == 2 && parts.first == _secret
          ? _entries[parts.last]
          : null;
      if (entry == null || _disposed) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      held = await _acquire(entry.key, entry.candidate);
      entry = held;
      // A new request after an earlier failure gets a clean retry.
      if (entry.error != null && entry.users == 1) {
        entry.operation = null;
        entry.ready = false;
        entry.received = 0;
        entry.total = null;
      }
      _start(entry);
      while (!entry.ready && entry.error == null && !_disposed) {
        await entry.changed.future;
      }
      if (_disposed) throw StateError('音频缓存已关闭。');
      if (entry.error != null) throw entry.error!;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null && entry.total == null) {
        await entry.operation;
        if (entry.error != null) throw entry.error!;
      }
      final total = entry.total;
      final bounds = _range(range, total);
      if (bounds == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        if (total != null) {
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$total',
          );
        }
        return;
      }
      final (start, end) = bounds;
      final response = request.response;
      response.bufferOutput = false;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        _contentType(entry.candidate.format),
      );
      if (range != null && total != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }
      if (end != null) response.contentLength = end - start + 1;
      if (request.method == 'HEAD') return;
      final input = await entry.file.open();
      try {
        var position = start;
        await input.setPosition(position);
        while (end == null || position <= end) {
          if (_disposed) break;
          if (entry.error != null) throw entry.error!;
          final available = min(entry.received - position, 64 * 1024);
          final count = end == null
              ? available
              : min(available, end - position + 1);
          if (count > 0) {
            final chunk = await input.read(count);
            if (chunk.isEmpty) throw const FileSystemException('音频缓存读取不完整。');
            response.add(chunk);
            await response.flush();
            position += chunk.length;
          } else if (entry.complete) {
            break;
          } else {
            await entry.changed.future;
          }
        }
      } finally {
        await input.close();
      }
    } catch (_) {
      // An upstream failure terminates the stream; mpv reports it normally.
      try {
        request.response.statusCode = HttpStatus.badGateway;
      } on Object {
        // Headers may already have been sent.
      }
    } finally {
      if (held != null) _release(held);
      try {
        await request.response.close();
      } on Object {
        // The player may disconnect on stop, seek or song change.
      }
    }
  }

  static (int, int?)? _range(String? value, int? total) {
    if (value == null) return (0, total == null ? null : total - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || total == null || total <= 0) return null;
    if (match[1]!.isEmpty) {
      final suffix = int.tryParse(match[2]!);
      return suffix == null || suffix <= 0
          ? null
          : (max(0, total - suffix), total - 1);
    }
    final start = int.tryParse(match[1]!);
    final end = match[2]!.isEmpty ? total - 1 : int.tryParse(match[2]!);
    if (start == null || end == null || start >= total || end < start) {
      return null;
    }
    return (start, min(end, total - 1));
  }

  static String _contentType(String format) => switch (format.toLowerCase()) {
    'mp3' => 'audio/mpeg',
    'm4a' || 'mp4' => 'audio/mp4',
    'flac' => 'audio/flac',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'aac' => 'audio/aac',
    _ => 'application/octet-stream',
  };

  static void _checkKey(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', 'Invalid audio cache key');
    }
  }

  void _release(_CacheEntry entry) {
    entry.users--;
    _cancelUnused(entry);
    unawaited(_pruneBestEffort());
  }

  void _cancelUnused(_CacheEntry entry) {
    if (entry.key != _playingKey && entry.users == 0 && !entry.complete) {
      entry.token?.cancel('播放已停止，保留其他正在使用的传输。');
    }
  }

  Future<void> _pruneBestEffort() async {
    if (_disposed || _root == null) return;
    try {
      await (_pruning ??= _prune().whenComplete(() => _pruning = null));
    } catch (error) {
      AppLog.instance.warning('cache', '清理音频缓存失败', detail: error);
    }
  }

  Future<void> _prune() async {
    final root = await _getRoot();
    if (!await root.exists()) return;
    final files = <(File, int, DateTime)>[];
    var bytes = 0;
    await for (final entity in root.list()) {
      if (entity is! File || p.extension(entity.path) != '.audio') continue;
      final stat = await entity.stat();
      final marker = File(p.setExtension(entity.path, '.json'));
      final markerStat = await marker.stat();
      bytes += stat.size;
      files.add((
        entity,
        stat.size,
        markerStat.type == FileSystemEntityType.file
            ? markerStat.modified
            : stat.modified,
      ));
    }
    files.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (file, size, modified) in files) {
      final key = p.basenameWithoutExtension(file.path);
      final entry = _entries[key];
      if (key == _playingKey ||
          (entry != null &&
              (entry.users > 0 || (!entry.complete && entry.error == null)))) {
        continue;
      }
      if (bytes <= maxBytes && DateTime.now().difference(modified) <= maxAge) {
        continue;
      }
      // Publish the eviction synchronously so new readers wait for it.
      final eviction = () async {
        if (await file.exists()) await file.delete();
        final marker = File(p.join(root.path, '$key.json'));
        if (await marker.exists()) await marker.delete();
        _entries.remove(key);
      }();
      _evictions[key] = eviction;
      try {
        await eviction;
        bytes -= size;
      } finally {
        _evictions.remove(key);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _entries.values) {
      entry.token?.cancel('音频缓存已关闭。');
      entry.signal();
    }
    final server = _server;
    if (server != null) {
      try {
        await (await server).close(force: true);
      } on Object {
        // Binding may have failed or been interrupted by disposal.
      }
    }
    await Future.wait(_requests.toList());
    await Future.wait([
      for (final entry in _entries.values)
        if (entry.operation != null) entry.operation!,
    ]);
    await _pruning;
  }
}

class _CacheEntry {
  _CacheEntry(this.key, this.candidate);
  final String key;
  AudioCandidate candidate;
  late File file;
  late File marker;
  Future<void>? loading;
  Future<void>? operation;
  CancelToken? token;
  Completer<void> changed = Completer<void>();
  int users = 0;
  int received = 0;
  int? total;
  bool ready = false;
  bool complete = false;
  Object? error;

  void signal() {
    final previous = changed;
    changed = Completer<void>();
    previous.complete();
  }
}
