import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/lyrics_service.dart';

void main() {
  test('prefers exact synced LRCLIB lyrics match', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.json))
      ..httpClientAdapter = _LyricsAdapter([
        {
          'trackName': '晴天',
          'artistName': '周杰伦',
          'albumName': '错误版本',
          'duration': 266.0,
          'syncedLyrics': _wrongTimedLyrics,
        },
        {
          'trackName': '晴天',
          'artistName': '周杰伦',
          'albumName': '叶惠美',
          'duration': 269.1,
          'syncedLyrics': _correctTimedLyrics,
        },
      ]);
    final service = LyricsService(
      dio: dio,
      baseUri: Uri.parse('https://lyrics.example.test/'),
    );

    final lyrics = await service.findLyrics(
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );

    expect(lyrics, _correctTimedLyrics);
  });

  test('does not fall back to untimed plain lyrics', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.json))
      ..httpClientAdapter = _LyricsAdapter([
        {
          'trackName': '晴天',
          'artistName': '周杰伦',
          'duration': 269,
          'plainLyrics': '故事的小黄花\n从出生那年就飘着',
        },
      ]);
    final service = LyricsService(
      dio: dio,
      baseUri: Uri.parse('https://lyrics.example.test/'),
    );

    final lyrics = await service.findLyrics(
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );

    expect(lyrics, isNull);
  });

  test('rejects synchronized lyrics from a mismatched recording', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.json))
      ..httpClientAdapter = _LyricsAdapter([
        {
          'trackName': '晴天',
          'artistName': '其他歌手',
          'duration': 269,
          'syncedLyrics': _wrongTimedLyrics,
        },
        {
          'trackName': '晴天',
          'artistName': '周杰伦',
          'duration': 249,
          'syncedLyrics': _wrongTimedLyrics,
        },
      ]);
    final service = LyricsService(
      dio: dio,
      baseUri: Uri.parse('https://lyrics.example.test/'),
    );

    final lyrics = await service.findLyrics(
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );

    expect(lyrics, isNull);
  });
}

const _correctTimedLyrics =
    '[00:29.36]故事的小黄花\n'
    '[00:33.20]从出生那年就飘着\n'
    '[00:37.50]童年的荡秋千';
const _wrongTimedLyrics =
    '[00:01.00]错误歌词一\n'
    '[00:04.00]错误歌词二\n'
    '[00:07.00]错误歌词三';

class _LyricsAdapter implements HttpClientAdapter {
  _LyricsAdapter(this.items);

  final List<Map<String, dynamic>> items;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.uri.path, '/api/search');
    expect(options.uri.queryParameters['track_name'], '晴天');
    expect(options.uri.queryParameters['artist_name'], '周杰伦');
    return ResponseBody.fromString(
      jsonEncode(items),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
