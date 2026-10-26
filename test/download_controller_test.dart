import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/download_controller.dart';
import 'package:qingting/download_transfer_service.dart';
import 'package:qingting/models.dart';
import 'package:qingting/storage_service.dart';

void main() {
  late Directory root;
  late Dio dio;
  late _Storage storage;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('qingting-queue-test-');
    dio = Dio();
    storage = _Storage();
  });
  tearDown(() async {
    dio.close(force: true);
    await root.delete(recursive: true);
  });
  DownloadTask task(String id) => DownloadTask(
    id: id,
    track: TrackSearchResult(
      id: id,
      title: id,
      artist: '',
      source: 'test',
      detailUrl: 'https://example.test/$id',
    ),
    candidate: AudioCandidate(
      url: 'https://example.test/$id.mp3',
      format: 'mp3',
    ),
    status: DownloadStatus.queued,
    progress: 0,
    savePath: '${root.path}/$id.mp3',
  );

  test(
    'enforces the concurrency limit and starts waiting tasks after a worker finishes',
    () async {
      final started = <String>[];
      final releases = <String, Completer<void>>{};
      late final DownloadController queue;
      queue = DownloadController(
        storage: storage,
        transferService: DownloadTransferService(dio),
        concurrency: () => 2,
        canStart: () => true,
        runTask: (id, token) async {
          started.add(id);
          await (releases[id] = Completer<void>()).future;
          queue.update(
            id,
            (task) => task.copyWith(status: DownloadStatus.completed),
          );
        },
      );
      addTearDown(queue.dispose);
      queue.tasks = [task('a'), task('b'), task('c')];
      queue.schedule();
      expect(started, ['a', 'b']);
      expect(queue.activeCount, 2);
      releases['a']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(started, ['a', 'b', 'c']);
      releases['b']!.complete();
      releases['c']!.complete();
      await queue.waitForIdle();
      expect(queue.activeCount, 0);
    },
  );
  test(
    'pause and immediate retry waits for the old worker before starting again',
    () async {
      final first = Completer<void>();
      var calls = 0;
      late final DownloadController queue;
      queue = DownloadController(
        storage: storage,
        transferService: DownloadTransferService(dio),
        concurrency: () => 1,
        canStart: () => true,
        runTask: (id, token) async {
          calls++;
          if (calls == 1) {
            await first.future;
            expect(token.isCancelled, isTrue);
          } else {
            queue.update(
              id,
              (task) => task.copyWith(status: DownloadStatus.completed),
            );
          }
        },
      );
      addTearDown(queue.dispose);
      queue.tasks = [task('a')];
      queue.schedule();
      queue.pause('a');
      queue.retry('a');
      expect(calls, 1);
      first.complete();
      await queue.waitForIdle();
      expect(calls, 2);
      expect(queue.tasks.single.status, DownloadStatus.completed);
      await queue.flush();
    },
  );
  test('cancel cleans the partial file before a retry starts', () async {
    final file = File('${root.path}/a.mp3');
    await file.writeAsString('old partial');
    late final DownloadController queue;
    queue = DownloadController(
      storage: storage,
      transferService: DownloadTransferService(dio),
      concurrency: () => 1,
      canStart: () => true,
      runTask: (id, token) async {
        expect(await file.exists(), isFalse);
        await file.writeAsString('new download');
        queue.update(
          id,
          (task) => task.copyWith(status: DownloadStatus.completed),
        );
      },
    );
    addTearDown(queue.dispose);
    queue.tasks = [task('a').copyWith(status: DownloadStatus.paused)];
    queue.cancel('a');
    queue.retry('a');
    await queue.waitForIdle();
    expect(await file.readAsString(), 'new download');
    await queue.flush();
  });
  test('concurrent path reservations cannot choose the same file', () async {
    final queue = DownloadController(
      storage: StorageService(),
      transferService: DownloadTransferService(dio),
      concurrency: () => 1,
      canStart: () => false,
      runTask: (_, _) async {},
    );
    addTearDown(queue.dispose);
    final paths = await Future.wait(
      List.generate(
        3,
        (_) => queue.reservePath(
          directory: root.path,
          title: 'Song',
          artist: 'Artist',
          format: 'mp3',
          libraryPaths: () => const [],
        ),
      ),
    );
    expect(paths.toSet(), hasLength(3));
    expect(queue.unfinishedPaths, hasLength(3));
    for (final path in paths) {
      queue.releasePath(path);
    }
    expect(queue.unfinishedPaths, isEmpty);
  });
  test(
    'save omits canceled and fully imported tasks but retains pending library imports',
    () async {
      final queue = DownloadController(
        storage: storage,
        transferService: DownloadTransferService(dio),
        concurrency: () => 1,
        canStart: () => false,
        runTask: (_, _) async {},
      );
      addTearDown(queue.dispose);
      queue.tasks = [
        task('a'),
        task('b').copyWith(status: DownloadStatus.canceled),
        task('c').copyWith(status: DownloadStatus.completed),
        task(
          'd',
        ).copyWith(status: DownloadStatus.completed, libraryPending: true),
      ];
      await queue.save();
      await queue.flush();
      expect(storage.saved.map((task) => task.id), ['a', 'd']);
    },
  );
}

class _Storage extends StorageService {
  List<DownloadTask> saved = [];
  @override
  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {
    saved = tasks;
  }
}
