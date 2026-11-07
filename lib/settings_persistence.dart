import 'dart:async';

import 'app_log.dart';
import 'models.dart';

/// Debounces UI edits, retries failed saves on the next flush, and retains an
/// edit made while an earlier snapshot is being written.
class SettingsPersistence {
  SettingsPersistence({
    required this.current,
    required this.save,
    this.onChanged,
    this.delay = const Duration(milliseconds: 350),
  });
  final AppSettings? Function() current;
  final Future<void> Function(AppSettings settings) save;
  final Duration delay;
  final void Function()? onChanged;
  Object? lastError;
  bool get hasPending => _savedRevision < _revision;
  bool get isSaving => _active != null;
  Timer? _timer;
  int _revision = 0;
  int _savedRevision = 0;
  Future<void>? _active;

  void schedule() {
    _revision++;
    onChanged?.call();
    _timer?.cancel();
    _timer = Timer(delay, () async {
      try {
        await flush();
      } catch (_) {
        // flush records the error and retains the pending revision for retry.
      }
    });
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    while (_savedRevision < _revision) {
      final running = _active;
      if (running != null) {
        await running;
        continue;
      }
      final snapshot = current();
      if (snapshot == null) return;
      final revision = _revision;
      final operation = Future<void>.sync(() => save(snapshot));
      _active = operation;
      onChanged?.call();
      try {
        await operation;
        _savedRevision = revision;
        lastError = null;
      } catch (error, stack) {
        lastError = error;
        AppLog.instance.error(
          'storage',
          '保存设置失败，修改仍待保存',
          error: error,
          stackTrace: stack,
        );
        rethrow;
      } finally {
        if (identical(_active, operation)) _active = null;
        onChanged?.call();
      }
    }
  }

  void cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
