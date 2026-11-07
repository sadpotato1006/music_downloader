import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/song_file_access.dart';

void main() {
  test('all readers must finish before a write or deletion can start', () {
    final files = SongFileAccess();
    addTearDown(files.dispose);
    expect(files.tryRead('song'), isTrue);
    expect(files.tryRead('song'), isTrue);
    expect(files.tryWrite('song'), isFalse);
    expect(files.tryDelete('song'), isFalse);
    files.endRead('song');
    expect(files.tryWrite('song'), isFalse);
    files.endRead('song');
    expect(files.tryWrite('song'), isTrue);
    expect(files.tryRead('song'), isFalse);
    expect(files.tryDelete('song'), isFalse);
    files.endWrite('song');
    expect(files.tryDelete('song'), isTrue);
    expect(files.tryRead('song'), isFalse);
    files.endDelete('song');
    expect(files.tryRead('song'), isTrue);
    files.endRead('song');
  });

  test(
    'sync drains reads, writes and deletion while blocking new work',
    () async {
      final files = SongFileAccess();
      addTearDown(files.dispose);
      files.tryRead('reading');
      files.tryWrite('writing');
      files.tryDelete('deleting');
      var started = false;
      final sync = files.beginSync().then((acquired) => started = acquired);
      expect(files.tryRead('new'), isFalse);
      expect(files.tryWrite('new'), isFalse);
      expect(files.tryDelete('new'), isFalse);
      files.endRead('reading');
      files.endWrite('writing');
      await Future<void>.delayed(Duration.zero);
      expect(started, isFalse);
      files.endDelete('deleting');
      await sync;
      expect(started, isTrue);
      files.endSync();
      expect(files.tryWrite('new'), isTrue);
      files.endWrite('new');
    },
  );

  test('waiting read resumes after a writer and after sync', () async {
    final files = SongFileAccess();
    addTearDown(files.dispose);
    files.tryWrite('song');
    final reading = files.readWhenAvailable('song');
    files.endWrite('song');
    expect(await reading, isTrue);
    files.endRead('song');
    expect(await files.beginSync(), isTrue);
    var finished = false;
    final afterSync = files.readWhenAvailable('song').then((acquired) {
      finished = true;
      return acquired;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    files.endSync();
    expect(await afterSync, isTrue);
    files.endRead('song');
  });

  test(
    'sync can import completed files without admitting ordinary reads',
    () async {
      final files = SongFileAccess();
      addTearDown(files.dispose);
      await files.beginSync();
      expect(files.tryRead('song'), isFalse);
      expect(files.tryRead('song', completedDownload: true), isTrue);
      files.endRead('song');
      files.endSync();
    },
  );

  test('dispose releases waiters and rejects new acquisitions', () async {
    final files = SongFileAccess();
    files.tryWrite('song');
    final reading = files.readWhenAvailable('song');
    final syncing = files.beginSync();
    files.dispose();
    expect(await reading, isFalse);
    expect(await syncing, isFalse);
    expect(files.tryRead('song', completedDownload: true), isFalse);
    expect(files.tryWrite('other'), isFalse);
    expect(files.tryDelete('other'), isFalse);
    // Finally blocks may run after disposal.
    files.endWrite('song');
    files.endSync();
  });

  test(
    'sync reconciliation admits reads while keeping writes blocked',
    () async {
      final files = SongFileAccess();
      addTearDown(files.dispose);
      await files.beginSync();
      final reading = files.readWhenAvailable('song');
      expect(files.tryRead('other'), isFalse);
      files.finishSyncFileChanges();
      expect(await reading, isTrue);
      expect(files.tryRead('other'), isTrue);
      expect(files.tryWrite('third'), isFalse);
      expect(files.tryDelete('third'), isFalse);
      files.endRead('song');
      files.endRead('other');
      files.endSync();
      expect(files.tryWrite('third'), isTrue);
      files.endWrite('third');
      // A later sync must block reads again until its file work finishes.
      await files.beginSync();
      expect(files.tryRead('song'), isFalse);
      files.endSync();
    },
  );
}
