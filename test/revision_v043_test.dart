import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/store.dart';
import 'package:malaria_care/ui/shell.dart' show delayWarning;

import 'engine_test.dart' show fixture;
import 'widget_test.dart' show TestNotifications;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('両モック通知の音・バイブ全組合せと繰り返しの再通知に対応', () async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final service = NotificationService()..ready = true;
    const native = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null),
    );
    for (final previous in [false, true]) {
      for (final sound in [false, true]) {
        for (final vibration in [false, true]) {
          final data = fixture()
            ..reminderSound = sound
            ..checkSound = sound
            ..reminderVibration = vibration
            ..checkVibration = vibration;
          final before = data.export();
          calls.clear();
          for (var i = 0; i < 2; i++) {
            await service.showPreviewNotification(
              data,
              DateTime(2026, 11, 3),
              previous: previous,
            );
          }
          expect(calls.map((c) => c.method), [
            'cancel',
            'show',
            'cancel',
            'show',
          ]);
          for (final call in calls.where((c) => c.method == 'show')) {
            final config = call.arguments['platformSpecifics'];
            expect(config['playSound'], sound);
            expect(config['enableVibration'], vibration);
            expect(config['onlyAlertOnce'], false);
            expect(
              config['channelId'],
              endsWith('s${sound ? 1 : 0}v${vibration ? 1 : 0}'),
            );
          }
          expect(calls[0].arguments['id'], calls[1].arguments['id']);
          expect(data.export(), before);
        }
      }
    }
    expect(
      NotificationService.details(
        fixture(),
        previous: false,
      ).android!.onlyAlertOnce,
      true,
    );
  });
  testWidgets('遅延の注意書きを日付のポップアップと入力画面に表示する', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await (FontLoader(
      'NotoSansJP',
    )..addFont(rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final c = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await c.init();
    await c.replace(fixture());
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    final cell = find.byKey(const ValueKey('calendar-day-2026-11-03'));
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    final warning = find.byKey(const ValueKey('day-popup-warning'));
    expect(tester.widget<Text>(warning).data, delayWarning);
    await tester.tap(find.byKey(const ValueKey('day-action-delay')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(delayWarning),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
