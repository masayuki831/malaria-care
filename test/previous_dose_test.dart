import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/store.dart';
import 'package:malaria_care/main.dart';

import 'engine_test.dart' show fixture;
import 'widget_test.dart' show TestNotifications;

void main() {
  test('確認OFFなら質問を予約せず、前日は服用済みで維持', () {
    final data = fixture()
      ..remindersEnabled = false
      ..nextDay = false;
    final now = DateTime(2026, 11, 3, 9), engine = MedicationEngine(data);
    engine.materialize(now);
    expect(NotificationService.requests(data, now), isEmpty);
    expect(engine.data.doses.first.status(now), DoseStatus.assumed);
    expect(engine.balance('a', now, now), 28);
  });
  test('前日確認ONは服用リマインダーOFFでも独立して指定時刻に予約', () {
    final data = fixture()
      ..remindersEnabled = false
      ..nextDay = true
      ..checkHour = 10
      ..checkMinute = 25;
    final now = DateTime(2026, 11, 3, 9);
    final queue = NotificationService.requests(data, now);
    expect(queue.first.at, DateTime(2026, 11, 3, 10, 25));
    expect(queue.first.payload, 'check:a@2026-11-02');
    expect(queue.every((n) => n.payload.startsWith('check:')), true);
    expect(queue.every((n) => n.at.hour == 10 && n.at.minute == 25), true);
  });
  test('両方ONでは前日確認と当日リマインダーをそれぞれの時刻に予約', () {
    final data = fixture()
      ..nextDay = true
      ..checkHour = 10
      ..checkMinute = 15
      ..reminderHour = 19
      ..reminderMinute = 30;
    final queue = NotificationService.requests(data, DateTime(2026, 11, 3, 9));
    expect(queue[0].payload, 'check:a@2026-11-02');
    expect(queue[1].payload, 'reminder:a@2026-11-03');
    expect(queue[1].at, DateTime(2026, 11, 3, 19, 30));
    expect(queue.length, 100);
  });
  test('週1回なら服用予定の翌日だけ確認、既に修正した日は質問しない', () {
    final data = fixture(frequency: Frequency.weekdays)
      ..nextDay = true
      ..remindersEnabled = false
      ..checkHour = 10;
    final now = DateTime(2026, 11, 3, 9), engine = MedicationEngine(data);
    final queue = NotificationService.requests(data, now);
    expect(queue.every((n) => n.at.weekday == 2), true);
    engine.record(
      engine.generate(DateTime(2026, 11, 2), now).single,
      DoseStatus.missed,
      now,
    );
    expect(
      NotificationService.requests(
        data,
        now,
      ).any((n) => n.payload == 'check:a@2026-11-02'),
      false,
    );
  });
  test('確認ONと時刻をJSON保存後も保持し、OFFに戻しても服用は消さない', () {
    final data = fixture()
      ..nextDay = true
      ..checkHour = 11
      ..checkMinute = 45;
    final restored = AppData.parse(data.export());
    expect(restored.nextDay, true);
    expect(restored.checkHour, 11);
    expect(restored.checkMinute, 45);
    restored.nextDay = false;
    expect(AppData.parse(restored.export()).nextDay, false);
    expect(
      MedicationEngine(restored)
          .balance('a', DateTime(2026, 11, 3, 9), DateTime(2026, 11, 3, 9)),
      28,
    );
  });
  Future<AppController> open(WidgetTester tester) async {
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
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('設定で前日確認ON/OFFとON時に有効になる時刻を変更・保存できる', (tester) async {
    final c = await open(tester);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('previous-dose-enabled'));
    await tester.ensureVisible(toggle);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('previous-dose-time')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(c.data.nextDay, true);
    final time = find.byKey(const ValueKey('previous-dose-time'));
    await tester.ensureVisible(time);
    await tester.tap(time);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TimePickerDialog>(find.byType(TimePickerDialog))
          .initialEntryMode,
      TimePickerEntryMode.dial,
    );
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.first, '9');
    await tester.enterText(fields.last, '30');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(c.data.checkHour, 9);
    expect(c.data.checkMinute, 30);
    expect((await c.store.load(true))!.nextDay, true);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(c.data.nextDay, false);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('previous-dose-time')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('通知の質問で飲んだは変更なし、飲み忘れは前日に反映し残数を戻す', (tester) async {
    final c = await open(tester);
    await c.commit((d, e) => d.nextDay = true);
    await tester.pumpAndSettle();
    final before = c.data.export(),
        balance = c.engine.balance('demo-daily', c.now, c.now);
    const payload = 'check:demo-daily@2026-11-02';
    c.notifications.dispatch(payload, null);
    await tester.pumpAndSettle();
    expect(find.text('前日の服用確認'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '飲んだ'));
    await tester.pumpAndSettle();
    expect(c.data.export(), before);
    c.notifications.dispatch(payload, null);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '飲み忘れた'));
    await tester.pumpAndSettle();
    expect(
      c.data.doses.firstWhere((d) => d.id == 'demo-daily@2026-11-02').explicit,
      DoseStatus.missed,
    );
    expect(c.engine.balance('demo-daily', c.now, c.now), balance + 1);
    await c.commit((d, e) => d.nextDay = false);
    await tester.pumpAndSettle();
    c.notifications.dispatch(payload, null);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
