import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum AppLogLevel { info, warning, error }

class AppLogEntry {
  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.detail,
  });

  final DateTime timestamp;
  final AppLogLevel level;
  final String category;
  final String message;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'category': category,
    'message': message,
    'detail': detail,
  };

  factory AppLogEntry.fromJson(Map<String, dynamic> json) {
    final levelName = json['level'] as String?;
    return AppLogEntry(
      timestamp:
          DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      level: AppLogLevel.values.firstWhere(
        (value) => value.name == levelName,
        orElse: () => AppLogLevel.info,
      ),
      category: json['category'] as String? ?? 'app',
      message: json['message'] as String? ?? '',
      detail: json['detail'] as String?,
    );
  }

  String toDisplayText() {
    final local = timestamp.toLocal();
    final time =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
    final detailText = detail == null || detail!.isEmpty ? '' : '\n$detail';
    return '$time [${level.name.toUpperCase()}] [$category] $message$detailText';
  }
}

class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();
  static const _maxEntries = 500;
  static const _maxFileBytes = 1024 * 1024;

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final List<AppLogEntry> _entries = [];
  Future<void> _writeQueue = Future<void>.value();
  File? _file;

  List<AppLogEntry> get entries => List<AppLogEntry>.unmodifiable(_entries);
  String? get filePath => _file?.path;

  Future<void> initialize({Directory? supportDirectory}) async {
    if (_file != null) {
      return;
    }
    try {
      final support =
          supportDirectory ?? await getApplicationSupportDirectory();
      final directory = Directory(p.join(support.path, 'logs'));
      await directory.create(recursive: true);
      _file = File(p.join(directory.path, 'qingting.log'));
      await _loadExistingEntries();
      info('app', '日志系统已初始化');
    } catch (error, stackTrace) {
      _addMemoryEntry(
        AppLogEntry(
          timestamp: DateTime.now(),
          level: AppLogLevel.error,
          category: 'logging',
          message: '日志文件初始化失败',
          detail: _sanitize('$error\n$stackTrace'),
        ),
      );
    }
  }

  Future<void> flush() => _writeQueue;

  void info(String category, String message, {Object? detail}) {
    _record(AppLogLevel.info, category, message, detail: detail);
  }

  void warning(String category, String message, {Object? detail}) {
    _record(AppLogLevel.warning, category, message, detail: detail);
  }

  void error(
    String category,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final detail = [
      if (error != null) '$error',
      if (stackTrace != null) '$stackTrace',
    ].join('\n');
    _record(AppLogLevel.error, category, message, detail: detail);
  }

  Future<void> clear() async {
    _entries.clear();
    revision.value += 1;
    final file = _file;
    if (file == null) {
      return;
    }
    final previous = _writeQueue;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A failed older write must not block clearing the log.
      }
      if (await file.exists()) {
        await file.writeAsString('', flush: true);
      }
      final old = File('${file.path}.old');
      if (await old.exists()) {
        await old.delete();
      }
    }();
    _writeQueue = operation;
    await operation;
  }

  String diagnosticsText({required String appVersion}) {
    final buffer = StringBuffer()
      ..writeln('青听诊断信息')
      ..writeln('版本：$appVersion')
      ..writeln(
        '平台：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      )
      ..writeln('日志文件：${filePath ?? '不可用'}')
      ..writeln('生成时间：${DateTime.now().toLocal().toIso8601String()}')
      ..writeln();
    for (final entry in _entries.reversed.take(200).toList().reversed) {
      buffer.writeln(entry.toDisplayText());
    }
    return buffer.toString();
  }

  void _record(
    AppLogLevel level,
    String category,
    String message, {
    Object? detail,
  }) {
    final entry = AppLogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: _sanitize(category, maxLength: 80),
      message: _sanitize(message, maxLength: 500),
      detail: detail == null ? null : _sanitize('$detail'),
    );
    _addMemoryEntry(entry);
    unawaited(_append(entry));
  }

  void _addMemoryEntry(AppLogEntry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    revision.value += 1;
  }

  Future<void> _loadExistingEntries() async {
    final file = _file;
    if (file == null || !await file.exists()) {
      return;
    }
    try {
      final lines = await file.readAsLines();
      for (final line in lines.skip(
        lines.length > _maxEntries ? lines.length - _maxEntries : 0,
      )) {
        try {
          final json = jsonDecode(line);
          if (json is Map) {
            _entries.add(AppLogEntry.fromJson(Map<String, dynamic>.from(json)));
          }
        } catch (_) {
          // Ignore a single incomplete trailing log line.
        }
      }
      if (_entries.length > _maxEntries) {
        _entries.removeRange(0, _entries.length - _maxEntries);
      }
      revision.value += 1;
    } catch (_) {
      // The diagnostics page remains usable with in-memory entries.
    }
  }

  Future<void> _append(AppLogEntry entry) {
    final file = _file;
    if (file == null) {
      return Future<void>.value();
    }
    final previous = _writeQueue;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A later entry can still be written after an earlier failure.
      }
      try {
        if (await file.exists() && await file.length() >= _maxFileBytes) {
          final old = File('${file.path}.old');
          if (await old.exists()) {
            await old.delete();
          }
          await file.rename(old.path);
        }
        await file.writeAsString(
          '${jsonEncode(entry.toJson())}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // Logging must never break the user action being diagnosed.
      }
    }();
    _writeQueue = operation;
    return operation;
  }

  static String _sanitize(String value, {int maxLength = 4000}) {
    var sanitized = value.replaceAllMapped(
      RegExp(r'https?://[^\s]+', caseSensitive: false),
      (match) {
        final raw = match.group(0)!;
        final uri = Uri.tryParse(raw);
        if (uri == null || (!uri.hasQuery && !uri.hasFragment)) {
          return raw;
        }
        return Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
        ).toString();
      },
    );
    sanitized = sanitized.replaceAll(
      RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'),
      '',
    );
    if (sanitized.length > maxLength) {
      sanitized = '${sanitized.substring(0, maxLength)}…';
    }
    return sanitized.trim();
  }
}
