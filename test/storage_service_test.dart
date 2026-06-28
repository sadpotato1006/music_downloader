import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/models.dart';
import 'package:qingting/storage_service.dart';

void main() {
  test(
    'atomic JSON storage recovers settings library queue and playlists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-storage-',
      );
      final storage = StorageService(supportDirectory: directory);
      final separator = Platform.pathSeparator;
      final firstTrack = DownloadedTrack(
        id: 'first',
        title: 'First Song',
        artist: 'Artist',
        path: 'first.mp3',
        format: 'mp3',
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        sourceUrl: 'https://example.test/first',
      );
      final secondTrack = DownloadedTrack(
        id: 'second',
        title: 'Second Song',
        artist: 'Artist',
        path: 'second.mp3',
        format: 'mp3',
        downloadedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        sourceUrl: 'https://example.test/second',
      );
      const firstQueueItem = PlayerItem(
        id: 'first',
        title: 'First Song',
        artist: 'Artist',
        uri: 'https://example.test/first.mp3',
      );
      const secondQueueItem = PlayerItem(
        id: 'second',
        title: 'Second Song',
        artist: 'Artist',
        uri: 'https://example.test/second.mp3',
      );

      try {
        await storage.saveSettings(
          const AppSettings(
            downloadDirectory: 'first-directory',
            sourceSearchHistory: ['first'],
          ),
        );
        await storage.saveSettings(
          const AppSettings(
            downloadDirectory: 'second-directory',
            sourceSearchHistory: ['second'],
          ),
        );
        await storage.saveDownloadedTracks([firstTrack]);
        await storage.saveDownloadedTracks([secondTrack]);
        await storage.saveMyMusic(
          const MyMusicData(favoriteTrackPaths: ['first.mp3']),
        );
        await storage.saveMyMusic(
          const MyMusicData(favoriteTrackPaths: ['second.mp3']),
        );
        await storage.savePlayerQueue(
          const [firstQueueItem],
          0,
          shuffleEnabled: false,
        );
        await storage.savePlayerQueue(
          const [secondQueueItem],
          0,
          shuffleEnabled: true,
        );

        for (final name in [
          'settings.json',
          'downloads.json',
          'my_music.json',
          'queue.json',
        ]) {
          await File(
            '${directory.path}$separator$name',
          ).writeAsString('{broken');
        }

        final settings = await storage.loadSettings();
        final tracks = await storage.loadDownloadedTracks();
        final myMusic = await storage.loadMyMusic();
        final queue = await storage.loadPlayerQueue();

        expect(settings.downloadDirectory, 'first-directory');
        expect(tracks.single.id, 'first');
        expect(myMusic.favoriteTrackPaths, ['first.mp3']);
        expect(queue.items.single.id, 'first');
        expect(queue.shuffleEnabled, isFalse);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('download tasks persist resume metadata', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-download-task-storage-',
    );
    final storage = StorageService(supportDirectory: directory);
    final task = DownloadTask(
      id: 'task-1',
      track: const TrackSearchResult(
        id: 'track-1',
        title: 'Song',
        artist: 'Artist',
        source: 'source',
        detailUrl: 'https://example.test/detail',
        duration: '3:20',
      ),
      candidate: const AudioCandidate(
        url: 'https://example.test/song.mp3',
        format: 'mp3',
        headers: {'Referer': 'https://example.test/'},
      ),
      status: DownloadStatus.paused,
      progress: 0.5,
      savePath: 'song.mp3',
      receivedBytes: 100,
      totalBytes: 200,
      resumeValidator: '"etag-1"',
      lyrics: '[00:01.00]Lyrics',
      album: 'Album',
    );

    try {
      await storage.saveDownloadTasks([task]);
      expect(
        await File(
          '${directory.path}${Platform.pathSeparator}download_tasks.json.bak',
        ).exists(),
        isTrue,
      );
      final restored = (await storage.loadDownloadTasks()).single;

      expect(restored.status, DownloadStatus.paused);
      expect(restored.receivedBytes, 100);
      expect(restored.totalBytes, 200);
      expect(restored.resumeValidator, '"etag-1"');
      expect(restored.candidate.headers['Referer'], 'https://example.test/');
      expect(restored.album, 'Album');
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
