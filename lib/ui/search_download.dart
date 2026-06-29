part of '../main.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController textController = TextEditingController(
    text: widget.controller.searchQuery,
  );
  final FocusNode searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    searchFocusNode.addListener(_handleSearchFocusChanged);
  }

  @override
  void dispose() {
    searchFocusNode.removeListener(_handleSearchFocusChanged);
    searchFocusNode.dispose();
    textController.dispose();
    super.dispose();
  }

  void _handleSearchFocusChanged() {
    setState(() {});
  }

  void _search(String value) {
    final keyword = value.trim();
    textController.text = keyword;
    textController.selection = TextSelection.collapsed(offset: keyword.length);
    searchFocusNode.unfocus();
    unawaited(widget.controller.search(keyword));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final cooldownText = controller.sourceCooldownText;
    final searchHistory =
        controller.settings?.sourceSearchHistory ?? const <String>[];
    return _PageFrame(
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                '音乐来源',
                style: TextStyle(color: _muted, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed:
                    !controller.canSwitchSource ||
                        controller.isSearching ||
                        controller.resolvingPlayId != null ||
                        controller.preparingDownloadId != null ||
                        controller.preparingQueueNextId != null
                    ? null
                    : () => unawaited(controller.switchToNextSource()),
                icon: const Icon(Icons.swap_horiz),
                label: Text(controller.source.name),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: textController,
                  focusNode: searchFocusNode,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _search,
                  decoration: const InputDecoration(
                    hintText: '歌名、歌手或关键词',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: controller.isSearching
                      ? null
                      : () => _search(textController.text),
                  icon: controller.isSearching
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward),
                  label: const Text('搜索'),
                ),
              ),
            ],
          ),
          if (searchFocusNode.hasFocus && searchHistory.isNotEmpty) ...[
            const SizedBox(height: 10),
            _SearchHistoryDropdown(history: searchHistory, onSelected: _search),
          ],
          if (cooldownText != null) ...[
            const SizedBox(height: 10),
            _InlineNotice(icon: Icons.timer_outlined, text: cooldownText),
          ],
          const SizedBox(height: 18),
          Expanded(
            child: controller.searchResults.isEmpty
                ? _EmptyState(
                    icon: Icons.music_note,
                    text: controller.searchError ?? '输入关键词开始搜索',
                  )
                : _ResponsiveTrackList(
                    itemCount: controller.searchResults.length,
                    itemBuilder: (context, index) {
                      final result = controller.searchResults[index];
                      return TrackTile(
                        title: result.title,
                        subtitle: result.displayArtist,
                        tertiary: result.source,
                        coverUrl: result.coverUrl,
                        onTap: () => controller.playSearchResult(result),
                        trailing: [
                          _IconAction(
                            tooltip: '下一首播放',
                            icon: controller.preparingQueueNextId == result.id
                                ? Icons.more_horiz
                                : Icons.playlist_add,
                            onPressed:
                                controller.preparingQueueNextId == result.id
                                ? null
                                : () =>
                                      controller.queueSearchResultNext(result),
                            size: 30,
                          ),
                          _IconAction(
                            tooltip: '下载',
                            icon: controller.preparingDownloadId == result.id
                                ? Icons.more_horiz
                                : Icons.download,
                            onPressed:
                                controller.preparingDownloadId == result.id
                                ? null
                                : () => _startDownload(context, result),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _startDownload(
    BuildContext context,
    TrackSearchResult result,
  ) async {
    final start = await widget.controller.startDownload(result);
    if (!context.mounted) {
      return;
    }
    if (start.didStart) {
      widget.controller.showMessage('已加入下载队列');
      return;
    }
    if (start.didFail) {
      widget.controller.showMessage(start.message ?? '创建下载任务失败');
      return;
    }

    final candidate = start.candidate!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('非 MP3 格式'),
        content: Text('当前页面只找到 ${candidate.format.toUpperCase()}，是否继续下载？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final retry = await widget.controller.startDownload(
        result,
        allowNonMp3: true,
      );
      if (context.mounted) {
        widget.controller.showMessage(
          retry.didStart ? '已加入下载队列' : retry.message ?? '下载失败',
        );
      }
    }
  }
}

class _SearchHistoryDropdown extends StatelessWidget {
  const _SearchHistoryDropdown({
    required this.history,
    required this.onSelected,
  });

  final List<String> history;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const SizedBox.shrink();
    }
    return TextFieldTapRegion(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _line),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: history.length,
              separatorBuilder: (_, _) => const Divider(
                height: 1,
                indent: 44,
                endIndent: 12,
                color: _line,
              ),
              itemBuilder: (context, index) {
                final item = history[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 18, color: _muted),
                  title: Text(
                    item,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  onTap: () => onSelected(item),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.controller});

  final AppController controller;

  Future<void> _scanDownloadDirectory() async {
    final imported = await controller.scanCurrentDownloadDirectory();
    if (imported > 0) {
      controller.selectIndex(2);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.downloadProgressListenable,
      builder: (context, _, _) {
        return _PageFrame(
          child: controller.downloadTasks.isEmpty
              ? Column(
                  children: [
                    _DirectoryScanButton(
                      controller: controller,
                      onPressed: _scanDownloadDirectory,
                    ),
                    const SizedBox(height: 12),
                    const Expanded(
                      child: _EmptyState(
                        icon: Icons.downloading,
                        text: '还没有下载任务',
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    _DirectoryScanButton(
                      controller: controller,
                      onPressed: _scanDownloadDirectory,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.separated(
                        itemCount: controller.downloadTasks.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final task = controller.downloadTasks[index];
                          return _TaskTile(controller: controller, task: task);
                        },
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.controller, required this.task});

  final AppController controller;
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final showProgress =
        task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued ||
        task.status == DownloadStatus.paused;
    String? localCoverFilePath;
    if (task.status == DownloadStatus.completed) {
      for (final track in controller.downloadedTracks) {
        if (track.path == task.savePath) {
          localCoverFilePath = track.coverFilePath;
          break;
        }
      }
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _tileDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TrackArtwork(
                coverUrl: localCoverFilePath == null
                    ? task.track.coverUrl
                    : null,
                coverFilePath: localCoverFilePath,
                icon: Icons.audio_file,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TrackText(
                  title: task.track.title,
                  subtitle:
                      '${task.track.displayArtist} · ${_statusLabel(task.status)}',
                ),
              ),
              if (task.status == DownloadStatus.downloading)
                _IconAction(
                  tooltip: '暂停',
                  icon: Icons.pause,
                  onPressed: () => controller.pauseDownload(task.id),
                ),
              if (task.status == DownloadStatus.failed ||
                  task.status == DownloadStatus.paused ||
                  task.status == DownloadStatus.canceled)
                _IconAction(
                  tooltip: '重试',
                  icon: Icons.refresh,
                  onPressed: () => controller.retryDownload(task.id),
                ),
              if (task.status != DownloadStatus.completed)
                _IconAction(
                  tooltip: '取消',
                  icon: Icons.close,
                  onPressed: () => controller.cancelDownload(task.id),
                ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: task.progress <= 0
                  ? null
                  : task.progress.clamp(0, 1).toDouble(),
              minHeight: 6,
              borderRadius: BorderRadius.circular(99),
            ),
          ],
          if (task.error != null) ...[
            const SizedBox(height: 8),
            Text(task.error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 8),
          Text(
            task.totalBytes == null
                ? task.savePath
                : '${_formatBytes(task.receivedBytes)} / ${_formatBytes(task.totalBytes!)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
