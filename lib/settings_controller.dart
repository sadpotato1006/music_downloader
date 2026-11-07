import 'package:flutter/foundation.dart';

import 'models.dart';
import 'settings_persistence.dart';
import 'settings_platform_service.dart';

typedef SettingsSaveState = ({bool pending, bool saving, Object? error});

/// Owns preferences and their write queue, independently of playback/library.
class SettingsController extends ChangeNotifier
    implements ValueListenable<AppSettings?> {
  SettingsController({
    required Future<void> Function(AppSettings) save,
    SettingsPlatformService? platform,
    AppSettings? initial = const AppSettings(downloadDirectory: ''),
  }) : platform = platform ?? SettingsPlatformService(),
       _value = initial,
       _theme = ValueNotifier(normalizeAppTheme(initial?.theme)) {
    _persistence = SettingsPersistence(
      current: () => _value,
      save: save,
      onChanged: _saveStateChanged,
    );
  }

  final SettingsPlatformService platform;
  late final SettingsPersistence _persistence;
  final ValueNotifier<String> _theme;
  AppSettings? _value;
  bool _disposed = false;
  final _saveState = ValueNotifier<SettingsSaveState>((
    pending: false,
    saving: false,
    error: null,
  ));
  ValueListenable<SettingsSaveState> get saveState => _saveState;

  void _saveStateChanged() {
    if (_disposed) return;
    _saveState.value = (
      pending: _persistence.hasPending,
      saving: _persistence.isSaving,
      error: _persistence.lastError,
    );
  }

  Future<bool> retrySave() async {
    try {
      await flush();
      return true;
    } catch (_) {
      return false; // The failure remains visible through saveState.
    }
  }

  @override
  AppSettings? get value => _value;
  ValueListenable<String> get theme => _theme;

  /// Restores a snapshot without scheduling a write (bootstrap/test fixtures).
  void restore(AppSettings? value) {
    if (_disposed || identical(_value, value)) return;
    _value = value;
    _theme.value = normalizeAppTheme(value?.theme);
    notifyListeners();
  }

  void update(AppSettings Function(AppSettings) change) {
    final current = _value;
    if (_disposed || current == null) return;
    final next = change(current);
    if (identical(next, current)) return;
    // Schedule before notifying: listeners may immediately flush or dispose.
    _persistence.schedule();
    restore(next);
  }

  Future<void> updateAndSave(AppSettings Function(AppSettings) change) async {
    update(change);
    await flush();
  }

  Future<void> flush() => _persistence.flush();

  Future<void> saveCurrent() {
    if (_value != null) _persistence.schedule();
    return flush();
  }

  void setTheme(String theme) {
    final next = normalizeAppTheme(theme);
    if (_value?.theme == next) return;
    update((value) => value.copyWith(theme: next));
  }

  Future<void> setAutoPlayOnStartup(bool enabled) =>
      updateAndSave((value) => value.copyWith(autoPlayOnStartup: enabled));

  Future<void> setDefaultStartupPageIndex(int index) => updateAndSave(
    (value) => value.copyWith(defaultStartupPageIndex: index == 2 ? 2 : 0),
  );

  Future<void> setConcurrentDownloads(int count) => updateAndSave(
    (value) => value.copyWith(concurrentDownloads: count.clamp(1, 4)),
  );

  Future<void> setCheckUpdatesOnStartup(bool enabled) =>
      updateAndSave((value) => value.copyWith(checkUpdatesOnStartup: enabled));

  void setDesktopLyricsSettings(DesktopLyricsSettings settings) =>
      update((value) => value.copyWith(desktopLyrics: settings));

  Future<bool> setDownloadDirectory(String path) async {
    if (_value == null || _disposed) return false;
    final selected = await platform.prepareDownloadDirectory(path);
    if (selected == null || _disposed) return false;
    await updateAndSave((value) => value.copyWith(downloadDirectory: selected));
    return true;
  }

  bool get lastDirectoryNeedsAllFilesAccess =>
      platform.lastDirectoryNeedsAllFilesAccess;
  Future<String?> pickDownloadDirectory() =>
      platform.pickDownloadDirectory(_value?.downloadDirectory ?? '');
  Future<void> openAllFilesAccessSettings() =>
      platform.openAllFilesAccessSettings();
  Future<bool> openProjectRepository() => platform.openProjectRepository();
  Future<bool> openExternalUrl(String url) => platform.openExternalUrl(url);

  @override
  void dispose() {
    _disposed = true;
    _persistence.cancelTimer();
    _theme.dispose();
    _saveState.dispose();
    super.dispose();
  }
}
