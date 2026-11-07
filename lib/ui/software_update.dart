part of '../main.dart';

class _SoftwareUpdatePanel extends StatelessWidget {
  const _SoftwareUpdatePanel({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final updates = controller.updates!;
    return AnimatedBuilder(
      animation: Listenable.merge([updates, controller.preferences]),
      builder: (context, _) {
        final release = updates.release;
        final status = updates.status;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('当前版本：$appReleaseVersion'),
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
                if (status == AppUpdateStatus.current)
                  Text(
                    '已是最新正式版',
                    style: TextStyle(color: themeAccent(context)),
                  ),
              ],
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启动时检查更新'),
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
                '新版 ${release.version.release}'
                '${release.size > 0 ? ' · ${(release.size / (1024 * 1024)).toStringAsFixed(1)} MB' : ''}',
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
            if (release?.requiresManualInstall == true)
              Text(
                updates.platform == AppUpdatePlatform.android
                    ? '此版本未提供应用内更新包，请前往发布页下载 APK。'
                    : '请选择 DEB、Arch 安装包或便携包，按原安装方式更新。',
              ),
            if (status == AppUpdateStatus.ready)
              Text(updates.restartsApp ? '下载完成，重启后生效' : '下载完成，点击安装更新'),
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
                      label: Text(updates.restartsApp ? '重启并更新' : '安装更新'),
                      onPressed: () => _install(context, updates),
                    )
                  else if (release?.requiresManualInstall == true)
                    FilledButton.icon(
                      onPressed: updates.busy
                          ? null
                          : () => updates.openDownloadPage(
                              controller.preferences.openExternalUrl,
                            ),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('前往下载'),
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
        );
      },
    );
  }

  Future<void> _install(
    BuildContext context,
    AppUpdateController updates,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(updates.restartsApp ? '重启并更新青听？' : '安装新版青听？'),
        content: Text(
          updates.restartsApp
              ? '将暂停播放和下载任务，保存歌单、设置与播放队列，然后完成升级并重新打开青听。'
              : '将暂停播放和下载任务，保存数据并打开系统安装器。首次安装可能需要允许青听安装应用，授权后返回再次点击“安装更新”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(updates.restartsApp ? '重启并更新' : '安装更新'),
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
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 18),
                          const Text('正在准备升级并保存数据…'),
                          const SizedBox(height: 8),
                          Text(
                            updates.restartsApp ? '完成后青听会重新打开' : '请在系统安装器中确认安装',
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
                color: Theme.of(context).scaffoldBackgroundColor,
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
