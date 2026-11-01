import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/services/report.dart';

AppData stockFixture({
  double initial = 2,
  Frequency frequency = Frequency.daily,
}) {
  final data = AppData.empty();
  data.profile = {
    'name': 'サンプル 花子（架空）',
    'cohort': '2025年度1次隊',
    'job': 'コミュニティ開発',
    'location': 'ガーナ／アクラ（デモ）',
    'start': '2025-04-22',
    'end': '2027-04-21',
  };
  data.medicines = [
    Medicine(
      id: 'a',
      name: '予防薬A（デモ）',
      start: DateTime(2026, 10, 29),
      initial: initial,
      versions: [
        ScheduleVersion(
          DateTime(2026, 10, 29),
          Rule(frequency: frequency, anchor: DateTime(2026, 10, 29), hour: 20),
          1,
        ),
      ],
    ),
  ];
  return data;
}

AppData reportSample() {
  final d = stockFixture();
  final start = DateTime(2025, 4, 22), now = DateTime(2026, 11, 4, 23);
  final med = d.medicines.single;
  med.start = start;
  med.versions[0] = ScheduleVersion(
    start,
    Rule(frequency: Frequency.daily, anchor: start, hour: 20),
    1,
  );
  med.initial = (daysBetween(start, DateTime(2026, 10, 30)) + 1 - 1 + 2)
      .toDouble();
  d.losses.add(Refill('loss', 'a', DateTime(2026, 9, 9), 2, '破損（架空）'));
  d.refills.add(Refill('refill', 'a', DateTime(2026, 11, 3), 100, '追加入手（架空）'));
  final e = MedicationEngine(d);
  e.materialize(now);
  e.record(
    d.doses.firstWhere((x) => ymd(x.scheduled) == '2026-10-01'),
    DoseStatus.missed,
    now,
  );
  e.record(
    d.doses.firstWhere((x) => ymd(x.scheduled) == '2026-11-03'),
    DoseStatus.confirmed,
    now,
    actual: DateTime(2026, 11, 3, 20),
  );
  return d;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('改修TC01～05：26か月の1ページ帳票用データと日本語PDF生成', () async {
    final data = reportSample(), now = DateTime(2026, 11, 4, 23);
    final r = ReportService(data, now, day(now));
    expect(r.from, DateTime(2025, 4, 22));
    expect(r.calendarEnd, DateTime(2027, 5, 21));
    expect(r.months.length, 26);
    expect(r.totals.balance, 98);
    expect(r.issues, isEmpty);
    final bytes = await r.pdf(
      verifiedBalance: 98,
      fontData: ByteData.sublistView(
        File('assets/fonts/NotoSansJP-Regular.ttf').readAsBytesSync(),
      ),
    );
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    // Regular tests must not overwrite an opened user-facing sample PDF.
    final artifacts = Directory(
      const bool.fromEnvironment('UPDATE_REPORT_SAMPLES')
          ? '.'
          : 'build/test-artifacts',
    );
    await Directory('${artifacts.path}/verification').create(recursive: true);
    await File('${artifacts.path}/sample-report.pdf').writeAsBytes(bytes);
    await File('${artifacts.path}/sample-backup.json')
        .writeAsString(data.export());
    await File('${artifacts.path}/sample-email.txt')
        .writeAsString('${r.subject}\n\n${r.body}');
    final cells = <Map<String, dynamic>>[];
    for (
      var date = r.from;
      !date.isAfter(r.calendarEnd);
      date = plusDays(date, 1)
    ) {
      final c = r.cell(date);
      cells.add({
        'date': ymd(date),
        'mark': c.mark,
        'balance': c.balance,
        'category': c.category,
        'shortageDate': c.shortageDate,
      });
    }
    await File('${artifacts.path}/verification/report-cells.json')
        .writeAsString(jsonEncode(cells));
    expect(cells.length, daysBetween(r.from, r.calendarEnd) + 1);
    expect(cells.map((c) => c['date']).toSet().length, cells.length);
  });
  test('改修TC06/09：同日は入手→服薬→消失、数量累計と日別残数', () {
    final d = stockFixture(initial: 5),
        e = MedicationEngine(d),
        now = DateTime(2026, 10, 29, 23);
    d.refills.add(Refill('r', 'a', day(now), 10, ''));
    d.losses.add(Refill('l', 'a', day(now), 3, ''));
    final ledger = e.ledger(now), t = ledger.totals['a']!;
    expect(t.acquired, 15);
    expect(t.taken, 1);
    expect(t.lost, 3);
    expect(t.balance, 11);
    expect(ledger.at('a', now).closing, 11);
  });
  test('PDFの入手・消失数量を日別合計で表示し、残数・未来の表示を維持', () async {
    final d = stockFixture(initial: 100), now = DateTime(2026, 11, 4, 23);
    d.refills.addAll([
      Refill('r1', 'a', DateTime(2026, 10, 30), 10, ''),
      Refill('r2', 'a', DateTime(2026, 10, 30), 20, ''),
      Refill('r3', 'a', DateTime(2026, 10, 31), 30, ''),
      Refill('r4', 'a', DateTime(2026, 11, 3), 999, ''),
      Refill('future', 'a', DateTime(2026, 11, 5), 30, ''),
    ]);
    d.losses.addAll([
      Refill('l1', 'a', DateTime(2026, 10, 30), 2, ''),
      Refill('l2', 'a', DateTime(2026, 10, 30), 3, ''),
      Refill('l3', 'a', DateTime(2026, 11, 1), 5, ''),
      Refill('l4', 'a', DateTime(2026, 11, 3), 999, ''),
    ]);
    final before = d.export(), r = ReportService(d, now, day(now));
    expect(r.cell(DateTime(2026, 10, 29)).mark, '済+100');
    expect(r.cell(DateTime(2026, 10, 30)).mark, '済+30-5');
    expect(r.cell(DateTime(2026, 10, 30)).balance, 123);
    expect(r.cell(DateTime(2026, 10, 31)).mark, '済+30');
    expect(r.cell(DateTime(2026, 11, 1)).mark, '済-5');
    expect(r.cell(DateTime(2026, 11, 2)).mark, '済');
    expect(r.cell(DateTime(2026, 11, 3)).mark, '済+999-999');
    expect(r.cell(DateTime(2026, 11, 5)).mark, '予');
    expect(r.cell(DateTime(2026, 11, 5)).balance, isNull);
    expect(r.issues, isEmpty);
    final bytes = await r.pdf(
      verifiedBalance: r.totals.balance,
      fontData: ByteData.sublistView(
        File('assets/fonts/NotoSansJP-Regular.ttf').readAsBytesSync(),
      ),
    );
    final artifacts = Directory('build/test-artifacts')
      ..createSync(recursive: true);
    await File('${artifacts.path}/quantity-report.pdf').writeAsBytes(bytes);
    expect(d.export(), before);
  });
  test('改修TC07/08：過去入手の追加・編集・削除で全期間を再計算', () {
    final d = stockFixture(),
        e = MedicationEngine(d),
        now = DateTime(2026, 11, 2, 23);
    expect(e.balance('a', now, now), 0);
    d.refills.add(Refill('r', 'a', DateTime(2026, 10, 31), 10, ''));
    expect(e.balance('a', now, now), 7);
    d.refills[0] = Refill('r', 'a', DateTime(2026, 11, 1), 20, '編集');
    expect(e.balance('a', now, now), 18);
    d.refills.clear();
    expect(e.balance('a', now, now), 0);
    expect(e.ledger(now).at('a', DateTime(2026, 10, 31)).unavailable.length, 1);
  });
  test('改修TC09：消失の登録・編集・削除を累計と残数に反映', () {
    final d = stockFixture(initial: 20),
        e = MedicationEngine(d),
        now = DateTime(2026, 10, 30, 23);
    d.losses.add(Refill('l', 'a', DateTime(2026, 10, 29), 3, ''));
    expect(e.balance('a', now, now), 15);
    d.losses[0] = Refill('l', 'a', DateTime(2026, 10, 30), 5, '修正');
    expect(e.ledger(now).totals['a']!.lost, 5);
    expect(e.balance('a', now, now), 13);
    d.losses.clear();
    expect(e.balance('a', now, now), 18);
  });
  test('改修TC10/11：10/30残0→3日間0→11/3入手100後99→11/4は98', () {
    final d = stockFixture(),
        e = MedicationEngine(d),
        now = DateTime(2026, 11, 4, 23);
    d.refills.add(Refill('r', 'a', DateTime(2026, 11, 3), 100, ''));
    final ledger = e.ledger(now);
    for (final date in [
      DateTime(2026, 10, 30),
      DateTime(2026, 10, 31),
      DateTime(2026, 11, 1),
      DateTime(2026, 11, 2),
    ])
      expect(ledger.at('a', date).closing, 0);
    expect(ledger.at('a', DateTime(2026, 11, 3)).closing, 99);
    expect(ledger.at('a', DateTime(2026, 11, 4)).closing, 98);
    expect(
      ledger.at('a', DateTime(2026, 10, 31)).unavailable.single.explicit,
      isNull,
    );
    expect(ledger.totals['a']!.taken, 4);
    expect(ledger.totals['a']!.missed, 0);
    expect(ledger.statuses['a@2026-10-31'], DoseStatus.stockout);
  });
  test('改修TC12：週1回の対象日だけ服薬、予定なしは残数を維持', () {
    final d = stockFixture(frequency: Frequency.weekdays),
        now = DateTime(2026, 11, 10, 23);
    final r = ReportService(d, now, day(now));
    expect(r.cell(DateTime(2026, 11, 2)).category, 'taken');
    expect(r.cell(DateTime(2026, 11, 3)).category, 'none');
    expect(
      r.cell(DateTime(2026, 11, 3)).balance,
      r.cell(DateTime(2026, 11, 2)).balance,
    );
    expect(r.cell(DateTime(2026, 11, 9)).category, 'taken');
  });
  test('改修TC13：月曜→火曜の変更と遅延を1回だけ計上', () {
    final d = stockFixture(initial: 10, frequency: Frequency.weekdays),
        e = MedicationEngine(d),
        now = DateTime(2026, 11, 3, 23);
    final original = e
        .generate(DateTime(2026, 11, 2), DateTime(2026, 11, 2))
        .single;
    e.shift(original, DateTime(2026, 11, 3, 8), now, reanchor: true);
    final r = ReportService(d, now, day(now));
    expect(r.cell(DateTime(2026, 11, 2)).mark, '遅');
    expect(r.cell(DateTime(2026, 11, 3)).mark, '済');
    expect(r.totals.taken, 1);
    expect(r.totals.missed, 0);
    expect(r.totals.balance, 9);
    expect(r.cell(DateTime(2026, 11, 9)).mark, '・');
    expect(r.cell(DateTime(2026, 11, 10)).mark, '予');
    expect(d.doses.single.scheduled, original.scheduled);
  });
  test('改修TC14：過去の服薬修正はそれ以降の全残数に反映', () {
    final d = stockFixture(initial: 20),
        e = MedicationEngine(d),
        now = DateTime(2026, 11, 3, 23);
    e.materialize(now);
    expect(e.balance('a', now, now), 14);
    e.record(d.doses.first, DoseStatus.missed, now);
    expect(e.balance('a', now, now), 15);
    expect(e.ledger(now).at('a', DateTime(2026, 11, 1)).closing, 17);
  });
  test('本人確認済みは在庫0でも消さず不整合。過去入手で解消', () {
    final d = stockFixture(initial: 0),
        e = MedicationEngine(d),
        now = DateTime(2026, 10, 29, 23);
    final dose = e.generate(now, now).single;
    e.record(dose, DoseStatus.confirmed, now, actual: dose.scheduled);
    var ledger = e.ledger(now);
    expect(ledger.totals['a']!.balance, 0);
    expect(ledger.statuses[dose.id], DoseStatus.confirmed);
    expect(ledger.issues.length, 1);
    d.refills.add(Refill('r', 'a', day(now), 2, ''));
    ledger = e.ledger(now);
    expect(ledger.issues, isEmpty);
    expect(ledger.totals['a']!.balance, 1);
    expect(d.doses.single.explicit, DoseStatus.confirmed);
  });
  test('0到達日と次の不足日を区別・未来残数は表示しない', () {
    final d = stockFixture(),
        now = DateTime(2026, 10, 29, 23),
        r = ReportService(d, now, day(now));
    expect(r.forecast.zeroOn, DateTime(2026, 10, 30));
    expect(r.forecast.insufficientOn, DateTime(2026, 10, 31));
    expect(r.cell(DateTime(2026, 10, 31)).shortageDate, true);
    expect(r.cell(DateTime(2026, 10, 30)).balance, isNull);
    expect(r.cell(DateTime(2026, 10, 30)).category, 'future');
  });
  test('報告日で履歴・入手・消失・本人実服薬を打ち切る', () {
    final d = stockFixture(initial: 20), now = DateTime(2026, 11, 4, 23);
    d.refills.add(Refill('r', 'a', DateTime(2026, 11, 3), 100, ''));
    d.losses.add(Refill('l', 'a', DateTime(2026, 11, 4), 10, ''));
    final r = ReportService(d, now, DateTime(2026, 10, 30));
    expect(r.totals.acquired, 20);
    expect(r.totals.taken, 2);
    expect(r.totals.lost, 0);
    expect(r.totals.balance, 18);
    expect(r.cell(DateTime(2026, 11, 3)).balance, isNull);
  });
  test('既に在庫0の場合も、0到達日は過去の実際の日を保持', () {
    final d = stockFixture(), now = DateTime(2026, 11, 2, 23);
    final forecast = MedicationEngine(d).forecast('a', now);
    expect(forecast.zeroOn, DateTime(2026, 10, 30));
    expect(forecast.insufficientOn, DateTime(2026, 11, 3));
  });
  test('日付の月加算・月途中の26か月・うるう日を保持', () {
    expect(nextCalendarMonth(DateTime(2027, 1, 31)), DateTime(2027, 2, 28));
    expect(nextCalendarMonth(DateTime(2028, 1, 31)), DateTime(2028, 2, 29));
    final d = stockFixture();
    d.profile['start'] = '2027-04-22';
    d.profile['end'] = '2029-04-21';
    final r = ReportService(d, DateTime(2028, 3, 1, 23), DateTime(2028, 3, 1));
    expect(r.months.length, 26);
    expect(r.cell(DateTime(2028, 2, 29)).category, isNot('outside'));
    expect(r.cell(DateTime(2027, 4, 21)).category, 'outside');
  });
  test('v1 JSONは履歴を消さずv3へ移行・入手消失の往復復元', () {
    final d = stockFixture();
    d.losses.add(Refill('l', 'a', DateTime(2026, 10, 29), 1, ''));
    expect(AppData.parse(d.export()).losses.single.quantity, 1);
    final old = d.toJson()
      ..['schemaVersion'] = 1
      ..remove('losses');
    final restored = AppData.parse(jsonEncode(old));
    expect(restored.losses, isEmpty);
    expect(restored.medicines.single.name, d.medicines.single.name);
    expect(restored.toJson()['schemaVersion'], 3);
  });
  test('単一薬の使用期間制約・旧薬を残して切替可能', () {
    final d = stockFixture();
    final newer = Medicine(
      id: 'b',
      name: '新薬',
      start: DateTime(2026, 11, 1),
      initial: 10,
      versions: [
        ScheduleVersion(
          DateTime(2026, 11, 1),
          Rule(frequency: Frequency.daily, anchor: DateTime(2026, 11, 1)),
          1,
        ),
      ],
    );
    expect(d.overlaps(newer), true);
    d.medicines.single.end = DateTime(2026, 10, 31);
    expect(d.overlaps(newer), false);
    d.medicines.add(newer);
    expect(d.hasOverlappingMedicines, false);
    expect(d.medicineAt(DateTime(2026, 11, 1))!.id, 'b');
    expect(d.medicineAt(DateTime(2026, 10, 31))!.id, 'a');
    final future = MedicationEngine(d)
        .forecast('b', DateTime(2026, 10, 31, 23));
    expect(future.zeroOn, DateTime(2026, 11, 10));
    expect(future.insufficientOn, DateTime(2026, 11, 11));
  });
  test('残数未一致・不整合のままのPDF生成を拒否、差分を消失にしない', () async {
    final d = stockFixture(),
        now = DateTime(2026, 10, 29, 23),
        r = ReportService(d, now, day(now));
    await expectLater(r.pdf(verifiedBalance: 999), throwsArgumentError);
    expect(d.losses, isEmpty);
    final e = MedicationEngine(d);
    d.medicines.single.initial = 0;
    e.record(e.generate(now, now).single, DoseStatus.confirmed, now);
    await expectLater(
      ReportService(d, now, day(now)).pdf(verifiedBalance: 0),
      throwsArgumentError,
    );
  });
}
