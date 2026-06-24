import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'models.dart';
import 'music_source.dart';

class GequbaoSource implements MusicSource {
  GequbaoSource({Dio? dio, Uri? baseUri})
    : _baseUri = baseUri ?? Uri.parse('https://www.gequbao.com/'),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 18),
              responseType: ResponseType.plain,
              headers: _browserLikeHeaders(),
              validateStatus: _validateAnyStatus,
            ),
          );

  final Dio _dio;
  final Uri _baseUri;

  @override
  String get name => '歌曲宝';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final encoded = Uri.encodeComponent(trimmed);
    final uri = _baseUri.resolve('/s/$encoded${page > 1 ? '?page=$page' : ''}');
    final html = await _getString(uri, referer: _baseUri.toString());
    return GequbaoParser.parseSearchResults(html, baseUrl: _baseUri);
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    final detailUri = _baseUri.resolve(result.detailUrl);
    final html = await _getString(detailUri, referer: _baseUri.toString());
    final detail = GequbaoParser.parseTrackDetail(
      html,
      baseUrl: _baseUri,
      fallback: result,
    );
    final playId = detail.rawMetadata['play_id'];
    final apiCandidate = playId == null || playId.isEmpty
        ? null
        : await _resolveCommonPlayCandidate(playId, detail.sourceUrl);

    if (apiCandidate == null) {
      return detail;
    }
    return TrackDetail(
      title: detail.title,
      artist: detail.artist,
      sourceUrl: detail.sourceUrl,
      candidates: [apiCandidate, ...detail.candidates],
      rawMetadata: detail.rawMetadata,
      lyrics: detail.lyrics,
      coverUrl: detail.coverUrl,
      album: detail.album,
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    return detail.candidates;
  }

  Future<String> _getString(Uri uri, {String? referer}) async {
    try {
      Response<String>? lastResponse;
      for (var attempt = 0; attempt < 2; attempt += 1) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
        final response = await _dio.getUri<String>(
          uri,
          options: Options(headers: _browserLikeHeaders(referer: referer)),
        );
        lastResponse = response;
        final status = response.statusCode ?? 0;
        if (!_shouldRetryStatus(status)) {
          break;
        }
      }

      final response = lastResponse;
      final status = response?.statusCode ?? 0;
      if (status == 403) {
        throw const MusicSourceException('歌曲宝拒绝了程序请求。请稍后重试，或在浏览器打开歌曲宝后再试。');
      }
      if (status == 520) {
        throw const MusicSourceException(
          '歌曲宝当前拦截或异常返回 HTTP 520。搜索可稍后重试，或减少连续搜索/播放次数。',
        );
      }
      if (status >= 400) {
        throw MusicSourceException('歌曲宝返回 HTTP $status，当前无法读取该页面。');
      }
      return response?.data?.toString() ?? '';
    } on MusicSourceException {
      rethrow;
    } on DioException catch (error) {
      throw MusicSourceException(_messageForDio(error));
    } catch (error) {
      throw MusicSourceException('读取页面失败：$error');
    }
  }

  Future<AudioCandidate?> _resolveCommonPlayCandidate(
    String playId,
    String sourceUrl,
  ) async {
    try {
      final response = await _dio.postUri<String>(
        _baseUri.resolve('/member/common-play-url'),
        data: {'id': playId},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            ..._browserLikeHeaders(referer: sourceUrl),
            'Accept': 'application/json, text/javascript, */*; q=0.01',
            'X-Requested-With': 'XMLHttpRequest',
            'Origin': _originFor(_baseUri),
            'Referer': sourceUrl,
          },
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 403) {
        throw const MusicSourceException('歌曲宝要求验证后才能解析这个音频链接。');
      }
      if (status >= 400) {
        throw MusicSourceException('歌曲宝播放接口返回 HTTP $status。');
      }

      final payload = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
      if (payload['code'] != 1) {
        final message = payload['msg']?.toString();
        if (payload['code'] == 2 || payload['code'] == 3) {
          throw MusicSourceException(message ?? '歌曲宝要求验证后才能解析这个音频链接。');
        }
        throw MusicSourceException(message ?? '歌曲宝没有返回可用的音频链接。');
      }

      final data = payload['data'];
      if (data is! Map) {
        return null;
      }
      final url = data['url']?.toString() ?? '';
      if (url.isEmpty) {
        return null;
      }
      final format = GequbaoParser.formatFromUrl(url);
      return AudioCandidate(
        url: url,
        format: format,
        qualityLabel: format.toUpperCase(),
        headers: const {},
      );
    } on MusicSourceException {
      rethrow;
    } on DioException catch (error) {
      throw MusicSourceException(_messageForDio(error));
    } catch (error) {
      throw MusicSourceException('解析歌曲宝音频链接失败：$error');
    }
  }

  static bool _validateAnyStatus(int? status) => status != null;

  static bool _shouldRetryStatus(int status) {
    return status == 520 ||
        status == 521 ||
        status == 522 ||
        status == 523 ||
        status == 524 ||
        status == 429;
  }

  static Map<String, String> _browserLikeHeaders({String? referer}) {
    return {
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.7',
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
      'Referer': referer ?? 'https://www.gequbao.com/',
      'Upgrade-Insecure-Requests': '1',
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36 QingTing/1.2.4',
    };
  }

  static String _originFor(Uri uri) {
    final defaultPort =
        (uri.scheme == 'https' && uri.port == 443) ||
        (uri.scheme == 'http' && uri.port == 80);
    return '${uri.scheme}://${uri.host}${defaultPort ? '' : ':${uri.port}'}';
  }

  static String _messageForDio(DioException error) {
    final status = error.response?.statusCode;
    if (status == 403) {
      return '歌曲宝拒绝了程序请求。请稍后重试，或在浏览器确认该公开页面是否仍可访问。';
    }
    if (status != null) {
      return '歌曲宝返回 HTTP $status，当前无法读取该页面。';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return '连接歌曲宝超时，请检查网络后重试。';
    }
    return '连接歌曲宝失败：${error.message ?? error.type.name}';
  }
}

class GequbaoParser {
  static List<TrackSearchResult> parseSearchResults(
    String html, {
    required Uri baseUrl,
  }) {
    final document = html_parser.parse(html);
    final results = <TrackSearchResult>[];
    final seen = <String>{};

    for (final anchor in document.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href'] ?? '';
      if (!href.contains('/music/')) {
        continue;
      }
      if (_isCommunityActivityResult(anchor)) {
        continue;
      }

      final detailUrl = baseUrl.resolve(href).toString();
      final id = _musicIdFromUrl(detailUrl) ?? detailUrl;
      if (!seen.add(id)) {
        continue;
      }

      final parsedName = _parseTitleAndArtist(_cleanSearchText(anchor.text));
      if (parsedName.title.isEmpty) {
        continue;
      }

      results.add(
        TrackSearchResult(
          id: id,
          title: parsedName.title,
          artist: parsedName.artist,
          source: '歌曲宝',
          detailUrl: detailUrl,
          duration: _nearbyDuration(anchor),
          coverUrl: _nearbyCover(anchor, baseUrl),
        ),
      );
    }

    return results;
  }

  static TrackDetail parseTrackDetail(
    String html, {
    required Uri baseUrl,
    required TrackSearchResult fallback,
  }) {
    final document = html_parser.parse(html);
    final metadata = _extractMetadata(document);
    final appData = parseAppData(html);
    if (appData != null) {
      for (final entry in appData.entries) {
        _collectAppDataMetadata(metadata, entry.key, entry.value);
      }
    }
    final pageTitle = _firstText(document, const [
      'h1',
      '.title',
      '.song-title',
      '.music-title',
    ]);
    final parsedTitle = _parseTitleAndArtist(
      pageTitle.isNotEmpty
          ? pageTitle
          : document.head?.querySelector('title')?.text ?? '',
    );

    final title =
        metadata['mp3_title'] ??
        metadata['歌曲'] ??
        metadata['歌名'] ??
        (parsedTitle.title.isNotEmpty ? parsedTitle.title : fallback.title);
    final artist =
        metadata['mp3_author'] ??
        metadata['歌手'] ??
        metadata['演唱'] ??
        (parsedTitle.artist.isNotEmpty ? parsedTitle.artist : fallback.artist);
    final album =
        _firstMetadataValue(metadata, const [
          'mp3_album',
          'album',
          'album_name',
          'albumName',
          'album_title',
          'albumTitle',
          'albumname',
          'song_album',
          'songAlbum',
          'music_album',
          'musicAlbum',
          '专辑',
        ]) ??
        _extractAlbumFromDocument(document) ??
        fallback.album;
    final sourceUrl = baseUrl.resolve(fallback.detailUrl).toString();

    return TrackDetail(
      title: title,
      artist: artist,
      sourceUrl: sourceUrl,
      candidates: _extractAudioCandidates(html, document, baseUrl, sourceUrl),
      rawMetadata: metadata,
      lyrics: _extractLyrics(html, document, metadata),
      coverUrl:
          _extractCoverUrl(document, baseUrl, metadata) ?? fallback.coverUrl,
      album: album,
    );
  }

  static Map<String, dynamic>? parseAppData(String html) {
    final match = RegExp(
      r"window\.appData\s*=\s*JSON\.parse\('([\s\S]*?)'\);",
    ).firstMatch(html);
    if (match == null) {
      return null;
    }
    try {
      final jsonText = _decodeJsSingleQuotedBody(match.group(1)!);
      return jsonDecode(jsonText) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static void _collectAppDataMetadata(
    Map<String, String> metadata,
    String key,
    Object? value,
  ) {
    if (value is String || value is num || value is bool) {
      metadata[key] = value.toString();
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        final childKey = entry.key.toString();
        _collectAppDataMetadata(metadata, childKey, entry.value);
        _collectAppDataMetadata(metadata, '${key}_$childKey', entry.value);
      }
    }
    if (value is Iterable) {
      var index = 0;
      for (final item in value) {
        _collectAppDataMetadata(metadata, key, item);
        _collectAppDataMetadata(metadata, '${key}_$index', item);
        index += 1;
      }
    }
  }

  static List<AudioCandidate> _extractAudioCandidates(
    String html,
    dom.Document document,
    Uri baseUrl,
    String sourceUrl,
  ) {
    final candidates = <AudioCandidate>[];
    final seen = <String>{};

    void addCandidate(String rawUrl, {String? label}) {
      final cleaned = rawUrl
          .trim()
          .replaceAll(r'\/', '/')
          .replaceAll('&amp;', '&');
      if (!_looksLikeAudioUrl(cleaned)) {
        return;
      }
      final resolved = baseUrl.resolve(cleaned).toString();
      if (!seen.add(resolved)) {
        return;
      }
      final format = formatFromUrl(resolved);
      candidates.add(
        AudioCandidate(
          url: resolved,
          format: format,
          qualityLabel: label == null || label.trim().isEmpty
              ? format.toUpperCase()
              : _normalizeSpaces(label),
          headers: {'Referer': sourceUrl},
        ),
      );
    }

    const attributes = [
      'href',
      'src',
      'data-src',
      'data-url',
      'data-mp3',
      'data-play',
      'data-download',
      'data-href',
    ];

    for (final element in document.querySelectorAll('*')) {
      for (final attribute in attributes) {
        final value = element.attributes[attribute];
        if (value != null) {
          addCandidate(value, label: element.text);
        }
      }
    }

    final directUrlPattern = RegExp(
      r'''https?:\\?/\\?/[^"'\s<>)]+?\.(?:mp3|flac|wav|m4a|aac)(?:\?[^"'\s<>)]+)?''',
      caseSensitive: false,
    );
    for (final match in directUrlPattern.allMatches(html)) {
      addCandidate(match.group(0) ?? '');
    }

    final relativeUrlPattern = RegExp(
      r'''["']([^"']+\.(?:mp3|flac|wav|m4a|aac)(?:\?[^"']+)?)["']''',
      caseSensitive: false,
    );
    for (final match in relativeUrlPattern.allMatches(html)) {
      addCandidate(match.group(1) ?? '');
    }

    candidates.sort((a, b) {
      if (a.isMp3 == b.isMp3) {
        return a.format.compareTo(b.format);
      }
      return a.isMp3 ? -1 : 1;
    });
    return candidates;
  }

  static String? _extractLyrics(
    String html,
    dom.Document document,
    Map<String, String> metadata,
  ) {
    final candidates = <String>[];

    void addCandidate(String raw) {
      final lyrics = _cleanLyricsText(raw);
      if (lyrics != null) {
        candidates.add(lyrics);
      }
    }

    for (final entry in metadata.entries) {
      final key = entry.key.toLowerCase();
      if (key.contains('lrc') ||
          key.contains('lyric') ||
          entry.key.contains('歌词')) {
        addCandidate(entry.value);
      }
    }

    for (final selector in const [
      'pre',
      'textarea',
      '[id*=lrc]',
      '[class*=lrc]',
      '[id*=lyric]',
      '[class*=lyric]',
      '[id*=lyrics]',
      '[class*=lyrics]',
    ]) {
      for (final element in document.querySelectorAll(selector)) {
        addCandidate(element.text);
        addCandidate(element.innerHtml);
      }
    }

    final bodyText = document.body?.text ?? '';
    for (final marker in const ['下载歌词', '歌词下载']) {
      final index = bodyText.indexOf(marker);
      if (index >= 0) {
        addCandidate(bodyText.substring(index + marker.length));
      }
    }
    addCandidate(bodyText);
    addCandidate(html);

    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) {
      final lineCompare = _lyricsLineCount(b).compareTo(_lyricsLineCount(a));
      if (lineCompare != 0) {
        return lineCompare;
      }
      return b.length.compareTo(a.length);
    });
    return candidates.first;
  }

  static String? _cleanLyricsText(String raw) {
    final normalized = raw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(?:p|div|li)>', caseSensitive: false), '\n')
        .replaceAll(r'\r\n', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\/', '/')
        .replaceAll('&nbsp;', ' ');
    final decoded = (html_parser.parseFragment(normalized).text ?? normalized)
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    final lines = <String>[];
    final seen = <String>{};
    final pattern = RegExp(
      r'((?:\[[0-9]{1,2}:[0-9]{2}(?:[.:][0-9]{1,3})?\])+[^\r\n\[]*)',
      caseSensitive: false,
    );

    for (final match in pattern.allMatches(decoded)) {
      final line = _normalizeSpaces(match.group(1) ?? '');
      if (line.isEmpty ||
          line.contains('...') ||
          line.contains('…') ||
          !seen.add(line)) {
        continue;
      }
      lines.add(line);
    }

    if (lines.length < 2) {
      return null;
    }
    return lines.join('\n');
  }

  static int _lyricsLineCount(String lyrics) {
    return RegExp(
      r'^\[[0-9]{1,2}:[0-9]{2}',
      multiLine: true,
    ).allMatches(lyrics).length;
  }

  static String? _extractCoverUrl(
    dom.Document document,
    Uri baseUrl,
    Map<String, String> metadata,
  ) {
    for (final key in const [
      'mp3_cover',
      'mp3_pic',
      'cover',
      'cover_url',
      'pic',
      'picture',
      'image',
      'img',
      'album_cover',
    ]) {
      final value = metadata[key];
      final resolved = _resolveImageUrl(value, baseUrl);
      if (resolved != null) {
        return resolved;
      }
    }

    for (final selector in const [
      'meta[property="og:image"]',
      'meta[name="og:image"]',
      'meta[name="twitter:image"]',
      'meta[property="twitter:image"]',
    ]) {
      final value = document.querySelector(selector)?.attributes['content'];
      final resolved = _resolveImageUrl(value, baseUrl);
      if (resolved != null) {
        return resolved;
      }
    }

    for (final selector in const [
      '.cover img',
      '.album img',
      '.song img',
      '.music img',
      'img',
      '[style*="url("]',
    ]) {
      for (final image in document.querySelectorAll(selector)) {
        final resolved = _imageUrlFromElement(image, baseUrl);
        if (resolved != null) {
          return resolved;
        }
      }
    }
    return null;
  }

  static String? _imageUrlFromElement(dom.Element element, Uri baseUrl) {
    for (final attribute in const [
      'src',
      'data-src',
      'data-original',
      'data-lazy-src',
      'data-url',
      'data-cover',
      'data-img',
      'data-image',
    ]) {
      final resolved = _resolveImageUrl(element.attributes[attribute], baseUrl);
      if (resolved != null) {
        return resolved;
      }
    }

    for (final attribute in const ['srcset', 'data-srcset']) {
      final srcset = element.attributes[attribute];
      if (srcset == null || srcset.trim().isEmpty) {
        continue;
      }
      for (final entry in srcset.split(',')) {
        final candidate = entry.trim().split(RegExp(r'\s+')).first;
        final resolved = _resolveImageUrl(candidate, baseUrl);
        if (resolved != null) {
          return resolved;
        }
      }
    }

    final style = element.attributes['style'];
    if (style != null && style.toLowerCase().contains('url')) {
      final pattern = RegExp(
        r'''url\(\s*['"]?([^'")]+)['"]?\s*\)''',
        caseSensitive: false,
      );
      for (final match in pattern.allMatches(style)) {
        final resolved = _resolveImageUrl(match.group(1), baseUrl);
        if (resolved != null) {
          return resolved;
        }
      }
    }
    return null;
  }

  static String? _resolveImageUrl(String? rawUrl, Uri baseUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      return null;
    }
    final cleaned = rawUrl
        .trim()
        .replaceAll(r'\/', '/')
        .replaceAll('&amp;', '&');
    if (cleaned.startsWith('data:')) {
      return null;
    }
    final resolved = baseUrl.resolve(cleaned).toString();
    final lower =
        Uri.tryParse(resolved)?.path.toLowerCase() ?? resolved.toLowerCase();
    if (RegExp(
      r'(?:blank|placeholder|loading|sprite|favicon|logo)',
    ).hasMatch(lower)) {
      return null;
    }
    if (!RegExp(r'\.(?:jpe?g|png|webp|gif)$').hasMatch(lower) &&
        !RegExp(
          r'(?:cover|album|pic|photo|image|img|upload|avatar)',
        ).hasMatch(lower)) {
      return null;
    }
    return resolved;
  }

  static Map<String, String> _extractMetadata(dom.Document document) {
    final metadata = <String, String>{};
    final text = document.body?.text ?? '';
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map(_normalizeSpaces)
        .where((line) => line.isNotEmpty);

    for (final line in lines) {
      final match = RegExp(
        r'^(歌名|歌曲|歌手|演唱|专辑|唱片|音质|大小)[:：]\s*(.+)$',
      ).firstMatch(line);
      if (match != null) {
        metadata[match.group(1)!] = match.group(2)!.trim();
      }
    }
    return metadata;
  }

  static String? _firstMetadataValue(
    Map<String, String> metadata,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = metadata[key]?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    final normalizedKeys = {for (final key in keys) key.toLowerCase()};
    for (final entry in metadata.entries) {
      final key = entry.key.trim().toLowerCase();
      final value = entry.value.trim();
      if (value.isNotEmpty && normalizedKeys.contains(key)) {
        return value;
      }
    }
    return null;
  }

  static String? _extractAlbumFromDocument(dom.Document document) {
    for (final selector in const [
      '[itemprop="inAlbum"]',
      '[itemprop="album"]',
      '.album',
      '.album-name',
      '.song-album',
    ]) {
      final text = _normalizeSpaces(
        document.querySelector(selector)?.text ?? '',
      );
      if (text.isNotEmpty) {
        return text;
      }
    }
    for (final selector in const [
      'meta[property="music:album"]',
      'meta[name="music:album"]',
      'meta[property="og:music:album"]',
      'meta[name="album"]',
    ]) {
      final content = document.querySelector(selector)?.attributes['content'];
      final text = _normalizeSpaces(content ?? '');
      if (text.isNotEmpty) {
        return text;
      }
    }
    return null;
  }

  static String _firstText(dom.Document document, List<String> selectors) {
    for (final selector in selectors) {
      final text = _normalizeSpaces(
        document.querySelector(selector)?.text ?? '',
      );
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }

  static String? _nearbyDuration(dom.Element anchor) {
    final containerText = _normalizeSpaces(anchor.parent?.text ?? '');
    final match = RegExp(r'\b\d{1,2}:\d{2}\b').firstMatch(containerText);
    return match?.group(0);
  }

  static String? _nearbyCover(dom.Element anchor, Uri baseUrl) {
    dom.Element? cursor = anchor;
    for (var depth = 0; depth < 3 && cursor != null; depth += 1) {
      final ownImage = _imageUrlFromElement(cursor, baseUrl);
      if (ownImage != null) {
        return ownImage;
      }

      for (final element in cursor.querySelectorAll(
        'img, [data-src], [data-original], [data-lazy-src], '
        '[data-cover], [data-img], [data-image], [srcset], '
        '[data-srcset], [style*="url("]',
      )) {
        final resolved = _imageUrlFromElement(element, baseUrl);
        if (resolved != null) {
          return resolved;
        }
      }
      cursor = cursor.parent;
    }
    return null;
  }

  static ({String title, String artist}) _parseTitleAndArtist(String rawText) {
    final cleaned = _normalizeSpaces(
      rawText
          .replaceAll(RegExp(r'\s*\d{4}-\d{2}-\d{2}$'), '')
          .replaceAll(RegExp(r'\s*-\s*歌曲宝.*$'), '')
          .replaceFirst(RegExp(r'^\d+\s+'), ''),
    );
    if (cleaned.isEmpty) {
      return (title: '', artist: '');
    }

    final parts = cleaned.split(RegExp(r'\s+-\s+'));
    if (parts.length >= 2) {
      final artist = parts.removeLast().trim();
      return (title: parts.join(' - ').trim(), artist: artist);
    }
    return (title: cleaned, artist: '');
  }

  static String _cleanSearchText(String text) {
    return _normalizeSpaces(text.replaceFirst(RegExp(r'^\d+\s*'), ''));
  }

  static bool _isCommunityActivityResult(dom.Element anchor) {
    final text = _normalizeSpaces(anchor.text);
    if (_containsCommunityActivityPrefix(text)) {
      return true;
    }

    final parent = anchor.parent;
    if (parent == null) {
      return false;
    }
    final parentMusicLinks = parent
        .querySelectorAll('a[href]')
        .where(
          (element) => (element.attributes['href'] ?? '').contains('/music/'),
        )
        .length;
    if (parentMusicLinks != 1) {
      return false;
    }
    return _containsCommunityActivityPrefix(_normalizeSpaces(parent.text));
  }

  static bool _containsCommunityActivityPrefix(String text) {
    return text.contains('网友刚刚下载了') || text.contains('网友刚刚搜索了');
  }

  static bool _looksLikeAudioUrl(String value) {
    final lower = value.toLowerCase();
    return RegExp(r'\.(mp3|flac|wav|m4a|aac)(?:[?#].*)?$').hasMatch(lower);
  }

  static String formatFromUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final match = RegExp(
      r'\.([a-z0-9]+)$',
      caseSensitive: false,
    ).firstMatch(path);
    return (match?.group(1) ?? 'mp3').toLowerCase();
  }

  static String _decodeJsSingleQuotedBody(String raw) {
    final buffer = StringBuffer();
    for (var index = 0; index < raw.length; index += 1) {
      final char = raw[index];
      if (char != '\\') {
        buffer.write(char);
        continue;
      }

      index += 1;
      if (index >= raw.length) {
        buffer.write('\\');
        break;
      }
      final next = raw[index];
      if (next == 'u' &&
          index + 4 < raw.length &&
          RegExp(
            r'^[0-9a-fA-F]{4}$',
          ).hasMatch(raw.substring(index + 1, index + 5))) {
        buffer.writeCharCode(
          int.parse(raw.substring(index + 1, index + 5), radix: 16),
        );
        index += 4;
      } else {
        buffer.write(switch (next) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          'b' => '\b',
          'f' => '\f',
          'v' => '\v',
          '0' => '\x00',
          _ => next,
        });
      }
    }
    return buffer.toString();
  }

  static String? _musicIdFromUrl(String url) {
    return RegExp(r'/music/([^/?#]+)').firstMatch(url)?.group(1);
  }

  static String _normalizeSpaces(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
