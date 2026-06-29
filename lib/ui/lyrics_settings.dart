part of '../main.dart';

class _LyricsSettingsButton extends StatelessWidget {
  const _LyricsSettingsButton({
    required this.controller,
    required this.onPressed,
  });

  final AppController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = controller.settings?.desktopLyrics.enabled ?? false;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(enabled ? Icons.subtitles : Icons.subtitles_outlined),
        label: Text(enabled ? '桌面歌词已开启' : '桌面歌词已关闭'),
      ),
    );
  }
}

class _LyricsSettingsSheet extends StatelessWidget {
  const _LyricsSettingsSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final settings =
            controller.settings?.desktopLyrics ?? defaultDesktopLyricsSettings;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.paddingOf(context).bottom + 18,
          ),
          child: SingleChildScrollView(
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
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '歌词设置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: settings.enabled,
                  onChanged: (enabled) =>
                      _update(settings.copyWith(enabled: enabled)),
                  title: const Text(
                    '桌面歌词',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (Platform.isAndroid && settings.enabled) ...[
                  const SizedBox(height: 8),
                  const _AndroidDesktopLyricsPermissionButton(),
                ],
                if (Platform.isWindows && settings.enabled) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: settings.locked,
                    onChanged: (locked) =>
                        _update(settings.copyWith(locked: locked)),
                    title: const Text(
                      '锁定桌面歌词',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text('锁定后歌词保持鼠标穿透；悬浮到歌词上会显示开锁图标。'),
                  ),
                ],
                const SizedBox(height: 10),
                _LyricsSettingsPreview(settings: settings),
                const SizedBox(height: 16),
                _LyricsSettingSlider(
                  label: '字体大小',
                  valueLabel: '${settings.fontSize.round()}',
                  min: 14,
                  max: 42,
                  divisions: 28,
                  value: settings.fontSize,
                  onChanged: (value) =>
                      _update(settings.copyWith(fontSize: value)),
                ),
                const SizedBox(height: 14),
                const Text(
                  '歌词颜色',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final colorValue in _desktopLyricColorOptions)
                      _LyricsColorChoice(
                        colorValue: colorValue,
                        selected: colorValue == settings.colorValue,
                        onTap: () =>
                            _update(settings.copyWith(colorValue: colorValue)),
                      ),
                    _LyricsCustomColorChoice(
                      colorValue: settings.colorValue,
                      selected: !_desktopLyricColorOptions.contains(
                        settings.colorValue,
                      ),
                      onTap: () => _pickCustomColor(context, settings),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (Platform.isWindows) ...[
                  _LyricsSettingSlider(
                    label: '水平位置',
                    valueLabel: _desktopLyricHorizontalPositionLabel(
                      settings.horizontalPosition,
                    ),
                    min: 0,
                    max: 1,
                    divisions: 100,
                    value: settings.horizontalPosition,
                    onChanged: (value) =>
                        _update(settings.copyWith(horizontalPosition: value)),
                  ),
                  const SizedBox(height: 14),
                ],
                _LyricsSettingSlider(
                  label: '显示位置',
                  valueLabel: _desktopLyricPositionLabel(
                    settings.verticalPosition,
                  ),
                  min: 0,
                  max: 1,
                  divisions: 100,
                  value: settings.verticalPosition,
                  onChanged: (value) =>
                      _update(settings.copyWith(verticalPosition: value)),
                ),
                const SizedBox(height: 14),
                _LyricsSettingSlider(
                  label: '显示延迟',
                  valueLabel: _formatLyricDelay(settings.delayMilliseconds),
                  min: -3000,
                  max: 3000,
                  divisions: 24,
                  value: settings.delayMilliseconds.toDouble(),
                  onChanged: (value) => _update(
                    settings.copyWith(delayMilliseconds: value.round()),
                  ),
                ),
                const SizedBox(height: 14),
                _LyricsSettingSlider(
                  label: '背景透明度',
                  valueLabel: '${(settings.backgroundOpacity * 100).round()}%',
                  min: 0,
                  max: 0.45,
                  divisions: 45,
                  value: settings.backgroundOpacity,
                  onChanged: (value) =>
                      _update(settings.copyWith(backgroundOpacity: value)),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _update(
                      defaultDesktopLyricsSettings.copyWith(
                        enabled: settings.enabled,
                      ),
                    ),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('恢复默认'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _update(DesktopLyricsSettings settings) {
    controller.setDesktopLyricsSettings(settings);
  }

  Future<void> _pickCustomColor(
    BuildContext context,
    DesktopLyricsSettings settings,
  ) async {
    final colorValue = await showDialog<int>(
      context: context,
      builder: (context) =>
          _LyricsColorPickerDialog(initialColorValue: settings.colorValue),
    );
    if (colorValue == null) {
      return;
    }
    _update(settings.copyWith(colorValue: colorValue));
  }
}

class _AndroidDesktopLyricsPermissionButton extends StatefulWidget {
  const _AndroidDesktopLyricsPermissionButton();

  @override
  State<_AndroidDesktopLyricsPermissionButton> createState() =>
      _AndroidDesktopLyricsPermissionButtonState();
}

class _AndroidDesktopLyricsPermissionButtonState
    extends State<_AndroidDesktopLyricsPermissionButton>
    with WidgetsBindingObserver {
  late Future<bool> _permissionFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _permissionFuture = DesktopLyricsService.isOverlayPermissionGranted();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _permissionFuture = DesktopLyricsService.isOverlayPermissionGranted();
    });
  }

  Future<void> _openSettings() async {
    await DesktopLyricsService.openOverlayPermissionSettings();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _permissionFuture,
      builder: (context, snapshot) {
        final granted = snapshot.data ?? false;
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: granted ? _refresh : _openSettings,
            icon: Icon(
              granted ? Icons.check_circle_outline : Icons.open_in_new,
            ),
            label: Text(granted ? '悬浮窗权限已开启' : '打开悬浮窗权限'),
          ),
        );
      },
    );
  }
}

class _LyricsSettingsPreview extends StatelessWidget {
  const _LyricsSettingsPreview({required this.settings});

  final DesktopLyricsSettings settings;

  @override
  Widget build(BuildContext context) {
    final color = Color(settings.colorValue);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: settings.backgroundOpacity),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              '青听桌面歌词预览',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: settings.fontSize,
                fontWeight: FontWeight.w800,
                height: 1.28,
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.38),
                    blurRadius: 7,
                    offset: const Offset(0, 1.5),
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

class _LyricsSettingSlider extends StatelessWidget {
  const _LyricsSettingSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              valueLabel,
              style: const TextStyle(
                color: _muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          min: min,
          max: max,
          divisions: divisions,
          value: value.clamp(min, max).toDouble(),
          label: valueLabel,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _LyricsColorChoice extends StatelessWidget {
  const _LyricsColorChoice({
    required this.colorValue,
    required this.selected,
    required this.onTap,
  });

  final int colorValue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(colorValue);
    return Tooltip(
      message: '#${colorValue.toRadixString(16).padLeft(8, '0').toUpperCase()}',
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? _accentStrong : _line,
              width: selected ? 3 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 18,
                  color: color.computeLuminance() > 0.62 ? _ink : Colors.white,
                )
              : null,
        ),
      ),
    );
  }
}

class _LyricsCustomColorChoice extends StatelessWidget {
  const _LyricsCustomColorChoice({
    required this.colorValue,
    required this.selected,
    required this.onTap,
  });

  final int colorValue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(colorValue);
    return Tooltip(
      message: '自定义颜色',
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: selected ? color : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? _accentStrong : _line,
              width: selected ? 3 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            Icons.palette_outlined,
            size: 18,
            color: selected && color.computeLuminance() < 0.55
                ? Colors.white
                : _ink,
          ),
        ),
      ),
    );
  }
}

class _LyricsColorPickerDialog extends StatefulWidget {
  const _LyricsColorPickerDialog({required this.initialColorValue});

  final int initialColorValue;

  @override
  State<_LyricsColorPickerDialog> createState() =>
      _LyricsColorPickerDialogState();
}

class _LyricsColorPickerDialogState extends State<_LyricsColorPickerDialog> {
  late int _red;
  late int _green;
  late int _blue;
  late final TextEditingController _hexController;

  int get _colorValue => 0xFF000000 | (_red << 16) | (_green << 8) | _blue;

  String get _hexText =>
      '#${(_colorValue & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  @override
  void initState() {
    super.initState();
    _red = (widget.initialColorValue >> 16) & 0xFF;
    _green = (widget.initialColorValue >> 8) & 0xFF;
    _blue = widget.initialColorValue & 0xFF;
    _hexController = TextEditingController(text: _hexText);
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _setComponent(String channel, double value) {
    setState(() {
      final normalized = value.round().clamp(0, 255);
      switch (channel) {
        case 'r':
          _red = normalized;
          break;
        case 'g':
          _green = normalized;
          break;
        case 'b':
          _blue = normalized;
          break;
      }
      _hexController.value = TextEditingValue(
        text: _hexText,
        selection: TextSelection.collapsed(offset: _hexText.length),
      );
    });
  }

  void _applyHex(String value) {
    final cleaned = value.trim().replaceFirst('#', '');
    if (cleaned.length != 6) {
      return;
    }
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) {
      return;
    }
    setState(() {
      _red = (parsed >> 16) & 0xFF;
      _green = (parsed >> 8) & 0xFF;
      _blue = parsed & 0xFF;
      _hexController.value = TextEditingValue(
        text: _hexText,
        selection: TextSelection.collapsed(offset: _hexText.length),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = Color(_colorValue);
    return AlertDialog(
      title: const Text('自定义歌词颜色'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 54,
              width: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _line),
              ),
              child: Text(
                '青听桌面歌词预览',
                style: TextStyle(
                  color: color.computeLuminance() > 0.62 ? _ink : Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _hexController,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Hex',
                prefixIcon: Icon(Icons.tag),
              ),
              onSubmitted: _applyHex,
              onEditingComplete: () => _applyHex(_hexController.text),
            ),
            const SizedBox(height: 12),
            _ColorComponentSlider(
              label: 'R',
              value: _red,
              activeColor: Colors.red,
              onChanged: (value) => _setComponent('r', value),
            ),
            _ColorComponentSlider(
              label: 'G',
              value: _green,
              activeColor: Colors.green,
              onChanged: (value) => _setComponent('g', value),
            ),
            _ColorComponentSlider(
              label: 'B',
              value: _blue,
              activeColor: Colors.blue,
              onChanged: (value) => _setComponent('b', value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _colorValue),
          child: const Text('使用'),
        ),
      ],
    );
  }
}

class _ColorComponentSlider extends StatelessWidget {
  const _ColorComponentSlider({
    required this.label,
    required this.value,
    required this.activeColor,
    required this.onChanged,
  });

  final String label;
  final int value;
  final Color activeColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 22,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: Slider(
            min: 0,
            max: 255,
            divisions: 255,
            activeColor: activeColor,
            value: value.toDouble(),
            label: '$value',
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            '$value',
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
