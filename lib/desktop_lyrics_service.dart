import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';

typedef DesktopLyricsPositionChanged =
    void Function(double horizontalPosition, double verticalPosition);
typedef DesktopLyricsLockChanged = void Function(bool locked);

class DesktopLyricsService {
  static const MethodChannel _channel = MethodChannel(
    'qingting/desktop_lyrics',
  );
  static DesktopLyricsPositionChanged? _positionChangedHandler;
  static DesktopLyricsLockChanged? _lockChangedHandler;
  static bool _methodHandlerRegistered = false;

  static bool get isSupported => Platform.isAndroid || Platform.isWindows;

  static void setPositionChangedHandler(DesktopLyricsPositionChanged? handler) {
    _positionChangedHandler = handler;
    _ensureMethodHandler();
  }

  static void setLockChangedHandler(DesktopLyricsLockChanged? handler) {
    _lockChangedHandler = handler;
    _ensureMethodHandler();
  }

  static Future<bool> update({
    required bool enabled,
    required String text,
    required DesktopLyricsSettings settings,
  }) async {
    if (!isSupported) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('update', {
        'enabled': enabled,
        'text': text,
        'fontSize': settings.fontSize,
        'colorValue': settings.colorValue,
        'horizontalPosition': settings.horizontalPosition,
        'verticalPosition': settings.verticalPosition,
        'backgroundOpacity': settings.backgroundOpacity,
        'locked': settings.locked,
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

  static Future<bool> isOverlayPermissionGranted() async {
    if (!isSupported) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>(
        'isOverlayPermissionGranted',
      );
      return result ?? Platform.isWindows;
    } on MissingPluginException {
      return Platform.isWindows;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> openOverlayPermissionSettings() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('openOverlayPermissionSettings');
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

  static Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'lockChanged') {
      final arguments = call.arguments;
      if (arguments is! Map) {
        return;
      }
      final locked = arguments['locked'];
      if (locked is bool) {
        _lockChangedHandler?.call(locked);
      }
      return;
    }
    if (call.method != 'positionChanged') {
      return;
    }
    final arguments = call.arguments;
    if (arguments is! Map) {
      return;
    }
    final horizontalPosition = _doubleValue(arguments['horizontalPosition']);
    final verticalPosition = _doubleValue(arguments['verticalPosition']);
    if (horizontalPosition == null || verticalPosition == null) {
      return;
    }
    _positionChangedHandler?.call(
      horizontalPosition.clamp(0.0, 1.0).toDouble(),
      verticalPosition.clamp(0.0, 1.0).toDouble(),
    );
  }

  static double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}
