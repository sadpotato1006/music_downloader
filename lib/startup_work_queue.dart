import 'dart:async';

/// Runs startup maintenance after the first frame and primary playback work.
/// Cancelling drops queued jobs and wakes frame/delay waits; an active job is
/// allowed to finish so shutdown can flush its writes.
class StartupWorkQueue {
  StartupWorkQueue({
    this.gap = const Duration(milliseconds: 300),
    required this.onError,
  });
  final Duration gap;
  final void Function(Object, StackTrace) onError;
  final Completer<void> _cancelled = Completer<void>();
  Future<void>? _operation;
  Timer? _timer;

  bool get cancelled => _cancelled.isCompleted;
  Future<void> get done => _operation ?? Future<void>.value();

  Future<void> start({
    Future<void> Function()? firstFrame,
    required Future<void> Function() primary,
    required List<Future<void> Function()> maintenance,
  }) => _operation ??= _run(firstFrame, [primary, ...maintenance]);

  Future<void> _run(
    Future<void> Function()? firstFrame,
    List<Future<void> Function()> jobs,
  ) async {
    if (firstFrame != null) {
      await Future.any([firstFrame(), _cancelled.future]);
    }
    for (var i = 0; i < jobs.length; i++) {
      if (cancelled) break;
      if (i > 0) {
        final pause = Completer<void>();
        _timer = Timer(gap, pause.complete);
        await Future.any([pause.future, _cancelled.future]);
        _timer?.cancel();
        _timer = null;
      }
      if (cancelled) break;
      try {
        await jobs[i]();
      } catch (error, stack) {
        onError(error, stack);
      }
    }
  }

  void cancel() {
    if (cancelled) return;
    _cancelled.complete();
    _timer?.cancel();
    _timer = null;
  }
}
