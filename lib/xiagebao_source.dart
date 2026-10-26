import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'app_info.dart';
import 'gequbao_source.dart';
import 'models.dart';
import 'music_source.dart';

/// Reads the site's public search/detail HTML. Net-disk shares and verification
/// pages are never treated as playable audio or handed to the downloader.
class XiagebaoSource implements MusicSource, DownloadMusicSource {
  XiagebaoSource({Dio? dio, Uri? baseUri})
    : _baseUri = baseUri ?? Uri.parse('https://www.xiagebao.com/'),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 18),
            ),
          );

  final Dio _dio;
  final Uri _baseUri;
  @override
  String get name => '下歌宝';

  Future<String> _get(Uri uri) async {
    try {
      final response = await _dio.getUri<String>(
        uri,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null,
          headers: {
            'User-Agent': appUserAgent,
            'Referer': _baseUri.toString(),
            'Accept': 'text/html',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      final html = response.data ?? '';
      if (status == 403 || XiagebaoParser.isVerificationPage(html)) {
        throw const MusicSourceException(
          '下歌宝要求浏览器验证（HTTP 403 或验证页面），请在浏览器确认网站可访问后重试，或切换歌曲源。',
        );
      }
      if (status < 200 || status >= 300) {
        throw MusicSourceException('下歌宝返回 HTTP $status，请稍后重试。');
      }
      return html;
    } on MusicSourceException {
      rethrow;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw MusicSourceException(
        status == null ? '连接下歌宝失败，请检查网络后重试。' : '下歌宝返回 HTTP $status，请稍后重试。',
      );
    }
  }

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final uri = _baseUri
        .resolve('s/${Uri.encodeComponent(query)}')
        .replace(queryParameters: page > 1 ? {'page': '$page'} : null);
    return XiagebaoParser.parseSearchResults(
      await _get(uri),
      baseUri: _baseUri,
    );
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    final uri = _baseUri.resolve(result.detailUrl);
    if (uri.origin != _baseUri.origin ||
        !RegExp(r'^/music/\d+/?$').hasMatch(uri.path)) {
      throw const MusicSourceException('下歌宝歌曲地址无效，请重新搜索。');
    }
    return XiagebaoParser.parseTrackDetail(
      await _get(uri),
      baseUri: _baseUri,
      fallback: result,
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    if (detail.candidates.isEmpty) {
      throw const MusicSourceException(
        '下歌宝此页面未提供可直接访问的公开音频，可能只有网盘链接或需要网站验证，请选择其他歌曲或歌曲源。',
      );
    }
    return detail.candidates;
  }

  @override
  Future<List<AudioCandidate>> resolveDownloadCandidates(TrackDetail detail) =>
      resolveCandidates(detail);

  void close() => _dio.close(force: true);
}

class XiagebaoParser {
  static bool isVerificationPage(String html) =>
      html.contains('/cdn-cgi/challenge-platform/') ||
      RegExp(
        r'<title[^>]*>\s*(?:Just a moment|请稍候|安全验证)',
        caseSensitive: false,
      ).hasMatch(html);

  static List<TrackSearchResult> parseSearchResults(
    String html, {
    required Uri baseUri,
  }) {
    if (isVerificationPage(html)) {
      throw const MusicSourceException('下歌宝要求浏览器验证，请稍后重试或切换歌曲源。');
    }
    final document = html_parser.parse(html);
    final results = <TrackSearchResult>[];
    final seen = <String>{};
    final fallback = {
      for (final track in GequbaoParser.parseSearchResults(
        html,
        baseUrl: baseUri,
      ))
        track.id: track,
    };
    for (final anchor in document.querySelectorAll('a[href]')) {
      final uri = baseUri.resolve(anchor.attributes['href'] ?? '');
      final match = RegExp(r'^/music/(\d+)/?$').firstMatch(uri.path);
      if (uri.origin != baseUri.origin || match == null) continue;
      if (_text(anchor).contains('网友刚刚') ||
          RegExp(r'^(播放|下载|播放&下载)$').hasMatch(_text(anchor))) {
        continue;
      }
      final id = match[1]!;
      final parsed = fallback[id];
      final row = _row(anchor);
      final title =
          _firstText(anchor, [
            '.song-title',
            '.music-title',
            '.track-title',
            '[data-title]',
          ]) ??
          _firstText(row, ['.song-title', '.music-title', '.track-title']) ??
          parsed?.title ??
          '';
      final artist =
          _firstText(anchor, [
            '.artist',
            '.singer',
            '.song-artist',
            '.music-artist',
            '.text-muted',
          ]) ??
          _firstText(row, [
            '.artist',
            '.singer',
            '.song-artist',
            '.music-artist',
          ]) ??
          parsed?.artist ??
          '';
      if (title.isEmpty || !seen.add(id)) continue;
      results.add(
        TrackSearchResult(
          id: 'xgb:$id',
          title: title,
          artist: artist,
          source: '下歌宝',
          detailUrl: uri.toString(),
          duration: parsed?.duration,
          coverUrl: parsed?.coverUrl,
        ),
      );
    }
    return results;
  }

  static TrackDetail parseTrackDetail(
    String html, {
    required Uri baseUri,
    required TrackSearchResult fallback,
  }) {
    if (isVerificationPage(html)) {
      throw const MusicSourceException('下歌宝要求浏览器验证，请稍后重试或切换歌曲源。');
    }
    final parsed = GequbaoParser.parseTrackDetail(
      html,
      baseUrl: baseUri,
      fallback: fallback,
    );
    final document = html_parser.parse(html);
    final title = _firstText(document.documentElement!, ['h1']) ?? parsed.title;
    final artist =
        _firstText(document.documentElement!, [
          '.song-artist',
          '.music-artist',
          '.artist',
          '[itemprop="byArtist"]',
        ]) ??
        parsed.artist;
    final candidates = <AudioCandidate>[];
    final seen = <String>{};
    void add(String raw, {bool explicitAudio = false}) {
      final uri = baseUri.resolve(raw);
      if (!const {'https', 'http'}.contains(uri.scheme) ||
          uri.userInfo.isNotEmpty) {
        return;
      }
      if (const {
            'pan.quark.cn',
            'pan.baidu.com',
            'www.alipan.com',
            'www.aliyundrive.com',
          }.contains(uri.host) ||
          uri.path.startsWith('/dp/')) {
        return;
      }
      if (!explicitAudio &&
          !RegExp(
            r'\.(mp3|m4a|aac|flac|wav|ogg)$',
            caseSensitive: false,
          ).hasMatch(uri.path)) {
        return;
      }
      if (seen.add(uri.toString())) {
        candidates.add(
          AudioCandidate(
            url: uri.toString(),
            format: GequbaoParser.formatFromUrl(uri.toString()),
            headers: {
              'Referer': fallback.detailUrl,
              'User-Agent': appUserAgent,
            },
          ),
        );
      }
    }

    for (final element in document.querySelectorAll(
      'audio[src], audio source[src]',
    )) {
      final url = element.attributes['src']?.trim() ?? '';
      if (url.isNotEmpty) add(url, explicitAudio: true);
    }
    for (final candidate in parsed.candidates) {
      add(candidate.url);
    }
    return TrackDetail(
      title: title,
      artist: artist,
      sourceUrl: fallback.detailUrl,
      candidates: candidates,
      rawMetadata: parsed.rawMetadata,
      lyrics: parsed.lyrics,
      coverUrl: parsed.coverUrl,
      album: parsed.album,
    );
  }

  static dom.Element _row(dom.Element anchor) {
    var row = anchor;
    for (var depth = 0; depth < 3; depth++) {
      final parent = row.parent;
      if (parent == null || const {'body', 'html'}.contains(parent.localName)) {
        break;
      }
      final songIds = parent
          .querySelectorAll('a[href]')
          .map(
            (link) => RegExp(
              r'/music/(\d+)',
            ).firstMatch(link.attributes['href'] ?? '')?.group(1),
          )
          .whereType<String>()
          .toSet();
      if (songIds.length > 1) break;
      row = parent;
      if (const {'tr', 'li'}.contains(row.localName) ||
          row.classes.any(
            (value) => value.contains('item') || value.contains('row'),
          )) {
        break;
      }
    }
    return row;
  }

  static String _text(dom.Element element) =>
      element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  static String? _firstText(dom.Element element, List<String> selectors) {
    for (final selector in selectors) {
      final child = element.querySelector(selector);
      final value = child == null ? '' : _text(child);
      if (value.isNotEmpty) return value;
    }
    return null;
  }
}
