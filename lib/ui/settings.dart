import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../app_update_service.dart' show appReleasePage;
import '../models.dart';
import '../settings_controller.dart';
import 'components.dart';
import 'theme.dart';
import 'settings_save_notice.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.controller,
    required this.libraryTools,
    required this.lyricsButton,
    required this.syncEntry,
    required this.showMessage,
    required this.openDiagnostics,
    this.platformSettings,
    this.updatePanel,
  });

  final Widget libraryTools;
  final Widget lyricsButton;
  final Widget syncEntry;
  final Widget? platformSettings;
  final Widget? updatePanel;
  final ValueChanged<String> showMessage;
  final void Function(BuildContext) openDiagnostics;

  final SettingsController controller;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late final TextEditingController pathController;
  late final FocusNode pathFocusNode;
  late String _lastDownloadDirectory;
  bool _concurrentWarningOpen = false;

  SettingsController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_handleSettingsChanged);
    pathController = TextEditingController(
      text: controller.value!.downloadDirectory,
    );
    pathFocusNode = FocusNode();
    _lastDownloadDirectory = controller.value!.downloadDirectory;
  }

  @override
  void didUpdateWidget(covariant SettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(_handleSettingsChanged);
      controller.addListener(_handleSettingsChanged);
    }
    _syncDownloadPath();
  }

  void _handleSettingsChanged() {
    _syncDownloadPath();
    if (mounted) setState(() {});
  }

  void _syncDownloadPath() {
    final currentPath = controller.value!.downloadDirectory;
    if (_lastDownloadDirectory != currentPath) {
      _lastDownloadDirectory = currentPath;
      if (!pathFocusNode.hasFocus && pathController.text != currentPath) {
        pathController.text = currentPath;
      }
    }
  }

  @override
  void dispose() {
    controller.removeListener(_handleSettingsChanged);
    pathController.dispose();
    pathFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = controller.value!;
    return PageFrame(
      child: Column(
        children: [
          SettingsSaveNotice(controller: controller),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 960,
                child: ListView(
                  children: [
                    _playbackSettings(settings),
                    const SizedBox(height: 16),
                    _downloadSettings(context, settings),
                    const SizedBox(height: 16),
                    SettingPanel(
                      title: '外观与歌词',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ThemePicker(
                            selected: settings.theme,
                            onChanged: controller.setTheme,
                          ),
                          const SizedBox(height: 16),
                          widget.lyricsButton,
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SettingPanel(
                      title: '同步',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '北科云盘 · 仅限 USTBer',
                            style: TextStyle(color: appMuted, fontSize: 12),
                          ),
                          widget.syncEntry,
                        ],
                      ),
                    ),
                    if (widget.platformSettings != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        decoration: tileDecoration(context),
                        child: Material(
                          type: MaterialType.transparency,
                          child: widget.platformSettings!,
                        ),
                      ),
                    ],
                    if (widget.updatePanel != null) ...[
                      const SizedBox(height: 16),
                      SettingPanel(title: '软件更新', child: widget.updatePanel!),
                    ],
                    const SizedBox(height: 16),
                    Container(
                      decoration: tileDecoration(context),
                      child: Material(
                        type: MaterialType.transparency,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          leading: Icon(
                            Icons.health_and_safety_outlined,
                            color: themeAccent(context),
                          ),
                          title: const Text(
                            '诊断与日志',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => widget.openDiagnostics(context),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SettingPanel(
                      title: '源代码',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _openProjectRepository(context),
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  FaIcon(
                                    FontAwesomeIcons.github,
                                    size: 22,
                                    color: appInk,
                                  ),
                                  SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'https://github.com/sadpotato1006/music_downloader',
                                      maxLines: 2,
                                      softWrap: true,
                                      overflow: TextOverflow.clip,
                                      style: TextStyle(
                                        color: themeAccent(context),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        decoration: TextDecoration.underline,
                                        decorationColor: themeAccent(context),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () async {
                              if (!await controller.openExternalUrl(
                                appReleasePage,
                              )) {
                                widget.showMessage('无法打开发布页');
                              }
                            },
                            icon: const Icon(Icons.open_in_new, size: 18),
                            label: const Text('打开发布页'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const SettingPanel(
                      title: '联系作者',
                      child: Row(
                        children: [
                          Icon(Icons.mail_outline, color: appMuted),
                          SizedBox(width: 12),
                          Expanded(
                            child: SelectableText(
                              'zhangzzx06@gmail.com',
                              style: TextStyle(
                                color: appInk,
                                fontWeight: FontWeight.w600,
                              ),
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
                        style: TextStyle(fontSize: 12, color: appMuted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _playbackSettings(AppSettings settings) => SettingPanel(
    title: '播放',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('启动时自动播放音乐'),
          value: settings.autoPlayOnStartup,
          onChanged: (value) =>
              runSettingsAction(() => controller.setAutoPlayOnStartup(value)),
        ),
        const SizedBox(height: 8),
        _SettingsOptionRow(
          label: '启动页面',
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
            onSelectionChanged: (selection) => runSettingsAction(
              () => controller.setDefaultStartupPageIndex(selection.first),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _downloadSettings(BuildContext context, AppSettings settings) =>
      SettingPanel(
        title: '下载与本地',
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
                prefixIcon: Icon(Icons.folder_outlined),
                labelText: '下载目录',
                hintText: '输入下载保存路径',
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [
                  if (Platform.isWindows || Platform.isLinux)
                    OutlinedButton.icon(
                      onPressed: () => _pickDownloadDirectory(context),
                      icon: const Icon(Icons.folder_open),
                      label: const Text('选择文件夹'),
                    ),
                  FilledButton.icon(
                    onPressed: () => _saveDownloadDirectory(context),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存路径'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SettingsOptionRow(
              label: '同时下载',
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
                    width: 32,
                    child: Text(
                      '${settings.concurrentDownloads}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 28),
            const Text('曲库管理', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            widget.libraryTools,
          ],
        ),
      );

  Future<void> _saveDownloadDirectory(BuildContext context) async {
    pathFocusNode.unfocus();
    bool success;
    try {
      success = await controller.setDownloadDirectory(pathController.text);
    } catch (_) {
      // Keep the typed path and expose the retryable persistence failure.
      return;
    }
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
    widget.showMessage(success ? '下载目录已保存' : '下载目录不可用');
    if (success) pathController.text = controller.value!.downloadDirectory;
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

  Future<void> _setConcurrentDownloads(BuildContext context, int value) async {
    final normalized = value.clamp(1, 4).toInt();
    final current = controller.value?.concurrentDownloads ?? 1;
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
    await runSettingsAction(
      () => controller.setConcurrentDownloads(normalized),
    );
  }

  Future<void> _openProjectRepository(BuildContext context) async {
    final opened = await controller.openProjectRepository();
    if (!context.mounted || opened) {
      return;
    }
    widget.showMessage('无法打开 GitHub 链接');
  }
}

class _SettingsOptionRow extends StatelessWidget {
  const _SettingsOptionRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final title = Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w600),
      );
      if (constraints.maxWidth >= 540) {
        return Row(
          children: [
            Expanded(child: title),
            SizedBox(width: 280, child: child),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: child),
        ],
      );
    },
  );
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.selected, required this.onChanged});

  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 650
          ? 6
          : constraints.maxWidth >= 280
          ? 3
          : 2;
      final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
      final selectedId = normalizeAppTheme(selected);
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final palette in themePalettes)
            SizedBox(
              width: width,
              child: Semantics(
                button: true,
                selected: selectedId == palette.id,
                label: '${palette.name}主题',
                excludeSemantics: true,
                child: Material(
                  color: palette.background,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: selectedId == palette.id
                          ? palette.primary
                          : themeLine(context),
                      width: selectedId == palette.id ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('theme-${palette.id}'),
                    onTap: () => onChanged(palette.id),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 24,
                            child: Row(
                              children: [
                                Expanded(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Container(
                                          width: 18,
                                          height: 4,
                                          color: palette.tint,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  width: 22,
                                  height: 22,
                                  decoration: BoxDecoration(
                                    color: palette.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                palette.name,
                                style: TextStyle(
                                  color: palette.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (selectedId == palette.id) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.check_circle,
                                  size: 15,
                                  color: palette.primary,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
