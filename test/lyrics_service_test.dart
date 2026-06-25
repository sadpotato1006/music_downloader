import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/lyrics_service.dart';

void main() {
  test('prefers exact synced LRCLIB lyrics match', () async {
    final dio = Dio(BaseOptions(responseType: ResponseType.json))
      ..httpClientAdapter = _LyricsAdapter();
    final service = LyricsService(
      dio: dio,
      baseUri: Uri.parse('https://lyrics.example.test/'),
    );

    final lyrics = await service.findLyrics(
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );

    expect(lyrics, '[00:01.00]故事的小黄花');
  });
}

class _LyricsAdapter implements HttpClientAdapter {
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
      jsonEncode([
        {
          'trackName': '晴天 (Live)',
          'artistName': '其他歌手',
          'duration': 300,
          'plainLyrics': '错误结果',
        },
        {
          'trackName': '晴天',
          'artistName': '周杰伦',
          'duration': 269,
          'syncedLyrics': '[00:01.00]故事的小黄花',
        },
      ]),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
