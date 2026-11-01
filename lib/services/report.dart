import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../domain/model.dart';
import '../domain/engine.dart';
import '../domain/inventory.dart';

DateTime nextCalendarMonth(DateTime date) {
  final last = DateTime(date.year, date.month + 2, 0).day;
  return DateTime(date.year, date.month + 1, date.day > last ? last : date.day);
}

String qty(double n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

class ReportCell {
  final DateTime date;
  final String mark;
  final double? balance;
  final String category;
  final bool shortageDate;
  ReportCell(
    this.date,
    this.mark,
    this.balance,
    this.category,
    this.shortageDate,
  );
}

class ReportService {
  final AppData data;
  final DateTime now, reportDate;
  final DateTime? periodStart, periodEnd;
  final String? medicineId;
  ReportService(
    this.data,
    this.now,
    this.reportDate, {
    this.medicineId,
    this.periodStart,
    this.periodEnd,
  });
  DateTime get from =>
      day(periodStart ?? DateTime.parse(data.profile['start']!));
  DateTime get to => day(periodEnd ?? reportDate);
  bool get validPeriod =>
      !from.isAfter(to) &&
      !to.isAfter(day(reportDate)) &&
      !day(reportDate).isAfter(day(now)) &&
      !from.isBefore(day(DateTime.parse(data.profile['start']!)));
  DateTime get asOf => to == day(now)
      ? now
      : DateTime(to.year, to.month, to.day, 23, 59, 59, 999);
  DateTime get calendarEnd {
    final end = nextCalendarMonth(DateTime.parse(data.profile['end']!));
    return to.isAfter(end) ? to : end;
  }

  late final MedicationEngine engine = MedicationEngine(data);
  late final InventoryLedger ledger = engine.ledger(asOf);
  Medicine? get medicine {
    if (medicineId != null)
      return data.medicines.where((m) => m.id == medicineId).firstOrNull;
    final candidates =
        data.medicines.where((m) => !day(m.start).isAfter(to)).toList()
          ..sort((a, b) => b.start.compareTo(a.start));
    return data.medicineAt(to) ?? candidates.firstOrNull;
  }

  List<Medicine> get medicines => medicine == null ? [] : [medicine!];
  late final InventoryTotals totals = () {
    final cumulative = ledger.totals[medicine?.id] ?? InventoryTotals();
    if (periodStart == null) return cumulative;
    final result = InventoryTotals()..balance = cumulative.balance;
    for (var date = from; !date.isAfter(to); date = plusDays(date, 1)) {
      final entry = ledger.at(medicine?.id ?? '', date);
      result.acquired += entry.acquired;
      result.taken += entry.taken;
      result.missed += entry.missed;
      result.lost += entry.lost;
    }
    return result;
  }();
  double get openingBalance =>
      ledger.at(medicine?.id ?? '', plusDays(from, -1)).closing;
  late final StockForecast forecast = medicine == null
      ? StockForecast(null, null)
      : engine.forecast(medicine!.id, asOf, snapshot: ledger);
  List<InventoryIssue> get issues =>
      ledger.issues.where((i) => i.medicineId == medicine?.id).toList();
  List<DateTime> get months {
    final result = <DateTime>[];
    for (
      var m = DateTime(from.year, from.month);
      !m.isAfter(calendarEnd);
      m = DateTime(m.year, m.month + 1)
    ) {
      result.add(m);
    }
    return result;
  }

  String stockLabel([String? id]) {
    final d = forecast.insufficientOn;
    return d == null ? '今後10年／使用期間内に不足予定なし' : ymd(d);
  }

  String fill(String template) {
    final values = {
      '氏名': data.profile['name']!,
      '隊次': data.profile['cohort']!,
      '薬名': medicine?.name ?? '未登録',
      '期間': '${ymd(from)} ～ ${ymd(to)}',
      '残数': '現在残数：${qty(totals.balance)}錠\n在庫切れ予定日：${stockLabel()}',
    };
    var result = template;
    for (final e in values.entries)
      result = result.replaceAll('{${e.key}}', e.value);
    return result;
  }

  String get subject => fill(data.mail['subject']!);
  String get body => '${fill(data.mail['body']!)}\n\n${data.mail['signature']}';
  late final Map<String, List<Dose>> _plans = () {
    final map = <String, List<Dose>>{};
    for (final d
        in engine
            .generate(from, calendarEnd)
            .where((d) => d.medicineId == medicine?.id))
      (map[ymd(d.scheduled)] ??= []).add(d);
    return map;
  }();
  ReportCell cell(DateTime date) {
    if (date.isBefore(day(from)) || date.isAfter(calendarEnd))
      return ReportCell(date, '', null, 'outside', false);
    final plans = _plans[ymd(date)] ?? [];
    final short = forecast.insufficientOn == day(date);
    if (date.isAfter(to))
      return ReportCell(
        date,
        plans.isEmpty ? '・' : '予',
        null,
        plans.isEmpty ? 'futureEmpty' : 'future',
        short,
      );
    final d = ledger.at(medicine?.id ?? '', date);
    var mark = '・', category = 'none';
    if (d.delayedSources.isNotEmpty) {
      mark = '遅';
      category = 'delayed';
    }
    if (d.unavailable.isNotEmpty) {
      mark = '欠';
      category = 'stockout';
    }
    if (d.forgotten.isNotEmpty) {
      mark = '忘';
      category = 'missed';
    }
    if (d.consumed.isNotEmpty) {
      mark = '済';
      category = 'taken';
    }
    if (d.acquired > 0) mark += '+${qty(d.acquired)}';
    if (d.lost > 0) mark += '-${qty(d.lost)}';
    return ReportCell(date, mark, d.closing, category, short);
  }

  Future<Uint8List> pdf({
    required double verifiedBalance,
    ByteData? fontData,
  }) async {
    if (medicine == null || !validPeriod)
      throw ArgumentError('報告日・派遣開始日・登録薬を確認してください。');
    if (data.hasOverlappingMedicines)
      throw ArgumentError('使用期間が重なる薬があります。薬の使用期間を確認してください。');
    if (issues.isNotEmpty)
      throw ArgumentError('在庫と本人の記録に不整合があります。履歴を修正してから報告してください。');
    if (!verifiedBalance.isFinite ||
        (verifiedBalance - totals.balance).abs() > 0.000001)
      throw ArgumentError('実際の残数を確認し、入力履歴との違いを修正してください。');
    if (months.isEmpty || months.length > 40)
      throw ArgumentError('1ページで判読性を確保できるのは40か月までです。派遣期間を確認してください。');
    final font = pw.Font.ttf(
      fontData ?? await rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf'),
    );
    final doc = pw.Document(
      title: 'マラリア予防薬 服薬・在庫報告',
      author: data.profile['name'],
    );
    // A3 provides 32 readable columns and at least 26 month rows without pagination.
    final paper = PdfPageFormat.a3.landscape;
    const margin = 18.0;
    final rowHeight = ((paper.height - margin * 2 - 172) / months.length).clamp(
      12.0,
      22.0,
    );
    final small = rowHeight < 16 ? 6.0 : 7.1;
    pw.Widget text(String value, {double size = 9}) =>
        pw.Text(value, style: pw.TextStyle(fontSize: size), maxLines: 2);
    pw.Widget profile(String a, String b) => pw.Container(
      height: 17,
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey300, width: .4),
        ),
      ),
      child: pw.Row(
        children: [
          pw.Expanded(child: text(a)),
          pw.Expanded(child: text(b)),
        ],
      ),
    );
    final bg = {
      'taken': PdfColor.fromHex('#d8eddf'),
      'missed': PdfColor.fromHex('#ffedb2'),
      'stockout': PdfColor.fromHex('#f9d2ce'),
      'none': PdfColors.white,
      'delayed': PdfColor.fromHex('#e8dff3'),
      'future': PdfColor.fromHex('#dfeefa'),
      'futureEmpty': PdfColor.fromHex('#f4f7fa'),
      'outside': PdfColor.fromHex('#e2e5e7'),
    };
    final values = [
      '${qty(totals.acquired)} 錠',
      '${qty(totals.taken)} 錠',
      '${qty(totals.missed)} 錠',
      '${qty(totals.lost)} 錠',
      '${qty(totals.balance)} 錠',
      forecast.insufficientOn == null
          ? '不足予定なし'
          : ymd(forecast.insufficientOn!),
    ];
    final headers = ['総入手数', '服薬数', '飲み忘れ数', '消失数', '現在残数', '在庫切れ予定日'];
    doc.addPage(
      pw.Page(
        pageFormat: paper,
        margin: const pw.EdgeInsets.all(margin),
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                text('マラリア予防薬 服薬・在庫報告書', size: 15),
                text('服用・在庫報告  /  報告日 ${ymd(reportDate)}', size: 10),
              ],
            ),
            pw.SizedBox(height: 4),
            text(
              '薬名：${medicine!.name}     報告対象：${ymd(from)} ～ ${ymd(to)}     カレンダー：${ymd(from)} ～ ${ymd(calendarEnd)}',
              size: 9,
            ),
            pw.SizedBox(height: 5),
            profile(
              '氏名：${data.profile['name']}',
              '隊次：${data.profile['cohort']}',
            ),
            profile(
              '職種：${data.profile['job']}',
              '任地：${data.profile['location']}',
            ),
            profile(
              '派遣開始日：${data.profile['start']}',
              '派遣終了日：${data.profile['end']}',
            ),
            pw.SizedBox(height: 5),
            text('服薬・在庫サマリー', size: 10),
            pw.SizedBox(height: 3),
            pw.Row(
              children: List.generate(
                6,
                (i) => pw.Expanded(
                  child: pw.Container(
                    height: 43,
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.grey100,
                      border: pw.Border(
                        right: pw.BorderSide(
                          color: PdfColors.grey300,
                          width: .5,
                        ),
                      ),
                    ),
                    child: pw.Stack(
                      children: [
                        pw.Positioned(
                          left: 8,
                          right: 4,
                          top: 3,
                          child: text(headers[i], size: 8),
                        ),
                        pw.Positioned(
                          left: 8,
                          right: 4,
                          top: 20,
                          child: text(values[i], size: 11),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            pw.SizedBox(height: 4),
            text(
              '${periodStart == null ? '' : '期首残数：${qty(openingBalance)}錠  /  '}在庫0到達：${forecast.zeroOn == null ? '該当なし' : ymd(forecast.zeroOn!)}  /  在庫切れ予定日は次の服薬量を確保できない日。未来セルの残数は空欄。',
              size: 7.5,
            ),
            pw.SizedBox(height: 4),
            pw.Table(
              columnWidths: {0: const pw.FixedColumnWidth(52)},
              defaultColumnWidth: const pw.FlexColumnWidth(),
              border: pw.TableBorder.all(
                color: PdfColor.fromHex('#929b9d'),
                width: .35,
              ),
              children: [
                pw.TableRow(
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('#e6ece9'),
                  ),
                  children: [
                    pw.Container(
                      height: 16,
                      alignment: pw.Alignment.center,
                      child: text('年月', size: 8),
                    ),
                    ...List.generate(
                      31,
                      (i) => pw.Container(
                        height: 16,
                        alignment: pw.Alignment.center,
                        child: text('${i + 1}', size: 8),
                      ),
                    ),
                  ],
                ),
                ...months.map(
                  (month) => pw.TableRow(
                    children: [
                      pw.Container(
                        height: rowHeight,
                        alignment: pw.Alignment.center,
                        color: PdfColor.fromHex('#f1f4f2'),
                        child: text(
                          '${month.year}/${month.month.toString().padLeft(2, '0')}',
                          size: 8,
                        ),
                      ),
                      ...List.generate(31, (i) {
                        final date = DateTime(month.year, month.month, i + 1);
                        if (date.month != month.month)
                          return pw.Container(
                            height: rowHeight,
                            color: bg['outside'],
                          );
                        final c = cell(date);
                        return pw.Container(
                          height: rowHeight,
                          alignment: pw.Alignment.center,
                          decoration: pw.BoxDecoration(
                            color: bg[c.category],
                            border: c.shortageDate
                                ? pw.Border.all(
                                    color: PdfColors.red800,
                                    width: 2.6,
                                  )
                                : null,
                          ),
                          child: pw.Column(
                            mainAxisAlignment: pw.MainAxisAlignment.center,
                            children: [
                              if (c.mark.isNotEmpty)
                                pw.SizedBox(
                                  width: double.infinity,
                                  height: small * 1.4,
                                  child: pw.FittedBox(
                                    fit: pw.BoxFit.scaleDown,
                                    child: pw.Text(
                                      c.mark,
                                      style: pw.TextStyle(fontSize: small),
                                      maxLines: 1,
                                    ),
                                  ),
                                ),
                              if (c.balance != null)
                                text(qty(c.balance!), size: small),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 5),
            pw.Wrap(
              spacing: 12,
              runSpacing: 3,
              children: [
                ...[
                  ('taken', '済 服薬済み'),
                  ('missed', '忘 飲み忘れ'),
                  ('stockout', '欠 在庫切れ未服薬'),
                  ('none', '・ 予定なし'),
                  ('future', '予 未来の服薬予定'),
                  ('delayed', '遅 元の予定日'),
                ].map(
                  (v) => pw.Row(
                    mainAxisSize: pw.MainAxisSize.min,
                    children: [
                      pw.Container(
                        width: 9,
                        height: 9,
                        color: bg[v.$1],
                        margin: const pw.EdgeInsets.only(right: 3),
                      ),
                      text(v.$2, size: 7.5),
                    ],
                  ),
                ),
                text('赤枠：在庫切れ予定日  +数量：入手  -数量：消失', size: 7.5),
              ],
            ),
            pw.SizedBox(height: 3),
            text(
              '上段＝状態記号／下段＝その日の残数（報告日当日も含む・日付単位）。灰色セルは対象外・存在しない日付。残数は利用者確認済み：${qty(verifiedBalance)}錠。',
              size: 7.5,
            ),
            if (medicine!.start.isBefore(from))
              text('在庫サマリーは使用開始日 ${ymd(medicine!.start)} からの累計を含みます。', size: 7),
            if (data.medicines.length > 1)
              text('本書は上記1薬のみ。切替前の薬の記録は端末内に保持し、対象薬を切り替えて出力できます。', size: 7),
          ],
        ),
      ),
    );
    return doc.save();
  }
}
