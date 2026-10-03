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

  static Future<bool> revealFile(String path) async {
    try {
      return await _channel.invokeMethod<bool>('revealFile', {
            'uri': File(path).absolute.uri.toString(),
          }) ??
          false;
    } on PlatformException {
      return _openUri(File(path).absolute.parent.uri);
    } on MissingPluginException {
      return _openUri(File(path).absolute.parent.uri);
    }
  }

  static Future<Uri?> login(Uri url, Uri callback) async {
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        callback.scheme != 'https' ||
        callback.host != '127.0.0.1' ||
        callback.path != '/callback' ||
        callback.hasQuery ||
        callback.hasFragment) {
      throw ArgumentError('无效的云盘登录地址');
    }
    final result = await _channel.invokeMethod<String>('login', {
      'url': url.toString(),
      'callbackUrl': callback.toString(),
    });
    if (result == null) return null;
    final uri = Uri.parse(result);
    if (uri.scheme != callback.scheme ||
        uri.host != callback.host ||
        uri.port != callback.port ||
        uri.path != callback.path ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('云盘登录返回了无效的回调地址');
    }
    return uri;
  }

  static Future<void> cancelLogin() async {
    try {
      await _channel.invokeMethod<void>('cancelLogin');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<Map<String, bool>> desktopSettings() async {
    final result = await _channel.invokeMapMethod<String, bool>('getSettings');
    return result ?? const {};
  }

  static Future<void> setCloseToTray(bool enabled) =>
      _channel.invokeMethod<void>('setCloseToTray', {'enabled': enabled});

  static Future<void> quit() => _channel.invokeMethod<void>('quit');

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
