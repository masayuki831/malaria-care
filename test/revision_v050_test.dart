import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/store.dart';
import 'package:malaria_care/ui/shell.dart' show delayWarning;

import 'engine_test.dart' show fixture;
import 'widget_test.dart' show TestNotifications;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<AppController> open(
    WidgetTester tester, {
    AppData? data,
    Size size = const Size(390, 844),
  }) async {
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
    await c.replace(data ?? fixture());
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> dayMenu(WidgetTester tester, String date) async {
    final cell = find.byKey(ValueKey('calendar-day-$date'));
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('日付を押すと対象日・3つの選択肢・遅延注意だけをその場に表示する', (tester) async {
    final c = await open(tester);
    final before = c.data.export();
    expect(find.text('服用済みに戻す'), findsNothing);
    await dayMenu(tester, '2026-11-02');
    expect(find.text('2026-11-02'), findsOneWidget);
    for (final label in ['服用済み', '飲み忘れ', '遅延服用', delayWarning]) {
      expect(find.text(label), findsOneWidget);
    }
    final rows = find.byType(PopupMenuItem<String>);
    expect(
      find.descendant(
        of: rows,
        matching: find.text(c.data.medicines.single.name),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: rows, matching: find.textContaining('錠')),
      findsNothing,
    );
    expect(find.textContaining('服薬後の'), findsNothing);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(c.data.export(), before);
    await close(tester);
  });
  testWidgets('ポップアップから飲み忘れ・服用済みを保存し残数と日付色を更新', (tester) async {
    final c = await open(tester);
    final before = c.engine.balance('a', c.now, c.now);
    await dayMenu(tester, '2026-11-02');
    await tester.tap(find.byKey(const ValueKey('day-action-missed')));
    await tester.pumpAndSettle();
    expect(c.data.doses.first.explicit, DoseStatus.missed);
    expect(c.engine.balance('a', c.now, c.now), before + 1);
    await dayMenu(tester, '2026-11-02');
    await tester.tap(find.byKey(const ValueKey('day-action-taken')));
    await tester.pumpAndSettle();
    expect(c.data.doses.first.actual, DateTime(2026, 11, 2));
    expect(c.engine.balance('a', c.now, c.now), before);
    expect(
      (await c.store.load(true))!.doses.first.explicit,
      DoseStatus.confirmed,
    );
    await close(tester);
  });
  testWidgets('予定なしの日へ遅延し移動先の服用済み操作でも日付を戻さない', (tester) async {
    final c = await open(tester, data: fixture(frequency: Frequency.weekdays));
    await dayMenu(tester, '2026-11-02');
    await tester.tap(find.byKey(const ValueKey('day-action-delay')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(c.data.medicines.single.name),
      ),
      findsNothing,
    );
    await tester.tap(find.text('服用日 2026-11-02'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服用日を保存'));
    await tester.pumpAndSettle();
    expect(c.data.doses.single.actual, DateTime(2026, 11, 3));
    await dayMenu(tester, '2026-11-03');
    expect(find.text('元の予定日 2026-11-02'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('day-action-taken')));
    await tester.pumpAndSettle();
    expect(c.data.doses.single.actual, DateTime(2026, 11, 3));
    expect(c.engine.balance('a', c.now, c.now), 29);
    await close(tester);
  });
  testWidgets('予定なし・未来の日は3操作を無効化し新しい服用を作らない', (tester) async {
    final c = await open(tester, data: fixture(frequency: Frequency.weekdays));
    final before = c.data.export();
    for (final date in ['2026-11-03', '2026-11-09']) {
      await dayMenu(tester, date);
      for (final action in ['taken', 'missed', 'delay']) {
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.byKey(ValueKey('day-action-$action')),
              )
              .enabled,
          false,
        );
      }
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
    }
    expect(c.data.export(), before);
    await close(tester);
  });
  testWidgets('残数は短い説明の直下でカレンダーより上、日付セルを48に縮める', (tester) async {
    await open(tester);
    final text = find.text('飲み忘れ・服用日の変更がある日だけ修正してください。');
    final stock = find.text('薬の残数');
    final grid = find.byType(GridView);
    expect(tester.getRect(text).bottom, lessThan(tester.getRect(stock).top));
    expect(tester.getRect(stock).bottom, lessThan(tester.getRect(grid).top));
    expect(
      tester
          .getSize(find.byKey(const ValueKey('calendar-day-2026-11-02')))
          .height,
      48,
    );
    expect(find.textContaining('今日までの予定は服用済み'), findsNothing);
    expect(find.textContaining('服用済みとして計算した残数'), findsNothing);
    await close(tester);
  });
  testWidgets('薬の管理では残数や説明を省き入手・消失と薬の編集を利用できる', (tester) async {
    await open(tester);
    await tester.tap(find.byIcon(Icons.medication_outlined).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('在庫切れ予測'), findsNothing);
    expect(find.textContaining('使用する薬を1種類管理'), findsNothing);
    expect(find.text('薬を入手'), findsOneWidget);
    expect(find.text('消失を登録'), findsOneWidget);
    expect(find.byTooltip('登録薬を編集'), findsOneWidget);
    await close(tester);
  });
  testWidgets('設定は服用確認へ改名しリマインダーの共通説明を省く', (tester) async {
    await open(tester);
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('服用確認'), findsOneWidget);
    expect(find.text('服用確認の通知音'), findsOneWidget);
    expect(find.text('服用確認のバイブ'), findsOneWidget);
    expect(find.text('前日の服用確認'), findsNothing);
    expect(find.text('すべての登録薬に共通する設定です'), findsNothing);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('reminder-enabled')),
          )
          .subtitle,
      isNull,
    );
    await close(tester);
  });
  test('OS通知とテスト通知の見出しは前日の服用確認のままにする', () async {
    final data = fixture()
      ..nextDay = true
      ..checkHour = 10;
    final requests = NotificationService.requests(
      data,
      DateTime(2026, 11, 3, 9),
    );
    expect(
      requests.where((r) => r.payload.startsWith('check:')).first.title,
      '前日の服用確認',
    );
    expect(
      requests.where((r) => r.payload.startsWith('check:')).first.body,
      contains('2026-11-02'),
    );
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const native = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null),
    );
    await (NotificationService()..ready = true).showPreviewNotification(
      data,
      DateTime(2026, 11, 3),
      previous: true,
    );
    expect(
      calls.singleWhere((c) => c.method == 'show').arguments['title'],
      '前日の服用確認（テスト）',
    );
  });
}
