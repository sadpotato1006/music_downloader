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

  test(
    'reveals the parent directory and preserves special characters',
    () async {
      final path = '${Directory.systemTemp.path}/青听 space # &/song.mp3';
      expect(await LinuxDesktopService.revealFile(path), isTrue);
      final uri = Uri.parse((calls.single.arguments as Map)['uri'] as String);
      expect(uri, File(path).absolute.parent.uri);
      expect(uri.path, isNot(endsWith('song.mp3')));
    },
  );

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
