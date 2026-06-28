import 'dart:io';

import 'package:flutter/services.dart';

typedef BluetoothAudioRouteChangedHandler = Future<void> Function();

class AudioRouteService {
  static const MethodChannel _channel = MethodChannel('qingting/audio_route');
  static BluetoothAudioRouteChangedHandler? _handler;
  static bool _methodHandlerRegistered = false;

  static bool get isSupported => Platform.isAndroid || Platform.isWindows;

  static void setBluetoothRouteChangedHandler(
    BluetoothAudioRouteChangedHandler? handler,
  ) {
    _handler = handler;
    _ensureMethodHandler();
  }

  static void _ensureMethodHandler() {
    if (_methodHandlerRegistered) {
      return;
    }
    _methodHandlerRegistered = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static Future<bool> _handleMethodCall(MethodCall call) async {
    if (call.method != 'bluetoothDisconnectedOrSwitched') {
      return false;
    }
    final handler = _handler;
    if (handler == null) {
      return false;
    }
    await handler();
    return true;
  }
}
