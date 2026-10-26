import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/xiagebao_source.dart';

final _base = Uri.parse('https://www.xiagebao.com/');
const _track = TrackSearchResult(
  id: 'xgb:4188',
  title: '测试歌曲',
  artist: '测试歌手',
  source: '下歌宝',
  detailUrl: 'https://www.xiagebao.com/music/4188',
);
const _searchHtml = '''
<h1>测试歌手</h1><div class="result-list">
 <div class="song-item"><a href="/music/4188"><span class="song-title">测试歌曲</span><span class="artist">测试歌手</span></a><a href="/music/4188">播放&下载</a></div>
 <a href="/music/5000">另一首 - 另一位歌手</a>
 <a href="/music/6000">网友刚刚下载了 推荐 - 歌手</a>
 <a href="https://unrelated.test/music/999">外站 - 歌手</a>
</div>''';
const _detailHtml = '''
<h1>测试歌曲</h1><div class="song-artist">测试歌手</div>
<meta property="og:image" content="/covers/4188.jpg">
<audio controls><source src="https://cdn.example.test/song.mp3?token=fresh" type="audio/mpeg"></audio>
<a href="/dp/aHR0cHM6Ly9wYW4ucXVhcmsuY24=">下载歌曲</a>
<pre id="lyrics">[00:01.00]测试歌词</pre>''';

void main() {
  test(
    'search parses identities, title and artist and ignores activity and external links',
    () {
      final tracks = XiagebaoParser.parseSearchResults(
        _searchHtml,
        baseUri: _base,
      );
      expect(tracks, hasLength(2));
      expect(tracks.first.id, 'xgb:4188');
      expect(tracks.first.source, '下歌宝');
      expect(tracks.first.title, '测试歌曲');
      expect(tracks.first.artist, '测试歌手');
      expect(tracks.last.artist, '另一位歌手');
    },
  );
  test(
    'detail resolves public audio and artwork without treating a net-disk link as audio',
    () {
      final detail = XiagebaoParser.parseTrackDetail(
        _detailHtml,
        baseUri: _base,
        fallback: _track,
      );
      expect(detail.title, '测试歌曲');
      expect(detail.artist, '测试歌手');
      expect(
        detail.candidates.single.url,
        'https://cdn.example.test/song.mp3?token=fresh',
      );
      expect(detail.candidates.single.headers['Referer'], _track.detailUrl);
      expect(detail.coverUrl, 'https://www.xiagebao.com/covers/4188.jpg');
    },
  );
  test('audio element with an extensionless endpoint is supported', () {
    final detail = XiagebaoParser.parseTrackDetail(
      '<h1>测试</h1><audio src="/media/play?id=4188"></audio>',
      baseUri: _base,
      fallback: _track,
    );
    expect(
      detail.candidates.single.url,
      'https://www.xiagebao.com/media/play?id=4188',
    );
  });
  for (final status in [200, 403]) {
    test('verification HTML produces an explicit error (HTTP $status)', () async {
      final dio = Dio()
        ..httpClientAdapter = _SiteAdapter(
          status: status,
          html:
              '<title>Just a moment...</title><script src="/cdn-cgi/challenge-platform/test"></script>',
        );
      final source = XiagebaoSource(dio: dio);
      addTearDown(source.close);
      await expectLater(
        source.search('测试'),
        throwsA(
          isA<MusicSourceException>().having(
            (error) => error.message,
            'message',
            contains('验证'),
          ),
        ),
      );
    });
  }
  test(
    'source encodes search, loads detail and exposes play and download candidates',
    () async {
      final adapter = _SiteAdapter();
      final source = XiagebaoSource(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(source.close);
      final tracks = await source.search('测试 歌手', page: 2);
      expect(adapter.requests.single.uri.pathSegments, ['s', '测试 歌手']);
      expect(adapter.requests.single.uri.queryParameters['page'], '2');
      final detail = await source.loadDetail(tracks.first);
      expect(
        (await source.resolveCandidates(detail)).single.url,
        contains('song.mp3'),
      );
      expect(
        (await source.resolveDownloadCandidates(detail)).single.url,
        contains('song.mp3'),
      );
    },
  );
  test(
    'net-disk-only pages report that no public audio is available',
    () async {
      final source = XiagebaoSource();
      addTearDown(source.close);
      final detail = XiagebaoParser.parseTrackDetail(
        '<h1>测试</h1><a href="https://pan.quark.cn/s/example.mp3">下载歌曲</a>',
        baseUri: _base,
        fallback: _track,
      );
      expect(detail.candidates, isEmpty);
      await expectLater(
        source.resolveDownloadCandidates(detail),
        throwsA(
          isA<MusicSourceException>().having(
            (error) => error.message,
            'message',
            contains('网盘'),
          ),
        ),
      );
    },
  );
  test('foreign detail URLs are rejected before making a request', () async {
    final adapter = _SiteAdapter();
    final source = XiagebaoSource(dio: Dio()..httpClientAdapter = adapter);
    addTearDown(source.close);
    await expectLater(
      source.loadDetail(
        _track.copyWith(detailUrl: 'https://unrelated.test/music/4188'),
      ),
      throwsA(isA<MusicSourceException>()),
    );
    expect(adapter.requests, isEmpty);
  });
}

class _SiteAdapter implements HttpClientAdapter {
  _SiteAdapter({this.status = 200, this.html});
  final int status;
  final String? html;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      html ?? (options.uri.path.startsWith('/s/') ? _searchHtml : _detailHtml),
      status,
      headers: {
        'content-type': ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
