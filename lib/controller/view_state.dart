part of '../app_controller.dart';

/// Immutable projections consumed by the shell. Collections are replaced by
/// their owning controllers; progress and lyric ticks keep separate listeners.
extension AppControllerViewState on AppController {
  Object get miniPlayerViewState =>
      (currentItem, player.isPlaying, queue.isNotEmpty, playbackHealthView);

  Object get playbackHealthView =>
      (currentPlaybackHealth.buffering, currentPlaybackHealth.error);

  Object get playbackViewState => (
    miniPlayerViewState,
    currentQueueIndex,
    repeatMode,
    shuffleEnabled,
    player.duration,
    queue,
  );

  Object get searchViewState => (
    source,
    searchQuery,
    onlineSearch.failed,
    songCardViewState,
    isSearching,
    searchResults,
    searchError,
    resolvingPlayId,
    preparingDownloadId,
    preparingQueueNextId,
    _HistoryView(settings?.sourceSearchHistory ?? const []),
  );

  Object get downloadsViewState => (
    downloadTasks,
    downloadedTracks,
    isScanningDownloadDirectory,
    _downloadImportOperations.keys.join('\u0000'),
  );

  Object get libraryViewState => (
    visibleDownloadedTracks,
    isPreparingLibraryView,
    libraryViewError,
    songCardViewState,
    myMusic,
    libraryQuery,
    librarySortMode,
    preparingQueueNextId,
    isCloudSyncing,
    cloudDeletionPolicyEnabled,
    isLibraryBatchRunning,
    libraryBatchCompleted,
    libraryBatchTotal,
    _songFiles.deletionRevision,
  );

  Object get songCardViewState => (
    currentItem?.id,
    currentItem?.localPath,
    player.isPlaying,
    preparingPlaybackKey,
    playbackFailure,
    playbackHealthView,
  );

  Object get libraryToolsViewState => (
    downloadedTracks,
    isScanningDownloadDirectory,
    isMatchingLocalAlbums,
    matchingAlbumTrackTitle,
    albumMatchProcessed,
    albumMatchTotal,
    albumMatchUpdated,
    albumMatchNotFound,
    albumMatchFailed,
    pendingAlbumMatches,
    _albumMatchCancelRequested,
  );
}

// AppSettings.copyWith normalizes history into a fresh list even when another
// preference changes. Compare this small value collection by contents.
class _HistoryView {
  _HistoryView(List<String> values) : values = List.unmodifiable(values);
  final List<String> values;
  @override
  bool operator ==(Object other) =>
      other is _HistoryView && listEquals(values, other.values);
  @override
  int get hashCode => Object.hashAll(values);
}
