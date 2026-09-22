import 'dart:async';

/// Serializes writes and replaces not-yet-started writes with the latest one.
/// All callers in a merged batch complete only after that batch is persisted.
class CoalescingWriteQueue {
  Future<void> Function()? _pendingWrite;
  Completer<void>? _pendingCompletion;
  Future<void>? _active;
  bool _scheduled = false;

  Future<void> enqueue(Future<void> Function() write) {
    _pendingWrite = write;
    final completion = _pendingCompletion ??= Completer<void>();
    _schedule();
    return completion.future;
  }

  void _schedule() {
    if (_scheduled || _active != null || _pendingWrite == null) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_active == null) _startPending();
    });
  }

  Future<void>? _startPending() {
    final write = _pendingWrite;
    final completion = _pendingCompletion;
    if (write == null || completion == null) return null;
    _pendingWrite = null;
    _pendingCompletion = null;
    _active = completion.future;
    unawaited(_run(write, completion));
    return completion.future;
  }

  Future<void> _run(
    Future<void> Function() write,
    Completer<void> completion,
  ) async {
    try {
      await write();
      completion.complete();
    } catch (error, stackTrace) {
      completion.completeError(error, stackTrace);
    } finally {
      _active = null;
      _schedule();
    }
  }

  /// Includes writes queued while an earlier write is in progress, even if an
  /// earlier batch fails. A later batch must still get a chance to persist.
  Future<void> flush() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    while (true) {
      final operation = _active ?? _startPending();
      if (operation == null) break;
      try {
        await operation;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}
