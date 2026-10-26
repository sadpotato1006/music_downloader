import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'app_info.dart';
import 'app_log.dart';
import 'app_update_service.dart';
import 'windows_update_bridge.dart';

enum AppUpdateStatus {
  idle,
  checking,
  current,
  available,
  downloading,
  ready,
  installing,
}

class WindowsUpdateController extends ChangeNotifier {
  WindowsUpdateController({
    AppUpdateSource? source,
    UpdateInstaller? installer,
    String currentVersion = appVersion,
  }) : _source = source ?? GitHubUpdateSource(),
       _installer = installer ?? WindowsUpdateInstaller(),
       currentVersion = UpdateVersion.parse(currentVersion);

  final AppUpdateSource _source;
  final UpdateInstaller _installer;
  final UpdateVersion currentVersion;
  AppUpdateStatus status = AppUpdateStatus.idle;
  AppUpdateRelease? release;
  String? error;
  double progress = 0;
  bool automaticCheckEnabled = true;
  bool noticeVisible = false;
  File? _download;
  CancelToken? _cancel;
  bool _disposed = false;
  bool get busy => const {
    AppUpdateStatus.checking,
    AppUpdateStatus.downloading,
    AppUpdateStatus.installing,
  }.contains(status);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void dismissNotice() {
    noticeVisible = false;
    _notify();
  }

  Future<void> check({bool automatic = false}) async {
    if (_disposed ||
        busy ||
        status == AppUpdateStatus.ready ||
        (automatic && !automaticCheckEnabled)) {
      return;
    }
    final cancel = _cancel = CancelToken();
    status = AppUpdateStatus.checking;
    error = null;
    _notify();
    try {
      final found = await _source.check(currentVersion, cancel);
      if (_disposed || cancel.isCancelled) return;
      release = found;
      status = found == null
          ? AppUpdateStatus.current
          : AppUpdateStatus.available;
      noticeVisible = found != null && (!automatic || automaticCheckEnabled);
    } catch (exception, stack) {
      if (!_disposed && !cancel.isCancelled) {
        status = release == null
            ? AppUpdateStatus.idle
            : AppUpdateStatus.available;
        error = _message(exception, '检查更新失败，请稍后重试或打开发布页');
        AppLog.instance.error(
          'update',
          '检查更新失败',
          error: exception,
          stackTrace: stack,
        );
      }
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
      _notify();
    }
  }

  Future<void> download() async {
    final selected = release;
    if (_disposed ||
        selected == null ||
        busy ||
        status == AppUpdateStatus.ready) {
      return;
    }
    final cancel = _cancel = CancelToken();
    status = AppUpdateStatus.downloading;
    progress = 0;
    error = null;
    _notify();
    final watch = Stopwatch()..start();
    try {
      _download = await _source.download(selected, cancel, (received, total) {
        progress = received / total;
        if (watch.elapsedMilliseconds >= 100 || received == total) {
          watch.reset();
          _notify();
        }
      });
      if (!_disposed) {
        status = cancel.isCancelled
            ? AppUpdateStatus.available
            : AppUpdateStatus.ready;
      }
    } catch (exception, stack) {
      if (!_disposed) {
        status = AppUpdateStatus.available;
        if (!cancel.isCancelled) {
          error = _message(exception, '更新下载失败，请重试');
          AppLog.instance.error(
            'update',
            '下载更新失败',
            error: exception,
            stackTrace: stack,
          );
        }
      }
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
      _notify();
    }
  }

  void cancelDownload() {
    if (status == AppUpdateStatus.downloading) _cancel?.cancel('用户取消更新下载');
  }

  Future<void> install({
    required Future<void> Function() prepareToExit,
    required void Function() restoreAfterFailure,
  }) async {
    if (_disposed ||
        status != AppUpdateStatus.ready ||
        _download == null ||
        release == null) {
      return;
    }
    status = AppUpdateStatus.installing;
    error = null;
    _notify();
    UpdateInstallSession? session;
    try {
      session = await _installer.prepare(_download!, release!);
      await prepareToExit();
      await session.commitAndExit();
    } catch (exception, stack) {
      try {
        await session?.abort();
      } catch (_) {
        /* Preserve the original error. */
      }
      restoreAfterFailure();
      status = AppUpdateStatus.ready;
      error = _message(exception, '升级未能开始，当前版本仍可继续使用');
      AppLog.instance.error(
        'update',
        '启动升级失败',
        error: exception,
        stackTrace: stack,
      );
      _notify();
    }
  }

  String _message(Object error, String fallback) =>
      error is FormatException ? error.message : fallback;

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    _source.close();
    super.dispose();
  }
}
