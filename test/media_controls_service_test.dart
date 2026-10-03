import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/android_media_controls_service.dart';
import 'package:qingting/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('qingting/media_controls');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<Object?> nativeCall(String method, [Object? args]) async {
    final result = Completer<Object?>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, args)),
      (data) {
        result.complete(data == null ? null : codec.decodeEnvelope(data));
      },
    );
    return result.future;
  }

  tearDown(() {
    AndroidMediaControlsService.setHandler(null);
    AndroidMediaControlsService.setPropertyHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('system controls dispatch stop and absolute seek', () async {
    final events = <(String, Duration?)>[];
    AndroidMediaControlsService.setHandler(
      (action, position) async => events.add((action, position)),
    );
    expect(await nativeCall('stop'), isTrue);
    expect(await nativeCall('seek', {'positionMs': 12345}), isTrue);
    expect(events, [
      ('stop', null),
      ('seek', const Duration(milliseconds: 12345)),
    ]);
    expect(await nativeCall('seek', {'positionMs': 'bad'}), isFalse);
    expect(events.length, 2);
  });

  test('MPRIS property types and loop values are validated', () async {
    final properties = <(String, Object)>[];
    AndroidMediaControlsService.setPropertyHandler(
      (name, value) async => properties.add((name, value)),
    );
    for (final entry in [
      ('Volume', 0.4),
      ('Shuffle', true),
      ('LoopStatus', 'Track'),
    ]) {
      expect(
        await nativeCall('setProperty', {
          'property': entry.$1,
          'value': entry.$2,
        }),
        isTrue,
      );
    }
    expect(properties.length, 3);
    for (final entry in [
      ('Volume', double.nan),
      ('Volume', '0.4'),
      ('Shuffle', 1),
      ('LoopStatus', 'Invalid'),
      ('Other', true),
    ]) {
      expect(
        await nativeCall('setProperty', {
          'property': entry.$1,
          'value': entry.$2,
        }),
        isFalse,
      );
    }
    expect(properties.length, 3);
    AndroidMediaControlsService.setPropertyHandler(null);
    expect(
      await nativeCall('setProperty', {'property': 'Volume', 'value': 1}),
      isFalse,
    );
  });

  test(
    'Linux metadata identifies the track and publishes player state',
    () async {
      MethodCall? sent;
      messenger.setMockMethodCallHandler(channel, (call) async {
        sent = call;
        return true;
      });
      final item = PlayerItem(
        id: 'id',
        title: '歌名',
        artist: '歌手',
        album: '专辑',
        uri: '/tmp/song.mp3',
      );
      expect(
        await AndroidMediaControlsService.update(
          item: item,
          isPlaying: true,
          position: const Duration(seconds: 12),
          duration: const Duration(minutes: 3),
          canPlayPrevious: true,
          canPlayNext: true,
          volume: 40,
          shuffle: true,
          loopStatus: 'Track',
        ),
        isTrue,
      );
      final args = sent!.arguments as Map;
      expect(args['trackId'], 'id|/tmp/song.mp3');
      expect(args['volume'], 0.4);
      expect(args['positionMs'], 12000);
      expect(args['durationMs'], 180000);
      expect(args['shuffle'], isTrue);
      expect(args['isOpened'], isTrue);
      expect(args['loopStatus'], 'Track');
    },
    skip: !(Platform.isLinux || Platform.isAndroid),
  );
}
