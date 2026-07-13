import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/album_metadata_service.dart';
import 'package:qingting/app_controller.dart';
import 'package:qingting/app_info.dart';
import 'package:qingting/app_log.dart';
import 'package:qingting/file_deletion_service.dart';
import 'package:qingting/id3_lyrics_embedder.dart';
import 'package:qingting/lyrics_service.dart';
import 'package:qingting/main.dart' as app;
import 'package:qingting/models.dart';
import 'package:qingting/music_source.dart';
import 'package:qingting/player_service.dart';
import 'package:qingting/pending_album_match.dart';
import 'package:qingting/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('first play toggle opens a restored queue item', () async {
    final player = _FakePlaybackService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: player,
    );
    const item = PlayerItem(
      id: 'restored-track',
      title: 'Restored Track',
      artist: 'Artist',
      uri: 'https://example.test/audio.mp3',
    );
    controller.queue = [item];
    controller.currentQueueIndex = 0;

    await controller.togglePlayPause();

    expect(player.openCalls, 1);
    expect(player.playOrPauseCalls, 0);
    expect(player.openedItem, same(item));

    await controller.togglePlayPause();

    expect(player.openCalls, 1);
    expect(player.playOrPauseCalls, 1);

    controller.dispose();
  });

  test('finishing the queue starts a newly shuffled round', () async {
    final player = _FakePlaybackService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: player,
    );
    const first = PlayerItem(
      id: 'first',
      title: 'First',
      artist: 'Artist',
      uri: 'https://example.test/first.mp3',
    );
    const second = PlayerItem(
      id: 'second',
      title: 'Second',
      artist: 'Artist',
      uri: 'https://example.test/second.mp3',
    );
    const third = PlayerItem(
      id: 'third',
      title: 'Third',
      artist: 'Artist',
      uri: 'https://example.test/third.mp3',
    );
    controller.queue = [first, second, third];
    controller.currentQueueIndex = 2;
    controller.shuffleEnabled = false;

    await controller.playNext();

    expect(controller.currentQueueIndex, 0);
    expect(controller.shuffleEnabled, isTrue);
    expect(controller.currentItem, isNot(third));
    expect(controller.queue.map((item) => item.id).toSet(), {
      'first',
      'second',
      'third',
    });
    expect(player.openedItem, controller.currentItem);
    controller.dispose();
  });

  test('rapid next requests share one queue transition', () async {
    final player = _FakePlaybackService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: player,
    );
    controller.queue = const [
      PlayerItem(
        id: 'first',
        title: 'First',
        artist: 'Artist',
        uri: 'https://example.test/first.mp3',
      ),
      PlayerItem(
        id: 'second',
        title: 'Second',
        artist: 'Artist',
        uri: 'https://example.test/second.mp3',
      ),
      PlayerItem(
        id: 'third',
        title: 'Third',
        artist: 'Artist',
        uri: 'https://example.test/third.mp3',
      ),
    ];
    controller.currentQueueIndex = 2;

    await Future.wait([controller.playNext(), controller.playNext()]);

    expect(controller.currentQueueIndex, 0);
    expect(player.openCalls, 1);
    expect(player.openedItem, controller.currentItem);
    controller.dispose();
  });

  test('queue persistence failure does not prevent playback', () async {
    final player = _FakePlaybackService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FailingQueueStorageService(),
      player: player,
    );
    const item = PlayerItem(
      id: 'play-despite-save-error',
      title: 'Playable',
      artist: 'Artist',
      uri: 'https://example.test/playable.mp3',
    );
    controller.queue = [item];

    await controller.playQueueAt(0);

    expect(player.openedItem, item);
    expect(controller.globalMessage, contains('播放队列保存失败'));
    controller.dispose();
  });

  test('a single-item queue starts another round after completion', () async {
    final player = _FakePlaybackService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: player,
    );
    const item = PlayerItem(
      id: 'only',
      title: 'Only',
      artist: 'Artist',
      uri: 'https://example.test/only.mp3',
    );
    controller.queue = [item];
    controller.currentQueueIndex = 0;

    player.onCompleted?.call();
    await Future<void>.delayed(Duration.zero);

    expect(controller.currentQueueIndex, 0);
    expect(player.openCalls, 1);
    expect(player.openedItem, item);
    controller.dispose();
  });

  test(
    'removing the current shuffled item hydrates the next embedded lyrics',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-remove-current-lyrics-',
      );
      final firstFile = File(
        '${directory.path}${Platform.pathSeparator}first.mp3',
      );
      final secondFile = File(
        '${directory.path}${Platform.pathSeparator}second.mp3',
      );
      final player = _FakePlaybackService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: _FakeStorageService(),
        player: player,
      );

      try {
        await firstFile.writeAsBytes(const [0xFF, 0xFB, 0x90, 0x64]);
        await secondFile.writeAsBytes(const [0xFF, 0xFB, 0x90, 0x64]);
        await Id3LyricsEmbedder.embedMetadata(
          firstFile,
          title: 'First',
          artist: 'Artist',
          lyrics: '[00:01.00]First lyric',
        );
        await Id3LyricsEmbedder.embedMetadata(
          secondFile,
          title: 'Second',
          artist: 'Artist',
          lyrics: '[00:01.00]Second lyric',
        );
        controller.downloadedTracks = [
          DownloadedTrack(
            id: 'first',
            title: 'First',
            artist: 'Artist',
            path: firstFile.path,
            format: 'mp3',
            downloadedAt: DateTime(2026),
            sourceUrl: '',
            album: 'Album',
          ),
          DownloadedTrack(
            id: 'second',
            title: 'Second',
            artist: 'Artist',
            path: secondFile.path,
            format: 'mp3',
            downloadedAt: DateTime(2026),
            sourceUrl: '',
            album: 'Album',
          ),
        ];

        await controller.startRandomLibraryPlayback();

        expect(controller.queue, hasLength(2));
        expect(controller.queue.first.lyrics, isNotEmpty);
        expect(controller.queue.last.lyrics, isNull);

        await controller.removeQueueAt(0);

        expect(controller.currentQueueIndex, 0);
        expect(controller.currentItem?.lyrics, isNotEmpty);
        expect(player.openedItem?.lyrics, controller.currentItem?.lyrics);
        expect(player.openCalls, 2);
      } finally {
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('switches music source and repeats the current search', () async {
    final sourceA = _SearchMusicSource('source-a', '来源 A');
    final sourceB = _SearchMusicSource('source-b', '来源 B');
    final controller = AppController(
      source: sourceA,
      sources: [sourceA, sourceB],
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );

    await controller.search('晴天');
    await controller.switchToNextSource();

    expect(controller.source, same(sourceB));
    expect(controller.searchResults.single.source, '来源 B');
    expect(sourceA.searchCalls, 1);
    expect(sourceB.searchCalls, 1);

    controller.dispose();
  });

  test('only the latest overlapping search can update results', () async {
    final source = _ControlledSearchMusicSource();
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );

    final olderSearch = controller.search('旧关键词');
    await source.waitForCalls(1);
    final newerSearch = controller.search('新关键词');
    source.complete(0, keyword: '旧关键词');
    await source.waitForCalls(2);
    source.complete(1, keyword: '新关键词');
    await Future.wait([olderSearch, newerSearch]);

    expect(controller.searchQuery, '新关键词');
    expect(controller.searchResults.single.title, '新关键词');
    expect(controller.searchError, isNull);
    expect(controller.isSearching, isFalse);
    controller.dispose();
  });

  test('disposing during search ignores the late response', () async {
    final source = _ControlledSearchMusicSource();
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );

    final search = controller.search('稍后返回');
    await source.waitForCalls(1);
    controller.dispose();
    source.complete(0, keyword: '稍后返回');

    await search;
  });

  test('prevents adding the same track to the download queue twice', () async {
    final source = _PlayableMusicSource();
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    final result = source.result;
    controller.downloadTasks = [
      DownloadTask(
        id: 'existing-task',
        track: result,
        candidate: const AudioCandidate(
          url: 'https://example.test/song.mp3',
          format: 'mp3',
        ),
        status: DownloadStatus.downloading,
        progress: 0.5,
        savePath: 'song.mp3',
      ),
    ];

    final start = await controller.startDownload(result);

    expect(start.didFail, isTrue);
    expect(start.message, contains('已在下载队列中'));
    expect(source.loadCalls, 0);
    controller.dispose();
  });

  test('bootstrap restores a saved disabled shuffle mode', () async {
    const item = PlayerItem(
      id: 'saved-item',
      title: 'Saved Song',
      artist: 'Saved Artist',
      uri: 'https://example.test/saved.mp3',
    );
    final storage = _BootstrapStorageService(
      queue: const SavedPlayerQueue(
        items: [item],
        currentIndex: 0,
        shuffleEnabled: false,
      ),
    );
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: storage,
      player: _FakePlaybackService(),
    );

    await controller.bootstrap();

    expect(controller.bootstrapStatus, AppBootstrapStatus.ready);
    expect(controller.shuffleEnabled, isFalse);
    controller.dispose();
  });

  test(
    'bootstrap restores valid pending album reviews and removes stale ones',
    () async {
      final validTrack = DownloadedTrack(
        id: 'valid',
        title: 'Valid Song',
        artist: 'Artist',
        path: 'valid.mp3',
        format: 'mp3',
        downloadedAt: DateTime(2026, 7, 11),
        sourceUrl: '',
      );
      final completedTrack = DownloadedTrack(
        id: 'completed',
        title: 'Completed Song',
        artist: 'Artist',
        path: 'completed.mp3',
        format: 'mp3',
        downloadedAt: DateTime(2026, 7, 11),
        sourceUrl: '',
        album: 'Existing Album',
      );
      PendingAlbumMatch pendingFor(DownloadedTrack track) => PendingAlbumMatch(
        trackId: track.id,
        trackPath: track.path,
        title: track.title,
        artist: track.artist,
        candidates: const [
          AlbumMetadataMatch(
            album: 'Candidate Album',
            recordingTitle: 'Valid Song',
            recordingArtist: 'Artist',
            score: 90,
          ),
        ],
      );
      final storage = _BootstrapStorageService(
        tracks: [validTrack, completedTrack],
        pendingAlbumMatches: [
          pendingFor(validTrack),
          pendingFor(completedTrack),
        ],
      );
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: _FakePlaybackService(),
      );

      await controller.bootstrap();
      await controller.flushPendingWrites();

      expect(controller.pendingAlbumMatches, hasLength(1));
      expect(controller.pendingAlbumMatches.single.trackId, 'valid');
      expect(storage.savedPendingAlbumMatches, hasLength(1));
      controller.dispose();
    },
  );

  test('bootstrap exposes failure state and can retry', () async {
    final storage = _RetryBootstrapStorageService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: storage,
      player: _FakePlaybackService(),
    );

    await controller.bootstrap();

    expect(controller.bootstrapStatus, AppBootstrapStatus.error);
    expect(controller.bootstrapError, isNotEmpty);
    expect(controller.isReady, isFalse);

    await controller.bootstrap();

    expect(storage.loadSettingsCalls, 2);
    expect(controller.bootstrapStatus, AppBootstrapStatus.ready);
    expect(controller.bootstrapError, isNull);
    expect(controller.isReady, isTrue);
    controller.dispose();
  });

  test('flushPendingWrites saves the latest debounced settings once', () async {
    final storage = _RecordingSettingsStorageService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: storage,
      player: _FakePlaybackService(),
    );
    controller.settings = const AppSettings(downloadDirectory: 'music');

    await controller.setVolume(37);
    controller.setDesktopLyricsSettings(
      const DesktopLyricsSettings(enabled: true, fontSize: 28),
    );

    expect(storage.saveSettingsCalls, 0);
    await controller.flushPendingWrites();

    expect(storage.saveSettingsCalls, 1);
    expect(storage.lastSettings?.volume, 37);
    expect(storage.lastSettings?.desktopLyrics.enabled, isTrue);
    expect(storage.lastSettings?.desktopLyrics.fontSize, 28);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(storage.saveSettingsCalls, 1);
    controller.dispose();
  });

  test('bootstrap pauses an interrupted persisted download', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-restored-download-',
    );
    final savePath = '${directory.path}${Platform.pathSeparator}partial.m4a';
    await File(savePath).writeAsBytes(const [1, 2, 3]);
    final source = _AlbumDownloadMusicSource();
    final interrupted = DownloadTask(
      id: 'interrupted-task',
      track: source.result,
      candidate: const AudioCandidate(
        url: 'https://example.test/test.m4a',
        format: 'm4a',
      ),
      status: DownloadStatus.downloading,
      progress: 0.1,
      savePath: savePath,
      receivedBytes: 1,
      totalBytes: 6,
    );
    final storage = _BootstrapStorageService(tasks: [interrupted]);
    final controller = AppController(
      source: source,
      storage: storage,
      player: _FakePlaybackService(),
    );

    try {
      await controller.bootstrap();

      final restored = controller.downloadTasks.single;
      expect(restored.status, DownloadStatus.paused);
      expect(restored.receivedBytes, 3);
      expect(restored.progress, 0.5);
      expect(storage.savedTasks.single.status, DownloadStatus.paused);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('resume download appends a valid HTTP range response', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-range-download-',
    );
    final savePath = '${directory.path}${Platform.pathSeparator}resume.m4a';
    await File(savePath).writeAsBytes(const [1, 2, 3]);
    final source = _AlbumDownloadMusicSource();
    final adapter = _RangeAudioDownloadAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final controller = AppController(
      source: source,
      storage: _DownloadStorageService(savePath),
      player: _FakePlaybackService(),
      downloadDio: dio,
      albumMetadata: _RecordingAlbumMetadataService(),
    );
    controller.downloadTasks = [
      DownloadTask(
        id: 'range-task',
        track: source.result,
        candidate: const AudioCandidate(
          url: 'https://example.test/test.m4a',
          format: 'm4a',
        ),
        status: DownloadStatus.paused,
        progress: 0.5,
        savePath: savePath,
        receivedBytes: 3,
        totalBytes: 6,
      ),
    ];

    try {
      controller.retryDownload('range-task');
      for (var attempt = 0; attempt < 100; attempt += 1) {
        final status = controller.downloadTasks.single.status;
        if (status == DownloadStatus.completed ||
            status == DownloadStatus.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final task = controller.downloadTasks.single;
      expect(task.status, DownloadStatus.completed, reason: task.error);
      expect(adapter.rangeHeader, 'bytes=3-');
      expect(await File(savePath).readAsBytes(), const [1, 2, 3, 4, 5, 6]);
      expect(task.resumeValidator, '"range-etag"');
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('resume download overwrites when the server ignores range', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-range-fallback-',
    );
    final savePath = '${directory.path}${Platform.pathSeparator}fallback.m4a';
    await File(savePath).writeAsBytes(const [1, 2, 3]);
    final source = _AlbumDownloadMusicSource();
    final adapter = _RangeAudioDownloadAdapter(
      statusCode: 200,
      payload: const [7, 8],
      contentRange: null,
    );
    final controller = AppController(
      source: source,
      storage: _DownloadStorageService(savePath),
      player: _FakePlaybackService(),
      downloadDio: Dio()..httpClientAdapter = adapter,
      albumMetadata: _RecordingAlbumMetadataService(),
    );
    controller.downloadTasks = [
      DownloadTask(
        id: 'range-fallback-task',
        track: source.result,
        candidate: const AudioCandidate(
          url: 'https://example.test/test.m4a',
          format: 'm4a',
        ),
        status: DownloadStatus.paused,
        progress: 0.5,
        savePath: savePath,
        receivedBytes: 3,
        totalBytes: 6,
      ),
    ];

    try {
      controller.retryDownload('range-fallback-task');
      for (var attempt = 0; attempt < 100; attempt += 1) {
        final status = controller.downloadTasks.single.status;
        if (status == DownloadStatus.completed ||
            status == DownloadStatus.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final task = controller.downloadTasks.single;
      expect(task.status, DownloadStatus.completed, reason: task.error);
      expect(adapter.rangeHeader, 'bytes=3-');
      expect(await File(savePath).readAsBytes(), const [7, 8]);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test(
    'oversized local range file is discarded and downloaded again',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-range-oversized-',
      );
      final savePath =
          '${directory.path}${Platform.pathSeparator}oversized.m4a';
      await File(savePath).writeAsBytes(const [1, 2, 3, 4, 5, 6, 7, 8]);
      final source = _AlbumDownloadMusicSource();
      final adapter = _Range416ThenFullDownloadAdapter();
      final controller = AppController(
        source: source,
        storage: _DownloadStorageService(savePath),
        player: _FakePlaybackService(),
        downloadDio: Dio()..httpClientAdapter = adapter,
        albumMetadata: _RecordingAlbumMetadataService(),
      );
      controller.downloadTasks = [
        DownloadTask(
          id: 'range-oversized-task',
          track: source.result,
          candidate: const AudioCandidate(
            url: 'https://example.test/test.m4a',
            format: 'm4a',
          ),
          status: DownloadStatus.paused,
          progress: 1,
          savePath: savePath,
          receivedBytes: 8,
          totalBytes: 6,
        ),
      ];

      try {
        controller.retryDownload('range-oversized-task');
        for (var attempt = 0; attempt < 100; attempt += 1) {
          final status = controller.downloadTasks.single.status;
          if (status == DownloadStatus.completed ||
              status == DownloadStatus.failed) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final task = controller.downloadTasks.single;
        expect(task.status, DownloadStatus.completed, reason: task.error);
        expect(adapter.calls, 2);
        expect(adapter.firstRangeHeader, 'bytes=8-');
        expect(await File(savePath).readAsBytes(), const [9, 8, 7, 6, 5, 4]);
      } finally {
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('short download response is rejected as incomplete', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-short-download-',
    );
    final savePath = '${directory.path}${Platform.pathSeparator}short.m4a';
    final source = _AlbumDownloadMusicSource();
    final controller = AppController(
      source: source,
      storage: _DownloadStorageService(savePath),
      player: _FakePlaybackService(),
      downloadDio: Dio()..httpClientAdapter = _ShortAudioDownloadAdapter(),
      albumMetadata: _RecordingAlbumMetadataService(),
    );

    try {
      final start = await controller.startDownload(
        source.result,
        allowNonMp3: true,
      );
      expect(start.didStart, isTrue);
      for (var attempt = 0; attempt < 100; attempt += 1) {
        final status = controller.downloadTasks.single.status;
        if (status == DownloadStatus.completed ||
            status == DownloadStatus.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final task = controller.downloadTasks.single;
      expect(task.status, DownloadStatus.failed);
      expect(task.error, contains('下载响应提前结束'));
      expect(controller.downloadedTracks, isEmpty);
      expect(await File(savePath).readAsBytes(), const [1, 2, 3]);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('pause and immediate retry never runs the same task twice', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-single-download-worker-',
    );
    final savePath =
        '${directory.path}${Platform.pathSeparator}single-worker.m4a';
    final source = _ControlledDeferredDownloadSource();
    final adapter = _CountingAudioDownloadAdapter();
    final controller = AppController(
      source: source,
      storage: _DownloadStorageService(savePath),
      player: _FakePlaybackService(),
      downloadDio: Dio()..httpClientAdapter = adapter,
      albumMetadata: _RecordingAlbumMetadataService(),
    );
    controller.settings = const AppSettings(
      downloadDirectory: '',
      concurrentDownloads: 2,
    );
    controller.downloadTasks = [
      DownloadTask(
        id: 'single-worker-task',
        track: source.result,
        candidate: const AudioCandidate(
          url: 'deferred-download://prepare',
          format: 'm4a',
        ),
        status: DownloadStatus.paused,
        progress: 0,
        savePath: savePath,
        lyrics: '[00:01.00]测试歌词',
      ),
    ];

    try {
      controller.retryDownload('single-worker-task');
      await source.firstPreparationStarted.future;

      controller.pauseDownload('single-worker-task');
      controller.retryDownload('single-worker-task');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(source.prepareCalls, 1);
      expect(source.maxConcurrentPreparations, 1);
      expect(adapter.calls, 0);

      source.finishFirstPreparation();
      for (var attempt = 0; attempt < 100; attempt += 1) {
        final status = controller.downloadTasks.single.status;
        if (status == DownloadStatus.completed ||
            status == DownloadStatus.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final task = controller.downloadTasks.single;
      expect(task.status, DownloadStatus.completed, reason: task.error);
      expect(source.maxConcurrentPreparations, 1);
      expect(adapter.calls, 1);
    } finally {
      controller.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('cancel during cover processing never becomes completed', () async {
    final directory = await Directory.systemTemp.createTemp(
      'qingting-cancel-post-processing-',
    );
    final savePath =
        '${directory.path}${Platform.pathSeparator}cancel-cover.mp3';
    final source = _CoverDownloadMusicSource();
    final adapter = _ControlledCoverDownloadAdapter();
    final controller = AppController(
      source: source,
      storage: _DownloadStorageService(savePath),
      player: _FakePlaybackService(),
      downloadDio: Dio()..httpClientAdapter = adapter,
      albumMetadata: _RecordingAlbumMetadataService(),
    );

    try {
      final start = await controller.startDownload(source.result);
      expect(start.didStart, isTrue);
      await adapter.coverRequestStarted.future;
      expect(
        controller.downloadTasks.single.status,
        DownloadStatus.downloading,
      );

      controller.cancelDownload(controller.downloadTasks.single.id);
      expect(controller.downloadTasks.single.status, DownloadStatus.canceled);
      adapter.finishCoverRequest();

      for (var attempt = 0; attempt < 100; attempt += 1) {
        if (!await File(savePath).exists()) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(controller.downloadTasks.single.status, DownloadStatus.canceled);
      expect(controller.downloadedTracks, isEmpty);
      expect(await File(savePath).exists(), isFalse);
    } finally {
      if (!adapter.coverRequestFinished.isCompleted) {
        adapter.finishCoverRequest();
      }
      controller.dispose();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });

  test(
    'download replaces a source album with the default Apple match',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'qingting-album-match-',
      );
      final savePath =
          '${directory.path}${Platform.pathSeparator}album-match.m4a';
      final source = _AlbumDownloadMusicSource();
      final albumMetadata = _RecordingAlbumMetadataService();
      final dio = Dio()..httpClientAdapter = const _AudioDownloadAdapter();
      final controller = AppController(
        source: source,
        storage: _DownloadStorageService(savePath),
        player: _FakePlaybackService(),
        downloadDio: dio,
        albumMetadata: albumMetadata,
      );

      try {
        final start = await controller.startDownload(
          source.result,
          allowNonMp3: true,
        );
        expect(start.didStart, isTrue);

        for (var attempt = 0; attempt < 100; attempt += 1) {
          final status = controller.downloadTasks.single.status;
          if (status == DownloadStatus.completed ||
              status == DownloadStatus.failed) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        final task = controller.downloadTasks.single;
        expect(task.status, DownloadStatus.completed, reason: task.error);
        expect(albumMetadata.calls, 1);
        expect(
          albumMetadata.receivedDuration,
          const Duration(minutes: 3, seconds: 20),
        );
        expect(task.album, 'Apple Album');
        expect(controller.downloadedTracks.single.album, 'Apple Album');
        expect(controller.downloadedTracks.single.durationMs, 200000);
      } finally {
        controller.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('online playback resolves lyrics and reports playback state', () async {
    final source = _PlayableMusicSource();
    final player = _FakePlaybackService();
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: player,
      lyricsService: _FakeLyricsService(),
    );

    await controller.playSearchResult(source.result);

    expect(player.openCalls, 1);
    expect(player.openedItem?.uri, 'https://example.test/generated.mp3');
    expect(player.openedItem?.lyrics, contains('[00:01.00]测试歌词'));
    expect(controller.globalMessage, '已开始播放：测试歌曲');
    controller.dispose();
  });

  test('pauses only when bluetooth changes during playback', () async {
    final player = _FakePlaybackService()..isPlaying = true;
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: player,
    );

    await controller.handleBluetoothAudioRouteChanged();

    expect(player.pauseCalls, 1);
    expect(player.isPlaying, isFalse);

    await controller.handleBluetoothAudioRouteChanged();

    expect(player.pauseCalls, 1);
    controller.dispose();
  });

  testWidgets('clicking source search history starts a search', (tester) async {
    final source = _SearchMusicSource('source-a', '来源 A');
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    controller.settings = const AppSettings(
      downloadDirectory: '',
      sourceSearchHistory: ['晴天'],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.SearchPage(controller: controller)),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    final historyItem = find.text('晴天');
    expect(historyItem, findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(historyItem));
    await tester.pump();
    expect(historyItem, findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(source.searchCalls, 1);
    expect(source.lastKeyword, '晴天');
    controller.dispose();
  });

  testWidgets('home shell refreshes the active page from controller changes', (
    tester,
  ) async {
    final source = _SearchMusicSource('source-a', '来源 A');
    final controller = AppController(
      source: source,
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    controller.settings = const AppSettings(downloadDirectory: '');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: app.HomeShell(controller: controller)),
    );
    expect(find.text('输入关键词开始搜索'), findsOneWidget);

    await controller.search('主动刷新');
    await tester.pump();

    expect(find.text('主动刷新'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
  });

  test(
    'directory scan imports supported files once and ignores other files',
    () async {
      final directory = Directory.systemTemp.createTempSync('qingting-scan-');
      final first = File(
        '${directory.path}${Platform.pathSeparator}歌手甲 - 歌曲甲.m4a',
      )..writeAsBytesSync(const [1, 2, 3]);
      final nested = Directory(
        '${directory.path}${Platform.pathSeparator}nested',
      )..createSync();
      final second = File(
        '${nested.path}${Platform.pathSeparator}歌手乙 - 歌曲乙.flac',
      )..writeAsBytesSync(const [4, 5, 6]);
      File(
        '${directory.path}${Platform.pathSeparator}说明.txt',
      ).writeAsStringSync('ignore');
      final storage = _FakeStorageService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: _FakePlaybackService(),
      );
      controller.settings = AppSettings(downloadDirectory: directory.path);
      addTearDown(() {
        controller.dispose();
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });

      expect(await controller.scanCurrentDownloadDirectory(), 2);
      expect(
        controller.downloadedTracks.map((track) => track.path),
        containsAll([first.path, second.path]),
      );
      expect(storage.savedDownloadedTracks, hasLength(2));

      expect(await controller.scanCurrentDownloadDirectory(), 0);
      expect(controller.downloadedTracks, hasLength(2));
    },
  );

  test(
    'album scan keeps ambiguous results for review and isolates failures',
    () async {
      final directory = Directory.systemTemp.createTempSync('qingting-albums-');
      final tracks = <DownloadedTrack>[];
      for (final title in ['自动匹配', '需要确认', '没有结果', '请求失败']) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}$title.m4a',
        )..writeAsBytesSync(const [1, 2, 3]);
        tracks.add(
          DownloadedTrack(
            id: title,
            title: title,
            artist: '测试歌手',
            path: file.path,
            format: 'm4a',
            downloadedAt: DateTime(2026, 7, 11),
            sourceUrl: '',
            durationMs: 200000,
          ),
        );
      }
      final storage = _FakeStorageService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: _FakePlaybackService(),
        albumMetadata: _BatchAlbumMetadataService(),
      );
      controller.downloadedTracks = tracks;
      addTearDown(() {
        controller.dispose();
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });

      expect(await controller.matchMissingDownloadedAlbums(), 1);
      expect(controller.albumMatchProcessed, 4);
      expect(controller.albumMatchUpdated, 1);
      expect(controller.albumMatchNotFound, 1);
      expect(controller.albumMatchFailed, 1);
      expect(controller.pendingAlbumMatches, hasLength(1));
      expect(
        controller.downloadedTracks
            .firstWhere((track) => track.id == '自动匹配')
            .album,
        '可靠专辑',
      );
      expect(
        controller.downloadedTracks
            .firstWhere((track) => track.id == '需要确认')
            .album,
        isEmpty,
      );
      expect(storage.savedDownloadedTracks, hasLength(4));
      expect(storage.savedPendingAlbumMatches, hasLength(1));

      final pending = controller.pendingAlbumMatches.single;
      expect(
        await controller.applyPendingAlbumMatch(
          pending,
          pending.candidates.single,
        ),
        isTrue,
      );
      expect(controller.pendingAlbumMatches, isEmpty);
      await controller.flushPendingWrites();
      expect(storage.savedPendingAlbumMatches, isEmpty);
      expect(
        controller.downloadedTracks
            .firstWhere((track) => track.id == '需要确认')
            .album,
        '候选专辑',
      );
    },
  );

  test('album scan cancellation stops after the active request', () async {
    final directory = Directory.systemTemp.createTempSync(
      'qingting-album-cancel-',
    );
    final tracks = <DownloadedTrack>[];
    for (var index = 0; index < 2; index += 1) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}song-$index.m4a',
      )..writeAsBytesSync(const [1]);
      tracks.add(
        DownloadedTrack(
          id: 'song-$index',
          title: 'Song $index',
          artist: 'Artist',
          path: file.path,
          format: 'm4a',
          downloadedAt: DateTime(2026, 7, 11),
          sourceUrl: '',
          durationMs: 180000,
        ),
      );
    }
    final metadata = _ControlledAlbumMetadataService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
      albumMetadata: metadata,
    );
    controller.downloadedTracks = tracks;
    addTearDown(() {
      controller.dispose();
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    final matching = controller.matchMissingDownloadedAlbums();
    await metadata.started.future;
    controller.cancelAlbumMatching();
    metadata.release.complete();
    expect(await matching, 0);

    expect(metadata.calls, 1);
    expect(controller.albumMatchProcessed, 1);
    expect(controller.albumMatchUpdated, 0);
    expect(
      controller.downloadedTracks.every((track) => track.album.isEmpty),
      isTrue,
    );
    expect(controller.globalMessage, contains('已停止'));
  });

  test(
    'flushPendingWrites stops album scan and saves the pending tail',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'qingting-album-flush-',
      );
      final tracks = <DownloadedTrack>[];
      for (var index = 0; index < 2; index += 1) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}flush-$index.m4a',
        )..writeAsBytesSync(const [1]);
        tracks.add(
          DownloadedTrack(
            id: 'flush-$index',
            title: 'Flush $index',
            artist: 'Artist',
            path: file.path,
            format: 'm4a',
            downloadedAt: DateTime(2026, 7, 12),
            sourceUrl: '',
            durationMs: 180000,
          ),
        );
      }
      final storage = _FakeStorageService();
      final metadata = _FlushAwareAlbumMetadataService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: _FakePlaybackService(),
        albumMetadata: metadata,
      )..downloadedTracks = tracks;
      addTearDown(() {
        controller.dispose();
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });

      final matching = controller.matchMissingDownloadedAlbums();
      await metadata.secondStarted.future;
      await controller.flushPendingWrites();

      expect(await matching, 0);
      expect(controller.pendingAlbumMatches, hasLength(1));
      expect(storage.savedPendingAlbumMatches, hasLength(1));
      expect(controller.isMatchingLocalAlbums, isFalse);
    },
  );

  test('album scan never recreates a record deleted during lookup', () async {
    final directory = Directory.systemTemp.createTempSync(
      'qingting-album-stale-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}stale.m4a')
      ..writeAsBytesSync(const [1]);
    final track = DownloadedTrack(
      id: 'stale',
      title: 'Song',
      artist: 'Artist',
      path: file.path,
      format: 'm4a',
      downloadedAt: DateTime(2026, 7, 11),
      sourceUrl: '',
      durationMs: 180000,
    );
    final metadata = _ControlledAlbumMetadataService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
      albumMetadata: metadata,
    );
    controller.downloadedTracks = [track];
    addTearDown(() {
      controller.dispose();
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    final matching = controller.matchMissingDownloadedAlbums();
    await metadata.started.future;
    await controller.removeDownloadedRecord(track);
    metadata.release.complete();
    expect(await matching, 0);

    expect(controller.downloadedTracks, isEmpty);
    expect(controller.albumMatchProcessed, 1);
    expect(controller.albumMatchFailed, 0);
    expect(controller.pendingAlbumMatches, isEmpty);
    expect(file.existsSync(), isTrue);
  });

  test(
    'single album lookup discards candidates after metadata changes',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'qingting-stale-single-album-',
      );
      final file = File('${directory.path}${Platform.pathSeparator}song.m4a')
        ..writeAsBytesSync(const [1]);
      final track = DownloadedTrack(
        id: 'stale-single',
        title: 'Song',
        artist: 'Artist',
        path: file.path,
        format: 'm4a',
        downloadedAt: DateTime(2026, 7, 12),
        sourceUrl: '',
        durationMs: 180000,
      );
      final metadata = _ControlledAlbumMetadataService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: _FakeStorageService(),
        player: _FakePlaybackService(),
        albumMetadata: metadata,
      )..downloadedTracks = [track];
      addTearDown(() {
        controller.dispose();
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });

      final lookup = controller.findDownloadedAlbumCandidates(track);
      await metadata.started.future;
      controller.downloadedTracks = [track.copyWith(album: 'Embedded Album')];
      metadata.release.complete();

      expect(await lookup, isEmpty);
      expect(controller.downloadedTracks.single.album, 'Embedded Album');
      expect(controller.globalMessage, contains('歌曲信息已经变化'));
    },
  );

  test('playback waits while album metadata is being persisted', () async {
    final directory = Directory.systemTemp.createTempSync(
      'qingting-album-playback-lock-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}song.m4a')
      ..writeAsBytesSync(const [1]);
    final sidecar = File('${directory.path}${Platform.pathSeparator}song.lrc')
      ..writeAsStringSync('[00:01.00]Locked lyrics');
    final track = DownloadedTrack(
      id: 'locked-playback',
      title: 'Song',
      artist: 'Artist',
      path: file.path,
      format: 'm4a',
      downloadedAt: DateTime(2026, 7, 12),
      sourceUrl: '',
    );
    final storage = _BlockingDownloadedTracksStorage();
    final player = _FakePlaybackService();
    final controller =
        AppController(
            source: _FakeMusicSource(),
            storage: storage,
            player: player,
          )
          ..downloadedTracks = [track]
          ..pendingAlbumMatches = [
            PendingAlbumMatch(
              trackId: track.id,
              trackPath: track.path,
              title: track.title,
              artist: track.artist,
              candidates: const [
                AlbumMetadataMatch(
                  album: 'Album',
                  recordingTitle: 'Song',
                  recordingArtist: 'Artist',
                  score: 90,
                ),
              ],
            ),
          ];
    storage.savedPendingAlbumMatches = List<PendingAlbumMatch>.from(
      controller.pendingAlbumMatches,
    );
    addTearDown(() {
      controller.dispose();
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    final applying = controller.applyDownloadedAlbumName(track, 'Album');
    await storage.started.future;
    await controller.playDownloaded(track);

    expect(player.openedItem, isNull);
    var lyricsReadCompleted = false;
    final lyricsRead = controller
        .readDownloadedLyrics(track)
        .whenComplete(() => lyricsReadCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(lyricsReadCompleted, isFalse);
    expect(controller.globalMessage, contains('请稍候再播放'));
    storage.release.complete();
    expect(await applying, isTrue);
    expect(controller.pendingAlbumMatches, isEmpty);
    expect(storage.savedPendingAlbumMatches, isEmpty);
    expect(await lyricsRead, await sidecar.readAsString());
  });

  test(
    'playback captures a missing local duration for later album matching',
    () async {
      final player = _FakePlaybackService();
      final storage = _FakeStorageService();
      final controller = AppController(
        source: _FakeMusicSource(),
        storage: storage,
        player: player,
      );
      final track = DownloadedTrack(
        id: 'duration-track',
        title: 'Duration Song',
        artist: 'Artist',
        path: 'C:\\Music\\duration-song.mp3',
        format: 'mp3',
        downloadedAt: DateTime(2026, 7, 11),
        sourceUrl: '',
      );
      controller.downloadedTracks = [track];
      controller.queue = const [
        PlayerItem(
          id: 'duration-track',
          title: 'Duration Song',
          artist: 'Artist',
          uri: 'file:///C:/Music/duration-song.mp3',
          localPath: 'C:\\Music\\duration-song.mp3',
        ),
      ];
      controller.currentQueueIndex = 0;
      player.duration = const Duration(minutes: 3, seconds: 21);
      addTearDown(controller.dispose);

      player.onChanged?.call();
      for (var attempt = 0; attempt < 20; attempt += 1) {
        if (controller.downloadedTracks.single.durationMs != null &&
            storage.savedDownloadedTracks.isNotEmpty) {
          break;
        }
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.downloadedTracks.single.durationMs, 201000);
      expect(storage.savedDownloadedTracks.single.durationMs, 201000);
    },
  );

  test('album matching can read sidecar lyrics for non-MP3 tracks', () async {
    final directory = Directory.systemTemp.createTempSync(
      'qingting-sidecar-lyrics-',
    );
    final audio = File('${directory.path}${Platform.pathSeparator}song.flac')
      ..writeAsBytesSync(const [1]);
    final lyrics = File('${directory.path}${Platform.pathSeparator}song.lrc')
      ..writeAsStringSync('[ti:Song]\n[ar:Artist]');
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    final track = DownloadedTrack(
      id: 'sidecar',
      title: 'Song',
      artist: 'Artist',
      path: audio.path,
      format: 'flac',
      downloadedAt: DateTime(2026, 7, 11),
      sourceUrl: '',
    );
    addTearDown(() {
      controller.dispose();
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    expect(
      await controller.readDownloadedLyrics(track),
      await lyrics.readAsString(),
    );
  });

  testWidgets('deleting a library record keeps the song file', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'qingting-remove-record-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
    file.writeAsBytesSync(const [1, 2, 3]);
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    final track = DownloadedTrack(
      id: 'remove-record-song',
      title: '保留文件的歌',
      artist: '测试歌手',
      path: file.path,
      format: 'mp3',
      downloadedAt: DateTime(2026, 6, 30),
      sourceUrl: '',
    );
    controller.downloadedTracks = [track];
    addTearDown(() {
      controller.dispose();
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.LibraryPage(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('删除歌曲'), findsOneWidget);
    expect(find.text('删除记录'), findsOneWidget);

    await tester.ensureVisible(find.text('删除记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除记录'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除记录'), findsOneWidget);
    expect(find.textContaining('不会删除歌曲文件本身'), findsOneWidget);
    expect(file.existsSync(), isTrue);
    expect(controller.downloadedTracks, [track]);

    await tester.tap(find.widgetWithText(TextButton, '删除记录'));
    await tester.pumpAndSettle();
    expect(file.existsSync(), isTrue);
    expect(controller.downloadedTracks, isEmpty);
    expect(controller.globalMessage, contains('歌曲文件仍保留'));
  });

  testWidgets('deleting a song warns before touching its file', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'qingting-delete-song-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}song.mp3');
    file.writeAsBytesSync(const [1, 2, 3]);
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
      fileDeletionService: _FakeFileDeletionService(
        movesFilesToRecycleBin: true,
      ),
    );
    final track = DownloadedTrack(
      id: 'delete-song',
      title: '真正删除的歌',
      artist: '测试歌手',
      path: file.path,
      format: 'mp3',
      downloadedAt: DateTime(2026, 6, 30),
      sourceUrl: '',
    );
    controller.downloadedTracks = [track];
    addTearDown(() {
      controller.dispose();
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.LibraryPage(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('删除歌曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除歌曲'), findsOneWidget);
    expect(find.textContaining('电脑端会将歌曲文件本身移入回收站'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '移入回收站'), findsOneWidget);
    expect(file.existsSync(), isTrue);
    expect(controller.downloadedTracks, [track]);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(file.existsSync(), isTrue);
    expect(controller.downloadedTracks, [track]);
  });

  testWidgets('mobile deletion warning says the file is permanent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
      fileDeletionService: _FakeFileDeletionService(
        movesFilesToRecycleBin: false,
      ),
    );
    final track = DownloadedTrack(
      id: 'mobile-delete-song',
      title: '手机端删除的歌',
      artist: '测试歌手',
      path: '/storage/emulated/0/Music/song.mp3',
      format: 'mp3',
      downloadedAt: DateTime(2026, 7, 2),
      sourceUrl: '',
    );
    controller.downloadedTracks = [track];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.LibraryPage(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('删除歌曲'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除歌曲'));
    await tester.pumpAndSettle();

    expect(find.text('确认删除歌曲'), findsOneWidget);
    expect(find.textContaining('手机端会直接永久删除'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '删除歌曲'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(controller.downloadedTracks, [track]);
  });

  testWidgets('deletion disables the track menu and shows progress', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fileDeletion = _ControlledFileDeletionService();
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
      fileDeletionService: fileDeletion,
    );
    final track = DownloadedTrack(
      id: 'deletion-progress-song',
      title: '正在删除的歌',
      artist: '测试歌手',
      path: 'C:\\Music\\deletion-progress.mp3',
      format: 'mp3',
      downloadedAt: DateTime(2026, 7, 2),
      sourceUrl: '',
    );
    controller.downloadedTracks = [track];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) =>
              Scaffold(body: app.LibraryPage(controller: controller)),
        ),
      ),
    );

    final deletion = controller.deleteDownloadedTrack(track);
    await tester.pump();

    expect(fileDeletion.hasStarted, isTrue);
    expect(controller.isDeletingDownloadedTrack(track), isTrue);
    expect(find.byTooltip('正在删除歌曲'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is PopupMenuButton && !widget.enabled,
      ),
      findsOneWidget,
    );

    final duplicateResult = await controller.deleteDownloadedTrack(track);
    expect(duplicateResult, isFalse);
    expect(fileDeletion.calls, 1);

    fileDeletion.finish();
    await tester.pumpAndSettle();

    expect(await deletion, isTrue);
    expect(controller.isDeletingDownloadedTrack(track), isFalse);
    expect(controller.downloadedTracks, isEmpty);
  });

  testWidgets('diagnostics page displays recorded log entries', (tester) async {
    await AppLog.instance.clear();
    AppLog.instance.warning('test', '诊断测试日志');

    await tester.pumpWidget(const MaterialApp(home: app.DiagnosticsPage()));
    await tester.pump();

    expect(find.text('诊断与日志'), findsOneWidget);
    expect(find.text('版本：$appVersion'), findsOneWidget);
    expect(find.text('诊断测试日志'), findsOneWidget);
  });

  testWidgets('settings reviews and applies pending album candidates', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = Directory.systemTemp.createTempSync(
      'qingting-album-review-',
    );
    final file = File('${directory.path}${Platform.pathSeparator}review.m4a')
      ..writeAsBytesSync(const [1]);
    final track = DownloadedTrack(
      id: 'review',
      title: '待确认歌曲',
      artist: '测试歌手',
      path: file.path,
      format: 'm4a',
      downloadedAt: DateTime(2026, 7, 11),
      sourceUrl: '',
    );
    const candidate = AlbumMetadataMatch(
      album: '人工确认专辑',
      recordingTitle: '待确认歌曲',
      recordingArtist: '测试歌手',
      score: 82,
    );
    final controller = AppController(
      source: _FakeMusicSource(),
      storage: _FakeStorageService(),
      player: _FakePlaybackService(),
    );
    controller.settings = AppSettings(downloadDirectory: directory.path);
    controller.downloadedTracks = [track];
    controller.pendingAlbumMatches = [
      PendingAlbumMatch(
        trackId: track.id,
        trackPath: track.path,
        title: track.title,
        artist: track.artist,
        candidates: const [candidate],
      ),
    ];
    addTearDown(() {
      controller.dispose();
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: app.SettingsPage(controller: controller)),
      ),
    );
    await tester.ensureVisible(find.text('审阅 1 个待确认结果'));
    await tester.tap(find.text('审阅 1 个待确认结果'));
    await tester.pumpAndSettle();

    expect(find.text('人工确认专辑'), findsOneWidget);
    await tester.tap(find.text('确认并继续'));
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (controller.pendingAlbumMatches.isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(find.text('待确认结果已处理完毕'), findsOneWidget);
    expect(controller.downloadedTracks.single.album, '人工确认专辑');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  });
}

class _FakePlaybackService implements PlaybackService {
  final ValueNotifier<Duration> _positionListenable = ValueNotifier(
    Duration.zero,
  );

  @override
  VoidCallback? onChanged;

  @override
  VoidCallback? onCompleted;

  PlayerItem? openedItem;
  int openCalls = 0;
  int playOrPauseCalls = 0;
  int pauseCalls = 0;

  @override
  bool isPlaying = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = Duration.zero;

  @override
  ValueListenable<Duration> get positionListenable => _positionListenable;

  @override
  bool isOpened(PlayerItem item) {
    final opened = openedItem;
    return opened != null && opened.id == item.id && opened.uri == item.uri;
  }

  @override
  Future<void> open(PlayerItem item) async {
    openCalls += 1;
    openedItem = item;
    isPlaying = true;
  }

  @override
  Future<void> play() async {
    isPlaying = true;
  }

  @override
  Future<void> playOrPause() async {
    playOrPauseCalls += 1;
    isPlaying = !isPlaying;
  }

  @override
  Future<void> pause() async {
    pauseCalls += 1;
    isPlaying = false;
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
    _positionListenable.value = value;
  }

  @override
  Future<void> setVolume(double value) async {}

  @override
  Future<void> stop() async {
    isPlaying = false;
  }

  @override
  Future<void> dispose() async {
    _positionListenable.dispose();
  }
}

class _FakeStorageService extends StorageService {
  List<DownloadedTrack> savedDownloadedTracks = const [];
  List<PendingAlbumMatch> savedPendingAlbumMatches = const [];

  @override
  Future<List<PendingAlbumMatch>> loadPendingAlbumMatches() async =>
      savedPendingAlbumMatches;

  @override
  Future<void> saveSettings(AppSettings settings) async {}

  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) async {}

  @override
  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {}

  @override
  Future<void> saveMyMusic(MyMusicData value) async {}

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    savedDownloadedTracks = List<DownloadedTrack>.from(tracks);
  }

  @override
  Future<void> savePendingAlbumMatches(List<PendingAlbumMatch> matches) async {
    savedPendingAlbumMatches = List<PendingAlbumMatch>.from(matches);
  }
}

class _FailingQueueStorageService extends _FakeStorageService {
  @override
  Future<void> savePlayerQueue(
    List<PlayerItem> items,
    int currentIndex, {
    required bool shuffleEnabled,
  }) {
    throw const FileSystemException('queue storage unavailable');
  }
}

class _BlockingDownloadedTracksStorage extends _FakeStorageService {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    await super.saveDownloadedTracks(tracks);
  }
}

class _FakeFileDeletionService implements FileDeletionService {
  const _FakeFileDeletionService({required this.movesFilesToRecycleBin});

  @override
  final bool movesFilesToRecycleBin;

  @override
  Future<bool> deleteFile(String path) {
    throw StateError('The confirmation tests must not delete a real file.');
  }
}

class _ControlledFileDeletionService implements FileDeletionService {
  @override
  bool get movesFilesToRecycleBin => false;

  Completer<void>? _release;
  bool hasStarted = false;
  int calls = 0;

  @override
  Future<bool> deleteFile(String path) async {
    calls += 1;
    hasStarted = true;
    _release = Completer<void>();
    await _release!.future;
    return true;
  }

  void finish() => _release!.complete();
}

class _BootstrapStorageService extends _FakeStorageService {
  _BootstrapStorageService({
    this.queue = const SavedPlayerQueue(items: [], currentIndex: -1),
    this.tasks = const [],
    this.pendingAlbumMatches = const [],
    this.tracks = const [],
  });

  final SavedPlayerQueue queue;
  final List<DownloadTask> tasks;
  final List<PendingAlbumMatch> pendingAlbumMatches;
  final List<DownloadedTrack> tracks;
  List<DownloadTask> savedTasks = const [];

  @override
  Future<AppSettings> loadSettings() async {
    return const AppSettings(downloadDirectory: '');
  }

  @override
  Future<MyMusicData> loadMyMusic() async => const MyMusicData();

  @override
  Future<List<DownloadedTrack>> loadDownloadedTracks() async => tracks;

  @override
  Future<SavedPlayerQueue> loadPlayerQueue() async => queue;

  @override
  Future<List<DownloadTask>> loadDownloadTasks() async => tasks;

  @override
  Future<List<PendingAlbumMatch>> loadPendingAlbumMatches() async =>
      pendingAlbumMatches;

  @override
  Future<void> saveDownloadTasks(List<DownloadTask> tasks) async {
    savedTasks = List<DownloadTask>.from(tasks);
  }
}

class _RetryBootstrapStorageService extends _BootstrapStorageService {
  int loadSettingsCalls = 0;

  @override
  Future<AppSettings> loadSettings() async {
    loadSettingsCalls += 1;
    if (loadSettingsCalls == 1) {
      throw const FileSystemException('temporary bootstrap failure');
    }
    return super.loadSettings();
  }
}

class _RecordingSettingsStorageService extends _FakeStorageService {
  int saveSettingsCalls = 0;
  AppSettings? lastSettings;

  @override
  Future<void> saveSettings(AppSettings settings) async {
    saveSettingsCalls += 1;
    lastSettings = settings;
  }
}

class _DownloadStorageService extends _FakeStorageService {
  _DownloadStorageService(this.savePath);

  final String savePath;

  @override
  Future<String> uniqueSavePath({
    required String downloadDirectory,
    required String title,
    required String artist,
    required String format,
  }) async => savePath;

  @override
  Future<String?> cacheEmbeddedCover(
    File audioFile, {
    required String cacheKey,
  }) async => null;

  @override
  Future<void> saveDownloadedTracks(List<DownloadedTrack> tracks) async {}
}

class _RecordingAlbumMetadataService extends AlbumMetadataService {
  int calls = 0;
  Duration? receivedDuration;

  @override
  Future<AlbumMetadataMatch?> findBestAlbum({
    required String title,
    required String artist,
    String? lyrics,
    Future<String?> Function()? lyricsLoader,
    bool Function()? isCancelled,
    Duration? duration,
  }) async {
    calls += 1;
    receivedDuration = duration;
    return const AlbumMetadataMatch(
      album: 'Apple Album',
      recordingTitle: 'Test Song',
      recordingArtist: 'Test Artist',
      score: 96,
      recordingId: 'apple:track-1',
      releaseId: 'apple:album-1',
    );
  }
}

class _BatchAlbumMetadataService extends AlbumMetadataService {
  @override
  Future<List<AlbumMetadataMatch>> findAlbumCandidates({
    required String title,
    required String artist,
    String? lyrics,
    Future<String?> Function()? lyricsLoader,
    bool Function()? isCancelled,
    Duration? duration,
    int limit = 5,
  }) async {
    if (title == '请求失败') {
      throw StateError('temporary album lookup failure');
    }
    if (title == '没有结果') {
      return const [];
    }
    if (title == '需要确认') {
      return const [
        AlbumMetadataMatch(
          album: '候选专辑',
          recordingTitle: '需要确认',
          recordingArtist: '测试歌手',
          score: 82,
          titleSimilarity: 1,
          artistSimilarity: 1,
          durationVerified: true,
        ),
      ];
    }
    return const [
      AlbumMetadataMatch(
        album: '可靠专辑',
        recordingTitle: '自动匹配',
        recordingArtist: '测试歌手',
        score: 95,
        titleSimilarity: 1,
        artistSimilarity: 1,
        durationVerified: true,
      ),
    ];
  }
}

class _ControlledAlbumMetadataService extends AlbumMetadataService {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int calls = 0;

  @override
  Future<List<AlbumMetadataMatch>> findAlbumCandidates({
    required String title,
    required String artist,
    String? lyrics,
    Future<String?> Function()? lyricsLoader,
    bool Function()? isCancelled,
    Duration? duration,
    int limit = 5,
  }) async {
    calls += 1;
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return const [
      AlbumMetadataMatch(
        album: 'Album',
        recordingTitle: 'Song',
        recordingArtist: 'Artist',
        score: 95,
        titleSimilarity: 1,
        artistSimilarity: 1,
        durationVerified: true,
      ),
    ];
  }
}

class _FlushAwareAlbumMetadataService extends AlbumMetadataService {
  final Completer<void> secondStarted = Completer<void>();
  int calls = 0;

  @override
  Future<List<AlbumMetadataMatch>> findAlbumCandidates({
    required String title,
    required String artist,
    String? lyrics,
    Future<String?> Function()? lyricsLoader,
    bool Function()? isCancelled,
    Duration? duration,
    int limit = 5,
  }) async {
    calls += 1;
    if (calls == 1) {
      return [
        AlbumMetadataMatch(
          album: 'Review Album',
          recordingTitle: title,
          recordingArtist: artist,
          score: 82,
          titleSimilarity: 1,
          artistSimilarity: 1,
          durationVerified: true,
        ),
      ];
    }
    if (!secondStarted.isCompleted) {
      secondStarted.complete();
    }
    while (!(isCancelled?.call() ?? false)) {
      await Future<void>.delayed(Duration.zero);
    }
    return const [];
  }
}

class _AudioDownloadAdapter implements HttpClientAdapter {
  const _AudioDownloadAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      Uint8List.fromList(const [0, 0, 0, 20, 102, 116, 121, 112]),
      200,
      headers: {
        Headers.contentLengthHeader: ['8'],
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RangeAudioDownloadAdapter implements HttpClientAdapter {
  _RangeAudioDownloadAdapter({
    this.statusCode = 206,
    this.payload = const [4, 5, 6],
    this.contentRange = 'bytes 3-5/6',
  });

  final int statusCode;
  final List<int> payload;
  final String? contentRange;
  String? rangeHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    rangeHeader = options.headers[HttpHeaders.rangeHeader]?.toString();
    return ResponseBody.fromBytes(
      Uint8List.fromList(payload),
      statusCode,
      headers: {
        Headers.contentLengthHeader: ['${payload.length}'],
        if (contentRange != null) 'content-range': [contentRange!],
        'etag': ['"range-etag"'],
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Range416ThenFullDownloadAdapter implements HttpClientAdapter {
  int calls = 0;
  String? firstRangeHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    if (calls == 1) {
      firstRangeHeader = options.headers[HttpHeaders.rangeHeader]?.toString();
      return ResponseBody.fromBytes(
        Uint8List(0),
        416,
        headers: {
          HttpHeaders.contentRangeHeader: ['bytes */6'],
        },
      );
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(const [9, 8, 7, 6, 5, 4]),
      200,
      headers: {
        Headers.contentLengthHeader: ['6'],
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ShortAudioDownloadAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      Uint8List.fromList(const [1, 2, 3]),
      200,
      headers: {
        Headers.contentLengthHeader: ['6'],
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CountingAudioDownloadAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    return ResponseBody.fromBytes(
      Uint8List.fromList(const [0, 0, 0, 20, 102, 116, 121, 112]),
      200,
      headers: {
        Headers.contentLengthHeader: ['8'],
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ControlledCoverDownloadAdapter implements HttpClientAdapter {
  final Completer<void> coverRequestStarted = Completer<void>();
  final Completer<void> coverRequestFinished = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('/cover.jpg')) {
      if (!coverRequestStarted.isCompleted) {
        coverRequestStarted.complete();
      }
      await coverRequestFinished.future;
      return ResponseBody.fromBytes(
        Uint8List.fromList(const [0xFF, 0xD8, 0xFF, 0xD9]),
        200,
        headers: {
          Headers.contentLengthHeader: ['4'],
          Headers.contentTypeHeader: ['image/jpeg'],
        },
      );
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(const [0xFF, 0xFB, 0x90, 0x64]),
      200,
      headers: {
        Headers.contentLengthHeader: ['4'],
        Headers.contentTypeHeader: ['audio/mpeg'],
      },
    );
  }

  void finishCoverRequest() {
    if (!coverRequestFinished.isCompleted) {
      coverRequestFinished.complete();
    }
  }

  @override
  void close({bool force = false}) {}
}

class _ControlledDeferredDownloadSource
    implements MusicSource, DeferredDownloadMusicSource {
  final Completer<void> firstPreparationStarted = Completer<void>();
  final Completer<void> _firstPreparationRelease = Completer<void>();
  int prepareCalls = 0;
  int _activePreparations = 0;
  int maxConcurrentPreparations = 0;

  TrackSearchResult get result => const TrackSearchResult(
    id: 'single-worker-track',
    title: 'Single Worker',
    artist: 'Test Artist',
    source: 'controlled-deferred-source',
    detailUrl: 'https://example.test/detail',
    duration: '3:20',
  );

  @override
  String get name => 'controlled-deferred-source';

  @override
  Future<AudioCandidate> prepareDownloadCandidate(
    AudioCandidate candidate,
  ) async {
    prepareCalls += 1;
    _activePreparations += 1;
    if (_activePreparations > maxConcurrentPreparations) {
      maxConcurrentPreparations = _activePreparations;
    }
    try {
      if (prepareCalls == 1) {
        firstPreparationStarted.complete();
        await _firstPreparationRelease.future;
      }
      return const AudioCandidate(
        url: 'https://example.test/single-worker.m4a',
        format: 'm4a',
      );
    } finally {
      _activePreparations -= 1;
    }
  }

  void finishFirstPreparation() => _firstPreparationRelease.complete();

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    return [result];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    throw UnimplementedError();
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    throw UnimplementedError();
  }
}

class _CoverDownloadMusicSource implements MusicSource {
  TrackSearchResult get result => const TrackSearchResult(
    id: 'cover-download',
    title: 'Cover Download',
    artist: 'Test Artist',
    source: 'cover-download-source',
    detailUrl: 'https://example.test/detail',
    duration: '3:20',
    coverUrl: 'https://example.test/cover.jpg',
  );

  @override
  String get name => 'cover-download-source';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    return [result];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    return TrackDetail(
      title: result.title,
      artist: result.artist,
      sourceUrl: result.detailUrl,
      candidates: const [],
      rawMetadata: const {},
      coverUrl: result.coverUrl,
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    return const [
      AudioCandidate(url: 'https://example.test/song.mp3', format: 'mp3'),
    ];
  }
}

class _AlbumDownloadMusicSource implements MusicSource {
  TrackSearchResult get result => const TrackSearchResult(
    id: 'album-download',
    title: 'Test Song',
    artist: 'Test Artist',
    source: 'album-download-source',
    detailUrl: 'https://example.test/detail',
    duration: '3:20',
    album: 'Site Album',
  );

  @override
  String get name => 'album-download-source';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    return [result];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    return TrackDetail(
      title: result.title,
      artist: result.artist,
      sourceUrl: result.detailUrl,
      candidates: const [],
      rawMetadata: const {},
      album: 'Site Album',
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    return const [
      AudioCandidate(url: 'https://example.test/test.m4a', format: 'm4a'),
    ];
  }
}

class _FakeMusicSource implements MusicSource {
  @override
  String get name => 'fake';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) {
    throw UnimplementedError();
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) {
    throw UnimplementedError();
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) {
    throw UnimplementedError();
  }
}

class _SearchMusicSource implements MusicSource {
  _SearchMusicSource(this.sourceId, this.name);

  final String sourceId;

  @override
  final String name;

  int searchCalls = 0;
  String? lastKeyword;

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    searchCalls += 1;
    lastKeyword = keyword;
    return [
      TrackSearchResult(
        id: '$sourceId-$keyword',
        title: keyword,
        artist: '测试歌手',
        source: name,
        detailUrl: 'https://example.test/$sourceId.mp3',
      ),
    ];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) {
    throw UnimplementedError();
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) {
    throw UnimplementedError();
  }
}

class _ControlledSearchMusicSource implements MusicSource {
  final List<Completer<List<TrackSearchResult>>> _pending = [];

  int get calls => _pending.length;

  @override
  String get name => 'controlled-search';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) {
    final completer = Completer<List<TrackSearchResult>>();
    _pending.add(completer);
    return completer.future;
  }

  Future<void> waitForCalls(int expected) async {
    for (var attempt = 0; attempt < 300 && calls < expected; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(calls, expected);
  }

  void complete(int index, {required String keyword}) {
    _pending[index].complete([
      TrackSearchResult(
        id: 'controlled-$keyword',
        title: keyword,
        artist: '测试歌手',
        source: name,
        detailUrl: 'https://example.test/$keyword',
      ),
    ]);
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) {
    throw UnimplementedError();
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) {
    throw UnimplementedError();
  }
}

class _PlayableMusicSource implements MusicSource {
  int loadCalls = 0;

  TrackSearchResult get result => const TrackSearchResult(
    id: 'playable-track',
    title: '测试歌曲',
    artist: '测试歌手',
    source: 'playable',
    detailUrl: 'https://example.test/detail',
    duration: '3:20',
  );

  @override
  String get name => 'playable';

  @override
  Future<List<TrackSearchResult>> search(String keyword, {int page = 1}) async {
    return [result];
  }

  @override
  Future<TrackDetail> loadDetail(TrackSearchResult result) async {
    loadCalls += 1;
    return TrackDetail(
      title: result.title,
      artist: result.artist,
      sourceUrl: result.detailUrl,
      candidates: const [],
      rawMetadata: const {},
    );
  }

  @override
  Future<List<AudioCandidate>> resolveCandidates(TrackDetail detail) async {
    return const [
      AudioCandidate(url: 'https://example.test/generated.mp3', format: 'mp3'),
    ];
  }
}

class _FakeLyricsService extends LyricsService {
  @override
  Future<String?> findLyrics({
    required String title,
    required String artist,
    Duration? duration,
  }) async {
    expect(duration, const Duration(minutes: 3, seconds: 20));
    return '[00:01.00]测试歌词';
  }
}
