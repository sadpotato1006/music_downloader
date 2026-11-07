import 'dart:async';

/// Coordinates local metadata reads/writes, deletion and cloud synchronization.
/// Callers supply canonical path keys and release successful acquisitions in
/// finally blocks. This class knows nothing about controllers or song models.
class SongFileAccess {
  final Map<String, int> _readers = {};
  final Set<String> _writers = {};
  final Set<String> _deletions = {};
  Completer<void> _changed = Completer<void>();
  bool _syncing = false;
  bool _syncFilesStable = false;
  bool _closed = false;
  int _deletionRevision = 0;
  int get deletionRevision => _deletionRevision;

  bool get isSyncing => _syncing;
  bool isReading(String key) => (_readers[key] ?? 0) > 0;
  bool isWriting(String key) => _writers.contains(key);
  bool isDeleting(String key) => _deletions.contains(key);

  bool tryRead(String key, {bool completedDownload = false}) {
    if (_closed ||
        (_syncing && !_syncFilesStable && !completedDownload) ||
        isWriting(key) ||
        isDeleting(key)) {
      return false;
    }
    _readers[key] = (_readers[key] ?? 0) + 1;
    return true;
  }

  Future<bool> readWhenAvailable(String key) async {
    while (!_closed && !isDeleting(key)) {
      if (tryRead(key)) return true;
      await _changed.future;
    }
    return false;
  }

  void endRead(String key) {
    final count = _readers[key] ?? 0;
    if (count <= 1) {
      _readers.remove(key);
    } else {
      _readers[key] = count - 1;
    }
    _signal();
  }

  bool tryWrite(String key) {
    if (_closed || _syncing || isReading(key) || isDeleting(key)) return false;
    return _writers.add(key);
  }

  void endWrite(String key) {
    _writers.remove(key);
    _signal();
  }

  bool tryDelete(String key) {
    if (_closed || _syncing || isReading(key) || isWriting(key)) return false;
    final acquired = _deletions.add(key);
    if (acquired) {
      _deletionRevision++;
      _signal();
    }
    return acquired;
  }

  void endDelete(String key) {
    if (_deletions.remove(key)) _deletionRevision++;
    _signal();
  }

  /// Prevents new local work before waiting for existing operations to finish.
  /// A download imported by sync itself may still use completedDownload reads.
  Future<bool> beginSync() async {
    if (_closed) return false;
    if (_syncing) throw StateError('A file sync is already active');
    _syncing = true;
    _syncFilesStable = false;
    while (!_closed &&
        (_readers.isNotEmpty || _writers.isNotEmpty || _deletions.isNotEmpty)) {
      await _changed.future;
    }
    return !_closed;
  }

  /// Sync has finished changing audio files. Playback may resume while the
  /// library is scanned and reconciled; local writes still wait for endSync.
  void finishSyncFileChanges() {
    if (!_syncing) return;
    _syncFilesStable = true;
    _signal();
  }

  void endSync() {
    _syncing = false;
    _syncFilesStable = false;
    _signal();
  }

  void _signal() {
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
  }

  void dispose() {
    _closed = true;
    _signal();
  }
}
