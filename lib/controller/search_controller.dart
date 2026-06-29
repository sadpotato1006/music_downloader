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
    if (LibrarySearch.normalize(libraryQuery).isNotEmpty) {
      unawaited(_ensureLibraryLyricsForQuery(libraryQuery));
    } else {
      _libraryLyricsSearchGeneration += 1;
    }
  }

  Future<void> _ensureLibraryLyricsForQuery(String query) async {
    final normalizedQuery = LibrarySearch.normalize(query);
    if (normalizedQuery.isEmpty) {
      return;
    }
    final generation = ++_libraryLyricsSearchGeneration;
    var changed = false;

    for (final track in List<DownloadedTrack>.from(downloadedTracks)) {
      if (generation != _libraryLyricsSearchGeneration ||
          LibrarySearch.normalize(libraryQuery) != normalizedQuery) {
        return;
      }

      if (_librarySearchIndexFor(
        track,
        includeCachedLyrics: false,
      ).matchesNormalizedQuery(normalizedQuery)) {
        continue;
      }

      final key = _libraryLyricsCacheKey(track);
      if (_libraryLyricsSearchCache.containsKey(key) ||
          !_loadingLibraryLyricsKeys.add(key)) {
        continue;
      }

      try {
        await Future<void>.delayed(Duration.zero);
        _libraryLyricsSearchCache[key] =
            (await readDownloadedLyrics(track))?.trim() ?? '';
        changed = true;
      } finally {
        _loadingLibraryLyricsKeys.remove(key);
      }
    }

    if (changed &&
        generation == _libraryLyricsSearchGeneration &&
        LibrarySearch.normalize(libraryQuery) == normalizedQuery) {
      _visibleDownloadedTracksSource = null;
      _notify();
    }
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
    sourceCooldownUntil = null;
    sourceCooldownReason = null;
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
    final keyword = value.trim();
    searchQuery = keyword;
    if (keyword.isEmpty) {
      searchResults = [];
      searchError = null;
      _notify();
      return;
    }

    _rememberSourceSearch(keyword);
    isSearching = true;
    searchError = null;
    _notify();

    try {
      searchResults = await _runSourceRequest(
        '搜索',
        () => source.search(keyword),
      );
      if (searchResults.isEmpty) {
        searchError = '没有找到公开可解析的搜索结果。';
      }
    } on MusicSourceException catch (error) {
      searchResults = [];
      searchError = error.message;
    } catch (error) {
      searchResults = [];
      searchError = '搜索失败：${_friendlyUnexpectedError(error)}';
    } finally {
      isSearching = false;
      _notify();
    }
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
    resolvingPlayId = result.id;
    globalMessage = '正在准备播放：${result.title}';
    _notify();

    try {
      final item = await _resolveSearchResultPlayerItem(result, '播放');
      await _enqueueAndPlay(item);
      globalMessage = '已开始播放：${item.title}';
    } on MusicSourceException catch (error) {
      globalMessage = error.message;
    } catch (error) {
      globalMessage = '播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      resolvingPlayId = null;
      _notify();
    }
  }

  Future<void> queueSearchResultNext(TrackSearchResult result) async {
    preparingQueueNextId = result.id;
    globalMessage = null;
    _notify();

    try {
      final item = await _resolveSearchResultPlayerItem(result, '下一首播放');
      final started = await _enqueueNextOrPlayWhenIdle(item);
      globalMessage = started
          ? '已开始播放：${item.title}'
          : '已加入下一首播放：${item.title}';
    } on MusicSourceException catch (error) {
      globalMessage = error.message;
    } catch (error) {
      globalMessage = '加入下一首播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      preparingQueueNextId = null;
      _notify();
    }
  }

  Future<void> playDownloaded(DownloadedTrack track) async {
    final item = await _playerItemFromDownloadedTrack(track);
    if (item == null) {
      return;
    }
    await _enqueueAndPlay(item);
  }

  Future<void> queueDownloadedNext(DownloadedTrack track) async {
    preparingQueueNextId = track.id;
    globalMessage = null;
    _notify();

    try {
      final item = await _playerItemFromDownloadedTrack(track);
      if (item == null) {
        return;
      }
      final started = await _enqueueNextOrPlayWhenIdle(item);
      globalMessage = started
          ? '已开始播放：${item.title}'
          : '已加入下一首播放：${item.title}';
    } catch (error) {
      globalMessage = '加入下一首播放失败：${_friendlyUnexpectedError(error)}';
    } finally {
      preparingQueueNextId = null;
      _notify();
    }
  }
}
