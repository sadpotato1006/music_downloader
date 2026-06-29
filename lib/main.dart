import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/cupertino.dart' hide RepeatMode;
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'album_metadata_service.dart';
import 'app_controller.dart';
import 'app_log.dart';
import 'desktop_lyrics_service.dart';
import 'gequbao_source.dart';
import 'models.dart';
import 'my_free_mp3_source.dart';

part 'ui/search_download.dart';
part 'ui/library.dart';
part 'ui/lyrics_settings.dart';
part 'ui/settings.dart';
part 'ui/playback.dart';
part 'ui/dialogs.dart';
part 'ui/diagnostics.dart';

const _accent = Color(0xFF8FD9A8);
const _appVersion = '1.3.3+19';
const _accentStrong = Color(0xFF4AA66A);
const _ink = Color(0xFF1F2A24);
const _muted = Color(0xFF6B756F);
const _surface = Color(0xFFF7FAF8);
const _line = Color(0xFFE5EFE8);
Map<String, String> _networkImageHeadersFor(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return {
    'Referer': host.contains('myfreemp3.ink')
        ? 'https://myfreemp3.ink/'
        : 'https://www.gequbao.com/',
    'User-Agent': 'QingTing/1.3.3 (+personal-use)',
  };
}

const _desktopLyricColorOptions = [
  0xFF4AA66A,
  0xFF1F2A24,
  0xFFFFFFFF,
  0xFFFFD166,
  0xFF56CCF2,
  0xFFFF6B9D,
  0xFF7C5CFF,
  0xFFFF7A45,
  0xFF00D1B2,
  0xFFB8E986,
  0xFFFFF3B0,
  0xFFB0D7FF,
];
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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    AppLog.instance.error(
      'flutter',
      'Flutter 框架异常',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    AppLog.instance.error(
      'platform',
      '未捕获的异步异常',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
  await AppLog.instance.initialize();
  AppLog.instance.info('app', '青听启动', detail: 'version=$_appVersion');
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
  late final gequbaoSource = GequbaoSource();
  late final myFreeMp3Source = MyFreeMp3Source();
  late final AppController controller = AppController(
    source: gequbaoSource,
    sources: [gequbaoSource, myFreeMp3Source],
  );

  @override
  void initState() {
    super.initState();
    unawaited(
      controller.bootstrap().catchError((Object error, StackTrace stackTrace) {
        AppLog.instance.error(
          'bootstrap',
          '应用初始化失败',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
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
            _DesktopLyricsOverlay(controller: controller),
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

class _DesktopLyricsOverlay extends StatefulWidget {
  const _DesktopLyricsOverlay({required this.controller});

  final AppController controller;

  @override
  State<_DesktopLyricsOverlay> createState() => _DesktopLyricsOverlayState();
}

class _DesktopLyricsOverlayState extends State<_DesktopLyricsOverlay>
    with WidgetsBindingObserver {
  bool _lastEnabled = false;
  String? _lastText;
  double? _lastFontSize;
  int? _lastColorValue;
  double? _lastHorizontalPosition;
  double? _lastVerticalPosition;
  double? _lastBackgroundOpacity;
  bool? _lastLocked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DesktopLyricsService.setPositionChangedHandler(
      _handleDesktopLyricsPositionChanged,
    );
    DesktopLyricsService.setLockChangedHandler(_handleDesktopLyricsLockChanged);
    widget.controller.addListener(_syncDesktopLyrics);
    widget.controller.player.positionListenable.addListener(_syncDesktopLyrics);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncDesktopLyrics(force: true);
      }
    });
  }

  @override
  void didUpdateWidget(_DesktopLyricsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_syncDesktopLyrics);
    oldWidget.controller.player.positionListenable.removeListener(
      _syncDesktopLyrics,
    );
    DesktopLyricsService.setPositionChangedHandler(
      _handleDesktopLyricsPositionChanged,
    );
    DesktopLyricsService.setLockChangedHandler(_handleDesktopLyricsLockChanged);
    widget.controller.addListener(_syncDesktopLyrics);
    widget.controller.player.positionListenable.addListener(_syncDesktopLyrics);
    _syncDesktopLyrics(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncDesktopLyrics(force: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_syncDesktopLyrics);
    widget.controller.player.positionListenable.removeListener(
      _syncDesktopLyrics,
    );
    DesktopLyricsService.setPositionChangedHandler(null);
    DesktopLyricsService.setLockChangedHandler(null);
    unawaited(DesktopLyricsService.hide());
    super.dispose();
  }

  void _handleDesktopLyricsPositionChanged(
    double horizontalPosition,
    double verticalPosition,
  ) {
    if (!mounted || !Platform.isWindows) {
      return;
    }
    final settings =
        widget.controller.settings?.desktopLyrics ??
        defaultDesktopLyricsSettings;
    widget.controller.setDesktopLyricsSettings(
      settings.copyWith(
        horizontalPosition: horizontalPosition,
        verticalPosition: verticalPosition,
      ),
    );
  }

  void _handleDesktopLyricsLockChanged(bool locked) {
    if (!mounted || !Platform.isWindows) {
      return;
    }
    final settings =
        widget.controller.settings?.desktopLyrics ??
        defaultDesktopLyricsSettings;
    if (settings.locked == locked) {
      return;
    }
    widget.controller.setDesktopLyricsSettings(
      settings.copyWith(locked: locked),
    );
    widget.controller.showGlobalMessage(
      locked ? '桌面歌词已锁定。将鼠标悬浮到歌词上可点击开锁图标，也可在设置或托盘菜单中解锁。' : '桌面歌词已解锁，可以拖动调整位置。',
    );
  }

  void _syncDesktopLyrics({bool force = false}) {
    if (!DesktopLyricsService.isSupported) {
      return;
    }

    final settings =
        widget.controller.settings?.desktopLyrics ??
        defaultDesktopLyricsSettings;
    final text = _resolveDesktopLyricText(settings)?.trim();
    final enabled = settings.enabled && text != null && text.isNotEmpty;

    if (!enabled) {
      if (_lastEnabled || _lastText != null || force) {
        _lastEnabled = false;
        _lastText = null;
        unawaited(DesktopLyricsService.hide());
      }
      return;
    }

    final unchanged =
        !force &&
        _lastEnabled &&
        _lastText == text &&
        _lastFontSize == settings.fontSize &&
        _lastColorValue == settings.colorValue &&
        _lastHorizontalPosition == settings.horizontalPosition &&
        _lastVerticalPosition == settings.verticalPosition &&
        _lastBackgroundOpacity == settings.backgroundOpacity &&
        _lastLocked == settings.locked;
    if (unchanged) {
      return;
    }

    _lastEnabled = true;
    _lastText = text;
    _lastFontSize = settings.fontSize;
    _lastColorValue = settings.colorValue;
    _lastHorizontalPosition = settings.horizontalPosition;
    _lastVerticalPosition = settings.verticalPosition;
    _lastBackgroundOpacity = settings.backgroundOpacity;
    _lastLocked = settings.locked;
    unawaited(
      DesktopLyricsService.update(
        enabled: true,
        text: text,
        settings: settings,
      ),
    );
  }

  String? _resolveDesktopLyricText(DesktopLyricsSettings settings) {
    final item = widget.controller.currentItem;
    if (item == null) {
      return null;
    }
    final lines = _parseLyricLines(item.lyrics);
    if (lines.isEmpty) {
      return null;
    }
    final effectivePosition =
        widget.controller.player.position -
        Duration(milliseconds: settings.delayMilliseconds);
    return _currentLyricText(
      lines,
      _currentLyricIndex(lines, effectivePosition),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
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
