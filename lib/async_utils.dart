import 'dart:math';

Future<List<R>> mapWithConcurrency<T, R>(
  Iterable<T> values,
  Future<R> Function(T value) mapper, {
  required int maxConcurrent,
}) async {
  final items = List<T>.from(values);
  if (items.isEmpty) {
    return <R>[];
  }

  final results = List<Object?>.filled(items.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (nextIndex < items.length) {
      final index = nextIndex;
      nextIndex += 1;
      results[index] = await mapper(items[index]);
    }
  }

  await Future.wait<void>([
    for (
      var index = 0;
      index < min(maxConcurrent.clamp(1, items.length), items.length);
      index += 1
    )
      worker(),
  ]);
  return [for (final result in results) result as R];
}
