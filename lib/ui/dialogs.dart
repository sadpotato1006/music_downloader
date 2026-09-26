part of '../main.dart';

Future<void> _showEditDownloadedTrackDialog(
  BuildContext context,
  AppController controller,
  DownloadedTrack track,
) async {
  final lyrics = await controller.readDownloadedLyrics(track) ?? '';
  if (!context.mounted) {
    return;
  }

  final titleController = TextEditingController(text: track.title);
  final artistController = TextEditingController(text: track.artist);
  final albumController = TextEditingController(text: track.album);
  final lyricsController = TextEditingController(text: lyrics);
  final coverController = TextEditingController();

  try {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑歌曲信息'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '歌名',
                    prefixIcon: Icon(Icons.music_note),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: artistController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '歌手',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: albumController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '专辑',
                    prefixIcon: Icon(Icons.album_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: coverController,
                  minLines: 1,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '封面图片路径或网址',
                    hintText: '留空则保留当前封面',
                    prefixIcon: Icon(Icons.image_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: lyricsController,
                  minLines: 5,
                  maxLines: 9,
                  decoration: const InputDecoration(
                    labelText: '歌词',
                    alignLabelWithHint: true,
                    prefixIcon: Icon(Icons.lyrics_outlined),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.save),
            label: const Text('保存'),
          ),
        ],
      ),
    );

    if (saved != true || !context.mounted) {
      return;
    }
    final success = await controller.updateDownloadedTrack(
      track,
      title: titleController.text,
      artist: artistController.text,
      album: albumController.text,
      lyrics: lyricsController.text,
      coverInput: coverController.text,
    );
    if (!context.mounted) {
      return;
    }
    controller.showMessage(success ? '歌曲信息已保存' : '歌曲信息保存失败');
  } finally {
    titleController.dispose();
    artistController.dispose();
    albumController.dispose();
    lyricsController.dispose();
    coverController.dispose();
  }
}

Future<void> _fetchAlbumForDownloadedTrack(
  BuildContext context,
  AppController controller,
  DownloadedTrack track,
) async {
  final candidates = await controller.findDownloadedAlbumCandidates(track);
  if (!context.mounted) {
    return;
  }
  if (candidates.isEmpty) {
    return;
  }

  AlbumMetadataMatch? selected = AlbumMetadataService.selectAutomaticMatch(
    candidates,
    hasArtist: track.artist.trim().isNotEmpty,
    hasDuration: track.durationMs != null,
  );
  if (selected == null) {
    selected = await _showAlbumCandidateDialog(
      context,
      candidates,
      trackTitle: track.title,
      trackArtist: track.artist,
    );
    if (!context.mounted || selected == null) {
      return;
    }
  }

  final success = await controller.applyDownloadedAlbumName(
    track,
    selected.album,
  );
  if (!context.mounted) {
    return;
  }
  controller.showMessage(success ? '已设置专辑名称：${selected.album}' : '专辑名称写入失败');
}

Future<AlbumMetadataMatch?> _showAlbumCandidateDialog(
  BuildContext context,
  List<AlbumMetadataMatch> candidates, {
  String? trackTitle,
  String? trackArtist,
}) {
  return showDialog<AlbumMetadataMatch>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('选择专辑名称'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '没有找到高置信度结果，可以从下面的候选中手动选择一个。',
                style: TextStyle(color: _muted, fontSize: 13),
              ),
              if (trackTitle != null) ...[
                const SizedBox(height: 5),
                Text(
                  trackArtist == null || trackArtist.trim().isEmpty
                      ? trackTitle
                      : '$trackArtist · $trackTitle',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.52,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final candidate = candidates[index];
                    final date = candidate.releaseDate?.trim();
                    final info = [
                      candidate.sourceLabel,
                      candidate.recordingArtist.trim().isEmpty
                          ? '未知歌手'
                          : candidate.recordingArtist.trim(),
                      candidate.recordingTitle.trim().isEmpty
                          ? null
                          : candidate.recordingTitle.trim(),
                      if (!candidate.releasePreferred) '合辑或非首选发行',
                      if (!candidate.durationVerified) '未校验时长',
                      if (date != null && date.isNotEmpty) date,
                      '置信度 ${candidate.score.round()}',
                    ].whereType<String>().join(' · ');
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.album_outlined),
                      title: Text(
                        candidate.album,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        info,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, candidate),
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
            child: const Text('取消'),
          ),
        ],
      );
    },
  );
}

Future<void> _showPendingAlbumMatchesSheet(
  BuildContext context,
  AppController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) => _PendingAlbumMatchesSheet(controller: controller),
  );
}

class _PendingAlbumMatchesSheet extends StatefulWidget {
  const _PendingAlbumMatchesSheet({required this.controller});

  final AppController controller;

  @override
  State<_PendingAlbumMatchesSheet> createState() =>
      _PendingAlbumMatchesSheetState();
}

class _PendingAlbumMatchesSheetState extends State<_PendingAlbumMatchesSheet> {
  String? _activePath;
  AlbumMetadataMatch? _selected;
  bool _isApplying = false;

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

  void _ensureSelection(PendingAlbumMatch pending) {
    if (_activePath == pending.trackPath) {
      return;
    }
    _activePath = pending.trackPath;
    _selected = pending.candidates.isEmpty ? null : pending.candidates.first;
  }

  Future<void> _apply(PendingAlbumMatch pending) async {
    final selected = _selected;
    if (selected == null || _isApplying) {
      return;
    }
    setState(() => _isApplying = true);
    await widget.controller.applyPendingAlbumMatch(pending, selected);
    if (mounted) {
      setState(() {
        _isApplying = false;
        _activePath = null;
        _selected = null;
      });
    }
  }

  void _skip(PendingAlbumMatch pending) {
    widget.controller.skipPendingAlbumMatch(pending);
    _activePath = null;
    _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final pendingItems = widget.controller.pendingAlbumMatches;
    if (pendingItems.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.task_alt, color: _accentStrong, size: 42),
            const SizedBox(height: 10),
            const Text(
              '待确认结果已处理完毕',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    }

    final pending = pendingItems.first;
    _ensureSelection(pending);
    final height = MediaQuery.sizeOf(context).height * 0.82;
    return SizedBox(
      height: height,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                const SizedBox(height: 16),
                Text(
                  '待确认专辑 · 剩余 ${pendingItems.length} 首',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  pending.artist.trim().isEmpty
                      ? pending.title
                      : '${pending.artist} · ${pending.title}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: pending.candidates.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final candidate = pending.candidates[index];
                      final selected = identical(candidate, _selected);
                      final date = candidate.releaseDate?.trim();
                      final info = [
                        candidate.sourceLabel,
                        candidate.recordingArtist.trim().isEmpty
                            ? '未知歌手'
                            : candidate.recordingArtist.trim(),
                        candidate.recordingTitle,
                        if (!candidate.releasePreferred) '合辑或非首选发行',
                        if (!candidate.durationVerified) '未校验时长',
                        if (date != null && date.isNotEmpty) date,
                        '置信度 ${candidate.score.round()}',
                      ].where((value) => value.trim().isNotEmpty).join(' · ');
                      return ListTile(
                        selected: selected,
                        selectedTileColor: _accent.withValues(alpha: 0.12),
                        leading: Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          color: selected ? _accentStrong : _muted,
                        ),
                        title: Text(candidate.album),
                        subtitle: Text(info),
                        onTap: _isApplying
                            ? null
                            : () => setState(() => _selected = candidate),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: _isApplying
                          ? null
                          : () => Navigator.pop(context),
                      child: const Text('稍后处理'),
                    ),
                    TextButton(
                      onPressed: _isApplying ? null : () => _skip(pending),
                      child: const Text('跳过此首'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _isApplying || _selected == null
                          ? null
                          : () => _apply(pending),
                      icon: _isApplying
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check),
                      label: const Text('确认并继续'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _LibraryTrackAction {
  toggleFavorite,
  addToPlaylist,
  edit,
  fetchAlbum,
  openFile,
  revealFile,
  deleteFile,
  removeRecord,
}

Future<void> _confirmDeleteDownloadedTrack(
  BuildContext context,
  AppController controller,
  DownloadedTrack track,
) async {
  final movesToRecycleBin = controller.movesDeletedFilesToRecycleBin;
  final consequence = movesToRecycleBin
      ? '将歌曲文件本身移入回收站，并同时移除青听中的歌曲记录和播放队列项目；文件仍可从回收站恢复。'
      : '将直接永久删除歌曲文件本身，并同时移除青听中的歌曲记录和播放队列项目；删除后无法恢复。';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认删除歌曲'),
      content: Text('$consequence\n\n歌曲：${track.title}'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(context, true),
          child: Text(movesToRecycleBin ? '移入回收站' : '删除歌曲'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await controller.deleteDownloadedTrack(track);
  }
}

Future<void> _confirmRemoveDownloadedRecord(
  BuildContext context,
  AppController controller,
  DownloadedTrack track,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('确认删除记录'),
      content: Text(
        '此操作只会从青听中删除歌曲记录，不会删除歌曲文件本身；文件仍会保留在原位置。\n\n'
        '歌曲：${track.title}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除记录'),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await controller.removeDownloadedRecord(track);
  }
}

class _LibraryMoreActions extends StatelessWidget {
  const _LibraryMoreActions({required this.controller, required this.track});

  final AppController controller;
  final DownloadedTrack track;

  @override
  Widget build(BuildContext context) {
    final isDeleting = controller.isDeletingDownloadedTrack(track);
    final isMatching = controller.isMatchingAlbumForTrack(track);
    final isBusy = isDeleting || isMatching;
    return SizedBox.square(
      dimension: 38,
      child: PopupMenuButton<_LibraryTrackAction>(
        enabled: !isBusy,
        tooltip: isDeleting
            ? '正在删除歌曲'
            : isMatching
            ? '正在匹配专辑'
            : '更多',
        padding: EdgeInsets.zero,
        icon: isBusy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: _accentStrong,
                ),
              )
            : const Icon(Icons.more_horiz),
        iconColor: _ink,
        color: Colors.white,
        elevation: 8,
        offset: const Offset(0, 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onSelected: (action) {
          switch (action) {
            case _LibraryTrackAction.toggleFavorite:
              unawaited(controller.toggleFavorite(track));
              return;
            case _LibraryTrackAction.addToPlaylist:
              _showAddToPlaylistSheet(context, controller, track);
              return;
            case _LibraryTrackAction.edit:
              _showEditDownloadedTrackDialog(context, controller, track);
              return;
            case _LibraryTrackAction.fetchAlbum:
              unawaited(
                _fetchAlbumForDownloadedTrack(context, controller, track),
              );
              return;
            case _LibraryTrackAction.openFile:
              controller.openDownloadedFile(track);
              return;
            case _LibraryTrackAction.revealFile:
              controller.revealDownloadedFile(track);
              return;
            case _LibraryTrackAction.deleteFile:
              unawaited(
                _confirmDeleteDownloadedTrack(context, controller, track),
              );
              return;
            case _LibraryTrackAction.removeRecord:
              unawaited(
                _confirmRemoveDownloadedRecord(context, controller, track),
              );
              return;
          }
        },
        itemBuilder: (context) {
          final favorite = controller.isFavorite(track);
          return [
            PopupMenuItem(
              value: _LibraryTrackAction.toggleFavorite,
              child: _MoreActionLabel(
                icon: favorite ? Icons.favorite : Icons.favorite_border,
                label: favorite ? '取消喜欢' : '添加到我喜欢',
              ),
            ),
            const PopupMenuItem(
              value: _LibraryTrackAction.addToPlaylist,
              child: _MoreActionLabel(icon: Icons.playlist_add, label: '加入歌单'),
            ),
            const PopupMenuItem(
              value: _LibraryTrackAction.edit,
              child: _MoreActionLabel(icon: Icons.edit_outlined, label: '编辑信息'),
            ),
            const PopupMenuItem(
              value: _LibraryTrackAction.fetchAlbum,
              child: _MoreActionLabel(
                icon: Icons.manage_search,
                label: '获取专辑名称',
              ),
            ),
            const PopupMenuItem(
              value: _LibraryTrackAction.openFile,
              child: _MoreActionLabel(icon: Icons.open_in_new, label: '打开文件'),
            ),
            const PopupMenuItem(
              value: _LibraryTrackAction.revealFile,
              child: _MoreActionLabel(icon: Icons.folder_open, label: '打开位置'),
            ),
            const PopupMenuItem(
              value: _LibraryTrackAction.deleteFile,
              child: _MoreActionLabel(
                icon: Icons.delete_forever_outlined,
                label: '删除歌曲',
                destructive: true,
              ),
            ),
            const PopupMenuItem(
              value: _LibraryTrackAction.removeRecord,
              child: _MoreActionLabel(
                icon: Icons.playlist_remove,
                label: '删除记录',
                destructive: true,
              ),
            ),
          ];
        },
      ),
    );
  }
}

class _MoreActionLabel extends StatelessWidget {
  const _MoreActionLabel({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Colors.redAccent : _ink;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.size = 38,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          fixedSize: Size(size, size),
          padding: EdgeInsets.zero,
          backgroundColor: selected ? _accent.withValues(alpha: 0.22) : null,
          foregroundColor: selected ? _accentStrong : _ink,
        ),
        icon: Icon(icon),
      ),
    );
  }
}

BoxDecoration _tileDecoration() {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: _line),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.025),
        blurRadius: 18,
        offset: const Offset(0, 8),
      ),
    ],
  );
}

String _statusLabel(DownloadStatus status) {
  return switch (status) {
    DownloadStatus.queued => '等待中',
    DownloadStatus.downloading => '下载中',
    DownloadStatus.paused => '已暂停',
    DownloadStatus.completed => '已完成',
    DownloadStatus.failed => '失败',
    DownloadStatus.canceled => '已取消',
  };
}

String _librarySortLabel(LibrarySortMode mode) {
  return switch (mode) {
    LibrarySortMode.downloadedAtDesc => '最近下载',
    LibrarySortMode.titleAsc => '歌名',
    LibrarySortMode.artistAsc => '歌手',
  };
}

IconData _librarySortIcon(LibrarySortMode mode) {
  return switch (mode) {
    LibrarySortMode.downloadedAtDesc => Icons.schedule,
    LibrarySortMode.titleAsc => Icons.sort_by_alpha,
    LibrarySortMode.artistAsc => Icons.person_outline,
  };
}

String _desktopLyricPositionLabel(double value) {
  if (value < 0.28) {
    return '靠上';
  }
  if (value > 0.72) {
    return '靠下';
  }
  return '居中';
}

String _desktopLyricHorizontalPositionLabel(double value) {
  if (value < 0.28) {
    return '靠左';
  }
  if (value > 0.72) {
    return '靠右';
  }
  return '居中';
}

String _formatLyricDelay(int milliseconds) {
  if (milliseconds == 0) {
    return '0ms';
  }
  final sign = milliseconds > 0 ? '+' : '';
  return '$sign${milliseconds}ms';
}

int _currentLyricIndex(List<LyricLine> lines, Duration position) {
  if (lines.isEmpty || lines.first.time == null) {
    return -1;
  }

  var low = 0;
  var high = lines.length - 1;
  var current = -1;
  while (low <= high) {
    final middle = low + ((high - low) >> 1);
    if (lines[middle].time! <= position) {
      current = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return current;
}

String? _currentLyricText(List<LyricLine> lines, int currentIndex) {
  if (currentIndex < 0 || currentIndex >= lines.length) {
    return null;
  }
  return lines[currentIndex].text;
}

String _formatDuration(Duration duration) {
  if (duration == Duration.zero) {
    return '0:00';
  }
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
