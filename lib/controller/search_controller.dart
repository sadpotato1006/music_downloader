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

  Future<void> _ensureLibraryLyricsForQuery(String query) =>
      _libraryLyricsSearch.search(query, downloadedTracks);

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
    _lastSourceRequestAt = null;
    searchResults = [];
    searchError = null;
    globalMessage = '已切换到 ${source.name}';
    _notify();

    final keyword = searchQuery.trim();
    if (keyword.isNotEmpty) {
      await search(keyword);
    }
  }

  Future<void> search(String value) async {
    if (_isDisposed) {
      return;
    }
    final generation = ++_sourceSearchGeneration;
    final keyword = value.trim();
    searchQuery = keyword;
    if (keyword.isEmpty) {
      searchResults = [];
      searchError = null;
      isSearching = false;
      _notify();
      return;
    }

    _rememberSourceSearch(keyword);
    final requestSource = source;
    isSearching = true;
    searchError = null;
    _notify();

    try {
      final results = await _runSourceRequest(
        '搜索',
        () => requestSource.search(keyword),
        shouldRun: () => _canCommitSourceSearch(generation),
      );
      if (!_canCommitSourceSearch(generation)) {
        return;
      }
      searchResults = results;
      if (results.isEmpty) {
        searchError = '没有找到公开可解析的搜索结果。';
      }
    } on _ObsoleteSourceRequest {
      return;
    } on MusicSourceException catch (error) {
      if (!_canCommitSourceSearch(generation)) {
        return;
      }
      searchResults = [];
      searchError = error.message;
    } catch (error) {
      if (!_canCommitSourceSearch(generation)) {
        return;
      }
      searchResults = [];
      searchError = '搜索失败：${_friendlyUnexpectedError(error)}';
    } finally {
      if (_canCommitSourceSearch(generation)) {
        isSearching = false;
        _notify();
      }
    }
  }

  bool _canCommitSourceSearch(int generation) {
    return !_isDisposed && generation == _sourceSearchGeneration;
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
    settings = activeSettings.copyWith(sourceSearchHistory: updated);
    _debouncedSaveSettings();
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
    settings = activeSettings.copyWith(librarySearchHistory: updated);
    _debouncedSaveSettings();
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
    } on _ObsoleteSourceRequest {
      return;
    } on MusicSourceException catch (error) {
      if (!_canCommitPlaybackRequest(generation)) return;
      globalMessage = error.message;
    } catch (error) {
      if (!_canCommitPlaybackRequest(generation)) return;
      globalMessage = '播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      if (_canCommitPlaybackRequest(generation)) {
        resolvingPlayId = null;
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
    } on _ObsoleteSourceRequest {
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
    if (!_tryBeginMetadataRead(track.path)) {
      globalMessage = '正在更新“${track.title}”的歌曲信息，请稍候再播放。';
      _notify();
      return;
    }
    var startedPlayback = false;
    try {
      final item = await _playerItemFromDownloadedTrack(
        track,
        metadataReadHeld: true,
      );
      if (item == null || !_canCommitPlaybackRequest(generation)) {
        return;
      }
      await _enqueueAndPlay(item, requestGeneration: generation);
      startedPlayback = _isCurrentPlaybackRequest(generation, item);
    } finally {
      _endMetadataRead(track.path);
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
      if (!_tryBeginMetadataRead(track.path)) {
        globalMessage = '正在更新“${track.title}”的歌曲信息，请稍候再加入队列。';
        return;
      }
      var startedPlayback = false;
      try {
        final item = await _playerItemFromDownloadedTrack(
          track,
          metadataReadHeld: true,
        );
        if (item == null || !_canCommitQueueNext(generation)) {
          return;
        }
        final started = await _enqueueNextOrPlayWhenIdle(item);
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
