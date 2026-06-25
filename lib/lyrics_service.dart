import 'package:dio/dio.dart';

class LyricsService {
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
                    'QingTing/1.3 (https://github.com/sadpotato1006/music_downloader)',
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
          .toList();
      if (candidates.isEmpty) {
        return null;
      }
      candidates.sort(
        (a, b) =>
            _score(
              b,
              title: trimmedTitle,
              artist: artist,
              duration: duration,
            ).compareTo(
              _score(
                a,
                title: trimmedTitle,
                artist: artist,
                duration: duration,
              ),
            ),
      );
      final best = candidates.first;
      final synced = best['syncedLyrics']?.toString().trim();
      if (synced != null && synced.isNotEmpty) {
        return synced;
      }
      final plain = best['plainLyrics']?.toString().trim();
      return plain == null || plain.isEmpty ? null : plain;
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }

  int _score(
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
    var score = 0;
    if (candidateTitle == expectedTitle) {
      score += 8;
    } else if (candidateTitle.contains(expectedTitle) ||
        expectedTitle.contains(candidateTitle)) {
      score += 3;
    }
    if (expectedArtist.isNotEmpty && candidateArtist == expectedArtist) {
      score += 7;
    } else if (expectedArtist.isNotEmpty &&
        (candidateArtist.contains(expectedArtist) ||
            expectedArtist.contains(candidateArtist))) {
      score += 2;
    }
    final candidateSeconds = (item['duration'] as num?)?.round();
    if (duration != null && candidateSeconds != null) {
      final delta = (candidateSeconds - duration.inSeconds).abs();
      if (delta <= 3) {
        score += 4;
      } else if (delta <= 10) {
        score += 1;
      }
    }
    final synced = item['syncedLyrics']?.toString().trim();
    if (synced != null && synced.isNotEmpty) {
      score += 2;
    }
    return score;
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
