import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/audio_cache_service.dart';
import 'package:qingting/download_controller.dart';
import 'package:qingting/download_transfer_service.dart';
import 'package:qingting/models.dart';
import 'package:qingting/storage_service.dart';

const _track = TrackSearchResult(
  id: 'a',
  title: 'Song',
  artist: 'Artist',
  source: 'test',
  detailUrl: 'https://example.test/a',
);
const _candidate = AudioCandidate(
  url: 'https://example.test/song.mp3?token=old',
  format: 'mp3',
  qualityLabel: 'MP3',
  headers: {'Referer': 'https://example.test/'},
);
final _audio = [...'ID3'.codeUnits, ...List.generate(200000, (i) => i % 256)];

void main() {
  late Directory root;
  late Dio dio;
  late _AudioAdapter adapter;
  late AudioCacheService cache;
  late HttpClient client;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qingting-audio-cache-');
    adapter = _AudioAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    cache = AudioCacheService(directory: () async => root, dio: dio);
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    if (adapter.gate != null && !adapter.gate!.isCompleted) {
      adapter.gate!.complete();
    }
    client.close(force: true);
    await cache.dispose();
    dio.close(force: true);
    await root.delete(recursive: true);
  });

  Future<Uri> playback({AudioCandidate candidate = _candidate}) => cache
      .playbackUri(AudioCacheService.trackKey(_track, candidate), candidate);

  DownloadTask task({AudioCandidate candidate = _candidate}) => DownloadTask(
    id: 'download',
    track: _track,
    candidate: candidate,
    status: DownloadStatus.downloading,
    progress: 0,
    savePath: '${root.path}/download/song.mp3',
  );

  Future<bool> copy({DownloadTask? download, CancelToken? token}) =>
      cache.copyIfAvailable(
        download ?? task(),
        token ?? CancelToken(),
        onResponse: (_, _, _) {},
        onProgress: (_, _) {},
      );

  Future<HttpClientResponse> get(
    Uri uri, {
    String? range,
    bool head = false,
  }) async {
    final request = await client.openUrl(head ? 'HEAD' : 'GET', uri);
    if (range != null) request.headers.set('range', range);
    return request.close();
  }

  Future<List<int>> bytes(HttpClientResponse response) =>
      response.fold<List<int>>([], (all, chunk) => all..addAll(chunk));

  test(
    'plays before completion and download shares exactly one upstream fetch',
    () async {
      adapter.gate = Completer<void>();
      final uri = await playback();
      final response = await get(uri);
      final first = Completer<void>();
      final played = <int>[];
      final consumed = response.forEach((chunk) {
        played.addAll(chunk);
        if (!first.isCompleted) first.complete();
      });
      await first.future.timeout(const Duration(seconds: 3));
      expect(played, isNotEmpty);
      expect(played.length, lessThan(_audio.length));
      // A renewed URL identifies the same rendition.
      final renewed = AudioCandidate(
        url: 'https://other.test/song.mp3?token=new',
        format: 'mp3',
        qualityLabel: 'MP3',
      );
      var copied = false;
      final copying = copy(download: task(candidate: renewed)).then((value) {
        copied = value;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(copied, isFalse);
      expect(adapter.requests, hasLength(1));
      adapter.gate!.complete();
      await consumed;
      expect(await copying, isTrue);
      expect(played, _audio);
      expect(await File(task().savePath).readAsBytes(), _audio);
      expect(
        adapter.requests.single.headers['Referer'],
        'https://example.test/',
      );
      // Editing the downloaded file cannot damage the cache used by playback.
      await File(task().savePath).writeAsBytes([1, 2, 3]);
      expect(await bytes(await get(uri)), _audio);
      expect(adapter.requests, hasLength(1));
    },
  );

  test('HEAD and byte ranges support player probes and seeking', () async {
    final uri = await playback();
    expect(await bytes(await get(uri)), _audio);
    final head = await get(uri, head: true);
    expect(head.contentLength, _audio.length);
    expect(await bytes(head), isEmpty);
    for (final range in ['bytes=10-19', 'bytes=-10', 'bytes=199999-']) {
      final response = await get(uri, range: range);
      expect(response.statusCode, 206);
      expect(response.headers.value('accept-ranges'), 'bytes');
      final expected = range == 'bytes=10-19'
          ? _audio.sublist(10, 20)
          : range == 'bytes=-10'
          ? _audio.sublist(_audio.length - 10)
          : _audio.sublist(199999);
      expect(await bytes(response), expected);
    }
    final invalid = await get(uri, range: 'bytes=999999-');
    expect(invalid.statusCode, 416);
    expect(invalid.headers.value('content-range'), 'bytes */${_audio.length}');
    await invalid.drain<void>();
    expect(adapter.requests, hasLength(1));
  });

  test(
    'seek waits for the missing bytes without a second remote request',
    () async {
      adapter.gate = Completer<void>();
      final uri = await playback();
      final first = await get(uri, range: 'bytes=0-99');
      expect(await bytes(first), _audio.sublist(0, 100));
      final sought = get(uri, range: 'bytes=190000-190009').then(bytes);
      adapter.gate!.complete();
      expect(await sought, _audio.sublist(190000, 190010));
      expect(adapter.requests, hasLength(1));
    },
  );

  test('completed cache persists across service restarts', () async {
    final uri = await playback();
    expect(await bytes(await get(uri)), _audio);
    expect(
      await copy(),
      isTrue,
    ); // Wait for validation and the completion marker.
    await cache.dispose();
    cache = AudioCacheService(directory: () async => root, dio: dio);
    expect(await copy(), isTrue);
    expect(await bytes(await get(await playback())), _audio);
    expect(adapter.requests, hasLength(1));
  });

  test(
    'cancelling a download leaves the shared playback transfer alive',
    () async {
      adapter.gate = Completer<void>();
      final response = await get(await playback());
      final playing = bytes(response);
      final token = CancelToken();
      final downloading = copy(token: token);
      final assertion = expectLater(downloading, throwsA(isA<DioException>()));
      token.cancel('user cancelled');
      await assertion;
      adapter.gate!.complete();
      expect(await playing, _audio);
      expect(await copy(), isTrue);
      expect(adapter.requests, hasLength(1));
    },
  );

  test('cache miss keeps the existing resumable downloader', () async {
    expect(await copy(), isFalse);
    expect(adapter.requests, isEmpty);
    final controller = DownloadController(
      storage: StorageService(
        supportDirectory: Directory('${root.path}/support'),
      ),
      transferService: DownloadTransferService(dio),
      audioCache: cache,
      runTask: (_, _) async {},
      concurrency: () => 1,
      canStart: () => true,
    );
    controller.tasks = [task()];
    try {
      await controller.transfer(task(), CancelToken());
      expect(await File(task().savePath).readAsBytes(), _audio);
      expect(adapter.requests, hasLength(1));
      await controller.flush();
    } finally {
      controller.dispose();
    }
  });

  test(
    'invalid HTTP content is never copied and a refreshed link can retry',
    () async {
      adapter.html = true;
      final uri = await playback();
      final bad = await get(uri);
      expect(bad.statusCode, 502);
      await bad.drain<void>();
      expect(await copy(), isFalse);
      expect(await File(task().savePath).exists(), isFalse);
      adapter.html = false;
      final renewed = AudioCandidate(
        url: 'https://example.test/new.mp3',
        format: 'mp3',
        qualityLabel: 'MP3',
      );
      expect(
        await bytes(await get(await playback(candidate: renewed))),
        _audio,
      );
      expect(adapter.requests.last.uri.path, '/new.mp3');
      expect(await copy(), isTrue);
    },
  );

  test(
    'truncated persisted cache is discarded before download reuse',
    () async {
      expect(await bytes(await get(await playback())), _audio);
      expect(await copy(), isTrue);
      await cache.dispose();
      final key = AudioCacheService.trackKey(_track, _candidate);
      await File(
        '${root.path}/$key.audio',
      ).writeAsBytes(_audio.take(100).toList());
      cache = AudioCacheService(directory: () async => root, dio: dio);
      expect(await copy(), isFalse);
      expect(await bytes(await get(await playback())), _audio);
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'unknown content length still streams and supports suffix seeking',
    () async {
      adapter.unknownLength = true;
      final uri = await playback();
      expect(await bytes(await get(uri)), _audio);
      expect(await copy(), isTrue);
      expect(
        await bytes(await get(uri, range: 'bytes=-10')),
        _audio.sublist(_audio.length - 10),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test('expired persisted cache is discarded', () async {
    expect(await bytes(await get(await playback())), _audio);
    expect(await copy(), isTrue);
    await cache.dispose();
    final key = AudioCacheService.trackKey(_track, _candidate);
    await File(
      '${root.path}/$key.json',
    ).setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    cache = AudioCacheService(directory: () async => root, dio: dio);
    expect(await copy(), isFalse);
    expect(await bytes(await get(await playback())), _audio);
    expect(adapter.requests, hasLength(2));
  });

  test('cache key separates sources and renditions', () {
    final key = AudioCacheService.trackKey(_track, _candidate);
    expect(
      AudioCacheService.trackKey(_track.copyWith(source: 'other'), _candidate),
      isNot(key),
    );
    expect(
      AudioCacheService.trackKey(
        _track,
        const AudioCandidate(
          url: 'https://example.test/song.flac',
          format: 'flac',
        ),
      ),
      isNot(key),
    );
  });

  test(
    'quota protects current playback and evicts released cached audio',
    () async {
      await cache.dispose();
      cache = AudioCacheService(
        directory: () async => root,
        dio: dio,
        maxBytes: 1,
      );
      expect(await bytes(await get(await playback())), _audio);
      expect(await copy(), isTrue);
      final file = File(
        '${root.path}/${AudioCacheService.trackKey(_track, _candidate)}.audio',
      );
      expect(await file.exists(), isTrue);
      cache.releasePlayback();
      // Disposal waits for the asynchronous pruning pass.
      await cache.dispose();
      expect(await file.exists(), isFalse);
    },
  );

  test('loopback endpoint rejects unauthenticated paths', () async {
    final uri = await playback();
    final response = await get(
      uri.replace(path: '/wrong/${uri.pathSegments.last}'),
    );
    expect(response.statusCode, 404);
    await response.drain<void>();
    expect(adapter.requests, isEmpty);
  });
}

class _AudioAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  Completer<void>? gate;
  bool html = false;
  bool unknownLength = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final payload = html ? '<html>denied</html>'.codeUnits : _audio;
    final held = gate;
    Stream<Uint8List> body() async* {
      yield Uint8List.fromList(payload.take(1024).toList());
      if (held != null) await held.future;
      yield Uint8List.fromList(payload.skip(1024).toList());
    }

    return ResponseBody(
      body(),
      200,
      headers: {
        if (!unknownLength) 'content-length': ['${payload.length}'],
        'content-type': [html ? 'text/html' : 'audio/mpeg'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }
}
