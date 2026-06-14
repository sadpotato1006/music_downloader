import 'package:flutter/cupertino.dart' hide RepeatMode;
import 'package:flutter/material.dart' hide RepeatMode;
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

const _topNavDestinations = [
  _TopNavDestination(icon: Icons.search, label: '搜索'),
  _TopNavDestination(icon: Icons.downloading, label: '下载'),
  _TopNavDestination(icon: Icons.library_music, label: '本地'),
  _TopNavDestination(icon: Icons.tune, label: '设置'),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
    return MaterialApp(
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
        builder: (context, _) {
          if (!controller.isReady) {
            return const _LoadingScreen();
          }
          return HomeShell(controller: controller);
        },
      ),
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(radius: 14),
            SizedBox(height: 18),
            Text('青听'),
          ],
        ),
      ),
    );
  }
}

class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    _showGlobalMessage(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 820;
        return Scaffold(
          body: Column(
            children: [
              _TopNavigation(controller: controller, isDesktop: isDesktop),
              Expanded(child: _currentPage()),
              MiniPlayer(controller: controller, isDesktop: isDesktop),
            ],
          ),
        );
      },
    );
  }

  Widget _currentPage() {
    return switch (controller.selectedIndex) {
      0 => SearchPage(controller: controller),
      1 => DownloadsPage(controller: controller),
      2 => LibraryPage(controller: controller),
      _ => SettingsPage(controller: controller),
    };
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      controller.clearGlobalMessage();
    });
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
    return SafeArea(
      bottom: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? 28 : 12,
          isDesktop ? 12 : 8,
          isDesktop ? 28 : 12,
          isDesktop ? 12 : 8,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: _line)),
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
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.music_note, color: _accentStrong),
        ),
        const SizedBox(width: 10),
        const Text(
          '青听',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
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
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: compact ? 46 : 48,
              padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 14),
              decoration: BoxDecoration(
                color: selected
                    ? _accent.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    destination.icon,
                    color: foreground,
                    size: compact ? 22 : 20,
                  ),
                  SizedBox(width: compact ? 5 : 8),
                  Flexible(
                    child: Text(
                      destination.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? _ink : _muted,
                        fontSize: compact ? 13 : 14,
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
    return _PageFrame(
      title: '青听',
      subtitle: '歌曲宝',
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
          const SizedBox(height: 18),
          Expanded(
            child: controller.searchResults.isEmpty
                ? _EmptyState(
                    icon: Icons.music_note,
                    text: controller.searchError ?? '输入关键词开始搜索',
                  )
                : ListView.separated(
                    itemCount: controller.searchResults.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final result = controller.searchResults[index];
                      return TrackTile(
                        title: result.title,
                        subtitle: result.displayArtist,
                        coverUrl: result.coverUrl,
                        trailing: [
                          _IconAction(
                            tooltip: '播放',
                            icon: controller.resolvingPlayId == result.id
                                ? Icons.more_horiz
                                : Icons.play_arrow,
                            onPressed: () =>
                                controller.playSearchResult(result),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已加入下载队列')));
      return;
    }
    if (start.didFail) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(start.message ?? '创建下载任务失败')));
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(retry.didStart ? '已加入下载队列' : retry.message ?? '下载失败'),
          ),
        );
      }
    }
  }
}

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: '下载',
      subtitle: '${controller.downloadTasks.length} 个任务',
      child: controller.downloadTasks.isEmpty
          ? const _EmptyState(icon: Icons.downloading, text: '还没有下载任务')
          : ListView.separated(
              itemCount: controller.downloadTasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final task = controller.downloadTasks[index];
                return _TaskTile(controller: controller, task: task);
              },
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
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _tileDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TrackArtwork(
                coverUrl: task.track.coverUrl,
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

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return _PageFrame(
      title: '本地',
      subtitle: '${controller.downloadedTracks.length} 首',
      child: controller.downloadedTracks.isEmpty
          ? const _EmptyState(icon: Icons.library_music, text: '下载完成后会出现在这里')
          : ListView.separated(
              itemCount: controller.downloadedTracks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final track = controller.downloadedTracks[index];
                return TrackTile(
                  title: track.title,
                  subtitle:
                      '${track.artist.isEmpty ? '未知歌手' : track.artist} · ${track.format.toUpperCase()}',
                  coverUrl: track.coverUrl,
                  trailing: [
                    _IconAction(
                      tooltip: '播放',
                      icon: Icons.play_arrow,
                      onPressed: () => controller.playDownloaded(track),
                    ),
                    _LibraryMoreActions(controller: controller, track: track),
                  ],
                );
              },
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
      title: '设置',
      subtitle: '轻绿 · 简洁',
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
                  child: FilledButton.icon(
                    onPressed: () => _saveDownloadDirectory(context),
                    icon: const Icon(Icons.save),
                    label: const Text('保存路径'),
                  ),
                ),
              ],
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
                        controller.setConcurrentDownloads(value.round()),
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
                        'github.com/sadpotato1006/music_downloader',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _accentStrong,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationColor: _accentStrong,
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Icon(Icons.chevron_right, color: _muted),
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(success ? '下载目录已保存' : '下载目录不可用')));
    if (!success) {
      pathController.text = controller.settings!.downloadDirectory;
    } else {
      pathController.text = controller.settings!.downloadDirectory;
    }
  }

  Future<void> _openProjectRepository(BuildContext context) async {
    final opened = await controller.openProjectRepository();
    if (!context.mounted || opened) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开 GitHub 链接')));
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
    final durationMs = controller.player.duration.inMilliseconds;
    final positionMs = controller.player.position.inMilliseconds.clamp(
      0,
      durationMs <= 0 ? 1 : durationMs,
    );
    final maxMs = (durationMs <= 0 ? 1 : durationMs).toDouble();

    return SafeArea(
      top: false,
      child: Container(
        height: isDesktop ? 96 : 112,
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
                positionMs: positionMs.toDouble(),
                maxMs: maxMs,
              )
            : _MobileMiniPlayerContent(
                controller: controller,
                item: item,
                positionMs: positionMs.toDouble(),
                maxMs: maxMs,
              ),
      ),
    );
  }
}

class _DesktopMiniPlayerContent extends StatelessWidget {
  const _DesktopMiniPlayerContent({
    required this.controller,
    required this.item,
    required this.positionMs,
    required this.maxMs,
  });

  final AppController controller;
  final PlayerItem? item;
  final double positionMs;
  final double maxMs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _TrackArtwork(coverUrl: item?.coverUrl, icon: Icons.graphic_eq),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: _TrackText(
            title: item?.title ?? '未播放',
            subtitle: item?.artist ?? '青听',
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          flex: 3,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PlaybackControls(controller: controller, compact: false),
              Row(
                children: [
                  Text(
                    _formatDuration(controller.player.position),
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                  Expanded(
                    child: Slider(
                      value: positionMs,
                      min: 0,
                      max: maxMs,
                      onChanged: item == null
                          ? null
                          : (value) => controller.seekTo(
                              Duration(milliseconds: value.round()),
                            ),
                    ),
                  ),
                  Text(
                    _formatDuration(controller.player.duration),
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        const Icon(Icons.volume_up, color: _muted, size: 19),
        SizedBox(
          width: 120,
          child: Slider(
            value: controller.player.volume.clamp(0, 100).toDouble(),
            min: 0,
            max: 100,
            onChanged: controller.setVolume,
          ),
        ),
      ],
    );
  }
}

class _MobileMiniPlayerContent extends StatelessWidget {
  const _MobileMiniPlayerContent({
    required this.controller,
    required this.item,
    required this.positionMs,
    required this.maxMs,
  });

  final AppController controller;
  final PlayerItem? item;
  final double positionMs;
  final double maxMs;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            _TrackArtwork(
              coverUrl: item?.coverUrl,
              icon: Icons.graphic_eq,
              size: 42,
              borderRadius: 14,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _TrackText(
                title: item?.title ?? '未播放',
                subtitle: item?.artist ?? '青听',
              ),
            ),
            _PlaybackControls(controller: controller, compact: true),
          ],
        ),
        SizedBox(
          height: 28,
          child: Row(
            children: [
              SizedBox(
                width: 38,
                child: Text(
                  _formatDuration(controller.player.position),
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                      disabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    value: positionMs,
                    min: 0,
                    max: maxMs,
                    onChanged: item == null
                        ? null
                        : (value) => controller.seekTo(
                            Duration(milliseconds: value.round()),
                          ),
                  ),
                ),
              ),
              SizedBox(
                width: 38,
                child: Text(
                  _formatDuration(controller.player.duration),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ),
            ],
          ),
        ),
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
        _IconAction(
          tooltip: '上一首',
          icon: Icons.skip_previous,
          size: buttonSize,
          onPressed: controller.playPrevious,
        ),
        _PlayButton(controller: controller, compact: compact),
        _IconAction(
          tooltip: '下一首',
          icon: Icons.skip_next,
          size: buttonSize,
          onPressed: controller.playNext,
        ),
        _IconAction(
          tooltip: '循环',
          icon: _repeatIcon(controller.repeatMode),
          size: buttonSize,
          selected: controller.repeatMode != RepeatMode.none,
          onPressed: controller.cycleRepeatMode,
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

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.coverUrl,
  });

  final String title;
  final String subtitle;
  final List<Widget> trailing;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _tileDecoration(),
      child: Row(
        children: [
          _TrackArtwork(coverUrl: coverUrl, icon: Icons.music_note),
          const SizedBox(width: 12),
          Expanded(
            child: _TrackText(title: title, subtitle: subtitle),
          ),
          const SizedBox(width: 8),
          Wrap(spacing: 4, children: trailing),
        ],
      ),
    );
  }
}

class _TrackText extends StatelessWidget {
  const _TrackText({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

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
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: _muted, fontSize: 13),
        ),
      ],
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(color: _muted)),
            const SizedBox(height: 20),
            Expanded(child: child),
          ],
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

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({
    required this.coverUrl,
    required this.icon,
    this.size = 44,
    this.borderRadius = 14,
  });

  final String? coverUrl;
  final IconData icon;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = coverUrl?.trim();
    final fallback = _LeadingIconShell(
      size: size,
      borderRadius: borderRadius,
      child: Icon(icon, color: _accentStrong, size: size * 0.52),
    );
    if (url == null || url.isEmpty) {
      return fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image.network(
        url,
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

enum _LibraryTrackAction { openFile, revealFile, removeRecord }

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

IconData _repeatIcon(RepeatMode mode) {
  return switch (mode) {
    RepeatMode.one => Icons.repeat_one,
    RepeatMode.all => Icons.repeat,
    RepeatMode.none => Icons.repeat,
  };
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
