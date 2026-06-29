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

  final best = candidates.first;
  AlbumMetadataMatch? selected;
  if (best.score >= AlbumMetadataService.highConfidenceScore) {
    selected = best;
  } else {
    selected = await _showAlbumCandidateDialog(context, candidates);
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
  List<AlbumMetadataMatch> candidates,
) {
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

enum _LibraryTrackAction {
  toggleFavorite,
  addToPlaylist,
  edit,
  fetchAlbum,
  openFile,
  revealFile,
  removeRecord,
}

class _LibraryMoreActions extends StatelessWidget {
  const _LibraryMoreActions({required this.controller, required this.track});

  final AppController controller;
  final DownloadedTrack track;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 38,
      child: PopupMenuButton<_LibraryTrackAction>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_horiz),
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
            case _LibraryTrackAction.removeRecord:
              controller.removeDownloadedRecord(track);
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
              value: _LibraryTrackAction.removeRecord,
              child: _MoreActionLabel(
                icon: Icons.delete_outline,
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

class _LyricLine {
  const _LyricLine({required this.time, required this.text});

  final Duration? time;
  final String text;
}

const _lyricLinesCacheLimit = 24;
final Map<String, List<_LyricLine>> _lyricLinesCache = {};

List<_LyricLine> _parseLyricLines(String? rawLyrics) {
  final raw = rawLyrics?.trim();
  if (raw == null || raw.isEmpty) {
    return const [];
  }

  final cached = _lyricLinesCache.remove(raw);
  if (cached != null) {
    _lyricLinesCache[raw] = cached;
    return cached;
  }

  final timedLines = <_LyricLine>[];
  final plainLines = <String>[];
  final timestampPattern = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');

  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final matches = timestampPattern.allMatches(line).toList();
    if (matches.isEmpty) {
      final plain = line.trim();
      if (plain.isNotEmpty) {
        plainLines.add(plain);
      }
      continue;
    }

    final text = line.substring(matches.last.end).trim();
    if (text.isEmpty) {
      continue;
    }
    for (final match in matches) {
      timedLines.add(_LyricLine(time: _parseLyricTimestamp(match), text: text));
    }
  }

  final parsed = <_LyricLine>[];
  if (timedLines.isNotEmpty) {
    timedLines.sort((a, b) => a.time!.compareTo(b.time!));
    parsed.addAll(timedLines);
  } else {
    parsed.addAll([
      for (final line in plainLines) _LyricLine(time: null, text: line),
    ]);
  }

  final result = List<_LyricLine>.unmodifiable(parsed);
  _lyricLinesCache[raw] = result;
  if (_lyricLinesCache.length > _lyricLinesCacheLimit) {
    _lyricLinesCache.remove(_lyricLinesCache.keys.first);
  }
  return result;
}

Duration _parseLyricTimestamp(RegExpMatch match) {
  final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
  final fraction = match.group(3) ?? '0';
  final milliseconds = switch (fraction.length) {
    1 => (int.tryParse(fraction) ?? 0) * 100,
    2 => (int.tryParse(fraction) ?? 0) * 10,
    _ => int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0,
  };
  return Duration(
    minutes: minutes,
    seconds: seconds,
    milliseconds: milliseconds,
  );
}

int _currentLyricIndex(List<_LyricLine> lines, Duration position) {
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

String? _currentLyricText(List<_LyricLine> lines, int currentIndex) {
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
