part of '../main.dart';

class _SoftwareUpdatePanel extends StatelessWidget {
  const _SoftwareUpdatePanel({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final updates = controller.updates!;
    return AnimatedBuilder(
      animation: Listenable.merge([updates, controller]),
      builder: (context, _) {
        final release = updates.release;
        final status = updates.status;
        return _SettingPanel(
          title: '软件更新',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('当前版本：$appVersion'),
                  if (updates.error != null)
                    Text(
                      updates.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: updates.busy || status == AppUpdateStatus.ready
                        ? null
                        : () => updates.check(),
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      status == AppUpdateStatus.checking ? '正在检查…' : '检查更新',
                    ),
                  ),
                ],
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('启动时检查更新'),
                subtitle: const Text('发现新版时提示'),
                value: controller.settings!.checkUpdatesOnStartup,
                onChanged: (value) async {
                  try {
                    await controller.setCheckUpdatesOnStartup(value);
                  } catch (_) {
                    controller.showMessage('更新设置保存失败，请重试');
                  }
                },
              ),
              if (release != null) ...[
                Text(
                  '新版 ${release.version} · ${(release.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (release.notes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: SingleChildScrollView(
                        child: SelectableText(release.notes),
                      ),
                    ),
                  ),
              ],
              if (status == AppUpdateStatus.current)
                const Text('已是最新正式版', style: TextStyle(color: _accentStrong)),
              if (status == AppUpdateStatus.checking)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                ),
              if (status == AppUpdateStatus.downloading) ...[
                LinearProgressIndicator(value: updates.progress),
                const SizedBox(height: 6),
                Text('正在下载 ${(updates.progress * 100).toStringAsFixed(0)}%'),
              ],
              if (status == AppUpdateStatus.ready) const Text('下载完成，重启后生效'),
              if (release != null ||
                  status == AppUpdateStatus.downloading ||
                  status == AppUpdateStatus.ready) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (status == AppUpdateStatus.downloading)
                      OutlinedButton(
                        onPressed: updates.cancelDownload,
                        child: const Text('取消下载'),
                      )
                    else if (status == AppUpdateStatus.ready)
                      FilledButton.icon(
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('重启并更新'),
                        onPressed: () => _install(context, updates),
                      )
                    else if (release != null)
                      FilledButton.icon(
                        onPressed: updates.busy ? null : updates.download,
                        icon: const Icon(Icons.download),
                        label: Text(updates.error == null ? '下载更新' : '重新下载'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _install(
    BuildContext context,
    WindowsUpdateController updates,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重启并更新青听？'),
        content: const Text('将暂停播放和下载任务，保存歌单、设置与播放队列，然后完成升级并重新打开青听。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重启并更新'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await updates.install(
      prepareToExit: () => controller.prepareForExit(strict: true),
      restoreAfterFailure: controller.cancelUpdateExit,
    );
  }
}

class _UpdateOverlay extends StatelessWidget {
  const _UpdateOverlay({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final updates = controller.updates!;
    return AnimatedBuilder(
      animation: Listenable.merge([updates, controller]),
      builder: (context, _) {
        if (updates.status == AppUpdateStatus.installing) {
          return Positioned.fill(
            child: Stack(
              children: [
                const ModalBarrier(dismissible: false, color: Colors.black45),
                Center(
                  child: Material(
                    borderRadius: BorderRadius.circular(18),
                    child: const Padding(
                      padding: EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 18),
                          Text('正在准备升级并保存数据…'),
                          SizedBox(height: 8),
                          Text('完成后青听会重新打开'),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        if (!updates.noticeVisible ||
            updates.release == null ||
            controller.selectedIndex == 3) {
          return const SizedBox.shrink();
        }
        return Positioned(
          top: 74,
          right: 18,
          left: 18,
          child: Align(
            alignment: Alignment.topRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(12),
                color: _surface,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '发现青听新版 ${updates.release!.version.release}',
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          controller.selectIndex(3);
                          updates.dismissNotice();
                        },
                        child: const Text('查看'),
                      ),
                      IconButton(
                        tooltip: '稍后再说',
                        onPressed: updates.dismissNotice,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
