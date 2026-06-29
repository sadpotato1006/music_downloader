part of '../app_controller.dart';

extension AppControllerPlaybackActions on AppController {
  Future<void> playDownloadedCollection(
    Iterable<DownloadedTrack> tracks, {
    bool shuffle = false,
  }) async {
    final ordered = List<DownloadedTrack>.from(tracks);
    if (ordered.isEmpty) {
      globalMessage = '当前列表中没有歌曲';
      _notify();
      return;
    }
    if (shuffle) {
      ordered.shuffle(_shuffleRandom);
    }
    final items = <PlayerItem>[];
    for (final track in ordered) {
      final item = await _playerItemFromDownloadedTrack(
        track,
        includeLyrics: false,
        showMissingMessage: false,
      );
      if (item != null) {
        items.add(item);
      }
    }
    if (items.isEmpty) {
      globalMessage = '没有可播放的歌曲，请检查本地文件是否存在';
      _notify();
      return;
    }
    queue = items;
    currentQueueIndex = 0;
    shuffleEnabled = shuffle;
    await playQueueAt(0);
  }

  Future<void> playQueueAt(int index) async {
    if (index < 0 || index >= queue.length) {
      return;
    }
    final item = await _hydrateQueueItemForPlayback(queue[index]);
    if (item.id != queue[index].id ||
        item.lyrics != queue[index].lyrics ||
        item.album != queue[index].album ||
        item.coverFilePath != queue[index].coverFilePath) {
      queue[index] = item;
    }
    currentQueueIndex = index;
    await _saveQueueState();
    _notify();
    unawaited(_syncAndroidMediaControls(force: true));
    await player.open(item);
    await _recordRecentPlayback(item);
  }

  Future<void> playNext() async {
    if (queue.isEmpty) {
      return;
    }
    if (currentQueueIndex < queue.length - 1) {
      await playQueueAt(currentQueueIndex + 1);
    } else if (repeatMode == RepeatMode.all) {
      await playQueueAt(0);
    }
  }

  Future<void> playPrevious() async {
    if (queue.isEmpty) {
      return;
    }
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
      return;
    }
    if (currentQueueIndex > 0) {
      await playQueueAt(currentQueueIndex - 1);
    } else if (repeatMode == RepeatMode.all) {
      await playQueueAt(queue.length - 1);
    }
  }

  Future<void> togglePlayPause() async {
    final item = currentItem;
    if (item == null) {
      return;
    }
    if (!player.isOpened(item)) {
      await _openCurrentItemForPlayback();
      return;
    }
    await player.playOrPause();
  }

  Future<void> _playCurrentItem() async {
    final item = currentItem;
    if (item == null) {
      return;
    }
    if (!player.isOpened(item)) {
      await _openCurrentItemForPlayback();
      return;
    }
    await player.play();
  }

  Future<bool> _openCurrentItemForPlayback() async {
    final index = currentQueueIndex;
    if (index < 0 || index >= queue.length) {
      return false;
    }
    try {
      await playQueueAt(index);
      return true;
    } catch (error) {
      globalMessage = '播放失败：${_friendlyUnexpectedError(error)}';
      _notify();
      return false;
    }
  }

  Future<void> seekTo(Duration value) => player.seek(value);

  Future<void> setVolume(double value) async {
    final normalized = value.clamp(0, 100).toDouble();
    await player.setVolume(normalized);
    if (settings == null) {
      return;
    }
    settings = settings!.copyWith(volume: normalized);
    _debouncedSaveSettings();
    _notify();
  }

  void cycleRepeatMode() {
    repeatMode = switch (repeatMode) {
      RepeatMode.none => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.none,
    };
    unawaited(_syncAndroidMediaControls(force: true));
    _notify();
  }

  void toggleShuffleMode() {
    shuffleEnabled = !shuffleEnabled;
    unawaited(_saveQueueState());
    _notify();
  }

  bool get isSingleLoopMode => repeatMode == RepeatMode.one;

  void toggleSingleLoopMode() {
    if (isSingleLoopMode) {
      repeatMode = RepeatMode.none;
    } else {
      repeatMode = RepeatMode.one;
    }
    _notify();
  }

  bool get canReshuffleUpcomingQueue {
    return queue.length - _upcomingQueueStartIndex > 1;
  }

  Future<void> startRandomLibraryPlayback() async {
    if (downloadedTracks.isEmpty) {
      globalMessage = '本地列表为空，请先下载歌曲或扫描下载目录。';
      _notify();
      return;
    }

    final shuffledTracks = List<DownloadedTrack>.from(downloadedTracks)
      ..shuffle(_shuffleRandom);
    final items = <PlayerItem>[];
    for (final track in shuffledTracks) {
      final item = await _playerItemFromDownloadedTrack(
        track,
        includeLyrics: false,
        showMissingMessage: false,
      );
      if (item != null) {
        items.add(item);
      }
    }

    if (items.isEmpty) {
      globalMessage = '没有找到可播放的本地文件，请重新扫描下载目录。';
      _notify();
      return;
    }

    queue = items;
    currentQueueIndex = 0;
    shuffleEnabled = true;
    await playQueueAt(0);
  }

  Future<void> reshuffleUpcomingQueue() async {
    final startIndex = _upcomingQueueStartIndex;
    final upcomingCount = queue.length - startIndex;
    if (upcomingCount < 2) {
      globalMessage = '后面没有足够的歌曲可以重新随机。';
      _notify();
      return;
    }

    final upcoming = queue.sublist(startIndex)..shuffle(_shuffleRandom);
    if (_sameQueueOrder(upcoming, queue.sublist(startIndex))) {
      upcoming.add(upcoming.removeAt(0));
    }

    queue = [...queue.take(startIndex), ...upcoming];
    shuffleEnabled = true;
    await _saveQueueState();
    globalMessage = '已重新随机接下来的 $upcomingCount 首歌。';
    _notify();
  }

  int get _upcomingQueueStartIndex {
    if (currentQueueIndex < 0 || currentQueueIndex >= queue.length) {
      return 0;
    }
    return currentQueueIndex + 1;
  }

  bool _sameQueueOrder(List<PlayerItem> left, List<PlayerItem> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index].id != right[index].id ||
          left[index].uri != right[index].uri) {
        return false;
      }
    }
    return true;
  }

  Future<void> removeQueueAt(int index) async {
    if (index < 0 || index >= queue.length) {
      return;
    }
    final removingCurrent = index == currentQueueIndex;
    queue = [
      for (var i = 0; i < queue.length; i += 1)
        if (i != index) queue[i],
    ];
    if (queue.isEmpty) {
      currentQueueIndex = -1;
      await player.stop();
    } else if (index < currentQueueIndex) {
      currentQueueIndex -= 1;
    } else if (removingCurrent) {
      currentQueueIndex = currentQueueIndex.clamp(0, queue.length - 1).toInt();
      await playQueueAt(currentQueueIndex);
      return;
    }
    await _saveQueueState();
    unawaited(_syncAndroidMediaControls(force: true));
    _notify();
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= queue.length) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0 || newIndex >= queue.length || oldIndex == newIndex) {
      return;
    }
    final moving = queue[oldIndex];
    final updatedQueue = List<PlayerItem>.from(queue)
      ..removeAt(oldIndex)
      ..insert(newIndex, moving);

    if (currentQueueIndex == oldIndex) {
      currentQueueIndex = newIndex;
    } else if (oldIndex < currentQueueIndex && newIndex >= currentQueueIndex) {
      currentQueueIndex -= 1;
    } else if (oldIndex > currentQueueIndex && newIndex <= currentQueueIndex) {
      currentQueueIndex += 1;
    }
    queue = updatedQueue;
    unawaited(_saveQueueState());
    unawaited(_syncAndroidMediaControls(force: true));
    _notify();
  }

  void moveQueueItemTo(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= queue.length ||
        newIndex < 0 ||
        newIndex >= queue.length ||
        oldIndex == newIndex) {
      return;
    }
    final moving = queue[oldIndex];
    final updatedQueue = List<PlayerItem>.from(queue)
      ..removeAt(oldIndex)
      ..insert(newIndex, moving);

    if (currentQueueIndex == oldIndex) {
      currentQueueIndex = newIndex;
    } else if (oldIndex < currentQueueIndex && newIndex >= currentQueueIndex) {
      currentQueueIndex -= 1;
    } else if (oldIndex > currentQueueIndex && newIndex <= currentQueueIndex) {
      currentQueueIndex += 1;
    }
    queue = updatedQueue;
    unawaited(_saveQueueState());
    unawaited(_syncAndroidMediaControls(force: true));
    _notify();
  }

  Future<void> clearQueue() async {
    queue = [];
    currentQueueIndex = -1;
    await player.stop();
    await _saveQueueState();
    unawaited(_syncAndroidMediaControls(force: true));
    _notify();
  }

  void clearGlobalMessage() {
    globalMessage = null;
    _notify();
  }

  void showGlobalMessage(String message) {
    globalMessage = message;
    _notify();
  }

  Future<void> _enqueueAndPlay(PlayerItem item) async {
    final existingIndex = queue.indexWhere((queued) => queued.id == item.id);
    if (existingIndex >= 0) {
      queue[existingIndex] = item;
      await playQueueAt(existingIndex);
      return;
    }

    queue = [...queue, item];
    await playQueueAt(queue.length - 1);
  }

  Future<void> _enqueueNext(PlayerItem item) async {
    final updatedQueue = List<PlayerItem>.from(queue);
    var insertionIndex = currentQueueIndex >= 0
        ? currentQueueIndex + 1
        : updatedQueue.length;
    final existingIndex = updatedQueue.indexWhere(
      (queued) => queued.id == item.id,
    );

    if (existingIndex >= 0) {
      if (existingIndex == currentQueueIndex) {
        updatedQueue[existingIndex] = item;
        queue = updatedQueue;
        await _saveQueueState();
        _notify();
        return;
      }
      updatedQueue.removeAt(existingIndex);
      if (existingIndex < currentQueueIndex) {
        currentQueueIndex -= 1;
      }
      insertionIndex = currentQueueIndex >= 0
          ? currentQueueIndex + 1
          : updatedQueue.length;
    }

    final clampedIndex = insertionIndex.clamp(0, updatedQueue.length).toInt();
    updatedQueue.insert(clampedIndex, item);
    queue = updatedQueue;
    await _saveQueueState();
    _notify();
  }

  Future<bool> _enqueueNextOrPlayWhenIdle(PlayerItem item) async {
    if (!player.isPlaying) {
      await _enqueueAndPlay(item);
      return true;
    }

    await _enqueueNext(item);
    return false;
  }

  Future<PlayerItem> _hydrateQueueItemForPlayback(PlayerItem item) async {
    final localPath = item.localPath;
    if (localPath == null || localPath.trim().isEmpty) {
      return item;
    }
    final file = File(localPath);
    if (!await file.exists()) {
      return item;
    }
    Id3Metadata metadata = const Id3Metadata();
    try {
      metadata = await Id3LyricsEmbedder.extractMetadata(file);
    } catch (_) {
      metadata = const Id3Metadata();
    }
    var lyrics = item.lyrics;
    if (lyrics == null || lyrics.trim().isEmpty) {
      lyrics = metadata.lyrics ?? await _readSidecarLyrics(file);
    }
    final embeddedAlbum = metadata.album?.trim();
    final album =
        item.album.trim().isEmpty &&
            embeddedAlbum != null &&
            embeddedAlbum.isNotEmpty
        ? embeddedAlbum
        : item.album;
    return item.copyWith(lyrics: lyrics, album: album);
  }

  Future<PlayerItem> _resolveSearchResultPlayerItem(
    TrackSearchResult result,
    String action,
  ) async {
    final requestSource = _sourceForName(result.source);
    final detail = await _runSourceRequest(
      action,
      () => requestSource.loadDetail(result),
    );
    final candidatesFuture = requestSource.resolveCandidates(detail);
    final lyricsFuture = _lyricsForTrack(
      existingLyrics: detail.lyrics,
      title: detail.title,
      artist: detail.artist,
      durationText: result.duration,
    );
    final candidate = _pickPreferredCandidate(
      await candidatesFuture,
      allowNonMp3: true,
    );
    if (candidate == null) {
      throw const MusicSourceException('这个歌曲页面没有找到可播放的公开音频链接。');
    }
    return PlayerItem(
      id: result.id,
      title: detail.title,
      artist: detail.artist,
      uri: candidate.url,
      headers: candidate.headers,
      coverUrl: detail.coverUrl ?? result.coverUrl,
      lyrics: await lyricsFuture,
      album: detail.album,
    );
  }

  Future<void> _saveQueueState() {
    return storage.savePlayerQueue(
      queue,
      currentQueueIndex,
      shuffleEnabled: shuffleEnabled,
    );
  }

  void _handlePlaybackCompleted() {
    unawaited(() async {
      if (repeatMode == RepeatMode.one && currentItem != null) {
        await playQueueAt(currentQueueIndex);
      } else {
        await playNext();
      }
    }());
  }
}
