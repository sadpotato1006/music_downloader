import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/download_transfer_service.dart';
import 'package:qingting/models.dart';

const _audio = [0, 0, 0, 16, 102, 116, 121, 112, 77, 52, 65, 32, 0, 0, 0, 0];
const _track = TrackSearchResult(
  id: 'test',
  title: 'Song',
  artist: 'Artist',
  source: 'test',
  detailUrl: 'https://example.test/song',
);

void main() {
  late Directory root;
  late File file;
  late _Responses adapter;
  late Dio dio;
  late DownloadTransferService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('qingting-transfer-test-');
    file = File('${root.path}/song.m4a');
    adapter = _Responses();
    dio = Dio()..httpClientAdapter = adapter;
    service = DownloadTransferService(dio);
  });
  tearDown(() async {
    dio.close(force: true);
    await root.delete(recursive: true);
  });

  Future<void> download({String? validator, CancelToken? token}) =>
      service.download(
        DownloadTask(
          id: 'test',
          track: _track,
          candidate: const AudioCandidate(
            url: 'https://example.test/song.m4a',
            format: 'm4a',
          ),
          status: DownloadStatus.downloading,
          progress: 0,
          savePath: file.path,
          resumeValidator: validator,
        ),
        token ?? CancelToken(),
        onProgress: (_, _) {},
        onResponse: (_, _, _) {},
      );

  for (final type in [
    'text/html; charset=utf-8',
    'application/json',
    'application/xhtml+xml',
    'image/png',
  ]) {
    test('rejects HTTP 200 $type without overwriting a partial file', () async {
      await file.writeAsBytes(_audio.take(8).toList());
      adapter.responses.add(
        _Response(200, '<html>Access denied</html>'.codeUnits, {
          'content-type': [type],
        }),
      );
      await expectLater(download(), throwsA(isA<InvalidAudioResponse>()));
      expect(await file.readAsBytes(), _audio.take(8).toList());
    });
  }
  for (final payload in [
    <int>[],
    '<html>login</html>'.codeUnits,
    '{"error":"expired"}'.codeUnits,
    [1, 2, 3],
  ]) {
    test(
      'rejects unrecognized audio even with an audio content type (${payload.length})',
      () async {
        adapter.responses.add(
          _Response(200, payload, {
            'content-type': ['audio/mp4'],
          }),
        );
        await expectLater(download(), throwsA(isA<InvalidAudioResponse>()));
        expect(await file.exists(), isFalse);
      },
    );
  }
  for (final payload in [
    _audio,
    [0xff, 0xfb, 0, 0],
    'ID3\x04\x00\x00'.codeUnits,
    'fLaCtest'.codeUnits,
    'OggStest'.codeUnits,
    'RIFF0000WAVEtest'.codeUnits,
    [0xff, 0xf1, 0x50, 0x80],
  ]) {
    test('accepts recognizable audio (${payload.take(4).join(',')})', () async {
      adapter.responses.add(_Response(200, payload));
      await download();
      expect(await file.readAsBytes(), payload);
    });
  }
  test('resumes a matching file using Range and If-Range', () async {
    await file.writeAsBytes(_audio.take(8).toList());
    adapter.responses.add(
      _Response(206, _audio.skip(8).toList(), {
        'content-range': ['bytes 8-15/16'],
        'etag': ['"same"'],
      }),
    );
    await download(validator: '"same"');
    expect(adapter.requests.single.headers['range'], 'bytes=8-');
    expect(adapter.requests.single.headers['if-range'], '"same"');
    expect(await file.readAsBytes(), _audio);
  });
  for (final returnedValidator in ['"new"', '']) {
    test(
      '416 cannot accept same-length content with validator $returnedValidator',
      () async {
        await file.writeAsBytes(_audio);
        final replacement = [..._audio.take(12), 1, 2, 3, 4];
        adapter.responses.addAll([
          _Response(416, [], {
            'content-range': ['bytes */16'],
            if (returnedValidator.isNotEmpty) 'etag': [returnedValidator],
          }),
          _Response(200, replacement, {
            'etag': ['"new"'],
          }),
        ]);
        await download(validator: '"old"');
        expect(adapter.requests, hasLength(2));
        expect(adapter.requests.last.headers['range'], isNull);
        expect(await file.readAsBytes(), replacement);
      },
    );
  }
  test(
    '416 accepts a valid complete file with the same strong validator',
    () async {
      await file.writeAsBytes(_audio);
      adapter.responses.add(
        _Response(416, [], {
          'content-range': ['bytes */16'],
          'etag': ['"same"'],
        }),
      );
      await download(validator: '"same"');
      expect(adapter.requests, hasLength(1));
      expect(await file.readAsBytes(), _audio);
    },
  );
  test('weak validator cannot prove completeness for 416', () async {
    await file.writeAsBytes(_audio);
    adapter.responses.addAll([
      _Response(416, [], {
        'content-range': ['bytes */16'],
        'etag': ['W/"same"'],
      }),
      _Response(200, _audio),
    ]);
    await download(validator: 'W/"same"');
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.first.headers['if-range'], isNull);
  });
  for (final range in ['bytes 9-15/16', 'bytes 8-16/16', 'nonsense']) {
    test(
      'invalid 206 range $range falls back once without appending',
      () async {
        await file.writeAsBytes(_audio.take(8).toList());
        adapter.responses.addAll([
          _Response(206, _audio.skip(8).toList(), {
            'content-range': [range],
          }),
          _Response(200, _audio),
        ]);
        await download();
        expect(adapter.requests, hasLength(2));
        expect(await file.readAsBytes(), _audio);
      },
    );
  }
  test('partial response from a different version is replaced', () async {
    await file.writeAsBytes(_audio.take(8).toList());
    adapter.responses.addAll([
      _Response(206, _audio.skip(8).toList(), {
        'content-range': ['bytes 8-15/16'],
        'etag': ['"new"'],
      }),
      _Response(200, _audio),
    ]);
    await download(validator: '"old"');
    expect(adapter.requests, hasLength(2));
    expect(await file.readAsBytes(), _audio);
  });
  test('short response remains incomplete', () async {
    adapter.responses.add(
      _Response(200, _audio.take(8).toList(), {
        'content-length': ['16'],
      }),
    );
    await expectLater(download(), throwsA(isA<FileSystemException>()));
  });
  test('a canceled token never accepts a complete file', () async {
    final token = CancelToken()..cancel('test');
    await expectLater(download(token: token), throwsA(isA<DioException>()));
  });
}

class _Response {
  _Response(this.status, this.bytes, [this.headers = const {}]);
  final int status;
  final List<int> bytes;
  final Map<String, List<String>> headers;
}

class _Responses implements HttpClientAdapter {
  final responses = <_Response>[];
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final response = responses.removeAt(0);
    return ResponseBody.fromBytes(
      response.bytes,
      response.status,
      headers: {
        'content-type': ['application/octet-stream'],
        'content-length': ['${response.bytes.length}'],
        ...response.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
