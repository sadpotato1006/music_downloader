part of '../main.dart';

class _LinuxDesktopSettings extends StatefulWidget {
  const _LinuxDesktopSettings();

  @override
  State<_LinuxDesktopSettings> createState() => _LinuxDesktopSettingsState();
}

class _LinuxDesktopSettingsState extends State<_LinuxDesktopSettings> {
  bool? _closeToTray;
  bool _trayAvailable = false;
  bool _busy = false;
  String? _error;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy) unawaited(_load());
    });
  }

  Future<void> _load() async {
    try {
      final settings = await LinuxDesktopService.desktopSettings();
      if (!mounted || _busy) return;
      setState(() {
        _closeToTray = settings['closeToTray'] ?? true;
        _trayAvailable = settings['trayAvailable'] ?? false;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取桌面设置，请稍后重试。');
    }
  }

  Future<void> _setCloseToTray(bool enabled) async {
    setState(() => _busy = true);
    try {
      await LinuxDesktopService.setCloseToTray(enabled);
      if (mounted) {
        setState(() {
          _closeToTray = enabled;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '保存桌面设置失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SettingPanel(
    title: 'Linux 桌面',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('关闭窗口后继续在托盘运行'),
          subtitle: Text(
            _trayAvailable ? '托盘可打开主窗口、控制播放和退出。' : '当前桌面没有可用托盘，关闭窗口会退出青听。',
          ),
          value: _closeToTray ?? true,
          onChanged: _busy || _closeToTray == null ? null : _setCloseToTray,
        ),
        const Text('支持系统媒体控制和蓝牙断开自动暂停；窗口尺寸和最大化状态会自动保存。'),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    await LinuxDesktopService.quit();
                  } catch (_) {
                    if (mounted) setState(() => _error = '退出失败，请稍后重试。');
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          icon: const Icon(Icons.exit_to_app),
          label: const Text('退出青听'),
        ),
      ],
    ),
  );
}
