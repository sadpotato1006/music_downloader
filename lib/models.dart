enum DownloadStatus { queued, downloading, paused, completed, failed, canceled }

enum RepeatMode { none, one, all }

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
  });

  final String id;
  final String title;
  final String artist;
  final String path;
  final String format;
  final DateTime downloadedAt;
  final String sourceUrl;
  final String? coverUrl;

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
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.downloadDirectory,
    this.preferredFormat = 'mp3',
    this.concurrentDownloads = 2,
    this.theme = 'lightGreen',
  });

  final String downloadDirectory;
  final String preferredFormat;
  final int concurrentDownloads;
  final String theme;

  AppSettings copyWith({
    String? downloadDirectory,
    String? preferredFormat,
    int? concurrentDownloads,
    String? theme,
  }) {
    return AppSettings(
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      preferredFormat: preferredFormat ?? this.preferredFormat,
      concurrentDownloads: concurrentDownloads ?? this.concurrentDownloads,
      theme: theme ?? this.theme,
    );
  }

  Map<String, dynamic> toJson() => {
    'downloadDirectory': downloadDirectory,
    'preferredFormat': preferredFormat,
    'concurrentDownloads': concurrentDownloads,
    'theme': theme,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      downloadDirectory: json['downloadDirectory'] as String,
      preferredFormat: json['preferredFormat'] as String? ?? 'mp3',
      concurrentDownloads: json['concurrentDownloads'] as int? ?? 2,
      theme: json['theme'] as String? ?? 'lightGreen',
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
  });

  final String id;
  final String title;
  final String artist;
  final String uri;
  final Map<String, String> headers;
  final String? localPath;
  final String? coverUrl;
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
