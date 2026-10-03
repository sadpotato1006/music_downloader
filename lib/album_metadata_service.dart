import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'app_info.dart';

import 'app_log.dart';

class AlbumMetadataService {
  AlbumMetadataService({
    Dio? dio,
    Uri? baseUri,
    Dio? appleDio,
    Uri? appleBaseUri,
    this.requestGap = const Duration(milliseconds: 1100),
    this.appleRequestGap = const Duration(seconds: 3),
    this.appleCountry = 'CN',
    this.maxRetries = 2,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               sendTimeout: const Duration(seconds: 10),
             ),
           ),
       _appleDio =
           appleDio ??
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               sendTimeout: const Duration(seconds: 10),
             ),
           ),
       _baseUri = baseUri ?? Uri.parse('https://musicbrainz.org/ws/2/'),
       _appleBaseUri = appleBaseUri ?? Uri.parse('https://itunes.apple.com/');

  final Dio _dio;
  final Dio _appleDio;
  final Uri _baseUri;
  final Uri _appleBaseUri;
  final Duration requestGap;
  final Duration appleRequestGap;
  final String appleCountry;
  final int maxRetries;
  Future<void> _requestQueue = Future<void>.value();
  Future<void> _appleRequestQueue = Future<void>.value();
  DateTime? _lastRequestAt;
  DateTime? _lastAppleRequestAt;
  final Map<String, List<AlbumMetadataMatch>> _appleCandidateCache = {};

  static const _userAgent = appProjectUserAgent;

  /// Minimum score for conservative download matching and source discovery.
  ///
  /// A score alone is not sufficient: [selectAutomaticMatch] also checks the
  /// runner-up, source evidence, and version compatibility.
  static const highConfidenceScore = 86.0;
  static const minimumAutomaticScoreGap = 8.0;
  static const _appleCacheLimit = 128;
  static const _accompaniment = '\u4f34\u594f';
  static const _concert = '\u6f14\u5531\u4f1a';
  static const _liveScene = '\u73b0\u573a';
  static const _variousArtists = '\u7fa4\u661f';
  static const _variousArtistsCollection = '\u7fa4\u661f\u5408\u8f91';

  Future<AlbumMetadataMatch?> findBestAlbum({
    required String title,
    required String artist,
    String? lyrics,
    Future<String?> Function()? lyricsLoader,
    bool Function()? isCancelled,
    Duration? duration,
  }) async {
    final candidates = await findAlbumCandidates(
      title: title,
      artist: artist,
      lyrics: lyrics,
      lyricsLoader: lyricsLoader,
      isCancelled: isCancelled,
      duration: duration,
      // Automatic selection needs the runner-up to detect ambiguity.
      limit: 5,
    );
    return selectAutomaticMatch(
      candidates,
      hasArtist: _cleanArtist(artist).isNotEmpty,
      hasDuration: duration != null,
    );
  }

  /// Picks the highest scored usable album for scans and explicit lookups.
  static AlbumMetadataMatch? selectHighestScoreMatch(
    Iterable<AlbumMetadataMatch> candidates,
  ) {
    AlbumMetadataMatch? best;
    for (final candidate in candidates) {
      if (candidate.album.trim().isEmpty) continue;
      if (best == null || candidate.compareTo(best) < 0) best = candidate;
    }
    return best;
  }

  /// Returns a candidate only when it is safe to apply without confirmation.
  ///
  /// [findAlbumCandidates] intentionally returns weaker and ambiguous matches
  /// as well, so callers can still offer them for manual selection.
  static AlbumMetadataMatch? selectAutomaticMatch(
    List<AlbumMetadataMatch> candidates, {
    required bool hasArtist,
    required bool hasDuration,
  }) {
    if (candidates.isEmpty) {
      return null;
    }

    final ranked = candidates.toList(growable: false)..sort();
    final best = ranked.first;
    if (best.score < highConfidenceScore ||
        !best.versionCompatible ||
        !best.releasePreferred ||
        best.titleSimilarity < 0.9 ||
        (hasArtist && best.artistSimilarity < 0.9)) {
      return null;
    }

    // An Apple song search without both identity signals is useful as a hint,
    // but is not strong enough to edit a local file by itself.
    if (best.isApple &&
        (!hasArtist || !hasDuration) &&
        !best.hasCrossSourceAgreement) {
      return null;
    }
    if (!hasArtist && !best.hasCrossSourceAgreement) {
      return null;
    }
    if (!hasDuration && !best.hasCrossSourceAgreement) {
      return null;
    }
    if (hasDuration && !best.durationVerified) {
      return null;
    }

    if (ranked.length > 1 &&
        best.score - ranked[1].score < minimumAutomaticScoreGap) {
      return null;
    }
    return best;
  }

  Future<List<AlbumMetadataMatch>> findAlbumCandidates({
    required String title,
    required String artist,
    String? lyrics,
    Future<String?> Function()? lyricsLoader,
    bool Function()? isCancelled,
    Duration? duration,
    int limit = 5,
  }) async {
    if (isCancelled?.call() ?? false) {
      return const [];
    }
    final cleanedTitle = _cleanTitle(title);
    final cleanedArtist = _cleanArtist(artist);
    if (cleanedTitle.isEmpty) {
      return const [];
    }

    Object? appleNetworkError;
    Object? musicBrainzNetworkError;
    List<AlbumMetadataMatch> appleCandidates;
    try {
      appleCandidates = await _findAppleCandidates(
        title: cleanedTitle,
        artist: cleanedArtist,
        duration: duration,
        isCancelled: isCancelled,
      );
    } on _AlbumMetadataCancelled {
      return const [];
    } on AlbumMetadataNetworkException catch (error) {
      appleNetworkError = error;
      appleCandidates = const [];
    }
    if (isCancelled?.call() ?? false) {
      return const [];
    }
    final safeAppleMatch = selectAutomaticMatch(
      appleCandidates,
      hasArtist: cleanedArtist.isNotEmpty,
      hasDuration: duration != null,
    );
    if (safeAppleMatch != null) {
      AppLog.instance.info(
        'album',
        'Apple iTunes 专辑匹配成功',
        detail:
            '$cleanedTitle → ${safeAppleMatch.album} '
            '(${safeAppleMatch.score.toStringAsFixed(1)})',
      );
      return appleCandidates.take(limit).toList();
    }

    AppLog.instance.info(
      'album',
      'Apple 无可靠专辑结果，切换 MusicBrainz',
      detail: cleanedTitle,
    );

    var resolvedLyrics = lyrics;
    if ((resolvedLyrics == null || resolvedLyrics.trim().isEmpty) &&
        lyricsLoader != null) {
      try {
        resolvedLyrics = await lyricsLoader();
      } catch (error, stackTrace) {
        AppLog.instance.warning(
          'album',
          '读取歌词提示失败，继续匹配专辑',
          detail: '$error\n$stackTrace',
        );
      }
    }
    final lyricHint = _lyricTitleArtistHint(resolvedLyrics);
    final queries = <_SearchHint>[
      _SearchHint(title: cleanedTitle, artist: cleanedArtist),
      if (lyricHint != null &&
          (lyricHint.title != cleanedTitle ||
              lyricHint.artist != cleanedArtist))
        lyricHint,
      _SearchHint(title: cleanedTitle, artist: ''),
    ];

    final candidatesByAlbum = <String, AlbumMetadataMatch>{};
    for (final candidate in appleCandidates) {
      _addOrMergeCandidate(candidatesByAlbum, candidate);
    }
    final searched = <String>{};
    for (final query in queries) {
      if (isCancelled?.call() ?? false) {
        return const [];
      }
      final key = '${query.title}\n${query.artist}';
      if (!searched.add(key)) {
        continue;
      }

      List<Map<String, dynamic>> recordings;
      try {
        recordings = await _searchRecordings(query, isCancelled: isCancelled);
      } on _AlbumMetadataCancelled {
        return const [];
      } on AlbumMetadataNetworkException catch (error) {
        musicBrainzNetworkError = error;
        continue;
      }
      final useLyricHintForScoring = identical(query, lyricHint);
      final scoringTitle = useLyricHintForScoring ? query.title : cleanedTitle;
      final scoringArtist = useLyricHintForScoring
          ? query.artist
          : cleanedArtist;
      for (var recording in recordings.take(5)) {
        if (isCancelled?.call() ?? false) {
          return const [];
        }
        if (_releases(recording).isEmpty) {
          Map<String, dynamic>? lookup;
          try {
            lookup = await _lookupRecording(
              recording['id'] as String?,
              isCancelled: isCancelled,
            );
          } on _AlbumMetadataCancelled {
            return const [];
          } on AlbumMetadataNetworkException catch (error) {
            musicBrainzNetworkError = error;
          }
          if (isCancelled?.call() ?? false) {
            return const [];
          }
          if (lookup != null) {
            recording = lookup;
          }
        }

        for (final release in _releases(recording)) {
          final candidate = _matchFromRecordingRelease(
            recording,
            release,
            title: scoringTitle,
            artist: scoringArtist,
            duration: duration,
          );
          if (candidate == null) {
            continue;
          }
          _addOrMergeCandidate(candidatesByAlbum, candidate);
        }
      }

      final safeMatch = selectAutomaticMatch(
        candidatesByAlbum.values.toList(growable: false),
        hasArtist: cleanedArtist.isNotEmpty,
        hasDuration: duration != null,
      );
      if (safeMatch != null) {
        break;
      }
    }

    final candidates = candidatesByAlbum.values.toList()..sort();
    if (candidates.isNotEmpty) {
      AppLog.instance.info(
        'album',
        '${candidates.first.sourceLabel} 返回最佳专辑候选',
        detail:
            '$cleanedTitle → ${candidates.first.album} '
            '(${candidates.first.score.toStringAsFixed(1)})',
      );
    } else {
      if (musicBrainzNetworkError != null) {
        throw musicBrainzNetworkError;
      }
      if (appleNetworkError != null) {
        AppLog.instance.warning(
          'album',
          'Apple 请求失败，但 MusicBrainz 已完成且没有候选',
          detail: '$appleNetworkError',
        );
      }
      AppLog.instance.warning('album', '未找到专辑候选', detail: cleanedTitle);
    }
    return candidates.take(limit).toList();
  }

  Future<List<AlbumMetadataMatch>> _findAppleCandidates({
    required String title,
    required String artist,
    required Duration? duration,
    bool Function()? isCancelled,
  }) async {
    final cacheKey = [
      _normalizeText(title),
      _normalizeText(artist),
      duration?.inMilliseconds ?? -1,
      appleCountry.toUpperCase(),
    ].join('\n');
    final cached = _appleCandidateCache.remove(cacheKey);
    if (cached != null) {
      _appleCandidateCache[cacheKey] = cached;
      return cached;
    }

    final term = [
      title,
      artist,
    ].where((value) => value.trim().isNotEmpty).join(' ');
    final data = await _getAppleJson({
      'term': term,
      'country': appleCountry,
      'media': 'music',
      'entity': 'song',
      'limit': '25',
    }, isCancelled: isCancelled);
    final results = data?['results'];
    if (results is! List) {
      throw AlbumMetadataNetworkException(
        'Apple iTunes 响应',
        const FormatException('results 字段缺失或格式不正确'),
      );
    }

    final candidatesByAlbum = <String, AlbumMetadataMatch>{};
    for (final raw in results.whereType<Map>()) {
      final candidate = _matchFromAppleResult(
        Map<String, dynamic>.from(raw),
        title: title,
        artist: artist,
        duration: duration,
      );
      if (candidate == null) {
        continue;
      }
      final key = _candidateKey(candidate);
      final existing = candidatesByAlbum[key];
      if (existing == null || candidate.compareTo(existing) < 0) {
        candidatesByAlbum[key] = candidate;
      }
    }

    final candidates = candidatesByAlbum.values.toList()..sort();
    final result = List<AlbumMetadataMatch>.unmodifiable(candidates);
    _appleCandidateCache[cacheKey] = result;
    if (_appleCandidateCache.length > _appleCacheLimit) {
      _appleCandidateCache.remove(_appleCandidateCache.keys.first);
    }
    return result;
  }

  Future<Map<String, dynamic>?> _getAppleJson(
    Map<String, String> query, {
    bool Function()? isCancelled,
  }) {
    return _enqueueAppleRequest(() async {
      final uri = _appleBaseUri
          .resolve('/search')
          .replace(queryParameters: query);
      try {
        final response = await _getWithRetry(
          _appleDio,
          uri,
          Options(
            receiveTimeout: const Duration(seconds: 10),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': _userAgent,
            },
          ),
          minimumDelay: appleRequestGap,
          isCancelled: isCancelled,
          markRetryStarted: () => _lastAppleRequestAt = DateTime.now(),
        );
        Object? data = response.data;
        if (data is String) {
          try {
            data = jsonDecode(data);
          } on FormatException catch (error) {
            AppLog.instance.warning('album', 'Apple 返回了无法解析的数据', detail: error);
            throw AlbumMetadataNetworkException('Apple iTunes 响应', error);
          }
        }
        if (data is Map<String, dynamic>) {
          return data;
        }
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      } on _AlbumMetadataCancelled {
        rethrow;
      } on AlbumMetadataNetworkException {
        rethrow;
      } on DioException catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'Apple iTunes 请求失败',
          error: error,
          stackTrace: stackTrace,
        );
        throw AlbumMetadataNetworkException('Apple iTunes', error);
      } catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'Apple iTunes 响应处理失败',
          error: error,
          stackTrace: stackTrace,
        );
        throw AlbumMetadataNetworkException('Apple iTunes 响应', error);
      }
      throw AlbumMetadataNetworkException(
        'Apple iTunes 响应',
        const FormatException('响应不是 JSON 对象'),
      );
    });
  }

  Future<List<Map<String, dynamic>>> _searchRecordings(
    _SearchHint hint, {
    bool Function()? isCancelled,
  }) async {
    final query = hint.artist.isEmpty
        ? 'recording:"${_escapeQuery(hint.title)}"'
        : 'recording:"${_escapeQuery(hint.title)}" AND '
              'artist:"${_escapeQuery(hint.artist)}"';
    final data = await _getJson('recording', {
      'query': query,
      'fmt': 'json',
      'limit': '10',
      'inc': 'releases+artist-credits+release-groups',
    }, isCancelled: isCancelled);
    final recordings = data?['recordings'];
    if (recordings is! List) {
      throw AlbumMetadataNetworkException(
        'MusicBrainz 响应',
        const FormatException('recordings 字段缺失或格式不正确'),
      );
    }
    return recordings
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<Map<String, dynamic>?> _lookupRecording(
    String? id, {
    bool Function()? isCancelled,
  }) async {
    if (id == null || id.trim().isEmpty) {
      return null;
    }
    final data = await _getJson('recording/$id', {
      'fmt': 'json',
      'inc': 'releases+artist-credits+release-groups',
    }, isCancelled: isCancelled);
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>?> _getJson(
    String path,
    Map<String, String> query, {
    bool Function()? isCancelled,
  }) {
    return _enqueueRequest(() async {
      final uri = _baseUri.resolve(path).replace(queryParameters: query);
      try {
        final response = await _getWithRetry(
          _dio,
          uri,
          Options(
            receiveTimeout: const Duration(seconds: 10),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': _userAgent,
            },
          ),
          minimumDelay: requestGap,
          isCancelled: isCancelled,
          markRetryStarted: () => _lastRequestAt = DateTime.now(),
        );
        Object? data = response.data;
        if (data is String) {
          try {
            data = jsonDecode(data);
          } on FormatException catch (error) {
            throw AlbumMetadataNetworkException('MusicBrainz 响应', error);
          }
        }
        if (data is Map<String, dynamic>) {
          return data;
        }
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      } on _AlbumMetadataCancelled {
        rethrow;
      } on AlbumMetadataNetworkException {
        rethrow;
      } on DioException catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'MusicBrainz 请求失败',
          error: error,
          stackTrace: stackTrace,
        );
        throw AlbumMetadataNetworkException('MusicBrainz', error);
      } catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'MusicBrainz 响应处理失败',
          error: error,
          stackTrace: stackTrace,
        );
        throw AlbumMetadataNetworkException('MusicBrainz 响应', error);
      }
      throw AlbumMetadataNetworkException(
        'MusicBrainz 响应',
        const FormatException('响应不是 JSON 对象'),
      );
    });
  }

  Future<T> _enqueueRequest<T>(Future<T> Function() request) {
    final completer = Completer<T>();
    _requestQueue = _requestQueue.then((_) async {
      try {
        await _respectRateLimit();
        completer.complete(await request());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Response<Object?>> _getWithRetry(
    Dio dio,
    Uri uri,
    Options options, {
    required Duration minimumDelay,
    bool Function()? isCancelled,
    void Function()? markRetryStarted,
  }) async {
    for (var attempt = 0; ; attempt += 1) {
      if (isCancelled?.call() ?? false) {
        throw const _AlbumMetadataCancelled();
      }
      if (attempt > 0) {
        markRetryStarted?.call();
      }
      try {
        return await dio.getUri<Object?>(uri, options: options);
      } on DioException catch (error) {
        if (attempt >= maxRetries || !_isRetryable(error)) {
          rethrow;
        }
        await _delayWithCancellation(
          _retryDelay(error, attempt, minimumDelay),
          isCancelled,
        );
      }
    }
  }

  static Future<void> _delayWithCancellation(
    Duration delay,
    bool Function()? isCancelled,
  ) async {
    var remaining = delay;
    const interval = Duration(milliseconds: 100);
    while (remaining > Duration.zero) {
      if (isCancelled?.call() ?? false) {
        throw const _AlbumMetadataCancelled();
      }
      final step = remaining < interval ? remaining : interval;
      await Future<void>.delayed(step);
      remaining -= step;
    }
    if (isCancelled?.call() ?? false) {
      throw const _AlbumMetadataCancelled();
    }
  }

  static bool _isRetryable(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return true;
    }
    final status = error.response?.statusCode;
    return status == 429 ||
        status == 500 ||
        status == 502 ||
        status == 503 ||
        status == 504;
  }

  static Duration _retryDelay(
    DioException error,
    int attempt,
    Duration minimumDelay,
  ) {
    final retryAfter = error.response?.headers.value('retry-after');
    final retryAfterSeconds = int.tryParse(retryAfter ?? '');
    if (retryAfterSeconds != null && retryAfterSeconds > 0) {
      final requested = Duration(
        seconds: retryAfterSeconds.clamp(1, 30).toInt(),
      );
      return requested > minimumDelay ? requested : minimumDelay;
    }
    final fallback = Duration(seconds: 1 << attempt.clamp(0, 4).toInt());
    return fallback > minimumDelay ? fallback : minimumDelay;
  }

  Future<T> _enqueueAppleRequest<T>(Future<T> Function() request) {
    final completer = Completer<T>();
    _appleRequestQueue = _appleRequestQueue.then((_) async {
      try {
        await _respectAppleRateLimit();
        completer.complete(await request());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _respectRateLimit() async {
    final last = _lastRequestAt;
    if (last != null && requestGap > Duration.zero) {
      final remaining = requestGap - DateTime.now().difference(last);
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  Future<void> _respectAppleRateLimit() async {
    final last = _lastAppleRequestAt;
    if (last != null && appleRequestGap > Duration.zero) {
      final remaining = appleRequestGap - DateTime.now().difference(last);
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
    _lastAppleRequestAt = DateTime.now();
  }

  AlbumMetadataMatch? _matchFromAppleResult(
    Map<String, dynamic> item, {
    required String title,
    required String artist,
    required Duration? duration,
  }) {
    final kind = (item['kind'] as String? ?? '').trim().toLowerCase();
    if (kind.isNotEmpty && kind != 'song') {
      return null;
    }

    final album = (item['collectionName'] as String? ?? '').trim();
    final recordingTitle = (item['trackName'] as String? ?? '').trim();
    final recordingArtist = (item['artistName'] as String? ?? '').trim();
    final collectionArtist = (item['collectionArtistName'] as String? ?? '')
        .trim();
    if (album.isEmpty || recordingTitle.isEmpty) {
      return null;
    }

    final titleScore = _textSimilarity(title, recordingTitle);
    final artistScore = artist.isEmpty
        ? 0.55
        : [
            _textSimilarity(artist, recordingArtist),
            _textSimilarity(artist, collectionArtist),
          ].reduce((a, b) => a > b ? a : b);
    if (titleScore < 0.72 || artistScore < 0.48) {
      return null;
    }
    if (!_versionsAreCompatible(title, '$recordingTitle\n$album')) {
      return null;
    }

    var durationScore = duration == null ? 0.65 : 0.35;
    var durationVerified = false;
    final trackTimeMillis = item['trackTimeMillis'];
    if (duration != null && trackTimeMillis is num && trackTimeMillis > 0) {
      final delta = (trackTimeMillis.toDouble() - duration.inMilliseconds)
          .abs();
      if (delta > 8000) {
        return null;
      }
      durationScore = delta <= 2000
          ? 1
          : delta <= 4000
          ? 0.9
          : 0.75;
      durationVerified = true;
    }

    final score = titleScore * 42 + artistScore * 34 + durationScore * 20;

    final trackId = item['trackId']?.toString();
    final collectionId = item['collectionId']?.toString();
    return AlbumMetadataMatch(
      album: album,
      recordingTitle: recordingTitle,
      recordingArtist: recordingArtist.isEmpty
          ? collectionArtist
          : recordingArtist,
      recordingId: trackId == null ? null : 'apple:$trackId',
      releaseId: collectionId == null ? null : 'apple:$collectionId',
      releaseDate: item['releaseDate'] as String?,
      score: score.clamp(0, 98).toDouble(),
      titleSimilarity: titleScore,
      artistSimilarity: artistScore,
      durationVerified: durationVerified,
      versionCompatible: true,
      releasePreferred:
          !_looksLikeVariousArtists(collectionArtist) &&
          !_looksLikeCompilationAlbum(album),
    );
  }

  AlbumMetadataMatch? _matchFromRecordingRelease(
    Map<String, dynamic> recording,
    Map<String, dynamic> release, {
    required String title,
    required String artist,
    required Duration? duration,
  }) {
    final album = (release['title'] as String? ?? '').trim();
    if (album.isEmpty) {
      return null;
    }

    final recordingTitle = (recording['title'] as String? ?? '').trim();
    final recordingArtist = _artistCreditName(recording['artist-credit']);
    final releaseArtist = _artistCreditName(release['artist-credit']);
    final releaseGroup = release['release-group'] is Map
        ? Map<String, dynamic>.from(release['release-group'] as Map)
        : const <String, dynamic>{};
    final primaryType = (releaseGroup['primary-type'] as String? ?? '')
        .trim()
        .toLowerCase();
    final secondaryTypes =
        (releaseGroup['secondary-types'] as List? ?? const [])
            .whereType<String>()
            .map((value) => value.toLowerCase())
            .toSet();
    final status = (release['status'] as String? ?? '').toLowerCase();
    final musicBrainzScore = _parseScore(recording['score']);

    final titleScore = _textSimilarity(title, recordingTitle);
    final artistScore = artist.isEmpty
        ? 0.55
        : [
            _textSimilarity(artist, recordingArtist),
            _textSimilarity(artist, releaseArtist),
          ].reduce((a, b) => a > b ? a : b);
    if (titleScore < 0.72 || artistScore < 0.48) {
      return null;
    }
    final versionText = [recordingTitle, album, ...secondaryTypes].join('\n');
    if (!_versionsAreCompatible(title, versionText)) {
      return null;
    }

    var durationScore = duration == null ? 0.65 : 0.35;
    var durationVerified = false;
    final recordingLength = recording['length'];
    if (duration != null && recordingLength is num && recordingLength > 0) {
      final delta = (recordingLength.toDouble() - duration.inMilliseconds)
          .abs();
      if (delta > 8000) {
        return null;
      }
      durationScore = delta <= 2000
          ? 1
          : delta <= 4000
          ? 0.9
          : 0.75;
      durationVerified = true;
    }

    // Keep identity evidence dominant and leave headroom for release ranking.
    // The previous additive formula routinely clamped unrelated releases to
    // 100, making their dates the accidental tie-breaker.
    var score =
        musicBrainzScore * 0.12 +
        titleScore * 34 +
        artistScore * 27 +
        durationScore * 12;
    if (status == 'official') {
      score += 5;
    } else if (status == 'bootleg') {
      score -= 5;
    }
    score += switch (primaryType) {
      'album' => 5,
      'ep' => 4,
      'single' => 3,
      'broadcast' => -6,
      _ => 0,
    };
    if (secondaryTypes.contains('soundtrack')) {
      score += 1;
    }
    if (secondaryTypes.contains('compilation')) {
      score -= 8;
    }
    if (_looksLikeCompilationAlbum(album)) {
      score -= 8;
    }
    if (_looksLikeVariousArtists(releaseArtist)) {
      score -= 6;
    }

    return AlbumMetadataMatch(
      album: album,
      recordingTitle: recordingTitle,
      recordingArtist: recordingArtist.isEmpty
          ? releaseArtist
          : recordingArtist,
      recordingId: recording['id'] as String?,
      releaseId: release['id'] as String?,
      releaseGroupId: releaseGroup['id'] as String?,
      releaseDate: release['date'] as String?,
      score: score.clamp(0, 98).toDouble(),
      titleSimilarity: titleScore,
      artistSimilarity: artistScore,
      durationVerified: durationVerified,
      versionCompatible: true,
      releasePreferred:
          status != 'bootleg' &&
          primaryType != 'broadcast' &&
          !secondaryTypes.contains('compilation') &&
          !_looksLikeCompilationAlbum(album) &&
          !_looksLikeVariousArtists(releaseArtist),
    );
  }

  List<Map<String, dynamic>> _releases(Map<String, dynamic> recording) {
    final releases = recording['releases'];
    if (releases is! List) {
      return const [];
    }
    return releases
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static String _artistCreditName(Object? artistCredit) {
    if (artistCredit is! List) {
      return '';
    }
    final buffer = StringBuffer();
    for (final item in artistCredit) {
      if (item is String) {
        buffer.write(item);
      } else if (item is Map) {
        final name =
            item['name'] as String? ??
            (item['artist'] is Map
                ? (item['artist'] as Map)['name'] as String?
                : null);
        if (name != null) {
          buffer.write(name);
        }
        final joinPhrase = item['joinphrase'] as String?;
        if (joinPhrase != null) {
          buffer.write(joinPhrase);
        }
      }
    }
    return buffer.toString().trim();
  }

  static double _parseScore(Object? value) {
    if (value is num) {
      return value.toDouble().clamp(0, 100);
    }
    if (value is String) {
      return (double.tryParse(value) ?? 0).clamp(0, 100);
    }
    return 0;
  }

  static bool _looksLikeVariousArtists(String value) {
    final normalized = _normalizeText(value);
    return normalized == 'variousartists' ||
        normalized == 'various' ||
        normalized == _normalizeText(_variousArtists) ||
        normalized == _normalizeText(_variousArtistsCollection);
  }

  static bool _looksLikeCompilationAlbum(String value) {
    final normalized = _normalizeText(value);
    return normalized.contains('greatesthits') ||
        normalized.contains('bestof') ||
        normalized.contains('collection') ||
        normalized.contains('anthology') ||
        normalized.contains('compilation') ||
        normalized.contains('精选') ||
        normalized.contains('金曲') ||
        normalized.contains('合辑');
  }

  static void _addOrMergeCandidate(
    Map<String, AlbumMetadataMatch> candidates,
    AlbumMetadataMatch candidate,
  ) {
    final key = _candidateKey(candidate);
    final existing = candidates[key];
    if (existing == null) {
      candidates[key] = candidate;
      return;
    }

    final preferred = candidate.compareTo(existing) < 0 ? candidate : existing;
    final crossSource =
        existing.hasCrossSourceAgreement ||
        candidate.hasCrossSourceAgreement ||
        existing.isApple != candidate.isApple;
    candidates[key] = preferred.copyWith(
      hasCrossSourceAgreement: crossSource,
      releasePreferred: existing.releasePreferred && candidate.releasePreferred,
    );
  }

  static String _candidateKey(AlbumMetadataMatch candidate) {
    // JSON encoding preserves field boundaries and avoids the collisions that
    // concatenating already-stripped strings can create.
    return jsonEncode([
      _normalizeText(candidate.album),
      _normalizeText(candidate.recordingArtist),
    ]);
  }

  static String _cleanTitle(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(
          RegExp(r'\s*[（(](?:mp3|flac)[）)]\s*$', caseSensitive: false),
          '',
        )
        .trim();
  }

  static String _cleanArtist(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _escapeQuery(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }

  static double _textSimilarity(String expected, String actual) {
    final left = _normalizeText(expected);
    final right = _normalizeText(actual);
    if (left.isEmpty || right.isEmpty) {
      return 0;
    }
    if (left == right) {
      return 1;
    }
    if (left.contains(right) || right.contains(left)) {
      final shorter = left.runes.length < right.runes.length
          ? left.runes.length
          : right.runes.length;
      final longer = left.runes.length > right.runes.length
          ? left.runes.length
          : right.runes.length;
      return 0.65 + 0.35 * (shorter / longer);
    }
    final leftRunes = left.runes.toList(growable: false);
    final rightRunes = right.runes.toList(growable: false);
    final longest = leftRunes.length > rightRunes.length
        ? leftRunes.length
        : rightRunes.length;
    final editSimilarity =
        1 - _levenshteinDistance(leftRunes, rightRunes) / longest;
    final bigramSimilarity = _bigramDice(leftRunes, rightRunes);
    return editSimilarity > bigramSimilarity
        ? editSimilarity
        : bigramSimilarity;
  }

  static String _normalizeText(String value) {
    return _normalizeWords(value).replaceAll(' ', '');
  }

  static String _normalizeWords(String value) {
    final buffer = StringBuffer();
    var needsSeparator = false;
    for (final rune in value.toLowerCase().runes) {
      final folded = _foldCompatibilityRune(rune);
      if (folded == null) {
        continue;
      }
      if (folded.isEmpty) {
        needsSeparator = true;
        continue;
      }
      if (needsSeparator && buffer.isNotEmpty) {
        buffer.write(' ');
      }
      buffer.write(folded);
      needsSeparator = false;
    }
    return buffer.toString();
  }

  /// Returns a folded word fragment, an empty separator, or `null` for a
  /// combining mark. This is a small dependency-free NFKC-style fold that
  /// keeps scripts such as Cyrillic and accented Latin instead of dropping
  /// them (which previously caused cache-key collisions).
  static String? _foldCompatibilityRune(int rune) {
    if (_isCombiningMark(rune)) {
      return null;
    }
    if (rune == 0x3000) {
      return '';
    }
    if (rune >= 0xff01 && rune <= 0xff5e) {
      rune -= 0xfee0;
    }
    if (_isSeparatorOrSymbol(rune)) {
      return '';
    }

    final character = String.fromCharCode(rune);
    if ('àáâãäåāăąǎ'.contains(character)) return 'a';
    if ('çćĉč'.contains(character)) return 'c';
    if ('ďđ'.contains(character)) return 'd';
    if ('èéêëēĕėęě'.contains(character)) return 'e';
    if ('ĝğġģ'.contains(character)) return 'g';
    if ('ĥħ'.contains(character)) return 'h';
    if ('ìíîïĩīĭįı'.contains(character)) return 'i';
    if ('ĵ'.contains(character)) return 'j';
    if ('ķ'.contains(character)) return 'k';
    if ('ĺļľł'.contains(character)) return 'l';
    if ('ñńņň'.contains(character)) return 'n';
    if ('òóôõöøōŏő'.contains(character)) return 'o';
    if ('ŕŗř'.contains(character)) return 'r';
    if ('śŝşš'.contains(character)) return 's';
    if ('ťŧ'.contains(character)) return 't';
    if ('ùúûüũūŭůűų'.contains(character)) return 'u';
    if (character == 'ŵ') return 'w';
    if ('ýÿŷ'.contains(character)) return 'y';
    if ('źżž'.contains(character)) return 'z';
    return switch (character) {
      'æ' => 'ae',
      'œ' => 'oe',
      'ß' => 'ss',
      'ð' => 'd',
      'þ' => 'th',
      'ĳ' => 'ij',
      _ => character,
    };
  }

  static bool _isCombiningMark(int rune) {
    return (rune >= 0x0300 && rune <= 0x036f) ||
        (rune >= 0x1ab0 && rune <= 0x1aff) ||
        (rune >= 0x1dc0 && rune <= 0x1dff) ||
        (rune >= 0x20d0 && rune <= 0x20ff) ||
        (rune >= 0xfe20 && rune <= 0xfe2f);
  }

  static bool _isSeparatorOrSymbol(int rune) {
    return rune <= 0x2f ||
        (rune >= 0x3a && rune <= 0x60) ||
        (rune >= 0x7b && rune <= 0xbf) ||
        (rune >= 0x2000 && rune <= 0x2bff) ||
        (rune >= 0x3000 && rune <= 0x303f) ||
        rune == 0x30fb ||
        (rune >= 0xfe00 && rune <= 0xfe1f) ||
        (rune >= 0xfe30 && rune <= 0xfe4f) ||
        (rune >= 0xff00 && rune <= 0xff0f) ||
        (rune >= 0xff1a && rune <= 0xff20) ||
        (rune >= 0xff3b && rune <= 0xff40) ||
        (rune >= 0xff5b && rune <= 0xff65) ||
        (rune >= 0x1f000 && rune <= 0x1faff);
  }

  static int _levenshteinDistance(List<int> left, List<int> right) {
    if (left.isEmpty) {
      return right.length;
    }
    if (right.isEmpty) {
      return left.length;
    }
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var leftIndex = 0; leftIndex < left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = leftIndex + 1;
      for (var rightIndex = 0; rightIndex < right.length; rightIndex++) {
        final substitutionCost = left[leftIndex] == right[rightIndex] ? 0 : 1;
        final deletion = previous[rightIndex + 1] + 1;
        final insertion = current[rightIndex] + 1;
        final substitution = previous[rightIndex] + substitutionCost;
        current[rightIndex + 1] = [
          deletion,
          insertion,
          substitution,
        ].reduce((a, b) => a < b ? a : b);
      }
      previous = current;
    }
    return previous.last;
  }

  static double _bigramDice(List<int> left, List<int> right) {
    if (left.length < 2 || right.length < 2) {
      return 0;
    }
    final leftPairs = <String, int>{};
    for (var index = 0; index < left.length - 1; index++) {
      final key = '${left[index]}:${left[index + 1]}';
      leftPairs[key] = (leftPairs[key] ?? 0) + 1;
    }
    final rightPairs = <String, int>{};
    for (var index = 0; index < right.length - 1; index++) {
      final key = '${right[index]}:${right[index + 1]}';
      rightPairs[key] = (rightPairs[key] ?? 0) + 1;
    }
    var overlap = 0;
    for (final entry in leftPairs.entries) {
      final rightCount = rightPairs[entry.key] ?? 0;
      overlap += entry.value < rightCount ? entry.value : rightCount;
    }
    return 2 * overlap / ((left.length - 1) + (right.length - 1));
  }

  static bool _versionsAreCompatible(String expected, String actual) {
    final expectedTags = _versionTags(expected);
    final actualTags = _versionTags(actual);
    return expectedTags.length == actualTags.length &&
        expectedTags.containsAll(actualTags);
  }

  static Set<String> _versionTags(String value) {
    final words = _normalizeWords(
      value,
    ).split(' ').where((word) => word.isNotEmpty).toSet();
    final compact = _normalizeText(value);
    final tags = <String>{};
    if (words.any(const {'live', 'concert', 'concerts'}.contains) ||
        compact.contains(_normalizeText(_concert)) ||
        compact.contains(_normalizeText(_liveScene)) ||
        compact.contains('ライブ') ||
        compact.contains('ライヴ') ||
        compact.contains('ﾗｲﾌﾞ') ||
        compact.contains('라이브')) {
      tags.add('live');
    }
    if (words.any(const {'remix', 'remixed', 'mix'}.contains) ||
        compact.contains('混音') ||
        compact.contains('リミックス') ||
        compact.contains('ﾘﾐｯｸｽ') ||
        compact.contains('리믹스')) {
      tags.add('remix');
    }
    if (words.any(const {'instrumental', 'instrumentals'}.contains) ||
        compact.contains(_normalizeText(_accompaniment)) ||
        compact.contains('offvocal') ||
        compact.contains('インストゥルメンタル') ||
        compact.contains('ｲﾝｽﾄｩﾙﾒﾝﾀﾙ') ||
        compact.contains('인스트루멘탈')) {
      tags.add('instrumental');
    }
    if (words.contains('karaoke') ||
        compact.contains('卡拉ok') ||
        compact.contains('カラオケ') ||
        compact.contains('ｶﾗｵｹ') ||
        compact.contains('노래방')) {
      tags.add('karaoke');
    }
    if (words.any(const {'acoustic', 'unplugged'}.contains) ||
        compact.contains('不插电') ||
        compact.contains('アコースティック') ||
        compact.contains('ｱｺｰｽﾃｨｯｸ') ||
        compact.contains('어쿠스틱')) {
      tags.add('acoustic');
    }
    if (words.any(const {'remaster', 'remastered', 'remastering'}.contains) ||
        compact.contains('重制版') ||
        compact.contains('リマスター') ||
        compact.contains('ﾘﾏｽﾀｰ') ||
        compact.contains('리마스터')) {
      tags.add('remaster');
    }
    if (words.contains('demo') ||
        compact.contains('样带') ||
        compact.contains('デモ') ||
        compact.contains('ﾃﾞﾓ') ||
        compact.contains('데모')) {
      tags.add('demo');
    }
    if (words.contains('cover') ||
        compact.contains('翻唱') ||
        compact.contains('カバー') ||
        compact.contains('ｶﾊﾞｰ') ||
        compact.contains('커버')) {
      tags.add('cover');
    }
    if ((words.contains('sped') && words.contains('up')) ||
        compact.contains('加速') ||
        compact.contains('スピードアップ') ||
        compact.contains('ｽﾋﾟｰﾄﾞｱｯﾌﾟ') ||
        compact.contains('가속')) {
      tags.add('sped-up');
    }
    if (words.contains('slowed') ||
        compact.contains('降速') ||
        compact.contains('スロー') ||
        compact.contains('ｽﾛｰ') ||
        compact.contains('감속')) {
      tags.add('slowed');
    }
    if ((words.contains('radio') && words.contains('edit')) ||
        compact.contains('电台版')) {
      tags.add('radio-edit');
    }
    return tags;
  }

  static _SearchHint? _lyricTitleArtistHint(String? lyrics) {
    if (lyrics == null || lyrics.trim().isEmpty) {
      return null;
    }
    final lines = lyrics.split(RegExp(r'[\r\n]+'));
    String? taggedTitle;
    String? taggedArtist;
    for (final line in lines.take(30)) {
      final titleMatch = RegExp(
        r'^\s*\[ti:(.+)\]\s*$',
        caseSensitive: false,
      ).firstMatch(line);
      if (titleMatch != null) {
        taggedTitle = _cleanTitle(titleMatch.group(1) ?? '');
      }
      final artistMatch = RegExp(
        r'^\s*\[ar:(.+)\]\s*$',
        caseSensitive: false,
      ).firstMatch(line);
      if (artistMatch != null) {
        taggedArtist = _cleanArtist(artistMatch.group(1) ?? '');
      }
    }
    if (taggedTitle != null &&
        taggedTitle.isNotEmpty &&
        taggedArtist != null &&
        taggedArtist.isNotEmpty) {
      return _SearchHint(title: taggedTitle, artist: taggedArtist);
    }

    for (final line in lines.take(8)) {
      if (RegExp(r'^\s*\[\d{1,3}:\d{2}').hasMatch(line)) {
        continue;
      }
      final cleaned = line.replaceAll(RegExp(r'^\s*\[[^\]]+\]\s*'), '').trim();
      final separator = cleaned.indexOf(' - ');
      if (separator <= 0 || separator >= cleaned.length - 3) {
        continue;
      }
      return _SearchHint(
        title: _cleanTitle(cleaned.substring(0, separator)),
        artist: _cleanArtist(cleaned.substring(separator + 3)),
      );
    }
    return null;
  }
}

class AlbumMetadataNetworkException implements Exception {
  const AlbumMetadataNetworkException(this.source, this.cause);

  final String source;
  final Object cause;

  @override
  String toString() => '$source 元数据请求失败：$cause';
}

class _AlbumMetadataCancelled implements Exception {
  const _AlbumMetadataCancelled();
}

class AlbumMetadataMatch implements Comparable<AlbumMetadataMatch> {
  const AlbumMetadataMatch({
    required this.album,
    required this.recordingTitle,
    required this.recordingArtist,
    required this.score,
    this.recordingId,
    this.releaseId,
    this.releaseGroupId,
    this.releaseDate,
    this.titleSimilarity = 1,
    this.artistSimilarity = 1,
    this.durationVerified = false,
    this.versionCompatible = true,
    this.releasePreferred = true,
    this.hasCrossSourceAgreement = false,
  });

  final String album;
  final String recordingTitle;
  final String recordingArtist;
  final double score;
  final String? recordingId;
  final String? releaseId;
  final String? releaseGroupId;
  final String? releaseDate;
  final double titleSimilarity;
  final double artistSimilarity;
  final bool durationVerified;
  final bool versionCompatible;
  final bool releasePreferred;
  final bool hasCrossSourceAgreement;

  factory AlbumMetadataMatch.fromJson(Map<String, dynamic> json) {
    return AlbumMetadataMatch(
      album: json['album'] as String? ?? '',
      recordingTitle: json['recordingTitle'] as String? ?? '',
      recordingArtist: json['recordingArtist'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0,
      recordingId: json['recordingId'] as String?,
      releaseId: json['releaseId'] as String?,
      releaseGroupId: json['releaseGroupId'] as String?,
      releaseDate: json['releaseDate'] as String?,
      titleSimilarity: (json['titleSimilarity'] as num?)?.toDouble() ?? 1,
      artistSimilarity: (json['artistSimilarity'] as num?)?.toDouble() ?? 1,
      durationVerified: json['durationVerified'] as bool? ?? false,
      versionCompatible: json['versionCompatible'] as bool? ?? true,
      releasePreferred: json['releasePreferred'] as bool? ?? true,
      hasCrossSourceAgreement:
          json['hasCrossSourceAgreement'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'album': album,
      'recordingTitle': recordingTitle,
      'recordingArtist': recordingArtist,
      'score': score,
      'recordingId': recordingId,
      'releaseId': releaseId,
      'releaseGroupId': releaseGroupId,
      'releaseDate': releaseDate,
      'titleSimilarity': titleSimilarity,
      'artistSimilarity': artistSimilarity,
      'durationVerified': durationVerified,
      'versionCompatible': versionCompatible,
      'releasePreferred': releasePreferred,
      'hasCrossSourceAgreement': hasCrossSourceAgreement,
    };
  }

  bool get isApple =>
      (recordingId?.startsWith('apple:') ?? false) ||
      (releaseId?.startsWith('apple:') ?? false);

  String get sourceLabel => hasCrossSourceAgreement
      ? 'Apple iTunes + MusicBrainz'
      : isApple
      ? 'Apple iTunes'
      : 'MusicBrainz';

  AlbumMetadataMatch copyWith({
    bool? hasCrossSourceAgreement,
    bool? releasePreferred,
  }) {
    return AlbumMetadataMatch(
      album: album,
      recordingTitle: recordingTitle,
      recordingArtist: recordingArtist,
      score: score,
      recordingId: recordingId,
      releaseId: releaseId,
      releaseGroupId: releaseGroupId,
      releaseDate: releaseDate,
      titleSimilarity: titleSimilarity,
      artistSimilarity: artistSimilarity,
      durationVerified: durationVerified,
      versionCompatible: versionCompatible,
      releasePreferred: releasePreferred ?? this.releasePreferred,
      hasCrossSourceAgreement:
          hasCrossSourceAgreement ?? this.hasCrossSourceAgreement,
    );
  }

  @override
  int compareTo(AlbumMetadataMatch other) {
    final scoreCompare = other.score.compareTo(score);
    if (scoreCompare != 0) {
      return scoreCompare;
    }
    final dateCompare = _dateKey(
      releaseDate,
    ).compareTo(_dateKey(other.releaseDate));
    if (dateCompare != 0) {
      return dateCompare;
    }
    return album.compareTo(other.album);
  }

  static String _dateKey(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? '9999-99-99' : trimmed;
  }
}

class _SearchHint {
  const _SearchHint({required this.title, required this.artist});

  final String title;
  final String artist;
}
