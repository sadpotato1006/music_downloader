import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/storage_json_codec.dart';

void main() {
  const codec = StorageJsonCodec();

  test('large encoding converts models in the background isolate', () async {
    final content = await codec.encode(
      List.generate(512, (i) => _EncodingProbe(i)),
      entries: 512,
    );
    final records = jsonDecode(content) as List;
    expect(
      records.map((item) => item['index']),
      orderedEquals(List.generate(512, (i) => i)),
    );
    expect(records.map((item) => item['isolate']).toSet(), {
      'qingting-json-encode',
    });
  });

  test('large decoding converts models in the background isolate', () async {
    final content = jsonEncode({'lyrics': '歌词\n' * 50000});
    final result = await codec.decode(content, _decodeProbe);
    expect(result.isolate, 'qingting-json-decode');
    expect(result.text, '歌词\n' * 50000);
  });

  test(
    'small documents avoid spawning an isolate and preserve Unicode',
    () async {
      final content = await codec.encode({'lyrics': '中文\n歌词'});
      final result = await codec.decode(content, _decodeProbe);
      expect(result.isolate, Isolate.current.debugName);
      expect(result.text, '中文\n歌词');
    },
  );

  test(
    'a large text payload uses the background isolate even with few records',
    () async {
      final content = await codec.encode(
        [const _EncodingProbe(0)],
        entries: 1,
        textCodeUnits: StorageJsonCodec.backgroundTextThreshold,
      );
      expect(
        (jsonDecode(content) as List).single['isolate'],
        'qingting-json-encode',
      );
    },
  );

  test('invalid large JSON reports the original parsing failure', () async {
    await expectLater(
      codec.decode(' ' * (128 * 1024) + '{broken', _decodeProbe),
      throwsA(isA<FormatException>()),
    );
  });
}

class _EncodingProbe {
  const _EncodingProbe(this.index);
  final int index;
  Map<String, Object?> toJson() => {
    'index': index,
    'isolate': Isolate.current.debugName,
  };
}

class _DecodedProbe {
  const _DecodedProbe(this.text, this.isolate);
  final String text;
  final String? isolate;
}

_DecodedProbe _decodeProbe(Object? value) => _DecodedProbe(
  (value as Map)['lyrics'] as String,
  Isolate.current.debugName,
);
