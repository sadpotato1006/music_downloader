import 'dart:convert';
import 'dart:io';

import 'package:qingting/coalescing_write_queue.dart';
import 'package:qingting/models.dart';

// Synthetic, in-memory benchmark of snapshot construction and JSON encoding.
// Does not read or write the user's library, and does not measure disk latency.
// Run with: dart run tools/benchmark_json_saves.dart
Future<void> main() async {
  for (final count in [200, 1000, 10000]) {
    final tracks = List.generate(
      count,
      (index) => DownloadedTrack(
        id: 'song-$index',
        title: '测试歌曲 $index',
        artist: '测试歌手',
        path: 'C:/Music/测试歌手 - 测试歌曲 $index.mp3',
        format: 'mp3',
        downloadedAt: DateTime(2026, 9, 22),
        sourceUrl: 'https://example.test/song/$index',
        album: '测试专辑',
        durationMs: 200000,
      ),
    );
    final values = tracks.map((track) => track.toJson()).toList();
    const prettyEncoder = JsonEncoder.withIndent('  ');
    for (var warmup = 0; warmup < 3; warmup++) {
      jsonEncode(values);
      prettyEncoder.convert(values);
    }
    final encodingTimes = <int>[];
    for (var run = 0; run < 7; run++) {
      final watch = Stopwatch()..start();
      jsonEncode(values);
      encodingTimes.add(watch.elapsedMicroseconds);
    }
    encodingTimes.sort();
    var baselineEncodes = 0;
    var compactEncodes = 0;
    final baselineWatch = Stopwatch()..start();
    for (var change = 0; change < 20; change++) {
      final snapshot = List<DownloadedTrack>.unmodifiable(tracks);
      prettyEncoder.convert(snapshot.map((track) => track.toJson()).toList());
      baselineEncodes++;
    }
    baselineWatch.stop();
    final queue = CoalescingWriteQueue();
    final optimizedWatch = Stopwatch()..start();
    final saves = <Future<void>>[];
    for (var change = 0; change < 20; change++) {
      final snapshot = List<DownloadedTrack>.unmodifiable(tracks);
      saves.add(
        queue.enqueue(() async {
          jsonEncode(snapshot.map((track) => track.toJson()).toList());
          compactEncodes++;
        }),
      );
    }
    await Future.wait(saves);
    optimizedWatch.stop();
    stdout.writeln(
      jsonEncode({
        'tracks': count,
        'pretty_bytes': utf8.encode(prettyEncoder.convert(values)).length,
        'compact_bytes': utf8.encode(jsonEncode(values)).length,
        'single_compact_encode_us_median': encodingTimes[3],
        'before_encodes': baselineEncodes,
        'after_encodes': compactEncodes,
        'before_serialization_us': baselineWatch.elapsedMicroseconds,
        'after_serialization_us': optimizedWatch.elapsedMicroseconds,
      }),
    );
  }
}
