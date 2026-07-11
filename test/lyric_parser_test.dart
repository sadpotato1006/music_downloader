import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/lyric_parser.dart';

void main() {
  test('parses fully synchronized lyrics as seekable lines', () {
    final lines = parseLyricLines('[ar:测试歌手]\n[00:01.20]第一句\n[00:03.45]第二句');

    expect(lines.map((line) => line.text), ['第一句', '第二句']);
    expect(lines[0].time, const Duration(milliseconds: 1200));
    expect(lines[1].time, const Duration(milliseconds: 3450));
  });

  test('partially timestamped lyrics keep all lines and disable seeking', () {
    final lines = parseLyricLines('[03:59.00]第一句\n第二句没有时间\n第三句也没有时间');

    expect(lines.map((line) => line.text), ['第一句', '第二句没有时间', '第三句也没有时间']);
    expect(lines.every((line) => line.time == null), isTrue);
  });

  test('plain lyrics remain visible and unseekable', () {
    final lines = parseLyricLines('第一句\n第二句');

    expect(lines.map((line) => line.text), ['第一句', '第二句']);
    expect(lines.every((line) => line.time == null), isTrue);
  });

  test('applies positive and negative LRC offsets', () {
    final delayed = parseLyricLines('[offset:+500]\n[00:01.00]第一句');
    final advanced = parseLyricLines('[offset:-1500]\n[00:01.00]第一句');

    expect(delayed.single.time, const Duration(milliseconds: 1500));
    expect(advanced.single.time, Duration.zero);
  });

  test('rejects malformed timestamp seconds', () {
    final lines = parseLyricLines('[00:75.00]错误时间');

    expect(lines.single.text, '[00:75.00]错误时间');
    expect(lines.single.time, isNull);
  });

  test('only allows lyric seeking inside the known song duration', () {
    const duration = Duration(minutes: 4);

    expect(
      isLyricTimestampSeekable(const Duration(minutes: 3), duration),
      isTrue,
    );
    expect(isLyricTimestampSeekable(duration, duration), isFalse);
    expect(
      isLyricTimestampSeekable(const Duration(minutes: 5), duration),
      isFalse,
    );
    expect(
      isLyricTimestampSeekable(const Duration(seconds: 1), Duration.zero),
      isFalse,
    );
  });
}
