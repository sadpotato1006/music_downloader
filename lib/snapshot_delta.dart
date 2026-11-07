/// Bounded cumulative overlay on a complete JSON snapshot. Index-based changes
/// make metadata edits and queue cursor updates small; large reorderings fall
/// back to a checkpoint. A digest binds the overlay to exactly one base file.
class SnapshotBase {
  SnapshotBase(this.hash, List<Object> items)
    : items = List<Object>.unmodifiable(items);
  final String hash;
  final List<Object> items;

  SnapshotDelta<Object>? diff(
    List<Object> next,
    Map<String, Object?> metadata,
  ) {
    final changed = <int, Object>{};
    for (var i = 0; i < next.length; i++) {
      if (i >= items.length || !identical(items[i], next[i])) {
        changed[i] = next[i];
        if (changed.length > 128) return null;
      }
    }
    return SnapshotDelta(
      hash: hash,
      baseLength: items.length,
      length: next.length,
      changed: changed,
      metadata: metadata,
    );
  }
}

class SnapshotDelta<T extends Object> {
  const SnapshotDelta({
    required this.hash,
    required this.baseLength,
    required this.length,
    required this.changed,
    required this.metadata,
  });
  final String hash;
  final int baseLength;
  final int length;
  final Map<int, T> changed;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
    'version': 1,
    'baseSha256': hash,
    'baseLength': baseLength,
    'length': length,
    'changed': {
      for (final entry in changed.entries) '${entry.key}': entry.value,
    },
    'metadata': metadata,
  };

  static SnapshotDelta<T> decode<T extends Object>(
    Object? json,
    T Function(Object?) decodeItem, {
    required bool queue,
  }) {
    if (json is! Map ||
        json['version'] != 1 ||
        json['baseSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(json['baseSha256'] as String) ||
        json['baseLength'] is! int ||
        (json['baseLength'] as int) < 0 ||
        json['length'] is! int ||
        (json['length'] as int) < 0 ||
        json['changed'] is! Map ||
        json['metadata'] is! Map) {
      throw const FormatException('无效的增量快照');
    }
    final length = json['length'] as int;
    final baseLength = json['baseLength'] as int;
    final changed = <int, T>{};
    for (final entry in (json['changed'] as Map).entries) {
      final index = int.tryParse('${entry.key}');
      if (index == null ||
          index < 0 ||
          index >= length ||
          changed.containsKey(index)) {
        throw const FormatException('无效的增量条目');
      }
      changed[index] = decodeItem(entry.value);
    }
    if (length > baseLength &&
        changed.keys.where((index) => index >= baseLength).length !=
            length - baseLength) {
      throw const FormatException('增量快照缺少新增条目');
    }
    final metadata = Map<String, Object?>.from(json['metadata'] as Map);
    if (queue &&
        (metadata['currentIndex'] is! int ||
            metadata['shuffleEnabled'] is! bool)) {
      throw const FormatException('无效的增量队列状态');
    }
    return SnapshotDelta(
      hash: json['baseSha256'] as String,
      baseLength: baseLength,
      length: length,
      changed: changed,
      metadata: metadata,
    );
  }

  List<T> apply(List<T> base) {
    if (base.length != baseLength) throw const FormatException('增量快照与基础文件不一致');
    return List<T>.unmodifiable(
      List.generate(length, (index) => changed[index] ?? base[index]),
    );
  }
}
