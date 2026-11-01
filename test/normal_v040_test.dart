import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:malaria_care/main.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/report.dart';
import 'package:malaria_care/services/store.dart';

import 'engine_test.dart' show fixture;
import 'widget_test.dart' show TestNotifications;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('通知音・バイブを種類ごとに保存し、旧バックアップでは両方ONを初期値にする', () {
    final data = fixture()
      ..reminderSound = false
      ..checkVibration = false;
    data.reminderAcknowledgements.add('reminder:a@2026-11-02');
    final restored = AppData.parse(data.export());
    expect(restored.reminderSound, false);
    expect(restored.reminderVibration, true);
    expect(restored.checkSound, true);
    expect(restored.checkVibration, false);
    expect(restored.reminderAcknowledgements, ['reminder:a@2026-11-02']);
    final old = data.toJson()
      ..remove('reminderSound')
      ..remove('reminderVibration')
      ..remove('checkSound')
      ..remove('checkVibration')
      ..remove('reminderAcknowledgements');
    final migrated = AppData.parse(jsonEncode(old));
    expect([
      migrated.reminderSound,
      migrated.reminderVibration,
      migrated.checkSound,
      migrated.checkVibration,
    ], everyElement(true));
  });
  test('通知本文には数量を含めず、確認済みのリマインダーは再予約しない', () {
    final data = fixture(), now = DateTime(2026, 11, 2, 9);
    final first = NotificationService.requests(data, now).first;
    expect(first.body, '飲む時間です。');
    expect(first.payload, 'reminder:a@2026-11-02');
    data.reminderAcknowledgements.add(first.payload);
    expect(
      NotificationService.requests(
        data,
        now,
      ).any((r) => r.payload == first.payload),
      false,
    );
  });
  test('2種類の通知で音とバイブを独立させ、確認ボタンでリマインダーを消す設定', () {
    final data = fixture();
    final channels = <String>{};
    for (final sound in [false, true])
      for (final vibrate in [false, true]) {
        data.reminderSound = sound;
        data.reminderVibration = vibrate;
        data.checkSound = !sound;
        data.checkVibration = !vibrate;
        final reminder = NotificationService.details(
          data,
          previous: false,
        ).android!;
        final check = NotificationService.details(
          data,
          previous: true,
        ).android!;
        expect(reminder.playSound, sound);
        expect(reminder.enableVibration, vibrate);
        expect(check.playSound, !sound);
        expect(check.enableVibration, !vibrate);
        expect(reminder.autoCancel, false);
        expect(reminder.ongoing, true);
        expect(reminder.actions!.single.title, '確認');
        expect(reminder.actions!.single.cancelNotification, false);
        channels.add(reminder.channelId);
        channels.add(check.channelId);
      }
    expect(channels.length, 8);
  });
  test('通知IDは再起動・予約の並び順に依存せず確認対象を特定できる', () {
    const payload = 'reminder:a@2026-11-02';
    expect(
      NotificationService.notificationId(payload),
      NotificationService.notificationId(payload),
    );
    final ids = [
      for (var n = 0; n < 3650; n++)
        NotificationService.notificationId(
          'reminder:a@${ymd(plusDays(DateTime(2026, 1, 1), n))}',
        ),
    ];
    expect(ids.toSet().length, ids.length);
    expect(
      NotificationService.notificationId(payload),
      isNot(NotificationService.notificationId('check:a@2026-11-02')),
    );
  });
  test('開始日を前後に訂正して自動記録と残数を再計算する', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 4, 9);
    e.materialize(now);
    expect(e.data.doses.length, 3);
    e.changeMedicineStart('a', DateTime(2026, 11, 3), now);
    expect(e.data.doses.map((d) => ymd(d.scheduled)), [
      '2026-11-03',
      '2026-11-04',
    ]);
    expect(e.balance('a', now, now), 28);
    e.changeMedicineStart('a', DateTime(2026, 11, 1), now);
    expect(e.data.doses.length, 4);
    expect(e.balance('a', now, now), 26);
    e.data.validate();
  });
  test('N日間隔も訂正後の開始日から再計算し、週の曜日選択は保持', () {
    final e = MedicationEngine(fixture(frequency: Frequency.days, interval: 2)),
        now = DateTime(2026, 11, 4, 9);
    e.materialize(now);
    e.changeMedicineStart('a', DateTime(2026, 11, 1), now);
    expect(e.generate(DateTime(2026, 11, 1), now).map((d) => d.scheduled.day), [
      1,
      3,
    ]);
    final weekly = MedicationEngine(fixture(frequency: Frequency.weekdays));
    weekly.materialize(now);
    weekly.changeMedicineStart('a', DateTime(2026, 11, 1), now);
    expect(weekly.data.medicines.single.versions.single.rule.weekdays, [1]);
    weekly.data.validate();
  });
  test('開始日の訂正で修正済み記録が消える場合は変更を保存しない', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 4, 9);
    e.materialize(now);
    e.record(e.data.doses.first, DoseStatus.missed, now);
    final before = e.data.export();
    expect(
      () => e.changeMedicineStart('a', DateTime(2026, 11, 3), now),
      throwsArgumentError,
    );
    expect(e.data.export(), before);
  });
  test('開始日より前の入手・消失は黙って移動せず修正を案内する', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 4, 9);
    e.data.refills.add(Refill('r', 'a', DateTime(2026, 11, 2), 10, ''));
    final before = e.data.export();
    expect(
      () => e.changeMedicineStart('a', DateTime(2026, 11, 3), now),
      throwsArgumentError,
    );
    expect(e.data.export(), before);
  });
  test('PDFの遅延元は遅、実際に飲んだ遅延先は済', () {
    final data = fixture(frequency: Frequency.weekdays),
        now = DateTime(2026, 11, 3, 9);
    data.profile['start'] = '2026-11-01';
    data.profile['end'] = '2027-11-01';
    final engine = MedicationEngine(data);
    engine.shift(
      engine.generate(DateTime(2026, 11, 2), now).single,
      now,
      now,
      reanchor: false,
    );
    final report = ReportService(data, now, day(now));
    expect(report.cell(DateTime(2026, 11, 2)).mark, startsWith('遅'));
    expect(report.cell(DateTime(2026, 11, 3)).mark, '済');
  });
  test('予約更新は未確認の表示済みリマインダーを消さず、確認で対象だけ消す', () async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    tzdata.initializeTimeZones();
    final data = fixture(),
        now = DateTime(2026, 11, 3, 9),
        service = NotificationService()..ready = true;
    final past = NotificationService.notificationId('reminder:a@2026-11-02');
    final future = NotificationService.notificationId('reminder:a@2026-11-04');
    final calls = <MethodCall>[];
    const native = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          calls.add(call);
          if (call.method == 'pendingNotificationRequests')
            return [
              {'id': future, 'payload': 'reminder:a@2026-11-04'},
            ];
          if (call.method == 'getActiveNotifications')
            return [
              {
                'id': past,
                'channelId': 'dose_reminder_v2_s1v1',
                'title': 'Malaria Care',
                'body': '飲む時間です。',
              },
            ];
          return null;
        });
    await service.sync(data, now, demo: false);
    expect(calls.any((c) => c.method == 'cancelAll'), false);
    expect(
      calls
          .where((c) => c.method == 'cancel')
          .any((c) => c.arguments['id'] == past),
      false,
    );
    expect(
      calls
          .where((c) => c.method == 'cancel')
          .any((c) => c.arguments['id'] == future),
      true,
    );
    await service.acknowledgeReminder('reminder:a@2026-11-02');
    expect(calls.last.method, 'cancel');
    expect(calls.last.arguments['id'], past);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });
  test('同時の確認・保存で先の変更を失わず、保存失敗後も処理を続けられる', () async {
    final c = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await c.init();
    await c.replace(fixture());
    await Future.wait([
      c.commit((d, e) => d.refills.add(Refill('r1', 'a', day(c.now), 1, ''))),
      c.commit((d, e) => d.refills.add(Refill('r2', 'a', day(c.now), 2, ''))),
    ]);
    expect(c.data.refills.map((r) => r.id).toSet(), {'r1', 'r2'});
    expect((await c.store.load(true))!.refills.length, 2);
    await expectLater(
      c.commit((d, e) => d.medicines.single.initial = -1),
      throwsFormatException,
    );
    await c.commit((d, e) => d.profile['location'] = '保存成功');
    expect(c.data.profile['location'], '保存成功');
    expect(c.data.medicines.single.initial, 30);
  });

  Future<AppController> open(WidgetTester tester, {AppData? data}) async {
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
    if (data != null) await c.replace(data);
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('リマインダーをタップしても確認まで残り、服用データを変更せず閉じる', (tester) async {
    final c = await open(tester);
    final doses = jsonEncode(c.data.doses.map((d) => d.toJson()).toList());
    const payload = 'reminder:demo-daily@2026-11-03';
    c.notifications.dispatch(payload, null);
    await tester.pumpAndSettle();
    expect(find.text('飲む時間です。'), findsOneWidget);
    await tester.tapAt(const Offset(8, 130));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(c.data.reminderAcknowledgements, contains(payload));
    expect((c.notifications as TestNotifications).acknowledgements, [payload]);
    expect(jsonEncode(c.data.doses.map((d) => d.toJson()).toList()), doses);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('通知音とバイブ4設定を独立して保存し通常版に診断ボタンを出さない', (tester) async {
    final c = await open(tester);
    await c.commit((d, e) => d.nextDay = true);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('notification-diagnostics')),
      findsNothing,
    );
    for (final key in ['reminder-sound', 'check-vibration']) {
      final toggle = find.byKey(ValueKey(key));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
    }
    final saved = (await c.store.load(true))!;
    expect(saved.reminderSound, false);
    expect(saved.reminderVibration, true);
    expect(saved.checkSound, true);
    expect(saved.checkVibration, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('カレンダーの遅延元を遅、服用した遅延先を済で表示', (tester) async {
    final data = fixture(frequency: Frequency.weekdays),
        now = DateTime(2026, 11, 3, 9);
    MedicationEngine(data).shift(
      MedicationEngine(data).generate(DateTime(2026, 11, 2), now).single,
      now,
      now,
      reanchor: false,
    );
    await open(tester, data: data);
    final source = find.byKey(const ValueKey('calendar-day-2026-11-02'));
    final target = find.byKey(const ValueKey('calendar-day-2026-11-03'));
    expect(
      find.descendant(of: source, matching: find.text('遅')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: target, matching: find.text('済')),
      findsOneWidget,
    );
    expect(find.descendant(of: target, matching: find.text('遅')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('登録済みの薬の開始日をカレンダーから訂正して保存できる', (tester) async {
    final c = await open(tester, data: fixture());
    await tester.tap(find.byIcon(Icons.medication_outlined).last);
    await tester.pumpAndSettle();
    final edit = find.byTooltip('登録薬を編集');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final start = find.byKey(const ValueKey('medicine-start'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('1').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(c.data.medicines.single.start, DateTime(2026, 11, 1));
    expect(
      (await c.store.load(true))!.medicines.single.start,
      DateTime(2026, 11, 1),
    );
    expect(c.engine.balance('a', c.now, c.now), 27);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
