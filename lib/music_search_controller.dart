import 'package:flutter/foundation.dart';

import 'models.dart';
import 'music_source.dart';
import 'source_request_queue.dart';

typedef SearchRequest =
    Future<List<TrackSearchResult>> Function(
      MusicSource source,
      String keyword,
      bool Function() isCurrent,
    );

/// Online search state is independent of download, playback and library state.
class MusicSearchController extends ChangeNotifier {
  MusicSearchController({required this.request, required this.describeError});
  final SearchRequest request;
  final String Function(Object error) describeError;
  String query = '';
  bool isSearching = false;
  String? error;
  List<TrackSearchResult> results = const [];
  int _generation = 0;
  bool _disposed = false;

  Future<void> search(MusicSource source, String value) async {
    if (_disposed) return;
    final generation = ++_generation;
    bool current() => !_disposed && _generation == generation;
    query = value.trim();
    error = null;
    if (query.isEmpty) {
      results = const [];
      isSearching = false;
      notifyListeners();
      return;
    }
    isSearching = true;
    notifyListeners();
    try {
      final found = await request(source, query, current);
      if (!current()) return;
      results = List.unmodifiable(found);
      if (found.isEmpty) error = '没有找到公开可解析的搜索结果。';
    } on ObsoleteSourceRequest {
      return;
    } catch (failure) {
      if (!current()) return;
      results = const [];
      error = failure is MusicSourceException
          ? failure.message
          : '搜索失败：${describeError(failure)}';
    } finally {
      if (current()) {
        isSearching = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
