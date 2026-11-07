part of '../main.dart';

/// Composition boundary: SettingsView only receives preferences and widgets.
/// Cross-feature actions are assembled here instead of inside the settings UI.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => SettingsView(
    controller: controller.preferences,
    showMessage: controller.showMessage,
    openDiagnostics: (context) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage())),
    libraryTools: SelectedBuilder(
      listenable: controller,
      select: () => controller.libraryToolsViewState,
      builder: (context, _) => _SettingsLibraryTools(controller: controller),
    ),
    platformSettings: Platform.isLinux
        ? SelectedBuilder(
            listenable: controller,
            select: () => controller.selectedIndex == 3,
            builder: (_, _) =>
                LinuxDesktopSettings(active: controller.selectedIndex == 3),
          )
        : null,
    updatePanel: controller.updates == null
        ? null
        : _SoftwareUpdatePanel(controller: controller),
    lyricsButton: AnimatedBuilder(
      animation: controller.preferences,
      builder: (context, _) => LyricsSettingsButton(
        controller: controller.preferences,
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          builder: (_) =>
              LyricsSettingsSheet(controller: controller.preferences),
        ),
      ),
    ),
    syncEntry: SelectedBuilder(
      listenable: controller,
      select: () =>
          (controller.settings?.cloudFolderName, controller.isCloudSyncing),
      builder: (context, _) {
        final folder = controller.settings?.cloudFolderName ?? '';
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.cloud_sync_outlined, color: themeAccent(context)),
          title: Text(folder.isEmpty ? '连接北科云盘' : '同步文件夹：$folder'),
          subtitle: Text(
            controller.isCloudSyncing ? '正在同步歌曲…' : '启动时自动同步，也可手动同步',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CloudSyncPage(controller: controller),
            ),
          ),
        );
      },
    ),
  );
}

class _SettingsLibraryTools extends StatelessWidget {
  const _SettingsLibraryTools({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _DirectoryScanButton(
        controller: controller,
        onPressed: controller.scanCurrentDownloadDirectory,
      ),
      const SizedBox(height: 10),
      _AlbumMatchButton(
        controller: controller,
        onPressed: () => _matchMissingAlbums(context),
        onReview: () => _showPendingAlbumMatchesSheet(context, controller),
      ),
    ],
  );

  Future<void> _matchMissingAlbums(BuildContext context) async {
    final count = controller.eligibleAlbumMatchCount;
    if (count >= 20) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('开始批量匹配专辑？'),
          content: Text(
            '将处理 $count 首歌曲。元数据服务需要限速访问，可能持续数分钟；'
            '每首歌曲默认选择得分最高的专辑并写入，过程中可以停止。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('开始匹配'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    await controller.matchMissingDownloadedAlbums();
  }
}
