import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/async_utils.dart';

void main() {
  test('bounded mapping preserves order and limits concurrency', () async {
    var active = 0;
    var maximumActive = 0;

    final result = await mapWithConcurrency([1, 2, 3, 4, 5], (value) async {
      active += 1;
      if (active > maximumActive) {
        maximumActive = active;
      }
      await Future<void>.delayed(Duration(milliseconds: 6 - value));
      active -= 1;
      return value * 2;
    }, maxConcurrent: 2);

    expect(result, [2, 4, 6, 8, 10]);
    expect(maximumActive, 2);
  });
}
