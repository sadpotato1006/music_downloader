import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';
import 'app_log.dart';
import 'audio_cache_service.dart';

class PlaybackHealth {
  const PlaybackHealth({this.itemKey, this.buffering = false, this.error});
  final (String, String)? itemKey;
  final bool buffering;
  final String? error;

  bool belongsTo(PlayerItem? item) =>
      item != null && itemKey == (item.id, item.uri);
}

abstract interface class PlaybackService {
  VoidCallback? get onChanged;
  set onChanged(VoidCallback? value);

  VoidCallback? get onCompleted;
  set onCompleted(VoidCallback? value);

  bool get isPlaying;
  PlaybackHealth get health;
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
  PlayerService({this.audioCache}) {
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
        if (health.itemKey == null ||
            health.error != null ||
            health.buffering == value) {
          return;
        }
        health = PlaybackHealth(itemKey: health.itemKey, buffering: value);
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
        if (health.itemKey == null || value.trim().isEmpty) return;
        health = PlaybackHealth(itemKey: health.itemKey, error: value);
        AppLog.instance.warning('playback', '播放中断', detail: value);
        _openedItemKey = null;
        onChanged?.call();
      }),
    ]);
  }

  final Player player = Player();
  final AudioCacheService? audioCache;
  late final Future<void> _linuxAudioConfiguration = _configureLinuxAudio();
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
  @override
  PlaybackHealth health = const PlaybackHealth();
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = Duration.zero;
  double volume = 100;

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
    _openedItemKey = null;
    await _linuxAudioConfiguration;
    if (generation != _openGeneration) return;
    health = PlaybackHealth(itemKey: (item.id, item.uri), buffering: true);
    onChanged?.call();
    try {
      var uri = item.uri;
      var headers = item.headers;
      final cacheKey = item.audioCacheKey;
      final cache = audioCache;
      if (cache != null && cacheKey != null && item.localPath == null) {
        try {
          uri = (await cache.playbackUri(
            cacheKey,
            AudioCandidate(
              url: item.uri,
              format: item.audioCacheFormat ?? '',
              headers: item.headers,
            ),
          )).toString();
          headers = const {};
        } catch (error) {
          cache.releasePlayback();
          AppLog.instance.warning('cache', '音频缓存不可用，直接在线播放', detail: error);
        }
      } else {
        cache?.releasePlayback();
      }
      if (generation != _openGeneration) return;
      await player.open(
        Media(
          uri,
          httpHeaders: headers,
          extras: {'title': item.title, 'artist': item.artist},
        ),
        play: true,
      );
    } catch (error) {
      if (generation == _openGeneration) {
        health = PlaybackHealth(itemKey: (item.id, item.uri), error: '$error');
        onChanged?.call();
      }
      rethrow;
    }
    if (generation == _openGeneration && health.error != null) {
      throw StateError(health.error!);
    }
    if (generation == _openGeneration) {
      _openedItemKey = itemKey;
      health = PlaybackHealth(
        itemKey: (item.id, item.uri),
        buffering: player.state.buffering,
      );
      onChanged?.call();
    }
  }

  Future<void> _configureLinuxAudio() async {
    if (!Platform.isLinux) return;
    final native = player.platform;
    if (native is! NativePlayer) return;
    try {
      // Prefer PulseAudio (also provided by pipewire-pulse) so the route
      // monitor can follow this process's stream. Keep mpv's fallback drivers
      // available for systems without a PulseAudio-compatible server.
      await native.setProperty('ao', 'pulse,');
      await native.setProperty('audio-client-name', '青听');
    } catch (error) {
      AppLog.instance.warning('linux', '无法设置音频输出，使用播放器默认配置', detail: error);
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
  Future<void> stop() async {
    audioCache?.releasePlayback();
    ++_openGeneration;
    _openedItemKey = null;
    health = const PlaybackHealth();
    onChanged?.call();
    await player.stop();
  }

  @override
  Future<void> dispose() async {
    audioCache?.releasePlayback();
    ++_openGeneration;
    _openedItemKey = null;
    health = const PlaybackHealth();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _positionListenable.dispose();
    await player.dispose();
  }
}
