part of '../app_controller.dart';

extension AppControllerSearchActions on AppController {
  void selectIndex(int index) {
    if (index < 0 || index > 3 || selectedIndex == index) {
      return;
    }
    selectedIndex = index;
    _notify();
  }

  void setLibraryQuery(String value) {
    _setLibraryQuery(value);
    _notify();
  }

  void commitLibrarySearch(String value) {
    final keyword = value.trim();
    _setLibraryQuery(keyword);
    if (keyword.isNotEmpty) {
      _rememberLibrarySearch(keyword);
    }
    _notify();
  }

  void _setLibraryQuery(String value) {
    libraryQuery = value.trim();
    _visibleDownloadedTracksSource = null;
    unawaited(_ensureLibraryLyricsForQuery(libraryQuery));
  }

  Future<void> _ensureLibraryLyricsForQuery(String query) {
    if (downloadedTracks.length >= AppController.backgroundLibraryThreshold) {
      final request = (
        downloadedTracks,
        LibrarySearch.normalize(query),
        librarySortMode,
      );
      if (_completedLibraryView == request) {
        return _libraryLyricsSearch.search(query, downloadedTracks);
      }
      unawaited(_libraryLyricsSearch.search('', const []));
      _requestLibraryView(request);
      return libraryViewReady;
    }
    return _libraryLyricsSearch.search(query, downloadedTracks);
  }

  void setLibrarySortMode(LibrarySortMode mode) {
    if (librarySortMode == mode) {
      return;
    }
    librarySortMode = mode;
    _notify();
  }

  void showMessage(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }
    globalMessage = trimmed;
    _notify();
  }

  Future<void> switchToNextSource() async {
    if (!canSwitchSource ||
        isSearching ||
        resolvingPlayId != null ||
        preparingDownloadId != null ||
        preparingQueueNextId != null) {
      return;
    }
    final currentIndex = sources.indexWhere((item) => item.name == source.name);
    source = sources[(currentIndex + 1) % sources.length];
    _sourceRequests.resetDelay();
    searchResults = [];
    searchError = null;
    onlineSearch.failed = false;
    globalMessage = '已切换到 ${source.name}';
    _notify();

    final keyword = searchQuery.trim();
    if (keyword.isNotEmpty) {
      await search(keyword);
    }
  }

  Future<void> search(String value) {
    if (_isDisposed) return Future<void>.value();
    final keyword = value.trim();
    if (keyword.isNotEmpty) _rememberSourceSearch(keyword);
    return onlineSearch.search(source, value);
  }

  void _rememberSourceSearch(String keyword) {
    final activeSettings = settings;
    if (activeSettings == null) {
      return;
    }
    final updated = _updatedSearchHistory(
      activeSettings.sourceSearchHistory,
      keyword,
    );
    if (listEquals(updated, activeSettings.sourceSearchHistory)) {
      return;
    }
    preferences.update((value) => value.copyWith(sourceSearchHistory: updated));
  }

  void _rememberLibrarySearch(String keyword) {
    final activeSettings = settings;
    if (activeSettings == null) {
      return;
    }
    final updated = _updatedSearchHistory(
      activeSettings.librarySearchHistory,
      keyword,
    );
    if (listEquals(updated, activeSettings.librarySearchHistory)) {
      return;
    }
    preferences.update(
      (value) => value.copyWith(librarySearchHistory: updated),
    );
  }

  List<String> _updatedSearchHistory(List<String> current, String keyword) {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return current;
    }
    return normalizeSearchHistory([
      trimmed,
      ...current.where(
        (item) => item.trim().toLowerCase() != trimmed.toLowerCase(),
      ),
    ]);
  }

  Future<void> playSearchResult(TrackSearchResult result) async {
    if (_isDisposed) return;
    final generation = _beginPlaybackRequest();
    resolvingPlayId = result.id;
    final key = searchPlaybackKey(result);
    preparingPlaybackKey = key;
    globalMessage = '正在准备播放：${result.title}';
    _notify();

    try {
      final item = await _resolveSearchResultPlayerItem(
        result,
        '播放',
        shouldRun: () => _canCommitPlaybackRequest(generation),
      );
      if (!_canCommitPlaybackRequest(generation)) return;
      await _enqueueAndPlay(item, requestGeneration: generation);
      if (!_isCurrentPlaybackRequest(generation, item)) return;
      globalMessage = '已开始播放：${item.title}';
      unawaited(
        _loadOnlineLyrics(
          item,
          durationText: result.duration,
          playbackGeneration: generation,
        ),
      );
    } on ObsoleteSourceRequest {
      return;
    } on MusicSourceException catch (error) {
      if (!_canCommitPlaybackRequest(generation)) return;
      globalMessage = error.message;
      playbackFailure = (key: key, message: error.message);
    } catch (error) {
      if (!_canCommitPlaybackRequest(generation)) return;
      globalMessage = '播放失败：${_friendlyUnexpectedError(error)}';
      playbackFailure = (key: key, message: globalMessage!);
    } finally {
      if (_canCommitPlaybackRequest(generation)) {
        resolvingPlayId = null;
        preparingPlaybackKey = null;
        _notify();
      }
    }
  }

  Future<void> queueSearchResultNext(TrackSearchResult result) async {
    if (_isDisposed) return;
    final generation = ++_queueNextRequestGeneration;
    preparingQueueNextId = result.id;
    globalMessage = null;
    _notify();

    try {
      final item = await _resolveSearchResultPlayerItem(
        result,
        '下一首播放',
        shouldRun: () => _canCommitQueueNext(generation),
      );
      if (!_canCommitQueueNext(generation)) return;
      final started = await _enqueueNextOrPlayWhenIdle(item);
      unawaited(_loadOnlineLyrics(item, durationText: result.duration));
      if (!_canCommitQueueNext(generation)) return;
      globalMessage = started
          ? '已开始播放：${item.title}'
          : '已加入下一首播放：${item.title}';
    } on ObsoleteSourceRequest {
      return;
    } on MusicSourceException catch (error) {
      if (!_canCommitQueueNext(generation)) return;
      globalMessage = error.message;
    } catch (error) {
      if (!_canCommitQueueNext(generation)) return;
      globalMessage = '加入下一首播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      if (_canCommitQueueNext(generation)) {
        preparingQueueNextId = null;
        _notify();
      }
    }
  }

  bool _canCommitQueueNext(int generation) =>
      !_isDisposed && generation == _queueNextRequestGeneration;

  Future<void> playDownloaded(DownloadedTrack track) async {
    if (_isDisposed) return;
    final generation = _beginPlaybackRequest();
    final key = localPlaybackKey(track);
    preparingPlaybackKey = key;
    _notify();
    var startedPlayback = false;
    var acquiredRead = false;
    try {
      acquiredRead = await _beginMetadataReadWhenAvailable(track.path);
      if (!acquiredRead || !_canCommitPlaybackRequest(generation)) return;
      final item = await _playerItemFromDownloadedTrack(
        track,
        metadataReadHeld: true,
      );
      if (item == null || !_canCommitPlaybackRequest(generation)) {
        if (item == null && _canCommitPlaybackRequest(generation)) {
          playbackFailure = (
            key: key,
            message: globalMessage ?? '文件不可用，请检查后重试',
          );
        }
        return;
      }
      await _enqueueAndPlay(
        item,
        requestGeneration: generation,
        metadataReadHeld: true,
      );
      startedPlayback = _isCurrentPlaybackRequest(generation, item);
    } catch (error) {
      if (_canCommitPlaybackRequest(generation)) {
        globalMessage = '播放失败：${_friendlyUnexpectedError(error)}';
        playbackFailure = (key: key, message: globalMessage!);
      }
    } finally {
      if (acquiredRead) _endMetadataRead(track.path);
      if (_canCommitPlaybackRequest(generation)) {
        preparingPlaybackKey = null;
        _notify();
      }
      if (startedPlayback) {
        unawaited(_captureCurrentTrackDuration());
      }
    }
  }

  Future<void> queueDownloadedNext(DownloadedTrack track) async {
    if (_isDisposed) return;
    final generation = ++_queueNextRequestGeneration;
    preparingQueueNextId = track.id;
    globalMessage = null;
    _notify();

    try {
      if (!await _beginMetadataReadWhenAvailable(track.path)) return;
      var startedPlayback = false;
      try {
        if (!_canCommitQueueNext(generation)) return;
        final item = await _playerItemFromDownloadedTrack(
          track,
          metadataReadHeld: true,
        );
        if (item == null || !_canCommitQueueNext(generation)) {
          return;
        }
        final started = await _enqueueNextOrPlayWhenIdle(
          item,
          metadataReadHeld: true,
        );
        startedPlayback = started;
        if (!_canCommitQueueNext(generation)) return;
        globalMessage = started
            ? '已开始播放：${item.title}'
            : '已加入下一首播放：${item.title}';
      } finally {
        _endMetadataRead(track.path);
        if (startedPlayback) {
          unawaited(_captureCurrentTrackDuration());
        }
      }
    } catch (error) {
      if (!_canCommitQueueNext(generation)) return;
      globalMessage = '加入下一首播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      if (_canCommitQueueNext(generation)) {
        preparingQueueNextId = null;
        _notify();
      }
    }
  }
}
