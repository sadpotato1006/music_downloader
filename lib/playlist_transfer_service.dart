import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'playlist_track_reference.dart';

class PortablePlaylist {
  const PortablePlaylist({required this.name, required this.tracks});
  final String name;
  final List<PlaylistTrackReference> tracks;
}

class PlaylistResolution {
  const PlaylistResolution(this.paths, this.pending);
  final List<String> paths;
  final List<PlaylistTrackReference> pending;
}

class PlaylistTransferService {
  static const maxFileBytes = 10 * 1024 * 1024;
  static const maxTracks = 50000;
  static const maxPlaylists = 1000;

  static String pathKey(String path) {
    final value = p.normalize(path.trim());
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  static PlaylistTrackReference reference(DownloadedTrack track) =>
      PlaylistTrackReference(
        title: track.title,
        artist: track.artist,
        album: track.album,
        sourceUrl: track.sourceUrl,
        syncId: track.syncId,
        originalPath: track.path,
        durationMs: track.durationMs,
      );

  static PortablePlaylist portable(
    MusicPlaylist playlist,
    List<DownloadedTrack> library,
  ) {
    final byPath = {for (final track in library) pathKey(track.path): track};
    PlaylistTrackReference forPath(String path) {
      final track = byPath[pathKey(path)];
      return track == null
          ? PlaylistTrackReference(
              title: p.posix.basename(path.replaceAll('\\', '/')),
              originalPath: path,
            )
          : reference(track);
    }

    final entries = <PlaylistTrackReference>[];
    var pathIndex = 0;
    for (final pending in playlist.pendingTracks) {
      while (entries.length < pending.position &&
          pathIndex < playlist.trackPaths.length) {
        entries.add(forPath(playlist.trackPaths[pathIndex++]));
      }
      entries.add(pending);
    }
    while (pathIndex < playlist.trackPaths.length) {
      entries.add(forPath(playlist.trackPaths[pathIndex++]));
    }
    return PortablePlaylist(name: playlist.name, tracks: entries);
  }

  static String encode(List<PortablePlaylist> playlists) {
    if (playlists.isEmpty ||
        playlists.length > maxPlaylists ||
        playlists.fold<int>(0, (n, item) => n + item.tracks.length) >
            maxTracks) {
      throw const FormatException('歌单数量或歌曲数量超出导出范围');
    }
    final content = jsonEncode({
      'format': 'qingting-playlists',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'playlists': [
        for (final playlist in playlists)
          {
            'name': playlist.name,
            'tracks': playlist.tracks.map((track) => track.toJson()).toList(),
          },
      ],
    });
    if (utf8.encode(content).length > maxFileBytes) {
      throw const FormatException('歌单文件超过 10 MiB，请分批导出');
    }
    return content;
  }

  static List<PortablePlaylist> decode(String content) {
    if (content.length > maxFileBytes ||
        utf8.encode(content).length > maxFileBytes) {
      throw const FormatException('歌单文件超过 10 MiB');
    }
    final json = jsonDecode(
      content.startsWith('\uFEFF') ? content.substring(1) : content,
    );
    if (json is! Map || json['format'] != 'qingting-playlists') {
      throw const FormatException('请选择青听导出的歌单文件');
    }
    if (json['version'] != 1) throw const FormatException('不支持此歌单文件版本');
    final lists = json['playlists'];
    if (lists is! List || lists.isEmpty || lists.length > maxPlaylists) {
      throw const FormatException('歌单文件内容无效');
    }
    var count = 0;
    return [
      for (final item in lists)
        (() {
          if (item is! Map ||
              item['name'] is! String ||
              (item['name'] as String).trim().isEmpty ||
              (item['name'] as String).length > 8192 ||
              item['tracks'] is! List) {
            throw const FormatException('歌单名称或歌曲列表无效');
          }
          final tracks = item['tracks'] as List;
          count += tracks.length;
          if (count > maxTracks) {
            throw const FormatException('单次最多导入 50000 首歌曲');
          }
          return PortablePlaylist(
            name: (item['name'] as String).trim(),
            tracks: [
              for (final track in tracks)
                if (track is Map)
                  PlaylistTrackReference.fromJson(
                    Map<String, dynamic>.from(track),
                  )
                else
                  throw const FormatException('歌单中的歌曲信息无效'),
            ],
          );
        })(),
    ];
  }
}

/// Index once per library snapshot. Ambiguous matches stay pending.
class PlaylistTrackMatcher {
  PlaylistTrackMatcher(List<DownloadedTrack> library) {
    for (final track in library) {
      _index(_paths, PlaylistTransferService.pathKey(track.path), track);
      _index(_syncIds, track.syncId, track);
      _index(_sources, track.sourceUrl, track);
      if (track.artist.trim().isNotEmpty) {
        _index(_songs, _songKey(track.title, track.artist), track);
      }
    }
  }
  final _paths = <String, List<DownloadedTrack>>{};
  final _syncIds = <String, List<DownloadedTrack>>{};
  final _sources = <String, List<DownloadedTrack>>{};
  final _songs = <String, List<DownloadedTrack>>{};

  static void _index(
    Map<String, List<DownloadedTrack>> index,
    String key,
    DownloadedTrack track,
  ) {
    if (key.isNotEmpty) (index[key] ??= []).add(track);
  }

  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static String _songKey(String title, String artist) =>
      '${_normalize(title)}\u0000${_normalize(artist)}';

  DownloadedTrack? match(PlaylistTrackReference ref) {
    final exact = _paths[PlaylistTransferService.pathKey(ref.originalPath)];
    if (exact?.length == 1 &&
        _songKey(exact!.single.title, exact.single.artist) ==
            _songKey(ref.title, ref.artist)) {
      return exact.single;
    }
    for (final candidates in [_syncIds[ref.syncId], _sources[ref.sourceUrl]]) {
      if (candidates == null || candidates.isEmpty) continue;
      var matches = candidates;
      if (matches.length > 1 && ref.album.trim().isNotEmpty) {
        matches = matches
            .where((t) => _normalize(t.album) == _normalize(ref.album))
            .toList();
      }
      if (ref.durationMs != null) {
        matches = matches
            .where(
              (t) =>
                  t.durationMs == null ||
                  (t.durationMs! - ref.durationMs!).abs() <= 2000,
            )
            .toList();
      }
      if (matches.length == 1) return matches.single;
      // A known identity with multiple versions must not fall back to a weaker hint.
      return null;
    }
    if (ref.artist.trim().isEmpty) return null;
    var matches =
        _songs[_songKey(ref.title, ref.artist)] ?? const <DownloadedTrack>[];
    if (ref.album.trim().isNotEmpty) {
      matches = matches
          .where(
            (track) =>
                track.album.trim().isEmpty ||
                _normalize(track.album) == _normalize(ref.album),
          )
          .toList();
    }
    if (ref.durationMs != null) {
      matches = matches
          .where(
            (track) =>
                track.durationMs == null ||
                (track.durationMs! - ref.durationMs!).abs() <= 2000,
          )
          .toList();
    }
    if (matches.length == 1) return matches.single;
    return null;
  }

  PlaylistResolution resolve(Iterable<PlaylistTrackReference> tracks) {
    final paths = <String>[];
    final pending = <PlaylistTrackReference>[];
    final seenPaths = <String>{};
    final seenPending = <String>{};
    var position = 0;
    for (final ref in tracks) {
      final track = match(ref);
      if (track != null) {
        if (!seenPaths.add(PlaylistTransferService.pathKey(track.path))) {
          continue;
        }
        paths.add(track.path);
      } else {
        if (!seenPending.add(ref.identityKey)) continue;
        pending.add(ref.atPosition(position));
      }
      position++;
    }
    return PlaylistResolution(paths, pending);
  }
}
