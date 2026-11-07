import 'dart:async';

import 'package:flutter/material.dart';

import '../linux_desktop_service.dart';
import 'components.dart';

class LinuxDesktopSettings extends StatefulWidget {
  const LinuxDesktopSettings({super.key, this.active = true});

  final bool active;

  @override
  State<LinuxDesktopSettings> createState() => _LinuxDesktopSettingsState();
}

class _LinuxDesktopSettingsState extends State<LinuxDesktopSettings>
    with WidgetsBindingObserver {
  bool? _closeToTray;
  bool _trayAvailable = false;
  bool _busy = false;
  String? _error;
  bool _loading = false;
  bool _reloadRequested = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) unawaited(_load());
  }

  @override
  void didUpdateWidget(LinuxDesktopSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _revision++;
      if (widget.active) unawaited(_load());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.active) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!mounted || !widget.active) return;
    if (_busy || _loading) {
      _reloadRequested = true;
      return;
    }
    _reloadRequested = false;
    _loading = true;
    final revision = _revision;
    try {
      final settings = await LinuxDesktopService.desktopSettings();
      if (!mounted || !widget.active || revision != _revision) return;
      final closeToTray = settings['closeToTray'] ?? true;
      final trayAvailable = settings['trayAvailable'] ?? false;
      if (_closeToTray == closeToTray &&
          _trayAvailable == trayAvailable &&
          _error == null) {
        return;
      }
      setState(() {
        _closeToTray = closeToTray;
        _trayAvailable = trayAvailable;
        _error = null;
      });
    } catch (_) {
      if (mounted && widget.active && revision == _revision) {
        setState(() => _error = '无法读取桌面设置，请稍后重试。');
      }
    } finally {
      _loading = false;
      if (_reloadRequested && mounted && widget.active) unawaited(_load());
    }
  }

  Future<void> _setCloseToTray(bool enabled) async {
    _revision++;
    var saved = false;
    setState(() => _busy = true);
    try {
      await LinuxDesktopService.setCloseToTray(enabled);
      saved = true;
      if (mounted) {
        setState(() {
          _closeToTray = enabled;
          _error = null;
        });
      }
    } catch (_) {
      _reloadRequested = false;
      if (mounted) setState(() => _error = '保存桌面设置失败，请重试。');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (saved) unawaited(_load());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _revision++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SettingsLabel('Linux 桌面'),
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
        TextButton(onPressed: _busy ? null : _load, child: const Text('重试读取')),
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
  );
}
