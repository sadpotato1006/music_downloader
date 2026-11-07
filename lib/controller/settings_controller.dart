part of '../app_controller.dart';

// Compatibility entry points for existing callers. State and persistence belong
// to SettingsController; only application-wide side effects stay here.
extension AppControllerSettingsActions on AppController {
  void setTheme(String theme) => preferences.setTheme(theme);

  Future<void> setCheckUpdatesOnStartup(bool enabled) =>
      preferences.setCheckUpdatesOnStartup(enabled);

  Future<bool> setDownloadDirectory(String path) =>
      preferences.setDownloadDirectory(path);
  Future<String?> pickDownloadDirectory() =>
      preferences.pickDownloadDirectory();
  Future<void> openAllFilesAccessSettings() =>
      preferences.openAllFilesAccessSettings();
  Future<bool> openProjectRepository() => preferences.openProjectRepository();
  Future<bool> openExternalUrl(String url) => preferences.openExternalUrl(url);
  Future<void> setConcurrentDownloads(int value) =>
      preferences.setConcurrentDownloads(value);
  Future<void> setAutoPlayOnStartup(bool value) =>
      preferences.setAutoPlayOnStartup(value);
  Future<void> setDefaultStartupPageIndex(int index) =>
      preferences.setDefaultStartupPageIndex(index);
  void setDesktopLyricsSettings(DesktopLyricsSettings value) =>
      preferences.setDesktopLyricsSettings(value);
}
