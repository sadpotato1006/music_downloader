part of '../main.dart';

Future<void> _exportPlaylistFile(
  AppController controller, {
  String? playlistId,
  PlaylistFileService files = const PlaylistFileService(),
}) async {
  try {
    final name = playlistId == null
        ? '青听全部歌单'
        : controller.playlistById(playlistId)?.name ?? '青听歌单';
    final snapshot = controller.portablePlaylists(playlistId: playlistId);
    final entries = snapshot.fold<int>(
      0,
      (count, p) => count + 1 + p.tracks.length,
    );
    final content = entries >= StorageJsonCodec.backgroundEntryThreshold
        ? await compute(PlaylistTransferService.encode, snapshot)
        : PlaylistTransferService.encode(snapshot);
    if (await files.save(name, content)) {
      controller.showMessage('歌单已导出（不含歌曲音频）');
    }
  } catch (error) {
    controller.showMessage('导出歌单失败：$error');
  }
}

Future<List<PlaylistImportRequest>?> _choosePlaylistImport(
  BuildContext context,
  AppController controller,
  List<PortablePlaylist> playlists,
) {
  final targets = List<String>.filled(playlists.length, '');
  final matcher = PlaylistTrackMatcher(controller.downloadedTracks);
  final previews = playlists.map((p) => matcher.resolve(p.tracks)).toList();
  return showDialog<List<PlaylistImportRequest>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('导入歌单'),
        content: SizedBox(
          width: 460,
          height: (MediaQuery.sizeOf(context).height * 0.5).clamp(180, 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择新建歌单或合并目标。重复歌曲自动去重，新建时重名自动加序号。',
                style: TextStyle(color: _muted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: playlists.length,
                  separatorBuilder: (_, _) => const Divider(height: 24),
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    final preview = previews[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          playlist.name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '${preview.paths.length} 首已匹配 · ${preview.pending.length} 首待匹配',
                          style: const TextStyle(color: _muted, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: targets[index],
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: '导入到'),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('新建歌单'),
                            ),
                            for (final existing in controller.myMusic.playlists)
                              DropdownMenuItem(
                                value: existing.id,
                                child: Text(
                                  '合并到：${existing.name}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => targets[index] = value ?? ''),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '未匹配歌曲会保留；歌曲下载或扫描入库后自动重试匹配。',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [
              for (var i = 0; i < playlists.length; i++)
                PlaylistImportRequest(
                  playlists[i],
                  targetPlaylistId: targets[i].isEmpty ? null : targets[i],
                ),
            ]),
            child: const Text('导入'),
          ),
        ],
      ),
    ),
  );
}

void _showPendingPlaylistTracks(BuildContext context, MusicPlaylist playlist) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('待匹配的歌曲（${playlist.pendingTracks.length}）'),
      content: SizedBox(
        width: 460,
        height: (MediaQuery.sizeOf(context).height * 0.5).clamp(180, 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '这些歌曲尚未匹配到本地曲库；存在多个可能的版本时也会保留在这里。歌曲入库后自动重试匹配。',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: playlist.pendingTracks.length,
                itemBuilder: (_, index) {
                  final song = playlist.pendingTracks[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.music_note_outlined),
                    title: Text(song.title),
                    subtitle: Text(
                      [
                        song.artist,
                        song.album,
                      ].where((s) => s.isNotEmpty).join(' · '),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
