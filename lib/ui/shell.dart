import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import 'report_preview.dart';

import 'package:share_plus/share_plus.dart';

import '../application/controller.dart';
import '../domain/model.dart';
import '../domain/inventory.dart';

import '../services/report.dart';
import '../services/notifications.dart' show notificationActionPort;

const green = Color(0xff186653);
const amber = Color(0xffa16b13);
const delayWarning = '遅延先の日付に服用予定又は記録がある場合には移動できません。';
Color statusColor(DoseStatus status) => [
  const Color(0xff7e8c98),
  green,
  green,
  const Color(0xffb54747),
  const Color(0xffb54747),
][status.index];
String number(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class AppShell extends StatefulWidget {
  final AppController controller;
  const AppShell({super.key, required this.controller});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  AppController get c => widget.controller;
  int tab = 0;
  late DateTime month, selected, reportTo;
  late InventoryLedger _stock;
  AppData? reportSource;
  final stockInput = TextEditingController();
  bool stockChecked = false;
  DateTimeRange? reportPeriod;
  DoseStatus effective(Dose d) => _stock.status(d);

  Timer? ticker;
  ReceivePort? backgroundResponses;
  late DateTime materializedDate;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    materializedDate = day(c.now);
    selected = day(c.now);
    month = DateTime(selected.year, selected.month);

    reportTo = selected;
    final dispatchStart = DateTime.parse(c.data.profile['start']!);
    if (!dispatchStart.isAfter(reportTo)) {
      reportPeriod = DateTimeRange(start: dispatchStart, end: reportTo);
    }
    reportSource = c.data;
    c.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    c.notifications.onResponse = notification;
    backgroundResponses = ReceivePort()
      ..listen((_) {
        unawaited(c.commit((_, __) {}).catchError((Object _) {}));
      });
    IsolateNameServer.removePortNameMapping(notificationActionPort);
    IsolateNameServer.registerPortWithName(
      backgroundResponses!.sendPort,
      notificationActionPort,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final payload = c.notifications.pendingPayload;
      if (payload != null) {
        notification(payload, c.notifications.pendingAction);
        c.notifications.pendingPayload = null;
      }
    });
    ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!c.demo && !busy && materializedDate != day(c.now)) {
        run(() => c.commit((_, __) {}), message: false);
      }
    });
  }

  void changed() {
    materializedDate = day(c.now);
    if (!identical(reportSource, c.data)) {
      stockChecked = false;
      stockInput.clear();
      reportSource = c.data;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ticker?.cancel();
    IsolateNameServer.removePortNameMapping(notificationActionPort);
    backgroundResponses?.close();
    stockInput.dispose();
    c.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    c.notifications.onResponse = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy)
      run(() => c.commit((_, __) {}), message: false);
  }

  Future<void> run(
    Future<void> Function() action, {
    bool message = true,
  }) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      if (message && mounted) toast('保存しました');
    } catch (error) {
      if (mounted)
        toast(
          error is ArgumentError
              ? error.message.toString()
              : error is FormatException
              ? error.message
              : '処理を完了できませんでした。入力内容・保存先・端末設定を確認してください。',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<DateTime?> datePicker(
    DateTime initial, {
    DateTime? first,
    DateTime? last,
  }) => showDatePicker(
    context: context,
    initialDate: initial,
    initialEntryMode: DatePickerEntryMode.calendarOnly,
    firstDate: first ?? DateTime(2000),
    lastDate: last ?? DateTime(2100),
  );
  Future<bool> confirm(String title, String content) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('実行する'),
            ),
          ],
        ),
      ) ??
      false;
  void notification(String? payload, String? action) {
    if (payload == 'preview:reminder') {
      if (action == 'reminder_confirm') {
        unawaited(acknowledgeReminder('preview:reminder'));
      } else {
        unawaited(showReminderConfirmation('preview:reminder'));
      }
      return;
    }
    if (payload == 'preview:check') {
      unawaited(showPreviousPreview(action));
      return;
    }
    if (payload != null && payload.startsWith('reminder:')) {
      if (action == 'reminder_confirm') {
        unawaited(acknowledgeReminder(payload));
      } else {
        unawaited(showReminderConfirmation(payload));
      }
      return;
    }
    if (payload == 'notification-test') {
      toast('テスト通知を開きました。');
      return;
    }
    if (payload != null && payload.startsWith('check:')) {
      if (!c.data.nextDay) return;
      final id = payload.substring('check:'.length);
      final dose = c.engine
          .generate(plusDays(c.now, -366), c.now)
          .where((d) => d.id == id)
          .firstOrNull;
      if (dose == null || !day(dose.scheduled).isBefore(day(c.now))) return;
      if (dose.explicit != null ||
          c.engine.effectiveStatus(dose, c.now) != DoseStatus.assumed) {
        toast('この日の服用記録は既に修正されています。');
        return;
      }
      if (action == 'previous_missed') {
        run(
          () => c.commit((d, e) => e.record(dose, DoseStatus.missed, c.now)),
          message: false,
        );
      } else if (action == 'previous_taken') {
        toast('${ymd(dose.scheduled)}は服用済みのままです。');
      } else {
        unawaited(confirmPreviousDose(dose));
      }
      return;
    }
    if (payload == 'check') {
      setState(() => tab = 0);
      return;
    }
    if (payload == null) return;
    final now = c.now;
    final list = c.engine.generate(plusDays(now, -100), plusDays(now, 1));
    final found = list.where((d) => d.id == payload);
    if (found.isEmpty) {
      toast('この通知の予定が見つかりません。カレンダーから確認してください。');
      return;
    }
    final dose = found.first;
    if ((action == 'taken' || action == 'later') &&
        dose.explicit == DoseStatus.confirmed) {
      toast('この予定は既に服用済みです。');
      return;
    }
    if (action == 'taken') {
      if (day(now) != day(dose.scheduled)) {
        editRecord(dose, initialActual: now);
        return;
      }
      run(() => c.commit((d, e) => e.record(dose, DoseStatus.confirmed, now)));
    } else if (action == 'later') {
      run(
        () => c.commit((d, e) {
          final record = e.record(dose, DoseStatus.assumed, now);
          record.later = true;
        }),
        message: false,
      );
      toast('服用記録は日付単位で管理します。変更がある日はカレンダーから修正してください。');
    } else {
      setState(() {
        tab = 0;
        selected = day(dose.scheduled);
        month = DateTime(selected.year, selected.month);
      });
    }
  }

  bool reminderDialogOpen = false;
  Future<void> acknowledgeReminder(String payload) async {
    try {
      if (!payload.startsWith('preview:')) {
        await c.commit((data, e) {
          if (!data.reminderAcknowledgements.contains(payload))
            data.reminderAcknowledgements.add(payload);
        });
      }
      await c.notifications.acknowledgeReminder(payload);
    } catch (_) {
      if (mounted) toast('確認を保存できませんでした。通知をもう一度開いて確認してください。');
    }
  }

  Future<void> showReminderConfirmation(String payload) async {
    if (reminderDialogOpen) return;
    reminderDialogOpen = true;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('服用リマインダー'),
          content: const Text('飲む時間です。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('確認'),
            ),
          ],
        ),
      ),
    );
    reminderDialogOpen = false;
    if (mounted && confirmed == true) await acknowledgeReminder(payload);
  }

  Future<bool?> askPreviousDose(String question, {bool preview = false}) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(preview ? '前日の服用確認（テスト）' : '前日の服用確認'),
          content: Text(question),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('飲み忘れた'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('飲んだ'),
            ),
          ],
        ),
      );

  Future<void> showPreviousPreview(String? action) async {
    if (action != 'previous_missed' && action != 'previous_taken') {
      await askPreviousDose('前日の薬を飲みましたか？\nテストのため服用記録は変更しません。', preview: true);
    }
    await acknowledgeReminder('preview:check');
    if (mounted) toast('テスト通知を確認しました。服用記録は変更していません。');
  }

  Future<void> confirmPreviousDose(Dose dose) async {
    final missed = await askPreviousDose(
      '${ymd(dose.scheduled)}に${dose.name}を飲みましたか？',
    );
    if (!mounted || missed != true) return;
    await run(
      () => c.commit((d, e) => e.record(dose, DoseStatus.missed, c.now)),
      message: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    _stock = c.engine.ledger(c.now);
    final wide = MediaQuery.sizeOf(context).width >= 850;
    final destinations = [
      ('カレンダー', Icons.calendar_month_outlined),
      ('薬の管理', Icons.medication_outlined),
      ('報告', Icons.description_outlined),
      ('設定', Icons.tune),
    ];
    final body = SafeArea(
      child: Column(
        children: [
          if (kIsWeb)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Webプレビュー：メモリ保存のみ。再読み込みで初期化されます。OS通知は実機で検証してください。',
                style: TextStyle(fontSize: 12, color: amber),
              ),
            ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (c.data.hasOverlappingMedicines || _stock.issues.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                c.data.hasOverlappingMedicines
                    ? '旧データに使用期間の重なる薬があります。薬の管理から確認してください。履歴は保持しています。'
                    : '本人の服薬・消失記録と在庫に不整合があります。薬の管理から入手・数量・履歴を確認してください。',
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
          if (c.warning != null)
            MaterialBanner(
              content: Text(c.warning!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => c.warning = null),
                  child: const Text('閉じる'),
                ),
              ],
            ),
          Expanded(
            child: IndexedStack(
              index: tab,
              children: [calendar(), medications(), reports(), settings()],
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.health_and_safety_outlined, color: green),
            SizedBox(width: 10),
            Expanded(
              child: FittedBox(
                alignment: Alignment.centerLeft,
                fit: BoxFit.scaleDown,
                child: Text(
                  'Malaria Care version 0.8',
                  style: TextStyle(fontSize: 16),
                ),
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: const Center(
              child: Text(
                'Nakata Design',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: tab,
                  onDestinationSelected: (v) => setState(() => tab = v),
                  labelType: NavigationRailLabelType.all,
                  destinations: destinations
                      .map(
                        (d) => NavigationRailDestination(
                          icon: Icon(d.$2),
                          label: Text(d.$1),
                        ),
                      )
                      .toList(),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (v) => setState(() => tab = v),
              destinations: destinations
                  .map(
                    (d) => NavigationDestination(icon: Icon(d.$2), label: d.$1),
                  )
                  .toList(),
            ),
    );
  }

  Widget page(List<Widget> children) => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1020),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ),
  );
  Widget title(
    String eyebrow,
    String title, {
    String? subtitle,
    Widget? action,
    double bottomPadding = 22,
  }) => Padding(
    padding: EdgeInsets.only(bottom: bottomPadding),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eyebrow,
                style: const TextStyle(
                  color: green,
                  fontSize: 11,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 7),
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xff63706a),
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (action != null) action,
      ],
    ),
  );
  Widget card(Widget child) => Card(
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
  Widget section(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 12),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
  Widget calendar() {
    final first = DateTime(month.year, month.month),
        last = DateTime(month.year, month.month + 1, 0);
    final start = plusDays(first, -(first.weekday - 1));
    final all = c.engine.generate(start, plusDays(start, 41));
    return page([
      title(
        'YOUR DAILY COMPANION',
        'いつもの毎日を、安心に。',
        subtitle: '飲み忘れ・服用日の変更がある日だけ修正してください。',
        bottomPadding: 12,
      ),
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text(
          '薬の残数',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      ...c.data.medicines.map(stockCard),
      const SizedBox(height: 8),
      card(
        Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '前の月',
                  onPressed: () => setState(
                    () => month = DateTime(month.year, month.month - 1),
                  ),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    '${month.year}年 ${month.month}月',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    selected = day(c.now);
                    month = DateTime(selected.year, selected.month);
                  }),
                  child: const Text('今日'),
                ),
                IconButton(
                  tooltip: '次の月',
                  onPressed: () => setState(
                    () => month = DateTime(month.year, month.month + 1),
                  ),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: ['月', '火', '水', '木', '金', '土', '日']
                  .map(
                    (s) => Expanded(
                      child: Text(
                        s,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff78847b),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 4),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: (first.weekday - 1 + last.day) > 35 ? 42 : 35,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisExtent: 48,
                crossAxisSpacing: 3,
                mainAxisSpacing: 2,
              ),
              itemBuilder: (ctx, i) {
                final date = plusDays(start, i),
                    doses = all.where((d) => day(d.scheduled) == date).toList();
                final active = date == selected;
                final entries = c.data.medicines.map(
                  (m) => _stock.at(m.id, date),
                );
                final states = doses.map(effective).toSet();
                final hasDelayed = entries.any(
                  (e) => e.delayedSources.isNotEmpty,
                );
                final (
                  label,
                  color,
                  background,
                ) = states.contains(DoseStatus.stockout)
                    ? ('不足', const Color(0xff9c2929), const Color(0xffffdede))
                    : states.contains(DoseStatus.missed)
                    ? ('忘', const Color(0xff805000), const Color(0xffffe9ae))
                    : hasDelayed
                    ? ('遅', const Color(0xff654399), const Color(0xffe9dff8))
                    : states.contains(DoseStatus.assumed) ||
                          states.contains(DoseStatus.confirmed) ||
                          entries.any((e) => e.consumed.isNotEmpty)
                    ? ('済', green, const Color(0xffcbe9d8))
                    : states.contains(DoseStatus.planned)
                    ? ('予定', const Color(0xff456477), const Color(0xffe4eef5))
                    : ('', const Color(0xff7e8c98), const Color(0xfff5f6f5));
                return Builder(
                  builder: (cellContext) => Semantics(
                    label: '${ymd(date)} $label',
                    button: true,
                    selected: active,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => calendarDayActions(date, cellContext),
                      child: Container(
                        key: ValueKey('calendar-day-${ymd(date)}'),
                        decoration: BoxDecoration(
                          color: background,
                          border: Border.all(
                            color: active ? green : Colors.transparent,
                            width: 2.5,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Opacity(
                          opacity: date.month == month.month ? 1 : .45,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '${date.day}',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                  color: color,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                ...[
                  ('済 服用済み', const Color(0xffcbe9d8)),
                  ('忘 飲み忘れ', const Color(0xffffe9ae)),
                  ('不足 在庫不足', const Color(0xffffdede)),
                  ('遅 元の予定日', const Color(0xffe9dff8)),
                  ('予定', const Color(0xffe4eef5)),
                ].map(
                  (item) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 16, height: 16, color: item.$2),
                      const SizedBox(width: 5),
                      Text(item.$1, style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ]);
  }

  Future<void> calendarDayActions(DateTime date, BuildContext anchor) async {
    if (busy) return;
    final box = anchor.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    setState(() => selected = day(date));
    final snapshot = c.engine.ledger(c.now);
    final doses = <String, Dose>{
      for (final dose in c.engine.generate(date, date)) dose.id: dose,
      for (final medicine in c.data.medicines)
        for (final dose
            in snapshot.at(medicine.id, date).consumed.where((d) => d.delayed))
          dose.id: dose,
    }.values.toList();
    final dose = doses.length == 1 ? doses.single : null;
    final future = day(date).isAfter(day(c.now));
    final editable = dose != null && !future;
    final explanation = doses.isEmpty
        ? 'この日は服用予定・記録がありません。'
        : doses.length > 1
        ? 'この日に複数の記録があります。薬の使用期間を確認してください。'
        : future
        ? '未来の予定は変更できません。'
        : null;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      constraints: const BoxConstraints(minWidth: 260, maxWidth: 320),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      semanticLabel: '${ymd(date)}の服用記録',
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 36,
          child: Text(
            ymd(date),
            key: const ValueKey('day-popup-date'),
            style: const TextStyle(color: green, fontWeight: FontWeight.w700),
          ),
        ),
        for (final item in [
          ('taken', '服用済み', Icons.check_circle_outline),
          ('missed', '飲み忘れ', Icons.cancel_outlined),
          ('delay', '遅延服用', Icons.event_repeat_outlined),
        ])
          PopupMenuItem<String>(
            key: ValueKey('day-action-${item.$1}'),
            value: item.$1,
            enabled: editable,
            child: Row(
              children: [
                Icon(item.$3, size: 20),
                const SizedBox(width: 12),
                Text(item.$2),
              ],
            ),
          ),
        if (explanation != null)
          PopupMenuItem<String>(
            enabled: false,
            child: Text(explanation, style: const TextStyle(fontSize: 12)),
          ),
        if (dose != null && dose.delayed && day(dose.scheduled) != day(date))
          PopupMenuItem<String>(
            enabled: false,
            height: 32,
            child: Text(
              '元の予定日 ${ymd(dose.scheduled)}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          enabled: false,
          child: Text(
            delayWarning,
            key: ValueKey('day-popup-warning'),
            style: TextStyle(fontSize: 12, color: amber, height: 1.5),
          ),
        ),
      ],
    );
    if (!mounted || choice == null || !editable) return;
    if (choice == 'delay') {
      await editRecord(dose, initialActual: dose.actual ?? date);
    } else {
      await run(
        () => c.commit(
          (data, engine) => engine.record(
            dose,
            choice == 'taken' ? DoseStatus.confirmed : DoseStatus.missed,
            c.now,
            actual: choice == 'taken' ? date : null,
          ),
        ),
      );
    }
  }

  Widget stockCard(Medicine m) {
    final balance = c.engine.balance(m.id, c.now, c.now),
        out = c.engine.stockout(m.id, c.now);
    return card(
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  '在庫切れ予測  ${out == null ? '終了日内／10年以内に該当なし' : ymd(out)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff63706a),
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${number(balance)} ',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(color: balance < 7 ? amber : green),
          ),
          const Text(
            '錠\n推定',
            style: TextStyle(fontSize: 11, color: Color(0xff63706a)),
          ),
        ],
      ),
    );
  }

  Future<void> editRecord(Dose dose, {DateTime? initialActual}) async {
    if (day(dose.scheduled).isAfter(day(c.now))) {
      toast('未来の予定は変更できません。');
      return;
    }
    var actual = day(initialActual ?? dose.actual ?? dose.scheduled),
        shift = false;
    final reason = TextEditingController(text: dose.note);
    String? validationError;
    Timer? errorTimer;
    final route = DialogRoute<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final m = c.data.medicines.firstWhere((m) => m.id == dose.medicineId);
          final rule = m.versionAt(dose.scheduled).rule;
          final originalNext = c.engine
              .generate(plusDays(c.now, 1), plusDays(c.now, 366))
              .where((d) => d.medicineId == m.id)
              .firstOrNull;
          final nextRule = rule.reanchor(actual);
          var next = plusDays(day(c.now), 1);
          while (!nextRule.matches(next)) {
            next = plusDays(next, 1);
          }
          void showError(String message) {
            errorTimer?.cancel();
            update(() => validationError = message);
            errorTimer = Timer(const Duration(seconds: 4), () {
              if (ctx.mounted) update(() => validationError = null);
            });
          }

          return Stack(
            children: [
              AlertDialog(
                key: const ValueKey('edit-dose-dialog'),
                alignment: Alignment.topCenter,
                insetPadding: const EdgeInsets.fromLTRB(20, 24, 20, 128),
                titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                title: const Text('遅延服用'),
                content: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('元の予定日：${ymd(dose.scheduled)}'),
                        const SizedBox(height: 8),
                        const Text(
                          delayWarning,
                          style: TextStyle(
                            fontSize: 12,
                            color: amber,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.event),
                          label: Text('服用日 ${ymd(actual)}'),
                          onPressed: () async {
                            final date = await datePicker(
                              day(actual),
                              first: m.start,
                              last: day(c.now),
                            );
                            if (date == null || !ctx.mounted) return;
                            update(() {
                              actual = day(date);
                              validationError = null;
                            });
                          },
                        ),
                        if (day(actual) != day(dose.scheduled)) ...[
                          const SizedBox(height: 12),
                          const Text(
                            '次回以降の予定（利用者が選択）',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          RadioGroup<bool>(
                            groupValue: shift,
                            onChanged: (v) => update(() => shift = v!),
                            child: Column(
                              children: [
                                RadioListTile<bool>(
                                  value: false,
                                  title: const Text('元のスケジュールを維持'),
                                  subtitle: Text(
                                    '次回 ${originalNext == null ? 'なし' : ymd(originalNext.scheduled)}',
                                  ),
                                ),
                                RadioListTile<bool>(
                                  value: true,
                                  title: const Text('実際の服薬日を基準に変更'),
                                  subtitle: Text('翌日以降に適用・次回 ${ymd(next)}'),
                                ),
                              ],
                            ),
                          ),
                          const Text(
                            '処方医などの医療担当者の指示を優先してください。アプリは服薬方法を判断しません。',
                            style: TextStyle(fontSize: 12, color: amber),
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: reason,
                          maxLength: 200,
                          decoration: const InputDecoration(
                            labelText: '備考・変更理由（任意）',
                          ),
                          maxLines: 2,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('キャンセル'),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (day(actual).isAfter(day(c.now))) {
                        showError('未来の服用日は指定できません。');
                        return;
                      }
                      try {
                        c.engine.validateActualDay(dose, actual, c.now);
                      } on ArgumentError catch (error) {
                        showError(error.message.toString());
                        return;
                      }
                      Navigator.pop(ctx);
                      run(
                        () => c.commit((data, e) {
                          if (day(actual) != day(dose.scheduled)) {
                            e.shift(
                              dose,
                              actual,
                              c.now,
                              reanchor: shift,
                              reason: reason.text,
                            );
                          } else {
                            e.record(
                              dose,
                              DoseStatus.confirmed,
                              c.now,
                              actual: actual,
                            );
                          }
                          data.doses.firstWhere((d) => d.id == dose.id).note =
                              reason.text;
                        }),
                      );
                    },
                    child: const Text('服用日を保存'),
                  ),
                ],
              ),
              if (validationError != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
                  child: SnackBar(
                    key: const ValueKey('edit-dose-error'),
                    content: Text(validationError!),
                    behavior: SnackBarBehavior.floating,
                    margin: EdgeInsets.zero,
                    showCloseIcon: false,
                    dismissDirection: DismissDirection.none,
                    animation: const AlwaysStoppedAnimation<double>(1),
                  ),
                ),
            ],
          );
        },
      ),
    );
    await Navigator.of(context).push(route);
    await route.completed;
    errorTimer?.cancel();
    reason.dispose();
  }

  Widget medications() => page([
    title('MEDICINES', '薬の管理'),
    if (c.data.medicines.isEmpty)
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('使用する薬を登録してください。'),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('register-medicine'),
              onPressed: () => medicineForm(),
              icon: const Icon(Icons.medication_outlined),
              label: const Text('薬を登録'),
            ),
          ],
        ),
      ),
    ...c.data.medicines.map(
      (m) => Column(
        children: [
          card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(m.name),
                  trailing: IconButton(
                    tooltip: '登録薬を編集',
                    onPressed: () => medicineForm(m),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => refillForm(m),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('薬を入手'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => inventoryForm(m, loss: true),
                      icon: const Icon(Icons.remove_circle_outline, size: 16),
                      label: const Text('消失を登録'),
                    ),
                  ],
                ),
                inventoryHistory(m),
              ],
            ),
          ),
        ],
      ),
    ),
  ]);
  Future<void> medicineForm([Medicine? medicine]) async {
    final current = medicine?.versions.last;
    final form = GlobalKey<FormState>();
    final name = TextEditingController(text: medicine?.name),
        amount = TextEditingController(text: number(current?.dose ?? 1)),
        initial = TextEditingController(text: number(medicine?.initial ?? 30)),
        interval = TextEditingController(
          text: '${current?.rule.interval ?? 1}',
        ),
        memo = TextEditingController(text: medicine?.memo);
    var start = medicine?.start ?? day(c.now),
        end = medicine?.end,
        frequency = current?.rule.frequency ?? Frequency.daily;
    int? weekDay = current?.rule.frequency == Frequency.weeks
        ? (current!.rule.usesWeekday
              ? current.rule.weekdays.first
              : current.rule.anchor.weekday)
        : null;
    final weekdays = (current?.rule.weekdays ?? [1]).toSet();
    String? positive(String? v) {
      final n = double.tryParse(v ?? '');
      return n != null && n.isFinite && n > 0 ? null : '0より大きい数値を入力';
    }

    final route = DialogRoute<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(medicine == null ? '薬を登録' : '薬を編集'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      controller: name,
                      maxLength: 100,
                      decoration: const InputDecoration(labelText: '薬名'),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '薬名を入力' : null,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          key: const ValueKey('medicine-start'),
                          onPressed: () async {
                            final d = await datePicker(start);
                            if (d != null) update(() => start = d);
                          },
                          child: Text('開始 ${ymd(start)}'),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            final d = await datePicker(
                              end ??
                                  (start.isAfter(c.now) ? start : day(c.now)),
                              first: start,
                            );
                            if (d != null) update(() => end = d);
                          },
                          child: Text('終了 ${end == null ? '任意' : ymd(end!)}'),
                        ),
                        if (end != null)
                          TextButton(
                            onPressed: () => update(() => end = null),
                            child: const Text('終了日を解除'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: amount,
                      keyboardType: TextInputType.number,
                      validator: positive,
                      decoration: const InputDecoration(labelText: '1回の服薬量（錠）'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<Frequency>(
                      initialValue: frequency,
                      decoration: const InputDecoration(labelText: '服薬頻度'),
                      items: const [
                        DropdownMenuItem(
                          value: Frequency.daily,
                          child: Text('毎日'),
                        ),
                        DropdownMenuItem(
                          value: Frequency.days,
                          child: Text('N日ごと'),
                        ),
                        DropdownMenuItem(
                          value: Frequency.weekdays,
                          child: Text('毎週指定曜日'),
                        ),
                        DropdownMenuItem(
                          value: Frequency.weeks,
                          child: Text('N週間ごと'),
                        ),
                      ],
                      onChanged: (v) => update(() {
                        frequency = v!;
                      }),
                    ),
                    if (frequency == Frequency.days ||
                        frequency == Frequency.weeks)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: TextFormField(
                          controller: interval,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: frequency == Frequency.days
                                ? '間隔（日）'
                                : '間隔（週）',
                          ),
                          validator: (v) {
                            final n = int.tryParse(v ?? '');
                            return n != null && n > 0 && n <= 3650
                                ? null
                                : '1～3650の整数を入力';
                          },
                        ),
                      ),
                    if (frequency == Frequency.weekdays)
                      Wrap(
                        spacing: 5,
                        children: List.generate(
                          7,
                          (i) => FilterChip(
                            label: Text('月火水木金土日'[i]),
                            selected: weekdays.contains(i + 1),
                            onSelected: (v) => update(() {
                              if (v) {
                                weekdays.add(i + 1);
                              } else {
                                weekdays.remove(i + 1);
                              }
                            }),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (frequency == Frequency.weeks) ...[
                      const Text('服用する曜日（必須・1つ選択）'),
                      Wrap(
                        spacing: 5,
                        children: List.generate(
                          7,
                          (i) => ChoiceChip(
                            label: Text('月火水木金土日'[i]),
                            selected: weekDay == i + 1,
                            onSelected: (_) => update(() => weekDay = i + 1),
                          ),
                        ),
                      ),
                      const Text(
                        '開始日以降の指定曜日から、N週間ごとに予定を作成します。',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: initial,
                      enabled: true,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '初期残数（錠）'),
                      validator: (v) {
                        final n = double.tryParse(v ?? '');
                        return n != null && n.isFinite && n >= 0
                            ? null
                            : '0以上の数値を入力';
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: memo,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'メモ'),
                    ),
                    if (medicine != null)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          '開始日を直すと自動の予定と残数を再計算します。修正済みの服用・入手・消失と矛盾する変更は保存しません。用量・頻度・曜日の変更は翌日から適用します。',
                          style: TextStyle(fontSize: 12, color: amber),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                if (!form.currentState!.validate()) return;
                if (frequency == Frequency.weekdays && weekdays.isEmpty) {
                  toast('曜日を1つ以上選んでください');
                  return;
                }
                if (frequency == Frequency.weeks && weekDay == null) {
                  toast('服用する曜日を選んでください');
                  return;
                }
                final effective = medicine == null
                    ? start
                    : plusDays(day(c.now), 1);
                final rule = Rule(
                  frequency: frequency,
                  anchor: effective,
                  interval: int.tryParse(interval.text) ?? 1,
                  hour: current?.rule.hour ?? 0,
                  minute: current?.rule.minute ?? 0,
                  weekdays: frequency == Frequency.weeks
                      ? [weekDay!]
                      : (weekdays.isEmpty ? [1] : (weekdays.toList()..sort())),
                  usesWeekday: frequency == Frequency.weeks,
                );
                final newName = name.text.trim(),
                    newMemo = memo.text,
                    newAmount = double.parse(amount.text),
                    newInitial = double.parse(initial.text);
                Navigator.pop(ctx);
                run(
                  () => c.commit((data, e) {
                    if (medicine == null) {
                      data.medicines.add(
                        Medicine(
                          id: newId(),
                          name: newName,
                          start: start,
                          end: end,
                          initial: newInitial,
                          memo: newMemo,
                          versions: [
                            ScheduleVersion(effective, rule, newAmount),
                          ],
                        ),
                      );
                    } else {
                      final m = data.medicines.firstWhere(
                        (x) => x.id == medicine.id,
                      );

                      m.end = end;
                      e.changeMedicineStart(m.id, start, c.now);
                      m.name = newName;
                      m.memo = newMemo;
                      m.end = end;
                      m.initial = newInitial;
                      Map<String, dynamic> scheduleKey(Rule value) {
                        final result = value.toJson()
                          ..remove('anchor')
                          ..remove('hour')
                          ..remove('minute')
                          ..remove('usesWeekday');
                        if (value.frequency == Frequency.weeks) {
                          result['weekdays'] = [
                            value.usesWeekday
                                ? value.weekdays.first
                                : value.anchor.weekday,
                          ];
                        }
                        return result;
                      }

                      final previousRule = scheduleKey(m.versions.last.rule);
                      final updatedRule = scheduleKey(rule);
                      if (jsonEncode(previousRule) != jsonEncode(updatedRule) ||
                          m.versions.last.dose != newAmount) {
                        if (m.versions.last.effective == effective)
                          throw ArgumentError(
                            '翌日の変更が既に登録されています。適用後に再編集してください。',
                          );
                        m.versions.add(
                          ScheduleVersion(
                            effective,
                            rule,
                            newAmount,
                            '薬の設定画面で利用者が変更',
                          ),
                        );
                      }
                    }
                    final updated = data.medicines.firstWhere(
                      (m) => m.id == (medicine?.id ?? data.medicines.last.id),
                    );
                    if (data.overlaps(updated))
                      throw ArgumentError('使用期間が他の薬と重なります。先に旧薬の終了日を設定してください。');
                    e.materialize(c.now);
                  }),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    await Navigator.of(context).push(route);
    await route.completed;
    for (final controller in [name, amount, initial, interval, memo]) {
      controller.dispose();
    }
  }

  Widget inventoryHistory(Medicine m) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('入手・消失履歴（編集・削除）', style: TextStyle(fontSize: 13)),
    children: [
      ...[false, true].expand((loss) {
        final records =
            (loss ? c.data.losses : c.data.refills)
                .where((r) => r.medicineId == m.id)
                .toList()
              ..sort((a, b) => b.date.compareTo(a.date));
        return records.map(
          (r) => ListTile(
            dense: true,
            title: Text(
              '${ymd(r.date)} ${loss ? '消失 −' : '入手 ＋'}${number(r.quantity)}錠',
            ),
            subtitle: Text(r.note),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '${loss ? '消失' : '入手'}履歴を編集',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => inventoryForm(m, loss: loss, existing: r),
                ),
                IconButton(
                  tooltip: '${loss ? '消失' : '入手'}履歴を削除',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () async {
                    if (await confirm(
                      '履歴を削除しますか？',
                      '${ymd(r.date)}の${loss ? '消失' : '入手'} ${number(r.quantity)}錠を削除し、以後の残数を再計算します。',
                    )) {
                      run(
                        () => c.commit(
                          (data, e) => (loss ? data.losses : data.refills)
                              .removeWhere((x) => x.id == r.id),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        );
      }),
    ],
  );

  Future<void> refillForm(Medicine m) => inventoryForm(m);
  Future<void> inventoryForm(
    Medicine m, {
    bool loss = false,
    Refill? existing,
  }) async {
    final quantity = TextEditingController(
          text: number(existing?.quantity ?? (loss ? 1 : 30)),
        ),
        note = TextEditingController(text: existing?.note ?? '');
    var date =
        existing?.date ?? (m.start.isAfter(c.now) ? m.start : day(c.now));
    final label = loss ? '消失' : '入手';
    final route = DialogRoute<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text('${existing == null ? label : '$label履歴の編集'}：${m.name}'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton(
                    onPressed: () async {
                      final d = await datePicker(
                        date,
                        first: m.start,
                        last: day(c.now).isBefore(m.start)
                            ? m.start
                            : day(c.now),
                      );
                      if (d != null) update(() => date = d);
                    },
                    child: Text('$label日 ${ymd(date)}'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: quantity,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: '$label数（錠）'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: note,
                    maxLength: 200,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: loss ? '理由・メモ' : 'メモ',
                    ),
                  ),
                  const Text(
                    '過去の日付も指定できます。同日は入手→服薬→消失の順に再計算します。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final n = double.tryParse(quantity.text);
                if (n == null || !n.isFinite || n <= 0) {
                  toast('0より大きい数量を入力してください');
                  return;
                }
                if (date.isAfter(day(c.now))) {
                  toast('未来の入手・消失は登録できません');
                  return;
                }
                final record = Refill(
                  existing?.id ?? newId(),
                  m.id,
                  date,
                  n,
                  note.text,
                );
                Navigator.pop(ctx);
                run(
                  () => c.commit((data, e) {
                    final records = loss ? data.losses : data.refills;
                    records.removeWhere((r) => r.id == record.id);
                    records.add(record);
                  }),
                );
              },
              child: const Text('履歴を保存'),
            ),
          ],
        ),
      ),
    );
    await Navigator.of(context).push(route);
    await route.completed;
    quantity.dispose();
    note.dispose();
  }

  Widget reports() {
    final report = ReportService(
      c.data,
      c.now,
      reportTo,
      periodStart: reportPeriod?.start,
      periodEnd: reportPeriod?.end,
    );
    final totals = report.totals;
    final actual = double.tryParse(stockInput.text);
    final matched =
        actual != null &&
        actual.isFinite &&
        (actual - totals.balance).abs() < 0.000001;
    final canGenerate =
        stockChecked &&
        matched &&
        report.medicine != null &&
        report.issues.isEmpty &&
        !c.data.hasOverlappingMedicines &&
        report.validPeriod;
    return page([
      title(
        'MEDICATION REPORT',
        '記録を、報告につなげる。',
        subtitle: '対象期間と報告日を選択し、実際の残数を確認してください。',
      ),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('report-period'),
              icon: const Icon(Icons.date_range, size: 18),
              label: Text('報告対象期間 ${ymd(report.from)} ～ ${ymd(report.to)}'),
              onPressed:
                  busy ||
                      DateTime.parse(c.data.profile['start']!)
                          .isAfter(day(c.now))
                  ? null
                  : () async {
                      final range = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime.parse(c.data.profile['start']!),
                        lastDate: day(c.now),
                        initialDateRange: report.validPeriod
                            ? DateTimeRange(start: report.from, end: report.to)
                            : null,
                        helpText: '報告対象期間を選択',
                        saveText: '選択',
                      );
                      if (range != null && mounted) {
                        setState(() {
                          reportPeriod = range;
                          if (reportTo.isBefore(range.end))
                            reportTo = range.end;
                          stockChecked = false;
                          stockInput.clear();
                        });
                      }
                    },
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('report-date'),
              icon: const Icon(Icons.event_outlined, size: 18),
              label: Text('報告日 ${ymd(reportTo)}'),
              onPressed: busy || report.to.isAfter(day(c.now))
                  ? null
                  : () async {
                      final date = await datePicker(
                        reportTo,
                        first: report.to,
                        last: day(c.now),
                      );
                      if (date != null && mounted) {
                        setState(() {
                          reportTo = date;
                          stockChecked = false;
                          stockInput.clear();
                        });
                      }
                    },
            ),
          ],
        ),
      ),
      section('服薬・在庫サマリー'),
      card(
        Wrap(
          spacing: 24,
          runSpacing: 16,
          children: [
            if (report.openingBalance > 0)
              stat('期首残数（錠）', number(report.openingBalance)),
            stat('総入手数（錠）', number(totals.acquired)),
            stat('服薬数（錠）', number(totals.taken)),
            stat('飲み忘れ数（錠）', number(totals.missed)),
            stat('消失数（錠）', number(totals.lost)),
            stat('現在残数（錠）', number(totals.balance)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '在庫切れ予定日',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(report.stockLabel()),
                Text(
                  '在庫0到達：${report.forecast.zeroOn == null ? '該当なし' : ymd(report.forecast.zeroOn!)}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
      if (report.issues.isNotEmpty)
        card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '在庫履歴との不整合があります',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.w700,
                ),
              ),
              ...report.issues
                  .take(4)
                  .map(
                    (i) => Text(
                      '${ymd(i.date)}：${i.message}（不足 ${number(i.missing)}錠）',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              TextButton(
                onPressed: () => setState(() => tab = 1),
                child: const Text('入手・消失・初期数を確認する'),
              ),
              TextButton(
                onPressed: () => setState(() => tab = 0),
                child: const Text('服薬履歴を確認する'),
              ),
            ],
          ),
        ),
      if (c.data.hasOverlappingMedicines)
        card(
          const Text(
            '旧データに使用期間の重なる薬があります。履歴は保持しています。薬の管理で使用期間を確認してください。',
            style: TextStyle(color: Colors.red),
          ),
        ),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PDF作成前の残数確認',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('actual-stock'),
              controller: stockInput,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '手元で確認した残数（錠）'),
              onChanged: (_) => setState(() => stockChecked = false),
            ),
            if (actual != null && !matched)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '計算結果と異なります。入手・消失・初期数・服薬履歴を修正してください。差分を自動で消失にはしません。',
                  style: TextStyle(color: amber, fontSize: 12),
                ),
              ),
            CheckboxListTile(
              key: const ValueKey('stock-confirmation'),
              contentPadding: EdgeInsets.zero,
              value: stockChecked,
              onChanged: matched
                  ? (v) => setState(() => stockChecked = v!)
                  : null,
              title: const Text(
                '実際の残数と計算結果が一致することを確認しました',
                style: TextStyle(fontSize: 13),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => setState(() => tab = 1),
                  child: const Text('入手・消失・数量を修正'),
                ),
                TextButton(
                  onPressed: () => setState(() => tab = 0),
                  child: const Text('服薬履歴を修正'),
                ),
              ],
            ),
          ],
        ),
      ),
      FilledButton.icon(
        key: const ValueKey('generate-report'),
        onPressed: busy || !canGenerate
            ? null
            : () => run(() async {
                final bytes = await report.pdf(verifiedBalance: actual);
                if (!mounted) return;
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (ctx) => ReportPreview(
                      bytes: bytes,
                      onSave: () => saveBytes(bytes, 'medication-report.pdf'),
                      onShare: () => shareReport(report, bytes),
                      onEmail: () => emailReport(report, bytes),
                    ),
                  ),
                );
              }, message: false),
        icon: const Icon(Icons.picture_as_pdf_outlined),
        label: const Text('PDFを作成'),
      ),
      section('メールのプレビュー'),
      card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              '宛先：${c.data.mail['to']!.isEmpty ? '未設定（設定画面で登録）' : c.data.mail['to']}',
            ),
            const SizedBox(height: 10),
            Text(
              report.subject,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const Divider(height: 24),
            SelectableText(
              report.body,
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => run(() async {
                    await Clipboard.setData(ClipboardData(text: report.body));
                    toast('本文をコピーしました');
                  }, message: false),
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('本文をコピー'),
                ),
                FilledButton.icon(
                  key: const ValueKey('compose-report-mail'),
                  onPressed: busy || !canGenerate
                      ? null
                      : () => run(() async {
                          final bytes = await report.pdf(
                            verifiedBalance: actual,
                          );
                          if (!mounted) return;
                          await emailReport(report, bytes);
                        }, message: false),
                  icon: const Icon(Icons.attach_email_outlined, size: 18),
                  label: const Text('PDFを添付してメールを作成'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'PDFを自動添付し、設定した宛先・件名・本文を入れたメールを開きます。内容と添付を確認してから送信してください。添付付きメールを直接開けない端末ではPDFの共有画面へ進みます。',
              style: TextStyle(fontSize: 12, color: amber),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: green,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        label,
        style: const TextStyle(fontSize: 11, color: Color(0xff63706a)),
      ),
    ],
  );
  Future<void> saveBytes(Uint8List bytes, String filename) async {
    final path = await FilePicker.saveFile(
      dialogTitle: '端末に保存',
      fileName: filename,
      bytes: bytes,
    );
    if (path != null && mounted) toast('ファイルを保存しました');
  }

  Future<void> shareReport(ReportService report, Uint8List bytes) async {
    await SharePlus.instance.share(
      ShareParams(
        subject: report.subject,
        text: report.body,
        files: [XFile.fromData(bytes, mimeType: 'application/pdf')],
        fileNameOverrides: ['medication-report.pdf'],
        sharePositionOrigin: Rect.fromLTWH(
          0,
          0,
          MediaQuery.sizeOf(context).width,
          100,
        ),
      ),
    );
  }

  Future<void> emailReport(ReportService report, Uint8List bytes) async {
    await c.reportMail.compose(
      pdf: bytes,
      recipient: report.data.mail['to'] ?? '',
      subject: report.subject,
      body: report.body,
      fileName: 'medication-report-${ymd(report.reportDate)}.pdf',
      shareFallback: () async {
        if (!mounted) return;
        toast('添付付きメールを直接開けないためPDFの共有画面を開きます。メールアプリを選び、宛先と添付を確認してください。');
        await shareReport(report, bytes);
      },
    );
  }

  Widget notificationSettings({required bool previous}) {
    final label = previous ? '服用確認' : '服用リマインダー';
    final prefix = previous ? 'check' : 'reminder';
    final enabled = previous ? c.data.nextDay : c.data.remindersEnabled;
    final hour = previous ? c.data.checkHour : c.data.reminderHour;
    final minute = previous ? c.data.checkMinute : c.data.reminderMinute;
    final sound = previous ? c.data.checkSound : c.data.reminderSound;
    final vibration = previous
        ? c.data.checkVibration
        : c.data.reminderVibration;
    final editable = enabled && !busy;
    Future<void> saveFlag(String field, bool value) => run(
      () => c.commit((d, e) {
        switch ((previous, field)) {
          case (true, 'enabled'):
            d.nextDay = value;
          case (false, 'enabled'):
            d.remindersEnabled = value;
          case (true, 'sound'):
            d.checkSound = value;
          case (false, 'sound'):
            d.reminderSound = value;
          case (true, 'vibration'):
            d.checkVibration = value;
          case (false, 'vibration'):
            d.reminderVibration = value;
        }
      }),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: ValueKey(
            previous ? 'previous-dose-enabled' : 'reminder-enabled',
          ),
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: previous
              ? const Text('翌日に飲んだかを確認します。OFFでは服用済みとして扱います。')
              : null,
          value: enabled,
          onChanged: busy
              ? null
              : (value) => run(
                  () => c.setNotificationEnabled(
                    previous: previous,
                    enabled: value,
                  ),
                ),
        ),
        OutlinedButton(
          key: ValueKey(previous ? 'previous-dose-time' : 'reminder-time'),
          onPressed: !editable
              ? null
              : () async {
                  final time = await showTimePicker(
                    context: context,
                    initialEntryMode: TimePickerEntryMode.dial,
                    initialTime: TimeOfDay(hour: hour, minute: minute),
                  );
                  if (time != null) {
                    await run(
                      () => c.commit((d, e) {
                        if (previous) {
                          d.checkHour = time.hour;
                          d.checkMinute = time.minute;
                        } else {
                          d.reminderHour = time.hour;
                          d.reminderMinute = time.minute;
                        }
                      }),
                    );
                  }
                },
          child: Text(
            '通知時刻 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}',
          ),
        ),
        SwitchListTile(
          key: ValueKey('$prefix-sound'),
          contentPadding: EdgeInsets.zero,
          title: Text('$labelの通知音'),
          value: sound,
          onChanged: !editable ? null : (value) => saveFlag('sound', value),
        ),
        SwitchListTile(
          key: ValueKey('$prefix-vibration'),
          contentPadding: EdgeInsets.zero,
          title: Text('$labelのバイブ'),
          value: vibration,
          subtitle: defaultTargetPlatform == TargetPlatform.iOS
              ? const Text('iPhoneでは端末本体のバイブ設定に従います。')
              : null,
          onChanged: !editable || defaultTargetPlatform == TargetPlatform.iOS
              ? null
              : (value) => saveFlag('vibration', value),
        ),
      ],
    );
  }

  Widget settings() => page([
    title('PREFERENCES', 'あなたの設定', subtitle: 'プロフィール・通知・報告設定を、この端末で管理します。'),
    card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('プロフィール', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text(
            '${c.data.profile['name']!.isEmpty ? '未登録' : c.data.profile['name']}\n${c.data.profile['cohort']}  ／  ${c.data.profile['job']}\n${c.data.profile['location']}\n派遣期間 ${c.data.profile['start']} ～ ${c.data.profile['end']}',
            style: const TextStyle(height: 1.8),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => editSettings(false),
            child: const Text('プロフィールを編集'),
          ),
        ],
      ),
    ),
    card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              const Text('通知', style: TextStyle(fontWeight: FontWeight.w700)),
              TextButton(
                key: const ValueKey('notification-permission'),
                onPressed: busy
                    ? null
                    : () => run(() async {
                        await c.retryNotifications(requestPermission: true);
                      }, message: false),
                child: const Text('OSの通知権限を許可'),
              ),
            ],
          ),
          Text(c.notifications.status, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          const Text(
            'OSの省電力等により遅延する場合があります。長期間起動しない場合は通知が途切れる場合があります。タイムゾーン変更後はアプリを起動しなおしてください。',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xff63706a),
              height: 1.6,
            ),
          ),
          const Divider(height: 24),
          notificationSettings(previous: false),
          const Divider(height: 24),
          notificationSettings(previous: true),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '「飲んだ」なら記録はそのまま。「飲み忘れた」なら前日を飲み忘れに変更し、残数を戻します。通知音やバイブは端末の消音・通知設定にも従います。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
    card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('報告メール', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(c.data.mail['to']!.isEmpty ? '宛先は未設定です' : c.data.mail['to']!),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => editSettings(true),
            child: const Text('宛先・テンプレート・署名を編集'),
          ),
        ],
      ),
    ),
    card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('バックアップ', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text(
            'バックアップには個人情報・健康情報が含まれます。暗号化されません。共有先と保管場所を確認してください。',
            style: TextStyle(fontSize: 12, color: amber, height: 1.6),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('保存'),
                onPressed: () => run(
                  () => saveBytes(
                    Uint8List.fromList(utf8.encode(c.data.export())),
                    'malaria-care-backup.json',
                  ),
                  message: false,
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.file_upload_outlined, size: 18),
                label: const Text('復元'),
                onPressed: () => run(() async {
                  final file = await FilePicker.pickFile(
                    type: FileType.custom,
                    allowedExtensions: ['json'],
                  );
                  if (file == null) return;
                  final bytes = await file.readAsBytes();
                  if (bytes.length > 20 * 1024 * 1024)
                    throw const FormatException('ファイルが大きすぎます。');
                  final incoming = AppData.parse(utf8.decode(bytes));
                  if (!await confirm(
                    '現在のデータを置き換えますか？',
                    '保存済みのデータを置き換えます。薬${incoming.medicines.length}件、服薬記録${incoming.doses.length}件を復元します。先にバックアップを保存してください。',
                  ))
                    return;
                  await c.replace(incoming);
                }),
              ),
            ],
          ),
        ],
      ),
    ),
    const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Text(
        '本アプリは服用の記録と報告を支援します。服薬量・頻度・遅延時の対応は、処方医などの医療担当者の指示に基づいて設定してください。',
        style: TextStyle(fontSize: 12, color: Color(0xff63706a), height: 1.7),
      ),
    ),
  ]);
  Future<void> editSettings(bool mail) async {
    final labels = mail
        ? {
            'to': '宛先メールアドレス',
            'subject': '件名テンプレート',
            'body': '本文テンプレート',
            'signature': '署名',
          }
        : {
            'name': '氏名',
            'cohort': '隊次',
            'job': '職種',
            'location': '任地',
            'start': '派遣開始日',
            'end': '派遣終了日',
          };
    final values = mail ? c.data.mail : c.data.profile;
    final fields = {
      for (final key in labels.keys)
        key: TextEditingController(text: values[key]),
    };
    final route = DialogRoute<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(mail ? 'メール設定' : 'プロフィール設定'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...labels.entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child:
                          !mail && (entry.key == 'start' || entry.key == 'end')
                          ? OutlinedButton.icon(
                              key: ValueKey('deployment-${entry.key}'),
                              icon: const Icon(Icons.calendar_month_outlined),
                              label: Text(
                                '${entry.value}  ${fields[entry.key]!.text}',
                              ),
                              onPressed: () async {
                                final first = entry.key == 'end'
                                    ? DateTime.parse(fields['start']!.text)
                                    : DateTime(2000);
                                var initial = DateTime.parse(
                                  fields[entry.key]!.text,
                                );
                                if (initial.isBefore(first)) initial = first;
                                final picked = await datePicker(
                                  initial,
                                  first: first,
                                );
                                if (picked != null && ctx.mounted)
                                  update(
                                    () => fields[entry.key]!.text = ymd(picked),
                                  );
                              },
                            )
                          : TextField(
                              controller: fields[entry.key],
                              maxLines: entry.key == 'body'
                                  ? 7
                                  : entry.key == 'signature'
                                  ? 2
                                  : 1,
                              decoration: InputDecoration(
                                labelText: entry.value,
                              ),
                            ),
                    ),
                  ),
                  if (mail)
                    const Text(
                      '置換項目：{氏名} {隊次} {薬名} {期間} {残数}',
                      style: TextStyle(fontSize: 12),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final updated = {
                  for (final entry in fields.entries)
                    entry.key: entry.value.text.trim(),
                };
                if (!mail) {
                  final start = DateTime.tryParse(updated['start']!),
                      end = DateTime.tryParse(updated['end']!);
                  if (start == null ||
                      end == null ||
                      end.isBefore(start) ||
                      ymd(start) != updated['start'] ||
                      ymd(end) != updated['end']) {
                    toast('派遣終了日は開始日以降を選んでください');
                    return;
                  }
                }
                if (mail &&
                    updated['to']!.isNotEmpty &&
                    !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                        .hasMatch(updated['to']!)) {
                  toast('宛先メールアドレスを確認してください');
                  return;
                }
                Navigator.pop(ctx);
                run(
                  () => c.commit((d, e) {
                    if (mail) {
                      d.mail = updated;
                    } else {
                      d.profile.addAll(updated);
                    }
                  }),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    await Navigator.of(context).push(route);
    // The pop result completes before the closing animation and overlay are removed.
    await route.completed;
    for (final field in fields.values) {
      field.dispose();
    }
  }
}
