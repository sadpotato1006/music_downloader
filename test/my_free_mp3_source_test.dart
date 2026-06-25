import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/my_free_mp3_source.dart';

void main() {
  final siteUri = Uri.parse('https://myfreemp3.ink/');

  test('parses public search tracks with stream and artwork', () {
    const html = '''
      <ul class=playlist>
        <li class=track
            data-owner-id=64874624
            data-track-id=456240367
            data-download=https://cdn.example.test/song/index.m3u8?siren=1>
          <button class=play-toggle
              style=background-image:url('https://img.example.test/cover.jpg');></button>
          <div class=track-artist><span>周杰伦</span></div>
          <div class=track-title>晴天</div>
          <span class=track-duration>4:29</span>
        </li>
      </ul>
    ''';

    final results = MyFreeMp3Parser.parseSearchResults(html, siteUri: siteUri);

    expect(results, hasLength(1));
    expect(results.single.id, 'mfm:64874624:456240367');
    expect(results.single.title, '晴天');
    expect(results.single.artist, '周杰伦');
    expect(results.single.source, 'MY FREE MP3');
    expect(results.single.detailUrl, contains('index.m3u8'));
    expect(results.single.coverUrl, 'https://img.example.test/cover.jpg');
  });

  test(
    'signs search requests and prepares generated mp3 for playback and download',
    () async {
      final adapter = _FakeMyFreeMp3Adapter();
      final dio = Dio(
        BaseOptions(
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      )..httpClientAdapter = adapter;
      final source = MyFreeMp3Source(dio: dio, siteUri: siteUri);

      final results = await source.search('晴天');
      final detail = await source.loadDetail(results.single);
      final downloads = await source.resolveDownloadCandidates(detail);
      final preparedDownload = await source.prepareDownloadCandidate(
        downloads.single,
      );
      final playback = await source.resolveCandidates(detail);

      expect(adapter.searchHeaders?['X-Api-Key-Id'], 'test-key');
      expect(adapter.searchHeaders?['X-Api-Ts'], isNotEmpty);
      expect(adapter.searchHeaders?['X-Api-Sig'], hasLength(64));
      expect(adapter.searchPath, '/search/%E6%99%B4%E5%A4%A9');
      final timestamp = adapter.searchHeaders!['X-Api-Ts'].toString();
      final expectedSignature = Hmac(
        sha256,
        utf8.encode('test-signing-key'),
      ).convert(utf8.encode('$timestamp\nGET\n/search/晴天\n')).toString();
      expect(adapter.searchHeaders?['X-Api-Sig'], expectedSignature);
      expect(downloads.single.format, 'mp3');
      expect(downloads.single.url, startsWith('myfreemp3-job://'));
      expect(preparedDownload.format, 'mp3');
      expect(
        preparedDownload.url,
        'https://api.myfreemp3.ink/download/job/file/test-job',
      );
      expect(playback.single.url, preparedDownload.url);
      expect(adapter.startCalls, 1);
    },
  );
}

class _FakeMyFreeMp3Adapter implements HttpClientAdapter {
  Map<String, dynamic>? searchHeaders;
  String? searchPath;
  int startCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/api/signing/bootstrap') {
      return ResponseBody.fromString(
        '{\u0022key_id\u0022:\u0022test-key\u0022,'
        '\u0022signing_key\u0022:\u0022test-signing-key\u0022,'
        '\u0022expires_at\u0022:4102444800,'
        '\u0022server_time\u0022:1782374879}',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
        },
      );
    }
    if (options.uri.path.startsWith('/search/')) {
      searchHeaders = Map<String, dynamic>.from(options.headers);
      searchPath = options.uri.path;
      return ResponseBody.fromString(
        '''
          <li class=track
              data-owner-id=64874624
              data-track-id=456240367
              data-download=https://cdn.example.test/song/index.m3u8?siren=1>
            <button class=play-toggle></button>
            <div class=track-artist>周杰伦</div>
            <div class=track-title>晴天</div>
          </li>
        ''',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    if (options.uri.path == '/download/job/start/64874624/456240367') {
      startCalls += 1;
      return ResponseBody.fromString(
        '{\u0022job_id\u0022:\u0022test-job\u0022,'
        '\u0022status\u0022:\u0022queued\u0022}',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
        },
      );
    }
    if (options.uri.path == '/download/job/progress/test-job') {
      return ResponseBody.fromString(
        '{\u0022job_id\u0022:\u0022test-job\u0022,'
        '\u0022status\u0022:\u0022done\u0022,'
        '\u0022progress\u0022:100}',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
        },
      );
    }
    return ResponseBody.fromString('', 404);
  }

  @override
  void close({bool force = false}) {}
}
