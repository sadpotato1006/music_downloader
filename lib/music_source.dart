import 'models.dart';

abstract class MusicSource {
  String get name;

  Future<List<TrackSearchResult>> search(String keyword, {int page = 1});

  Future<TrackDetail> loadDetail(TrackSearchResult result);

  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail);
}

abstract class DownloadMusicSource {
  Future<List<AudioCandidate>> resolveDownloadCandidates(TrackDetail detail);
}

abstract class DeferredDownloadMusicSource {
  Future<AudioCandidate> prepareDownloadCandidate(AudioCandidate candidate);
}

class MusicSourceException implements Exception {
  const MusicSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}
