import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/album_metadata_service.dart';

void main() {
  test(
    'score selection ignores blank albums and accepts close lower scores',
    () {
      const lower = AlbumMetadataMatch(
        album: 'Lower',
        recordingTitle: 'Song',
        recordingArtist: '',
        score: 70,
      );
      const best = AlbumMetadataMatch(
        album: 'Best',
        recordingTitle: 'Song',
        recordingArtist: '',
        score: 72,
      );
      const blank = AlbumMetadataMatch(
        album: '  ',
        recordingTitle: 'Song',
        recordingArtist: '',
        score: 100,
      );
      expect(
        AlbumMetadataService.selectHighestScoreMatch([lower, blank, best]),
        same(best),
      );
      expect(AlbumMetadataService.selectHighestScoreMatch([blank]), isNull);
      expect(AlbumMetadataService.selectHighestScoreMatch([]), isNull);
    },
  );

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

  test(
    'duration-sensitive Apple cache keys keep millisecond boundaries',
    () async {
      final adapter = _AppleAlbumAdapter(trackTimeMillis: 180500);
      final dio = Dio()..httpClientAdapter = adapter;
      final service = AlbumMetadataService(
        dio: dio,
        appleDio: dio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        appleBaseUri: Uri.parse('https://itunes.test/'),
        requestGap: Duration.zero,
        appleRequestGap: Duration.zero,
      );

      final accepted = await service.findAlbumCandidates(
        title: '晴天',
        artist: '周杰伦',
        duration: const Duration(milliseconds: 172501),
      );
      final rejected = await service.findAlbumCandidates(
        title: '晴天',
        artist: '周杰伦',
        duration: const Duration(milliseconds: 172499),
      );

      expect(accepted, isNotEmpty);
      expect(rejected, isEmpty);
      expect(adapter.appleCalls, 2);
    },
  );

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
      duration: const Duration(minutes: 3),
    );

    expect(match, isNotNull);
    expect(match!.album, 'Original Album');
    expect(match.score, lessThan(100));
  });

  test('does not treat a Live version as the original recording', () async {
    final dio = Dio()..httpClientAdapter = const _LiveVersionAdapter();
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final candidates = await service.findAlbumCandidates(
      title: 'Night Song',
      artist: 'Example Artist',
      duration: const Duration(minutes: 3),
    );

    expect(candidates, isEmpty);
  });

  test('does not treat Japanese live versions as the original', () async {
    for (final halfWidth in [false, true]) {
      final dio = Dio()
        ..httpClientAdapter = _JapaneseLiveVersionAdapter(halfWidth: halfWidth);
      final service = AlbumMetadataService(
        dio: dio,
        appleDio: dio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        appleBaseUri: Uri.parse('https://itunes.test/'),
        requestGap: Duration.zero,
        appleRequestGap: Duration.zero,
      );

      final candidates = await service.findAlbumCandidates(
        title: 'Beautiful Endless Song',
        artist: 'Example Artist',
        duration: const Duration(minutes: 3),
      );

      expect(candidates, isEmpty);
    }
  });

  test('does not treat a bare Chinese sped-up label as the original', () async {
    final dio = Dio()
      ..httpClientAdapter = const _LocalizedTitleAdapter(
        title: 'Beautiful Endless Song (加速)',
      );
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final candidates = await service.findAlbumCandidates(
      title: 'Beautiful Endless Song',
      artist: 'Example Artist',
      duration: const Duration(minutes: 3),
    );

    expect(candidates, isEmpty);
  });

  test('normalizes the Japanese middle dot in short titles', () async {
    final dio = Dio()
      ..httpClientAdapter = const _LocalizedTitleAdapter(title: 'AB');
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final match = await service.findBestAlbum(
      title: 'A・B',
      artist: 'Example Artist',
      duration: const Duration(minutes: 3),
    );

    expect(match?.album, 'Localized Album');
  });

  test('requires enough evidence before accepting a sole Apple result', () {
    const apple = AlbumMetadataMatch(
      album: 'Only Apple Album',
      recordingTitle: 'Night Song',
      recordingArtist: 'Example Artist',
      score: 96,
      recordingId: 'apple:track-1',
      releaseId: 'apple:album-1',
      durationVerified: true,
    );

    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [apple],
        hasArtist: true,
        hasDuration: false,
      ),
      isNull,
    );
    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [apple],
        hasArtist: false,
        hasDuration: true,
      ),
      isNull,
    );
    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [apple],
        hasArtist: true,
        hasDuration: true,
      ),
      same(apple),
    );
  });

  test('requires returned duration when local duration is available', () {
    const musicBrainz = AlbumMetadataMatch(
      album: 'Original Album',
      recordingTitle: 'Night Song',
      recordingArtist: 'Example Artist',
      score: 96,
    );
    const agreedMusicBrainz = AlbumMetadataMatch(
      album: 'Original Album',
      recordingTitle: 'Night Song',
      recordingArtist: 'Example Artist',
      score: 96,
      hasCrossSourceAgreement: true,
    );

    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [musicBrainz],
        hasArtist: true,
        hasDuration: true,
      ),
      isNull,
    );
    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [musicBrainz],
        hasArtist: true,
        hasDuration: false,
      ),
      isNull,
    );
    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [agreedMusicBrainz],
        hasArtist: true,
        hasDuration: false,
      ),
      same(agreedMusicBrainz),
    );
  });

  test('does not auto accept candidates with a small score gap', () {
    const best = AlbumMetadataMatch(
      album: 'First Album',
      recordingTitle: 'Night Song',
      recordingArtist: 'Example Artist',
      score: 96,
      recordingId: 'apple:track-1',
      durationVerified: true,
    );
    const closeRunnerUp = AlbumMetadataMatch(
      album: 'Second Album',
      recordingTitle: 'Night Song',
      recordingArtist: 'Example Artist',
      score: 90,
      recordingId: 'apple:track-2',
      durationVerified: true,
    );
    const distantRunnerUp = AlbumMetadataMatch(
      album: 'Third Album',
      recordingTitle: 'Night Song',
      recordingArtist: 'Example Artist',
      score: 87,
      recordingId: 'apple:track-3',
      durationVerified: true,
    );

    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [best, closeRunnerUp],
        hasArtist: true,
        hasDuration: true,
      ),
      isNull,
    );
    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [distantRunnerUp, best],
        hasArtist: true,
        hasDuration: true,
      ),
      same(best),
    );
  });

  test('does not auto accept a compilation release', () {
    const compilation = AlbumMetadataMatch(
      album: 'Greatest Hits Collection',
      recordingTitle: 'Night Song',
      recordingArtist: 'Example Artist',
      score: 96,
      recordingId: 'apple:track-1',
      durationVerified: true,
      releasePreferred: false,
    );

    expect(
      AlbumMetadataService.selectAutomaticMatch(
        const [compilation],
        hasArtist: true,
        hasDuration: true,
      ),
      isNull,
    );
  });

  test(
    'text matching preserves order instead of comparing rune sets',
    () async {
      final dio = Dio()..httpClientAdapter = const _ReorderedTitleAdapter();
      final service = AlbumMetadataService(
        dio: dio,
        appleDio: dio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        appleBaseUri: Uri.parse('https://itunes.test/'),
        requestGap: Duration.zero,
        appleRequestGap: Duration.zero,
      );

      final candidates = await service.findAlbumCandidates(
        title: 'abc',
        artist: 'Same Artist',
        duration: const Duration(minutes: 3),
      );

      expect(candidates, isEmpty);
    },
  );

  test('short title and artist substrings stay manual candidates', () async {
    final dio = Dio()..httpClientAdapter = const _SubstringIdentityAdapter();
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final candidates = await service.findAlbumCandidates(
      title: '光',
      artist: '王',
      duration: const Duration(minutes: 3),
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.titleSimilarity, lessThan(0.9));
    expect(
      AlbumMetadataService.selectAutomaticMatch(
        candidates,
        hasArtist: true,
        hasDuration: true,
      ),
      isNull,
    );
  });

  test('non-ASCII titles have distinct Apple cache keys', () async {
    final adapter = _UnicodeCacheAdapter();
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
      title: 'Привет',
      artist: 'Исполнитель',
      duration: const Duration(minutes: 3),
    );
    final second = await service.findBestAlbum(
      title: 'До свидания',
      artist: 'Исполнитель',
      duration: const Duration(minutes: 3),
    );

    expect(first?.album, 'Первый альбом');
    expect(second?.album, 'Второй альбом');
    expect(adapter.appleCalls, 2);
  });

  test('accented Latin folding keeps letter groups aligned', () async {
    final dio = Dio()..httpClientAdapter = const _AccentFoldingAdapter();
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final match = await service.findBestAlbum(
      title: 'Śong',
      artist: 'Beyoncé',
      duration: const Duration(minutes: 3),
    );

    expect(match?.album, 'Accent Album');
  });

  test('ambiguous high Apple scores fall back to MusicBrainz', () async {
    final adapter = _AmbiguousAppleAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    await service.findAlbumCandidates(
      title: 'Night Song',
      artist: 'Example Artist',
      duration: const Duration(minutes: 3),
    );

    expect(adapter.appleCalls, 1);
    expect(adapter.musicBrainzCalls, greaterThan(0));
  });

  test('cancellation stops before the first metadata request', () async {
    final adapter = _AmbiguousAppleAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final candidates = await service.findAlbumCandidates(
      title: 'Night Song',
      artist: 'Example Artist',
      duration: const Duration(minutes: 3),
      isCancelled: () => true,
    );

    expect(candidates, isEmpty);
    expect(adapter.appleCalls, 0);
    expect(adapter.musicBrainzCalls, 0);
  });

  test('cancellation prevents a retry after a transient failure', () async {
    final adapter = _CancelDuringRetryAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final candidates = await service.findAlbumCandidates(
      title: 'Night Song',
      artist: 'Example Artist',
      duration: const Duration(minutes: 3),
      isCancelled: () => adapter.calls > 0,
    );

    expect(candidates, isEmpty);
    expect(adapter.calls, 1);
  });

  test('rate limits the next request after a retry', () async {
    final adapter = _RetryRateLimitAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: const Duration(milliseconds: 60),
      appleRequestGap: Duration.zero,
      maxRetries: 1,
    );

    await service.findAlbumCandidates(
      title: 'Night Song',
      artist: 'Example Artist',
    );

    expect(adapter.musicBrainzRequests, hasLength(3));
    expect(
      adapter.musicBrainzRequests[2].difference(adapter.musicBrainzRequests[1]),
      greaterThanOrEqualTo(const Duration(milliseconds: 40)),
    );
  });

  test(
    'loads lyrics lazily only when Apple evidence is insufficient',
    () async {
      final safeAdapter = _AppleAlbumAdapter();
      final safeDio = Dio()..httpClientAdapter = safeAdapter;
      final safeService = AlbumMetadataService(
        dio: safeDio,
        appleDio: safeDio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        appleBaseUri: Uri.parse('https://itunes.test/'),
        requestGap: Duration.zero,
        appleRequestGap: Duration.zero,
      );
      var safeLoads = 0;
      await safeService.findAlbumCandidates(
        title: '晴天',
        artist: '周杰伦',
        duration: const Duration(minutes: 4, seconds: 29),
        lyricsLoader: () async {
          safeLoads += 1;
          return 'unused';
        },
      );

      final unsafeAdapter = _AppleAlbumAdapter();
      final unsafeDio = Dio()..httpClientAdapter = unsafeAdapter;
      final unsafeService = AlbumMetadataService(
        dio: unsafeDio,
        appleDio: unsafeDio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        appleBaseUri: Uri.parse('https://itunes.test/'),
        requestGap: Duration.zero,
        appleRequestGap: Duration.zero,
      );
      var unsafeLoads = 0;
      await unsafeService.findAlbumCandidates(
        title: '晴天',
        artist: '周杰伦',
        lyricsLoader: () async {
          unsafeLoads += 1;
          return '[00:00.00]晴天 - 周杰伦';
        },
      );

      expect(safeLoads, 0);
      expect(unsafeLoads, 1);
    },
  );

  test('uses standard LRC title and artist tags as fallback hints', () async {
    final adapter = _QueryCaptureAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
    );

    final candidates = await service.findAlbumCandidates(
      title: 'Dirty File Name',
      artist: 'Unknown',
      lyrics: '[ti:Correct Song]\n[ar:Correct Artist]\n[00:01.00]Lyrics',
    );

    expect(
      adapter.musicBrainzQueries,
      contains('recording:"Correct Song" AND artist:"Correct Artist"'),
    );
    expect(candidates.single.album, 'Correct Album');
  });

  test(
    'reports a network failure instead of treating it as no match',
    () async {
      final dio = Dio()..httpClientAdapter = const _FailingMetadataAdapter();
      final service = AlbumMetadataService(
        dio: dio,
        appleDio: dio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        appleBaseUri: Uri.parse('https://itunes.test/'),
        requestGap: Duration.zero,
        appleRequestGap: Duration.zero,
        maxRetries: 0,
      );

      await expectLater(
        service.findAlbumCandidates(
          title: 'Night Song',
          artist: 'Example Artist',
        ),
        throwsA(isA<AlbumMetadataNetworkException>()),
      );
    },
  );

  test('reports failure when required recording lookup is offline', () async {
    final dio = Dio()..httpClientAdapter = const _FailingLookupAdapter();
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
      maxRetries: 0,
    );

    await expectLater(
      service.findAlbumCandidates(
        title: 'Night Song',
        artist: 'Example Artist',
      ),
      throwsA(isA<AlbumMetadataNetworkException>()),
    );
  });

  test(
    'does not hide a fallback lookup failure behind an empty query',
    () async {
      final dio = Dio()
        ..httpClientAdapter = const _PartialLookupFailureAdapter();
      final service = AlbumMetadataService(
        dio: dio,
        appleDio: dio,
        baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
        appleBaseUri: Uri.parse('https://itunes.test/'),
        requestGap: Duration.zero,
        appleRequestGap: Duration.zero,
        maxRetries: 0,
      );

      await expectLater(
        service.findAlbumCandidates(
          title: 'Dirty File Name',
          artist: 'Unknown',
          lyrics: '[ti:Correct Song]\n[ar:Correct Artist]',
        ),
        throwsA(isA<AlbumMetadataNetworkException>()),
      );
    },
  );

  test('does not cache malformed Apple responses as empty results', () async {
    final adapter = _MalformedAppleAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
      maxRetries: 0,
    );

    expect(
      await service.findAlbumCandidates(
        title: 'Night Song',
        artist: 'Example Artist',
      ),
      isEmpty,
    );
    expect(
      await service.findAlbumCandidates(
        title: 'Night Song',
        artist: 'Example Artist',
      ),
      isEmpty,
    );
    expect(adapter.appleCalls, 2);
  });

  test('reports malformed MusicBrainz responses as failures', () async {
    final dio = Dio()..httpClientAdapter = const _MalformedMusicBrainzAdapter();
    final service = AlbumMetadataService(
      dio: dio,
      appleDio: dio,
      baseUri: Uri.parse('https://musicbrainz.test/ws/2/'),
      appleBaseUri: Uri.parse('https://itunes.test/'),
      requestGap: Duration.zero,
      appleRequestGap: Duration.zero,
      maxRetries: 0,
    );

    await expectLater(
      service.findAlbumCandidates(
        title: 'Night Song',
        artist: 'Example Artist',
      ),
      throwsA(isA<AlbumMetadataNetworkException>()),
    );
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

class _QueryCaptureAdapter implements HttpClientAdapter {
  final List<String> musicBrainzQueries = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({'resultCount': 0, 'results': []});
    }
    final query = options.uri.queryParameters['query'];
    if (query != null) {
      musicBrainzQueries.add(query);
    }
    if (query?.contains('recording:"Correct Song"') ?? false) {
      return _jsonResponse({
        'recordings': [
          {
            'id': 'correct-recording',
            'score': '100',
            'title': 'Correct Song',
            'artist-credit': [
              {'name': 'Correct Artist'},
            ],
            'releases': [
              {
                'id': 'correct-release',
                'title': 'Correct Album',
                'status': 'Official',
                'artist-credit': [
                  {'name': 'Correct Artist'},
                ],
                'release-group': {
                  'id': 'correct-release-group',
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

class _FailingMetadataAdapter implements HttpClientAdapter {
  const _FailingMetadataAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({'resultCount': 0, 'results': []});
    }
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: StateError('offline'),
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FailingLookupAdapter implements HttpClientAdapter {
  const _FailingLookupAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({'resultCount': 0, 'results': []});
    }
    if (options.uri.path == '/ws/2/recording') {
      return _jsonResponse({
        'recordings': [
          {
            'id': 'recording-without-releases',
            'score': '100',
            'title': 'Night Song',
            'artist-credit': [
              {'name': 'Example Artist'},
            ],
            'releases': [],
          },
        ],
      });
    }
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: StateError('lookup offline'),
    );
  }

  @override
  void close({bool force = false}) {}
}

class _PartialLookupFailureAdapter implements HttpClientAdapter {
  const _PartialLookupFailureAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({'resultCount': 0, 'results': []});
    }
    if (options.uri.path == '/ws/2/recording') {
      final query = options.uri.queryParameters['query'] ?? '';
      if (!query.contains('Correct Song')) {
        return _jsonResponse({'recordings': []});
      }
      return _jsonResponse({
        'recordings': [
          {
            'id': 'fallback-recording',
            'score': '100',
            'title': 'Correct Song',
            'artist-credit': [
              {'name': 'Correct Artist'},
            ],
            'releases': [],
          },
        ],
      });
    }
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: StateError('fallback lookup offline'),
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MalformedAppleAdapter implements HttpClientAdapter {
  int appleCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      appleCalls += 1;
      return _javascriptResponse({'unexpected': true});
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _MalformedMusicBrainzAdapter implements HttpClientAdapter {
  const _MalformedMusicBrainzAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({'resultCount': 0, 'results': []});
    }
    return _jsonResponse({'unexpected': true});
  }

  @override
  void close({bool force = false}) {}
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

class _LiveVersionAdapter implements HttpClientAdapter {
  const _LiveVersionAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: 1,
            collectionId: 10,
            title: 'Night Song (Live)',
            artist: 'Example Artist',
            album: 'Live at Example Hall',
          ),
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _JapaneseLiveVersionAdapter implements HttpClientAdapter {
  const _JapaneseLiveVersionAdapter({required this.halfWidth});

  final bool halfWidth;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: 11,
            collectionId: 110,
            title: 'Beautiful Endless Song (${halfWidth ? 'ﾗｲﾌﾞ' : 'ライブ'})',
            artist: 'Example Artist',
            album: 'Example Album',
          ),
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _LocalizedTitleAdapter implements HttpClientAdapter {
  const _LocalizedTitleAdapter({required this.title});

  final String title;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: 13,
            collectionId: 130,
            title: title,
            artist: 'Example Artist',
            album: 'Localized Album',
          ),
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _ReorderedTitleAdapter implements HttpClientAdapter {
  const _ReorderedTitleAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: 2,
            collectionId: 20,
            title: 'cba',
            artist: 'Same Artist',
            album: 'Wrong Album',
          ),
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _SubstringIdentityAdapter implements HttpClientAdapter {
  const _SubstringIdentityAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: 12,
            collectionId: 120,
            title: '光年',
            artist: '王菲',
            album: 'Wrong Album',
          ),
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _UnicodeCacheAdapter implements HttpClientAdapter {
  int appleCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      appleCalls += 1;
      final term = options.uri.queryParameters['term'] ?? '';
      final isFirst = term.contains('Привет');
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: isFirst ? 3 : 4,
            collectionId: isFirst ? 30 : 40,
            title: isFirst ? 'Привет' : 'До свидания',
            artist: 'Исполнитель',
            album: isFirst ? 'Первый альбом' : 'Второй альбом',
          ),
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _AccentFoldingAdapter implements HttpClientAdapter {
  const _AccentFoldingAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: 7,
            collectionId: 70,
            title: 'Song',
            artist: 'Beyonce',
            album: 'Accent Album',
          ),
        ],
      });
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _CancelDuringRetryAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    return ResponseBody.fromString(
      '{}',
      503,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RetryRateLimitAdapter implements HttpClientAdapter {
  final List<DateTime> musicBrainzRequests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      return _javascriptResponse({'resultCount': 0, 'results': []});
    }
    musicBrainzRequests.add(DateTime.now());
    if (musicBrainzRequests.length == 1) {
      return ResponseBody.fromString(
        '{}',
        503,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
    }
    return _jsonResponse({'recordings': []});
  }

  @override
  void close({bool force = false}) {}
}

class _AmbiguousAppleAdapter implements HttpClientAdapter {
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
      return _javascriptResponse({
        'results': [
          _appleResult(
            trackId: 5,
            collectionId: 50,
            title: 'Night Song',
            artist: 'Example Artist',
            album: 'First Album',
          ),
          _appleResult(
            trackId: 6,
            collectionId: 60,
            title: 'Night Song',
            artist: 'Example Artist',
            album: 'Second Album',
          ),
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
            'length': 180000,
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
            {'name': 'Example Artist'},
          ],
          'releases': [
            {
              'id': 'release-low',
              'title': 'Unverified Broadcast',
              'status': 'Bootleg',
              'date': '2021-01-01',
              'artist-credit': [
                {'name': 'Example Artist'},
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

Map<String, Object?> _appleResult({
  required int trackId,
  required int collectionId,
  required String title,
  required String artist,
  required String album,
  int trackTimeMillis = 180000,
}) {
  return {
    'wrapperType': 'track',
    'kind': 'song',
    'trackId': trackId,
    'collectionId': collectionId,
    'trackName': title,
    'artistName': artist,
    'collectionName': album,
    'trackTimeMillis': trackTimeMillis,
    'releaseDate': '2020-01-01T00:00:00Z',
  };
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
