import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/services/store.dart';
import 'package:malaria_care/services/notifications.dart';

class TestNotifications extends NotificationService {
  final List<String> acknowledgements = [];
  @override
  Future<void> acknowledgeReminder(String payload) async {
    acknowledgements.add(payload);
  }

  @override
  Future<void> permission() async {}

  @override
  Future<void> init() async {
    status = 'テスト環境：OS通知なし';
  }
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('NotoSansJP')
      ..addFont(rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf'));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  testWidgets('スマートフォン幅でカレンダー・報告・設定を表示', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await controller.init();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MalariaApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('いつもの毎日を、安心に。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('goldens/calendar.png'),
    );
    expect(find.byIcon(Icons.fact_check_outlined), findsNothing);
    expect(find.textContaining('未確認'), findsNothing);
    await tester.tap(find.byIcon(Icons.description_outlined));
    await tester.pumpAndSettle();
    expect(find.text('記録を、報告につなげる。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(const ValueKey('capture')),
      matchesGoldenFile('goldens/report.png'),
    );
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('あなたの設定'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('薬の新規登録フォームを開き、必須項目検証', (tester) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await controller.init();
    await controller.switchMode(false);
    await tester.pumpWidget(MalariaApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('薬の管理').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('register-medicine')));
    await tester.pumpAndSettle();
    expect(find.text('薬を登録'), findsAtLeastNWidgets(1));
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(find.text('薬名を入力'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('入手・消失の画面登録、履歴の編集・削除で再計算', (tester) async {
    tester.view.physicalSize = const Size(1100, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await c.init();
    final before = c.engine.balance('demo-daily', c.now, c.now),
        original = c.data.refills.length;
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('薬の管理').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('薬を入手'));
    await tester.tap(find.text('薬を入手'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '入手数（錠）'), '8');
    await tester.tap(find.text('履歴を保存'));
    await tester.pumpAndSettle();
    expect(c.data.refills.length, original + 1);
    expect(c.engine.balance('demo-daily', c.now, c.now), before + 8);
    await tester.ensureVisible(find.text('入手・消失履歴（編集・削除）'));
    await tester.tap(find.text('入手・消失履歴（編集・削除）'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('入手履歴を編集').first);
    await tester.tap(find.byTooltip('入手履歴を編集').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '入手数（錠）'), '10');
    await tester.tap(find.text('履歴を保存'));
    await tester.pumpAndSettle();
    expect(c.engine.balance('demo-daily', c.now, c.now), before + 10);
    await tester.ensureVisible(find.byTooltip('入手履歴を削除').first);
    await tester.tap(find.byTooltip('入手履歴を削除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('実行する'));
    await tester.pumpAndSettle();
    expect(c.data.refills.length, original);
    expect(c.engine.balance('demo-daily', c.now, c.now), before);
    await tester.ensureVisible(find.text('消失を登録'));
    await tester.tap(find.text('消失を登録'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '消失数（錠）'), '2');
    await tester.tap(find.text('履歴を保存'));
    await tester.pumpAndSettle();
    expect(c.data.losses.length, 2);
    expect(c.engine.balance('demo-daily', c.now, c.now), before - 2);
    await tester.ensureVisible(find.byTooltip('消失履歴を編集').first);
    await tester.tap(find.byTooltip('消失履歴を編集').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '消失数（錠）'), '3');
    await tester.tap(find.text('履歴を保存'));
    await tester.pumpAndSettle();
    expect(c.engine.balance('demo-daily', c.now, c.now), before - 3);
    await tester.ensureVisible(find.byTooltip('消失履歴を削除').first);
    await tester.tap(find.byTooltip('消失履歴を削除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('実行する'));
    await tester.pumpAndSettle();
    expect(c.data.losses.length, 1);
    expect(c.engine.balance('demo-daily', c.now, c.now), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('実残数一致と本人確認を経てPDF作成を有効化し、不一致なら停止', (tester) async {
    tester.view.physicalSize = const Size(1000, 1100);
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
    await tester.tap(find.byIcon(Icons.description_outlined));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('generate-report')))
          .onPressed,
      isNull,
    );
    final stock = find.byKey(const ValueKey('actual-stock'));
    await tester.ensureVisible(stock);
    await tester.enterText(
      stock,
      numberForTest(c.engine.balance('demo-daily', c.now, c.now)),
    );
    await tester.pumpAndSettle();
    final check = find.byKey(const ValueKey('stock-confirmation'));
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('generate-report')))
          .onPressed,
      isNotNull,
    );
    await tester.ensureVisible(stock);
    await tester.enterText(stock, '9999');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('generate-report')))
          .onPressed,
      isNull,
    );
    expect(c.data.losses.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('登録済みの薬には追加ボタンがなく、登録行から編集できる', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await c.init();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('medicine-capture'),
        child: MalariaApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.medication_outlined).last);
    await tester.pumpAndSettle();
    expect(find.byTooltip('薬を追加'), findsNothing);
    expect(find.byKey(const ValueKey('register-medicine')), findsNothing);
    expect(find.text('Malaria Care version 0.8'), findsOneWidget);
    expect(find.text('Nakata Design'), findsOneWidget);
    expect(find.textContaining('JICA'), findsNothing);
    await expectLater(
      find.byKey(const ValueKey('medicine-capture')),
      matchesGoldenFile('goldens/medicine.png'),
    );
    final edit = find.byTooltip('登録薬を編集');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.text('薬を編集'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(c.data.medicines.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

String numberForTest(double n) => n.toString();
