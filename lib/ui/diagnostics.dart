part of '../main.dart';

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final log = AppLog.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断与日志'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '复制诊断信息',
            onPressed: () => _copyDiagnostics(context),
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '清空日志',
            onPressed: () => _clearDiagnostics(context),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: log.revision,
        builder: (context, _, _) {
          final entries = log.entries.reversed.toList(growable: false);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _DiagnosticSummary(log: log),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '最近日志',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '${entries.length} 条',
                    style: const TextStyle(color: _muted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (entries.isEmpty)
                const _EmptyState(
                  icon: Icons.receipt_long_outlined,
                  text: '暂无日志\n应用运行、网络回退和数据恢复信息会显示在这里。',
                )
              else
                ...entries.map(_DiagnosticLogTile.new),
            ],
          );
        },
      ),
    );
  }

  Future<void> _copyDiagnostics(BuildContext context) async {
    await Clipboard.setData(
      ClipboardData(
        text: AppLog.instance.diagnosticsText(appVersion: _appVersion),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('诊断信息已复制，发送反馈前可先检查内容。')));
    }
  }

  Future<void> _clearDiagnostics(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空诊断日志？'),
        content: const Text('这不会删除歌曲、设置或下载任务。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AppLog.instance.clear();
    }
  }
}

class _DiagnosticSummary extends StatelessWidget {
  const _DiagnosticSummary({required this.log});

  final AppLog log;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.health_and_safety_outlined, color: _accentStrong),
                SizedBox(width: 10),
                Text(
                  '运行信息',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('版本：$_appVersion'),
            const SizedBox(height: 5),
            Text('平台：${Platform.operatingSystem}'),
            const SizedBox(height: 5),
            SelectableText(
              '日志文件：${log.filePath ?? '不可用，仅保留内存日志'}',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            const Text(
              '复制内容会自动去除日志中 URL 的查询参数，避免携带临时签名。',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticLogTile extends StatelessWidget {
  const _DiagnosticLogTile(this.entry);

  final AppLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      AppLogLevel.info => _accentStrong,
      AppLogLevel.warning => Colors.orange.shade700,
      AppLogLevel.error => Colors.red.shade700,
    };
    final icon = switch (entry.level) {
      AppLogLevel.info => Icons.info_outline,
      AppLogLevel.warning => Icons.warning_amber_outlined,
      AppLogLevel.error => Icons.error_outline,
    };
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: _line),
      ),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text(
          entry.message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${entry.timestamp.toLocal().toString().split('.').first} · ${entry.category}',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            entry.detail == null || entry.detail!.isEmpty
                ? entry.message
                : entry.detail!,
            style: const TextStyle(fontSize: 12, color: _ink),
          ),
        ],
      ),
    );
  }
}
