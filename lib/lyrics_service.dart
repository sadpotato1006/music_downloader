import 'package:dio/dio.dart';

class LyricsService {
  static const double _maximumDurationDeltaSeconds = 4;

  LyricsService({Dio? dio, Uri? baseUri})
    : _baseUri = baseUri ?? Uri.parse('https://lrclib.net/'),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.json,
              headers: const {
                'Accept': 'application/json',
                'User-Agent':
                    'QingTing/1.3.1 (https://github.com/sadpotato1006/music_downloader)',
              },
            ),
          );

  final Dio _dio;
  final Uri _baseUri;

  Future<String?> findLyrics({
    required String title,
    required String artist,
    Duration? duration,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) {
      return null;
    }
    try {
      final uri = _baseUri
          .resolve('/api/search')
          .replace(
            queryParameters: {
              'track_name': trimmedTitle,
              if (artist.trim().isNotEmpty) 'artist_name': artist.trim(),
            },
          );
      final response = await _dio.getUri<dynamic>(uri);
      final raw = response.data;
      if (raw is! List) {
        return null;
      }
      final candidates = raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where((item) => item['instrumental'] != true)
          .where(
            (item) => _isReliableSynchronizedMatch(
              item,
              title: trimmedTitle,
              artist: artist,
              duration: duration,
            ),
          )
          .toList();
      if (candidates.isEmpty) {
        return null;
      }
      candidates.sort((a, b) {
        final durationCompare = _durationDelta(
          a,
          duration,
        ).compareTo(_durationDelta(b, duration));
        if (durationCompare != 0) {
          return durationCompare;
        }
        return _timestampCount(b).compareTo(_timestampCount(a));
      });
      final best = candidates.first;
      final synced = best['syncedLyrics']?.toString().trim();
      return synced == null || synced.isEmpty ? null : synced;
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _isReliableSynchronizedMatch(
    Map<String, dynamic> item, {
    required String title,
    required String artist,
    required Duration? duration,
  }) {
    final expectedTitle = _normalize(title);
    final expectedArtist = _normalize(artist);
    final candidateTitle = _normalize(
      item['trackName']?.toString() ?? item['name']?.toString() ?? '',
    );
    final candidateArtist = _normalize(item['artistName']?.toString() ?? '');
    if (expectedTitle.isEmpty || candidateTitle != expectedTitle) {
      return false;
    }
    if (expectedArtist.isNotEmpty &&
        !_artistMatches(expectedArtist, candidateArtist)) {
      return false;
    }
    if (duration != null &&
        _durationDelta(item, duration) > _maximumDurationDeltaSeconds) {
      return false;
    }
    final synced = item['syncedLyrics']?.toString().trim();
    if (synced == null || synced.isEmpty || _timestampCount(item) == 0) {
      return false;
    }
    return true;
  }

  bool _artistMatches(String expected, String candidate) {
    if (candidate == expected) {
      return true;
    }
    return candidate.contains(expected) &&
        candidate.length - expected.length <= 8;
  }

  double _durationDelta(Map<String, dynamic> item, Duration? expectedDuration) {
    if (expectedDuration == null) {
      return 0;
    }
    final candidateDuration = item['duration'];
    if (candidateDuration is! num || candidateDuration <= 0) {
      return double.infinity;
    }
    return (candidateDuration.toDouble() -
            expectedDuration.inMilliseconds / 1000)
        .abs();
  }

  int _timestampCount(Map<String, dynamic> item) {
    final synced = item['syncedLyrics']?.toString() ?? '';
    return RegExp(
      r'^\s*\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]',
      multiLine: true,
    ).allMatches(synced).length;
  }

  String _normalize(String value) {
    return value.toLowerCase().replaceAll(
      RegExp(
        r'[\s\-_.,，。!！?？:：;；/\\|()\[\]{}（）【】《》“”‘’·•~`@#$%^&*+=<>]+',
        unicode: true,
      ),
      '',
    );
  }
}
