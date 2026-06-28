import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'models.dart';
import 'music_source.dart';

class MyFreeMp3Source
    implements MusicSource, DownloadMusicSource, DeferredDownloadMusicSource {
  MyFreeMp3Source({Dio? dio, Uri? siteUri, Uri? apiUri, Uri? downloadUri})
    : _siteUri = siteUri ?? Uri.parse('https://myfreemp3.ink/'),
      _apiUri = apiUri ?? Uri.parse('https://api.myfreemp3.ink/'),
      _downloadUri = downloadUri ?? Uri.parse('https://api.myfreemp3.ink/'),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 25),
              responseType: ResponseType.plain,
              validateStatus: (status) => status != null,
            ),
          );

  final Dio _dio;
  final Uri _siteUri;
  final Uri _apiUri;
  final Uri _downloadUri;

  String? _keyId;
  String? _signingKey;
  int _expiresAt = 0;
  int _clockOffsetSeconds = 0;
  Future<void>? _bootstrapFuture;
  final Map<String, Future<AudioCandidate>> _preparedCandidates = {};

  @override
  String get name => 'MY FREE MP3';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    final query = _sanitizeQuery(keyword);
    if (query.isEmpty) {
      return const [];
    }
    final uri = _apiUri.replace(
      pathSegments: ['search', query],
      queryParameters: page > 1 ? {'page': '$page'} : null,
    );
    final html = await _signedGetString(uri);
    return MyFreeMp3Parser.parseSearchResults(html, siteUri: _siteUri);
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    final ids = _idsFromResult(result);
    return TrackDetail(
      title: result.title,
      artist: result.artist,
      sourceUrl: result.detailUrl,
      candidates: const [],
      rawMetadata: {
        if (ids != null) 'owner_id': ids.$1,
        if (ids != null) 'track_id': ids.$2,
      },
      coverUrl: result.coverUrl,
      album: result.album,
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    final ownerId = detail.rawMetadata['owner_id'];
    final trackId = detail.rawMetadata['track_id'];
    if (ownerId == null || trackId == null) {
      return const [];
    }
    return [await _prepareCandidate(ownerId, trackId)];
  }

  @override
  Future<List<AudioCandidate>> resolveDownloadCandidates(
    TrackDetail detail,
  ) async {
    final ownerId = detail.rawMetadata['owner_id'];
    final trackId = detail.rawMetadata['track_id'];
    if (ownerId == null || trackId == null) {
      return const [];
    }
    return [
      AudioCandidate(
        url: 'myfreemp3-job://prepare/$ownerId/$trackId',
        format: 'mp3',
        qualityLabel: 'MP3（后台生成）',
      ),
    ];
  }

  @override
  Future<AudioCandidate> prepareDownloadCandidate(
    AudioCandidate candidate,
  ) async {
    final uri = Uri.tryParse(candidate.url);
    if (uri == null || uri.scheme != 'myfreemp3-job') {
      return candidate;
    }
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (uri.host != 'prepare' || parts.length != 2) {
      throw const MusicSourceException('MY FREE MP3 下载任务信息不完整。');
    }
    return _prepareCandidate(parts[0], parts[1]);
  }

  Future<AudioCandidate> _prepareCandidate(
    String ownerId,
    String trackId,
  ) async {
    final key = '$ownerId:$trackId';
    final existing = _preparedCandidates[key];
    if (existing != null) {
      return existing;
    }
    final future = _createPreparedCandidate(ownerId, trackId);
    _preparedCandidates[key] = future;
    try {
      return await future;
    } catch (_) {
      if (identical(_preparedCandidates[key], future)) {
        _preparedCandidates.remove(key);
      }
      rethrow;
    }
  }

  Future<AudioCandidate> _createPreparedCandidate(
    String ownerId,
    String trackId,
  ) async {
    final jobId = await _startDownloadJob(ownerId, trackId);
    await _waitForDownloadJob(jobId, ownerId: ownerId, trackId: trackId);
    return AudioCandidate(
      url: _downloadUri.resolve('/download/job/file/$jobId').toString(),
      format: 'mp3',
      qualityLabel: 'MP3',
      headers: _downloadHeaders(ownerId, trackId),
    );
  }

  Future<String> _startDownloadJob(String ownerId, String trackId) async {
    final uri = _downloadUri.resolve('/download/job/start/$ownerId/$trackId');
    final response = await _downloadJsonRequest(
      uri,
      method: 'POST',
      headers: _downloadHeaders(ownerId, trackId),
    );
    final status = response.$1;
    final data = response.$2;
    if (status >= 400) {
      throw MusicSourceException(
        data['error']?.toString() ??
            data['detail']?.toString() ??
            'MY FREE MP3 创建下载任务失败：HTTP $status。',
      );
    }
    final jobId = data['job_id']?.toString();
    if (jobId == null || jobId.isEmpty) {
      throw const MusicSourceException('MY FREE MP3 没有返回下载任务编号。');
    }
    return jobId;
  }

  Future<void> _waitForDownloadJob(
    String jobId, {
    required String ownerId,
    required String trackId,
  }) async {
    final uri = _downloadUri.resolve('/download/job/progress/$jobId');
    for (var attempt = 0; attempt < 150; attempt += 1) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      final response = await _downloadJsonRequest(
        uri,
        headers: _downloadHeaders(ownerId, trackId),
      );
      final statusCode = response.$1;
      final data = response.$2;
      if (statusCode >= 400) {
        throw MusicSourceException(
          data['error']?.toString() ??
              data['detail']?.toString() ??
              'MY FREE MP3 查询下载进度失败：HTTP $statusCode。',
        );
      }
      final status = data['status']?.toString().toLowerCase();
      if (status == 'done') {
        return;
      }
      if (status == 'error') {
        throw MusicSourceException(
          data['error']?.toString() ?? 'MY FREE MP3 生成 MP3 文件失败。',
        );
      }
    }
    throw const MusicSourceException('MY FREE MP3 生成 MP3 文件超时，请稍后重试。');
  }

  Future<(int, Map<String, dynamic>)> _downloadJsonRequest(
    Uri uri, {
    String method = 'GET',
    required Map<String, String> headers,
  }) async {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      try {
        final response = method == 'POST'
            ? await _dio.postUri<String>(
                uri,
                options: Options(headers: headers),
              )
            : await _dio.getUri<String>(
                uri,
                options: Options(headers: headers),
              );
        final status = response.statusCode ?? 0;
        if (_isTransientStatus(status) && attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 700 * (attempt + 1)),
          );
          continue;
        }
        return (status, _jsonObject(response.data));
      } on DioException catch (error) {
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 700 * (attempt + 1)),
          );
          continue;
        }
        throw MusicSourceException(
          '连接 MY FREE MP3 下载服务失败：${error.message ?? error.type.name}',
        );
      }
    }
    throw const MusicSourceException('连接 MY FREE MP3 下载服务失败。');
  }

  bool _isTransientStatus(int status) {
    return status == 429 ||
        status == 502 ||
        status == 503 ||
        status == 504 ||
        (status >= 520 && status <= 524);
  }

  Future<String> _signedGetString(Uri uri, {bool retry = true}) async {
    await _ensureSigningKey();
    final response = await _dio.getUri<String>(
      uri,
      options: Options(headers: await _signedHeaders(uri)),
    );
    final status = response.statusCode ?? 0;
    if (status == 403 && retry) {
      final body = _jsonObject(response.data);
      final serverTime = body['server_time'];
      if (serverTime is num) {
        _applyServerTime(serverTime.toInt());
      }
      _clearSigningKey();
      await _ensureSigningKey(force: true);
      return _signedGetString(uri, retry: false);
    }
    if (status == 429) {
      throw const MusicSourceException('MY FREE MP3 返回 HTTP 429，请稍后重试。');
    }
    if (status >= 400) {
      final reason = _jsonObject(response.data)['reason']?.toString();
      throw MusicSourceException(
        reason == null || reason.isEmpty
            ? 'MY FREE MP3 返回 HTTP $status。'
            : 'MY FREE MP3 返回 HTTP $status（$reason）。',
      );
    }
    return response.data?.toString() ?? '';
  }

  Future<Map<String, String>> _signedHeaders(Uri uri) async {
    final keyId = _keyId;
    final signingKey = _signingKey;
    if (keyId == null || signingKey == null) {
      throw const MusicSourceException('MY FREE MP3 签名初始化失败。');
    }
    final timestamp = _nowSeconds();
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final path = _decodedSigningPath(uri.path);
    final message = '$timestamp\nGET\n$path\n$query';
    final signature = Hmac(
      sha256,
      utf8.encode(signingKey),
    ).convert(utf8.encode(message)).toString();
    return {
      ..._requestHeaders(accept: 'text/html,application/xhtml+xml'),
      'X-Api-Key-Id': keyId,
      'X-Api-Ts': '$timestamp',
      'X-Api-Sig': signature,
    };
  }

  Future<void> _ensureSigningKey({bool force = false}) async {
    if (!force && !_signingKeyNeedsRefresh()) {
      return;
    }
    final pending = _bootstrapFuture;
    if (!force && pending != null) {
      return pending;
    }
    final future = _bootstrapSigningKey();
    _bootstrapFuture = future;
    try {
      await future;
    } finally {
      if (identical(_bootstrapFuture, future)) {
        _bootstrapFuture = null;
      }
    }
  }

  Future<void> _bootstrapSigningKey() async {
    final uri = _apiUri.resolve('/api/signing/bootstrap');
    final response = await _dio.getUri<String>(
      uri,
      options: Options(headers: _requestHeaders(accept: 'application/json')),
    );
    final status = response.statusCode ?? 0;
    if (status >= 400) {
      throw MusicSourceException('MY FREE MP3 签名接口返回 HTTP $status。');
    }
    final data = _jsonObject(response.data);
    final keyId = data['key_id']?.toString();
    final signingKey = data['signing_key']?.toString();
    if (keyId == null ||
        keyId.isEmpty ||
        signingKey == null ||
        signingKey.isEmpty) {
      throw const MusicSourceException('MY FREE MP3 没有返回可用的临时签名。');
    }
    _keyId = keyId;
    _signingKey = signingKey;
    _expiresAt = (data['expires_at'] as num?)?.toInt() ?? 0;
    final serverTime = (data['server_time'] as num?)?.toInt();
    if (serverTime != null) {
      _applyServerTime(serverTime);
    }
  }

  Map<String, String> _requestHeaders({required String accept}) {
    return {
      'Accept': accept,
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.7',
      'Origin': _originFor(_siteUri),
      'Referer': _siteUri.toString(),
      'User-Agent': 'QingTing/1.3.1 (+personal-use)',
      'X-Requested-With': 'XMLHttpRequest',
    };
  }

  Map<String, String> _downloadHeaders(String ownerId, String trackId) {
    return {
      'Accept': 'application/json, audio/mpeg, */*',
      'Referer': _downloadUri
          .resolve('/download/ui/$ownerId/$trackId')
          .toString(),
      'User-Agent': 'QingTing/1.3.1 (+personal-use)',
    };
  }

  bool _signingKeyNeedsRefresh() {
    return _keyId == null ||
        _signingKey == null ||
        _nowSeconds() >= _expiresAt - 45;
  }

  int _nowSeconds() {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 + _clockOffsetSeconds;
  }

  void _applyServerTime(int serverTime) {
    _clockOffsetSeconds =
        serverTime - DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  void _clearSigningKey() {
    _keyId = null;
    _signingKey = null;
    _expiresAt = 0;
  }

  (String, String)? _idsFromResult(TrackSearchResult result) {
    final parts = result.id.split(':');
    if (parts.length != 3 || parts.first != 'mfm') {
      return null;
    }
    return (parts[1], parts[2]);
  }

  String _sanitizeQuery(String value) {
    return value
        .replaceAll(RegExp(r'[\\/]+'), ' ')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
        .replaceAll(RegExp(r'[?#%<>{}\[\]|^`]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Map<String, dynamic> _jsonObject(Object? data) {
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    try {
      final decoded = jsonDecode(data?.toString() ?? '{}');
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  String _originFor(Uri uri) {
    final defaultPort =
        (uri.scheme == 'https' && uri.port == 443) ||
        (uri.scheme == 'http' && uri.port == 80);
    return '${uri.scheme}://${uri.host}${defaultPort ? '' : ':${uri.port}'}';
  }

  String _decodedSigningPath(String path) {
    try {
      return Uri.decodeComponent(path);
    } catch (_) {
      return path;
    }
  }
}

class MyFreeMp3Parser {
  const MyFreeMp3Parser._();

  static List<TrackSearchResult> parseSearchResults(
    String html, {
    required Uri siteUri,
  }) {
    final document = html_parser.parse(html);
    final results = <TrackSearchResult>[];
    final seen = <String>{};
    for (final track in document.querySelectorAll('.track')) {
      final ownerId = track.attributes['data-owner-id']?.trim() ?? '';
      final trackId = track.attributes['data-track-id']?.trim() ?? '';
      final streamUrl = track.attributes['data-download']?.trim() ?? '';
      final title = track.querySelector('.track-title')?.text.trim() ?? '';
      final artist = track.querySelector('.track-artist')?.text.trim() ?? '';
      if (ownerId.isEmpty ||
          trackId.isEmpty ||
          streamUrl.isEmpty ||
          title.isEmpty) {
        continue;
      }
      final id = 'mfm:$ownerId:$trackId';
      if (!seen.add(id)) {
        continue;
      }
      results.add(
        TrackSearchResult(
          id: id,
          title: title,
          artist: artist,
          source: 'MY FREE MP3',
          detailUrl: siteUri.resolve(streamUrl).toString(),
          duration: track.querySelector('.track-duration')?.text.trim(),
          coverUrl: _coverUrl(track, siteUri),
        ),
      );
    }
    return results;
  }

  static String? _coverUrl(dom.Element track, Uri siteUri) {
    final style = track.querySelector('.play-toggle')?.attributes['style'];
    if (style == null) {
      return null;
    }
    final match = RegExp(
      r'''background-image\s*:\s*url\((?:['])?(.*?)(?:['])?\)''',
      caseSensitive: false,
    ).firstMatch(style);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty
        ? null
        : siteUri.resolve(value).toString();
  }
}
