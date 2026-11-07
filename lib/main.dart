import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/cupertino.dart' hide RepeatMode;
import 'package:flutter/foundation.dart' show listEquals, compute;
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'album_metadata_service.dart';
import 'anyshare_auth.dart';
import 'anyshare_client.dart';
import 'app_info.dart';
import 'app_controller.dart';
import 'ui/lyrics_settings.dart';
import 'ui/linux_desktop_settings.dart';
import 'ui/settings.dart';
import 'ui/settings_save_notice.dart';
import 'ui/selected_builder.dart';
import 'ui/theme.dart';
import 'ui/components.dart';

export 'ui/theme.dart' show qingTingTheme;
import 'app_log.dart';
import 'cloud_sync_service.dart' show CloudSyncProgress;
import 'desktop_lyrics_service.dart';
import 'gequbao_source.dart';
import 'lyric_parser.dart';
import 'linux_desktop_service.dart';
import 'models.dart';
import 'my_free_mp3_source.dart';
import 'xiagebao_source.dart';
import 'pending_album_match.dart';
import 'playlist_file_service.dart';
import 'playlist_transfer_service.dart';
import 'storage_json_codec.dart';
import 'app_update_controller.dart';
import 'app_update_service.dart';
import 'windows_update_bridge.dart';

part 'ui/search_download.dart';
part 'ui/library.dart';
part 'ui/library_batch.dart';
part 'ui/playlist_transfer.dart';

part 'ui/settings_integration.dart';

part 'ui/cloud_sync.dart';
part 'ui/playback.dart';
part 'ui/dialogs.dart';
part 'ui/diagnostics.dart';
part 'ui/software_update.dart';

const _appLifecycleChannel = MethodChannel('qingting/app_lifecycle');
Map<String, String> _networkImageHeadersFor(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  return {
    'Referer': host == 'xiagebao.com' || host.endsWith('.xiagebao.com')
        ? 'https://www.xiagebao.com/'
        : host == 'myfreemp3.ink' || host.endsWith('.myfreemp3.ink')
        ? 'https://myfreemp3.ink/'
        : 'https://www.gequbao.com/',
    'User-Agent': appUserAgent,
  };
}

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
  AppLog.instance.info('app', '青听启动', detail: 'version=$appVersion');
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  MediaKit.ensureInitialized();
  runApp(const QingTingApp());
}

class QingTingApp extends StatefulWidget {
  const QingTingApp({super.key});

  @override
  State<QingTingApp> createState() => _QingTingAppState();
}

class _QingTingAppState extends State<QingTingApp> with WidgetsBindingObserver {
  late final gequbaoSource = GequbaoSource();
  late final myFreeMp3Source = MyFreeMp3Source();
  late final xiagebaoSource = XiagebaoSource();
  late final AppController controller = AppController(
    source: gequbaoSource,
    waitForStartupFrame: () => WidgetsBinding.instance.endOfFrame,
    sources: [gequbaoSource, myFreeMp3Source, xiagebaoSource],
    updates: Platform.isWindows || Platform.isAndroid || Platform.isLinux
        ? AppUpdateController()
        : null,
  );
  Timer? _updateCheckTimer;
  Future<void> _bootstrap() async {
    await controller.bootstrap();
    if (!mounted || !controller.isReady) return;
    await WidgetsBinding.instance.endOfFrame;
    try {
      await WindowsUpdateInstaller.acknowledgeStartup();
    } catch (error, stack) {
      AppLog.instance.error(
        'update',
        '确认新版启动失败',
        error: error,
        stackTrace: stack,
      );
    }
    if (!mounted || controller.updates == null) return;
    controller.updates!.automaticCheckEnabled =
        controller.settings!.checkUpdatesOnStartup;
    _updateCheckTimer?.cancel();
    _updateCheckTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) unawaited(controller.updates!.check(automatic: true));
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows || Platform.isLinux) {
      _appLifecycleChannel.setMethodCallHandler(_handleLifecycleMethod);
    }
    unawaited(_bootstrap());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(controller.flushPendingWrites());
        break;
    }
  }

  Future<Object?> _handleLifecycleMethod(MethodCall call) async {
    if (call.method != 'prepareToExit') {
      throw MissingPluginException('Unknown lifecycle method: ${call.method}');
    }
    await controller.prepareForExit();
    return true;
  }

  @override
  void dispose() {
    _updateCheckTimer?.cancel();
    xiagebaoSource.close();
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows || Platform.isLinux) {
      _appLifecycleChannel.setMethodCallHandler(null);
    }
    unawaited(controller.flushPendingWrites());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiOverlayStyle,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '青听',
        builder: (context, child) =>
            AppThemeScope(theme: controller.preferences.theme, child: child!),
        theme: qingTingTheme(),
        home: SelectedBuilder(
          listenable: controller,
          select: () => (controller.bootstrapStatus, controller.bootstrapError),
          child: HomeShell(controller: controller),
          builder: (context, child) {
            return switch (controller.bootstrapStatus) {
              AppBootstrapStatus.loading => const _StartupStatusPage(),
              AppBootstrapStatus.error => _StartupStatusPage(
                error: controller.bootstrapError,
                onRetry: () => unawaited(_bootstrap()),
              ),
              AppBootstrapStatus.ready => child!,
            };
          },
        ),
      ),
    );
  }
}

class _StartupStatusPage extends StatelessWidget {
  const _StartupStatusPage({this.error, this.onRetry});

  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failed)
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.redAccent,
                    )
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    failed ? '青听启动失败' : '正在加载音乐数据',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    error ?? '正在恢复设置、曲库、播放队列和下载任务…',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: appMuted),
                  ),
                  if (failed) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ],
              ),
            ),
          ),
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
  late int _selectedPageTarget;
  int? _programmaticPageTarget;
  int _navigationRevision = 0;
  Timer? _toastTimer;
  final _toastMessage = ValueNotifier<String?>(null);
  String? _scheduledToastMessage;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: controller.selectedIndex);
    _selectedPageTarget = controller.selectedIndex;
    controller.addListener(_handleControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scheduleGlobalMessage();
      }
    });
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_handleControllerChanged);
    controller.addListener(_handleControllerChanged);
    _selectedPageTarget = -1;
    _handleControllerChanged();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _toastMessage.dispose();
    controller.removeListener(_handleControllerChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    _syncPageWithSelectedIndex();
    _scheduleGlobalMessage();
  }

  void _syncPageWithSelectedIndex() {
    final target = controller.selectedIndex;
    // Progress, playback and settings notifications must not restart a swipe.
    if (!_pageController.hasClients || _selectedPageTarget == target) return;
    _selectedPageTarget = target;
    _programmaticPageTarget = target;
    final revision = ++_navigationRevision;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(target);
      _programmaticPageTarget = null;
      return;
    }
    unawaited(
      _pageController
          .animateToPage(
            target,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            if (mounted && revision == _navigationRevision) {
              _programmaticPageTarget = null;
            }
          }),
    );
  }

  void _onPageChanged(int index) {
    // Intermediate pages crossed by a tab animation are not new destinations.
    if (_programmaticPageTarget != null) return;
    _selectedPageTarget = index;
    controller.selectIndex(index);
  }

  bool _onPageScrollStart(ScrollStartNotification notification) {
    if (notification.depth == 0 && notification.dragDetails != null) {
      _navigationRevision++;
      _programmaticPageTarget = null;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AppThemeScope(
      theme: controller.preferences.theme,
      child: _buildShell(context),
    );
  }

  Widget _buildShell(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 820;
        return Stack(
          children: [
            Scaffold(
              body: Column(
                children: [
                  SelectedBuilder(
                    key: const ValueKey('navigation-updates'),
                    listenable: controller,
                    select: () => controller.selectedIndex,
                    builder: (context, _) => _TopNavigation(
                      controller: controller,
                      isDesktop: isDesktop,
                      pageController: _pageController,
                    ),
                  ),
                  Expanded(
                    child: NotificationListener<ScrollStartNotification>(
                      onNotification: _onPageScrollStart,
                      child: PageView(
                        controller: _pageController,
                        onPageChanged: _onPageChanged,
                        children: [
                          _ActiveControllerPage(
                            controller: controller,
                            index: 0,
                            select: () => controller.searchViewState,
                            builder: (_) => SearchPage(controller: controller),
                          ),
                          _ActiveControllerPage(
                            controller: controller,
                            index: 1,
                            select: () => controller.downloadsViewState,
                            additionalListenables: [
                              controller.downloadProgressListenable,
                            ],
                            builder: (_) =>
                                DownloadsPage(controller: controller),
                          ),
                          _ActiveControllerPage(
                            controller: controller,
                            index: 2,
                            select: () => controller.libraryViewState,
                            builder: (_) => LibraryPage(controller: controller),
                          ),
                          SettingsPage(controller: controller),
                        ],
                      ),
                    ),
                  ),
                  SelectedBuilder(
                    key: const ValueKey('mini-player-updates'),
                    listenable: controller,
                    select: () => controller.miniPlayerViewState,
                    builder: (context, _) => MiniPlayer(
                      controller: controller,
                      isDesktop: isDesktop,
                    ),
                  ),
                ],
              ),
            ),
            _DesktopLyricsOverlay(controller: controller),
            if (controller.updates != null)
              _UpdateOverlay(controller: controller),
            Positioned(
              bottom:
                  MediaQuery.paddingOf(context).bottom + (isDesktop ? 98 : 112),
              left: 18,
              right: 18,
              child: ValueListenableBuilder<String?>(
                valueListenable: _toastMessage,
                builder: (_, message, _) => message == null
                    ? const SizedBox.shrink()
                    : IgnorePointer(child: _QingTingToast(message: message)),
              ),
            ),
          ],
        );
      },
    );
  }

  void _scheduleGlobalMessage() {
    final message = controller.globalMessage;
    if (message == null || message == _scheduledToastMessage) {
      return;
    }
    _scheduledToastMessage = message;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _scheduledToastMessage = null;
      _toastMessage.value = message;
      _toastTimer?.cancel();
      _toastTimer = Timer(const Duration(milliseconds: 2200), () {
        if (mounted) {
          _toastMessage.value = null;
        }
      });
      if (controller.globalMessage == message) {
        controller.clearGlobalMessage();
      }
    });
    // Selected widgets may all ignore this notification, so request the frame
    // needed to deliver the toast's post-frame callback explicitly.
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}

class _ActiveControllerPage extends StatefulWidget {
  const _ActiveControllerPage({
    required this.controller,
    required this.index,
    required this.select,
    required this.builder,
    this.additionalListenables = const [],
  });

  final AppController controller;
  final int index;
  final Object Function() select;
  final WidgetBuilder builder;
  final List<Listenable> additionalListenables;

  @override
  State<_ActiveControllerPage> createState() => _ActiveControllerPageState();
}

class _ActiveControllerPageState extends State<_ActiveControllerPage>
    with AutomaticKeepAliveClientMixin {
  Object? _lastView;
  bool _wasActive = false;
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    _addListeners(widget);
  }

  @override
  void didUpdateWidget(covariant _ActiveControllerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        !listEquals(
          oldWidget.additionalListenables,
          widget.additionalListenables,
        )) {
      _removeListeners(oldWidget);
      _addListeners(widget);
    }
  }

  @override
  void dispose() {
    _removeListeners(widget);
    super.dispose();
  }

  void _addListeners(_ActiveControllerPage value) {
    value.controller.addListener(_handleChanged);
    for (final listenable in value.additionalListenables) {
      listenable.addListener(_handleChanged);
    }
  }

  void _removeListeners(_ActiveControllerPage value) {
    value.controller.removeListener(_handleChanged);
    for (final listenable in value.additionalListenables) {
      listenable.removeListener(_handleChanged);
    }
  }

  void _handleChanged() {
    final active = widget.controller.selectedIndex == widget.index;
    if (!active) {
      _wasActive = false;
      return;
    }
    final view = widget.select();
    if (!_wasActive || view != _lastView) {
      _lastView = view;
      if (mounted) setState(() {});
    }
    _wasActive = true;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    _lastView = widget.select();
    _wasActive = widget.controller.selectedIndex == widget.index;
    return RepaintBoundary(child: widget.builder(context));
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
              border: Border.all(color: themeLine(context)),
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
                      color: themeAccent(context).withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.music_note,
                      color: themeAccent(context),
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
                        color: appInk,
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
  String? _lyricSource;
  List<LyricLine> _lyricLines = const [];
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
    final text = settings.enabled ? _resolveDesktopLyricText(settings) : null;
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
    final source = widget.controller.currentItem?.lyrics;
    if (source != _lyricSource) {
      // Keep the current lines locally: position ticks should not trim/hash
      // the LRC or touch the shared parser cache. Null also clears old lyrics.
      _lyricLines = parseLyricLines(source);
      _lyricSource = source;
    }
    if (_lyricLines.isEmpty) {
      return null;
    }
    final effectivePosition =
        widget.controller.player.position -
        Duration(milliseconds: settings.delayMilliseconds);
    return _currentLyricText(
      _lyricLines,
      _currentLyricIndex(_lyricLines, effectivePosition),
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
  const _TopNavigation({
    required this.controller,
    required this.isDesktop,
    required this.pageController,
  });

  final AppController controller;
  final bool isDesktop;
  final PageController pageController;

  @override
  Widget build(BuildContext context) {
    // Tight height also keeps LayoutBuilder's animation rebuilds from
    // invalidating the surrounding capsule's layout and cached paint.
    final tabs = SizedBox(
      height: 48,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / _topNavDestinations.length;
          return Stack(
            children: [
              // Moving Positioned.left would relayout the navigation on every
              // tick. Keep its layout fixed and translate the cached lens only.
              Positioned(
                top: 2,
                bottom: 2,
                left: 2,
                width: tabWidth - 4,
                child: AnimatedBuilder(
                  animation: pageController,
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: DecoratedBox(
                        key: const ValueKey('navigation-indicator'),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: themeTint(context),
                        ),
                      ),
                    ),
                  ),
                  builder: (context, child) {
                    final page =
                        pageController.hasClients &&
                            pageController.position.hasContentDimensions
                        ? pageController.page ??
                              pageController.initialPage.toDouble()
                        : pageController.initialPage.toDouble();
                    return Transform.translate(
                      offset: Offset(page.clamp(0, 3) * tabWidth, 0),
                      child: child,
                    );
                  },
                ),
              ),
              Row(
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
            ],
          );
        },
      ),
    );
    final content = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 20 : 4,
        vertical: 4,
      ),
      child: Row(
        children: [
          if (isDesktop) ...[const _AppMark(), const SizedBox(width: 22)],
          Expanded(child: tabs),
        ],
      ),
    );
    // The inset belongs outside the surface, so the status bar never becomes
    // part of the capsule on Android's edge-to-edge windows.
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? 24 : 16,
          12,
          isDesktop ? 24 : 16,
          0,
        ),
        child: ThemeSurface(
          key: const ValueKey('navigation-capsule'),
          radius: 999,
          isolateContent: true,
          child: content,
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
            color: themeTint(context),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(Icons.music_note, color: themeAccent(context)),
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
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: NavigationButton(
          selected: selected,
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  destination.icon,
                  size: 19,
                  color: selected ? themeAccent(context) : appMuted,
                ),
                SizedBox(width: compact ? 4 : 8),
                Flexible(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12.5 : 13,
                      color: selected ? appInk : appMuted,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
