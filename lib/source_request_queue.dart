import 'dart:async';

class ObsoleteSourceRequest implements Exception {
  const ObsoleteSourceRequest();
}

/// Serializes source requests and drops obsolete work before contacting a site.
/// A rejected request releases the queue without imposing another local delay.
class SourceRequestQueue {
  SourceRequestQueue({this.gap = const Duration(seconds: 2)});
  final Duration gap;
  Future<void> _tail = Future<void>.value();
  DateTime? _lastSuccess;

  void resetDelay() => _lastSuccess = null;

  Future<T> run<T>(
    Future<T> Function() request, {
    bool Function()? shouldRun,
  }) async {
    final previous = _tail;
    final completion = Completer<void>();
    _tail = previous.then((_) => completion.future);
    await previous;
    try {
      if (shouldRun != null && !shouldRun()) {
        throw const ObsoleteSourceRequest();
      }
      final last = _lastSuccess;
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        if (elapsed < gap) await Future<void>.delayed(gap - elapsed);
      }
      if (shouldRun != null && !shouldRun()) {
        throw const ObsoleteSourceRequest();
      }
      final result = await request();
      _lastSuccess = DateTime.now();
      return result;
    } finally {
      completion.complete();
    }
  }
}
