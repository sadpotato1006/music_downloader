import 'dart:io';

import 'android_storage_access.dart';
import 'linux_desktop_service.dart';

/// Platform integration used by settings; no application controller dependency.
class SettingsPlatformService {
  bool lastDirectoryNeedsAllFilesAccess = false;

  Future<String?> prepareDownloadDirectory(String selected) async {
    lastDirectoryNeedsAllFilesAccess = false;
    // Backslashes, commas and trailing spaces are valid Linux directory names.
    final trimmed = Platform.isLinux
        ? selected
        : _normalizeManualDownloadPath(selected);
    if (trimmed.trim().isEmpty) {
      return null;
    }
    try {
      final directory = Directory(trimmed);
      await directory.create(recursive: true);
      final probe = File(
        '${directory.path}${Platform.pathSeparator}.qingting_write_test',
      );
      await probe.writeAsString('ok');
      if (await probe.exists()) {
        await probe.delete();
      }
    } catch (_) {
      if (AndroidStorageAccess.isAndroid &&
          AndroidStorageAccess.isPublicExternalPath(trimmed) &&
          !await AndroidStorageAccess.hasAllFilesAccess()) {
        lastDirectoryNeedsAllFilesAccess = true;
      }
      return null;
    }
    return trimmed;
  }

  Future<String?> pickDownloadDirectory(String initialDirectory) async {
    if (Platform.isLinux) {
      return LinuxDesktopService.pickDirectory(initialDirectory);
    }
    if (!Platform.isWindows) {
      return null;
    }
    final script =
        '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
\$dialog.Description = '选择青听下载目录'
\$dialog.ShowNewFolderButton = \$true
\$initial = '${_escapePowerShellSingleQuoted(initialDirectory)}'
if (\$initial -and [System.IO.Directory]::Exists(\$initial)) {
  \$dialog.SelectedPath = \$initial
}
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  Write-Output \$dialog.SelectedPath
}
''';
    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-Command', script],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
      if (result.exitCode != 0) {
        return null;
      }
      final selected = result.stdout.toString().trim();
      return selected.isEmpty ? null : selected;
    } catch (_) {
      return null;
    }
  }

  String _escapePowerShellSingleQuoted(String value) {
    return value.replaceAll("'", "''");
  }

  Future<void> openAllFilesAccessSettings() {
    return AndroidStorageAccess.openAllFilesAccessSettings();
  }

  Future<bool> openProjectRepository() {
    return openExternalUrl('https://github.com/sadpotato1006/music_downloader');
  }

  Future<bool> openExternalUrl(String url) async {
    if (Platform.isLinux) {
      return LinuxDesktopService.openUrl(url);
    }
    if (AndroidStorageAccess.isAndroid) {
      return AndroidStorageAccess.openUrl(url);
    }
    if (Platform.isWindows) {
      try {
        await Process.start('rundll32.exe', [
          'url.dll,FileProtocolHandler',
          url,
        ]);
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  String _normalizeManualDownloadPath(String value) {
    return value
        .trim()
        .replaceAll('\\', Platform.pathSeparator)
        .replaceFirstMapped(
          RegExp(r'[，,]+([/\\])?$'),
          (match) => match.group(1) ?? '',
        )
        .trim();
  }
}
