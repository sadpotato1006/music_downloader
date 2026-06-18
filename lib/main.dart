import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' hide RepeatMode;
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app_controller.dart';
import 'gequbao_source.dart';
import 'models.dart';

const _accent = Color(0xFF8FD9A8);
const _accentStrong = Color(0xFF4AA66A);
const _ink = Color(0xFF1F2A24);
const _muted = Color(0xFF6B756F);
const _surface = Color(0xFFF7FAF8);
const _line = Color(0xFFE5EFE8);
const _networkImageHeaders = {
  'Referer': 'https://www.gequbao.com/',
  'User-Agent': 'QingTing/1.0 (+personal-use)',
};
const _systemUiOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.white,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Colors.white,
  systemNavigationBarIconBrightness: Brightness.dark,
);

const _topNavDestinations = [
  _TopNavDestination(icon: Icons.search, label: '搜索'),
  _TopNavDestination(icon: Icons.downloading, label: '下载'),
  _TopNavDestination(icon: Icons.library_music, label: '本地'),
  _TopNavDestination(icon: Icons.tune, label: '设置'),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(_systemUiOverlayStyle);
  MediaKit.ensureInitialized();
  runApp(const QingTingApp());
}

class QingTingApp extends StatefulWidget {
  const QingTingApp({super.key});

  @override
  State<QingTingApp> createState() => _QingTingAppState();
}

class _QingTingAppState extends State<QingTingApp> {
  late final AppController controller = AppController(source: GequbaoSource());

  @override
  void initState() {
    super.initState();
    controller.bootstrap();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemUiOverlayStyle,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '青听',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: _accent,
            brightness: Brightness.light,
            surface: Colors.white,
          ),
          scaffoldBackgroundColor: _surface,
          fontFamily: 'Microsoft YaHei',
          textTheme: ThemeData.light().textTheme.apply(
            bodyColor: _ink,
            displayColor: _ink,
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: _line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: _line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: _accentStrong, width: 1.4),
            ),
          ),
        ),
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => HomeShell(controller: controller),
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final PageController _pageController;
  Timer? _toastTimer;
  String? _toastMessage;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: controller.selectedIndex);
    controller.addListener(_syncPageWithSelectedIndex);
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_syncPageWithSelectedIndex);
    controller.addListener(_syncPageWithSelectedIndex);
    _syncPageWithSelectedIndex();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    controller.removeListener(_syncPageWithSelectedIndex);
    _pageController.dispose();
    super.dispose();
  }

  void _syncPageWithSelectedIndex() {
    if (!_pageController.hasClients) {
      return;
    }
    final currentPage =
        _pageController.page?.round() ?? _pageController.initialPage;
    if (currentPage == controller.selectedIndex) {
      return;
    }
    _pageController.animateToPage(
      controller.selectedIndex,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    _showGlobalMessage(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 820;
        return Stack(
          children: [
            Scaffold(
              body: Column(
                children: [
                  _TopNavigation(controller: controller, isDesktop: isDesktop),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      onPageChanged: controller.selectIndex,
                      children: [
                        SearchPage(controller: controller),
                        DownloadsPage(controller: controller),
                        LibraryPage(controller: controller),
                        SettingsPage(controller: controller),
                      ],
                    ),
                  ),
                  MiniPlayer(controller: controller, isDesktop: isDesktop),
                ],
              ),
            ),
            if (_toastMessage != null)
              Positioned(
                bottom:
                    MediaQuery.paddingOf(context).bottom +
                    (isDesktop ? 98 : 112),
                left: 18,
                right: 18,
                child: IgnorePointer(
                  child: _QingTingToast(message: _toastMessage!),
                ),
              ),
          ],
        );
      },
    );
  }

  void _showGlobalMessage(BuildContext context) {
    final message = controller.globalMessage;
    if (message == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) {
        return;
      }
      setState(() => _toastMessage = message);
      _toastTimer?.cancel();
      _toastTimer = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) {
          setState(() => _toastMessage = null);
        }
      });
      controller.clearGlobalMessage();
    });
  }
}

class _QingTingToast extends StatelessWidget {
  const _QingTingToast({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: Colors.transparent,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _line),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.music_note,
                      color: _accentStrong,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopNavDestination {
  const _TopNavDestination({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

class _TopNavigation extends StatelessWidget {
  const _TopNavigation({required this.controller, required this.isDesktop});

  final AppController controller;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isDesktop ? 28 : 12,
            isDesktop ? 8 : 5,
            isDesktop ? 28 : 12,
            isDesktop ? 8 : 5,
          ),
          child: Row(
            children: [
              if (isDesktop) ...[const _AppMark(), const SizedBox(width: 22)],
              Expanded(
                child: Row(
                  children: [
                    for (
                      var index = 0;
                      index < _topNavDestinations.length;
                      index++
                    )
                      _TopNavItem(
                        destination: _topNavDestinations[index],
                        selected: controller.selectedIndex == index,
                        onTap: () => controller.selectIndex(index),
                        compact: !isDesktop,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(Icons.music_note, color: _accentStrong),
        ),
        const SizedBox(width: 8),
        const Text(
          '青听',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _TopNavItem extends StatelessWidget {
  const _TopNavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
    required this.compact,
  });

  final _TopNavDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? _accentStrong : _muted;
    return Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 4),
        child: Tooltip(
          message: destination.label,
          child: InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: compact ? 40 : 42,
              padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 12),
              decoration: BoxDecoration(
                color: selected
                    ? _accent.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    destination.icon,
                    color: foreground,
                    size: compact ? 20 : 19,
                  ),
                  SizedBox(width: compact ? 4 : 7),
                  Flexible(
                    child: Text(
                      destination.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? _ink : _muted,
                        fontSize: compact ? 12.5 : 13,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController textController = TextEditingController(
    text: widget.controller.searchQuery,
  );

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cooldownText = controller.sourceCooldownText;
    return _PageFrame(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: textController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: controller.search,
                  decoration: const InputDecoration(
                    hintText: '歌名、歌手或关键词',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: controller.isSearching
                      ? null
                      : () => controller.search(textController.text),
                  icon: controller.isSearching
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward),
                  label: const Text('搜索'),
                ),
              ),
            ],
          ),
          if (cooldownText != null) ...[
            const SizedBox(height: 10),
            _InlineNotice(icon: Icons.timer_outlined, text: cooldownText),
          ],
          const SizedBox(height: 18),
          Expanded(
            child: controller.searchResults.isEmpty
                ? _EmptyState(
                    icon: Icons.music_note,
                    text: controller.searchError ?? '输入关键词开始搜索',
                  )
                : _ResponsiveTrackList(
                    itemCount: controller.searchResults.length,
                    itemBuilder: (context, index) {
                      final result = controller.searchResults[index];
                      return TrackTile(
                        title: result.title,
                        subtitle: result.displayArtist,
                        showArtwork: false,
                        onTap: () => controller.playSearchResult(result),
                        trailing: [
                          _IconAction(
                            tooltip: '下一首播放',
                            icon: controller.preparingQueueNextId == result.id
                                ? Icons.more_horiz
                                : Icons.playlist_add,
                            onPressed:
                                controller.preparingQueueNextId == result.id
                                ? null
                                : () =>
                                      controller.queueSearchResultNext(result),
                            size: 30,
                          ),
                          _IconAction(
                            tooltip: '下载',
                            icon: controller.preparingDownloadId == result.id
                                ? Icons.more_horiz
                                : Icons.download,
                            onPressed: () => _startDownload(context, result),
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

  Future<void> _startDownload(
    BuildContext context,
    TrackSearchResult result,
  ) async {
    final start = await widget.controller.startDownload(result);
    if (!context.mounted) {
      return;
    }
    if (start.didStart) {
      widget.controller.showMessage('已加入下载队列');
      return;
    }
    if (start.didFail) {
      widget.controller.showMessage(start.message ?? '创建下载任务失败');
      return;
    }

    final candidate = start.candidate!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('非 MP3 格式'),
        content: Text('当前页面只找到 ${candidate.format.toUpperCase()}，是否继续下载？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final retry = await widget.controller.startDownload(
        result,
        allowNonMp3: true,
      );
      if (context.mounted) {
        widget.controller.showMessage(
          retry.didStart ? '已加入下载队列' : retry.message ?? '下载失败',
        );
      }
    }
  }
}

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.controller});

  final AppController controller;

  Future<void> _scanDownloadDirectory() async {
    final imported = await controller.scanCurrentDownloadDirectory();
    if (imported > 0) {
      controller.selectIndex(2);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      child: controller.downloadTasks.isEmpty
          ? Column(
              children: [
                _DirectoryScanButton(
                  controller: controller,
                  onPressed: _scanDownloadDirectory,
                ),
                const SizedBox(height: 12),
                const Expanded(
                  child: _EmptyState(icon: Icons.downloading, text: '还没有下载任务'),
                ),
              ],
            )
          : Column(
              children: [
                _DirectoryScanButton(
                  controller: controller,
                  onPressed: _scanDownloadDirectory,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.separated(
                    itemCount: controller.downloadTasks.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final task = controller.downloadTasks[index];
                      return _TaskTile(controller: controller, task: task);
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.controller, required this.task});

  final AppController controller;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final showProgress =
        task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.paused;
    String? localCoverFilePath;
    if (task.status == DownloadStatus.completed) {
      for (final track in controller.downloadedTracks) {
        if (track.path == task.savePath) {
          localCoverFilePath = track.coverFilePath;
          break;
        }
      }
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _tileDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TrackArtwork(
                coverUrl: localCoverFilePath == null
                    ? task.track.coverUrl
                    : null,
                coverFilePath: localCoverFilePath,
                icon: Icons.audio_file,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TrackText(
                  title: task.track.title,
                  subtitle:
                      '${task.track.displayArtist} · ${_statusLabel(task.status)}',
                ),
              ),
              if (task.status == DownloadStatus.downloading)
                _IconAction(
                  tooltip: '暂停',
                  icon: Icons.pause,
                  onPressed: () => controller.pauseDownload(task.id),
                ),
              if (task.status == DownloadStatus.failed ||
                  task.status == DownloadStatus.paused ||
                  task.status == DownloadStatus.canceled)
                _IconAction(
                  tooltip: '重试',
                  icon: Icons.refresh,
                  onPressed: () => controller.retryDownload(task.id),
                ),
              if (task.status != DownloadStatus.completed)
                _IconAction(
                  tooltip: '取消',
                  icon: Icons.close,
                  onPressed: () => controller.cancelDownload(task.id),
                ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: task.progress <= 0
                  ? null
                  : task.progress.clamp(0, 1).toDouble(),
              minHeight: 6,
              borderRadius: BorderRadius.circular(99),
            ),
          ],
          if (task.error != null) ...[
            const SizedBox(height: 8),
            Text(task.error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 8),
          Text(
            task.totalBytes == null
                ? task.savePath
                : '${_formatBytes(task.receivedBytes)} / ${_formatBytes(task.totalBytes!)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final TextEditingController queryController = TextEditingController(
    text: widget.controller.libraryQuery,
  );

  AppController get controller => widget.controller;

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (queryController.text != controller.libraryQuery) {
      queryController.text = controller.libraryQuery;
    }
  }

  @override
  void dispose() {
    queryController.dispose();
    super.dispose();
  }

  Future<void> _showLibrarySearch() async {
    final textController = TextEditingController(text: controller.libraryQuery);
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('搜索本地歌曲'),
          content: TextField(
            controller: textController,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) => Navigator.pop(context, value),
            decoration: const InputDecoration(
              hintText: '歌名、歌手或专辑',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('清空'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, textController.text),
              child: const Text('搜索'),
            ),
          ],
        ),
      );
      if (value == null || !mounted) {
        return;
      }
      queryController.text = value;
      controller.setLibraryQuery(value);
      setState(() {});
    } finally {
      textController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleTracks = controller.visibleDownloadedTracks;
    return _PageFrame(
      horizontalPadding: 18,
      child: Column(
        children: [
          _LibraryToolbar(controller: controller, onSearch: _showLibrarySearch),
          const SizedBox(height: 8),
          Expanded(
            child: controller.downloadedTracks.isEmpty
                ? const _EmptyState(
                    icon: Icons.library_music,
                    text: '下载完成后会出现在这里',
                  )
                : visibleTracks.isEmpty
                ? const _EmptyState(icon: Icons.search_off, text: '没有匹配的本地歌曲')
                : _ResponsiveTrackList(
                    itemCount: visibleTracks.length,
                    itemBuilder: (context, index) {
                      final track = visibleTracks[index];
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
                        onTap: () => controller.playDownloaded(track),
                        trailing: [
                          _IconAction(
                            tooltip: '下一首播放',
                            icon: controller.preparingQueueNextId == track.id
                                ? Icons.more_horiz
                                : Icons.playlist_add,
                            onPressed:
                                controller.preparingQueueNextId == track.id
                                ? null
                                : () => controller.queueDownloadedNext(track),
                            size: 28,
                          ),
                          _LibraryMoreActions(
                            controller: controller,
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

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController pathController;
  late final FocusNode pathFocusNode;
  bool _concurrentWarningOpen = false;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    pathController = TextEditingController(
      text: controller.settings!.downloadDirectory,
    );
    pathFocusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentPath = controller.settings!.downloadDirectory;
    if (!pathFocusNode.hasFocus && pathController.text != currentPath) {
      pathController.text = currentPath;
    }
  }

  @override
  void dispose() {
    pathController.dispose();
    pathFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings!;
    return _PageFrame(
      child: ListView(
        children: [
          _SettingPanel(
            title: '下载目录',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: pathController,
                  focusNode: pathFocusNode,
                  minLines: 1,
                  maxLines: 2,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.folder),
                    hintText: '输入下载保存路径',
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      if (Platform.isWindows)
                        OutlinedButton.icon(
                          onPressed: () => _pickDownloadDirectory(context),
                          icon: const Icon(Icons.folder_open),
                          label: const Text('选择文件夹'),
                        ),
                      FilledButton.icon(
                        onPressed: () => _saveDownloadDirectory(context),
                        icon: const Icon(Icons.save),
                        label: const Text('保存路径'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SettingPanel(
            title: '本地歌曲',
            child: _DirectoryScanButton(
              controller: controller,
              onPressed: () => _scanDownloadDirectory(context),
            ),
          ),
          const SizedBox(height: 12),
          _SettingPanel(
            title: '启动播放',
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '启动软件时自动播放音乐',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Switch(
                  value: settings.autoPlayOnStartup,
                  onChanged: controller.setAutoPlayOnStartup,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SettingPanel(
            title: '启动页面',
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.search),
                    label: Text('搜索'),
                  ),
                  ButtonSegment(
                    value: 2,
                    icon: Icon(Icons.library_music),
                    label: Text('本地'),
                  ),
                ],
                selected: {settings.defaultStartupPageIndex == 2 ? 2 : 0},
                onSelectionChanged: (selection) =>
                    controller.setDefaultStartupPageIndex(selection.first),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SettingPanel(
            title: '同时下载',
            child: Row(
              children: [
                Expanded(
                  child: Slider(
                    min: 1,
                    max: 4,
                    divisions: 3,
                    label: '${settings.concurrentDownloads}',
                    value: settings.concurrentDownloads.toDouble(),
                    onChanged: (value) =>
                        _setConcurrentDownloads(context, value.round()),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${settings.concurrentDownloads}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SettingPanel(
            title: '源代码',
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _openProjectRepository(context),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    FaIcon(FontAwesomeIcons.github, size: 22, color: _ink),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'https://github.com/sadpotato1006/music_downloader',
                        maxLines: 2,
                        softWrap: true,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          color: _accentStrong,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationColor: _accentStrong,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _SettingPanel(
            title: '联系作者',
            child: Row(
              children: [
                Icon(Icons.mail_outline, color: _muted),
                SizedBox(width: 12),
                Expanded(
                  child: SelectableText(
                    'zhangzzx06@gmail.com',
                    style: TextStyle(color: _ink, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Center(
            child: Text(
              '资源来源于网络，如有侵权请联系删除',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: _muted),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveDownloadDirectory(BuildContext context) async {
    pathFocusNode.unfocus();
    final success = await controller.setDownloadDirectory(pathController.text);
    if (!context.mounted) {
      return;
    }
    if (!success && controller.lastDirectoryNeedsAllFilesAccess) {
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('需要文件访问权限'),
          content: const Text('这个目录属于安卓公共存储。请在系统设置里允许青听访问所有文件，然后回到这里再次保存路径。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.settings),
              label: const Text('去授权'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        await controller.openAllFilesAccessSettings();
      }
      return;
    }
    controller.showMessage(success ? '下载目录已保存' : '下载目录不可用');
    if (!success) {
      pathController.text = controller.settings!.downloadDirectory;
    } else {
      pathController.text = controller.settings!.downloadDirectory;
    }
  }

  Future<void> _pickDownloadDirectory(BuildContext context) async {
    pathFocusNode.unfocus();
    final selected = await controller.pickDownloadDirectory();
    if (!context.mounted || selected == null || selected.trim().isEmpty) {
      return;
    }
    pathController.text = selected;
    await _saveDownloadDirectory(context);
  }

  Future<void> _scanDownloadDirectory(BuildContext context) async {
    await controller.scanCurrentDownloadDirectory();
  }

  Future<void> _setConcurrentDownloads(BuildContext context, int value) async {
    final normalized = value.clamp(1, 4).toInt();
    final current = controller.settings?.concurrentDownloads ?? 1;
    if (normalized == current) {
      return;
    }
    if (normalized > current) {
      if (_concurrentWarningOpen) {
        return;
      }
      _concurrentWarningOpen = true;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认提高同时下载数？'),
          content: const Text(
            '同时下载越多，请求越频繁，可能更容易被网站拒绝访问或触发临时限制。建议保持 1，确认后再提高。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认提高'),
            ),
          ],
        ),
      );
      _concurrentWarningOpen = false;
      if (confirmed != true || !context.mounted) {
        return;
      }
    }
    await controller.setConcurrentDownloads(normalized);
  }

  Future<void> _openProjectRepository(BuildContext context) async {
    final opened = await controller.openProjectRepository();
    if (!context.mounted || opened) {
      return;
    }
    controller.showMessage('无法打开 GitHub 链接');
  }
}

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
    final item = controller.currentItem;
    final lyricLines = _parseLyricLines(item?.lyrics);
    final currentLyricIndex = _currentLyricIndex(
      lyricLines,
      controller.player.position,
    );

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
        final columns = _trackListColumnCount(context, constraints);
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

int _trackListColumnCount(BuildContext context, BoxConstraints constraints) {
  final window = MediaQuery.sizeOf(context);
  final isWideAndShort = window.height / window.width <= 0.72;
  if (!isWideAndShort || constraints.maxWidth < 980) {
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
  const _EmptyState({required this.icon, required this.text});

  final IconData icon;
  final String text;

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
  final ScrollController scrollController = ScrollController();
  int lastScrolledIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    _scheduleScroll();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
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

  void _scheduleScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) {
        return;
      }
      final lines = _parseLyricLines(widget.controller.currentItem?.lyrics);
      final currentIndex = _currentLyricIndex(
        lines,
        widget.controller.player.position,
      );
      if (currentIndex < 0 || currentIndex == lastScrolledIndex) {
        return;
      }
      lastScrolledIndex = currentIndex;
      var target = currentIndex * 46.0 - 140;
      if (target < 0) {
        target = 0;
      }
      final maxExtent = scrollController.position.maxScrollExtent;
      if (target > maxExtent) {
        target = maxExtent;
      }
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
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
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 84),
                        itemCount: lines.length,
                        itemBuilder: (context, index) {
                          final selected = index == currentIndex;
                          final line = lines[index];
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => widget.controller.seekTo(line.time),
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 160),
                              style: TextStyle(
                                color: selected ? _accentStrong : _muted,
                                fontSize: selected ? 18 : 15,
                                fontWeight: selected
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
                                  line.text,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
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
          tooltip: singleLoop ? '单曲循环' : '随机播放',
          icon: singleLoop ? Icons.repeat_one : Icons.shuffle,
          selected: !singleLoop,
          onPressed: controller.toggleLyricsPlaybackMode,
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
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  '${queue.length} 首',
                  style: const TextStyle(color: _muted),
                ),
                const SizedBox(width: 10),
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
        headers: _networkImageHeaders,
        width: size,
        height: size,
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
    lyricsController.dispose();
    coverController.dispose();
  }
}

enum _LibraryTrackAction { edit, openFile, revealFile, removeRecord }

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
            case _LibraryTrackAction.edit:
              _showEditDownloadedTrackDialog(context, controller, track);
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
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _LibraryTrackAction.edit,
            child: _MoreActionLabel(icon: Icons.edit_outlined, label: '编辑信息'),
          ),
          PopupMenuItem(
            value: _LibraryTrackAction.openFile,
            child: _MoreActionLabel(icon: Icons.open_in_new, label: '打开文件'),
          ),
          PopupMenuItem(
            value: _LibraryTrackAction.revealFile,
            child: _MoreActionLabel(icon: Icons.folder_open, label: '打开位置'),
          ),
          PopupMenuItem(
            value: _LibraryTrackAction.removeRecord,
            child: _MoreActionLabel(
              icon: Icons.delete_outline,
              label: '删除记录',
              destructive: true,
            ),
          ),
        ],
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

class _LyricLine {
  const _LyricLine({required this.time, required this.text});

  final Duration time;
  final String text;
}

List<_LyricLine> _parseLyricLines(String? rawLyrics) {
  final raw = rawLyrics?.trim();
  if (raw == null || raw.isEmpty) {
    return const [];
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

  if (timedLines.isNotEmpty) {
    timedLines.sort((a, b) => a.time.compareTo(b.time));
    return timedLines;
  }

  return [
    for (var index = 0; index < plainLines.length; index += 1)
      _LyricLine(
        time: Duration(seconds: index * 3),
        text: plainLines[index],
      ),
  ];
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
  if (lines.isEmpty) {
    return -1;
  }
  var current = 0;
  for (var index = 0; index < lines.length; index += 1) {
    if (lines[index].time <= position) {
      current = index;
      continue;
    }
    break;
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
