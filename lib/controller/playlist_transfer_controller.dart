part of '../app_controller.dart';

class PlaylistImportRequest {
  const PlaylistImportRequest(this.playlist, {this.targetPlaylistId});
  final PortablePlaylist playlist;
  final String? targetPlaylistId;
}

class PlaylistImportResult {
  const PlaylistImportResult(this.playlists, this.matched, this.pending);
  final int playlists;
  final int matched;
  final int pending;
}

extension AppControllerPlaylistTransfer on AppController {
  String exportPlaylists({String? playlistId}) {
    return PlaylistTransferService.encode(
      portablePlaylists(playlistId: playlistId),
    );
  }

  List<PortablePlaylist> portablePlaylists({String? playlistId}) {
    final playlists = playlistId == null
        ? myMusic.playlists
        : [playlistById(playlistId) ?? (throw StateError('歌单已不存在'))];
    return [
      for (final playlist in playlists)
        PlaylistTransferService.portable(playlist, downloadedTracks),
    ];
  }

  Future<PlaylistImportResult> importPlaylists(
    List<PlaylistImportRequest> requests,
  ) async {
    if (_preparingToExit || isLibraryBatchRunning) {
      throw StateError('歌曲正在处理中，请稍后重试');
    }
    final before = myMusic;
    final playlists = [...before.playlists];
    final matcher = PlaylistTrackMatcher(downloadedTracks);
    var matched = 0;
    var pending = 0;
    final now = DateTime.now();
    for (var i = 0; i < requests.length; i++) {
      final request = requests[i];
      final index = playlists.indexWhere(
        (p) => p.id == request.targetPlaylistId,
      );
      if (request.targetPlaylistId != null && index == -1) {
        throw StateError('目标歌单已不存在');
      }
      final previous = index == -1 ? null : playlists[index];
      final resolution = matcher.resolve([
        if (previous != null)
          ...PlaylistTransferService.portable(
            previous,
            downloadedTracks,
          ).tracks,
        ...request.playlist.tracks,
      ]);
      var name = request.playlist.name;
      if (previous == null) {
        final names = playlists.map((p) => p.name.trim().toLowerCase()).toSet();
        for (var suffix = 2; names.contains(name.toLowerCase()); suffix++) {
          name = '${request.playlist.name} ($suffix)';
        }
      }
      final playlist = MusicPlaylist(
        id: previous?.id ?? 'playlist-${now.microsecondsSinceEpoch}-$i',
        name: previous?.name ?? name,
        createdAt: previous?.createdAt ?? now,
        trackPaths: resolution.paths,
        pendingTracks: resolution.pending,
      );
      if (index == -1) {
        playlists.add(playlist);
      } else {
        playlists[index] = playlist;
      }
    }
    // Report final counts once, even if several imports target the same playlist.
    final touched = <String>{};
    for (var i = 0; i < requests.length; i++) {
      touched.add(
        requests[i].targetPlaylistId ??
            'playlist-${now.microsecondsSinceEpoch}-$i',
      );
    }
    for (final playlist in playlists.where((p) => touched.contains(p.id))) {
      matched += playlist.trackPaths.length;
      pending += playlist.pendingTracks.length;
    }
    final next = before.copyWith(playlists: playlists);
    myMusic = next;
    final save = _saveMyMusic();
    final savedSnapshot = myMusic;
    try {
      await save;
    } catch (_) {
      if (identical(myMusic, savedSnapshot)) myMusic = before;
      _notify();
      rethrow;
    }
    globalMessage =
        '已导入 ${touched.length} 个歌单 · $matched 首已匹配'
        '${pending == 0 ? '' : ' · $pending 首待匹配'}';
    _notify();
    return PlaylistImportResult(touched.length, matched, pending);
  }

  bool _resolvePendingPlaylistTracks() {
    if (!myMusic.playlists.any((p) => p.pendingTracks.isNotEmpty)) return false;
    final matcher = PlaylistTrackMatcher(downloadedTracks);
    var changed = false;
    final playlists = [
      for (final playlist in myMusic.playlists)
        (() {
          if (playlist.pendingTracks.isEmpty ||
              !playlist.pendingTracks.any(
                (ref) => matcher.match(ref) != null,
              )) {
            return playlist;
          }
          final resolution = matcher.resolve(
            PlaylistTransferService.portable(playlist, downloadedTracks).tracks,
          );
          changed = true;
          return playlist.copyWith(
            trackPaths: resolution.paths,
            pendingTracks: resolution.pending,
          );
        })(),
    ];
    if (changed) myMusic = myMusic.copyWith(playlists: playlists);
    return changed;
  }
}
