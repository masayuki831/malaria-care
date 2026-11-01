import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/services/store.dart';

import 'widget_test.dart' show TestNotifications;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansJP',
    )..addFont(rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  Future<AppController> openSettings(
    WidgetTester tester, {
    bool demo = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
    );
    await c.init();
    if (!demo) await c.switchMode(false);
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    return c;
  }

  for (final demo in [true, false]) {
    testWidgets('${demo ? 'デモ' : '実利用'}：プロフィールを入力フォーカス中に保存し、再編集・読込できる', (
      tester,
    ) async {
      final c = await openSettings(tester, demo: demo);
      for (var i = 1; i <= 2; i++) {
        final edit = find.text('プロフィールを編集');
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        final name = find.widgetWithText(TextField, '氏名');
        await tester.enterText(name, '保存テスト $i');
        await tester.tap(find.widgetWithText(FilledButton, '保存'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(c.data.profile['name'], '保存テスト $i');
        final persisted = await c.store.load(demo);
        expect(persisted!.profile['name'], '保存テスト $i');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
  testWidgets('メール設定：宛先の検証後に入力中の本文を保存し、再編集できる', (tester) async {
    final c = await openSettings(tester);
    final edit = find.text('宛先・テンプレート・署名を編集');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final to = find.widgetWithText(TextField, '宛先メールアドレス');
    await tester.enterText(to, 'invalid');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('メール設定'), findsOneWidget);
    expect(c.data.mail['to'], '');
    await tester.enterText(to, 'report@example.invalid');
    final body = find.widgetWithText(TextField, '本文テンプレート');
    await tester.ensureVisible(body);
    await tester.enterText(body, '保存テスト本文 {氏名}');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(c.data.mail['to'], 'report@example.invalid');
    expect(c.data.mail['body'], '保存テスト本文 {氏名}');
    expect((await c.store.load(true))!.mail['body'], '保存テスト本文 {氏名}');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.text('保存テスト本文 {氏名}'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets('プロフィール：入力中にキャンセルしてもエラーにならず変更を保存しない', (tester) async {
    final c = await openSettings(tester), before = c.data.profile['name'];
    final edit = find.text('プロフィールを編集');
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '氏名'), '保存しない変更');
    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(c.data.profile['name'], before);
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    expect(find.text(before!), findsAtLeastNWidgets(1));
    await tester.tap(find.widgetWithText(TextButton, 'キャンセル'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
