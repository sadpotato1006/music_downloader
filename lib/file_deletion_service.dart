import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class FileDeletionService {
  bool get movesFilesToRecycleBin;

  Future<bool> deleteFile(String path);
}

class PlatformFileDeletionService implements FileDeletionService {
  static const MethodChannel _channel = MethodChannel(
    'qingting/file_operations',
  );

  @override
  bool get movesFilesToRecycleBin => Platform.isWindows;

  @override
  Future<bool> deleteFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return false;
    }
    if (Platform.isWindows) {
      final moved = await _channel.invokeMethod<bool>('moveToRecycleBin', {
        'path': path,
      });
      if (moved != true) {
        throw FileSystemException('无法将歌曲文件移入回收站', path);
      }
      return true;
    }

    await file.delete();
    return true;
  }
}
