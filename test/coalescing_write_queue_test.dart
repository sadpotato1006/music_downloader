import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/coalescing_write_queue.dart';

void main() {
  test(
    'a burst writes only the latest state and waits for persistence',
    () async {
      final queue = CoalescingWriteQueue();
      final started = Completer<void>();
      final release = Completer<void>();
      final written = <int>[];
      var completed = 0;
      final saves = [
        for (var index = 0; index < 20; index++)
          queue
              .enqueue(() async {
                written.add(index);
                started.complete();
                await release.future;
              })
              .then((_) {
                completed++;
              }),
      ];
      await started.future;
      expect(written, [19]);
      expect(completed, 0);
      release.complete();
      await Future.wait(saves);
      expect(completed, 20);
    },
  );

  test('requests during a write merge into one serial follow-up', () async {
    final queue = CoalescingWriteQueue();
    final started = Completer<void>();
    final release = Completer<void>();
    final written = <int>[];
    final first = queue.enqueue(() async {
      written.add(0);
      started.complete();
      await release.future;
    });
    await started.future;
    final second = queue.enqueue(() async {
      written.add(1);
    });
    final third = queue.enqueue(() async {
      written.add(2);
    });
    expect(written, [0]);
    final flushing = queue.flush();
    release.complete();
    await Future.wait([first, second, third, flushing]);
    expect(written, [0, 2]);
  });

  test(
    'a failed batch rejects every caller and later saves can retry',
    () async {
      final queue = CoalescingWriteQueue();
      final error = StateError('disk full');
      final first = queue.enqueue(() async {});
      final second = queue.enqueue(() async {
        throw error;
      });
      await Future.wait([
        expectLater(first, throwsA(same(error))),
        expectLater(second, throwsA(same(error))),
      ]);
      var written = false;
      await queue.enqueue(() async {
        written = true;
      });
      expect(written, isTrue);
      await queue.flush();
    },
  );

  test('flush drains newer writes even after the active write fails', () async {
    final queue = CoalescingWriteQueue();
    final started = Completer<void>();
    final release = Completer<void>();
    final error = StateError('first write failed');
    final first = queue.enqueue(() async {
      started.complete();
      await release.future;
      throw error;
    });
    final firstFailure = expectLater(first, throwsA(same(error)));
    await started.future;
    var written = false;
    final flushing = expectLater(queue.flush(), throwsA(same(error)));
    final next = queue.enqueue(() async {
      written = true;
    });
    release.complete();
    await Future.wait([firstFailure, next, flushing]);
    expect(written, isTrue);
  });

  test('simultaneous flushes wait for the same single write', () async {
    final queue = CoalescingWriteQueue();
    final release = Completer<void>();
    var calls = 0;
    final saved = queue.enqueue(() async {
      calls++;
      await release.future;
    });
    final first = queue.flush();
    final second = queue.flush();
    release.complete();
    await Future.wait([saved, first, second]);
    expect(calls, 1);
  });

  test('different files can persist independently', () async {
    final slow = CoalescingWriteQueue();
    final fast = CoalescingWriteQueue();
    final release = Completer<void>();
    var slowFinished = false;
    final slowSave = slow.enqueue(() async {
      await release.future;
      slowFinished = true;
    });
    await fast.enqueue(() async {});
    expect(slowFinished, isFalse);
    release.complete();
    await slowSave;
  });
}
