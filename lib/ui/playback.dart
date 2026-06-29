part of '../main.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.controller,
    required this.isDesktop,
  });

  final AppController controller;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: controller.player.positionListenable,
      builder: (context, position, _) {
        final item = controller.currentItem;
        final lyricLines = _parseLyricLines(item?.lyrics);
        final currentLyricIndex = _currentLyricIndex(lyricLines, position);

        return SafeArea(
          top: false,
          child: Container(
            height: isDesktop ? 78 : 82,
            padding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 24 : 14,
              vertical: isDesktop ? 10 : 8,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: _line)),
            ),
            child: isDesktop
                ? _DesktopMiniPlayerContent(
                    controller: controller,
                    item: item,
                    lyricLines: lyricLines,
                    currentLyricIndex: currentLyricIndex,
                  )
                : _MobileMiniPlayerContent(
                    controller: controller,
                    item: item,
                    lyricLines: lyricLines,
                    currentLyricIndex: currentLyricIndex,
                  ),
          ),
        );
      },
    );
  }
}

class _DesktopMiniPlayerContent extends StatelessWidget {
  const _DesktopMiniPlayerContent({
    required this.controller,
    required this.item,
    required this.lyricLines,
    required this.currentLyricIndex,
  });

  final AppController controller;
  final PlayerItem? item;
  final List<_LyricLine> lyricLines;
  final int currentLyricIndex;

  @override
  Widget build(BuildContext context) {
    final lyricText = _currentLyricText(lyricLines, currentLyricIndex);
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: item == null
                ? null
                : () => _showLyricsSheet(context, controller),
            child: Row(
              children: [
                _TrackArtwork(
                  coverUrl: item?.coverUrl,
                  coverFilePath: item?.coverFilePath,
                  icon: Icons.graphic_eq,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TrackText(
                    title: item?.title ?? '未播放',
                    subtitle: lyricText ?? item?.artist ?? '青听',
                    tertiary: item?.album.trim().isEmpty ?? true
                        ? null
                        : item?.album.trim(),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        _PlaybackControls(controller: controller, compact: false),
      ],
    );
  }
}

class _MobileMiniPlayerContent extends StatelessWidget {
  const _MobileMiniPlayerContent({
    required this.controller,
    required this.item,
    required this.lyricLines,
    required this.currentLyricIndex,
  });

  final AppController controller;
  final PlayerItem? item;
  final List<_LyricLine> lyricLines;
  final int currentLyricIndex;

  @override
  Widget build(BuildContext context) {
    final lyricText = _currentLyricText(lyricLines, currentLyricIndex);
    return Row(
      children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: item == null
                ? null
                : () => _showLyricsSheet(context, controller),
            child: Row(
              children: [
                _TrackArtwork(
                  coverUrl: item?.coverUrl,
                  coverFilePath: item?.coverFilePath,
                  icon: Icons.graphic_eq,
                  size: 46,
                  borderRadius: 14,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _TrackText(
                    title: item?.title ?? '未播放',
                    subtitle: lyricText ?? item?.artist ?? '青听',
                    tertiary: item?.album.trim().isEmpty ?? true
                        ? null
                        : item?.album.trim(),
                  ),
                ),
              ],
            ),
          ),
        ),
        _PlaybackControls(controller: controller, compact: true),
      ],
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.controller, required this.compact});

  final AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final buttonSize = compact ? 34.0 : 38.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _PlayButton(controller: controller, compact: compact),
        _IconAction(
          tooltip: '播放队列',
          icon: Icons.queue_music,
          size: buttonSize,
          selected: controller.queue.isNotEmpty,
          onPressed: () => _showQueueSheet(context, controller),
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.controller, this.compact = false});

  final AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.currentItem != null;
    final size = compact ? 42.0 : 48.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 6),
      child: SizedBox.square(
        dimension: size,
        child: IconButton.filled(
          tooltip: controller.player.isPlaying ? '暂停' : '播放',
          onPressed: enabled ? controller.togglePlayPause : null,
          icon: Icon(
            controller.player.isPlaying ? Icons.pause : Icons.play_arrow,
            size: compact ? 22 : 24,
          ),
        ),
      ),
    );
  }
}

class _ResponsiveTrackList extends StatelessWidget {
  const _ResponsiveTrackList({
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _trackListColumnCount(constraints);
        if (columns <= 1) {
          return ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: itemCount,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: itemBuilder,
          );
        }

        return GridView.builder(
          padding: EdgeInsets.zero,
          itemCount: itemCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: 72,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}

int _trackListColumnCount(BoxConstraints constraints) {
  if (constraints.maxWidth < 980) {
    return 1;
  }
  if (constraints.maxWidth >= 1640) {
    return 3;
  }
  return 2;
}

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.onTap,
    this.tertiary,
    this.coverUrl,
    this.coverFilePath,
    this.showArtwork = true,
    this.artworkSize = 40,
    this.titleWeight = FontWeight.w700,
    this.titleSize = 15,
    this.subtitleSize = 13,
    this.tertiarySize = 12,
  });

  final String title;
  final String subtitle;
  final String? tertiary;
  final List<Widget> trailing;
  final VoidCallback? onTap;
  final String? coverUrl;
  final String? coverFilePath;
  final bool showArtwork;
  final double artworkSize;
  final FontWeight titleWeight;
  final double titleSize;
  final double subtitleSize;
  final double tertiarySize;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: _accent.withValues(alpha: 0.18),
        highlightColor: _accent.withValues(alpha: 0.10),
        child: Ink(
          decoration: _tileDecoration(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (showArtwork) ...[
                  _TrackArtwork(
                    coverUrl: coverUrl,
                    coverFilePath: coverFilePath,
                    icon: Icons.music_note,
                    size: artworkSize,
                    borderRadius: 12,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: _TrackText(
                    title: title,
                    subtitle: subtitle,
                    tertiary: tertiary,
                    titleWeight: titleWeight,
                    titleSize: titleSize,
                    subtitleSize: subtitleSize,
                    tertiarySize: tertiarySize,
                  ),
                ),
                const SizedBox(width: 6),
                Wrap(spacing: 2, children: trailing),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackText extends StatelessWidget {
  const _TrackText({
    required this.title,
    required this.subtitle,
    this.tertiary,
    this.titleWeight = FontWeight.w700,
    this.titleSize = 15,
    this.subtitleSize = 13,
    this.tertiarySize = 12,
  });

  final String title;
  final String subtitle;
  final String? tertiary;
  final FontWeight titleWeight;
  final double titleSize;
  final double subtitleSize;
  final double tertiarySize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: titleWeight, fontSize: titleSize),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: _muted, fontSize: subtitleSize),
        ),
        if (tertiary != null && tertiary!.trim().isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            tertiary!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _muted.withValues(alpha: 0.82),
              fontSize: tertiarySize,
            ),
          ),
        ],
      ],
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.child, this.horizontalPadding = 24});

  final Widget child;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          20,
          horizontalPadding,
          14,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Expanded(child: child)],
        ),
      ),
    );
  }
}

class _SettingPanel extends StatelessWidget {
  const _SettingPanel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _tileDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _accentStrong.withValues(alpha: 0.52), size: 44),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(icon, color: _accentStrong, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

void _showLyricsSheet(BuildContext context, AppController controller) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: false,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height),
    builder: (context) => _LyricsSheet(controller: controller),
  );
}

class _LyricsSheet extends StatefulWidget {
  const _LyricsSheet({required this.controller});

  final AppController controller;

  @override
  State<_LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<_LyricsSheet> {
  static const _lyricsMinListPadding = 84.0;
  static const _estimatedLyricLineExtent = 58.0;

  final ScrollController scrollController = ScrollController();
  final Map<int, GlobalKey> _lyricLineKeys = {};
  int lastScrolledIndex = -1;
  String? lastScrolledItemId;
  double _lyricsVerticalPadding = _lyricsMinListPadding;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.player.positionListenable.addListener(
      _handlePlayerPositionChanged,
    );
    _scheduleScroll();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    widget.controller.player.positionListenable.removeListener(
      _handlePlayerPositionChanged,
    );
    scrollController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _scheduleScroll();
  }

  void _handlePlayerPositionChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _scheduleScroll();
  }

  void _scheduleScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) {
        return;
      }
      final item = widget.controller.currentItem;
      if (item?.id != lastScrolledItemId) {
        lastScrolledItemId = item?.id;
        lastScrolledIndex = -1;
      }
      final lines = _parseLyricLines(item?.lyrics);
      final currentIndex = _currentLyricIndex(
        lines,
        widget.controller.player.position,
      );
      if (currentIndex < 0 || currentIndex == lastScrolledIndex) {
        return;
      }
      final itemId = item?.id;
      final lineContext = _lyricLineKeys[currentIndex]?.currentContext;
      if (lineContext == null || !lineContext.mounted) {
        final estimatedTarget =
            _lyricsVerticalPadding +
            currentIndex * _estimatedLyricLineExtent -
            scrollController.position.viewportDimension / 2;
        scrollController.jumpTo(
          estimatedTarget
              .clamp(0.0, scrollController.position.maxScrollExtent)
              .toDouble(),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || widget.controller.currentItem?.id != itemId) {
            return;
          }
          final builtContext = _lyricLineKeys[currentIndex]?.currentContext;
          lastScrolledIndex = currentIndex;
          if (builtContext == null || !builtContext.mounted) {
            return;
          }
          Scrollable.ensureVisible(
            builtContext,
            alignment: 0.5,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          );
        });
        return;
      }
      lastScrolledIndex = currentIndex;
      Scrollable.ensureVisible(
        lineContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.controller.currentItem;
    final lines = _parseLyricLines(item?.lyrics);
    final currentIndex = _currentLyricIndex(
      lines,
      widget.controller.player.position,
    );
    final duration = widget.controller.player.duration;
    final durationMs = duration.inMilliseconds;
    final maxMs = (durationMs <= 0 ? 1 : durationMs).toDouble();
    final positionMs = widget.controller.player.position.inMilliseconds.clamp(
      0,
      durationMs <= 0 ? 1 : durationMs,
    );
    final album = item?.album.trim();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
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
                      '歌词',
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
              const SizedBox(height: 8),
              Row(
                children: [
                  _TrackArtwork(
                    coverUrl: item?.coverUrl,
                    coverFilePath: item?.coverFilePath,
                    icon: Icons.graphic_eq,
                    size: 64,
                    borderRadius: 16,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _TrackText(
                      title: item?.title ?? '未播放',
                      subtitle: item?.artist.trim().isEmpty ?? true
                          ? '青听'
                          : item!.artist.trim(),
                      tertiary: album == null || album.isEmpty ? null : album,
                      titleWeight: FontWeight.w600,
                      titleSize: 18,
                      subtitleSize: 13,
                      tertiarySize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: lines.isEmpty
                    ? const _EmptyState(icon: Icons.lyrics, text: '这首歌没有内嵌歌词')
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final verticalPadding =
                              (constraints.maxHeight / 2 - 32)
                                  .clamp(_lyricsMinListPadding, 260.0)
                                  .toDouble();
                          _lyricsVerticalPadding = verticalPadding;
                          return ListView.builder(
                            controller: scrollController,
                            padding: EdgeInsets.symmetric(
                              vertical: verticalPadding,
                            ),
                            itemCount: lines.length,
                            itemBuilder: (context, index) {
                              return InkWell(
                                key: _lyricLineKeys.putIfAbsent(
                                  index,
                                  GlobalKey.new,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                onTap: lines[index].time == null
                                    ? null
                                    : () => widget.controller.seekTo(
                                        lines[index].time!,
                                      ),
                                child: AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 160),
                                  style: TextStyle(
                                    color: index == currentIndex
                                        ? _accentStrong
                                        : _muted,
                                    fontSize: 16,
                                    fontWeight: index == currentIndex
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    height: 1.45,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                      horizontal: 8,
                                    ),
                                    child: Text(
                                      lines[index].text,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 42,
                    child: Text(
                      _formatDuration(widget.controller.player.position),
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                          disabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        value: positionMs.toDouble(),
                        min: 0,
                        max: maxMs,
                        onChanged: item == null
                            ? null
                            : (value) => widget.controller.seekTo(
                                Duration(milliseconds: value.round()),
                              ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    child: Text(
                      _formatDuration(duration),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _LyricsPlaybackControls(controller: widget.controller),
            ],
          ),
        ),
      ),
    );
  }
}

class _LyricsPlaybackControls extends StatelessWidget {
  const _LyricsPlaybackControls({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final item = controller.currentItem;
    final singleLoop = controller.isSingleLoopMode;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _LyricsRoundButton(
          tooltip: singleLoop ? '关闭单曲循环' : '开启单曲循环',
          icon: singleLoop ? Icons.repeat_one : Icons.repeat,
          selected: singleLoop,
          onPressed: controller.toggleSingleLoopMode,
        ),
        _LyricsRoundButton(
          tooltip: '上一首',
          icon: Icons.skip_previous,
          onPressed: controller.queue.isEmpty ? null : controller.playPrevious,
        ),
        _LyricsMainPlayButton(controller: controller),
        _LyricsRoundButton(
          tooltip: '下一首',
          icon: Icons.skip_next,
          onPressed: controller.queue.isEmpty ? null : controller.playNext,
        ),
        _LyricsRoundButton(
          tooltip: '歌曲信息',
          icon: Icons.more_horiz,
          onPressed: item == null
              ? null
              : () => _showTrackInfoSheet(context, item),
        ),
      ],
    );
  }
}

class _LyricsRoundButton extends StatelessWidget {
  const _LyricsRoundButton({
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
      dimension: 44,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: selected ? _accent.withValues(alpha: 0.18) : null,
          foregroundColor: selected ? _accentStrong : _ink,
        ),
        icon: Icon(icon),
      ),
    );
  }
}

class _LyricsMainPlayButton extends StatelessWidget {
  const _LyricsMainPlayButton({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.currentItem != null;
    return SizedBox.square(
      dimension: 52,
      child: IconButton.filled(
        tooltip: controller.player.isPlaying ? '暂停' : '播放',
        onPressed: enabled ? controller.togglePlayPause : null,
        icon: Icon(
          controller.player.isPlaying ? Icons.pause : Icons.play_arrow,
          size: 26,
        ),
      ),
    );
  }
}

void _showQueueSheet(BuildContext context, AppController controller) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) => _QueueSheet(controller: controller),
  );
}

void _showTrackInfoSheet(BuildContext context, PlayerItem item) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (context) {
      final album = item.album.trim();
      final path = item.localPath?.trim();
      final source = path == null || path.isEmpty ? item.uri : path;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            const SizedBox(height: 18),
            const Text(
              '歌曲信息',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            _TrackInfoRow(label: '歌名', value: item.title),
            _TrackInfoRow(
              label: '歌手',
              value: item.artist.trim().isEmpty ? '未知歌手' : item.artist,
            ),
            _TrackInfoRow(label: '专辑', value: album.isEmpty ? '未知专辑' : album),
            _TrackInfoRow(label: '来源', value: source),
          ],
        ),
      );
    },
  );
}

class _TrackInfoRow extends StatelessWidget {
  const _TrackInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              label,
              style: const TextStyle(color: _muted, fontSize: 13),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 14.5, color: _ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueSheet extends StatefulWidget {
  const _QueueSheet({required this.controller});

  final AppController controller;

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  static const _queueItemExtent = 80.0;

  final ScrollController queueScrollController = ScrollController();
  int? _lastCenteredQueueIndex;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChanged);
    _scheduleCurrentQueueScroll(force: true);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChanged);
    queueScrollController.dispose();
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) {
      setState(() {});
      _scheduleCurrentQueueScroll();
    }
  }

  void _scheduleCurrentQueueScroll({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !queueScrollController.hasClients) {
        return;
      }
      final index = widget.controller.currentQueueIndex;
      final queueLength = widget.controller.queue.length;
      if (index < 0 || index >= queueLength) {
        return;
      }
      if (!force && _lastCenteredQueueIndex == index) {
        return;
      }
      _lastCenteredQueueIndex = index;

      final position = queueScrollController.position;
      final rawTarget =
          index * _queueItemExtent +
          _queueItemExtent / 2 -
          position.viewportDimension / 2;
      final target = rawTarget.clamp(0.0, position.maxScrollExtent).toDouble();
      if ((position.pixels - target).abs() < 2) {
        return;
      }
      queueScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final queue = controller.queue;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
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
                    '播放队列',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  '${queue.length} 首',
                  style: const TextStyle(color: _muted),
                ),
                const SizedBox(width: 10),
                _IconAction(
                  tooltip: '重新随机接下来的歌曲',
                  icon: Icons.shuffle,
                  selected:
                      controller.shuffleEnabled &&
                      controller.canReshuffleUpcomingQueue,
                  onPressed: controller.canReshuffleUpcomingQueue
                      ? () => controller.reshuffleUpcomingQueue()
                      : null,
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: queue.isEmpty ? null : controller.clearQueue,
                  icon: const Icon(Icons.clear_all),
                  label: const Text('清空'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: queue.isEmpty
                  ? const _EmptyState(icon: Icons.queue_music, text: '播放队列为空')
                  : ReorderableListView.builder(
                      scrollController: queueScrollController,
                      itemExtent: _queueItemExtent,
                      itemCount: queue.length,
                      buildDefaultDragHandles: false,
                      onReorderItem: controller.moveQueueItemTo,
                      proxyDecorator: (child, index, animation) {
                        return Material(
                          color: Colors.transparent,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 1, end: 1.02).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeOutCubic,
                              ),
                            ),
                            child: child,
                          ),
                        );
                      },
                      itemBuilder: (context, index) {
                        final item = queue[index];
                        final selected = index == controller.currentQueueIndex;
                        final artist = item.artist.trim().isEmpty
                            ? '未知歌手'
                            : item.artist.trim();
                        final album = item.album.trim().isEmpty
                            ? '未知专辑'
                            : item.album.trim();
                        return Padding(
                          key: ValueKey('${item.id}-${item.uri}'),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              splashColor: _accent.withValues(alpha: 0.18),
                              highlightColor: _accent.withValues(alpha: 0.10),
                              onTap: selected
                                  ? () {}
                                  : () => controller.playQueueAt(index),
                              child: Ink(
                                decoration: BoxDecoration(
                                  color: selected
                                      ? _accent.withValues(alpha: 0.14)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: selected ? _accentStrong : _line,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      _TrackArtwork(
                                        coverUrl: item.coverUrl,
                                        coverFilePath: item.coverFilePath,
                                        icon: selected
                                            ? Icons.graphic_eq
                                            : Icons.music_note,
                                        size: 48,
                                        borderRadius: 12,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: _TrackText(
                                          title: item.title,
                                          subtitle: '$artist  ·  $album',
                                          titleWeight: FontWeight.w400,
                                          titleSize: 15.5,
                                          subtitleSize: 13.2,
                                        ),
                                      ),
                                      _IconAction(
                                        tooltip: '移除',
                                        icon: Icons.close,
                                        onPressed: () =>
                                            controller.removeQueueAt(index),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
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

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({
    required this.icon,
    this.coverUrl,
    this.coverFilePath,
    this.size = 44,
    this.borderRadius = 14,
  });

  final String? coverUrl;
  final String? coverFilePath;
  final IconData icon;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final filePath = coverFilePath?.trim();
    final url = coverUrl?.trim();
    final cacheSize = (size * MediaQuery.devicePixelRatioOf(context)).ceil();
    final fallback = _LeadingIconShell(
      size: size,
      borderRadius: borderRadius,
      child: Icon(icon, color: _accentStrong, size: size * 0.52),
    );

    if (filePath != null && filePath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.file(
          File(filePath),
          width: size,
          height: size,
          cacheWidth: cacheSize,
          cacheHeight: cacheSize,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    }

    if (url == null || url.isEmpty) {
      return fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.network(
        url,
        headers: _networkImageHeadersFor(url),
        width: size,
        height: size,
        cacheWidth: cacheSize,
        cacheHeight: cacheSize,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) {
            return child;
          }
          return _LeadingIconShell(
            size: size,
            borderRadius: borderRadius,
            child: const CupertinoActivityIndicator(radius: 8),
          );
        },
      ),
    );
  }
}

class _LeadingIconShell extends StatelessWidget {
  const _LeadingIconShell({
    required this.size,
    required this.borderRadius,
    required this.child,
  });

  final double size;
  final double borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}
