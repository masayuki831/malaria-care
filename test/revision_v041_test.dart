import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/store.dart';

import 'engine_test.dart' show fixture;
import 'widget_test.dart' show TestNotifications;

class PreviewNotifications extends TestNotifications {
  final previews = <bool>[];
  @override
  Future<void> showPreviewNotification(
    AppData data,
    DateTime now, {
    required bool previous,
  }) async => previews.add(previous);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 6, 9);
  for (final status in [null, ...DoseStatus.values]) {
    test('遅延先に予定・記録（$status）がある場合は拒否し変更しない', () {
      final data = fixture(frequency: Frequency.days, interval: 2);
      final engine = MedicationEngine(data);
      engine.materialize(now);
      final source = data.doses.first;
      final occupied = data.doses[1]..explicit = status;
      if (status == DoseStatus.confirmed) occupied.actual = occupied.scheduled;
      final before = data.export();
      for (final reanchor in [false, true]) {
        expect(
          () =>
              engine.shift(source, occupied.scheduled, now, reanchor: reanchor),
          throwsArgumentError,
        );
        expect(data.export(), before);
      }
      expect(
        () => engine.record(
          source,
          DoseStatus.confirmed,
          now,
          actual: occupied.scheduled,
        ),
        throwsArgumentError,
      );
      expect(data.export(), before);
    });
  }
  test('生成済み記録がなくても遅延先の予定を検出する', () {
    final engine = MedicationEngine(fixture());
    final source = engine.generate(DateTime(2026, 11, 2), now).first;
    final before = engine.data.export();
    expect(
      () => engine.shift(source, DateTime(2026, 11, 3), now, reanchor: true),
      throwsArgumentError,
    );
    expect(engine.data.export(), before);
  });
  test('別の遅延先・遅延元・ルールから外れた保存済み履歴も拒否する', () {
    final engine = MedicationEngine(fixture(frequency: Frequency.weekdays));
    engine.materialize(DateTime(2026, 11, 10));
    final first = engine.data.doses.first;
    engine.shift(
      first,
      DateTime(2026, 11, 3),
      DateTime(2026, 11, 10),
      reanchor: false,
    );
    final next = engine.data.doses.last;
    final before = engine.data.export();
    for (final destination in [DateTime(2026, 11, 2), DateTime(2026, 11, 3)]) {
      expect(
        () => engine.shift(
          next,
          destination,
          DateTime(2026, 11, 10),
          reanchor: false,
        ),
        throwsArgumentError,
      );
      expect(engine.data.export(), before);
    }
    engine.data.doses.add(
      Dose(
        id: 'legacy',
        medicineId: 'a',
        name: '薬',
        scheduled: DateTime(2026, 11, 4),
        quantity: 1,
        explicit: DoseStatus.missed,
      ),
    );
    expect(
      () => engine.shift(
        next,
        DateTime(2026, 11, 4),
        DateTime(2026, 11, 10),
        reanchor: false,
      ),
      throwsArgumentError,
    );
  });
  test('予定なしの日への遅延・再保存・元の日への復元を許可し重複減算しない', () {
    final engine = MedicationEngine(fixture(frequency: Frequency.weekdays));
    final source = engine.generate(DateTime(2026, 11, 2), now).single;
    engine.shift(source, DateTime(2026, 11, 3), now, reanchor: false);
    expect(engine.balance('a', now, now), 29);
    final saved = engine.data.doses.single;
    engine.record(
      saved,
      DoseStatus.confirmed,
      now,
      actual: DateTime(2026, 11, 3),
    );
    expect(engine.balance('a', now, now), 29);
    engine.record(saved, DoseStatus.confirmed, now, actual: source.scheduled);
    expect(engine.data.doses.single.delayed, false);
    expect(engine.balance('a', now, now), 29);
  });
  test('服用予定・前日確認を時間順で最大100件、週1回でも100件用意する', () {
    for (final frequency in [Frequency.daily, Frequency.weekdays]) {
      for (final flags in [(true, false), (false, true), (true, true)]) {
        final data = fixture(frequency: frequency)
          ..remindersEnabled = flags.$1
          ..nextDay = flags.$2;
        final queue = NotificationService.requests(
          data,
          DateTime(2026, 11, 3, 9),
        );
        expect(queue.length, 100);
        expect(queue.map((r) => r.payload).toSet().length, 100);
        for (var i = 1; i < queue.length; i++) {
          expect(queue[i].at.isBefore(queue[i - 1].at), false);
        }
        expect(queue.any((r) => r.payload.startsWith('reminder:')), flags.$1);
        expect(queue.any((r) => r.payload.startsWith('check:')), flags.$2);
      }
    }
  });
  test('テスト表示は各種類の音・バイブを使用し本番の予約や記録に触れない', () async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final service = NotificationService()..ready = true;
    final data = fixture()
      ..remindersEnabled = false
      ..nextDay = false
      ..reminderSound = false
      ..reminderVibration = true
      ..checkSound = true
      ..checkVibration = false;
    final before = data.export();
    final calls = <MethodCall>[];
    const native = MethodChannel('dexterous.com/flutter/local_notifications');
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
      await service.showPreviewNotification(data, now, previous: previous);
    }
    expect(data.export(), before);
    expect(calls.map((c) => c.method), ['cancel', 'show', 'cancel', 'show']);
    final shows = calls.where((c) => c.method == 'show').toList();
    expect(shows[0].arguments['payload'], 'preview:reminder');
    expect(shows[1].arguments['payload'], 'preview:check');
    final first = shows[0].arguments['platformSpecifics'];
    final second = shows[1].arguments['platformSpecifics'];
    expect(first['playSound'], false);
    expect(first['enableVibration'], true);
    expect(second['playSound'], true);
    expect(second['enableVibration'], false);
  });
  test('通常起動で旧テスト通知を消し、隔離したテスト環境は保持する', () async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    tzdata.initializeTimeZones();
    final service = NotificationService()..ready = true;
    final calls = <MethodCall>[];
    const native = MethodChannel('dexterous.com/flutter/local_notifications');
    final previews = [
      'preview:reminder',
      'preview:check',
    ].map(NotificationService.notificationId).toSet();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          calls.add(call);
          if (call.method == 'pendingNotificationRequests')
            return [
              {'id': 123},
            ];
          if (call.method == 'getActiveNotifications')
            return [
              for (final id in previews)
                {'id': id, 'channelId': 'dose_reminder_v2_s1v1'},
              {'id': 456, 'channelId': 'dose_reminder_v2_s1v1'},
            ];
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null),
    );
    for (final demo in [false, true]) {
      calls.clear();
      await service.sync(fixture(), now, demo: demo);
      expect(calls.any((c) => c.method == 'cancelAll'), false);
      final cancelled = calls
          .where((c) => c.method == 'cancel')
          .map((c) => c.arguments['id'])
          .toSet();
      expect(cancelled, containsAll([123, 456]));
      expect(
        cancelled.intersection(previews),
        demo ? isEmpty : equals(previews),
      );
    }
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
      PreviewNotifications(),
    );
    await c.init();
    if (data != null) await c.replace(data);
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> close(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('OS許可を見出し横に配置し2組の設定をOFF時グレーアウトする', (tester) async {
    final c = await open(tester);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final permission = find.byKey(const ValueKey('notification-permission'));
    expect(find.text('OSの通知権限を許可'), findsOneWidget);
    expect(
      tester.getTopLeft(permission).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('reminder-enabled'))).dy,
      ),
    );
    expect(find.textContaining('60件'), findsNothing);
    expect(
      find.text(
        'OSの省電力等により遅延する場合があります。長期間起動しない場合は通知が途切れる場合があります。タイムゾーン変更後はアプリを起動しなおしてください。',
      ),
      findsOneWidget,
    );
    for (final previous in [false, true]) {
      final toggle = find.byKey(
        ValueKey(previous ? 'previous-dose-enabled' : 'reminder-enabled'),
      );
      if (previous) {
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
      }
      for (final kind in ['sound', 'vibration']) {
        final key = ValueKey('${previous ? 'check' : 'reminder'}-$kind');
        expect(
          tester.widget<SwitchListTile>(find.byKey(key)).onChanged,
          isNotNull,
        );
      }
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      for (final kind in ['sound', 'vibration']) {
        final key = ValueKey('${previous ? 'check' : 'reminder'}-$kind');
        final widget = tester.widget<SwitchListTile>(find.byKey(key));
        expect(widget.onChanged, isNull);
        expect(
          widget.value,
          true,
        ); // Keep the previous preference while disabled.
      }
      final time = find.byKey(
        ValueKey(previous ? 'previous-dose-time' : 'reminder-time'),
      );
      expect(tester.widget<OutlinedButton>(time).onPressed, isNull);
    }
    expect(c.data.remindersEnabled, false);
    expect(c.data.nextDay, false);
    expect((await c.store.load(true))!.reminderSound, true);
    await close(tester);
  });
  testWidgets('設定からモック検証の操作を削除し記録は保持する', (tester) async {
    final c = await open(tester);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final before = c.data.export();
    expect(find.byKey(const ValueKey('preview-reminder')), findsNothing);
    expect(find.byKey(const ValueKey('preview-check')), findsNothing);
    expect(find.textContaining('モック'), findsNothing);
    expect(find.textContaining('検証モード'), findsNothing);
    expect((c.notifications as PreviewNotifications).previews, isEmpty);
    expect(c.data.export(), before);
    await close(tester);
  });
  testWidgets('薬の管理から変更履歴表示を削除し保存済みルールは保持する', (tester) async {
    final c = await open(tester);
    final versions = jsonEncode(c.data.medicines.single.toJson()['versions']);
    await tester.tap(find.byIcon(Icons.medication_outlined).last);
    await tester.pumpAndSettle();
    expect(find.text('スケジュール変更履歴'), findsNothing);
    expect(find.text('入手・消失履歴（編集・削除）'), findsOneWidget);
    expect(jsonEncode(c.data.medicines.single.toJson()['versions']), versions);
    await close(tester);
  });
  testWidgets('重なる遅延は入力画面を閉じず拒否し保存済み記録を維持する', (tester) async {
    final c = await open(tester, data: fixture());
    await tester.ensureVisible(
      find.byKey(const ValueKey('calendar-day-2026-11-02')),
    );
    await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-02')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('day-action-delay')));
    await tester.pumpAndSettle();
    final before = c.data.export();
    await tester.tap(find.text('服用日 2026-11-02'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服用日を保存'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('2026-11-03には服用予定または記録があります。予定なしの日を選んでください。'),
      findsOneWidget,
    );
    expect(c.data.export(), before);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    await close(tester);
  });
}
