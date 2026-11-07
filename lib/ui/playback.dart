part of '../main.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({
    super.key,
    required this.controller,
    required this.isDesktop,
  });

  final AppController controller;
  final bool isDesktop;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  List<LyricLine> _lines = const [];
  int _highlightedIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.player.positionListenable.addListener(_onPositionChanged);
    _updateLyricState();
  }

  @override
  void didUpdateWidget(MiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.player.positionListenable.removeListener(
        _onPositionChanged,
      );
      widget.controller.player.positionListenable.addListener(
        _onPositionChanged,
      );
    }
    // The parent rebuilds on song, metadata and playback state changes.
    _updateLyricState();
  }

  void _updateLyricState() {
    _lines = parseLyricLines(widget.controller.currentItem?.lyrics);
    _highlightedIndex = _currentLyricIndex(
      _lines,
      widget.controller.player.position,
    );
  }

  void _onPositionChanged() {
    final index = _currentLyricIndex(_lines, widget.controller.player.position);
    if (index != _highlightedIndex) {
      setState(() => _highlightedIndex = index);
    }
  }

  @override
  void dispose() {
    widget.controller.player.positionListenable.removeListener(
      _onPositionChanged,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final isDesktop = widget.isDesktop;
    final item = controller.currentItem;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? 24 : 12,
          6,
          isDesktop ? 24 : 12,
          12,
        ),
        child: ThemeSurface(
          key: const ValueKey('mini-player-surface'),
          isolateContent: true,
          radius: 24,
          padding: EdgeInsets.symmetric(
            horizontal: isDesktop ? 20 : 12,
            vertical: 12,
          ),
          child: SizedBox(
            height: MediaQuery.textScalerOf(context).scale(isDesktop ? 60 : 58),
            child: isDesktop
                ? _DesktopMiniPlayerContent(
                    controller: controller,
                    item: item,
                    lyricLines: _lines,
                    currentLyricIndex: _highlightedIndex,
                  )
                : _MobileMiniPlayerContent(
                    controller: controller,
                    item: item,
                    lyricLines: _lines,
                    currentLyricIndex: _highlightedIndex,
                  ),
          ),
        ),
      ),
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
  final List<LyricLine> lyricLines;
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
                    subtitle:
                        controller.playbackStatusText ??
                        lyricText ??
                        item?.artist ??
                        '青听',
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
  final List<LyricLine> lyricLines;
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
                    subtitle:
                        controller.playbackStatusText ??
                        lyricText ??
                        item?.artist ??
                        '青听',
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
          tooltip: controller.currentPlaybackHealth.error != null
              ? '重试播放'
              : controller.player.isPlaying
              ? '暂停'
              : '播放',
          onPressed: enabled ? controller.togglePlayPause : null,
          icon: Icon(
            controller.currentPlaybackHealth.error != null
                ? Icons.refresh
                : controller.player.isPlaying
                ? Icons.pause
                : Icons.play_arrow,
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
            mainAxisExtent:
                72 *
                (MediaQuery.textScalerOf(context).scale(16) / 16).clamp(
                  1,
                  double.infinity,
                ),
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
    this.onLongPress,
    this.selected = false,
    this.current = false,
    this.playing = false,
    this.preparing = false,
    this.buffering = false,
    this.playbackError,
    this.onRetry,
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
  final VoidCallback? onLongPress;
  final bool selected;
  final bool current;
  final bool playing;
  final bool preparing;
  final bool buffering;
  final String? playbackError;
  final VoidCallback? onRetry;
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
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        splashColor: themeAccent(context).withValues(alpha: 0.18),
        highlightColor: themeAccent(context).withValues(alpha: 0.10),
        child: Ink(
          decoration: selected || current
              ? tileDecoration(context, song: true).copyWith(
                  color: themeTint(context),
                  border: Border.all(color: themeAccent(context), width: 0.8),
                )
              : tileDecoration(context, song: true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (showArtwork) ...[
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      _TrackArtwork(
                        coverUrl: coverUrl,
                        coverFilePath: coverFilePath,
                        icon: Icons.music_note,
                        size: artworkSize,
                        borderRadius: 12,
                      ),
                      if (preparing || buffering)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: themeTint(context),
                            shape: BoxShape.circle,
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(5),
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      if (playbackError != null && onRetry != null)
                        IconButton.filledTonal(
                          tooltip: '重试播放',
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh),
                        ),
                    ],
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Tooltip(
                    message: playbackError ?? '',
                    child: _TrackText(
                      title: title,
                      subtitle: subtitle,
                      tertiary: buffering
                          ? '正在缓冲…'
                          : preparing
                          ? '正在准备播放'
                          : playbackError != null
                          ? '播放失败：$playbackError'
                          : current && !playing
                          ? '已暂停'
                          : tertiary,
                      tertiaryColor: playbackError != null
                          ? Theme.of(context).colorScheme.error
                          : preparing || buffering || current
                          ? themeAccent(context)
                          : null,
                      titleWeight: titleWeight,
                      titleSize: titleSize,
                      subtitleSize: subtitleSize,
                      tertiarySize: tertiarySize,
                      compact: true,
                    ),
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
    this.tertiaryColor,
    this.titleWeight = FontWeight.w700,
    this.titleSize = 15,
    this.subtitleSize = 13,
    this.tertiarySize = 12,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final String? tertiary;
  final Color? tertiaryColor;
  final FontWeight titleWeight;
  final double titleSize;
  final double subtitleSize;
  final double tertiarySize;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final lineHeight = compact && tertiary?.trim().isNotEmpty == true
        ? 1.2
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: titleWeight,
            fontSize: titleSize,
            height: lineHeight,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: appMuted,
            fontSize: subtitleSize,
            height: lineHeight,
          ),
        ),
        if (tertiary != null && tertiary!.trim().isNotEmpty) ...[
          const SizedBox(height: 1),
          Text(
            tertiary!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tertiaryColor ?? appMuted.withValues(alpha: 0.82),
              fontSize: tertiarySize,
              height: lineHeight,
            ),
          ),
        ],
      ],
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
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: themeAccent(context).withValues(alpha: 0.52),
              size: 44,
            ),
            const SizedBox(height: 18),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: appMuted),
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
  Object? _lastView;
  Object get _view => widget.controller.playbackViewState;

  static const _lyricsMinListPadding = 84.0;
  static const _estimatedLyricLineExtent = 58.0;

  final ScrollController scrollController = ScrollController();
  final Map<int, GlobalKey> _lyricLineKeys = {};
  List<LyricLine> _lines = const [];
  int _highlightedIndex = -1;
  bool _scrollScheduled = false;
  bool _followingLyrics = true;
  (String, String)? _lyricItemKey;
  int lastScrolledIndex = -1;
  String? lastScrolledItemId;
  double _lyricsVerticalPadding = _lyricsMinListPadding;

  @override
  void initState() {
    super.initState();
    _lastView = _view;
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.player.positionListenable.addListener(
      _handlePlayerPositionChanged,
    );
    _updateLyricState();
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
    final view = _view;
    if (view == _lastView) return;
    _lastView = view;
    if (!mounted) {
      return;
    }
    setState(_updateLyricState);
    _scheduleScroll();
  }

  void _updateLyricState() {
    final item = widget.controller.currentItem;
    final key = item == null ? null : (item.id, item.uri);
    if (key != _lyricItemKey) {
      _lyricItemKey = key;
      _followingLyrics = true;
      lastScrolledIndex = -1;
    }
    final lines = parseLyricLines(widget.controller.currentItem?.lyrics);
    if (!identical(lines, _lines)) {
      _lines = lines;
      _lyricLineKeys.clear();
      lastScrolledIndex = -1;
    }
    _highlightedIndex = _currentLyricIndex(
      _lines,
      widget.controller.player.position,
    );
  }

  void _handlePlayerPositionChanged() {
    if (!mounted) {
      return;
    }
    final index = _currentLyricIndex(_lines, widget.controller.player.position);
    if (index == _highlightedIndex) return;
    setState(() => _highlightedIndex = index);
    _scheduleScroll();
  }

  void _scheduleScroll() {
    if (_scrollScheduled || !_followingLyrics) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_followingLyrics || !scrollController.hasClients) {
        return;
      }
      final item = widget.controller.currentItem;
      if (item?.id != lastScrolledItemId) {
        lastScrolledItemId = item?.id;
        lastScrolledIndex = -1;
      }
      final currentIndex = _highlightedIndex;
      if (currentIndex < 0 || currentIndex == lastScrolledIndex) {
        return;
      }
      final itemKey = _lyricItemKey;
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
          if (!mounted ||
              !_followingLyrics ||
              _lyricItemKey != itemKey ||
              _highlightedIndex != currentIndex) {
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

  bool _handleLyricsScroll(ScrollNotification notification) {
    final manual =
        notification is ScrollStartNotification &&
            notification.dragDetails != null ||
        notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle;
    if (notification.depth == 0 && manual && _followingLyrics) {
      setState(() => _followingLyrics = false);
    }
    return false;
  }

  void _resumeLyricsFollowing() {
    setState(() {
      _followingLyrics = true;
      lastScrolledIndex = -1;
    });
    _scheduleScroll();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.controller.currentItem;
    final lines = _lines;
    final currentIndex = _highlightedIndex;
    final duration = widget.controller.player.duration;
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
                  color: themeLine(context),
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
              if (widget.controller.playbackStatusText != null)
                _PlaybackStatusNotice(controller: widget.controller),
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
                          return NotificationListener<ScrollNotification>(
                            onNotification: _handleLyricsScroll,
                            child: ListView.builder(
                              key: const ValueKey('lyrics-list'),
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
                                  onTap:
                                      !isLyricTimestampSeekable(
                                        lines[index].time,
                                        duration,
                                      )
                                      ? null
                                      : () => widget.controller.seekToLyricLine(
                                          item!,
                                          lines[index].time,
                                        ),
                                  child: AnimatedDefaultTextStyle(
                                    duration: const Duration(milliseconds: 160),
                                    style: TextStyle(
                                      color: index == currentIndex
                                          ? themeAccent(context)
                                          : appMuted,
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
                            ),
                          );
                        },
                      ),
              ),
              if (!_followingLyrics &&
                  lines.isNotEmpty &&
                  lines.first.time != null)
                TextButton.icon(
                  onPressed: _resumeLyricsFollowing,
                  icon: const Icon(Icons.my_location, size: 18),
                  label: const Text('回到当前歌词'),
                ),
              const SizedBox(height: 8),
              _LyricsProgress(
                key: ValueKey((item?.id, item?.uri)),
                controller: widget.controller,
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

class _PlaybackStatusNotice extends StatelessWidget {
  const _PlaybackStatusNotice({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final error = controller.currentPlaybackHealth.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            error == null ? Icons.hourglass_top : Icons.error_outline,
            size: 18,
            color: themeAccent(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error == null ? '正在缓冲…' : '播放中断：$error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (error != null)
            TextButton(
              onPressed: controller.retryCurrentPlayback,
              child: const Text('重试播放'),
            ),
        ],
      ),
    );
  }
}

class _LyricsProgress extends StatefulWidget {
  const _LyricsProgress({super.key, required this.controller});

  final AppController controller;

  @override
  State<_LyricsProgress> createState() => _LyricsProgressState();
}

class _LyricsProgressState extends State<_LyricsProgress> {
  double? _previewMs;
  double? _pendingMs;
  Timer? _seekTimer;
  PlayerItem? _dragItem;
  int _seekGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.player.positionListenable.addListener(_confirmSeek);
  }

  @override
  void didUpdateWidget(_LyricsProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.player.positionListenable.removeListener(
        _confirmSeek,
      );
      widget.controller.player.positionListenable.addListener(_confirmSeek);
      _seekGeneration++;
      _seekTimer?.cancel();
      _previewMs = _pendingMs = null;
    }
  }

  @override
  void dispose() {
    _seekTimer?.cancel();
    widget.controller.player.positionListenable.removeListener(_confirmSeek);
    super.dispose();
  }

  void _clearPreview() {
    _seekTimer?.cancel();
    setState(() => _previewMs = _pendingMs = null);
  }

  void _confirmSeek() {
    if (_pendingMs != null &&
        (widget.controller.player.position.inMilliseconds - _pendingMs!).abs() <
            1000) {
      _clearPreview();
    }
  }

  Future<void> _finishSeek(double value) async {
    if (!mounted) return;
    final controller = widget.controller;
    final current = controller.currentItem;
    final generation = ++_seekGeneration;
    if (current == null ||
        current.id != _dragItem?.id ||
        current.uri != _dragItem?.uri) {
      setState(() => _previewMs = null);
      return;
    }
    _pendingMs = value;
    _seekTimer?.cancel();
    // Native players may acknowledge the seek before publishing its position.
    // Keep the preview until that position arrives, with a bounded fallback.
    _seekTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && generation == _seekGeneration) _clearPreview();
    });
    try {
      await controller.seekTo(Duration(milliseconds: value.round()));
      if (mounted && generation == _seekGeneration) {
        _confirmSeek();
      }
    } catch (_) {
      if (mounted && generation == _seekGeneration) {
        _clearPreview();
        controller.showGlobalMessage('跳转失败，请重试');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ValueListenableBuilder<Duration>(
      valueListenable: controller.player.positionListenable,
      builder: (context, position, child) {
        final maximum = controller.maximumSeekPosition.inMilliseconds;
        final maxMs = (maximum <= 0 ? 1 : maximum).toDouble();
        final displayedMs = (_previewMs ?? position.inMilliseconds.toDouble())
            .clamp(0.0, maxMs);
        return Row(
          children: [
            SizedBox(
              width: 42,
              child: Text(
                _formatDuration(Duration(milliseconds: displayedMs.round())),
                style: const TextStyle(fontSize: 12, color: appMuted),
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
                  key: const ValueKey('lyrics-progress'),
                  value: displayedMs,
                  min: 0,
                  max: maxMs,
                  onChangeStart: (_) {
                    _seekGeneration++;
                    _seekTimer?.cancel();
                    _pendingMs = null;
                    _dragItem = controller.currentItem;
                  },
                  onChangeEnd: _finishSeek,
                  onChanged: controller.currentItem == null || maximum <= 0
                      ? null
                      : (value) => setState(() => _previewMs = value),
                ),
              ),
            ),
            SizedBox(
              width: 42,
              child: Text(
                _formatDuration(controller.player.duration),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, color: appMuted),
              ),
            ),
          ],
        );
      },
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
          backgroundColor: selected
              ? themeAccent(context).withValues(alpha: 0.18)
              : null,
          foregroundColor: selected ? themeAccent(context) : appInk,
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
        tooltip: controller.currentPlaybackHealth.error != null
            ? '重试播放'
            : controller.player.isPlaying
            ? '暂停'
            : '播放',
        onPressed: enabled ? controller.togglePlayPause : null,
        icon: Icon(
          controller.currentPlaybackHealth.error != null
              ? Icons.refresh
              : controller.player.isPlaying
              ? Icons.pause
              : Icons.play_arrow,
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
                  color: themeLine(context),
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
              style: const TextStyle(color: appMuted, fontSize: 13),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 14.5, color: appInk),
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
  Object? _lastView;
  Object get _view => (
    widget.controller.queue,
    widget.controller.currentQueueIndex,
    widget.controller.shuffleEnabled,
  );

  static const _queueItemExtent = 80.0;

  final ScrollController queueScrollController = ScrollController();
  int? _lastCenteredQueueIndex;

  @override
  void initState() {
    super.initState();
    _lastView = _view;
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
    final view = _view;
    if (view == _lastView) return;
    _lastView = view;
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
                color: themeLine(context),
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
                  style: const TextStyle(color: appMuted),
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
                              splashColor: themeAccent(
                                context,
                              ).withValues(alpha: 0.18),
                              highlightColor: themeAccent(
                                context,
                              ).withValues(alpha: 0.10),
                              onTap: selected
                                  ? () {}
                                  : () => controller.playQueueAt(index),
                              child: Ink(
                                decoration: BoxDecoration(
                                  color: selected
                                      ? themeAccent(
                                          context,
                                        ).withValues(alpha: 0.14)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: selected
                                        ? themeAccent(context)
                                        : themeLine(context),
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
      child: Icon(icon, color: themeAccent(context), size: size * 0.52),
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
        color: themeAccent(context).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}
