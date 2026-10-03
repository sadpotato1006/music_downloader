import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/song_metadata.dart';

void main() {
  test(
    'a long offline retry remains acknowledged after recent receipts are trimmed',
    () {
      final firstDevice = newMetadataDeviceId(),
          secondDevice = newMetadataDeviceId();
      final pending = LocalSongMetadata(
        values: const SongMetadata(
          title: 'Song',
          artist: 'Artist',
          album: 'First',
        ),
        fields: const {'album'},
        editId: '$firstDevice:1',
      );
      var document = SongMetadataDocument(
        syncId: songSyncId('song'),
        version: 1,
        values: const SongMetadata(title: 'Song', artist: 'Artist'),
      ).apply(pending);
      for (var sequence = 1; sequence <= 180; sequence++) {
        document = document.apply(
          LocalSongMetadata(
            values: SongMetadata(
              title: 'Song',
              artist: 'Artist',
              album: 'Latest $sequence',
            ),
            fields: const {'album'},
            editId: '$secondDevice:$sequence',
          ),
        );
      }
      document = SongMetadataDocument.fromJson(document.toJson()).tagged('rev');
      expect(document.editIds, isNot(contains(pending.editId)));
      expect(document.hasEdit(pending.editId), isTrue);
      expect(document.apply(pending), same(document));
      expect(document.values.album, 'Latest 180');
      final reedit = LocalSongMetadata(
        values: pending.values.merge(
          const SongMetadata(title: '', artist: '', lyrics: 'New lyrics'),
          const {'lyrics'},
        ),
        fields: const {'album', 'lyrics'},
        editId: '$firstDevice:2',
        fieldEditIds: {'album': '$firstDevice:1', 'lyrics': '$firstDevice:2'},
      );
      final merged = document.apply(reedit);
      expect(merged.values.album, 'Latest 180');
      expect(merged.values.lyrics, 'New lyrics');
      expect(merged.deviceSequences[firstDevice], 2);
      expect(merged.deviceSequences[secondDevice], 180);
    },
  );
}
