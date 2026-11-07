import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/models.dart';
import 'package:qingting/settings_controller.dart';

void main() {
  test(
    'settings writes serialize and include edits made during an active save',
    () async {
      final firstWrite = Completer<void>();
      final saved = <AppSettings>[];
      var active = 0;
      final settings = SettingsController(
        save: (snapshot) async {
          expect(++active, 1);
          saved.add(snapshot);
          if (saved.length == 1) await firstWrite.future;
          active--;
        },
      );
      addTearDown(settings.dispose);
      final saving = settings.setConcurrentDownloads(3);
      settings.setTheme('lavender');
      final savingPlayback = settings.setAutoPlayOnStartup(true);
      firstWrite.complete();
      await Future.wait([saving, savingPlayback]);
      expect(saved.last.concurrentDownloads, 3);
      expect(saved.last.theme, 'lavender');
      expect(saved.last.autoPlayOnStartup, isTrue);
      expect(saved.last, same(settings.value));
    },
  );

  test(
    'failed update preference does not discard a simultaneous theme edit',
    () async {
      final write = Completer<void>();
      var fail = true;
      final saved = <AppSettings>[];
      final settings = SettingsController(
        save: (snapshot) async {
          if (fail) await write.future;
          saved.add(snapshot);
        },
      );
      addTearDown(settings.dispose);
      final operation = settings.setCheckUpdatesOnStartup(false);
      final failure = expectLater(operation, throwsStateError);
      settings.setTheme('rose');
      write.completeError(StateError('disk unavailable'));
      await failure;
      expect(settings.value!.theme, 'rose');
      expect(settings.value!.checkUpdatesOnStartup, isFalse);
      fail = false;
      await settings.flush();
      expect(saved.single.theme, 'rose');
      expect(saved.single.checkUpdatesOnStartup, isFalse);
    },
  );

  test(
    'theme signal ignores unrelated settings and identical theme selections',
    () async {
      final settings = SettingsController(save: (_) async {});
      addTearDown(settings.dispose);
      var themeChanges = 0;
      settings.theme.addListener(() => themeChanges++);
      settings.update((value) => value.copyWith(volume: 42));
      await settings.setConcurrentDownloads(2);
      expect(themeChanges, 0);
      settings.setTheme('skyBlue');
      settings.setTheme('skyBlue');
      expect(themeChanges, 1);
      await settings.flush();
    },
  );

  test(
    'restoration does not write settings and disposal suppresses late edits',
    () async {
      var saves = 0;
      var changes = 0;
      final settings = SettingsController(save: (_) async => saves++);
      settings.addListener(() => changes++);
      settings.restore(
        const AppSettings(downloadDirectory: 'restored', theme: 'rose'),
      );
      await settings.flush();
      expect(saves, 0);
      expect(changes, 1);
      settings.dispose();
      settings.setTheme('graphite');
      expect(settings.value!.theme, 'rose');
      expect(changes, 1);
    },
  );
}
