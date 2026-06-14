import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';

class PlayerService {
  PlayerService() {
    _subscriptions.addAll([
      player.stream.playing.listen((value) {
        isPlaying = value;
        onChanged?.call();
      }),
      player.stream.position.listen((value) {
        position = value;
        onChanged?.call();
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
        onChanged?.call();
      }),
    ]);
  }

  final Player player = Player();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  VoidCallback? onChanged;
  VoidCallback? onCompleted;

  bool isPlaying = false;
  bool isBuffering = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double volume = 100;
  String? errorMessage;

  Future<void> open(PlayerItem item) async {
    errorMessage = null;
    await player.open(
      Media(
        item.uri,
        httpHeaders: item.headers,
        extras: {'title': item.title, 'artist': item.artist},
      ),
      play: true,
    );
  }

  Future<void> playOrPause() => player.playOrPause();

  Future<void> pause() => player.pause();

  Future<void> seek(Duration value) => player.seek(value);

  Future<void> setVolume(double value) => player.setVolume(value);

  Future<void> stop() => player.stop();

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }
}
