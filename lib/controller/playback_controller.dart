part of '../app_controller.dart';

const _seekEndGuard = Duration(milliseconds: 250);

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
    if (_isDisposed) return;
    final generation = _beginPlaybackRequest();
    if (shuffle) {
      ordered.shuffle(_shuffleRandom);
    }
    final resolvedItems = await mapWithConcurrency(
      ordered,
      (track) => _playerItemFromDownloadedTrack(
        track,
        includeLyrics: false,
        includeMetadata: false,
        showMissingMessage: false,
      ),
      maxConcurrent: 8,
    );
    final items = resolvedItems.whereType<PlayerItem>().toList();
    if (!_canCommitPlaybackRequest(generation)) return;
    if (items.isEmpty) {
      globalMessage = '没有可播放的歌曲，请检查本地文件是否存在';
      _notify();
      return;
    }
    queue = items;
    currentQueueIndex = 0;
    shuffleEnabled = shuffle;
    await _playQueueAt(0, generation);
  }

  Future<void> playQueueAt(int index) async {
    if (_isDisposed || index < 0 || index >= queue.length) {
      return;
    }
    await _playQueueAt(index, _beginPlaybackRequest());
  }

  int _beginPlaybackRequest() {
    resolvingPlayId = null;
    return ++_playbackRequestGeneration;
  }

  bool _canCommitPlaybackRequest(int generation) =>
      !_isDisposed && generation == _playbackRequestGeneration;

  Future<void> _playQueueAt(int index, int generation) async {
    if (!_canCommitPlaybackRequest(generation) ||
        index < 0 ||
        index >= queue.length) {
      return;
    }
    final requestedItem = queue[index];
    final localPath = requestedItem.localPath;
    final acquiredRead = localPath == null || _tryBeginMetadataRead(localPath);
    if (!acquiredRead) {
      globalMessage = '正在更新“${queue[index].title}”的歌曲信息，请稍候再播放。';
      _notify();
      return;
    }
    var didOpen = false;
    try {
      final hydrated = await _hydrateQueueItemForPlayback(requestedItem);
      if (_isDisposed || generation != _playbackRequestGeneration) {
        return;
      }
      // The queue may have moved, removed or updated this item during I/O.
      final targetIndex = queue.indexWhere(
        (item) => item.id == requestedItem.id && item.uri == requestedItem.uri,
      );
      if (targetIndex < 0) return;
      final latestItem = queue[targetIndex];
      final item = identical(latestItem, requestedItem)
          ? hydrated
          : latestItem.copyWith(
              lyrics: (latestItem.lyrics?.trim().isEmpty ?? true)
                  ? hydrated.lyrics
                  : latestItem.lyrics,
              album: latestItem.album.trim().isEmpty
                  ? hydrated.album
                  : latestItem.album,
            );
      if (!identical(latestItem, item)) {
        queue = List<PlayerItem>.from(queue)..[targetIndex] = item;
      }
      currentQueueIndex = targetIndex;
      _notify();
      unawaited(_syncAndroidMediaControls(force: true));
      await _runPlaybackMutation(() async {
        if (!_isCurrentPlaybackRequest(generation, item)) return;
        await player.open(item);
        didOpen = _isCurrentPlaybackRequest(generation, item);
      });
      if (!didOpen || !_isCurrentPlaybackRequest(generation, item)) return;
      await _saveQueueStateAfterPlaybackStarts();
      if (!_isCurrentPlaybackRequest(generation, item)) return;
      await _recordRecentPlayback(item);
    } finally {
      if (localPath != null) {
        _endMetadataRead(localPath);
      }
      if (didOpen &&
          localPath != null &&
          !_metadataReadInProgress(_trackPathKey(localPath))) {
        unawaited(_captureCurrentTrackDuration());
      }
    }
  }

  bool _isCurrentPlaybackRequest(int generation, PlayerItem item) =>
      !_isDisposed &&
      generation == _playbackRequestGeneration &&
      currentItem?.id == item.id &&
      currentItem?.uri == item.uri;

  Future<void> _runPlaybackMutation(Future<void> Function() action) {
    final previous = _playbackMutationQueue;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A failed open must not prevent a later stop or selection.
      }
      if (!_isDisposed) await action();
    }();
    _playbackMutationQueue = operation;
    return operation;
  }

  Future<void> _stopPlayback() {
    _beginPlaybackRequest();
    return _runPlaybackMutation(player.stop);
  }

  Future<void> playNext() {
    final activeOperation = _playNextOperation;
    if (activeOperation != null) {
      return activeOperation;
    }

    late final Future<void> operation;
    operation = _playNextInternal().whenComplete(() {
      if (identical(_playNextOperation, operation)) {
        _playNextOperation = null;
      }
    });
    _playNextOperation = operation;
    return operation;
  }

  Future<void> _playNextInternal() async {
    if (queue.isEmpty) {
      return;
    }
    if (currentQueueIndex < queue.length - 1) {
      await playQueueAt(currentQueueIndex + 1);
    } else {
      await _startNextRandomRound();
    }
  }

  Future<void> _startNextRandomRound() async {
    final previousItem = currentItem;
    final randomized = List<PlayerItem>.from(queue)..shuffle(_shuffleRandom);
    if (previousItem != null && randomized.length > 1) {
      final previousIndex = randomized.indexWhere(
        (item) => item.id == previousItem.id && item.uri == previousItem.uri,
      );
      if (previousIndex == 0) {
        final swapIndex = 1 + _shuffleRandom.nextInt(randomized.length - 1);
        final replacement = randomized[swapIndex];
        randomized[swapIndex] = randomized[0];
        randomized[0] = replacement;
      }
    }
    queue = randomized;
    currentQueueIndex = 0;
    shuffleEnabled = true;
    await playQueueAt(0);
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

  Duration get maximumSeekPosition {
    final duration = player.duration;
    if (duration <= Duration.zero) {
      return Duration.zero;
    }
    if (duration <= _seekEndGuard) {
      return Duration.zero;
    }
    return duration - _seekEndGuard;
  }

  Future<void> seekTo(Duration value) {
    final duration = player.duration;
    final lowerBounded = value < Duration.zero ? Duration.zero : value;
    if (duration <= Duration.zero) {
      return player.seek(lowerBounded);
    }
    final upperBound = maximumSeekPosition;
    return player.seek(lowerBounded > upperBound ? upperBound : lowerBounded);
  }

  Future<bool> seekToLyricLine(
    PlayerItem expectedItem,
    Duration? timestamp,
  ) async {
    final item = currentItem;
    final duration = player.duration;
    if (item == null ||
        item.id != expectedItem.id ||
        item.uri != expectedItem.uri ||
        !player.isOpened(item) ||
        timestamp == null ||
        duration <= Duration.zero ||
        timestamp < Duration.zero ||
        timestamp >= duration) {
      return false;
    }
    await player.seek(timestamp);
    return true;
  }

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
    final resolvedItems = await mapWithConcurrency(
      shuffledTracks,
      (track) => _playerItemFromDownloadedTrack(
        track,
        includeLyrics: false,
        includeMetadata: false,
        showMissingMessage: false,
      ),
      maxConcurrent: 8,
    );
    final items = resolvedItems.whereType<PlayerItem>().toList();

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
      await _stopPlayback();
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
    await _stopPlayback();
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

  Future<void> _enqueueAndPlay(
    PlayerItem item, {
    int? requestGeneration,
  }) async {
    final generation = requestGeneration ?? _beginPlaybackRequest();
    if (!_canCommitPlaybackRequest(generation)) return;
    final existingIndex = queue.indexWhere((queued) => queued.id == item.id);
    if (existingIndex >= 0) {
      queue = List<PlayerItem>.from(queue)..[existingIndex] = item;
      await _playQueueAt(existingIndex, generation);
      return;
    }

    queue = [...queue, item];
    await _playQueueAt(queue.length - 1, generation);
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
    String action, {
    bool Function()? shouldRun,
  }) async {
    final requestSource = _sourceForName(result.source);
    final (detail, candidates) = await _runSourceRequest(action, () async {
      final detail = await requestSource.loadDetail(result);
      if (shouldRun != null && !shouldRun()) {
        throw const _ObsoleteSourceRequest();
      }
      final candidates = await requestSource.resolveCandidates(detail);
      return (detail, candidates);
    }, shouldRun: shouldRun);
    final candidate = _pickPreferredCandidate(candidates, allowNonMp3: true);
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
      lyrics: detail.lyrics,
      album: detail.album,
    );
  }

  Future<void> _loadOnlineLyrics(
    PlayerItem item, {
    String? durationText,
    int? playbackGeneration,
  }) async {
    if (_isDisposed || (item.lyrics?.trim().isNotEmpty ?? false)) return;
    try {
      final lyrics = await _lyricsForTrack(
        existingLyrics: item.lyrics,
        title: item.title,
        artist: item.artist,
        durationText: durationText,
      );
      if (_isDisposed || lyrics == null || lyrics.trim().isEmpty) return;
      if (playbackGeneration != null &&
          !_isCurrentPlaybackRequest(playbackGeneration, item)) {
        return;
      }
      // Identity also rejects a removed and re-added item with the same URL.
      final index = queue.indexWhere((queued) => identical(queued, item));
      if (index < 0) return;
      queue = List<PlayerItem>.from(queue)
        ..[index] = item.copyWith(lyrics: lyrics);
      _notify();
      unawaited(_syncAndroidMediaControls(force: true));
      await _saveQueueState();
    } catch (error, stackTrace) {
      AppLog.instance.warning(
        'lyrics',
        '后台补全在线歌词失败',
        detail: '$error\n$stackTrace',
      );
    }
  }

  Future<void> _saveQueueState() {
    final items = List<PlayerItem>.unmodifiable(queue);
    final index = currentQueueIndex;
    final shuffle = shuffleEnabled;
    return _playerQueueSaveQueue.enqueue(
      () => storage.savePlayerQueue(items, index, shuffleEnabled: shuffle),
    );
  }

  Future<void> _saveQueueStateAfterPlaybackStarts() async {
    try {
      await _saveQueueState();
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'playback',
        '歌曲已播放，但播放队列保存失败',
        error: error,
        stackTrace: stackTrace,
      );
      globalMessage = '歌曲已开始播放，但播放队列保存失败。';
      _notify();
    }
  }

  void _handlePlaybackCompleted() {
    if (_playbackCompletionOperation != null) {
      return;
    }

    late final Future<void> operation;
    operation = _continueAfterPlaybackCompleted().whenComplete(() {
      if (identical(_playbackCompletionOperation, operation)) {
        _playbackCompletionOperation = null;
      }
    });
    _playbackCompletionOperation = operation;
    unawaited(operation);
  }

  Future<void> _continueAfterPlaybackCompleted() async {
    try {
      if (repeatMode == RepeatMode.one && currentItem != null) {
        await playQueueAt(currentQueueIndex);
      } else {
        await playNext();
      }
    } catch (error, stackTrace) {
      AppLog.instance.error(
        'playback',
        '自动接播下一首失败',
        error: error,
        stackTrace: stackTrace,
      );
      globalMessage = '自动播放下一首失败：${_friendlyUnexpectedError(error)}';
      _notify();
    }
  }
}
