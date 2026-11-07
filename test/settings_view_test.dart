import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/models.dart';
import 'package:qingting/settings_controller.dart';
import 'package:qingting/ui/settings.dart';
import 'package:qingting/ui/theme.dart';

void main() {
  testWidgets('failed automatic save keeps edits and exposes a working retry', (
    tester,
  ) async {
    var failSave = true;
    AppSettings? saved;
    final preferences = SettingsController(
      save: (value) async {
        if (failSave) throw StateError('disk unavailable');
        saved = value;
      },
    );
    addTearDown(preferences.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            controller: preferences,
            libraryTools: const SizedBox(),
            lyricsButton: const SizedBox(),
            syncEntry: const SizedBox(),
            showMessage: (_) {},
            openDiagnostics: (_) {},
          ),
        ),
      ),
    );
    final field = find.byType(TextField);
    await tester.ensureVisible(field);
    await tester.enterText(field, 'unsaved path');
    preferences.setTheme('rose');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-save-error')), findsOneWidget);
    expect(preferences.value!.theme, 'rose');
    expect(tester.widget<TextField>(field).controller!.text, 'unsaved path');
    failSave = false;
    await tester.tap(find.widgetWithText(TextButton, '重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-save-error')), findsNothing);
    expect(saved!.theme, 'rose');
    expect(preferences.saveState.value.pending, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed switch save retains selection without an unhandled UI error',
    (tester) async {
      final preferences = SettingsController(
        save: (_) async => throw StateError('disk full'),
      );
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(
              controller: preferences,
              libraryTools: const SizedBox(),
              lyricsButton: const SizedBox(),
              syncEntry: const SizedBox(),
              showMessage: (_) {},
              openDiagnostics: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(preferences.value!.autoPlayOnStartup, isTrue);
      expect(find.byKey(const ValueKey('settings-save-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('theme scope updates only when the theme changes', (
    tester,
  ) async {
    final preferences = SettingsController(save: (_) async {});
    addTearDown(preferences.dispose);
    var builds = 0;
    Color? color;
    await tester.pumpWidget(
      MaterialApp(
        home: AppThemeScope(
          theme: preferences.theme,
          child: Builder(
            builder: (context) {
              builds++;
              color = Theme.of(context).colorScheme.primary;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final initialBuilds = builds;
    preferences.update((value) => value.copyWith(volume: 25));
    await tester.pump();
    expect(builds, initialBuilds);
    preferences.setTheme('lavender');
    await tester.pump();
    expect(builds, initialBuilds + 1);
    expect(color, qingTingTheme(theme: 'lavender').colorScheme.primary);
    await preferences.flush();
  });

  testWidgets(
    'settings works independently and retains a draft across changes',
    (tester) async {
      final preferences = SettingsController(
        save: (_) async {},
        initial: const AppSettings(downloadDirectory: 'music'),
      );
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(
              controller: preferences,
              libraryTools: const SizedBox(),
              lyricsButton: const Text('lyrics feature'),
              syncEntry: const Text('sync feature'),
              showMessage: (_) {},
              openDiagnostics: (_) {},
            ),
          ),
        ),
      );
      final field = find.byType(TextField);
      await tester.ensureVisible(field);
      await tester.enterText(field, 'unsaved path');
      preferences.setTheme('rose');
      await preferences.setAutoPlayOnStartup(true);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'unsaved path');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      preferences.restore(
        preferences.value!.copyWith(downloadDirectory: 'new path'),
      );
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'new path');
      await preferences.flush();
    },
  );
}
