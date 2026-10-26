import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'playlist_transfer_service.dart';

class PlaylistFileService {
  const PlaylistFileService();
  Future<String?> open() async {
    final selected = await FilePicker.pickFile(
      dialogTitle: '导入青听歌单',
      type: FileType.custom,
      allowedExtensions: ['json'],
      windowsOptions: const WindowsOptions(lockParentWindow: true),
      linuxOptions: const LinuxOptions(lockParentWindow: true),
    );
    if (selected == null) return null;
    if ((await selected.length() ?? 0) > PlaylistTransferService.maxFileBytes) {
      throw const FormatException('歌单文件超过 10 MiB');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in selected.readAsByteStream()) {
      if (builder.length + chunk.length >
          PlaylistTransferService.maxFileBytes) {
        throw const FormatException('歌单文件超过 10 MiB');
      }
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes());
  }

  Future<bool> save(String name, String content) async {
    var safe = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    if (safe.isEmpty) safe = '青听歌单';
    if (safe.length > 100) safe = safe.substring(0, 100);
    final result = await FilePicker.saveFile(
      dialogTitle: '导出青听歌单',
      fileName: '$safe.qingting.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: Uint8List.fromList(utf8.encode(content)),
      mimeType: 'application/json',
      windowsOptions: const WindowsOptions(lockParentWindow: true),
      linuxOptions: const LinuxOptions(lockParentWindow: true),
    );
    return result != null;
  }
}
