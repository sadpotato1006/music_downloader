import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'coalescing_write_queue.dart';
import 'download_transfer_service.dart';
import 'models.dart';
import 'storage_service.dart';

/// Owns download state, workers, cancellation, path reservations and durable
/// snapshots. Application callbacks handle source preparation and library import.
class DownloadController extends ChangeNotifier {
  DownloadController({
    required this.storage,
    required this.transferService,
    required this.runTask,
    required this.concurrency,
    required this.canStart,
  });

  final StorageService storage;
  final DownloadTransferService transferService;
  final Future<void> Function(String id, CancelToken token) runTask;
  final int Function() concurrency;
  final bool Function() canStart;
  final _writes = CoalescingWriteQueue();
  final _workers = <String, Future<void>>{};
  final _tokens = <String, CancelToken>{};
  final _cleanups = <String, Future<void>>{};
  final _reservedPaths = <String>{};
  final _lastProgress = <String, int>{};
  final ValueNotifier<int> _progress = ValueNotifier(0);
  Future<void> _reservationQueue = Future<void>.value();
  List<DownloadTask> _tasks = const [];
  bool _disposed = false;

  List<DownloadTask> get tasks => _tasks;
  set tasks(List<DownloadTask> value) => _tasks = List.unmodifiable(value);
  ValueListenable<int> get progressListenable => _progress;
  int get activeCount => _workers.length;

  DownloadTask? taskById(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void update(String id, DownloadTask Function(DownloadTask) transform) {
    tasks = [for (final task in _tasks) task.id == id ? transform(task) : task];
  }

  static String _pathKey(String path) {
    final value = p.normalize(path.trim());
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  Set<String> get unfinishedPaths => {
    for (final task in _tasks)
      if (task.status != DownloadStatus.completed ||
          _cleanups.containsKey(task.id))
        _pathKey(task.savePath),
    for (final path in _reservedPaths) _pathKey(path),
  };

  Future<String> reservePath({
    required String directory,
    required String title,
    required String artist,
    required String format,
    required Iterable<String> Function() libraryPaths,
  }) async {
    final previous = _reservationQueue;
    final completion = Completer<void>();
    _reservationQueue = previous.then((_) => completion.future);
    await previous;
    try {
      final path = await storage.uniqueSavePath(
        downloadDirectory: directory,
        title: title,
        artist: artist,
        format: format,
        reservedPaths: [
          ..._reservedPaths,
          for (final task in tasks) task.savePath,
          ...libraryPaths(),
        ],
      );
      _reservedPaths.add(path);
      return path;
    } finally {
      completion.complete();
    }
  }

  void releasePath(String path) => _reservedPaths.remove(path);

  Future<void> save() {
    final snapshot = List<DownloadTask>.unmodifiable(
      tasks.where(
        (task) =>
            (task.status != DownloadStatus.completed || task.libraryPending) &&
            task.status != DownloadStatus.canceled,
      ),
    );
    return _writes.enqueue(() => storage.saveDownloadTasks(snapshot));
  }

  Future<void> persistBestEffort() async {
    try {
      await save();
    } catch (error, stack) {
      AppLog.instance.warning('storage', '保存下载任务失败', detail: '$error\n$stack');
    }
  }

  Future<void> restore() async {
    var changed = false;
    final restored = <DownloadTask>[];
    for (final task in tasks) {
      final file = File(task.savePath);
      final exists = await file.exists();
      final received = exists ? await file.length() : 0;
      var status = task.status;
      var error = task.error;
      if (status == DownloadStatus.downloading) status = DownloadStatus.paused;
      if (status == DownloadStatus.completed && !exists) {
        status = DownloadStatus.failed;
        error = '已下载文件不存在，请重新下载。';
      }
      final total = task.totalBytes;
      final progress = status == DownloadStatus.completed && exists
          ? 1.0
          : total != null && total > 0
          ? (received / total).clamp(0, 1).toDouble()
          : received > 0
          ? task.progress
          : 0.0;
      changed |=
          status != task.status ||
          received != task.receivedBytes ||
          progress != task.progress ||
          task.status == DownloadStatus.canceled ||
          (task.status == DownloadStatus.completed && !task.libraryPending);
      restored.add(
        task.copyWith(
          status: status,
          error: error,
          receivedBytes: received,
          progress: progress,
          libraryPending: task.libraryPending && exists,
        ),
      );
    }
    tasks = restored;
    if (changed) await save();
  }

  void pause(String id) {
    final current = taskById(id);
    if (current == null ||
        current.status == DownloadStatus.completed ||
        current.status == DownloadStatus.canceled) {
      return;
    }
    update(id, (task) => task.copyWith(status: DownloadStatus.paused));
    _tokens[id]?.cancel('paused');
    AppLog.instance.info('download', '下载已暂停', detail: current.track.title);
    unawaited(persistBestEffort());
    _notify();
  }

  void cancel(String id) {
    final current = taskById(id);
    if (current == null ||
        current.status == DownloadStatus.completed ||
        current.status == DownloadStatus.canceled) {
      return;
    }
    update(id, (task) => task.copyWith(status: DownloadStatus.canceled));
    _tokens[id]?.cancel('canceled');
    if (!_workers.containsKey(id)) unawaited(_cleanup(current));
    unawaited(persistBestEffort());
    _notify();
    schedule();
  }

  void retry(String id) {
    final current = taskById(id);
    if (_disposed ||
        current == null ||
        const {
          DownloadStatus.completed,
          DownloadStatus.queued,
          DownloadStatus.downloading,
        }.contains(current.status)) {
      return;
    }
    update(
      id,
      (task) => task.copyWith(status: DownloadStatus.queued, error: null),
    );
    unawaited(persistBestEffort());
    _notify();
    schedule();
  }

  void schedule() {
    if (_disposed || !canStart()) return;
    while (_workers.length < concurrency().clamp(1, 4)) {
      DownloadTask? next;
      for (final task in tasks) {
        if (task.status == DownloadStatus.queued &&
            !_workers.containsKey(task.id) &&
            !_cleanups.containsKey(task.id)) {
          next = task;
          break;
        }
      }
      if (next == null) return;
      final id = next.id;
      final token = CancelToken();
      _tokens[id] = token;
      update(
        id,
        (task) =>
            task.copyWith(status: DownloadStatus.downloading, error: null),
      );
      // Register the worker before any callback can synchronously reschedule.
      final done = Completer<void>();
      _workers[id] = done.future;
      unawaited(_run(id, token, done));
    }
  }

  Future<void> _run(String id, CancelToken token, Completer<void> done) async {
    try {
      await runTask(id, token);
    } catch (error, stack) {
      if (!token.isCancelled) {
        update(
          id,
          (task) =>
              task.copyWith(status: DownloadStatus.failed, error: '$error'),
        );
        AppLog.instance.error(
          'download',
          '下载任务处理失败',
          error: error,
          stackTrace: stack,
        );
        await persistBestEffort();
      }
    } finally {
      final task = taskById(id);
      if (task?.status == DownloadStatus.canceled) await _cleanup(task!);
      _tokens.remove(id);
      _lastProgress.remove(id);
      _workers.remove(id);
      done.complete();
      _notify();
      schedule();
    }
  }

  Future<void> _cleanup(DownloadTask task) {
    final active = _cleanups[task.id];
    if (active != null) return active;
    late final Future<void> operation;
    operation =
        Future<void>(() async {
          try {
            final file = File(task.savePath);
            if (await file.exists()) await file.delete();
          } catch (error, stack) {
            AppLog.instance.error(
              'download',
              '清理已取消的下载文件失败',
              error: error,
              stackTrace: stack,
            );
          }
        }).whenComplete(() {
          _cleanups.remove(task.id);
          _notify();
          schedule();
        });
    _cleanups[task.id] = operation;
    return operation;
  }

  Future<void> transfer(DownloadTask task, CancelToken token) =>
      transferService.download(
        task,
        token,
        onResponse: (received, total, validator) {
          update(
            task.id,
            (current) => current.copyWith(
              receivedBytes: received,
              totalBytes: total,
              clearTotalBytes: total == null,
              resumeValidator: validator,
              clearResumeValidator: validator == null,
            ),
          );
          unawaited(persistBestEffort());
        },
        onProgress: (received, total) {
          if (_disposed) return;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (total != received && now - (_lastProgress[task.id] ?? 0) < 100) {
            return;
          }
          _lastProgress[task.id] = now;
          update(
            task.id,
            (current) => current.copyWith(
              receivedBytes: received,
              totalBytes: total,
              progress: total != null && total > 0
                  ? (received / total).clamp(0, 1).toDouble()
                  : current.progress,
            ),
          );
          _progress.value += 1;
        },
      );

  Future<void> waitForIdle() async {
    while (_workers.isNotEmpty || _cleanups.isNotEmpty) {
      await Future.wait([..._workers.values, ..._cleanups.values]);
    }
  }

  Future<void> flush() => _writes.flush();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final token in _tokens.values) {
      token.cancel('disposed');
    }
    _progress.dispose();
    super.dispose();
  }
}
