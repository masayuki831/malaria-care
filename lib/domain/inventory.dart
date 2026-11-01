import 'model.dart';

double precise(double n) => double.parse(n.toStringAsFixed(6));

class InventoryIssue {
  final String medicineId, referenceId, message;
  final DateTime date;
  final double missing;
  InventoryIssue(
    this.medicineId,
    this.referenceId,
    this.date,
    this.missing,
    this.message,
  );
}

class InventoryDay {
  double acquired = 0, taken = 0, missed = 0, lost = 0, closing = 0;
  final List<Dose> consumed = [],
      unavailable = [],
      forgotten = [],
      delayedSources = [];
}

class InventoryTotals {
  double acquired = 0, taken = 0, missed = 0, lost = 0, balance = 0;
}

class StockForecast {
  final DateTime? zeroOn, insufficientOn;
  StockForecast(this.zeroOn, this.insufficientOn);
}

/// Replays source events; derived shortage states are never persisted onto doses.
class InventoryLedger {
  final AppData data;
  final DateTime asOf;
  final List<Dose> occurrences;
  final Map<String, InventoryDay> days = {};
  final Map<String, DoseStatus> statuses = {};
  final Map<String, InventoryTotals> totals = {};
  final List<InventoryIssue> issues = [];
  InventoryLedger(this.data, this.occurrences, this.asOf) {
    _replay();
  }
  String key(String id, DateTime date) => '$id@${ymd(date)}';
  InventoryDay at(String id, DateTime date) =>
      days[key(id, date)] ?? InventoryDay();
  void _replay() {
    final all = {
      for (final d in occurrences) d.id: d,
      ...{for (final d in data.doses) d.id: d},
    };
    for (final m in data.medicines) {
      final total = InventoryTotals();
      totals[m.id] = total;
      if (day(m.start).isAfter(day(asOf))) continue;
      final consumption = <String, List<Dose>>{},
          missed = <String, List<Dose>>{},
          delayed = <String, List<Dose>>{};
      for (final d in all.values.where((d) => d.medicineId == m.id)) {
        if (d.explicit == DoseStatus.confirmed &&
            d.actual != null &&
            !day(d.actual!).isAfter(day(asOf))) {
          (consumption[ymd(d.actual!)] ??= []).add(d);
          if (d.delayed && !day(d.scheduled).isAfter(day(asOf)))
            (delayed[ymd(d.scheduled)] ??= []).add(d);
        } else if (!day(d.scheduled).isAfter(day(asOf))) {
          if (d.explicit == DoseStatus.missed) {
            (missed[ymd(d.scheduled)] ??= []).add(d);
            statuses[d.id] = DoseStatus.missed;
          } else if (d.explicit == null)
            (consumption[ymd(d.scheduled)] ??= []).add(d);
        }
      }
      final receipts = <String, double>{}, losses = <String, List<Refill>>{};
      for (final r in data.refills.where(
        (r) => r.medicineId == m.id && !day(r.date).isAfter(day(asOf)),
      )) {
        receipts.update(
          ymd(r.date),
          (v) => v + r.quantity,
          ifAbsent: () => r.quantity,
        );
      }
      for (final r in data.losses.where(
        (r) => r.medicineId == m.id && !day(r.date).isAfter(day(asOf)),
      ))
        (losses[ymd(r.date)] ??= []).add(r);
      var stock = 0.0;
      for (
        var date = day(m.start);
        !date.isAfter(day(asOf));
        date = plusDays(date, 1)
      ) {
        final entry = InventoryDay();
        days[key(m.id, date)] = entry;
        entry.acquired =
            (date == day(m.start) ? m.initial : 0) + (receipts[ymd(date)] ?? 0);
        stock = precise(stock + entry.acquired);
        total.acquired += entry.acquired;
        final doses = consumption[ymd(date)] ?? [];
        doses.sort((a, b) {
          final c = (a.actual ?? a.scheduled).compareTo(
            b.actual ?? b.scheduled,
          );
          return c == 0 ? a.id.compareTo(b.id) : c;
        });
        for (final d in doses) {
          final confirmed = d.explicit == DoseStatus.confirmed;
          if (stock + 0.0000001 >= d.quantity) {
            stock = precise(stock - d.quantity);
            entry.taken += d.quantity;
            entry.consumed.add(d);
            statuses[d.id] = confirmed
                ? DoseStatus.confirmed
                : DoseStatus.assumed;
          } else if (confirmed) {
            issues.add(
              InventoryIssue(
                m.id,
                d.id,
                date,
                precise(d.quantity - stock),
                '本人確認済みの服薬に対して在庫が不足しています。入手日・数量・服薬記録を確認してください。',
              ),
            );
            entry.taken += d.quantity;
            entry.consumed.add(d);
            statuses[d.id] = DoseStatus.confirmed;
            stock = 0;
          } else {
            entry.unavailable.add(d);
            statuses[d.id] = DoseStatus.stockout;
          }
        }
        entry.forgotten.addAll(missed[ymd(date)] ?? []);
        entry.delayedSources.addAll(delayed[ymd(date)] ?? []);
        entry.missed = entry.forgotten.fold<double>(
          0,
          (n, d) => n + d.quantity,
        );
        for (final loss
            in (losses[ymd(date)] ?? [])
              ..sort((a, b) => a.id.compareTo(b.id))) {
          entry.lost += loss.quantity;
          if (stock + 0.0000001 < loss.quantity)
            issues.add(
              InventoryIssue(
                m.id,
                loss.id,
                date,
                precise(loss.quantity - stock),
                '消失数が当日の在庫を超えています。消失・入手・服薬履歴を確認してください。',
              ),
            );
          stock = precise((stock - loss.quantity).clamp(0, double.infinity));
        }
        entry.closing = stock;
        total.taken += entry.taken;
        total.missed += entry.missed;
        total.lost += entry.lost;
      }
      total.balance = stock;
      total.acquired = precise(total.acquired);
      total.taken = precise(total.taken);
      total.missed = precise(total.missed);
      total.lost = precise(total.lost);
    }
  }

  DoseStatus status(Dose d) => statuses[d.id] ?? d.status(asOf);
}
