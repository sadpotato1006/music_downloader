import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/album_metadata_service.dart';

void main() {
  test('uses Apple as the default source and caches the result', () async {
    final adapter = _AppleAlbumAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final first = await service.findBestAlbum(
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );
    final second = await service.findBestAlbum(
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );

    expect(first?.album, '叶惠美');
    expect(second?.album, '叶惠美');
    expect(adapter.appleCalls, 1);
    expect(adapter.musicBrainzCalls, 0);
  });

  test('rejects an Apple result with a mismatched duration', () async {
    final adapter = _AppleAlbumAdapter(trackTimeMillis: 300000);
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final match = await service.findBestAlbum(
      title: '晴天',
      artist: '周杰伦',
      duration: const Duration(minutes: 4, seconds: 29),
    );

    expect(match, isNull);
    expect(adapter.appleCalls, 1);
    expect(adapter.musicBrainzCalls, greaterThan(0));
  });

  test('prefers an official artist album over compilation releases', () async {
    final dio = Dio()..httpClientAdapter = _FakeMusicBrainzAdapter();
    final service = AlbumMetadataService(
      dio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      requestGap: Duration.zero,
    );

    final match = await service.findBestAlbum(
      title: 'Night Song',
      artist: 'Example Artist',
      lyrics: '[00:00.00]Night Song - Example Artist',
    );

    expect(match, isNotNull);
    expect(match!.album, 'Original Album');
  });

  test('returns null when the recording match is too weak', () async {
    final dio = Dio()..httpClientAdapter = const _WeakMatchAdapter();
    final service = AlbumMetadataService(
      dio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      requestGap: Duration.zero,
    );

    final match = await service.findBestAlbum(
      title: 'Night Song',
      artist: 'Example Artist',
    );

    expect(match, isNull);
  });

  test(
    'returns low confidence candidates without auto accepting them',
    () async {
      final dio = Dio()..httpClientAdapter = const _LowConfidenceAdapter();
      final service = AlbumMetadataService(
        dio: dio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        requestGap: Duration.zero,
      );

      final candidates = await service.findAlbumCandidates(
        title: 'Night Song',
        artist: 'Example Artist',
      );
      final match = await service.findBestAlbum(
        title: 'Night Song',
        artist: 'Example Artist',
      );

      expect(match, isNull);
      expect(candidates, hasLength(1));
      expect(candidates.single.album, 'Unverified Broadcast');
      expect(
        candidates.single.score,
        lessThan(AlbumMetadataService.highConfidenceScore),
      );
    },
  );
}

class _AppleAlbumAdapter implements HttpClientAdapter {
  _AppleAlbumAdapter({this.trackTimeMillis = 269000});

  final int trackTimeMillis;
  int appleCalls = 0;
  int musicBrainzCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      appleCalls += 1;
      expect(options.uri.queryParameters['country'], 'CN');
      expect(options.uri.queryParameters['entity'], 'song');
      return _javascriptResponse({
        'resultCount': 1,
        'results': [
          {
            'wrapperType': 'track',
            'kind': 'song',
            'trackId': 1850000001,
            'collectionId': 1850000000,
            'trackName': '晴天',
            'artistName': '周杰伦',
            'collectionName': '叶惠美',
            'trackTimeMillis': trackTimeMillis,
            'releaseDate': '2003-07-31T12:00:00Z',
          },
        ],
      });
    }
    musicBrainzCalls += 1;
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _FakeMusicBrainzAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/ws/2/recording') {
      return _jsonResponse({
        'recordings': [
          {
            'id': 'recording-1',
            'score': '100',
            'title': 'Night Song',
            'artist-credit': [
              {'name': 'Example Artist'},
            ],
            'releases': [
              {
                'id': 'release-compilation',
                'title': 'Top Hits Collection',
                'status': 'Official',
                'date': '2024-01-01',
                'artist-credit': [
                  {'name': 'Various Artists'},
                ],
                'release-group': {
                  'id': 'release-group-compilation',
                  'primary-type': 'Album',
                  'secondary-types': ['Compilation'],
                },
              },
              {
                'id': 'release-original',
                'title': 'Original Album',
                'status': 'Official',
                'date': '2020-01-01',
                'artist-credit': [
                  {'name': 'Example Artist'},
                ],
                'release-group': {
                  'id': 'release-group-original',
                  'primary-type': 'Album',
                  'secondary-types': [],
                },
              },
            ],
          },
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _WeakMatchAdapter implements HttpClientAdapter {
  const _WeakMatchAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return _jsonResponse({
      'recordings': [
        {
          'id': 'recording-weak',
          'score': '100',
          'title': 'Completely Different Song',
          'artist-credit': [
            {'name': 'Other Artist'},
          ],
          'releases': [
            {
              'id': 'release-weak',
              'title': 'Other Album',
              'status': 'Official',
              'date': '2020-01-01',
              'artist-credit': [
                {'name': 'Other Artist'},
              ],
              'release-group': {
                'id': 'release-group-weak',
                'primary-type': 'Album',
                'secondary-types': [],
              },
            },
          ],
        },
      ],
    });
  }

  @override
  void close({bool force = false}) {}
}

class _LowConfidenceAdapter implements HttpClientAdapter {
  const _LowConfidenceAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return _jsonResponse({
      'recordings': [
        {
          'id': 'recording-low',
          'score': '0',
          'title': 'Night Song',
          'artist-credit': [
            {'name': 'Sample Singer'},
          ],
          'releases': [
            {
              'id': 'release-low',
              'title': 'Unverified Broadcast',
              'status': 'Bootleg',
              'date': '2021-01-01',
              'artist-credit': [
                {'name': 'Sample Singer'},
              ],
              'release-group': {
                'id': 'release-group-low',
                'primary-type': 'Broadcast',
                'secondary-types': [],
              },
            },
          ],
        },
      ],
    });
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Map<String, Object?> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );
}

ResponseBody _javascriptResponse(Map<String, Object?> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: ['text/javascript; charset=utf-8'],
    },
  );
}
