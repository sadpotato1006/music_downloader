import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/ui/linux_desktop_settings.dart';

void main() {
  const channel = MethodChannel('qingting/linux_desktop');
  Widget page(bool active) => MaterialApp(
    home: Scaffold(body: LinuxDesktopSettings(active: active)),
  );

  testWidgets('settings refresh on entry resume and writes without polling', (
    tester,
  ) async {
    var reads = 0;
    var closeToTray = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setCloseToTray') {
        closeToTray = (call.arguments as Map)['enabled'] as bool;
        return null;
      }
      if (call.method == 'getSettings') {
        reads++;
        return {'closeToTray': closeToTray, 'trayAvailable': true};
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(page(false));
    expect(reads, 0);
    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(reads, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 1);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(closeToTray, isFalse);
    expect(reads, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 3);
    await tester.pumpWidget(page(false));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 3);
    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(reads, 4);
  });

  testWidgets(
    'old reads cannot overwrite a newer setting and errors can retry',
    (tester) async {
      Completer<Map<String, bool>>? gate;
      var closeToTray = true;
      var fail = false;
      var failWrite = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'setCloseToTray') {
          if (failWrite) throw PlatformException(code: 'write-failed');
          closeToTray = (call.arguments as Map)['enabled'] as bool;
          return null;
        }
        if (call.method == 'getSettings') {
          if (fail) throw PlatformException(code: 'unavailable');
          return gate?.future ??
              {'closeToTray': closeToTray, 'trayAvailable': true};
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      gate = Completer<Map<String, bool>>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      final pending = gate;
      gate = null;
      pending.complete({'closeToTray': true, 'trayAvailable': true});
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      fail = true;
      await tester.pumpWidget(page(false));
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(find.text('重试读取'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('重试读取'));
      await tester.pumpAndSettle();
      expect(find.text('重试读取'), findsNothing);
      failWrite = true;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('保存桌面设置失败，请重试。'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    },
  );
}
