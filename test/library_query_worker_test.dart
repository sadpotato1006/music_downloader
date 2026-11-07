import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/library_query_worker.dart';
import 'package:qingting/models.dart';

DownloadedTrack track(
  String path,
  String title, {
  String artist = '歌手',
  int day = 1,
}) => DownloadedTrack(
  id: path,
  path: path,
  title: title,
  artist: artist,
  album: '叶惠美',
  format: 'mp3',
  sourceUrl: '',
  downloadedAt: DateTime(2026, 1, day),
);

void main() {
  test(
    'worker searches Chinese and pinyin and preserves each sort order',
    () async {
      final worker = LibraryQueryWorker();
      addTearDown(worker.dispose);
      final songs = [
        track('a', '晴天', artist: '周杰伦'),
        track('b', '爱你', artist: '王心凌', day: 2),
        track('c', 'Blue', artist: ''),
      ];
      for (final query in ['晴天', 'qingtian', 'qt', 'zjl']) {
        final result = await worker.query(
          songs,
          query,
          LibrarySortMode.downloadedAtDesc,
        );
        expect(result.metadataPaths, {'a'});
        expect(result.order.first, 1);
      }
      final title = await worker.query(songs, '', LibrarySortMode.titleAsc);
      expect(title.order, [2, 0, 1]);
      final artist = await worker.query(songs, '', LibrarySortMode.artistAsc);
      expect(artist.order, [0, 2, 1]);
    },
  );

  test(
    'worker invalidates changed metadata and removes deleted rows',
    () async {
      final worker = LibraryQueryWorker();
      addTearDown(worker.dispose);
      final original = [track('same-path', '旧歌名'), track('deleted', '旧歌名')];
      expect(
        (await worker.query(
          original,
          '旧歌名',
          LibrarySortMode.titleAsc,
        )).metadataPaths,
        {'same-path', 'deleted'},
      );
      final updated = [original.first.copyWith(title: '新歌名', artist: '新歌手')];
      expect(
        (await worker.query(
          updated,
          '旧歌名',
          LibrarySortMode.titleAsc,
        )).metadataPaths,
        isEmpty,
      );
      final found = await worker.query(
        updated,
        '新歌手',
        LibrarySortMode.titleAsc,
      );
      expect(found.metadataPaths, {'same-path'});
      expect(found.order, [0]);
    },
  );

  test('disposing during worker startup completes pending queries', () async {
    final worker = LibraryQueryWorker();
    final result = worker.query(
      [track('a', '晴天')],
      '晴天',
      LibrarySortMode.titleAsc,
    );
    final expectation = expectLater(result, throwsStateError);
    worker.dispose();
    await expectation;
    await expectLater(
      worker.query([], '', LibrarySortMode.titleAsc),
      throwsStateError,
    );
  });

  test('reset releases a large snapshot and permits a new query', () async {
    final worker = LibraryQueryWorker();
    addTearDown(worker.dispose);
    await worker.query([track('old', '旧歌曲')], '旧歌曲', LibrarySortMode.titleAsc);
    worker.reset();
    final result = await worker.query(
      [track('new', '新歌曲')],
      '新歌曲',
      LibrarySortMode.titleAsc,
    );
    expect(result.metadataPaths, {'new'});
    expect(result.order, [0]);
  });
}
