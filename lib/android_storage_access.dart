import 'dart:io';

import 'package:flutter/services.dart';

class AndroidStorageAccess {
  static const MethodChannel _channel = MethodChannel('qingting/storage');

  static bool get isAndroid => Platform.isAndroid;

  static bool isPublicExternalPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized == '/storage/emulated/0' ||
        normalized.startsWith('/storage/emulated/0/');
  }

  static Future<bool> hasAllFilesAccess() async {
    if (!isAndroid) {
      return true;
    }
    return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  }

  static Future<void> openAllFilesAccessSettings() async {
    if (!isAndroid) {
      return;
    }
    await _channel.invokeMethod<void>('openAllFilesAccessSettings');
  }

  static Future<bool> openUrl(String url) async {
    if (!isAndroid) {
      return false;
    }
    return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  }
}
