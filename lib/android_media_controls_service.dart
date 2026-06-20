import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';

typedef AndroidMediaControlHandler =
    Future<void> Function(String action, Duration? position);

class AndroidMediaControlsService {
  static const MethodChannel _channel = MethodChannel(
    'qingting/media_controls',
  );
  static AndroidMediaControlHandler? _handler;
  static bool _methodHandlerRegistered = false;

  static bool get isSupported => Platform.isAndroid;

  static void setHandler(AndroidMediaControlHandler? handler) {
    _handler = handler;
    _ensureMethodHandler();
  }

  static Future<bool> update({
    required PlayerItem item,
    required bool isPlaying,
    required Duration position,
    required Duration duration,
    required bool canPlayPrevious,
    required bool canPlayNext,
  }) async {
    if (!isSupported) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('update', {
        'title': item.title,
        'artist': item.artist,
        'album': item.album,
        'durationMs': duration.inMilliseconds,
        'positionMs': position.inMilliseconds,
        'isPlaying': isPlaying,
        'canPlayPrevious': canPlayPrevious,
        'canPlayNext': canPlayNext,
        'coverFilePath': item.coverFilePath,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> hide() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static void _ensureMethodHandler() {
    if (_methodHandlerRegistered) {
      return;
    }
    _methodHandlerRegistered = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static Future<bool> _handleMethodCall(MethodCall call) async {
    final handler = _handler;
    if (handler == null) {
      return false;
    }
    switch (call.method) {
      case 'play':
      case 'pause':
      case 'toggle':
      case 'previous':
      case 'next':
        await handler(call.method, null);
        return true;
      case 'seek':
        final arguments = call.arguments;
        if (arguments is! Map) {
          return false;
        }
        final positionMs = arguments['positionMs'];
        if (positionMs is! num) {
          return false;
        }
        await handler(call.method, Duration(milliseconds: positionMs.toInt()));
        return true;
      default:
        return false;
    }
  }
}
