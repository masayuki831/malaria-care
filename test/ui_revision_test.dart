import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printing/printing.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/services/store.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/ui/report_preview.dart';

import 'engine_test.dart' show fixture;
import 'widget_test.dart' show TestNotifications;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansJP',
    )..addFont(rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test('2週間ごと・水曜：開始後最初の水曜から14日間隔、年越しも維持', () {
    final rule = Rule(
      frequency: Frequency.weeks,
      anchor: DateTime(2026, 12, 28),
      interval: 2,
      weekdays: [3],
      usesWeekday: true,
    );
    final dates = [
      for (
        var d = DateTime(2026, 12, 27);
        !d.isAfter(DateTime(2027, 2, 1));
        d = plusDays(d, 1)
      )
        if (rule.matches(d)) ymd(d),
    ];
    expect(dates, ['2026-12-30', '2027-01-13', '2027-01-27']);
    expect(Rule.fromJson(rule.toJson()).matches(DateTime(2027, 1, 13)), true);
    expect(
      rule.reanchor(DateTime(2027, 1, 14)).matches(DateTime(2027, 1, 28)),
      true,
    );
  });
  test('旧N週間ルールは元の基準曜日と位相を保持する', () {
    final j = fixture(frequency: Frequency.weeks, interval: 2).toJson()
      ..['schemaVersion'] = 2;
    final data = AppData.parse(jsonEncode(j));
    expect(data.medicines.single.versions.single.rule.usesWeekday, false);
    expect(
      MedicationEngine(data)
          .generate(DateTime(2026, 11, 2), DateTime(2026, 11, 30))
          .map((d) => ymd(d.scheduled)),
      ['2026-11-02', '2026-11-16', '2026-11-30'],
    );
    expect(data.nextDay, false);
    expect(data.reminderHour, 20);
  });
  test('リマインダーは全体時刻を使い、当日自動服用済みでも通知し、翌日確認を作らない', () {
    final d = fixture()
      ..reminderHour = 18
      ..reminderMinute = 15
      ..nextDay = false;
    d.medicines.single.reminder = false;
    MedicationEngine(d).materialize(DateTime(2026, 11, 2, 9));
    final q = NotificationService.requests(d, DateTime(2026, 11, 2, 9));
    expect(q.first.at, DateTime(2026, 11, 2, 18, 15));
    expect(
      q.every(
        (r) => r.payload != 'check' && r.at.hour == 18 && r.at.minute == 15,
      ),
      true,
    );
    expect(q.length, 100);
    d.remindersEnabled = false;
    expect(NotificationService.requests(d, DateTime(2026, 11, 2, 9)), isEmpty);
    final restored = AppData.parse(d.export());
    expect(restored.remindersEnabled, false);
    expect(restored.reminderMinute, 15);
  });
  test('服用日の修正は時刻を新規保存せず、古い時刻付き記録は読み込み時に保持する', () {
    final d = fixture(),
        e = MedicationEngine(d),
        now = DateTime(2026, 11, 3, 9);
    e.record(
      e.generate(now, now).single,
      DoseStatus.confirmed,
      now,
      actual: DateTime(2026, 11, 3, 7, 30),
    );
    expect(d.doses.single.actual, DateTime(2026, 11, 3));
    d.doses.single.actual = DateTime(2026, 11, 3, 7, 30);
    expect(
      AppData.parse(d.export()).doses.single.actual,
      DateTime(2026, 11, 3, 7, 30),
    );
  });
  Future<AppController> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await c.init();
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets('派遣開始日・終了日をカレンダーで選択、保存・再読込できる', (tester) async {
    final c = await open(tester);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('プロフィールを編集'));
    await tester.pumpAndSettle();
    for (final entry in [
      ('start', '23', '2025-04-23'),
      ('end', '22', '2027-04-22'),
    ]) {
      final button = find.byKey(ValueKey('deployment-${entry.$1}'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DatePickerDialog>(find.byType(DatePickerDialog))
            .initialEntryMode,
        DatePickerEntryMode.calendarOnly,
      );
      await tester.tap(find.text(entry.$2).last);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining(entry.$3), findsOneWidget);
    }
    expect(find.widgetWithText(TextField, '派遣開始日'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(c.data.profile['start'], '2025-04-23');
    expect((await c.store.load(true))!.profile['end'], '2027-04-22');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('N週間ごとは曜日必須、登録行の編集を使い、服用時刻欄は表示しない', (tester) async {
    final c = await open(tester);
    await c.switchMode(false);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.medication_outlined).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('register-medicine')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '薬名'), '週の薬');
    final freq = find.byType(DropdownButtonFormField<Frequency>);
    await tester.ensureVisible(freq);
    await tester.tap(freq);
    await tester.pumpAndSettle();
    await tester.tap(find.text('N週間ごと').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '間隔（週）'), '2');
    expect(find.textContaining('服薬時刻'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(c.data.medicines, isEmpty);
    final wed = find.widgetWithText(ChoiceChip, '水');
    await tester.ensureVisible(wed);
    await tester.tap(wed);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(c.data.medicines.single.versions.single.rule.weekdays, [3]);
    expect(c.data.medicines.single.versions.single.rule.usesWeekday, true);
    expect(find.text('編集'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    final edit = find.byTooltip('登録薬を編集');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final memo = find.widgetWithText(TextFormField, 'メモ');
    await tester.ensureVisible(memo);
    await tester.enterText(memo, '備考だけ修正');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(c.data.medicines.single.versions.length, 1);
    expect(c.data.medicines.single.memo, '備考だけ修正');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('設定の全体リマインダーを保存し、記録の修正には時刻入力がない', (tester) async {
    final c = await open(tester);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, '服用リマインダー');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect((await c.store.load(true))!.remindersEnabled, false);
    expect(find.textContaining('翌日の服薬確認'), findsNothing);
    c.notifications.dispatch(c.engine.generate(c.now, c.now).single.id, null);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('いつもの毎日を、安心に。'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.calendar_month_outlined).last);
    await tester.pumpAndSettle();
    final cell = find.byKey(const ValueKey('calendar-day-2026-11-03'));
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('day-action-delay')));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
    final dayButton = find.widgetWithText(OutlinedButton, '服用日 2026-11-03');
    await tester.ensureVisible(dayButton);
    await tester.tap(dayButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
    await tester.tap(find.text('服用日を保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('日付全体の色で服用済み・飲み忘れ・在庫不足を区別、選択時も色を保持', (tester) async {
    final c = await open(tester);
    Color? bg(String date) =>
        (tester
                    .widget<Container>(
                      find.byKey(ValueKey('calendar-day-$date')),
                    )
                    .decoration
                as BoxDecoration)
            .color;
    final taken = bg('2026-11-03');
    expect(taken, const Color(0xffcbe9d8));
    final dose = c.engine.generate(c.now, c.now).single;
    await c.commit((d, e) => e.record(dose, DoseStatus.missed, c.now));
    await tester.pumpAndSettle();
    expect(bg('2026-11-03'), const Color(0xffffe9ae));
    await c.commit((d, e) {
      e.record(dose, DoseStatus.assumed, c.now);
      d.medicines.single.initial = 0;
      d.refills.clear();
      d.losses.clear();
      for (final row in d.doses) {
        row.explicit = null;
        row.actual = null;
        row.confirmedAt = null;
      }
    });
    await tester.pumpAndSettle();
    expect(bg('2026-11-03'), const Color(0xffffdede));
    expect(find.textContaining('未確認'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('PDF確認は開発用スイッチなし、名前付き保存・共有を実行できる', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('net.nfet.printing'),
          (call) async => <String, dynamic>{},
        );
    var saved = 0, shared = 0, emailed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReportPreview(
          bytes: Uint8List(0),
          onEmail: () async {
            emailed++;
          },
          onSave: () async {
            saved++;
          },
          onShare: () async {
            shared++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final preview = tester.widget<PdfPreview>(find.byType(PdfPreview));
    expect(preview.canDebug, false);
    expect(preview.useActions, false);
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '共有'));
    await tester.pumpAndSettle();
    expect(saved, 1);
    expect(shared, 1);
    await tester.tap(find.widgetWithText(FilledButton, 'PDFを添付してメールを作成'));
    await tester.pumpAndSettle();
    expect(emailed, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('net.nfet.printing'),
          null,
        );
  });
}
