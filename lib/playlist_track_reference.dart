/// Portable song identity. Paths are hints only; audio is never included.
class PlaylistTrackReference {
  const PlaylistTrackReference({
    required this.title,
    this.artist = '',
    this.album = '',
    this.sourceUrl = '',
    this.syncId = '',
    this.originalPath = '',
    this.durationMs,
    this.position = 0,
  });

  final String title;
  final String artist;
  final String album;
  final String sourceUrl;
  final String syncId;
  final String originalPath;
  final int? durationMs;
  final int position;

  PlaylistTrackReference atPosition(int value) => PlaylistTrackReference(
    title: title,
    artist: artist,
    album: album,
    sourceUrl: sourceUrl,
    syncId: syncId,
    originalPath: originalPath,
    durationMs: durationMs,
    position: value,
  );

  String get identityKey {
    if (syncId.isNotEmpty) return 'sync:$syncId';
    if (sourceUrl.isNotEmpty) return 'source:$sourceUrl';
    return 'song:${[title, artist, album, durationMs, originalPath].join('\u0000')}';
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'artist': artist,
    'album': album,
    'sourceUrl': sourceUrl,
    'syncId': syncId,
    'originalPath': originalPath,
    if (durationMs != null) 'durationMs': durationMs,
    'position': position,
  };

  factory PlaylistTrackReference.fromJson(Map<String, dynamic> json) {
    String field(String key) {
      final value = json[key];
      if (value == null) return '';
      if (value is! String || value.length > 8192) {
        throw const FormatException('歌单中的歌曲信息无效');
      }
      return value;
    }

    final title = field('title');
    if (title.trim().isEmpty) throw const FormatException('歌单中存在空歌曲名称');
    final duration = json['durationMs'];
    final position = json['position'] ?? 0;
    if ((duration != null && (duration is! int || duration < 0)) ||
        position is! int ||
        position < 0) {
      throw const FormatException('歌单中的歌曲时长或顺序无效');
    }
    return PlaylistTrackReference(
      title: title,
      artist: field('artist'),
      album: field('album'),
      sourceUrl: field('sourceUrl'),
      syncId: field('syncId'),
      originalPath: field('originalPath'),
      durationMs: duration as int?,
      position: position,
    );
  }
}
