import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/album_metadata_service.dart';
import 'package:qingting/models.dart';
import 'package:qingting/pending_album_match.dart';
import 'package:qingting/storage_service.dart';

void main() {
  for (final fileName in [
    'settings.json',
    'downloads.json',
    'my_music.json',
    'queue.json',
    'download_tasks.json',
    'pending_album_matches.json',
  ]) {
    test(
      '$fileName corruption preserves both generations and blocks writes until repaired',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'qingting-corrupt-storage-',
        );
        final primary = File('${directory.path}/$fileName');
        final backup = File('${primary.path}.bak');
        final storage = StorageService(supportDirectory: directory);
        Future<Object> load() => switch (fileName) {
          'settings.json' => storage.loadSettings(),
          'downloads.json' => storage.loadDownloadedTracks(),
          'my_music.json' => storage.loadMyMusic(),
          'queue.json' => storage.loadPlayerQueue(),
          'download_tasks.json' => storage.loadDownloadTasks(),
          _ => storage.loadPendingAlbumMatches(),
        };
        final repaired = switch (fileName) {
          'settings.json' => '{"downloadDirectory":"music"}',
          'my_music.json' => '{}',
          'queue.json' => '{"items":[],"currentIndex":-1}',
          _ => '[]',
        };
        try {
          await primary.writeAsString('{broken-primary');
          await backup.writeAsString('{broken-backup');
          await expectLater(load(), throwsA(isA<StorageRecoveryException>()));
          await expectLater(
            storage.saveDownloadedTracks([]),
            throwsA(isA<StorageRecoveryException>()),
          );
          await expectLater(
            storage.saveDownloadTasks([]),
            throwsA(isA<StorageRecoveryException>()),
          );
          await expectLater(
            storage.saveMyMusic(const MyMusicData()),
            throwsA(isA<StorageRecoveryException>()),
          );
          expect(await primary.readAsString(), '{broken-primary');
          expect(await backup.readAsString(), '{broken-backup');
          await primary.writeAsString(repaired);
          await load();
          await storage.saveMyMusic(
            const MyMusicData(favoriteTrackPaths: ['song.mp3']),
          );
          expect((await storage.loadMyMusic()).favoriteTrackPaths, [
            'song.mp3',
          ]);
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test(
    'missing documents use first-run defaults, a corrupt primary without backup fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-first-run-storage-',
      );
      final storage = StorageService(supportDirectory: directory);
      try {
        expect(await storage.loadDownloadedTracks(), isEmpty);
        expect((await storage.loadMyMusic()).favoriteTrackPaths, isEmpty);
        expect((await storage.loadPlayerQueue()).items, isEmpty);
        expect(await storage.loadDownloadTasks(), isEmpty);
        expect(await storage.loadPendingAlbumMatches(), isEmpty);
        final file = File('${directory.path}/downloads.json');
        await file.writeAsString('{broken');
        await expectLater(
          storage.loadDownloadedTracks(),
          throwsA(isA<StorageRecoveryException>()),
        );
        expect(await file.readAsString(), '{broken');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('invalid record shapes cannot silently reset the library', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-schema-storage-',
    );
    final storage = StorageService(supportDirectory: directory);
    try {
      await File('${directory.path}/downloads.json').writeAsString('[42]');
      await expectLater(
        storage.loadDownloadedTracks(),
        throwsA(isA<StorageRecoveryException>()),
      );
      await File(
        '${directory.path}/my_music.json',
      ).writeAsString('{"playlists":[42]}');
      await expectLater(
        storage.loadMyMusic(),
        throwsA(isA<StorageRecoveryException>()),
      );
      await File(
        '${directory.path}/queue.json',
      ).writeAsString('{"items":[42]}');
      await expectLater(
        storage.loadPlayerQueue(),
        throwsA(isA<StorageRecoveryException>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'a readable backup remains intact when restoring the primary fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-restore-failure-',
      );
      final blocker = Directory('${directory.path}/downloads.json');
      final backup = File('${blocker.path}.bak');
      final storage = StorageService(supportDirectory: directory);
      try {
        await blocker.create();
        await backup.writeAsString('[]');
        await expectLater(
          storage.loadDownloadedTracks(),
          throwsA(
            isA<StorageRecoveryException>().having(
              (e) => e.backupAvailable,
              'readable backup',
              true,
            ),
          ),
        );
        expect(await backup.readAsString(), '[]');
        await expectLater(
          storage.saveDownloadedTracks([]),
          throwsA(isA<StorageRecoveryException>()),
        );
        await blocker.delete();
        expect(await storage.loadDownloadedTracks(), isEmpty);
        await storage.saveDownloadedTracks([]);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'large asynchronous saves preserve snapshots order and immediate flush',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-large-storage-',
      );
      final storage = StorageService(supportDirectory: directory);
      final tracks = List.generate(
        600,
        (i) => DownloadedTrack(
          id: 'song-$i',
          title: '歌曲$i',
          artist: '歌手',
          path: 'song-$i.mp3',
          format: 'mp3',
          downloadedAt: DateTime(2026, 10, 5),
          sourceUrl: '',
          metadataLyrics: '[00:01]中文歌词\n',
        ),
      );
      try {
        final firstSave = storage.saveDownloadedTracks(tracks);
        tracks[0] = tracks[0].copyWith(title: '新标题');
        final lastSave = storage.saveDownloadedTracks(tracks);
        tracks.clear();
        await storage.flushPendingWrites();
        await Future.wait([firstSave, lastSave]);
        final restored = await storage.loadDownloadedTracks();
        expect(restored, hasLength(600));
        expect(restored.first.title, '新标题');
        expect(restored.last.id, 'song-599');
        expect(restored.last.metadataLyrics, '[00:01]中文歌词\n');
        final backup =
            jsonDecode(
                  await File(
                    '${directory.path}/downloads.json.bak',
                  ).readAsString(),
                )
                as List;
        expect(backup.first['title'], '歌曲0');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'large queue and playlist saves freeze their nested snapshots',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-large-music-storage-',
      );
      final storage = StorageService(supportDirectory: directory);
      final items = List.generate(
        600,
        (i) => PlayerItem(
          id: 'song-$i',
          title: '歌曲$i',
          artist: '歌手',
          uri: 'file:///song-$i.mp3',
          lyrics: '[00:01]中文歌词\n',
        ),
      );
      final paths = List.generate(600, (i) => 'song-$i.mp3');
      try {
        final queueSave = storage.savePlayerQueue(
          items,
          599,
          shuffleEnabled: true,
        );
        final musicSave = storage.saveMyMusic(
          MyMusicData(
            favoriteTrackPaths: paths,
            playlists: [
              MusicPlaylist(
                id: 'playlist',
                name: '歌单',
                trackPaths: paths,
                createdAt: DateTime(2026, 10, 5),
              ),
            ],
          ),
        );
        items.clear();
        paths.clear();
        await storage.flushPendingWrites();
        await Future.wait([queueSave, musicSave]);
        final queue = await storage.loadPlayerQueue();
        final music = await storage.loadMyMusic();
        expect(queue.items, hasLength(600));
        expect(queue.items.last.lyrics, '[00:01]中文歌词\n');
        expect(queue.currentIndex, 599);
        expect(queue.shuffleEnabled, isTrue);
        expect(music.favoriteTrackPaths, hasLength(600));
        expect(music.playlists.single.trackPaths.last, 'song-599.mp3');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('JSON is compact and preserves Unicode and multiline text', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-compact-json-',
    );
    final storage = StorageService(supportDirectory: directory);
    const item = PlayerItem(
      id: 'song',
      title: '中文歌名',
      artist: '歌手',
      uri: 'file:///song.mp3',
      lyrics: '[00:01.00]第一句\n[00:02.00]第二句',
    );
    try {
      await storage.savePlayerQueue([item], 0, shuffleEnabled: true);
      final text = await File(
        '${directory.path}${Platform.pathSeparator}queue.json',
      ).readAsString();
      expect(text, jsonEncode(jsonDecode(text)));
      expect(text, isNot(contains('\n')));
      final restored = await storage.loadPlayerQueue();
      expect(restored.items.single.title, item.title);
      expect(restored.items.single.lyrics, item.lyrics);
      expect(
        await File(
          '${directory.path}${Platform.pathSeparator}queue.json.bak',
        ).exists(),
        isTrue,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test(
    'an immediate flush includes writes waiting for their directory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-flush-storage-',
      );
      final storage = StorageService(supportDirectory: directory);
      try {
        final saves = [
          storage.saveSettings(const AppSettings(downloadDirectory: 'first')),
          storage.saveSettings(const AppSettings(downloadDirectory: 'latest')),
          storage.saveMyMusic(
            const MyMusicData(favoriteTrackPaths: ['song.mp3']),
          ),
        ];
        await storage.flushPendingWrites();
        final reloaded = StorageService(supportDirectory: directory);
        expect((await reloaded.loadSettings()).downloadDirectory, 'latest');
        expect((await reloaded.loadMyMusic()).favoriteTrackPaths, ['song.mp3']);
        await Future.wait(saves);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('failed storage flush does not block a later retry', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-flush-failure-',
    );
    final path = '${directory.path}${Platform.pathSeparator}blocked';
    final blocker = File(path);
    await blocker.writeAsString('not a directory');
    final storage = StorageService(supportDirectory: Directory(path));
    try {
      final save = storage.saveSettings(
        const AppSettings(downloadDirectory: 'music'),
      );
      await Future.wait([
        expectLater(save, throwsA(isA<FileSystemException>())),
        expectLater(
          storage.flushPendingWrites(),
          throwsA(isA<FileSystemException>()),
        ),
      ]);
      await blocker.delete();
      await storage.saveSettings(
        const AppSettings(downloadDirectory: 'recovered'),
      );
      await storage.flushPendingWrites();
      expect((await storage.loadSettings()).downloadDirectory, 'recovered');
    } finally {
      await directory.delete(recursive: true);
    }
  });

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
        durationMs: 201000,
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
        expect(tracks.single.durationMs, 201000);
        expect(myMusic.favoriteTrackPaths, ['first.mp3']);
        expect(queue.items.single.id, 'first');
        expect(queue.shuffleEnabled, isFalse);
        final preserved = await directory
            .list()
            .where((file) => file.path.contains('.corrupt-'))
            .toList();
        expect(preserved, hasLength(4));
        for (final file in preserved.cast<File>()) {
          expect(await file.readAsString(), '{broken');
        }
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

  test('unique save path skips paths reserved by queued downloads', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-reserved-download-path-',
    );
    final storage = StorageService(supportDirectory: directory);
    final basePath =
        '${directory.path}${Platform.pathSeparator}Artist - Song.mp3';

    try {
      final savePath = await storage.uniqueSavePath(
        downloadDirectory: directory.path,
        title: 'Song',
        artist: 'Artist',
        format: 'mp3',
        reservedPaths: [basePath],
      );

      expect(
        savePath,
        '${directory.path}${Platform.pathSeparator}Artist - Song (1).mp3',
      );
      expect(await File(basePath).exists(), isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('pending album candidates persist all review evidence', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-pending-album-storage-',
    );
    final storage = StorageService(supportDirectory: directory);
    final pending = PendingAlbumMatch(
      trackId: 'track-1',
      trackPath: 'song.mp3',
      title: 'Song',
      artist: 'Artist',
      candidates: const [
        AlbumMetadataMatch(
          album: 'Album',
          recordingTitle: 'Song',
          recordingArtist: 'Artist',
          score: 91.5,
          recordingId: 'apple:1',
          releaseId: 'apple:2',
          releaseDate: '2020-01-01',
          titleSimilarity: 0.98,
          artistSimilarity: 0.97,
          durationVerified: true,
          hasCrossSourceAgreement: true,
        ),
      ],
    );

    try {
      await storage.savePendingAlbumMatches([pending]);
      final restored = (await storage.loadPendingAlbumMatches()).single;

      expect(restored.trackPath, pending.trackPath);
      expect(restored.candidates.single.album, 'Album');
      expect(restored.candidates.single.score, 91.5);
      expect(restored.candidates.single.durationVerified, isTrue);
      expect(restored.candidates.single.hasCrossSourceAgreement, isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('cover cache cleanup preserves referenced and recent files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-cover-cache-',
    );
    final storage = StorageService(supportDirectory: directory);
    final covers = Directory(
      '${directory.path}${Platform.pathSeparator}covers',
    );

    try {
      await covers.create(recursive: true);
      final retained = File(
        '${covers.path}${Platform.pathSeparator}retained.jpg',
      );
      final orphan = File('${covers.path}${Platform.pathSeparator}orphan.jpg');
      final recent = File('${covers.path}${Platform.pathSeparator}recent.jpg');
      await retained.writeAsBytes([1]);
      await orphan.writeAsBytes([2]);
      await recent.writeAsBytes([3]);
      final old = DateTime.now().subtract(const Duration(days: 2));
      await retained.setLastModified(old);
      await orphan.setLastModified(old);

      final removed = await storage.cleanupCachedCovers([retained.path]);

      expect(removed, 1);
      expect(await retained.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
      expect(await recent.exists(), isTrue);
      expect(await storage.deleteCachedCover(retained.path), isTrue);
      expect(await retained.exists(), isFalse);
      expect(
        await storage.deleteCachedCover(
          '${directory.path}${Platform.pathSeparator}outside.jpg',
        ),
        isFalse,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
