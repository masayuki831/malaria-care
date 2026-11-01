import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/report.dart';
import 'package:malaria_care/services/store.dart';

import 'inventory_report_test.dart' show stockFixture;

class PermissionNotifications extends NotificationService {
  int permissions = 0;
  bool denied = false;
  @override
  Future<void> init() async {
    ready = true;
  }

  @override
  Future<void> permission() async {
    permissions++;
    permissionStatus = denied ? '通知が許可されていません。' : '通知を許可しました';
  }

  @override
  Future<void> sync(AppData data, DateTime now, {required bool demo}) async {
    status = permissionStatus;
  }
}

AppData personalFixture() {
  final data = AppData.empty();
  final start = plusDays(DateTime.now(), -7);
  data.profile['start'] = ymd(start);
  data.profile['name'] = '保存済みの利用者';
  data.medicines.add(
    Medicine(
      id: 'personal',
      name: '登録済みの薬',
      start: start,
      initial: 100,
      versions: [
        ScheduleVersion(
          start,
          Rule(frequency: Frequency.daily, anchor: start),
          1,
        ),
      ],
    ),
  );
  MedicationEngine(data).materialize(DateTime.now());
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('新規起動は空の個人領域で通知2種類OFF、権限要求なし', () async {
    final store = MemoryStore(), notifications = PermissionNotifications();
    final controller = AppController(store, notifications);
    await controller.init();
    expect(controller.demo, false);
    expect(store.mode, false);
    expect(controller.data.medicines, isEmpty);
    expect(controller.data.doses, isEmpty);
    expect(controller.data.remindersEnabled, false);
    expect(controller.data.nextDay, false);
    expect(notifications.permissions, 0);
    expect(() => controller.switchMode(true), throwsStateError);
    controller.dispose();
  });
  test('旧モード指定を使わず既存個人データと通知選択を保持、架空領域は不変', () async {
    final store = MemoryStore(),
        data = personalFixture()
          ..remindersEnabled = true
          ..nextDay = true;
    await store.save(data, false);
    await store.save(demoData(), true);
    final isolated = (await store.load(true))!.export();
    final controller = AppController(store, PermissionNotifications());
    await controller.init();
    expect(controller.demo, false);
    expect(controller.data.export(), data.export());
    expect((await store.load(true))!.export(), isolated);
    expect(controller.data.remindersEnabled, true);
    expect(controller.data.nextDay, true);
    controller.dispose();
  });
  test('2種類のOFF→ONだけで権限確認し、拒否後も記録を保持する', () async {
    final store = MemoryStore(), notifications = PermissionNotifications();
    await store.save(personalFixture(), false);
    final controller = AppController(store, notifications);
    await controller.init();
    final records = controller.data.doses
        .map((d) => d.toJson())
        .toList()
        .toString();
    await controller.setNotificationEnabled(previous: false, enabled: true);
    expect(notifications.permissions, 1);
    expect((await store.load(false))!.remindersEnabled, true);
    await controller.setNotificationEnabled(previous: false, enabled: true);
    await controller.setNotificationEnabled(previous: false, enabled: false);
    expect(notifications.permissions, 1);
    notifications.denied = true;
    await controller.setNotificationEnabled(previous: true, enabled: true);
    expect(notifications.permissions, 2);
    expect(controller.data.nextDay, true);
    expect(notifications.status, contains('許可されていません'));
    expect(
      controller.data.doses.map((d) => d.toJson()).toList().toString(),
      records,
    );
    controller.dispose();
  });
  test('選択した報告期間を集計し期首在庫と報告日を別に保持、日本語PDF生成', () async {
    final data = stockFixture(initial: 20);
    data.refills.add(Refill('r', 'a', DateTime(2026, 10, 31), 30, ''));
    data.refills.add(Refill('outside', 'a', DateTime(2026, 11, 3), 100, ''));
    data.losses.add(Refill('l', 'a', DateTime(2026, 11, 1), 5, ''));
    final report = ReportService(
      data,
      DateTime(2026, 11, 4, 23),
      DateTime(2026, 11, 4),
      periodStart: DateTime(2026, 10, 30),
      periodEnd: DateTime(2026, 11, 2),
    );
    expect(report.openingBalance, 19);
    expect(report.totals.acquired, 30);
    expect(report.totals.taken, 4);
    expect(report.totals.lost, 5);
    expect(report.totals.balance, 40);
    expect(report.cell(DateTime(2026, 11, 3)).balance, isNull);
    expect(report.cell(DateTime(2026, 10, 29)).category, 'outside');
    expect(report.fill('{期間}'), '2026-10-30 ～ 2026-11-02');
    expect(report.validPeriod, true);
    final bytes = await report.pdf(
      verifiedBalance: 40,
      fontData: ByteData.sublistView(
        File('assets/fonts/NotoSansJP-Regular.ttf').readAsBytesSync(),
      ),
    );
    Directory('build/test-artifacts').createSync(recursive: true);
    await File('build/test-artifacts/report-period-v080.pdf')
        .writeAsBytes(bytes);
    for (final range in [
      (DateTime(2026, 11, 3), DateTime(2026, 11, 2)),
      (DateTime(2026, 10, 1), DateTime(2026, 11, 5)),
      (DateTime(2025, 4, 21), DateTime(2026, 11, 2)),
    ]) {
      final invalid = ReportService(
        data,
        DateTime(2026, 11, 4),
        DateTime(2026, 11, 4),
        periodStart: range.$1,
        periodEnd: range.$2,
      );
      expect(invalid.validPeriod, false);
      await expectLater(invalid.pdf(verifiedBalance: 40), throwsArgumentError);
    }
  });
  test('報告対象薬は選択した期間末の薬から自動決定する', () {
    final data = stockFixture(initial: 20);
    data.medicines.single.end = DateTime(2026, 10, 31);
    data.medicines.add(
      Medicine(
        id: 'b',
        name: '次の薬',
        start: DateTime(2026, 11, 1),
        initial: 10,
        versions: [
          ScheduleVersion(
            DateTime(2026, 11, 1),
            Rule(frequency: Frequency.daily, anchor: DateTime(2026, 11, 1)),
            1,
          ),
        ],
      ),
    );
    final report = ReportService(
      data,
      DateTime(2026, 11, 4),
      DateTime(2026, 11, 4),
      periodStart: DateTime(2026, 10, 29),
      periodEnd: DateTime(2026, 10, 31),
    );
    expect(report.medicine!.id, 'a');
    expect(report.totals.balance, 17);
  });

  Future<(AppController, PermissionNotifications)> open(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryStore(), notifications = PermissionNotifications();
    await store.save(personalFixture(), false);
    final controller = AppController(store, notifications);
    await controller.init();
    await tester.pumpWidget(MalariaApp(controller: controller));
    await tester.pumpAndSettle();
    return (controller, notifications);
  }

  testWidgets('0.8表示、モード表示・検証操作なし、簡潔な報告選択とバックアップ', (tester) async {
    final (c, notifications) = await open(tester);
    expect(find.text('Malaria Care version 0.8'), findsOneWidget);
    expect(find.text('Nakata Design'), findsOneWidget);
    for (final text in ['検証モード', '実利用モード', 'PROTOTYPE', 'モック']) {
      expect(find.textContaining(text), findsNothing);
    }
    await tester.tap(find.byIcon(Icons.description_outlined).last);
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.textContaining('A3'), findsNothing);
    expect(find.textContaining('カレンダー：'), findsNothing);
    final period = find.byKey(const ValueKey('report-period'));
    await tester.tap(period);
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('report-date')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune).last);
    await tester.pumpAndSettle();
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('復元'), findsOneWidget);
    expect(find.textContaining('JSON'), findsNothing);
    expect(find.byKey(const ValueKey('preview-reminder')), findsNothing);
    expect(find.byKey(const ValueKey('preview-check')), findsNothing);
    for (final key in ['reminder-enabled', 'previous-dose-enabled']) {
      final toggle = find.byKey(ValueKey(key));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
    }
    expect(notifications.permissions, 2);
    expect(c.data.remindersEnabled, true);
    expect(c.data.nextDay, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
