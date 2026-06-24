import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';

abstract interface class PlaybackService {
  VoidCallback? get onChanged;
  set onChanged(VoidCallback? value);

  VoidCallback? get onCompleted;
  set onCompleted(VoidCallback? value);

  bool get isPlaying;
  Duration get position;
  Duration get duration;
  ValueListenable<Duration> get positionListenable;

  bool isOpened(PlayerItem item);
  Future<void> open(PlayerItem item);
  Future<void> play();
  Future<void> playOrPause();
  Future<void> pause();
  Future<void> seek(Duration value);
  Future<void> setVolume(double value);
  Future<void> stop();
  Future<void> dispose();
}

class PlayerService implements PlaybackService {
  PlayerService() {
    _subscriptions.addAll([
      player.stream.playing.listen((value) {
        isPlaying = value;
        onChanged?.call();
      }),
      player.stream.position.listen((value) {
        position = value;
        _positionListenable.value = value;
      }),
      player.stream.duration.listen((value) {
        duration = value;
        onChanged?.call();
      }),
      player.stream.buffering.listen((value) {
        isBuffering = value;
        onChanged?.call();
      }),
      player.stream.volume.listen((value) {
        volume = value;
        onChanged?.call();
      }),
      player.stream.completed.listen((value) {
        if (value) {
          onCompleted?.call();
        }
      }),
      player.stream.error.listen((value) {
        errorMessage = value;
        _openedItemKey = null;
        onChanged?.call();
      }),
    ]);
  }

  final Player player = Player();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final ValueNotifier<Duration> _positionListenable = ValueNotifier(
    Duration.zero,
  );
  String? _openedItemKey;
  String? _openingItemKey;
  Future<void>? _openingOperation;
  int _openGeneration = 0;

  @override
  VoidCallback? onChanged;
  @override
  VoidCallback? onCompleted;

  @override
  bool isPlaying = false;
  bool isBuffering = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = Duration.zero;
  double volume = 100;
  String? errorMessage;

  @override
  ValueListenable<Duration> get positionListenable => _positionListenable;

  @override
  bool isOpened(PlayerItem item) => _openedItemKey == _itemKey(item);

  @override
  Future<void> open(PlayerItem item) async {
    final itemKey = _itemKey(item);
    final openingOperation = _openingOperation;
    if (_openingItemKey == itemKey && openingOperation != null) {
      await openingOperation;
      return;
    }

    final generation = ++_openGeneration;
    final operation = _open(item, itemKey, generation);
    _openingItemKey = itemKey;
    _openingOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_openingOperation, operation)) {
        _openingItemKey = null;
        _openingOperation = null;
      }
    }
  }

  Future<void> _open(PlayerItem item, String itemKey, int generation) async {
    errorMessage = null;
    _openedItemKey = null;
    await player.open(
      Media(
        item.uri,
        httpHeaders: item.headers,
        extras: {'title': item.title, 'artist': item.artist},
      ),
      play: true,
    );
    if (generation == _openGeneration) {
      _openedItemKey = itemKey;
    }
  }

  String _itemKey(PlayerItem item) => '${item.id}\u0000${item.uri}';
  @override
  Future<void> play() => player.play();

  @override
  Future<void> playOrPause() => player.playOrPause();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration value) => player.seek(value);

  @override
  Future<void> setVolume(double value) => player.setVolume(value);

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _positionListenable.dispose();
    await player.dispose();
  }
}
