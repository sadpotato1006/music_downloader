import 'dart:async';

import 'library_search.dart';
import 'models.dart';

/// A single worker pool follows the latest query and keeps a bounded LRU cache.
/// Matches for the active query survive cache eviction until the query changes.
class LibraryLyricsSearch {
  LibraryLyricsSearch({
    required this.readLyrics,
    required this.trackKey,
    required this.isCurrent,
    required this.matchesMetadata,
    required this.onChanged,
    this.onError,
    this.maxConcurrent = 3,
    this.maxCacheEntries = 256,
    this.maxCacheCodeUnits = 2 * 1024 * 1024,
    this.refreshInterval = const Duration(milliseconds: 80),
  }) : assert(maxConcurrent > 0),
       assert(maxCacheEntries > 0),
       assert(maxCacheCodeUnits > 0);

  final Future<String?> Function(DownloadedTrack) readLyrics;
  final String Function(DownloadedTrack) trackKey;
  final bool Function(DownloadedTrack) isCurrent;
  final bool Function(DownloadedTrack, String) matchesMetadata;
  final void Function() onChanged;
  final void Function(Object, StackTrace)? onError;
  final int maxConcurrent;
  final int maxCacheEntries;
  final int maxCacheCodeUnits;
  final Duration refreshInterval;
  final Map<String, String> _cache = {};
  final Set<String> _matches = {};
  int _cacheCodeUnits = 0;
  int _generation = 0;
  String _query = '';
  List<DownloadedTrack>? _pending;
  Future<void>? _operation;
  Timer? _refresh;
  bool _dirty = false;
  bool _disposed = false;

  int get cachedEntries => _cache.length;
  int get cachedCodeUnits => _cacheCodeUnits;

  bool matches(DownloadedTrack track, String normalizedQuery) {
    if (normalizedQuery.isEmpty) return false;
    final key = trackKey(track);
    if (_query == normalizedQuery && _matches.contains(key)) {
      return true;
    }
    final cached = _cache[key];
    return cached != null && cached.contains(normalizedQuery);
  }

  Future<void> search(String query, Iterable<DownloadedTrack> tracks) {
    if (_disposed) return Future<void>.value();
    final normalized = LibrarySearch.normalize(query);
    if (_query != normalized) _matches.clear();
    _query = normalized;
    _generation++;
    _pending = normalized.isEmpty ? null : List.of(tracks);
    _refresh?.cancel();
    _refresh = null;
    _dirty = false;
    return _start();
  }

  Future<void> _start() {
    if (_operation != null) return _operation!;
    if (_disposed || _pending == null) return Future<void>.value();
    late final Future<void> operation;
    operation = _run().whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
      if (!_disposed && _pending != null) unawaited(_start());
    });
    _operation = operation;
    return operation;
  }

  Future<void> _run() async {
    while (!_disposed && _pending != null) {
      final tracks = _pending!;
      _pending = null;
      final generation = _generation;
      final query = _query;
      var next = 0;
      bool active() => !_disposed && generation == _generation;

      Future<void> worker() async {
        while (active() && next < tracks.length) {
          final track = tracks[next++];
          // Yield even on cache hits so a large library cannot monopolize UI.
          await Future<void>.delayed(Duration.zero);
          if (!active()) return;
          if (!isCurrent(track) || matchesMetadata(track, query)) continue;
          final key = trackKey(track);
          if (_matches.contains(key)) continue;
          final cached = _cache.remove(key);
          if (cached != null) _cache[key] = cached;
          try {
            final lyrics =
                cached ??
                LibrarySearch.normalize(await readLyrics(track) ?? '');
            if (_disposed || !isCurrent(track)) continue;
            if (cached == null) _cacheLyrics(track, lyrics);
            if (!active()) continue;
            if (lyrics.contains(query) && _matches.add(key)) _markChanged();
          } catch (error, stackTrace) {
            if (!_disposed) onError?.call(error, stackTrace);
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < maxConcurrent && i < tracks.length; i++) worker(),
      ]);
      if (active()) _publish();
    }
  }

  void update(DownloadedTrack track, String lyrics) {
    if (_disposed) return;
    remove(track);
    final normalized = LibrarySearch.normalize(lyrics);
    _cacheLyrics(track, normalized);
    if (_query.isNotEmpty && normalized.contains(_query)) {
      _matches.add(trackKey(track));
    }
    _markChanged();
  }

  void remove(DownloadedTrack track) {
    final key = trackKey(track);
    final old = _cache.remove(key);
    if (old != null) _cacheCodeUnits -= old.length;
    _matches.remove(key);
  }

  void _cacheLyrics(DownloadedTrack track, String lyrics) {
    final key = trackKey(track);
    final old = _cache.remove(key);
    if (old != null) _cacheCodeUnits -= old.length;
    if (lyrics.length > maxCacheCodeUnits) return;
    _cache[key] = lyrics;
    _cacheCodeUnits += lyrics.length;
    while (_cache.length > maxCacheEntries ||
        _cacheCodeUnits > maxCacheCodeUnits) {
      _cacheCodeUnits -= _cache.remove(_cache.keys.first)!.length;
    }
  }

  void _markChanged() {
    _dirty = true;
    _refresh ??= Timer(refreshInterval, _publish);
  }

  void _publish() {
    _refresh?.cancel();
    _refresh = null;
    if (_disposed || !_dirty) return;
    _dirty = false;
    onChanged();
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _pending = null;
    _refresh?.cancel();
    _cache.clear();
    _matches.clear();
    _cacheCodeUnits = 0;
  }
}
