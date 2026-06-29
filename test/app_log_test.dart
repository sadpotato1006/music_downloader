import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/app_log.dart';

void main() {
  test('persists logs and removes URL query secrets', () async {
    final directory = await Directory.systemTemp.createTemp('qingting-log-');
    final log = AppLog.instance;

    try {
      await log.initialize(supportDirectory: directory);
      log.warning(
        'network',
        '测试请求失败',
        detail: 'https://example.test/audio.mp3?token=secret#fragment',
      );
      await log.flush();

      final text = log.diagnosticsText(appVersion: 'test-version');
      final file = File(log.filePath!);
      final persisted = await file.readAsString();
      expect(text, contains('测试请求失败'));
      expect(text, contains('https://example.test/audio.mp3'));
      expect(text, isNot(contains('token=secret')));
      expect(persisted, isNot(contains('token=secret')));

      await log.clear();
      expect(log.entries, isEmpty);
      expect(await file.readAsString(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('log entries survive JSON round-trip', () {
    final original = AppLogEntry(
      timestamp: DateTime.utc(2026, 6, 28, 12, 30),
      level: AppLogLevel.error,
      category: 'download',
      message: '下载失败',
      detail: 'HTTP 500',
    );

    final restored = AppLogEntry.fromJson(original.toJson());

    expect(restored.timestamp, original.timestamp);
    expect(restored.level, AppLogLevel.error);
    expect(restored.category, 'download');
    expect(restored.message, '下载失败');
    expect(restored.detail, 'HTTP 500');
  });
}
