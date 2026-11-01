import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/services/notification_actions.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/store.dart';

import 'engine_test.dart' show fixture;
import 'widget_test.dart' show TestNotifications;

class FailingActionStore extends MemoryStore {
  bool fail = false;
  @override
  Future<void> save(AppData data, bool demo) async {
    if (fail) throw StateError('save failed');
    await super.save(data, demo);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 3, 9);
  Future<MemoryStore> populated([MemoryStore? input]) async {
    final store = input ?? MemoryStore();
    final data = fixture()..nextDay = true;
    MedicationEngine(data).materialize(now);
    await store.save(data, false);
    await store.saveMode(false);
    return store;
  }

  test('3種類のOS通知ボタンはUIを起動せず保存成功後に消す', () {
    final data = fixture();
    for (final previous in [false, true]) {
      final details = NotificationService.details(
        data,
        previous: previous,
      ).android!;
      for (final action in details.actions!) {
        expect(action.showsUserInterface, false);
        expect(action.cancelNotification, false);
      }
    }
  });
  test('バックグラウンド確認は識別子だけ保存し服用・在庫・他領域を変えない', () async {
    final store = await populated();
    await store.save(fixture(), true);
    final before = (await store.load(false))!;
    final demo = (await store.load(true))!.export();
    final cancellations = <String>[];
    final processor = NotificationActionProcessor(
      store,
      cancel: (payload) async {
        expect(
          (await store.load(false))!.reminderAcknowledgements,
          contains(payload),
        );
        cancellations.add(payload);
      },
    );
    const payload = 'reminder:a@2026-11-03';
    expect(await processor.handle(payload, 'reminder_confirm', now), true);
    expect(await processor.handle(payload, 'reminder_confirm', now), true);
    final saved = (await store.load(false))!;
    expect(saved.reminderAcknowledgements, [payload]);
    expect(
      jsonEncode(saved.doses.map((d) => d.toJson()).toList()),
      jsonEncode(before.doses.map((d) => d.toJson()).toList()),
    );
    expect((await store.load(true))!.export(), demo);
    expect(cancellations, [payload, payload]);
  });
  test('飲んだは保存内容を維持、飲み忘れは前日のみ変更し残数を戻す', () async {
    final store = await populated();
    final processor = NotificationActionProcessor(store, cancel: (_) async {});
    final before = (await store.load(false))!.export();
    const payload = 'check:a@2026-11-02';
    await processor.handle(payload, 'previous_taken', now);
    expect((await store.load(false))!.export(), before);
    await processor.handle(payload, 'previous_missed', now);
    final data = (await store.load(false))!;
    expect(data.doses.first.explicit, DoseStatus.missed);
    expect(data.doses.last.explicit, isNull);
    expect(MedicationEngine(data).balance('a', now, now), 29);
    final missed = data.export();
    await processor.handle(payload, 'previous_missed', now);
    await processor.handle(payload, 'previous_taken', now);
    expect((await store.load(false))!.export(), missed);
  });
  test('修正済み・確認OFF・当日と未来の確認では服用を上書きしない', () async {
    for (final kind in ['corrected', 'off', 'today', 'future']) {
      final store = await populated();
      await store.update(false, (data) {
        if (kind == 'corrected') {
          MedicationEngine(data).record(
            data.doses.first,
            DoseStatus.confirmed,
            now,
            actual: data.doses.first.scheduled,
          );
        }
        if (kind == 'off') data.nextDay = false;
      });
      final before = (await store.load(false))!.export();
      final date = kind == 'today'
          ? '2026-11-03'
          : kind == 'future'
          ? '2026-11-04'
          : '2026-11-02';
      await NotificationActionProcessor(
        store,
        cancel: (_) async {},
      ).handle('check:a@$date', 'previous_missed', now);
      expect((await store.load(false))!.export(), before);
    }
  });
  test('テスト通知の全回答は実データにも検証データにも書き込まない', () async {
    final store = await populated();
    await store.save(fixture(), true);
    final before = (await store.load(false))!.export();
    final demo = (await store.load(true))!.export();
    final cancelled = <String>[];
    final processor = NotificationActionProcessor(
      store,
      cancel: (p) async => cancelled.add(p),
    );
    for (final pair in [
      ('preview:reminder', 'reminder_confirm'),
      ('preview:check', 'previous_taken'),
      ('preview:check', 'previous_missed'),
    ]) {
      expect(await processor.handle(pair.$1, pair.$2, now), true);
    }
    expect(cancelled.length, 3);
    expect((await store.load(false))!.export(), before);
    expect((await store.load(true))!.export(), demo);
  });
  test('保存失敗時は通知を消さず、再操作で保存・消去できる', () async {
    final store = FailingActionStore();
    await populated(store);
    final cancelled = <String>[];
    final processor = NotificationActionProcessor(
      store,
      cancel: (p) async => cancelled.add(p),
    );
    store.fail = true;
    await expectLater(
      processor.handle('reminder:a@2026-11-03', 'reminder_confirm', now),
      throwsStateError,
    );
    expect(cancelled, isEmpty);
    expect((await store.load(false))!.reminderAcknowledgements, isEmpty);
    store.fail = false;
    expect(
      await processor.handle('reminder:a@2026-11-03', 'reminder_confirm', now),
      true,
    );
  });
  test('不明な通知・組合せ・欠落データでは保存や消去を行わない', () async {
    final store = await populated();
    final before = (await store.load(false))!.export();
    final cancelled = <String>[];
    final processor = NotificationActionProcessor(
      store,
      cancel: (p) async => cancelled.add(p),
    );
    for (final pair in [
      (null, null),
      ('check', 'previous_missed'),
      ('reminder:missing', 'reminder_confirm'),
      ('reminder:unknown@2026-11-03', 'reminder_confirm'),
      ('check:a@2026-11-02', 'reminder_confirm'),
    ]) {
      expect(await processor.handle(pair.$1, pair.$2, now), false);
    }
    expect((await store.load(false))!.export(), before);
    expect(cancelled, isEmpty);
  });
  test('画面保存とバックグラウンド回答が重なっても双方を保持する', () async {
    final store = await populated();
    final c = AppController.withDemoForTesting(store, TestNotifications());
    await c.init();
    final processor = NotificationActionProcessor(store, cancel: (_) async {});
    await Future.wait([
      c.commit((d, e) => d.profile['location'] = '保存場所'),
      processor.handle('reminder:a@2026-11-03', 'reminder_confirm', now),
    ]);
    // The controller's cached copy may predate the background action.
    await c.commit((d, e) => d.profile['job'] = '後から保存');
    expect(c.data.profile['location'], '保存場所');
    expect(c.data.profile['job'], '後から保存');
    expect(c.data.reminderAcknowledgements, ['reminder:a@2026-11-03']);
  });

  Future<AppController> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
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
      TestNotifications(),
    );
    await c.init();
    await c.replace(fixture());
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  for (final size in [const Size(390, 844), const Size(360, 640)]) {
    testWidgets('小画面${size.height}でも黒い拒否メッセージがダイアログの手前で見える', (tester) async {
      final c = await open(tester, size);
      await tester.ensureVisible(
        find.byKey(const ValueKey('calendar-day-2026-11-02')),
      );
      await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-02')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('day-action-delay')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('服用日 2026-11-02'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      final before = c.data.export();
      await tester.tap(find.text('服用日を保存'));
      await tester.pumpAndSettle();
      final error = find.byKey(const ValueKey('edit-dose-error'));
      expect(error.hitTestable(), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget(error), isA<SnackBar>());
      final rect = tester.getRect(error);
      expect(rect.bottom, lessThan(size.height));
      expect(rect.top, greaterThan(0));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(c.data.export(), before);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('通知の状態・省電力説明を共通許可ボタンの直下に配置する', (tester) async {
    final c = await open(tester, const Size(390, 844));
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    final permission = find.byKey(const ValueKey('notification-permission'));
    final status = find.text(c.notifications.status);
    final explanation = find.text(
      'OSの省電力等により遅延する場合があります。長期間起動しない場合は通知が途切れる場合があります。タイムゾーン変更後はアプリを起動しなおしてください。',
    );
    final toggle = find.byKey(const ValueKey('reminder-enabled'));
    expect(
      tester.getRect(permission).bottom,
      lessThanOrEqualTo(tester.getRect(status).top),
    );
    expect(
      tester.getRect(status).bottom,
      lessThanOrEqualTo(tester.getRect(explanation).top),
    );
    expect(
      tester.getRect(explanation).bottom,
      lessThan(tester.getRect(toggle).top),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
