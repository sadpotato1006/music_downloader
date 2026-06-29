part of '../main.dart';

enum _LibrarySection { all, favorites, playlists, recent }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  AppController get controller => widget.controller;
  _LibrarySection section = _LibrarySection.all;

  Future<void> _showLibrarySearch() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: false,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height),
      builder: (context) => _LibrarySearchSheet(controller: controller),
    );
    if (value == null || !mounted) {
      return;
    }
    controller.commitLibrarySearch(value);
    setState(() {});
  }

  Future<void> _createPlaylist() async {
    final name = await _showPlaylistNameDialog(context, title: '新建歌单');
    if (name != null && mounted) {
      await controller.createPlaylist(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = switch (section) {
      _LibrarySection.all => controller.visibleDownloadedTracks,
      _LibrarySection.favorites => controller.favoriteTracks,
      _LibrarySection.recent => controller.recentTracks,
      _LibrarySection.playlists => const <DownloadedTrack>[],
    };
    final emptyText = switch (section) {
      _LibrarySection.all =>
        controller.downloadedTracks.isEmpty ? '下载完成后会出现在这里' : '没有匹配的本地歌曲',
      _LibrarySection.favorites => '还没有喜欢的歌曲',
      _LibrarySection.recent => '还没有最近播放记录',
      _LibrarySection.playlists => '还没有创建歌单',
    };
    final emptyIcon = switch (section) {
      _LibrarySection.all =>
        controller.downloadedTracks.isEmpty
            ? Icons.library_music
            : Icons.search_off,
      _LibrarySection.favorites => Icons.favorite_border,
      _LibrarySection.recent => Icons.history,
      _LibrarySection.playlists => Icons.queue_music,
    };

    return _PageFrame(
      horizontalPadding: 18,
      child: Column(
        children: [
          _LibrarySectionPicker(
            selected: section,
            onSelected: (value) => setState(() => section = value),
          ),
          const SizedBox(height: 10),
          switch (section) {
            _LibrarySection.all => _LibraryToolbar(
              controller: controller,
              onSearch: _showLibrarySearch,
            ),
            _LibrarySection.favorites => _LibraryCollectionToolbar(
              controller: controller,
              tracks: tracks,
              label: '我喜欢 · ${tracks.length} 首',
            ),
            _LibrarySection.recent => _LibraryCollectionToolbar(
              controller: controller,
              tracks: tracks,
              label: '最近播放 · ${tracks.length} 首',
              onClear: tracks.isEmpty ? null : controller.clearRecentPlaybacks,
            ),
            _LibrarySection.playlists => _PlaylistToolbar(
              count: controller.myMusic.playlists.length,
              onCreate: _createPlaylist,
            ),
          },
          const SizedBox(height: 8),
          Expanded(
            child: section == _LibrarySection.playlists
                ? _PlaylistOverview(
                    controller: controller,
                    onCreate: _createPlaylist,
                  )
                : _LibraryTrackList(
                    controller: controller,
                    tracks: tracks,
                    emptyIcon: emptyIcon,
                    emptyText: emptyText,
                  ),
          ),
        ],
      ),
    );
  }
}

class _LibrarySectionPicker extends StatelessWidget {
  const _LibrarySectionPicker({
    required this.selected,
    required this.onSelected,
  });

  final _LibrarySection selected;
  final ValueChanged<_LibrarySection> onSelected;

  @override
  Widget build(BuildContext context) {
    const entries = [
      (_LibrarySection.all, Icons.library_music, '全部'),
      (_LibrarySection.favorites, Icons.favorite, '我喜欢'),
      (_LibrarySection.playlists, Icons.queue_music, '歌单'),
      (_LibrarySection.recent, Icons.history, '最近'),
    ];
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ChoiceChip(
            selected: selected == entry.$1,
            onSelected: (_) => onSelected(entry.$1),
            avatar: Icon(entry.$2, size: 17),
            label: Text(entry.$3),
            showCheckmark: false,
          );
        },
      ),
    );
  }
}

class _LibraryTrackList extends StatelessWidget {
  const _LibraryTrackList({
    required this.controller,
    required this.tracks,
    required this.emptyIcon,
    required this.emptyText,
  });

  final AppController controller;
  final List<DownloadedTrack> tracks;
  final IconData emptyIcon;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return _EmptyState(icon: emptyIcon, text: emptyText);
    }
    return _ResponsiveTrackList(
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        final artist = track.artist.isEmpty ? '未知歌手' : track.artist;
        final album = track.album.trim().isEmpty ? '未知专辑' : track.album.trim();
        return TrackTile(
          title: track.title,
          subtitle: '$artist  ·  $album',
          coverFilePath: track.coverFilePath,
          artworkSize: 48,
          titleWeight: FontWeight.w400,
          titleSize: 15.5,
          subtitleSize: 13.2,
          onTap: () => controller.playDownloaded(track),
          trailing: [
            _IconAction(
              tooltip: '下一首播放',
              icon: controller.preparingQueueNextId == track.id
                  ? Icons.more_horiz
                  : Icons.playlist_add,
              onPressed: controller.preparingQueueNextId == track.id
                  ? null
                  : () => controller.queueDownloadedNext(track),
              size: 28,
            ),
            _LibraryMoreActions(controller: controller, track: track),
          ],
        );
      },
    );
  }
}

class _LibraryCollectionToolbar extends StatelessWidget {
  const _LibraryCollectionToolbar({
    required this.controller,
    required this.tracks,
    required this.label,
    this.onClear,
  });

  final AppController controller;
  final List<DownloadedTrack> tracks;
  final String label;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: tracks.isEmpty
                ? null
                : () => controller.playDownloadedCollection(tracks),
            icon: const Icon(Icons.play_arrow),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(width: 6),
        _CompactIconButton(
          tooltip: '随机播放',
          icon: Icons.shuffle,
          onPressed: tracks.isEmpty
              ? null
              : () =>
                    controller.playDownloadedCollection(tracks, shuffle: true),
        ),
        if (onClear != null) ...[
          const SizedBox(width: 6),
          _CompactIconButton(
            tooltip: '清空最近播放',
            icon: Icons.delete_sweep_outlined,
            onPressed: onClear,
          ),
        ],
      ],
    );
  }
}

class _PlaylistToolbar extends StatelessWidget {
  const _PlaylistToolbar({required this.count, required this.onCreate});

  final int count;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '$count 个歌单',
            style: const TextStyle(fontWeight: FontWeight.w700, color: _muted),
          ),
        ),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('新建歌单'),
        ),
      ],
    );
  }
}

class _PlaylistOverview extends StatelessWidget {
  const _PlaylistOverview({required this.controller, required this.onCreate});

  final AppController controller;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final playlists = controller.myMusic.playlists;
    if (playlists.isEmpty) {
      return _EmptyState(
        icon: Icons.queue_music,
        text: '还没有创建歌单',
        actionLabel: '新建歌单',
        onAction: onCreate,
      );
    }
    return ListView.separated(
      itemCount: playlists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        final count = controller.tracksForPlaylist(playlist.id).length;
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: _line),
            ),
            leading: const _LeadingIconShell(
              size: 48,
              borderRadius: 14,
              child: Icon(Icons.queue_music, color: _accentStrong),
            ),
            title: Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text('$count 首歌曲'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPlaylistSheet(context, controller, playlist.id),
          ),
        );
      },
    );
  }
}

Future<String?> _showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
}) async {
  final textController = TextEditingController(text: initialValue);
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLength: 40,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) {
              Navigator.pop(context, trimmed);
            }
          },
          decoration: const InputDecoration(
            labelText: '歌单名称',
            prefixIcon: Icon(Icons.queue_music),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = textController.text.trim();
              if (trimmed.isNotEmpty) {
                Navigator.pop(context, trimmed);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  } finally {
    textController.dispose();
  }
}

void _showPlaylistSheet(
  BuildContext context,
  AppController controller,
  String playlistId,
) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) =>
        _PlaylistSheet(controller: controller, playlistId: playlistId),
  );
}

void _showAddToPlaylistSheet(
  BuildContext context,
  AppController controller,
  DownloadedTrack track,
) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) =>
        _AddToPlaylistSheet(controller: controller, track: track),
  );
}

class _PlaylistSheet extends StatefulWidget {
  const _PlaylistSheet({required this.controller, required this.playlistId});

  final AppController controller;
  final String playlistId;

  @override
  State<_PlaylistSheet> createState() => _PlaylistSheetState();
}

class _PlaylistSheetState extends State<_PlaylistSheet> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _rename(MusicPlaylist playlist) async {
    final name = await _showPlaylistNameDialog(
      context,
      title: '重命名歌单',
      initialValue: playlist.name,
    );
    if (name != null && mounted) {
      await widget.controller.renamePlaylist(playlist.id, name);
    }
  }

  Future<void> _delete(MusicPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除歌单？'),
        content: Text('将删除歌单“${playlist.name}”，歌曲文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    Navigator.pop(context);
    await widget.controller.deletePlaylist(playlist.id);
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.controller.playlistById(widget.playlistId);
    if (playlist == null) {
      return const SizedBox.shrink();
    }
    final tracks = widget.controller.tracksForPlaylist(playlist.id);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: _line,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${tracks.length} 首歌曲',
                        style: const TextStyle(color: _muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '歌单设置',
                  onSelected: (value) {
                    if (value == 'rename') {
                      unawaited(_rename(playlist));
                    } else if (value == 'delete') {
                      unawaited(_delete(playlist));
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除歌单')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: tracks.isEmpty
                        ? null
                        : () => widget.controller.playDownloadedCollection(
                            tracks,
                          ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('播放全部'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: tracks.isEmpty
                      ? null
                      : () => widget.controller.playDownloadedCollection(
                          tracks,
                          shuffle: true,
                        ),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('随机'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: tracks.isEmpty
                  ? const _EmptyState(
                      icon: Icons.playlist_add,
                      text: '从本地歌曲菜单中加入歌曲',
                    )
                  : ListView.separated(
                      itemCount: tracks.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        final artist = track.artist.trim().isEmpty
                            ? '未知歌手'
                            : track.artist.trim();
                        return TrackTile(
                          title: track.title,
                          subtitle: artist,
                          coverFilePath: track.coverFilePath,
                          onTap: () => widget.controller.playDownloaded(track),
                          trailing: [
                            _IconAction(
                              tooltip: '从歌单移除',
                              icon: Icons.remove_circle_outline,
                              onPressed: () =>
                                  widget.controller.setTrackInPlaylist(
                                    playlist.id,
                                    track,
                                    included: false,
                                  ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddToPlaylistSheet extends StatefulWidget {
  const _AddToPlaylistSheet({required this.controller, required this.track});

  final AppController controller;
  final DownloadedTrack track;

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _createPlaylist() async {
    final name = await _showPlaylistNameDialog(context, title: '新建歌单');
    if (name == null || !mounted) {
      return;
    }
    final playlist = await widget.controller.createPlaylist(name);
    if (playlist != null && mounted) {
      await widget.controller.setTrackInPlaylist(
        playlist.id,
        widget.track,
        included: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = widget.controller.myMusic.playlists;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.62,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: _line,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '加入歌单',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton.icon(
                  onPressed: _createPlaylist,
                  icon: const Icon(Icons.add),
                  label: const Text('新建'),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: playlists.isEmpty
                  ? _EmptyState(
                      icon: Icons.queue_music,
                      text: '还没有歌单',
                      actionLabel: '新建歌单',
                      onAction: _createPlaylist,
                    )
                  : ListView.separated(
                      itemCount: playlists.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        final included = widget.controller.isTrackInPlaylist(
                          playlist.id,
                          widget.track,
                        );
                        return CheckboxListTile(
                          value: included,
                          controlAffinity: ListTileControlAffinity.trailing,
                          secondary: const Icon(Icons.queue_music),
                          title: Text(playlist.name),
                          subtitle: Text(
                            '${widget.controller.tracksForPlaylist(playlist.id).length} 首歌曲',
                          ),
                          onChanged: (value) =>
                              widget.controller.setTrackInPlaylist(
                                playlist.id,
                                widget.track,
                                included: value ?? false,
                              ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibrarySearchSheet extends StatefulWidget {
  const _LibrarySearchSheet({required this.controller});

  final AppController controller;

  @override
  State<_LibrarySearchSheet> createState() => _LibrarySearchSheetState();
}

class _LibrarySearchSheetState extends State<_LibrarySearchSheet> {
  late final TextEditingController textController = TextEditingController(
    text: widget.controller.libraryQuery,
  );
  final FocusNode searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    textController.addListener(_handleTextChanged);
    searchFocusNode.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    searchFocusNode.removeListener(_handleTextChanged);
    textController.removeListener(_handleTextChanged);
    searchFocusNode.dispose();
    textController.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    setState(() {});
  }

  void _submit(String value) {
    searchFocusNode.unfocus();
    Navigator.pop(context, value.trim());
  }

  @override
  Widget build(BuildContext context) {
    final history =
        widget.controller.settings?.librarySearchHistory ?? const <String>[];
    final hasText = textController.text.trim().isNotEmpty;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _line,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  const Expanded(
                    child: Text(
                      '本地搜索',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                focusNode: searchFocusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: _submit,
                decoration: InputDecoration(
                  hintText: '歌名、歌手、专辑、歌词或拼音首字母',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasText)
                        IconButton(
                          tooltip: '清空',
                          onPressed: () => textController.clear(),
                          icon: const Icon(Icons.close),
                        ),
                      IconButton(
                        tooltip: '搜索',
                        onPressed: () => _submit(textController.text),
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ],
                  ),
                ),
              ),
              if (searchFocusNode.hasFocus && history.isNotEmpty) ...[
                const SizedBox(height: 10),
                _SearchHistoryDropdown(history: history, onSelected: _submit),
              ],
              const SizedBox(height: 18),
              Expanded(
                child: _EmptyState(
                  icon: history.isEmpty ? Icons.history : Icons.library_music,
                  text: history.isEmpty ? '暂无搜索历史' : '本地歌曲搜索',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryToolbar extends StatelessWidget {
  const _LibraryToolbar({required this.controller, required this.onSearch});

  final AppController controller;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final hasQuery = controller.libraryQuery.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 42,
            child: FilledButton.icon(
              onPressed: controller.downloadedTracks.isEmpty
                  ? null
                  : controller.startRandomLibraryPlayback,
              icon: const Icon(Icons.shuffle),
              label: const Text(
                '点击开始随机播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: FilledButton.styleFrom(
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _LibrarySortMenu(controller: controller),
        const SizedBox(width: 6),
        _CompactIconButton(
          tooltip: hasQuery ? '修改搜索' : '搜索',
          icon: hasQuery ? Icons.search_off : Icons.search,
          selected: hasQuery,
          onPressed: onSearch,
        ),
      ],
    );
  }
}

class _CompactIconButton extends StatelessWidget {
  const _CompactIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 42,
      child: Tooltip(
        message: tooltip,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: selected ? _accent.withValues(alpha: 0.16) : null,
            foregroundColor: selected ? _accentStrong : _ink,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: Icon(icon),
        ),
      ),
    );
  }
}

class _DirectoryScanButton extends StatelessWidget {
  const _DirectoryScanButton({
    required this.controller,
    required this.onPressed,
  });

  final AppController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      child: OutlinedButton.icon(
        onPressed: controller.isScanningDownloadDirectory ? null : onPressed,
        icon: controller.isScanningDownloadDirectory
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.manage_search),
        label: Text(
          controller.isScanningDownloadDirectory ? '正在扫描下载目录' : '扫描当前下载目录',
        ),
      ),
    );
    return SizedBox(width: double.infinity, child: button);
  }
}

class _AlbumMatchButton extends StatelessWidget {
  const _AlbumMatchButton({required this.controller, required this.onPressed});

  final AppController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final hasMissingAlbums = controller.downloadedTracks.any(
      (track) => track.album.trim().isEmpty,
    );
    final isBusy = controller.isMatchingLocalAlbums;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: isBusy || !hasMissingAlbums ? null : onPressed,
        icon: isBusy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.album_outlined),
        label: Text(isBusy ? '正在匹配专辑名称' : '匹配所有歌曲缺失专辑名称'),
      ),
    );
  }
}

class _LibrarySortMenu extends StatelessWidget {
  const _LibrarySortMenu({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<LibrarySortMode>(
      tooltip: '排序',
      onSelected: controller.setLibrarySortMode,
      itemBuilder: (context) => [
        for (final mode in LibrarySortMode.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                Icon(_librarySortIcon(mode), size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(_librarySortLabel(mode))),
                if (mode == controller.librarySortMode)
                  const Icon(Icons.check, color: _accentStrong, size: 20),
              ],
            ),
          ),
      ],
      child: SizedBox.square(
        dimension: 42,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            _librarySortIcon(controller.librarySortMode),
            color: _muted,
          ),
        ),
      ),
    );
  }
}
