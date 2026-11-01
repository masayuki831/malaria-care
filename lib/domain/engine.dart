import 'model.dart';
import 'inventory.dart';

class MedicationEngine {
  final AppData data;
  MedicationEngine(this.data);

  List<Dose> generate(DateTime from, DateTime to) {
    if (daysBetween(from, to) > 36600) throw ArgumentError('対象期間が長すぎます。');
    final result = <Dose>[];
    final saved = {for (final d in data.doses) d.id: d};
    for (final m in data.medicines) {
      for (
        var date = day(from.isAfter(m.start) ? from : m.start);
        !date.isAfter(day(to));
        date = plusDays(date, 1)
      ) {
        if (m.end != null && date.isAfter(day(m.end!))) break;
        final v = m.versionAt(date);
        if (!v.rule.matches(date)) continue;
        final id = '${m.id}@${ymd(date)}';
        result.add(
          saved[id] ??
              Dose(
                id: id,
                medicineId: m.id,
                name: m.name,
                scheduled: DateTime(
                  date.year,
                  date.month,
                  date.day,
                  v.rule.hour,
                  v.rule.minute,
                ),
                quantity: v.dose,
              ),
        );
      }
    }
    // Persisted history is authoritative, even after later schedule edits.
    final included = result.map((d) => d.id).toSet();
    for (final d in data.doses) {
      if (!day(d.scheduled).isBefore(day(from)) &&
          !day(d.scheduled).isAfter(day(to)) &&
          included.add(d.id))
        result.add(d);
    }
    result.sort((a, b) => a.scheduled.compareTo(b.scheduled));
    return result;
  }

  /// Corrects initial registration without discarding explicitly edited history.
  void changeMedicineStart(String medicineId, DateTime date, DateTime now) {
    final m = data.medicines.firstWhere((m) => m.id == medicineId);
    final start = day(date);
    if (start == day(m.start)) return;
    if (m.end != null && start.isAfter(day(m.end!)))
      throw ArgumentError('開始日は終了日以前を選んでください。');
    if (m.versions.length > 1 && !start.isBefore(m.versions[1].effective)) {
      throw ArgumentError('開始日は最初のスケジュール変更日より前を選んでください。変更履歴は保持しています。');
    }
    if ([
      ...data.refills,
      ...data.losses,
    ].any((r) => r.medicineId == medicineId && day(r.date).isBefore(start))) {
      throw ArgumentError('変更後の開始日より前に入手・消失の登録があります。該当行の日付を先に修正してください。');
    }
    final first = m.versions.first;
    final r = first.rule;
    final rule = Rule(
      frequency: r.frequency,
      anchor: start,
      interval: r.interval,
      hour: r.hour,
      minute: r.minute,
      weekdays: r.frequency == Frequency.weeks && !r.usesWeekday
          ? [r.anchor.weekday]
          : r.weekdays,
      usesWeekday: r.frequency == Frequency.weeks ? true : r.usesWeekday,
    );
    final candidate = Medicine(
      id: m.id,
      name: m.name,
      start: start,
      end: m.end,
      initial: m.initial,
      versions: [
        ScheduleVersion(start, rule, first.dose, first.reason),
        ...m.versions.skip(1),
      ],
    );
    if (data.overlaps(candidate)) throw ArgumentError('開始日が他の薬の使用期間と重なります。');
    final remove = <String>{};
    for (final d in data.doses.where((d) => d.medicineId == medicineId)) {
      final inPeriod = !day(d.scheduled).isBefore(start);
      final v = inPeriod ? candidate.versionAt(d.scheduled) : null;
      final compatible =
          inPeriod &&
          (d.actual == null || !day(d.actual!).isBefore(start)) &&
          v!.rule.matches(d.scheduled) &&
          v.rule.hour == d.scheduled.hour &&
          v.rule.minute == d.scheduled.minute &&
          v.dose == d.quantity;
      if (compatible) continue;
      if (d.explicit != null ||
          d.actual != null ||
          d.note.isNotEmpty ||
          d.later) {
        throw ArgumentError(
          '${ymd(d.scheduled)}の修正済み服用記録と開始日が合いません。記録を保持したまま変更を中止しました。',
        );
      }
      remove.add(d.id);
    }
    m.start = start;
    m.versions = candidate.versions;
    data.doses.removeWhere((d) => remove.contains(d.id));
    materialize(now);
  }

  void materialize(DateTime now) {
    if (data.medicines.isEmpty) return;
    final start = data.medicines
        .map((m) => m.start)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final existing = data.doses.map((d) => d.id).toSet();
    for (final d in generate(start, now)) {
      if (!day(d.scheduled).isAfter(day(now)) && existing.add(d.id))
        data.doses.add(d);
    }
  }

  /// A destination must have neither another schedule nor another intake record.
  /// Excluding the source permits correcting or restoring the same record.
  void validateActualDay(Dose source, DateTime actual, DateTime now) {
    final date = day(actual);
    final medicine = data.medicines.firstWhere(
      (m) => m.id == source.medicineId,
    );
    if (date.isAfter(day(now)) || date.isBefore(day(medicine.start))) {
      throw ArgumentError('実際の服薬日は使用開始以降、今日以前を指定してください。');
    }
    final occupied =
        generate(date, date).any((d) => d.id != source.id) ||
        data.doses.any(
          (d) =>
              d.id != source.id && d.actual != null && day(d.actual!) == date,
        );
    if (occupied) {
      throw ArgumentError('${ymd(date)}には服用予定または記録があります。予定なしの日を選んでください。');
    }
  }

  Dose record(
    Dose source,
    DoseStatus status,
    DateTime now, {
    DateTime? actual,
  }) {
    if (day(source.scheduled).isAfter(day(now)) ||
        status == DoseStatus.planned ||
        status == DoseStatus.stockout)
      throw ArgumentError('未来の予定は服薬記録に変更できません。');
    if (status == DoseStatus.confirmed) {
      validateActualDay(source, actual ?? now, now);
    }
    final index = data.doses.indexWhere((d) => d.id == source.id);
    final target = index < 0 ? source : data.doses[index];
    if (index < 0) data.doses.add(target);
    target.explicit = status == DoseStatus.assumed ? null : status;
    target.actual = status == DoseStatus.confirmed ? day(actual ?? now) : null;
    target.confirmedAt = status == DoseStatus.confirmed ? now : null;
    return target;
  }

  void shift(
    Dose source,
    DateTime actual,
    DateTime now, {
    required bool reanchor,
    String reason = '',
  }) {
    validateActualDay(source, actual, now);
    final m = data.medicines.firstWhere((m) => m.id == source.medicineId);
    final effective = plusDays(day(actual), 1);
    if (reanchor && m.versions.any((v) => !v.effective.isBefore(effective))) {
      throw ArgumentError('この日以降に変更履歴があります。後の変更を確認してから登録してください。');
    }
    final applies = plusDays(day(now), 1);
    if (reanchor && m.versions.any((v) => !v.effective.isBefore(applies))) {
      throw ArgumentError('翌日以降の変更が既にあります。');
    }
    final previous = m.versionAt(source.scheduled);
    // Validate before materializing, so a rejected shift leaves history intact.
    if (day(source.scheduled).isAfter(day(now))) {
      throw ArgumentError('未来の予定は服薬記録に変更できません。');
    }
    materialize(now);
    record(source, DoseStatus.confirmed, now, actual: actual);
    if (reanchor) {
      // Changes only affect future dates; already elapsed schedules remain intact.
      m.versions.add(
        ScheduleVersion(
          applies,
          previous.rule.reanchor(actual),
          previous.dose,
          reason.isEmpty
              ? '${ymd(source.scheduled)}予定分を${ymd(actual)}に服薬。利用者が基準日変更を選択。'
              : reason,
        ),
      );
    }
  }

  InventoryLedger ledger(DateTime asOf) {
    final start = data.medicines.isEmpty
        ? day(asOf)
        : data.medicines
              .map((m) => m.start)
              .reduce((a, b) => a.isBefore(b) ? a : b);
    return InventoryLedger(data, generate(start, asOf), asOf);
  }

  DoseStatus effectiveStatus(Dose d, DateTime now) => ledger(now).status(d);
  double balance(String medicineId, DateTime at, DateTime now) {
    final cutoff = at.isAfter(now) ? now : at;
    return ledger(cutoff).totals[medicineId]?.balance ?? 0;
  }

  double balanceAfter(Dose d, DateTime now) {
    final at = d.consumptionAt(now) ?? d.scheduled;
    return balance(d.medicineId, at, now);
  }

  StockForecast forecast(
    String medicineId,
    DateTime asOf, {
    InventoryLedger? snapshot,
  }) {
    final history = snapshot ?? ledger(asOf);
    var stock = history.totals[medicineId]?.balance ?? 0;
    DateTime? zero;
    if (stock <= 0) {
      var previous = -1.0;
      for (final entry in history.days.entries.where(
        (e) => e.key.startsWith('$medicineId@'),
      )) {
        final value = entry.value;
        if (value.closing == 0 &&
            (previous != 0 ||
                value.acquired > 0 ||
                value.taken > 0 ||
                value.lost > 0))
          zero = DateTime.parse(entry.key.substring('$medicineId@'.length));
        previous = value.closing;
      }
      zero ??= day(asOf);
    }
    final horizon = plusDays(asOf, 3650);
    final doses = generate(asOf, horizon)
        .where(
          (d) =>
              d.medicineId == medicineId &&
              day(d.scheduled).isAfter(day(asOf)) &&
              !(d.explicit == DoseStatus.confirmed &&
                  d.actual != null &&
                  !day(d.actual!).isAfter(day(asOf))),
        )
        .toList();
    final receipt = <String, double>{}, losses = <String, double>{};
    final medicine = data.medicines.firstWhere((m) => m.id == medicineId);
    if (day(medicine.start).isAfter(day(asOf)))
      receipt[ymd(medicine.start)] = medicine.initial;
    for (final r in data.refills.where(
      (r) => r.medicineId == medicineId && day(r.date).isAfter(day(asOf)),
    ))
      receipt.update(
        ymd(r.date),
        (n) => n + r.quantity,
        ifAbsent: () => r.quantity,
      );
    for (final r in data.losses.where(
      (r) => r.medicineId == medicineId && day(r.date).isAfter(day(asOf)),
    ))
      losses.update(
        ymd(r.date),
        (n) => n + r.quantity,
        ifAbsent: () => r.quantity,
      );
    final byDay = <String, List<Dose>>{};
    for (final d in doses) (byDay[ymd(d.scheduled)] ??= []).add(d);
    for (
      var date = day(asOf);
      !date.isAfter(horizon);
      date = plusDays(date, 1)
    ) {
      final incoming = receipt[ymd(date)] ?? 0;
      if (incoming > 0) {
        stock = precise(stock + incoming);
        zero = null;
      }
      for (final d in byDay[ymd(date)] ?? <Dose>[]) {
        if (stock + 0.0000001 < d.quantity) return StockForecast(zero, date);
        stock = precise(stock - d.quantity);
        if (stock == 0) zero = date;
      }
      final loss = losses[ymd(date)] ?? 0;
      if (loss > 0) {
        stock = precise((stock - loss).clamp(0, double.infinity));
        if (stock == 0) zero = date;
      }
    }
    return StockForecast(zero, null);
  }

  DateTime? stockout(String medicineId, DateTime now) {
    final f = forecast(medicineId, now);
    return f.zeroOn ?? f.insufficientOn;
  }

  Map<String, int> summary(
    String id,
    DateTime from,
    DateTime to,
    DateTime now,
  ) {
    final list = generate(from, to).where((d) => d.medicineId == id).toList();
    final stock = ledger(now);
    return {
      'scheduled': list.length,
      'confirmed': list
          .where((d) => stock.status(d) == DoseStatus.confirmed)
          .length,
      'assumed': list
          .where((d) => stock.status(d) == DoseStatus.assumed)
          .length,
      'missed': list.where((d) => stock.status(d) == DoseStatus.missed).length,
      'stockout': list
          .where((d) => stock.status(d) == DoseStatus.stockout)
          .length,
      'planned': list
          .where((d) => stock.status(d) == DoseStatus.planned)
          .length,
      'delayed': list
          .where((d) => d.delayed && stock.status(d) == DoseStatus.confirmed)
          .length,
    };
  }
}

AppData demoData() {
  final data = AppData.empty()..remindersEnabled = true;
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
      id: 'demo-daily',
      name: '予防薬A（デモ）',
      start: DateTime(2025, 4, 22),
      initial: 200,
      memo: '架空の薬・用法です。医療担当者の指示を優先してください。',
      versions: [
        ScheduleVersion(
          DateTime(2025, 4, 22),
          Rule(frequency: Frequency.daily, anchor: DateTime(2025, 4, 22)),
          1,
        ),
      ],
    ),
  ];
  data.refills = [
    Refill('demo-r1', 'demo-daily', DateTime(2025, 10, 1), 200, '追加入手（架空）'),
    Refill('demo-r2', 'demo-daily', DateTime(2026, 5, 1), 200, '追加入手（架空）'),
  ];
  data.losses = [
    Refill('demo-l1', 'demo-daily', DateTime(2026, 10, 1), 10, '破損（架空）'),
  ];
  final e = MedicationEngine(data), now = DateTime(2026, 11, 3, 9);
  e.materialize(now);
  for (final d in data.doses.where(
    (d) => d.scheduled.isBefore(plusDays(day(now), -3)),
  )) {
    d.explicit = DoseStatus.confirmed;
    d.actual = d.scheduled;
    d.confirmedAt = now;
  }
  e.record(
    data.doses.firstWhere((d) => d.id == 'demo-daily@2026-11-01'),
    DoseStatus.confirmed,
    now,
    actual: DateTime(2026, 11, 1, 20, 3),
  );
  e.record(
    data.doses.firstWhere((d) => d.id == 'demo-daily@2026-10-31'),
    DoseStatus.missed,
    now,
  );
  return data;
}
