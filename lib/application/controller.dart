import 'package:flutter/foundation.dart';

import '../domain/model.dart';
import '../domain/engine.dart';
import '../services/store.dart';
import '../services/notifications.dart';
import '../services/report_mail.dart';

class AppController extends ChangeNotifier {
  final DataStore store;
  final NotificationService notifications;
  final ReportMailService reportMail;
  AppData data = AppData.empty();
  bool demo = false;
  final bool allowDemo;
  DateTime virtualNow = DateTime(2026, 11, 3, 9);
  String? warning;
  AppController(
    this.store,
    this.notifications, {
    ReportMailService? reportMail,
    this.allowDemo = false,
  }) : reportMail = reportMail ?? ReportMailService();
  @visibleForTesting
  AppController.withDemoForTesting(
    DataStore store,
    NotificationService notifications, {
    ReportMailService? reportMail,
  }) : this(store, notifications, reportMail: reportMail, allowDemo: true);
  DateTime get now => demo ? virtualNow : DateTime.now();
  MedicationEngine get engine => MedicationEngine(data);
  Future<void> init() async {
    demo = allowDemo && await store.loadMode();
    if (!allowDemo) await store.saveMode(false);
    data = await store.load(demo) ?? (demo ? demoData() : AppData.empty());
    virtualNow =
        DateTime.tryParse(data.profile['_demoClock'] ?? '') ?? virtualNow;
    data = (await store.update(demo, (latest) {
      MedicationEngine(latest).materialize(now);
    }, ifAbsent: () => data))!;
    await retryNotifications();
  }

  Future<void> retryNotifications({bool requestPermission = false}) async {
    try {
      await notifications.init();
      if (requestPermission) await notifications.permission();
      warning = null;
      await syncNotifications();
    } catch (error) {
      warning =
          notifications.initFailure?.summary ??
          '通知の準備に失敗しました。設定の通知権限ボタンから再試行してください。';
      notifications.logDiagnostic(
        'CONTROLLER init failed: ${error.runtimeType}',
      );
    }
    notifyListeners();
  }

  Future<void> _commitQueue = Future<void>.value();
  Future<void> commit(void Function(AppData, MedicationEngine) change) {
    final operation = _commitQueue.then((_) => _commitNow(change));
    _commitQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<void> _commitNow(
    void Function(AppData, MedicationEngine) change,
  ) async {
    final currentMode = demo;
    final updated = await store.update(currentMode, (draft) {
      final logic = MedicationEngine(draft);
      logic.materialize(now);
      change(draft, logic);
      draft.validate();
    }, ifAbsent: () => AppData.parse(data.export()));
    if (currentMode != demo) return;
    data = updated!;
    notifyListeners();
    await syncNotifications();
  }

  Future<void> syncNotifications() async {
    try {
      await notifications.sync(data, now, demo: demo);
    } catch (error) {
      notifications.logDiagnostic('SYNC failed: $error');
      warning = '通知の予約に失敗しました。服薬記録は保存されています。OSの通知設定を確認してください。';
    }
    notifyListeners();
  }

  Future<void> switchMode(bool useDemo) async {
    if (useDemo && !allowDemo) throw StateError('このアプリでは架空データを使用できません。');
    final loaded =
        await store.load(useDemo) ?? (useDemo ? demoData() : AppData.empty());
    demo = useDemo;
    data = loaded;
    await store.saveMode(useDemo);
    if (demo)
      virtualNow =
          DateTime.tryParse(data.profile['_demoClock'] ?? '') ??
          DateTime(2026, 11, 3, 9);
    await commit((_, __) {});
  }

  Future<void> setClock(DateTime date) async {
    if (!demo) throw StateError('仮想日時は検証モードだけで利用できます。');
    if (date.isBefore(now)) throw ArgumentError('時刻を戻す場合はデモを初期化してください。');
    virtualNow = date;
    await commit((d, e) {
      d.profile['_demoClock'] = date.toIso8601String();
      e.materialize(date);
    });
  }

  Future<void> resetDemo() async {
    await store.save(demoData(), true);
    await switchMode(true);
    virtualNow = DateTime(2026, 11, 3, 9);
    await commit((_, __) {});
  }

  Future<void> replace(AppData incoming) async {
    incoming.validate();
    MedicationEngine(incoming).materialize(now);
    await store.save(incoming, demo);
    data = incoming;
    notifyListeners();
    await syncNotifications();
  }

  Future<void> setNotificationEnabled({
    required bool previous,
    required bool enabled,
  }) async {
    final wasEnabled = previous ? data.nextDay : data.remindersEnabled;
    if (enabled && !wasEnabled)
      await retryNotifications(requestPermission: true);
    await commit((draft, _) {
      if (previous) {
        draft.nextDay = enabled;
      } else {
        draft.remindersEnabled = enabled;
      }
    });
  }
}
