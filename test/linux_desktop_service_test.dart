import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/linux_desktop_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qingting/linux_desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reveals the selected file and preserves special characters', () async {
    final path = '${Directory.systemTemp.path}/青听 space # &/song.mp3';
    expect(await LinuxDesktopService.revealFile(path), isTrue);
    final uri = Uri.parse((calls.single.arguments as Map)['uri'] as String);
    expect(calls.single.method, 'revealFile');
    expect(uri, File(path).absolute.uri);
  });

  test('opening a file preserves its full path', () async {
    final path = '${Directory.systemTemp.path}/青听 space # &/song.mp3';
    expect(await LinuxDesktopService.openFile(path), isTrue);
    final uri = Uri.parse((calls.single.arguments as Map)['uri'] as String);
    expect(uri, File(path).absolute.uri);
  });

  test('external URLs reject local files and non-web schemes', () async {
    for (final url in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      '/relative',
      'https:',
    ]) {
      expect(await LinuxDesktopService.openUrl(url), isFalse);
    }
    expect(calls, isEmpty);
    expect(
      await LinuxDesktopService.openUrl('https://example.com/?q=a%20b'),
      isTrue,
    );
  });

  test('a cancelled folder picker leaves the directory unchanged', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await LinuxDesktopService.pickDirectory('/tmp/music'), isNull);
  });

  test('file manager failure falls back to opening the parent', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'revealFile') throw PlatformException(code: 'no_bus');
      return true;
    });
    final path = '${Directory.systemTemp.path}/青听/song.mp3';
    expect(await LinuxDesktopService.revealFile(path), isTrue);
    expect(calls.map((call) => call.method), ['revealFile', 'openUri']);
    expect(
      Uri.parse((calls.last.arguments as Map)['uri']),
      File(path).absolute.parent.uri,
    );
  });

  test(
    'login returns only an exact OAuth callback; cancellation is null',
    () async {
      final callback = Uri.parse('https://127.0.0.1:9010/callback');
      final url = Uri.parse(
        'https://yunpan.ustb.edu.cn/oauth2/auth?state=test',
      );
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => '$callback?code=test&state=test',
      );
      expect(
        (await LinuxDesktopService.login(
          url,
          callback,
        ))!.queryParameters['code'],
        'test',
      );
      for (final invalid in [
        'https://127.0.0.1:9010/callback/other?code=test',
        'https://127.0.0.1:9010/callback.evil?code=test',
        'http://127.0.0.1:9010/callback?code=test',
        'https://127.0.0.1:9020/callback?code=test',
        'https://127.0.0.1.evil:9010/callback?code=test',
        'https://user@127.0.0.1:9010/callback?code=test',
        'https://127.0.0.1:9010/callback#code=test',
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async => invalid);
        await expectLater(
          LinuxDesktopService.login(url, callback),
          throwsFormatException,
        );
      }
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await LinuxDesktopService.login(url, callback), isNull);
    },
  );

  test('login load failures reach the UI for retry', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'login_failed', message: '加载失败');
    });
    await expectLater(
      LinuxDesktopService.login(
        Uri.parse('https://yunpan.ustb.edu.cn/oauth2/auth'),
        Uri.parse('https://127.0.0.1:9010/callback'),
      ),
      throwsA(isA<PlatformException>()),
    );
    await LinuxDesktopService.cancelLogin();
  });

  test(
    'picker returns the selected Unicode path without trimming it',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async => '/tmp/ 音乐 ');
      expect(await LinuxDesktopService.pickDirectory('/tmp'), '/tmp/ 音乐 ');
    },
  );

  test(
    'missing desktop applications and native failures are handled',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'open_failed', message: 'No application');
      });
      expect(await LinuxDesktopService.openUrl('https://example.com'), isFalse);
      expect(await LinuxDesktopService.pickDirectory('/tmp'), isNull);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await LinuxDesktopService.openUrl('https://example.com'), isFalse);
    },
  );
}
