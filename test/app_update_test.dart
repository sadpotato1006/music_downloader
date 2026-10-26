import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/app_info.dart';
import 'package:qingting/app_update_service.dart';
import 'package:qingting/models.dart';
import 'package:qingting/windows_update_bridge.dart';
import 'package:qingting/windows_update_controller.dart';

const _base =
    'https://github.com/sadpotato1006/music_downloader/releases/download/v1.7.0/';
const _name = 'QingTingSetup-v1_7_0.exe';
final _bytes = utf8.encode('test installer');
final _hash = sha256.convert(_bytes).toString();
AppUpdateRelease _release() => AppUpdateRelease(
  version: UpdateVersion.parse('1.7.0+35'),
  notes: 'Release notes',
  assetName: _name,
  url: Uri.parse('$_base$_name'),
  size: _bytes.length,
  sha256Hex: _hash,
);
Map<String, dynamic> _asset(String name) => {
  'name': name,
  'browser_download_url': '$_base$name',
  'size': _bytes.length,
  if (name == _name) 'digest': 'sha256:$_hash',
};
Map<String, dynamic> _manifest() => {
  'schemaVersion': 1,
  'version': '1.7.0+35',
  'windows-x64': {'installer': _name, 'size': _bytes.length, 'sha256': _hash},
};
Map<String, dynamic> _latest() => {
  'tag_name': 'v1.7.0',
  'draft': false,
  'prerelease': false,
  'body': 'Release notes',
  'assets': [_asset('qingting-update.json'), _asset(_name)],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'numeric versions compare release and build, reject preview versions',
    () {
      expect(
        UpdateVersion.parse(
          '1.10.0',
        ).compareTo(UpdateVersion.parse('1.9.9+90')),
        greaterThan(0),
      );
      expect(
        UpdateVersion.parse(
          'v1.6.1+35',
        ).compareTo(UpdateVersion.parse('1.6.1+34')),
        greaterThan(0),
      );
      expect(() => UpdateVersion.parse('1.7.0-beta'), throwsFormatException);
      final source = File('pubspec.yaml').readAsStringSync();
      expect(
        RegExp(
          r'^version:\s*(\S+)',
          multiLine: true,
        ).firstMatch(source)!.group(1),
        appVersion,
      );
    },
  );
  test('automatic check preference defaults on and round trips off', () {
    expect(
      AppSettings.fromJson({
        'downloadDirectory': 'music',
      }).checkUpdatesOnStartup,
      isTrue,
    );
    final settings = AppSettings(
      downloadDirectory: 'music',
    ).copyWith(checkUpdatesOnStartup: false);
    expect(
      AppSettings.fromJson(settings.toJson()).checkUpdatesOnStartup,
      isFalse,
    );
  });

  group('GitHub release verification', () {
    late Map<String, dynamic> latest, manifest;
    late _Adapter adapter;
    late GitHubUpdateSource source;
    setUp(() {
      latest = _latest();
      manifest = _manifest();
      adapter = _Adapter(
        (options) => ResponseBody.fromString(
          jsonEncode(options.uri.host == 'api.github.com' ? latest : manifest),
          200,
        ),
      );
      source = GitHubUpdateSource(dio: Dio()..httpClientAdapter = adapter);
      addTearDown(source.close);
    });
    Future<AppUpdateRelease?> check() =>
        source.check(UpdateVersion.parse('1.6.1+34'), CancelToken());
    test('accepts matching version, repository, size and SHA256', () async {
      final release = (await check())!;
      expect(release.version.toString(), '1.7.0+35');
      expect(release.sha256Hex, _hash);
      expect(adapter.calls, hasLength(2));
    });
    test('older release does not need a manifest', () async {
      latest['tag_name'] = 'v1.5.0';
      latest['assets'] = [];
      expect(await check(), isNull);
      expect(adapter.calls, hasLength(1));
    });
    test('new release missing manifest offers manual download', () async {
      latest['assets'] = [];
      await expectLater(check(), throwsFormatException);
    });
    test('ignores draft and preview releases', () async {
      latest['prerelease'] = true;
      expect(await check(), isNull);
      latest['prerelease'] = false;
      latest['draft'] = true;
      expect(await check(), isNull);
    });
    for (final invalid in [
      'version',
      'size',
      'digest',
      'repository',
      'schema',
    ]) {
      test('rejects mismatched $invalid', () async {
        switch (invalid) {
          case 'version':
            manifest['version'] = '1.8.0+35';
          case 'size':
            (manifest['windows-x64'] as Map)['size'] = 12;
          case 'digest':
            (latest['assets'] as List).last['digest'] = 'sha256:bad';
          case 'repository':
            (latest['assets'] as List).last['browser_download_url'] =
                'https://github.com/other/repo/releases/download/v1.7.0/$_name';
          case 'schema':
            manifest['schemaVersion'] = 2;
        }
        await expectLater(check(), throwsFormatException);
      });
    }
    test(
      'rejects redirect to an untrusted host before contacting it',
      () async {
        adapter.handler = (_) => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['https://example.com/installer'],
          },
        );
        await expectLater(check(), throwsFormatException);
        expect(adapter.calls, hasLength(1));
      },
    );
    test('bounds release JSON', () async {
      adapter.handler = (_) =>
          ResponseBody.fromString(' ' * (1024 * 1024 + 1), 200);
      await expectLater(check(), throwsFormatException);
    });
  });

  group('download validation', () {
    late Directory cache;
    late _Adapter adapter;
    late GitHubUpdateSource source;
    setUp(() async {
      cache = await Directory.systemTemp.createTemp('qingting-update-test-');
      adapter = _Adapter((_) => ResponseBody.fromBytes(_bytes, 200));
      source = GitHubUpdateSource(
        dio: Dio()..httpClientAdapter = adapter,
        cacheDirectory: () async => cache,
      );
      addTearDown(() async {
        source.close();
        await cache.delete(recursive: true);
      });
    });
    test('returns only fully verified installer', () async {
      var received = 0;
      final file = await source.download(_release(), CancelToken(), (
        done,
        total,
      ) {
        received = done;
      });
      expect(await file.readAsBytes(), _bytes);
      expect(received, _bytes.length);
      expect(file.path, endsWith(_name));
    });
    for (final bytes in [
      <int>[1],
      List.filled(_bytes.length, 1),
      List.filled(_bytes.length + 1, 1),
    ]) {
      test(
        'removes truncated, corrupted or oversized download (${bytes.length})',
        () async {
          adapter.handler = (_) => ResponseBody.fromBytes(bytes, 200);
          await expectLater(
            source.download(_release(), CancelToken(), (_, _) {}),
            throwsFormatException,
          );
          expect(await cache.list().toList(), isEmpty);
        },
      );
    }
    test('cancelling during progress cleans the partial download', () async {
      final cancel = CancelToken();
      await expectLater(
        source.download(_release(), cancel, (_, _) => cancel.cancel()),
        throwsA(isA<DioException>()),
      );
      expect(await cache.list().toList(), isEmpty);
    });
  });

  group('user controlled update lifecycle', () {
    late _Source source;
    late _Installer installer;
    late WindowsUpdateController controller;
    setUp(() {
      source = _Source();
      installer = _Installer();
      controller = WindowsUpdateController(
        source: source,
        installer: installer,
        currentVersion: '1.6.1+34',
      );
      addTearDown(controller.dispose);
    });
    test('opt-out skips startup check but permits manual check', () async {
      controller.automaticCheckEnabled = false;
      await controller.check(automatic: true);
      expect(source.checks, 0);
      await controller.check();
      expect(controller.status, AppUpdateStatus.available);
      expect(source.downloads, 0);
      expect(installer.prepares, 0);
    });
    test(
      'checks, downloads, and commits only at separate explicit steps',
      () async {
        await controller.check(automatic: true);
        expect(controller.noticeVisible, isTrue);
        await controller.download();
        expect(controller.status, AppUpdateStatus.ready);
        expect(installer.prepares, 0);
        final events = installer.events;
        await controller.install(
          prepareToExit: () async {
            events.add('save');
          },
          restoreAfterFailure: () {
            events.add('restore');
          },
        );
        expect(events, ['prepare', 'save', 'commit']);
      },
    );
    test(
      'failed save aborts helper and keeps old app available for retry',
      () async {
        await controller.check();
        await controller.download();
        await controller.install(
          prepareToExit: () async {
            throw const FormatException('disk full');
          },
          restoreAfterFailure: () {
            installer.events.add('restore');
          },
        );
        expect(installer.events, ['prepare', 'abort', 'restore']);
        expect(controller.status, AppUpdateStatus.ready);
        expect(controller.error, 'disk full');
      },
    );
    test(
      'download cancellation is retryable even when transport finishes at the same time',
      () async {
        await controller.check();
        source.pendingDownload = Completer<File>();
        final operation = controller.download();
        controller.cancelDownload();
        source.pendingDownload!.complete(File('unused.exe'));
        await operation;
        expect(controller.status, AppUpdateStatus.available);
        expect(controller.error, isNull);
        source.pendingDownload = null;
        await controller.download();
        expect(controller.status, AppUpdateStatus.ready);
      },
    );
    test(
      'concurrent checks are coalesced and failures do not show startup notice',
      () async {
        source.pendingCheck = Completer<AppUpdateRelease?>();
        final operation = controller.check(automatic: true);
        await controller.check();
        expect(source.checks, 1);
        source.pendingCheck!.completeError(const FormatException('offline'));
        await operation;
        expect(controller.noticeVisible, isFalse);
        expect(controller.busy, isFalse);
        expect(controller.error, 'offline');
      },
    );
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  ResponseBody Function(RequestOptions) handler;
  final calls = <Uri>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options.uri);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

class _Source extends AppUpdateSource {
  int checks = 0, downloads = 0;
  Completer<File>? pendingDownload;
  Completer<AppUpdateRelease?>? pendingCheck;
  @override
  Future<AppUpdateRelease?> check(
    UpdateVersion current,
    CancelToken cancel,
  ) async {
    checks++;
    return pendingCheck == null ? _release() : pendingCheck!.future;
  }

  @override
  Future<File> download(
    AppUpdateRelease release,
    CancelToken cancel,
    void Function(int, int) progress,
  ) async {
    downloads++;
    return pendingDownload == null
        ? File('unused.exe')
        : pendingDownload!.future;
  }
}

class _Installer implements UpdateInstaller {
  int prepares = 0;
  final events = <String>[];
  @override
  Future<UpdateInstallSession> prepare(
    File file,
    AppUpdateRelease release,
  ) async {
    prepares++;
    events.add('prepare');
    return _Session(events);
  }
}

class _Session implements UpdateInstallSession {
  _Session(this.events);
  final List<String> events;
  @override
  Future<void> commitAndExit() async {
    events.add('commit');
  }

  @override
  Future<void> abort() async {
    events.add('abort');
  }
}
