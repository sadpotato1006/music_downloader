import 'album_metadata_service.dart';

class PendingAlbumMatch {
  PendingAlbumMatch({
    required this.trackId,
    required this.trackPath,
    required this.title,
    required this.artist,
    required List<AlbumMetadataMatch> candidates,
    this.automaticWrite = false,
    this.originalAlbum = '',
  }) : candidates = List<AlbumMetadataMatch>.unmodifiable(candidates);

  final String trackId;
  final String trackPath;
  final String title;
  final String artist;
  final List<AlbumMetadataMatch> candidates;
  final bool automaticWrite;
  final String originalAlbum;

  factory PendingAlbumMatch.fromJson(Map<String, dynamic> json) {
    final rawCandidates = json['candidates'];
    return PendingAlbumMatch(
      trackId: json['trackId'] as String? ?? '',
      trackPath: json['trackPath'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      automaticWrite: json['automaticWrite'] as bool? ?? false,
      originalAlbum: json['originalAlbum'] as String? ?? '',
      candidates: rawCandidates is List
          ? rawCandidates
                .whereType<Map>()
                .map(
                  (item) => AlbumMetadataMatch.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .where((candidate) => candidate.album.trim().isNotEmpty)
                .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'trackId': trackId,
      'trackPath': trackPath,
      'title': title,
      'artist': artist,
      'automaticWrite': automaticWrite,
      'originalAlbum': originalAlbum,
      'candidates': candidates.map((candidate) => candidate.toJson()).toList(),
    };
  }
}
