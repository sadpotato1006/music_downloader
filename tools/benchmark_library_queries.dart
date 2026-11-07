import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qingting/library_query_worker.dart';
import 'package:qingting/models.dart';

// Synthetic metadata only: does not read user files or measure GPU/frame time.
// Run: dart run tools/benchmark_library_queries.dart
Future<void> main() async {
  for (final size in [1000, 10000]) {
    final tracks = List.generate(
      size,
      (i) => DownloadedTrack(
        id: '$i',
        title: '晴天与夜曲 $i',
        artist: '周杰伦',
        album: '测试专辑 $i',
        path: 'music/song-$i.mp3',
        format: 'mp3',
        sourceUrl: '',
        downloadedAt: DateTime(2026).add(Duration(seconds: i)),
      ),
    );
    final worker = LibraryQueryWorker();
    final clock = Stopwatch()..start();
    var lastTick = 0;
    var maxGap = 0;
    var ticks = 0;
    final heartbeat = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = clock.elapsedMicroseconds;
      final gap = now - lastTick;
      if (gap > maxGap) maxGap = gap;
      lastTick = now;
      ticks++;
    });
    try {
      final cold = Stopwatch()..start();
      final found = await worker.query(tracks, 'zjl', LibrarySortMode.titleAsc);
      cold.stop();
      final warm = Stopwatch()..start();
      await worker.query(tracks, 'yequ', LibrarySortMode.titleAsc);
      warm.stop();
      stdout.writeln(
        jsonEncode({
          'songs': size,
          'matches': found.metadataPaths.length,
          'coldMs': cold.elapsedMilliseconds,
          'warmMs': warm.elapsedMilliseconds,
          'mainIsolateTimerTicks': ticks,
          'maxTimerGapMs': maxGap / 1000,
        }),
      );
    } finally {
      heartbeat.cancel();
      worker.dispose();
    }
  }
}
