part of '../main.dart';

enum _LibraryBatchAction {
  favorite,
  unfavorite,
  addToPlaylist,
  removeFromPlaylist,
  album,
  removeRecord,
  deleteFile;

  String get label => switch (this) {
    favorite => '添加到我喜欢',
    unfavorite => '取消喜欢',
    addToPlaylist => '加入歌单',
    removeFromPlaylist => '从当前歌单移除',
    album => '修改专辑',
    removeRecord => '删除记录',
    deleteFile => '删除歌曲',
  };
}

String _librarySelectionKey(String path) {
  final normalized = p.normalize(path.trim());
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

class _LibraryTrackList extends StatefulWidget {
  const _LibraryTrackList({
    super.key,
    required this.controller,
    required this.tracks,
    required this.emptyIcon,
    required this.emptyText,
    required this.toolbar,
    this.playlistId,
  });
  final AppController controller;
  final List<DownloadedTrack> tracks;
  final IconData emptyIcon;
  final String emptyText;
  final Widget toolbar;
  final String? playlistId;

  @override
  State<_LibraryTrackList> createState() => _LibraryTrackListState();
}

class _LibraryTrackListState extends State<_LibraryTrackList> {
  final Set<String> _selectedKeys = {};
  bool _selecting = false;
  bool _busy = false;
  bool get _disabled => _busy || widget.controller.isLibraryBatchRunning;

  List<DownloadedTrack> get _selectedTracks => [
    for (final track in widget.tracks)
      if (_selectedKeys.contains(_librarySelectionKey(track.path))) track,
  ];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant _LibraryTrackList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    final visible = widget.tracks
        .map((t) => _librarySelectionKey(t.path))
        .toSet();
    _selectedKeys.retainAll(visible);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _toggle(DownloadedTrack track) {
    if (_disabled) return;
    setState(() {
      _selecting = true;
      final key = _librarySelectionKey(track.path);
      if (!_selectedKeys.add(key)) _selectedKeys.remove(key);
    });
  }

  void _endSelection() => setState(() {
    _selecting = false;
    _selectedKeys.clear();
  });

  Future<void> _perform(_LibraryBatchAction action) async {
    if (_disabled) return;
    final tracks = List<DownloadedTrack>.unmodifiable(_selectedTracks);
    if (tracks.isEmpty) return;
    // Freeze the selection while dialogs are open, as well as during execution.
    setState(() => _busy = true);
    LibraryBatchResult? result;
    try {
      final controller = widget.controller;
      switch (action) {
        case _LibraryBatchAction.favorite:
        case _LibraryBatchAction.unfavorite:
          result = await controller.setFavoritesForTracks(
            tracks,
            favorite: action == _LibraryBatchAction.favorite,
          );
        case _LibraryBatchAction.addToPlaylist:
          final id = await _chooseBatchPlaylist(context, controller);
          if (id == null) return;
          result = await controller.setTracksInPlaylist(
            id,
            tracks,
            included: true,
          );
        case _LibraryBatchAction.removeFromPlaylist:
          result = await controller.setTracksInPlaylist(
            widget.playlistId!,
            tracks,
            included: false,
          );
        case _LibraryBatchAction.album:
          final album = await _chooseBatchAlbum(context, tracks);
          if (album == null) return;
          result = await controller.setAlbumsForTracks(tracks, album);
        case _LibraryBatchAction.removeRecord:
        case _LibraryBatchAction.deleteFile:
          if (!await _confirmBatchDeletion(
            context,
            controller,
            tracks,
            deleteFiles: action == _LibraryBatchAction.deleteFile,
          )) {
            return;
          }
          result = action == _LibraryBatchAction.deleteFile
              ? await controller.deleteDownloadedTracks(tracks)
              : await controller.removeDownloadedRecords(tracks);
      }
      if (!mounted) return;
      setState(() {
        _selectedKeys.removeAll(
          result!.completedPaths.map(_librarySelectionKey),
        );
        if (_selectedKeys.isEmpty) _selecting = false;
      });
      if (result.failures.isNotEmpty || result.warnings.isNotEmpty) {
        await _showBatchResult(context, result);
      }
    } catch (error) {
      widget.controller.showMessage('批量操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.tracks;
    final visible = tracks.map((t) => _librarySelectionKey(t.path)).toSet();
    _selectedKeys.retainAll(visible);
    final allSelected =
        visible.isNotEmpty && _selectedKeys.containsAll(visible);
    return PopScope(
      canPop: !_selecting && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_disabled) _endSelection();
      },
      child: Column(
        children: [
          if (!_selecting)
            Row(
              children: [
                Expanded(child: widget.toolbar),
                const SizedBox(width: 6),
                _CompactIconButton(
                  tooltip: '多选',
                  icon: Icons.checklist,
                  onPressed: tracks.isEmpty || _disabled
                      ? null
                      : () => setState(() => _selecting = true),
                ),
              ],
            )
          else
            Row(
              children: [
                IconButton(
                  tooltip: '退出多选',
                  onPressed: _disabled ? null : _endSelection,
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    '已选 ${_selectedKeys.length} 首',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: _disabled
                      ? null
                      : () => setState(() {
                          if (allSelected) {
                            _selectedKeys.clear();
                          } else {
                            _selectedKeys.addAll(visible);
                          }
                        }),
                  child: Text(allSelected ? '取消全选' : '全选'),
                ),
                PopupMenuButton<_LibraryBatchAction>(
                  tooltip: '批量操作',
                  enabled: !_disabled && _selectedKeys.isNotEmpty,
                  onSelected: (action) => unawaited(_perform(action)),
                  itemBuilder: (_) => [
                    for (final action in _LibraryBatchAction.values)
                      if (action != _LibraryBatchAction.removeFromPlaylist ||
                          widget.playlistId != null)
                        PopupMenuItem(
                          value: action,
                          child: Text(
                            action.label,
                            style:
                                action == _LibraryBatchAction.deleteFile ||
                                    action == _LibraryBatchAction.removeRecord
                                ? const TextStyle(color: Colors.redAccent)
                                : null,
                          ),
                        ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    child: Text(
                      '操作',
                      style: TextStyle(
                        color: _disabled || _selectedKeys.isEmpty
                            ? _muted
                            : _accentStrong,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          if (_busy && widget.controller.isLibraryBatchRunning) ...[
            LinearProgressIndicator(
              value: widget.controller.libraryBatchTotal == 0
                  ? null
                  : widget.controller.libraryBatchCompleted /
                        widget.controller.libraryBatchTotal,
            ),
            Text(
              '正在处理 ${widget.controller.libraryBatchCompleted} / '
              '${widget.controller.libraryBatchTotal} 首',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: tracks.isEmpty
                ? _EmptyState(icon: widget.emptyIcon, text: widget.emptyText)
                : _ResponsiveTrackList(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final track = tracks[index];
                      final selected = _selectedKeys.contains(
                        _librarySelectionKey(track.path),
                      );
                      final artist = track.artist.isEmpty
                          ? '未知歌手'
                          : track.artist;
                      final album = track.album.trim().isEmpty
                          ? '未知专辑'
                          : track.album.trim();
                      return TrackTile(
                        title: track.title,
                        subtitle: '$artist  ·  $album',
                        coverFilePath: track.coverFilePath,
                        artworkSize: 48,
                        titleWeight: FontWeight.w400,
                        titleSize: 15.5,
                        subtitleSize: 13.2,
                        selected: _selecting && selected,
                        onTap: _disabled
                            ? null
                            : _selecting
                            ? () => _toggle(track)
                            : () => widget.controller.playDownloaded(track),
                        onLongPress: _disabled ? null : () => _toggle(track),
                        trailing: _selecting
                            ? [
                                Checkbox(
                                  value: selected,
                                  semanticLabel: '选择${track.title}',
                                  onChanged: _disabled
                                      ? null
                                      : (_) => _toggle(track),
                                ),
                              ]
                            : widget.playlistId != null
                            ? [
                                _IconAction(
                                  tooltip: '从歌单移除',
                                  icon: Icons.remove_circle_outline,
                                  onPressed: _disabled
                                      ? null
                                      : () => widget.controller
                                            .setTrackInPlaylist(
                                              widget.playlistId!,
                                              track,
                                              included: false,
                                            ),
                                ),
                              ]
                            : [
                                _IconAction(
                                  tooltip: '下一首播放',
                                  icon:
                                      widget.controller.preparingQueueNextId ==
                                          track.id
                                      ? Icons.more_horiz
                                      : Icons.playlist_add,
                                  onPressed:
                                      _disabled ||
                                          widget
                                                  .controller
                                                  .preparingQueueNextId ==
                                              track.id
                                      ? null
                                      : () => widget.controller
                                            .queueDownloadedNext(track),
                                  size: 28,
                                ),
                                _LibraryMoreActions(
                                  controller: widget.controller,
                                  track: track,
                                ),
                              ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _chooseBatchPlaylist(
  BuildContext context,
  AppController controller,
) => showDialog<String>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('加入歌单'),
    content: SizedBox(
      width: 360,
      height: 240,
      child: controller.myMusic.playlists.isEmpty
          ? const Center(child: Text('还没有歌单，可先新建一个。'))
          : ListView.builder(
              itemCount: controller.myMusic.playlists.length,
              itemBuilder: (_, index) {
                final playlist = controller.myMusic.playlists[index];
                return ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(playlist.name),
                  onTap: () => Navigator.pop(context, playlist.id),
                );
              },
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton.icon(
        icon: const Icon(Icons.add),
        label: const Text('新建歌单'),
        onPressed: () async {
          final name = await _showPlaylistNameDialog(context, title: '新建歌单');
          if (name == null || !context.mounted) return;
          final playlist = await controller.createPlaylist(name);
          if (playlist != null && context.mounted) {
            Navigator.pop(context, playlist.id);
          }
        },
      ),
    ],
  ),
);

Future<String?> _chooseBatchAlbum(
  BuildContext context,
  List<DownloadedTrack> tracks,
) async {
  final albums = tracks.map((t) => t.album).toSet();
  final input = TextEditingController(
    text: albums.length == 1 ? albums.single : '',
  );
  try {
    final route = DialogRoute<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批量修改专辑'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('将为选中的 ${tracks.length} 首歌曲设置同一个专辑。留空会清除专辑名称。'),
              const SizedBox(height: 8),
              const Text(
                'MP3 会更新文件标签；其他格式更新青听内的信息。正在播放的 MP3 会在切歌后写入。',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: input,
                autofocus: true,
                decoration: const InputDecoration(labelText: '专辑名称'),
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
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final result = await Navigator.of(context).push(route);
    await route.completed;
    return result;
  } finally {
    input.dispose();
  }
}

Future<bool> _confirmBatchDeletion(
  BuildContext context,
  AppController controller,
  List<DownloadedTrack> tracks, {
  required bool deleteFiles,
}) async {
  final trash = controller.movesDeletedFilesToRecycleBin;
  final consequence = !deleteFiles
      ? '只从青听中删除歌曲记录，歌曲文件仍保留在原位置。'
      : trash
      ? '将歌曲文件本身移入回收站，同时移除歌曲记录和播放队列项目。文件可从回收站恢复。'
      : '将直接永久删除歌曲文件，同时移除歌曲记录和播放队列项目。删除后无法恢复。';
  final cloudCount =
      deleteFiles &&
          controller.cloudDeletionPolicyEnabled == true &&
          controller.settings?.cloudFolderId.isNotEmpty == true
      ? tracks
            .where(
              (t) => p.isWithin(controller.settings!.downloadDirectory, t.path),
            )
            .length
      : 0;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(deleteFiles ? '确认批量删除歌曲' : '确认批量删除记录'),
          content: SingleChildScrollView(
            child: Text(
              '已选择 ${tracks.length} 首歌曲。\n\n$consequence'
              '${cloudCount == 0 ? '' : '\n\n其中 $cloudCount 首歌曲下次云盘同步时，也会删除云端及其他设备上的相同歌曲。'}'
              '\n\n${tracks.take(5).map((t) => t.title).join('\n')}'
              '${tracks.length > 5 ? '\n…等 ${tracks.length} 首' : ''}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                !deleteFiles
                    ? '删除记录'
                    : trash
                    ? '移入回收站'
                    : '永久删除',
              ),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> _showBatchResult(
  BuildContext context,
  LibraryBatchResult result,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('批量操作结果'),
    content: SingleChildScrollView(
      child: Text(
        [
          '成功 ${result.completedPaths.length} 首，失败 ${result.failures.length} 首。',
          if (result.failures.isNotEmpty) '失败的歌曲仍保留选中，可再次操作。',
          for (final failure in result.failures)
            '${failure.track.title}：${failure.message}',
          ...result.warnings,
        ].join('\n\n'),
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
