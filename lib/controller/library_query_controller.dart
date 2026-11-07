part of '../app_controller.dart';

extension AppControllerLibraryQuery on AppController {
  void _releaseLargeLibraryView() {
    if (_requestedLibraryView == null &&
        _completedLibraryView == null &&
        _failedLibraryView == null) {
      return;
    }
    _requestedLibraryView = null;
    _completedLibraryView = null;
    _failedLibraryView = null;
    _libraryQueryResult = null;
    _libraryQueryWorker.reset();
  }

  bool get isPreparingLibraryView =>
      downloadedTracks.length >= AppController.backgroundLibraryThreshold &&
      _completedLibraryView !=
          (
            downloadedTracks,
            LibrarySearch.normalize(libraryQuery),
            librarySortMode,
          ) &&
      libraryViewError == null;

  String? get libraryViewError =>
      _failedLibraryView ==
          (
            downloadedTracks,
            LibrarySearch.normalize(libraryQuery),
            librarySortMode,
          )
      ? '曲库搜索暂时不可用，请重试'
      : null;

  Future<void> get libraryViewReady =>
      _libraryQueryOperation ?? Future<void>.value();

  void retryLibraryView() {
    _failedLibraryView = null;
    _requestLibraryView((
      downloadedTracks,
      LibrarySearch.normalize(libraryQuery),
      librarySortMode,
    ));
    _notify();
  }

  void _requestLibraryView(
    (List<DownloadedTrack>, String, LibrarySortMode) request,
  ) {
    if (_isDisposed ||
        _failedLibraryView == request ||
        _completedLibraryView == request) {
      return;
    }
    _requestedLibraryView = request;
    if (_libraryQueryOperation != null) return;
    // Defer work so a getter used by build never notifies listeners synchronously.
    _libraryQueryOperation = Future<void>.microtask(_runLibraryQueries)
        .whenComplete(() {
          _libraryQueryOperation = null;
        });
  }

  Future<void> _runLibraryQueries() async {
    while (!_isDisposed && _requestedLibraryView != null) {
      final request = _requestedLibraryView!;
      try {
        final result = await _libraryQueryWorker.query(
          request.$1,
          request.$2,
          request.$3,
        );
        if (_isDisposed) return;
        final latest = (
          downloadedTracks,
          LibrarySearch.normalize(libraryQuery),
          librarySortMode,
        );
        if (latest != request) {
          _requestedLibraryView =
              downloadedTracks.length >=
                  AppController.backgroundLibraryThreshold
              ? latest
              : null;
          continue;
        }
        _completedLibraryView = request;
        _libraryQueryResult = result;
        _failedLibraryView = null;
        _visibleDownloadedTracksSource = null;
        _requestedLibraryView = null;
        _notify();
        if (request.$2.isNotEmpty &&
            identical(downloadedTracks, request.$1) &&
            LibrarySearch.normalize(libraryQuery) == request.$2) {
          unawaited(_libraryLyricsSearch.search(request.$2, request.$1));
        }
      } catch (error, stack) {
        if (_isDisposed) return;
        if (_requestedLibraryView != request) continue;
        _failedLibraryView = request;
        _requestedLibraryView = null;
        AppLog.instance.warning(
          'library',
          '后台曲库搜索失败',
          detail: '$error\n$stack',
        );
        _notify();
      }
    }
  }
}
