part of '../app_controller.dart';

extension AppControllerSettingsActions on AppController {
  Future<bool> setDownloadDirectory(String selected) async {
    lastDirectoryNeedsAllFilesAccess = false;
    final trimmed = _normalizeManualDownloadPath(selected);
    if (trimmed.isEmpty || settings == null) {
      return false;
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
      return false;
    }
    settings = settings!.copyWith(downloadDirectory: trimmed);
    await storage.saveSettings(settings!);
    _notify();
    return true;
  }

  Future<String?> pickDownloadDirectory() async {
    if (!Platform.isWindows) {
      return null;
    }
    final initialDirectory = settings?.downloadDirectory ?? '';
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

  Future<void> setConcurrentDownloads(int value) async {
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(
      concurrentDownloads: value.clamp(1, 4).toInt(),
    );
    await storage.saveSettings(settings!);
    _notify();
    _scheduleDownloads();
  }

  Future<void> setAutoPlayOnStartup(bool enabled) async {
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(autoPlayOnStartup: enabled);
    await storage.saveSettings(settings!);
    _notify();
  }

  Future<void> setDefaultStartupPageIndex(int index) async {
    if (settings == null) {
      return;
    }
    final normalized = index == 2 ? 2 : 0;
    settings = settings!.copyWith(defaultStartupPageIndex: normalized);
    await storage.saveSettings(settings!);
    _notify();
  }

  void setDesktopLyricsSettings(DesktopLyricsSettings value) {
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(desktopLyrics: value);
    _debouncedSaveSettings();
    _notify();
  }
}
