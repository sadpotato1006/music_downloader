import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';

class LinuxDesktopService {
  static const _channel = MethodChannel('qingting/linux_desktop');

  static Future<String?> pickDirectory(String initialDirectory) async {
    try {
      return await _channel.invokeMethod<String>('pickDirectory', {
        'initialDirectory': initialDirectory,
      });
    } on PlatformException catch (error) {
      AppLog.instance.warning('linux', '无法打开文件夹选择器', detail: error);
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> openFile(String path) =>
      _openUri(File(path).absolute.uri);

  static Future<bool> revealFile(String path) =>
      _openUri(File(path).absolute.parent.uri);

  static Future<bool> openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return false;
    }
    return _openUri(uri);
  }

  static Future<bool> _openUri(Uri uri) async {
    try {
      return await _channel.invokeMethod<bool>('openUri', {
            'uri': uri.toString(),
          }) ??
          false;
    } on PlatformException catch (error) {
      AppLog.instance.warning('linux', '无法打开文件或链接', detail: error);
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
