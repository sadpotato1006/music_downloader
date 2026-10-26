import 'dart:async';

import 'app_log.dart';
import 'models.dart';

/// Debounces UI edits, retries failed saves on the next flush, and retains an
/// edit made while an earlier snapshot is being written.
class SettingsPersistence {
  SettingsPersistence({
    required this.current,
    required this.save,
    this.delay = const Duration(milliseconds: 350),
  });
  final AppSettings? Function() current;
  final Future<void> Function(AppSettings settings) save;
  final Duration delay;
  Timer? _timer;
  int _revision = 0;
  int _savedRevision = 0;
  Future<void>? _active;

  void schedule() {
    _revision++;
    _timer?.cancel();
    _timer = Timer(delay, () async {
      try {
        await flush();
      } catch (error, stack) {
        AppLog.instance.error(
          'storage',
          '保存设置失败，将在下次保存时重试',
          error: error,
          stackTrace: stack,
        );
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
      try {
        await operation;
        _savedRevision = revision;
      } finally {
        if (identical(_active, operation)) _active = null;
      }
    }
  }

  void cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
