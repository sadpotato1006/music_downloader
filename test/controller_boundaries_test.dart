import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/models.dart';
import 'package:qingting/music_search_controller.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/settings_persistence.dart';
import 'package:qingting/source_request_queue.dart';

void main() {
  test(
    'a failed source request releases the queue for a later request',
    () async {
      final queue = SourceRequestQueue(gap: Duration.zero);
      await expectLater(
        queue.run(() async => throw StateError('refused')),
        throwsStateError,
      );
      expect(await queue.run(() async => 42), 42);
    },
  );
  test('obsolete queued work never calls its source', () async {
    final queue = SourceRequestQueue(gap: Duration.zero);
    final release = Completer<void>();
    final first = queue.run(() => release.future);
    var calls = 0;
    var current = true;
    final second = queue.run(() async {
      calls++;
      return 1;
    }, shouldRun: () => current);
    final assertion = expectLater(
      second,
      throwsA(isA<ObsoleteSourceRequest>()),
    );
    current = false;
    release.complete();
    await first;
    await assertion;
    expect(calls, 0);
  });
  test('late search results cannot replace the newest query', () async {
    final requests = <String, Completer<List<TrackSearchResult>>>{};
    final search = MusicSearchController(
      request: (_, keyword, current) =>
          (requests[keyword] = Completer<List<TrackSearchResult>>()).future,
      describeError: (error) => '$error',
    );
    addTearDown(search.dispose);
    final old = search.search(_Source(), 'old');
    final newer = search.search(_Source(), 'new');
    requests['new']!.complete([_track('new')]);
    await newer;
    requests['old']!.complete([_track('old')]);
    await old;
    expect(search.results.single.id, 'new');
    expect(search.isSearching, isFalse);
  });
  test(
    'disposing search drops pending completions without notifying listeners',
    () async {
      final response = Completer<List<TrackSearchResult>>();
      final search = MusicSearchController(
        request: (_, _, _) => response.future,
        describeError: (error) => '$error',
      );
      var notifications = 0;
      search.addListener(() => notifications++);
      final operation = search.search(_Source(), 'query');
      search.dispose();
      response.complete([_track('late')]);
      await operation;
      expect(notifications, 1);
    },
  );
  test('settings flush includes edits made during an earlier write', () async {
    var settings = const AppSettings(downloadDirectory: 'first');
    final release = Completer<void>();
    final saved = <String>[];
    final persistence = SettingsPersistence(
      current: () => settings,
      save: (snapshot) async {
        saved.add(snapshot.downloadDirectory);
        if (saved.length == 1) await release.future;
      },
    );
    addTearDown(persistence.cancelTimer);
    persistence.schedule();
    final flushing = persistence.flush();
    settings = settings.copyWith(downloadDirectory: 'latest');
    persistence.schedule();
    release.complete();
    await flushing;
    expect(saved, ['first', 'latest']);
    await persistence.flush();
    expect(saved, hasLength(2));
  });
  test('a failed settings write remains pending for the next flush', () async {
    var calls = 0;
    final persistence = SettingsPersistence(
      current: () => const AppSettings(downloadDirectory: 'music'),
      save: (_) async {
        if (++calls == 1) throw StateError('disk unavailable');
      },
    );
    addTearDown(persistence.cancelTimer);
    persistence.schedule();
    await expectLater(persistence.flush(), throwsStateError);
    await persistence.flush();
    expect(calls, 2);
  });
}

TrackSearchResult _track(String id) => TrackSearchResult(
  id: id,
  title: id,
  artist: '',
  source: 'test',
  detailUrl: 'https://example.test/$id',
);

class _Source implements MusicSource {
  @override
  String get name => 'test';
  @override
  Future<List<TrackSearchResult>> search(
    String keyword, {
    int page = 1,
  }) async => [];
  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) =>
      throw UnimplementedError();
  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) =>
      throw UnimplementedError();
}
