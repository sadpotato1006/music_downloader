import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/startup_work_queue.dart';

void main() {
  test('maintenance waits for the first frame and primary playback', () async {
    final frame = Completer<void>();
    final playing = Completer<void>();
    final calls = <String>[];
    final queue = StartupWorkQueue(
      gap: Duration.zero,
      onError: (e, _) => fail('$e'),
    );
    addTearDown(queue.cancel);
    final done = queue.start(
      firstFrame: () => frame.future,
      primary: () async {
        calls.add('play');
        await playing.future;
      },
      maintenance: [
        () async => calls.add('import'),
        () async => calls.add('sync'),
      ],
    );
    expect(calls, isEmpty);
    frame.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['play']);
    playing.complete();
    await done;
    expect(calls, ['play', 'import', 'sync']);
  });

  test('cancelling while waiting for a frame does not hang shutdown', () async {
    final frame = Completer<void>();
    final queue = StartupWorkQueue(onError: (e, _) => fail('$e'));
    var ran = false;
    final done = queue.start(
      firstFrame: () => frame.future,
      primary: () async => ran = true,
      maintenance: [],
    );
    queue.cancel();
    await done;
    expect(ran, isFalse);
  });

  test(
    'cancelling lets an active task finish but drops remaining work',
    () async {
      final active = Completer<void>();
      final calls = <String>[];
      final queue = StartupWorkQueue(
        gap: Duration.zero,
        onError: (e, _) => fail('$e'),
      );
      final done = queue.start(
        primary: () async {
          calls.add('play');
          await active.future;
        },
        maintenance: [() async => calls.add('scan')],
      );
      queue.cancel();
      active.complete();
      await done;
      expect(calls, ['play']);
    },
  );

  test('a failed maintenance task does not prevent later work', () async {
    final failures = <Object>[];
    var ran = false;
    final queue = StartupWorkQueue(
      gap: Duration.zero,
      onError: (e, _) => failures.add(e),
    );
    addTearDown(queue.cancel);
    await queue.start(
      primary: () async {},
      maintenance: [
        () async => throw StateError('failed import'),
        () async => ran = true,
      ],
    );
    expect(failures.single, isA<StateError>());
    expect(ran, isTrue);
  });
}
