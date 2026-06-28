enum DownloadStatus { queued, downloading, paused, completed, failed, canceled }

enum RepeatMode { none, one, all }

enum LibrarySortMode { downloadedAtDesc, titleAsc, artistAsc }

const defaultDesktopLyricsSettings = DesktopLyricsSettings();
const maxSearchHistoryItems = 12;

class TrackSearchResult {
  const TrackSearchResult({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    required this.detailUrl,
    this.duration,
    this.coverUrl,
    this.album = '',
  });

  final String id;
  final String title;
  final String artist;
  final String source;
  final String detailUrl;
  final String? duration;
  final String? coverUrl;
  final String album;

  String get displayArtist => artist.trim().isEmpty ? '未知歌手' : artist;

  TrackSearchResult copyWith({
    String? id,
    String? title,
    String? artist,
    String? source,
    String? detailUrl,
    String? duration,
    String? coverUrl,
    String? album,
  }) {
    return TrackSearchResult(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      source: source ?? this.source,
      detailUrl: detailUrl ?? this.detailUrl,
      duration: duration ?? this.duration,
      coverUrl: coverUrl ?? this.coverUrl,
      album: album ?? this.album,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'source': source,
    'detailUrl': detailUrl,
    'duration': duration,
    'coverUrl': coverUrl,
    'album': album,
  };

  factory TrackSearchResult.fromJson(Map<String, dynamic> json) {
    return TrackSearchResult(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String? ?? '',
      source: json['source'] as String? ?? '歌曲宝',
      detailUrl: json['detailUrl'] as String,
      duration: json['duration'] as String?,
      coverUrl: json['coverUrl'] as String?,
      album: json['album'] as String? ?? '',
    );
  }
}

class TrackDetail {
  const TrackDetail({
    required this.title,
    required this.artist,
    required this.sourceUrl,
    required this.candidates,
    required this.rawMetadata,
    this.lyrics,
    this.coverUrl,
    this.album = '',
  });

  final String title;
  final String artist;
  final String sourceUrl;
  final List<AudioCandidate> candidates;
  final Map<String, String> rawMetadata;
  final String? lyrics;
  final String? coverUrl;
  final String album;
}

class AudioCandidate {
  const AudioCandidate({
    required this.url,
    required this.format,
    this.qualityLabel,
    this.bitrate,
    this.sizeBytes,
    this.headers = const {},
  });

  final String url;
  final String format;
  final String? qualityLabel;
  final int? bitrate;
  final int? sizeBytes;
  final Map<String, String> headers;

  bool get isMp3 => format.toLowerCase() == 'mp3';

  Map<String, dynamic> toJson() => {
    'url': url,
    'format': format,
    'qualityLabel': qualityLabel,
    'bitrate': bitrate,
    'sizeBytes': sizeBytes,
    'headers': headers,
  };

  factory AudioCandidate.fromJson(Map<String, dynamic> json) {
    return AudioCandidate(
      url: json['url'] as String,
      format: json['format'] as String,
      qualityLabel: json['qualityLabel'] as String?,
      bitrate: json['bitrate'] as int?,
      sizeBytes: json['sizeBytes'] as int?,
      headers: Map<String, String>.from(json['headers'] as Map? ?? const {}),
    );
  }
}

class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.track,
    required this.candidate,
    required this.status,
    required this.progress,
    required this.savePath,
    this.error,
    this.receivedBytes = 0,
    this.totalBytes,
    this.resumeValidator,
    this.lyrics,
    this.album = '',
  });

  final String id;
  final TrackSearchResult track;
  final AudioCandidate candidate;
  final DownloadStatus status;
  final double progress;
  final String savePath;
  final String? error;
  final int receivedBytes;
  final int? totalBytes;
  final String? resumeValidator;
  final String? lyrics;
  final String album;

  DownloadTask copyWith({
    AudioCandidate? candidate,
    DownloadStatus? status,
    double? progress,
    String? savePath,
    String? error,
    int? receivedBytes,
    int? totalBytes,
    String? resumeValidator,
    String? lyrics,
    String? album,
  }) {
    return DownloadTask(
      id: id,
      track: track,
      candidate: candidate ?? this.candidate,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      savePath: savePath ?? this.savePath,
      error: error,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      resumeValidator: resumeValidator ?? this.resumeValidator,
      lyrics: lyrics ?? this.lyrics,
      album: album ?? this.album,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'track': track.toJson(),
    'candidate': candidate.toJson(),
    'status': status.name,
    'progress': progress,
    'savePath': savePath,
    'error': error,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'resumeValidator': resumeValidator,
    'lyrics': lyrics,
    'album': album,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final statusName = json['status'] as String?;
    final status = DownloadStatus.values.where(
      (value) => value.name == statusName,
    );
    return DownloadTask(
      id: json['id'] as String,
      track: TrackSearchResult.fromJson(
        Map<String, dynamic>.from(json['track'] as Map),
      ),
      candidate: AudioCandidate.fromJson(
        Map<String, dynamic>.from(json['candidate'] as Map),
      ),
      status: status.isEmpty ? DownloadStatus.paused : status.first,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      savePath: json['savePath'] as String,
      error: json['error'] as String?,
      receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt(),
      resumeValidator: json['resumeValidator'] as String?,
      lyrics: json['lyrics'] as String?,
      album: json['album'] as String? ?? '',
    );
  }
}

class DownloadedTrack {
  const DownloadedTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.path,
    required this.format,
    required this.downloadedAt,
    required this.sourceUrl,
    this.album = '',
    this.coverUrl,
    this.coverFilePath,
  });

  final String id;
  final String title;
  final String artist;
  final String path;
  final String format;
  final DateTime downloadedAt;
  final String sourceUrl;
  final String album;
  final String? coverUrl;
  final String? coverFilePath;

  DownloadedTrack copyWith({
    String? id,
    String? title,
    String? artist,
    String? path,
    String? format,
    DateTime? downloadedAt,
    String? sourceUrl,
    String? album,
    String? coverUrl,
    String? coverFilePath,
  }) {
    return DownloadedTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      path: path ?? this.path,
      format: format ?? this.format,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      album: album ?? this.album,
      coverUrl: coverUrl ?? this.coverUrl,
      coverFilePath: coverFilePath ?? this.coverFilePath,
    );
  }

  TrackSearchResult toTrackResult() {
    return TrackSearchResult(
      id: id,
      title: title,
      artist: artist,
      source: '本地',
      detailUrl: sourceUrl,
      coverUrl: coverUrl,
      album: album,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'path': path,
    'format': format,
    'downloadedAt': downloadedAt.toIso8601String(),
    'sourceUrl': sourceUrl,
    'album': album,
    'coverUrl': coverUrl,
    'coverFilePath': coverFilePath,
  };

  factory DownloadedTrack.fromJson(Map<String, dynamic> json) {
    return DownloadedTrack(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String? ?? '',
      path: json['path'] as String,
      format: json['format'] as String? ?? 'mp3',
      downloadedAt:
          DateTime.tryParse(json['downloadedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      sourceUrl: json['sourceUrl'] as String? ?? '',
      album: json['album'] as String? ?? '',
      coverUrl: json['coverUrl'] as String?,
      coverFilePath: json['coverFilePath'] as String?,
    );
  }
}

class MusicPlaylist {
  const MusicPlaylist({
    required this.id,
    required this.name,
    required this.trackPaths,
    required this.createdAt,
  });

  final String id;
  final String name;
  final List<String> trackPaths;
  final DateTime createdAt;

  MusicPlaylist copyWith({
    String? id,
    String? name,
    List<String>? trackPaths,
    DateTime? createdAt,
  }) {
    return MusicPlaylist(
      id: id ?? this.id,
      name: name ?? this.name,
      trackPaths: trackPaths ?? this.trackPaths,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'trackPaths': trackPaths,
    'createdAt': createdAt.toIso8601String(),
  };

  factory MusicPlaylist.fromJson(Map<String, dynamic> json) {
    return MusicPlaylist(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '未命名歌单',
      trackPaths: (json['trackPaths'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class RecentPlayback {
  const RecentPlayback({required this.trackPath, required this.playedAt});

  final String trackPath;
  final DateTime playedAt;

  Map<String, dynamic> toJson() => {
    'trackPath': trackPath,
    'playedAt': playedAt.toIso8601String(),
  };

  factory RecentPlayback.fromJson(Map<String, dynamic> json) {
    return RecentPlayback(
      trackPath: json['trackPath'] as String? ?? '',
      playedAt:
          DateTime.tryParse(json['playedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class MyMusicData {
  const MyMusicData({
    this.favoriteTrackPaths = const [],
    this.playlists = const [],
    this.recentPlaybacks = const [],
  });

  final List<String> favoriteTrackPaths;
  final List<MusicPlaylist> playlists;
  final List<RecentPlayback> recentPlaybacks;

  MyMusicData copyWith({
    List<String>? favoriteTrackPaths,
    List<MusicPlaylist>? playlists,
    List<RecentPlayback>? recentPlaybacks,
  }) {
    return MyMusicData(
      favoriteTrackPaths: favoriteTrackPaths ?? this.favoriteTrackPaths,
      playlists: playlists ?? this.playlists,
      recentPlaybacks: recentPlaybacks ?? this.recentPlaybacks,
    );
  }

  Map<String, dynamic> toJson() => {
    'favoriteTrackPaths': favoriteTrackPaths,
    'playlists': playlists.map((playlist) => playlist.toJson()).toList(),
    'recentPlaybacks': recentPlaybacks
        .map((playback) => playback.toJson())
        .toList(),
  };

  factory MyMusicData.fromJson(Map<String, dynamic> json) {
    final rawPlaylists =
        json['playlists'] as List<dynamic>? ?? const <dynamic>[];
    final rawRecent =
        json['recentPlaybacks'] as List<dynamic>? ?? const <dynamic>[];
    return MyMusicData(
      favoriteTrackPaths:
          (json['favoriteTrackPaths'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => item.toString())
              .where((item) => item.trim().isNotEmpty)
              .toList(),
      playlists: rawPlaylists
          .whereType<Map>()
          .map(
            (item) => MusicPlaylist.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((playlist) => playlist.id.trim().isNotEmpty)
          .toList(),
      recentPlaybacks: rawRecent
          .whereType<Map>()
          .map(
            (item) => RecentPlayback.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((playback) => playback.trackPath.trim().isNotEmpty)
          .toList(),
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.downloadDirectory,
    this.preferredFormat = 'mp3',
    this.concurrentDownloads = 1,
    this.theme = 'lightGreen',
    this.volume = 100,
    this.autoPlayOnStartup = false,
    this.defaultStartupPageIndex = 0,
    this.desktopLyrics = defaultDesktopLyricsSettings,
    this.sourceSearchHistory = const [],
    this.librarySearchHistory = const [],
  });

  final String downloadDirectory;
  final String preferredFormat;
  final int concurrentDownloads;
  final String theme;
  final double volume;
  final bool autoPlayOnStartup;
  final int defaultStartupPageIndex;
  final DesktopLyricsSettings desktopLyrics;
  final List<String> sourceSearchHistory;
  final List<String> librarySearchHistory;

  AppSettings copyWith({
    String? downloadDirectory,
    String? preferredFormat,
    int? concurrentDownloads,
    String? theme,
    double? volume,
    bool? autoPlayOnStartup,
    int? defaultStartupPageIndex,
    DesktopLyricsSettings? desktopLyrics,
    List<String>? sourceSearchHistory,
    List<String>? librarySearchHistory,
  }) {
    return AppSettings(
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      preferredFormat: preferredFormat ?? this.preferredFormat,
      concurrentDownloads: concurrentDownloads ?? this.concurrentDownloads,
      theme: theme ?? this.theme,
      volume: volume ?? this.volume,
      autoPlayOnStartup: autoPlayOnStartup ?? this.autoPlayOnStartup,
      defaultStartupPageIndex:
          defaultStartupPageIndex ?? this.defaultStartupPageIndex,
      desktopLyrics: desktopLyrics ?? this.desktopLyrics,
      sourceSearchHistory: normalizeSearchHistory(
        sourceSearchHistory ?? this.sourceSearchHistory,
      ),
      librarySearchHistory: normalizeSearchHistory(
        librarySearchHistory ?? this.librarySearchHistory,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'downloadDirectory': downloadDirectory,
    'preferredFormat': preferredFormat,
    'concurrentDownloads': concurrentDownloads,
    'theme': theme,
    'volume': volume,
    'autoPlayOnStartup': autoPlayOnStartup,
    'defaultStartupPageIndex': defaultStartupPageIndex,
    'desktopLyrics': desktopLyrics.toJson(),
    'sourceSearchHistory': sourceSearchHistory,
    'librarySearchHistory': librarySearchHistory,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final savedDefaultPage = json['defaultStartupPageIndex'] as int? ?? 0;
    final desktopLyricsJson = json['desktopLyrics'];
    return AppSettings(
      downloadDirectory: json['downloadDirectory'] as String,
      preferredFormat: json['preferredFormat'] as String? ?? 'mp3',
      concurrentDownloads: json['concurrentDownloads'] as int? ?? 1,
      theme: json['theme'] as String? ?? 'lightGreen',
      volume: (json['volume'] as num?)?.toDouble() ?? 100,
      autoPlayOnStartup: json['autoPlayOnStartup'] as bool? ?? false,
      defaultStartupPageIndex: savedDefaultPage == 2 ? 2 : 0,
      desktopLyrics: desktopLyricsJson is Map
          ? DesktopLyricsSettings.fromJson(
              Map<String, dynamic>.from(desktopLyricsJson),
            )
          : defaultDesktopLyricsSettings,
      sourceSearchHistory: normalizeSearchHistory(
        (json['sourceSearchHistory'] as List?)?.cast<Object?>(),
      ),
      librarySearchHistory: normalizeSearchHistory(
        (json['librarySearchHistory'] as List?)?.cast<Object?>(),
      ),
    );
  }
}

List<String> normalizeSearchHistory(Iterable<Object?>? values) {
  if (values == null) {
    return const [];
  }
  final normalized = <String>[];
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) {
      continue;
    }
    if (normalized.any((item) => item.toLowerCase() == text.toLowerCase())) {
      continue;
    }
    normalized.add(text);
    if (normalized.length >= maxSearchHistoryItems) {
      break;
    }
  }
  return List.unmodifiable(normalized);
}

class DesktopLyricsSettings {
  const DesktopLyricsSettings({
    this.enabled = false,
    this.fontSize = 22,
    this.colorValue = 0xFF4AA66A,
    this.horizontalPosition = 0.5,
    this.verticalPosition = 0.78,
    this.delayMilliseconds = 0,
    this.backgroundOpacity = 0.12,
    this.locked = false,
  });

  final bool enabled;
  final double fontSize;
  final int colorValue;
  final double horizontalPosition;
  final double verticalPosition;
  final int delayMilliseconds;
  final double backgroundOpacity;
  final bool locked;

  DesktopLyricsSettings copyWith({
    bool? enabled,
    double? fontSize,
    int? colorValue,
    double? horizontalPosition,
    double? verticalPosition,
    int? delayMilliseconds,
    double? backgroundOpacity,
    bool? locked,
  }) {
    return DesktopLyricsSettings(
      enabled: enabled ?? this.enabled,
      fontSize: _clampDouble(fontSize ?? this.fontSize, 14, 42),
      colorValue: colorValue ?? this.colorValue,
      horizontalPosition: _clampDouble(
        horizontalPosition ?? this.horizontalPosition,
        0.0,
        1.0,
      ),
      verticalPosition: _clampDouble(
        verticalPosition ?? this.verticalPosition,
        0.0,
        1.0,
      ),
      delayMilliseconds: (delayMilliseconds ?? this.delayMilliseconds).clamp(
        -3000,
        3000,
      ),
      backgroundOpacity: _clampDouble(
        backgroundOpacity ?? this.backgroundOpacity,
        0,
        0.45,
      ),
      locked: locked ?? this.locked,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'fontSize': fontSize,
    'colorValue': colorValue,
    'horizontalPosition': horizontalPosition,
    'verticalPosition': verticalPosition,
    'delayMilliseconds': delayMilliseconds,
    'backgroundOpacity': backgroundOpacity,
    'locked': locked,
  };

  factory DesktopLyricsSettings.fromJson(Map<String, dynamic> json) {
    return DesktopLyricsSettings(
      enabled: json['enabled'] as bool? ?? false,
      fontSize: _clampDouble(
        (json['fontSize'] as num?)?.toDouble() ?? 22,
        14,
        42,
      ),
      colorValue: json['colorValue'] as int? ?? 0xFF4AA66A,
      horizontalPosition: _clampDouble(
        (json['horizontalPosition'] as num?)?.toDouble() ?? 0.5,
        0.0,
        1.0,
      ),
      verticalPosition: _clampDouble(
        (json['verticalPosition'] as num?)?.toDouble() ?? 0.78,
        0.0,
        1.0,
      ),
      delayMilliseconds: (json['delayMilliseconds'] as int? ?? 0).clamp(
        -3000,
        3000,
      ),
      backgroundOpacity: _clampDouble(
        (json['backgroundOpacity'] as num?)?.toDouble() ?? 0.12,
        0,
        0.45,
      ),
      locked: json['locked'] as bool? ?? false,
    );
  }

  static double _clampDouble(double value, double min, double max) {
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}

class PlayerItem {
  const PlayerItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.uri,
    this.headers = const {},
    this.localPath,
    this.coverUrl,
    this.coverFilePath,
    this.lyrics,
    this.album = '',
  });

  final String id;
  final String title;
  final String artist;
  final String uri;
  final Map<String, String> headers;
  final String? localPath;
  final String? coverUrl;
  final String? coverFilePath;
  final String? lyrics;
  final String album;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'uri': uri,
    'headers': headers,
    'localPath': localPath,
    'coverUrl': coverUrl,
    'coverFilePath': coverFilePath,
    'lyrics': lyrics,
    'album': album,
  };

  factory PlayerItem.fromJson(Map<String, dynamic> json) {
    return PlayerItem(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String? ?? '',
      uri: json['uri'] as String,
      headers: Map<String, String>.from(json['headers'] as Map? ?? const {}),
      localPath: json['localPath'] as String?,
      coverUrl: json['coverUrl'] as String?,
      coverFilePath: json['coverFilePath'] as String?,
      lyrics: json['lyrics'] as String?,
      album: json['album'] as String? ?? '',
    );
  }

  PlayerItem copyWith({
    String? id,
    String? title,
    String? artist,
    String? uri,
    Map<String, String>? headers,
    String? localPath,
    String? coverUrl,
    String? coverFilePath,
    String? lyrics,
    String? album,
  }) {
    return PlayerItem(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      uri: uri ?? this.uri,
      headers: headers ?? this.headers,
      localPath: localPath ?? this.localPath,
      coverUrl: coverUrl ?? this.coverUrl,
      coverFilePath: coverFilePath ?? this.coverFilePath,
      lyrics: lyrics ?? this.lyrics,
      album: album ?? this.album,
    );
  }
}

class SavedPlayerQueue {
  const SavedPlayerQueue({
    required this.items,
    required this.currentIndex,
    this.shuffleEnabled = true,
  });

  final List<PlayerItem> items;
  final int currentIndex;
  final bool shuffleEnabled;

  int get normalizedCurrentIndex {
    if (items.isEmpty) {
      return -1;
    }
    return currentIndex.clamp(0, items.length - 1).toInt();
  }

  Map<String, dynamic> toJson() => {
    'items': items.map((item) => item.toJson()).toList(),
    'currentIndex': currentIndex,
    'shuffleEnabled': shuffleEnabled,
  };

  factory SavedPlayerQueue.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    final items = rawItems
        .whereType<Map>()
        .map((item) => PlayerItem.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final currentIndex = json['currentIndex'] as int? ?? -1;
    return SavedPlayerQueue(
      items: items,
      currentIndex: currentIndex,
      shuffleEnabled: json['shuffleEnabled'] as bool? ?? true,
    );
  }
}

class DownloadStartResult {
  const DownloadStartResult.started() : candidate = null, message = null;
  const DownloadStartResult.requiresConfirmation(this.candidate)
    : message = null;
  const DownloadStartResult.failed(this.message) : candidate = null;

  final AudioCandidate? candidate;
  final String? message;

  bool get didStart => candidate == null && message == null;
  bool get needsConfirmation => candidate != null;
  bool get didFail => message != null;
}
