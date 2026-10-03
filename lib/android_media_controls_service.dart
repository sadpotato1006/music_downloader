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
  static Future<void> Function(String property, Object value)? _propertyHandler;
  static bool _methodHandlerRegistered = false;

  static bool get isSupported => Platform.isAndroid || Platform.isLinux;

  static void setPropertyHandler(
    Future<void> Function(String property, Object value)? handler,
  ) {
    _propertyHandler = handler;
    _ensureMethodHandler();
  }

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
    double volume = 100,
    bool shuffle = false,
    String loopStatus = 'None',
    bool isOpened = true,
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
        'trackId': '${item.id}|${item.uri}',
        'volume': volume / 100,
        'shuffle': shuffle,
        'loopStatus': loopStatus,
        'isOpened': isOpened,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> updateState({
    required double volume,
    required bool shuffle,
    required String loopStatus,
  }) async {
    if (!Platform.isLinux) return;
    try {
      await _channel.invokeMethod<void>('state', {
        'volume': volume / 100,
        'shuffle': shuffle,
        'loopStatus': loopStatus,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
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
    if (call.method == 'setProperty') {
      final args = call.arguments;
      if (args is! Map || _propertyHandler == null) return false;
      final property = args['property'];
      final value = args['value'];
      final valid =
          (property == 'Volume' && value is num && value.isFinite) ||
          (property == 'Shuffle' && value is bool) ||
          (property == 'LoopStatus' &&
              const ['None', 'Track', 'Playlist'].contains(value));
      if (!valid || value == null) return false;
      await _propertyHandler!(property as String, value);
      return true;
    }
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
      case 'stop':
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
