import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'app_update_service.dart';
import 'windows_update_bridge.dart';

class AndroidUpdateInstaller implements UpdateInstaller {
  static const _channel = MethodChannel('qingting/app_update');

  @override
  Future<UpdateInstallSession> prepare(
    File installer,
    AppUpdateRelease release,
  ) async {
    if (release.requiresManualInstall ||
        !installer.path.endsWith('.apk') ||
        await installer.length() != release.size ||
        (await sha256.bind(installer.openRead()).first).toString() !=
            release.sha256Hex) {
      throw const FormatException('更新包已变化，请重新下载');
    }
    final arguments = <String, Object>{
      'path': installer.path,
      'versionName': release.version.release,
      'versionCode': release.version.build,
    };
    await _invoke('prepareInstall', arguments);
    return _AndroidInstallSession(arguments);
  }

  static Future<void> _invoke(
    String method,
    Map<String, Object> arguments,
  ) async {
    try {
      final accepted = await _channel.invokeMethod<bool>(method, arguments);
      if (accepted != true) throw const FormatException('无法打开系统安装器，请重试');
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? '无法打开系统安装器，请重试');
    }
  }
}

class _AndroidInstallSession implements UpdateInstallSession {
  _AndroidInstallSession(this.arguments);
  final Map<String, Object> arguments;

  @override
  Future<void> commitAndExit() =>
      AndroidUpdateInstaller._invoke('installApk', arguments);

  @override
  Future<void> abort() async {}
}
