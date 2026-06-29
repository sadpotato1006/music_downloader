import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

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
  }) : _dio = dio ?? Dio(),
       _appleDio = appleDio ?? dio ?? Dio(),
       _baseUri = baseUri ?? Uri.parse('https://musicbrainz.org/ws/2/'),
       _appleBaseUri = appleBaseUri ?? Uri.parse('https://itunes.apple.com/');

  final Dio _dio;
  final Dio _appleDio;
  final Uri _baseUri;
  final Uri _appleBaseUri;
  final Duration requestGap;
  final Duration appleRequestGap;
  final String appleCountry;
  Future<void> _requestQueue = Future<void>.value();
  Future<void> _appleRequestQueue = Future<void>.value();
  DateTime? _lastRequestAt;
  DateTime? _lastAppleRequestAt;
  final Map<String, List<AlbumMetadataMatch>> _appleCandidateCache = {};

  static const _userAgent =
      'QingTing/1.3.3 (https://github.com/sadpotato1006/music_downloader)';
  static const highConfidenceScore = 72.0;
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
    Duration? duration,
  }) async {
    final candidates = await findAlbumCandidates(
      title: title,
      artist: artist,
      lyrics: lyrics,
      duration: duration,
      limit: 1,
    );
    if (candidates.isEmpty || candidates.first.score < highConfidenceScore) {
      return null;
    }
    return candidates.first;
  }

  Future<List<AlbumMetadataMatch>> findAlbumCandidates({
    required String title,
    required String artist,
    String? lyrics,
    Duration? duration,
    int limit = 5,
  }) async {
    final cleanedTitle = _cleanTitle(title);
    final cleanedArtist = _cleanArtist(artist);
    if (cleanedTitle.isEmpty) {
      return const [];
    }

    final appleCandidates = await _findAppleCandidates(
      title: cleanedTitle,
      artist: cleanedArtist,
      duration: duration,
    );
    if (appleCandidates.isNotEmpty &&
        appleCandidates.first.score >= highConfidenceScore) {
      AppLog.instance.info(
        'album',
        'Apple iTunes 专辑匹配成功',
        detail:
            '$cleanedTitle → ${appleCandidates.first.album} '
            '(${appleCandidates.first.score.toStringAsFixed(1)})',
      );
      return appleCandidates.take(limit).toList();
    }

    AppLog.instance.info(
      'album',
      'Apple 无可靠专辑结果，切换 MusicBrainz',
      detail: cleanedTitle,
    );

    final lyricHint = _lyricTitleArtistHint(lyrics);
    final queries = <_SearchHint>[
      _SearchHint(title: cleanedTitle, artist: cleanedArtist),
      if (lyricHint != null &&
          (lyricHint.title != cleanedTitle ||
              lyricHint.artist != cleanedArtist))
        lyricHint,
      _SearchHint(title: cleanedTitle, artist: ''),
    ];

    final candidatesByAlbum = <String, AlbumMetadataMatch>{
      for (final candidate in appleCandidates)
        _normalizeText('${candidate.album}\n${candidate.recordingArtist}'):
            candidate,
    };
    final searched = <String>{};
    for (final query in queries) {
      final key = '${query.title}\n${query.artist}';
      if (!searched.add(key)) {
        continue;
      }

      final recordings = await _searchRecordings(query);
      for (var recording in recordings.take(5)) {
        if (_releases(recording).isEmpty) {
          final lookup = await _lookupRecording(recording['id'] as String?);
          if (lookup != null) {
            recording = lookup;
          }
        }

        for (final release in _releases(recording)) {
          final candidate = _matchFromRecordingRelease(
            recording,
            release,
            title: cleanedTitle,
            artist: cleanedArtist,
          );
          if (candidate == null) {
            continue;
          }
          final key = _normalizeText(
            '${candidate.album}\n${candidate.recordingArtist}',
          );
          final existing = candidatesByAlbum[key];
          if (existing == null || candidate.compareTo(existing) < 0) {
            candidatesByAlbum[key] = candidate;
          }
        }
      }

      final best = _bestCandidate(candidatesByAlbum.values);
      if (best != null && best.score >= 90) {
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
      AppLog.instance.warning('album', '未找到专辑候选', detail: cleanedTitle);
    }
    return candidates.take(limit).toList();
  }

  Future<List<AlbumMetadataMatch>> _findAppleCandidates({
    required String title,
    required String artist,
    required Duration? duration,
  }) async {
    final cacheKey = [
      _normalizeText(title),
      _normalizeText(artist),
      duration?.inSeconds ?? -1,
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
    });
    final results = data?['results'];
    if (results is! List) {
      if (data != null) {
        _appleCandidateCache[cacheKey] = const [];
        if (_appleCandidateCache.length > _appleCacheLimit) {
          _appleCandidateCache.remove(_appleCandidateCache.keys.first);
        }
      }
      return const [];
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
      final key = _normalizeText(
        '${candidate.album}\n${candidate.recordingArtist}',
      );
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

  Future<Map<String, dynamic>?> _getAppleJson(Map<String, String> query) {
    return _enqueueAppleRequest(() async {
      final uri = _appleBaseUri
          .resolve('/search')
          .replace(queryParameters: query);
      try {
        final response = await _appleDio.getUri<Object?>(
          uri,
          options: Options(
            receiveTimeout: const Duration(seconds: 10),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': _userAgent,
            },
          ),
        );
        Object? data = response.data;
        if (data is String) {
          try {
            data = jsonDecode(data);
          } on FormatException catch (error) {
            AppLog.instance.warning('album', 'Apple 返回了无法解析的数据', detail: error);
            return null;
          }
        }
        if (data is Map<String, dynamic>) {
          return data;
        }
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      } on DioException catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'Apple iTunes 请求失败',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      } catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'Apple iTunes 响应处理失败',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
      return null;
    });
  }

  Future<List<Map<String, dynamic>>> _searchRecordings(_SearchHint hint) async {
    final query = hint.artist.isEmpty
        ? 'recording:"${_escapeQuery(hint.title)}"'
        : 'recording:"${_escapeQuery(hint.title)}" AND '
              'artist:"${_escapeQuery(hint.artist)}"';
    final data = await _getJson('recording', {
      'query': query,
      'fmt': 'json',
      'limit': '10',
      'inc': 'releases+artist-credits+release-groups',
    });
    final recordings = data?['recordings'];
    if (recordings is! List) {
      return const [];
    }
    return recordings
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<Map<String, dynamic>?> _lookupRecording(String? id) async {
    if (id == null || id.trim().isEmpty) {
      return null;
    }
    final data = await _getJson('recording/$id', {
      'fmt': 'json',
      'inc': 'releases+artist-credits+release-groups',
    });
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>?> _getJson(
    String path,
    Map<String, String> query,
  ) {
    return _enqueueRequest(() async {
      final uri = _baseUri.resolve(path).replace(queryParameters: query);
      try {
        final response = await _dio.getUri<Object?>(
          uri,
          options: Options(
            receiveTimeout: const Duration(seconds: 10),
            headers: const {
              'Accept': 'application/json',
              'User-Agent': _userAgent,
            },
          ),
        );
        final data = response.data;
        if (data is Map<String, dynamic>) {
          return data;
        }
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      } on DioException catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'MusicBrainz 请求失败',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      } catch (error, stackTrace) {
        AppLog.instance.error(
          'album',
          'MusicBrainz 响应处理失败',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
      return null;
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
        ? 0.7
        : [
            _textSimilarity(artist, recordingArtist),
            _textSimilarity(artist, collectionArtist),
          ].reduce((a, b) => a > b ? a : b);
    if (titleScore < 0.72 || artistScore < 0.48) {
      return null;
    }

    var durationScore = duration == null ? 0.72 : 0.4;
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
    }

    var score = titleScore * 42 + artistScore * 34 + durationScore * 20;
    final normalizedVersion = _normalizeText('$recordingTitle\n$album');
    if (normalizedVersion.contains('karaoke') ||
        normalizedVersion.contains('instrumental') ||
        normalizedVersion.contains(_normalizeText(_accompaniment))) {
      score -= 12;
    }
    if (normalizedVersion.contains('live') ||
        normalizedVersion.contains(_normalizeText(_concert)) ||
        normalizedVersion.contains(_normalizeText(_liveScene))) {
      score -= 9;
    }

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
      score: score.clamp(0, 100).toDouble(),
    );
  }

  AlbumMetadataMatch? _matchFromRecordingRelease(
    Map<String, dynamic> recording,
    Map<String, dynamic> release, {
    required String title,
    required String artist,
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
        ? 0.7
        : [
            _textSimilarity(artist, recordingArtist),
            _textSimilarity(artist, releaseArtist),
          ].reduce((a, b) => a > b ? a : b);
    if (titleScore < 0.72 || artistScore < 0.48) {
      return null;
    }

    var score = musicBrainzScore * 0.35 + titleScore * 34 + artistScore * 28;
    if (status == 'official') {
      score += 8;
    }
    score += switch (primaryType) {
      'album' => 12,
      'ep' => 10,
      'single' => 7,
      'broadcast' => -8,
      _ => 2,
    };
    if (secondaryTypes.contains('soundtrack')) {
      score += 4;
    }
    if (secondaryTypes.contains('compilation')) {
      score -= 10;
    }
    if (_looksLikeVariousArtists(releaseArtist)) {
      score -= 8;
    }

    final normalizedAlbum = _normalizeText(album);
    if (normalizedAlbum.contains('karaoke') ||
        normalizedAlbum.contains('instrumental') ||
        normalizedAlbum.contains(_normalizeText(_accompaniment))) {
      score -= 12;
    }
    if (normalizedAlbum.contains('live') ||
        normalizedAlbum.contains(_normalizeText(_concert)) ||
        normalizedAlbum.contains(_normalizeText(_liveScene))) {
      score -= 7;
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
      score: score.clamp(0, 100).toDouble(),
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

  static AlbumMetadataMatch? _bestCandidate(
    Iterable<AlbumMetadataMatch> candidates,
  ) {
    AlbumMetadataMatch? best;
    for (final candidate in candidates) {
      if (best == null || candidate.compareTo(best) < 0) {
        best = candidate;
      }
    }
    return best;
  }

  static String _cleanTitle(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(
          RegExp(
            '\\s*[（(](?:mp3|flac|$_accompaniment)[）)]\\s*\$',
            caseSensitive: false,
          ),
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
      return 0.86;
    }
    final leftUnits = left.runes.toSet();
    final rightUnits = right.runes.toSet();
    final overlap = leftUnits.intersection(rightUnits).length;
    final longest = leftUnits.length > rightUnits.length
        ? leftUnits.length
        : rightUnits.length;
    return longest == 0 ? 0 : overlap / longest;
  }

  static String _normalizeText(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      if (_isSearchableRune(rune)) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static bool _isSearchableRune(int rune) {
    return (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x61 && rune <= 0x7a) ||
        (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x4e00 && rune <= 0x9fff) ||
        (rune >= 0xac00 && rune <= 0xd7af) ||
        (rune >= 0x3040 && rune <= 0x30ff);
  }

  static _SearchHint? _lyricTitleArtistHint(String? lyrics) {
    if (lyrics == null || lyrics.trim().isEmpty) {
      return null;
    }
    for (final line in lyrics.split(RegExp(r'[\r\n]+')).take(8)) {
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
  });

  final String album;
  final String recordingTitle;
  final String recordingArtist;
  final double score;
  final String? recordingId;
  final String? releaseId;
  final String? releaseGroupId;
  final String? releaseDate;

  bool get isApple =>
      (recordingId?.startsWith('apple:') ?? false) ||
      (releaseId?.startsWith('apple:') ?? false);

  String get sourceLabel => isApple ? 'Apple iTunes' : 'MusicBrainz';

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
