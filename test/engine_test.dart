import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/domain/engine.dart';

AppData fixture({
  Frequency frequency = Frequency.daily,
  int interval = 1,
  double initial = 30,
  double quantity = 1,
  DateTime? end,
}) {
  final d = AppData.empty()..remindersEnabled = true;
  d.medicines.add(
    Medicine(
      id: 'a',
      name: 'テスト薬',
      start: DateTime(2026, 11, 2),
      end: end,
      initial: initial,
      versions: [
        ScheduleVersion(
          DateTime(2026, 11, 2),
          Rule(
            frequency: frequency,
            anchor: DateTime(2026, 11, 2),
            hour: 20,
            interval: interval,
          ),
          quantity,
        ),
      ],
    ),
  );
  return d;
}

void main() {
  test('TC01 毎日20時に予定を生成', () {
    final e = MedicationEngine(fixture());
    final result = e.generate(DateTime(2026, 11, 2), DateTime(2026, 11, 4));
    expect(result.map((d) => ymd(d.scheduled)), [
      '2026-11-02',
      '2026-11-03',
      '2026-11-04',
    ]);
    expect(result.every((d) => d.scheduled.hour == 20), true);
  });
  test('TC02 毎週月曜8時・予定がない日は生成しない', () {
    final data = fixture(frequency: Frequency.weekdays);
    data.medicines[0].versions[0] = ScheduleVersion(
      DateTime(2026, 11, 2),
      Rule(
        frequency: Frequency.weekdays,
        anchor: DateTime(2026, 11, 2),
        hour: 8,
      ),
      1,
    );
    final result = MedicationEngine(data)
        .generate(DateTime(2026, 11, 1), DateTime(2026, 11, 15));
    expect(result.map((d) => ymd(d.scheduled)), ['2026-11-02', '2026-11-09']);
    expect(result.every((d) => d.scheduled.hour == 8), true);
  });
  test('TC03 今日まで服用済みで未来日は予定', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 3, 12);
    final list = e.generate(DateTime(2026, 11, 2), DateTime(2026, 11, 4));
    expect(list[0].status(now), DoseStatus.assumed);
    expect(list[1].status(now), DoseStatus.assumed);
    expect(list[2].status(now), DoseStatus.planned);
  });
  test('TC04 飲んだ・確認日時を保存・冪等', () {
    final d = fixture(),
        e = MedicationEngine(d),
        now = DateTime(2026, 11, 2, 21);
    final dose = e.generate(now, now).single;
    e.record(dose, DoseStatus.confirmed, now);
    e.record(dose, DoseStatus.confirmed, now);
    expect(d.doses.single.confirmedAt, now);
    expect(e.balance('a', now, now), 29);
  });
  test('TC05 入力なしで今日までを服用済み、未来日は予定にする', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 3, 0);
    e.materialize(now);
    expect(e.data.doses.length, 2);
    expect(
      e.data.doses.every((d) => d.status(now) == DoseStatus.assumed),
      true,
    );
    expect(e.balance('a', now, now), 28);
    expect(
      e.generate(plusDays(now, 1), plusDays(now, 1)).single.status(now),
      DoseStatus.planned,
    );
  });
  test('TC06 日内の時刻で服用状態と残数は変わらない', () {
    final e = MedicationEngine(fixture());
    for (final hour in [0, 8, 20, 23]) {
      final now = DateTime(2026, 11, 3, hour);
      expect(e.balance('a', now, now), 28);
      expect(e.generate(now, now).single.status(now), DoseStatus.assumed);
    }
  });
  test('TC07 飲み忘れの修正で在庫が戻る', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 3, 8);
    final d = e.generate(DateTime(2026, 11, 2), now).first;
    expect(e.balance('a', now, now), 28);
    e.record(d, DoseStatus.missed, now);
    expect(e.balance('a', now, now), 29);
  });
  test('TC08 服用済みの自動記録は再起動後も重複しない', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 4, 8);
    e.materialize(now);
    final restored = MedicationEngine(AppData.parse(e.data.export()));
    restored.materialize(now);
    expect(restored.data.doses.length, 3);
    expect(restored.balance('a', now, now), 27);
  });
  test('TC09 初期30から3回で27', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 4, 21);
    expect(e.balance('a', now, now), 27);
  });
  test('TC10 みなし→忘れ→確認→みなしでも一致', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 4, 21);
    e.materialize(now);
    final d = e.data.doses.first;
    for (var i = 0; i < 5; i++) {
      e.record(d, DoseStatus.missed, now);
      expect(e.balance('a', now, now), 28);
      e.record(d, DoseStatus.confirmed, now, actual: d.scheduled);
      expect(e.balance('a', now, now), 27);
      e.record(d, DoseStatus.assumed, now);
      expect(e.balance('a', now, now), 27);
    }
  });
  test('TC11 補充30を加算・未来補充は現在に加算しない', () {
    final data = fixture(initial: 10),
        e = MedicationEngine(data),
        now = DateTime(2026, 11, 2, 8);
    data.refills.add(Refill('r', 'a', day(now), 30, ''));
    data.refills.add(Refill('r2', 'a', plusDays(now, 1), 20, ''));
    expect(e.balance('a', now, now), 39);
  });
  test('TC12 元の予定日と実際の日時を別保存', () {
    final data = fixture(frequency: Frequency.weekdays),
        e = MedicationEngine(data),
        now = DateTime(2026, 11, 3, 21);
    final d = e.generate(DateTime(2026, 11, 2), now).single;
    e.shift(d, now, now, reanchor: false);
    expect(d.scheduled, DateTime(2026, 11, 2, 20));
    expect(data.doses.single.actual, day(now));
    expect(data.doses.single.delayed, true);
  });
  test('TC13 元の月曜日を維持し11/9', () {
    final e = MedicationEngine(fixture(frequency: Frequency.weekdays)),
        now = DateTime(2026, 11, 3, 21);
    e.shift(
      e.generate(DateTime(2026, 11, 2), now).single,
      now,
      now,
      reanchor: false,
    );
    expect(
      ymd(e.generate(plusDays(now, 1), DateTime(2026, 11, 17)).first.scheduled),
      '2026-11-09',
    );
  });
  test('TC14 火曜日に変更し11/10・11/17', () {
    final e = MedicationEngine(fixture(frequency: Frequency.weekdays)),
        now = DateTime(2026, 11, 3, 21);
    e.shift(
      e.generate(DateTime(2026, 11, 2), now).single,
      now,
      now,
      reanchor: true,
    );
    expect(
      e
          .generate(plusDays(now, 1), DateTime(2026, 11, 17))
          .map((d) => ymd(d.scheduled)),
      ['2026-11-10', '2026-11-17'],
    );
  });
  test('TC15 変更後も過去履歴と変更前ルールを保持', () {
    final data = fixture(frequency: Frequency.weekdays),
        e = MedicationEngine(data),
        now = DateTime(2026, 11, 10, 9);
    e.materialize(now);
    final ids = data.doses.map((d) => d.id).toList();
    e.shift(data.doses.last, now, now, reanchor: true, reason: '利用者が選択');
    expect(data.doses.map((d) => d.id), ids);
    expect(data.medicines.single.versions.length, 2);
    expect(data.medicines.single.versions.first.rule.weekdays, [1]);
    expect(data.medicines.single.versions.last.rule.weekdays, [2]);
    expect(data.medicines.single.versions.last.reason, '利用者が選択');
    expect(AppData.parse(data.export()).doses.length, 2);
  });
  test('TC16 遅延服薬は実際の日に1回だけ減算', () {
    final e = MedicationEngine(fixture(frequency: Frequency.weekdays)),
        now = DateTime(2026, 11, 3, 21);
    final source = e.generate(DateTime(2026, 11, 2), now).single;
    e.shift(source, now, now, reanchor: true);
    expect(e.balance('a', DateTime(2026, 11, 2, 23), now), 30);
    expect(e.balance('a', now, now), 29);
    final saved = e.data.doses.single;
    e.record(saved, DoseStatus.confirmed, now, actual: now);
    expect(e.balance('a', now, now), 29);
  });
  test('TC17 毎日残3錠の在庫切れ・複数補充・終了日', () {
    final data = fixture(initial: 3),
        e = MedicationEngine(data),
        now = DateTime(2026, 11, 2, 9);
    expect(e.stockout('a', now), DateTime(2026, 11, 4));
    data.refills.add(Refill('r', 'a', DateTime(2026, 11, 3), 2, ''));
    expect(e.stockout('a', now), DateTime(2026, 11, 6));
    data.medicines.single.end = DateTime(2026, 11, 4);
    expect(e.stockout('a', now), isNull);
  });
  test('TC20 JSON完全復元・変更履歴と補充を含む', () {
    final data = fixture(frequency: Frequency.weekdays),
        e = MedicationEngine(data),
        now = DateTime(2026, 11, 3, 21);
    data.refills.add(Refill('r', 'a', DateTime(2026, 11, 3), 10, '処方'));
    e.shift(
      e.generate(DateTime(2026, 11, 2), now).single,
      now,
      now,
      reanchor: true,
    );
    final restored = AppData.parse(data.export());
    expect(restored.export(), data.export());
    expect(MedicationEngine(restored).balance('a', now, now), 39);
  });
  test('TC22 過去修正は以降の残数と報告集計に反映', () {
    final e = MedicationEngine(fixture()), now = DateTime(2026, 11, 4, 21);
    e.materialize(now);
    final last = e.data.doses.last;
    expect(e.balanceAfter(last, now), 27);
    e.record(e.data.doses.first, DoseStatus.missed, now);
    expect(e.balanceAfter(last, now), 28);
    expect(e.summary('a', DateTime(2026, 11, 2), now, now)['missed'], 1);
  });
  test('3日ごと・2週間ごと・端数服薬', () {
    final now = DateTime(2026, 11, 8, 21),
        e = MedicationEngine(
          fixture(frequency: Frequency.days, interval: 3, quantity: .5),
        );
    expect(e.generate(DateTime(2026, 11, 1), now).map((d) => d.scheduled.day), [
      2,
      5,
      8,
    ]);
    expect(e.balance('a', now, now), 28.5);
    final weeks = MedicationEngine(
      fixture(frequency: Frequency.weeks, interval: 2),
    );
    expect(
      weeks
          .generate(DateTime(2026, 11, 2), DateTime(2026, 11, 30))
          .map((d) => d.scheduled.day),
      [2, 16, 30],
    );
  });
  test('未来の記録・実服薬日は拒否', () {
    final e = MedicationEngine(fixture()),
        now = DateTime(2026, 11, 2, 9),
        d = e.generate(plusDays(now, 1), plusDays(now, 1)).single;
    expect(() => e.record(d, DoseStatus.confirmed, now), throwsArgumentError);
    expect(() => e.record(d, DoseStatus.missed, now), throwsArgumentError);
    expect(
      () => e.record(
        d,
        DoseStatus.confirmed,
        DateTime(2026, 11, 2, 21),
        actual: DateTime(2026, 11, 3),
      ),
      throwsArgumentError,
    );
  });
  test('JSON不正・未知schema・重複ID・参照切れ・NaN用量を拒否', () {
    expect(() => AppData.parse('not json'), throwsFormatException);
    final source = fixture().toJson();
    source['schemaVersion'] = 99;
    expect(() => AppData.parse(jsonEncode(source)), throwsFormatException);
    final duplicate = fixture();
    duplicate.medicines.add(duplicate.medicines.first);
    expect(() => AppData.parse(duplicate.export()), throwsFormatException);
    final bad = fixture();
    bad.refills.add(Refill('r', 'unknown', DateTime(2026, 11, 2), 1, ''));
    expect(() => bad.validate(), throwsFormatException);
    final invalid = fixture();
    invalid.medicines.single.versions[0] = ScheduleVersion(
      DateTime(2026, 11, 2),
      Rule(frequency: Frequency.daily, anchor: DateTime(2026, 11, 2)),
      double.nan,
    );
    expect(() => invalid.validate(), throwsFormatException);
  });
  test('予定のバージョン変更で過去の服薬量を保持', () {
    final data = fixture(),
        e = MedicationEngine(data),
        now = DateTime(2026, 11, 3, 21);
    e.materialize(now);
    data.medicines.single.versions.add(
      ScheduleVersion(
        DateTime(2026, 11, 4),
        Rule(
          frequency: Frequency.days,
          anchor: DateTime(2026, 11, 4),
          interval: 2,
        ),
        2,
      ),
    );
    final list = e.generate(DateTime(2026, 11, 2), DateTime(2026, 11, 6));
    expect(list.map((d) => d.quantity), [1, 1, 2, 2]);
    expect(e.balance('a', now, now), 28);
    data.validate();
  });
  test('日付差は暦日で算出・開始前と終了後に生成しない', () {
    expect(
      daysBetween(DateTime(2026, 10, 31, 23), DateTime(2026, 11, 1, 1)),
      1,
    );
    final e = MedicationEngine(fixture(end: DateTime(2026, 11, 3)));
    expect(e.generate(DateTime(2026, 10, 31), DateTime(2026, 11, 8)).length, 2);
  });
}
