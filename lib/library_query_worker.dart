import 'dart:async';
import 'dart:isolate';

import 'library_search.dart';
import 'models.dart';

typedef _Row = ({
  String path,
  String title,
  String artist,
  String album,
  int time,
});

class LibraryQueryResult {
  const LibraryQueryResult(this.order, this.metadataPaths);
  final List<int> order;
  final Set<String> metadataPaths;
}

/// One worker retains metadata indexes and ordering between searches. Only a
/// changed library sends a new metadata snapshot; lyrics and artwork stay out.
class LibraryQueryWorker {
  ReceivePort? _replies;
  ReceivePort? _errors;
  ReceivePort? _exits;
  Isolate? _isolate;
  Completer<SendPort>? _ready;
  final Map<int, Completer<LibraryQueryResult>> _requests = {};
  List<DownloadedTrack>? _sentSource;
  int _nextId = 0;
  bool _disposed = false;

  Future<SendPort> _start() {
    if (_disposed) return Future.error(StateError('Library worker disposed'));
    if (_ready != null) return _ready!.future;
    final ready = _ready = Completer<SendPort>();
    _replies = ReceivePort()
      ..listen((message) {
        if (message is SendPort) {
          if (!ready.isCompleted) ready.complete(message);
        } else if (message is (int, LibraryQueryResult)) {
          _requests.remove(message.$1)?.complete(message.$2);
        } else if (message is (int, String)) {
          _requests.remove(message.$1)?.completeError(StateError(message.$2));
        }
      });
    _errors = ReceivePort()..listen((error) => _fail(StateError('$error')));
    _exits = ReceivePort()
      ..listen((_) {
        if (!_disposed) _fail(StateError('Library worker stopped'));
      });
    Isolate.spawn(
      _runLibraryQueries,
      _replies!.sendPort,
      onError: _errors!.sendPort,
      onExit: _exits!.sendPort,
      debugName: 'qingting-library-query',
    ).then((isolate) {
      if (_disposed || !identical(_ready, ready)) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    }, onError: (Object error, StackTrace stack) => _fail(error));
    return ready.future;
  }

  Future<LibraryQueryResult> query(
    List<DownloadedTrack> source,
    String query,
    LibrarySortMode sort,
  ) async {
    final port = await _start();
    if (_disposed) throw StateError('Library worker disposed');
    final rows = identical(source, _sentSource)
        ? null
        : [
            for (final track in source)
              (
                path: track.path,
                title: track.title,
                artist: track.artist,
                album: track.album,
                time: track.downloadedAt.microsecondsSinceEpoch,
              ),
          ];
    _sentSource = source;
    final id = ++_nextId;
    final result = Completer<LibraryQueryResult>();
    _requests[id] = result;
    port.send((id, rows, query, sort));
    return result.future;
  }

  void _fail(Object error) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    for (final request in _requests.values) {
      request.completeError(error);
    }
    _requests.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _replies?.close();
    _errors?.close();
    _exits?.close();
    _ready = null;
    _sentSource = null;
  }

  void dispose() {
    _disposed = true;
    _fail(StateError('Library worker disposed'));
  }

  void reset() => _fail(StateError('Library snapshot released'));
}

void _runLibraryQueries(SendPort reply) {
  final input = ReceivePort();
  reply.send(input.sendPort);
  var rows = <_Row>[];
  final indexes = <String, (_Row, LibrarySearchIndex)>{};
  List<int>? order;
  LibrarySortMode? lastSort;
  input.listen((message) {
    final (id, snapshot, query, sort) =
        message as (int, List<_Row>?, String, LibrarySortMode);
    try {
      if (snapshot != null) {
        rows = snapshot;
        order = null;
        final paths = rows.map((row) => row.path).toSet();
        indexes.removeWhere((path, _) => !paths.contains(path));
      }
      if (order == null || lastSort != sort) {
        order = List.generate(rows.length, (i) => i)
          ..sort((a, b) {
            final left = rows[a], right = rows[b];
            int compare(String a, String b) =>
                a.toLowerCase().compareTo(b.toLowerCase());
            return switch (sort) {
              LibrarySortMode.downloadedAtDesc => right.time.compareTo(
                left.time,
              ),
              LibrarySortMode.titleAsc => compare(left.title, right.title),
              LibrarySortMode.artistAsc => compare(
                left.artist.isEmpty ? '未知歌手' : left.artist,
                right.artist.isEmpty ? '未知歌手' : right.artist,
              ),
            };
          });
        lastSort = sort;
      }
      final matches = <String>{};
      if (query.isNotEmpty) {
        for (final row in rows) {
          var cached = indexes[row.path];
          if (cached == null ||
              cached.$1.title != row.title ||
              cached.$1.artist != row.artist ||
              cached.$1.album != row.album) {
            cached = (
              row,
              LibrarySearchIndex.fromTrack(
                DownloadedTrack(
                  id: row.path,
                  title: row.title,
                  artist: row.artist,
                  album: row.album,
                  path: row.path,
                  format: '',
                  sourceUrl: '',
                  downloadedAt: DateTime.fromMicrosecondsSinceEpoch(row.time),
                ),
              ),
            );
            indexes[row.path] = cached;
          }
          if (cached.$2.matchesNormalizedQuery(query)) matches.add(row.path);
        }
      }
      reply.send((id, LibraryQueryResult(order!, matches)));
    } catch (error) {
      reply.send((id, '$error'));
    }
  });
}
