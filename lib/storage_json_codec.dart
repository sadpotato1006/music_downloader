import 'dart:convert';
import 'dart:isolate';

/// Keeps small documents cheap and moves large JSON and model conversions off
/// the UI isolate. Decoders must be top-level/static functions without UI state.
class StorageJsonCodec {
  const StorageJsonCodec();

  static const backgroundEntryThreshold = 512;
  static const backgroundTextThreshold = 128 * 1024;

  Future<String> encode(
    Object? snapshot, {
    int entries = 0,
    int textCodeUnits = 0,
  }) async {
    if (entries < backgroundEntryThreshold &&
        textCodeUnits < backgroundTextThreshold) {
      return jsonEncode(snapshot);
    }
    return _encodeInBackground(snapshot);
  }

  Future<T> decode<T>(String content, T Function(Object?) decodeModel) async {
    if (content.length < backgroundTextThreshold) {
      return decodeModel(jsonDecode(content));
    }
    return _decodeInBackground(content, decodeModel);
  }
}

// These helpers capture only the immutable payload and a pure decoder, never
// StorageService, Flutter listeners, open files, or queued save operations.
Future<String> _encodeInBackground(Object? snapshot) =>
    Isolate.run(() => jsonEncode(snapshot), debugName: 'qingting-json-encode');

Future<T> _decodeInBackground<T>(
  String content,
  T Function(Object?) decodeModel,
) => Isolate.run(
  () => decodeModel(jsonDecode(content)),
  debugName: 'qingting-json-decode',
);
