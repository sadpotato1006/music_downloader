part of '../main.dart';

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
            child: Column(
              children: [
                _DirectoryScanButton(
                  controller: controller,
                  onPressed: () => _scanDownloadDirectory(context),
                ),
                const SizedBox(height: 10),
                _AlbumMatchButton(
                  controller: controller,
                  onPressed: _matchMissingAlbums,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _SettingPanel(
            title: '歌词设置',
            child: _LyricsSettingsButton(
              controller: controller,
              onPressed: () => _showLyricsSettings(context),
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
            title: '诊断',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.health_and_safety_outlined,
                color: _accentStrong,
              ),
              title: const Text(
                '诊断与日志',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('查看网络回退、数据恢复和未捕获异常'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DiagnosticsPage(),
                ),
              ),
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

  Future<void> _matchMissingAlbums() async {
    await controller.matchMissingDownloadedAlbums();
  }

  Future<void> _showLyricsSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) => _LyricsSettingsSheet(controller: controller),
    );
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
