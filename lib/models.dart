enum DownloadStatus { queued, downloading, paused, completed, failed, canceled }

enum RepeatMode { none, one, all }

enum LibrarySortMode { downloadedAtDesc, titleAsc, artistAsc }

class TrackSearchResult {
  const TrackSearchResult({
    required this.id,
    required this.title,
    required this.artist,
    required this.source,
    required this.detailUrl,
    this.duration,
    this.coverUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String source;
  final String detailUrl;
  final String? duration;
  final String? coverUrl;

  String get displayArtist => artist.trim().isEmpty ? '未知歌手' : artist;

  TrackSearchResult copyWith({
    String? id,
    String? title,
    String? artist,
    String? source,
    String? detailUrl,
    String? duration,
    String? coverUrl,
  }) {
    return TrackSearchResult(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      source: source ?? this.source,
      detailUrl: detailUrl ?? this.detailUrl,
      duration: duration ?? this.duration,
      coverUrl: coverUrl ?? this.coverUrl,
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
  });

  final String title;
  final String artist;
  final String sourceUrl;
  final List<AudioCandidate> candidates;
  final Map<String, String> rawMetadata;
  final String? lyrics;
  final String? coverUrl;
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
    this.lyrics,
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
  final String? lyrics;

  DownloadTask copyWith({
    DownloadStatus? status,
    double? progress,
    String? savePath,
    String? error,
    int? receivedBytes,
    int? totalBytes,
    String? lyrics,
  }) {
    return DownloadTask(
      id: id,
      track: track,
      candidate: candidate,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      savePath: savePath ?? this.savePath,
      error: error,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      lyrics: lyrics ?? this.lyrics,
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
      coverUrl: json['coverUrl'] as String?,
      coverFilePath: json['coverFilePath'] as String?,
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.downloadDirectory,
    this.preferredFormat = 'mp3',
    this.concurrentDownloads = 2,
    this.theme = 'lightGreen',
    this.volume = 100,
  });

  final String downloadDirectory;
  final String preferredFormat;
  final int concurrentDownloads;
  final String theme;
  final double volume;

  AppSettings copyWith({
    String? downloadDirectory,
    String? preferredFormat,
    int? concurrentDownloads,
    String? theme,
    double? volume,
  }) {
    return AppSettings(
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      preferredFormat: preferredFormat ?? this.preferredFormat,
      concurrentDownloads: concurrentDownloads ?? this.concurrentDownloads,
      theme: theme ?? this.theme,
      volume: volume ?? this.volume,
    );
  }

  Map<String, dynamic> toJson() => {
    'downloadDirectory': downloadDirectory,
    'preferredFormat': preferredFormat,
    'concurrentDownloads': concurrentDownloads,
    'theme': theme,
    'volume': volume,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      downloadDirectory: json['downloadDirectory'] as String,
      preferredFormat: json['preferredFormat'] as String? ?? 'mp3',
      concurrentDownloads: json['concurrentDownloads'] as int? ?? 2,
      theme: json['theme'] as String? ?? 'lightGreen',
      volume: (json['volume'] as num?)?.toDouble() ?? 100,
    );
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
    );
  }
}

class SavedPlayerQueue {
  const SavedPlayerQueue({
    required this.items,
    required this.currentIndex,
    this.shuffleEnabled = false,
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
      shuffleEnabled: json['shuffleEnabled'] as bool? ?? false,
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
