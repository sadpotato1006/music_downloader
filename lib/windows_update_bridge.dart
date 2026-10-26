import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app_info.dart';
import 'app_update_service.dart';

abstract class UpdateInstallSession {
  Future<void> commitAndExit();
  Future<void> abort();
}

abstract class UpdateInstaller {
  Future<UpdateInstallSession> prepare(
    File installer,
    AppUpdateRelease release,
  );
}

class WindowsUpdateInstaller implements UpdateInstaller {
  static const _channel = MethodChannel('qingting/app_lifecycle');

  @override
  Future<UpdateInstallSession> prepare(
    File installer,
    AppUpdateRelease release,
  ) async {
    if (!Platform.isWindows ||
        p.basename(Platform.resolvedExecutable).toLowerCase() !=
            'qingting.exe') {
      throw const FormatException('请在安装后的 Windows 青听中执行升级');
    }
    if (await installer.length() != release.size ||
        (await sha256.bind(installer.openRead()).first).toString() !=
            release.sha256Hex) {
      throw const FormatException('更新包已变化，请重新下载');
    }
    final root = await GitHubUpdateSource.defaultUpdateDirectory();
    await root.create(recursive: true);
    final directory = await root.createTemp('session-');
    final token = List.generate(
      32,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final request = File(p.join(directory.path, 'request.json'));
    await request.writeAsString(
      jsonEncode({
        'protocol': 1,
        'token': token,
        'version': release.version.toString(),
        'installDir': p.dirname(Platform.resolvedExecutable),
        'parentPid': pid,
      }),
      flush: true,
    );
    final session = _WindowsInstallSession(directory, token);
    try {
      await Process.start(installer.path, [
        '--update',
        request.path,
      ], mode: ProcessStartMode.detached);
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (DateTime.now().isBefore(deadline)) {
        final error = File(p.join(directory.path, 'error.txt'));
        if (await error.exists()) {
          throw FormatException(await error.readAsString());
        }
        final ready = File(p.join(directory.path, 'ready'));
        if (await ready.exists() && (await ready.readAsString()) == token) {
          return session;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw const FormatException('升级程序未能就绪，当前版本未被替换，请重试');
    } catch (_) {
      await session.abort();
      rethrow;
    }
  }

  /// Acknowledge only after library bootstrap and the first usable UI frame.
  /// Session paths supplied by the helper must remain under our update cache.
  static Future<void> acknowledgeStartup() async {
    if (!Platform.isWindows) return;
    final sessionPath = Platform.environment['QINGTING_UPDATE_SESSION'];
    final token = Platform.environment['QINGTING_UPDATE_TOKEN'];
    if (sessionPath == null ||
        token == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      return;
    }
    final root = await GitHubUpdateSource.defaultUpdateDirectory();
    final directory = Directory(sessionPath);
    if (!await root.exists() || !await directory.exists()) return;
    if (!p.isWithin(
      await root.resolveSymbolicLinks(),
      await directory.resolveSymbolicLinks(),
    )) {
      return;
    }
    final request = jsonDecode(
      await File(p.join(sessionPath, 'request.json')).readAsString(),
    );
    if (request is! Map ||
        request['token'] != token ||
        request['version'] != appVersion ||
        request['installDir'] is! String ||
        !p.equals(
          p.normalize(request['installDir'] as String),
          p.dirname(Platform.resolvedExecutable),
        )) {
      return;
    }
    final temporary = File(p.join(sessionPath, 'started.tmp'));
    await temporary.writeAsString(token, flush: true);
    await temporary.rename(p.join(sessionPath, 'started'));
  }
}

class _WindowsInstallSession implements UpdateInstallSession {
  _WindowsInstallSession(this.directory, this.token);
  final Directory directory;
  final String token;

  @override
  Future<void> commitAndExit() async {
    await File(
      p.join(directory.path, 'commit'),
    ).writeAsString(token, flush: true);
    final accepted = await WindowsUpdateInstaller._channel.invokeMethod<bool>(
      'exitForUpdate',
    );
    if (accepted != true) throw const FormatException('无法退出青听，升级已取消');
  }

  @override
  Future<void> abort() async {
    await File(
      p.join(directory.path, 'abort'),
    ).writeAsString(token, flush: true);
  }
}
