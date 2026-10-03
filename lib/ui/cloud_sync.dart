part of '../main.dart';

class CloudSyncPage extends StatefulWidget {
  const CloudSyncPage({super.key, required this.controller});
  final AppController controller;

  @override
  State<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends State<CloudSyncPage> {
  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(controller.refreshCloudDeletionPolicy());
  }

  Future<void> _login() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _CloudLoginPage(controller: controller),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _chooseFolder() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _CloudFolderPicker(controller: controller),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final settings = controller.settings!;
      final progress = controller.cloudSyncProgress;
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            '北科云盘歌曲同步(仅限USTBer)',
            style: TextStyle(fontSize: 16),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '将本地下载目录与所选云盘文件夹内的“青听歌曲”同步。歌曲保存在“青听歌曲”，歌曲信息、封面、索引和删除记录保存在“青听数据”；这些文件夹会自动创建。',
            ),
            const SizedBox(height: 8),
            const Text('在青听中修改歌曲信息后，其他设备下次同步也会更新，原下载顺序保持不变。'),
            const SizedBox(height: 20),
            if (!controller.cloudConnected)
              FilledButton.icon(
                onPressed: _login,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('扫码登录北科云盘'),
              )
            else ...[
              ListTile(
                leading: const Icon(Icons.check_circle, color: _accentStrong),
                title: const Text('已连接北科云盘'),
                trailing: TextButton(
                  onPressed:
                      controller.isCloudSyncing ||
                          controller.isCloudPolicyLoading
                      ? null
                      : controller.disconnectCloud,
                  child: const Text('退出登录'),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed:
                    controller.isCloudSyncing || controller.isCloudPolicyLoading
                    ? null
                    : _chooseFolder,
                icon: const Icon(Icons.folder_open),
                label: Text(
                  settings.cloudFolderId.isEmpty
                      ? '选择云盘文件夹'
                      : '当前文件夹：${settings.cloudFolderName}',
                ),
              ),
              TextButton(
                onPressed:
                    controller.isCloudSyncing || controller.isCloudPolicyLoading
                    ? null
                    : _login,
                child: const Text('重新扫码登录'),
              ),
              if (settings.cloudFolderId.isNotEmpty) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('打开青听时自动同步'),
                  value: settings.cloudSyncEnabled,
                  onChanged: controller.isCloudPolicyLoading
                      ? null
                      : controller.setCloudSyncEnabled,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('此云盘文件夹的同步删除'),
                  subtitle: Text(
                    controller.cloudDeletionPolicyEnabled == null
                        ? '正在读取云盘设置；读取失败时暂停同步以保护歌曲。'
                        : '所有已更新设备下次同步生效。关闭后仍会执行已确认的删除记录；只删除内容未变化的歌曲。',
                  ),
                  value: controller.cloudDeletionPolicyEnabled ?? false,
                  onChanged:
                      controller.isCloudSyncing ||
                          controller.isCloudPolicyLoading ||
                          controller.cloudDeletionPolicyEnabled == null
                      ? null
                      : controller.setCloudSyncDeletionsEnabled,
                ),
                FilledButton.icon(
                  onPressed:
                      controller.isCloudSyncing ||
                          controller.isCloudPolicyLoading
                      ? null
                      : () => controller.syncCloud(),
                  icon: const Icon(Icons.sync),
                  label: Text(controller.isCloudSyncing ? '同步中…' : '立即同步'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed:
                      controller.isCloudSyncing ||
                          controller.isCloudPolicyLoading
                      ? null
                      : () => controller.syncCloud(preferLocalOrder: true),
                  icon: const Icon(Icons.sort),
                  label: const Text('以本机下载顺序为准'),
                ),
                const Text('将本机曲库的下载时间写入云盘；其他设备下次同步后按这个顺序显示。'),
              ],
            ],
            if (controller.isCloudSyncing) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: progress == null || progress.total <= 0
                    ? null
                    : (progress.completed / progress.total).clamp(0.0, 1.0),
              ),
              if (progress != null) ...[
                const SizedBox(height: 8),
                Text(
                  progress.stage.label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '已处理 ${progress.completed}/${progress.total} · '
                  '上传 ${progress.uploaded} · 下载 ${progress.downloaded} · 失败 ${progress.failed}',
                ),
                if (progress.transfers.isEmpty && progress.current.isNotEmpty)
                  Text(
                    progress.current,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                for (final transfer in progress.transfers) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${transfer.stage.label}：${transfer.path}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: transfer.fraction),
                  const SizedBox(height: 4),
                  Text(
                    '${transfer.fraction == null ? '准备传输' : '${(transfer.fraction! * 100).round()}%'} · '
                    '${_cloudBytes(transfer.bytes)} / ${transfer.totalBytes <= 0 ? '未知' : _cloudBytes(transfer.totalBytes)} · '
                    '${_cloudBytes(transfer.bytesPerSecond)}/s',
                  ),
                ],
              ],
            ],
            if (controller.cloudSyncFailures.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '失败歌曲：${controller.cloudSyncFailures.length} 首',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed:
                    controller.isCloudSyncing || controller.isCloudPolicyLoading
                    ? null
                    : controller.retryFailedCloudSongs,
                icon: const Icon(Icons.refresh),
                label: const Text('一键重试失败歌曲'),
              ),
              for (final failure in controller.cloudSyncFailures)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    failure.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${failure.stage.label}：${failure.message}'),
                ),
            ],
            if (controller.cloudSyncError != null) ...[
              const SizedBox(height: 16),
              Text(
                controller.cloudSyncError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (controller.cloudSyncNotice != null) ...[
              const SizedBox(height: 16),
              Text(controller.cloudSyncNotice!),
            ],
            if (controller.lastCloudSyncAt != null) ...[
              const SizedBox(height: 16),
              Text('上次同步：${controller.lastCloudSyncAt!.toLocal()}'),
            ],
          ],
        ),
      );
    },
  );
}

String _cloudBytes(num bytes) {
  if (bytes < 1024) return '${bytes.round()} B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _CloudLoginPage extends StatefulWidget {
  const _CloudLoginPage({required this.controller});
  final AppController controller;

  @override
  State<_CloudLoginPage> createState() => _CloudLoginPageState();
}

class _CloudLoginPageState extends State<_CloudLoginPage> {
  late Future<Uri> _url;
  bool _finishing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startLogin();
  }

  void _retry() {
    setState(_startLogin);
  }

  void _startLogin() {
    _error = null;
    _finishing = false;
    _url = widget.controller.beginCloudLogin();
    if (Platform.isLinux) unawaited(_loginOnLinux(_url));
  }

  Future<void> _loginOnLinux(Future<Uri> request) async {
    try {
      final url = await request;
      if (!mounted || !identical(request, _url)) return;
      final callback = await LinuxDesktopService.login(
        url,
        Uri.parse(AnyShareAuth.callbackUrl),
      );
      if (!mounted || !identical(request, _url)) return;
      if (callback == null) {
        setState(() => _error = '扫码登录已取消，可点击重试重新打开。');
      } else {
        await _finish(callback);
      }
    } catch (error) {
      if (mounted && identical(request, _url)) {
        setState(() => _error = '无法完成扫码登录：$error');
      }
    }
  }

  @override
  void dispose() {
    if (Platform.isLinux) unawaited(LinuxDesktopService.cancelLogin());
    super.dispose();
  }

  Future<void> _finish(Uri uri) async {
    if (_finishing) return;
    _finishing = true;
    try {
      await widget.controller.finishCloudLogin(uri);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
      _finishing = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫码登录')),
    body: FutureBuilder<Uri>(
      future: _url,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('无法打开云盘登录页：${snapshot.error}'),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _retry, child: const Text('重试')),
                ],
              ),
            ),
          );
        }
        final url = snapshot.data;
        if (url == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (Platform.isLinux) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.qr_code_2, size: 64),
                  const SizedBox(height: 16),
                  Text(
                    _finishing ? '正在保存云盘授权…' : '请在青听的扫码登录窗口中点击“个人用户登录”，再用微信扫码。',
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _retry, child: const Text('重试')),
                  ] else ...[
                    const SizedBox(height: 16),
                    const CircularProgressIndicator(),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('点击“个人用户登录”，再用微信扫描二维码完成北科云盘授权。'),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(url.toString())),
                initialSettings: InAppWebViewSettings(
                  useShouldOverrideUrlLoading: true,
                ),
                shouldOverrideUrlLoading: (webController, action) async {
                  final next = action.request.url;
                  if (next != null &&
                      next.toString().startsWith(AnyShareAuth.callbackUrl)) {
                    unawaited(_finish(Uri.parse(next.toString())));
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
                onLoadStart: (webController, next) {
                  if (next != null &&
                      next.toString().startsWith(AnyShareAuth.callbackUrl)) {
                    unawaited(_finish(Uri.parse(next.toString())));
                  }
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _CloudFolderPicker extends StatefulWidget {
  const _CloudFolderPicker({required this.controller});
  final AppController controller;

  @override
  State<_CloudFolderPicker> createState() => _CloudFolderPickerState();
}

class _CloudFolderPickerState extends State<_CloudFolderPicker> {
  final List<AnyShareFolder> _path = [];
  List<AnyShareFolder> _folders = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = _path.isEmpty
          ? await widget.controller.cloudRootFolders()
          : (await widget.controller.cloudFolderChildren(
              _path.last.id,
            )).folders;
      if (mounted) setState(() => _folders = items);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select() async {
    if (_path.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.selectCloudFolder(_path.last);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_path.isEmpty ? '选择云盘文件夹' : _path.last.name),
      actions: [
        if (_path.isNotEmpty)
          TextButton(
            onPressed: _saving ? null : _select,
            child: const Text('选定此文件夹'),
          ),
      ],
    ),
    body: Column(
      children: [
        if (_path.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('返回上一级'),
            onTap: () {
              _path.removeLast();
              unawaited(_load());
            },
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            itemCount: _folders.length,
            itemBuilder: (context, index) {
              final folder = _folders[index];
              return ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  _path.add(folder);
                  unawaited(_load());
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}
