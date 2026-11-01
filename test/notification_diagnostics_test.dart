import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as reduced;
import 'package:timezone/timezone.dart' as tz;
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/services/notifications.dart';
import 'package:malaria_care/services/store.dart';
import 'package:malaria_care/ui/notification_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('dexterous.com/flutter/local_notifications');
  const zone = MethodChannel('flutter_timezone');
  const device = MethodChannel('malaria_care/diagnostics');
  String zoneId = 'GMT';
  bool initResult = true;
  Object? initError;
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    zoneId = 'GMT';
    initResult = true;
    initError = null;
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      zone,
      (_) async => {'identifier': zoneId},
    );
    messenger.setMockMethodCallHandler(
      device,
      (_) async => {
        'model': 'Pixel 6a',
        'androidRelease': '17',
        'sdkInt': 37,
        'deviceTimezone': 'GMT',
      },
    );
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      if (call.method == 'initialize') {
        if (initError != null) throw initError!;
        return initResult;
      }
      if (call.method == 'getNotificationAppLaunchDetails')
        return {'notificationLaunchedApp': false};
      if (call.method == 'areNotificationsEnabled') return true;
      return null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [zone, device, native]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('旧DBのGMTエラーを再現し、全DBでGMTの通知初期化に成功する', () async {
    reduced.initializeTimeZones();
    expect(() => tz.getLocation('GMT'), throwsA(anything));
    final service = NotificationService();
    await service.init();
    expect(service.ready, true);
    expect(service.timezoneId, 'GMT');
    expect(tz.local.currentTimeZone.offset, Duration.zero);
    expect(service.diagnosticReport, contains('INIT READY'));
    expect(service.diagnosticReport, contains('Pixel 6a'));
    expect(service.diagnosticReport, contains('sdkInt: 37'));
  });
  test('通常の地域タイムゾーンと夏時間の規則を保持する', () async {
    zoneId = 'Europe/London';
    final service = NotificationService();
    await service.init();
    expect(tz.TZDateTime(tz.local, 2026, 1, 1).timeZoneOffset, Duration.zero);
    expect(
      tz.TZDateTime(tz.local, 2026, 7, 1).timeZoneOffset,
      const Duration(hours: 1),
    );
  });
  test('未知の地域名をUTCへ黙って変更せず、失敗工程を出す', () async {
    zoneId = 'Invalid/Region';
    final service = NotificationService();
    await expectLater(service.init(), throwsA(isA<NotificationInitFailure>()));
    expect(service.ready, false);
    expect(service.initFailure!.step, 'タイムゾーンの設定');
    expect(service.diagnosticReport, contains('Invalid/Region'));
  });
  test('タイムゾーン取得のプラグインエラーコードを保持する', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          zone,
          (_) async => throw PlatformException(
            code: 'timezone_test_failure',
            message: 'timezone unavailable',
          ),
        );
    final service = NotificationService();
    await expectLater(service.init(), throwsA(isA<NotificationInitFailure>()));
    expect(service.initFailure!.step, '端末のタイムゾーン取得');
    expect(service.initFailure!.code, 'timezone_test_failure');
  });
  test('OS初期化がfalseなら準備完了にせず診断へ記録', () async {
    initResult = false;
    final service = NotificationService();
    await expectLater(service.init(), throwsA(isA<NotificationInitFailure>()));
    expect(service.ready, false);
    expect(service.initFailure!.step, 'OS通知の登録結果');
  });
  test('通知アイコン等のOS側エラーを工程とコードで識別できる', () async {
    initError = PlatformException(
      code: 'invalid_icon',
      message: 'test icon unavailable',
    );
    final service = NotificationService();
    await expectLater(service.init(), throwsA(isA<NotificationInitFailure>()));
    expect(service.initFailure!.step, 'OS通知の登録');
    expect(service.initFailure!.code, 'invalid_icon');
  });
  test('確認用の通知は専用IDでOSへ渡し、結果をログに残す', () async {
    final service = NotificationService();
    await service.init();
    await service.showTestNotification();
    final show = calls.singleWhere((call) => call.method == 'show');
    expect(
      show.arguments['id'],
      NotificationService.notificationId('reminder:notification-test'),
    );
    expect(show.arguments['payload'], 'reminder:notification-test');
    expect(service.diagnosticReport, contains('TEST SHOW accepted by OS'));
  });
  test('再診断の成功で警告を解除し、保存内容を変えない', () async {
    final service = NotificationService(), store = MemoryStore();
    final c = AppController.withDemoForTesting(store, service);
    zoneId = 'Invalid/Region';
    await c.init();
    final before = c.data.export();
    expect(c.warning, isNotNull);
    zoneId = 'GMT';
    await c.retryNotifications();
    expect(c.warning, isNull);
    expect(c.notifications.ready, true);
    expect(c.data.export(), before);
    expect((await store.load(true))!.export(), before);
  });
  testWidgets('診断画面からテスト通知とログコピーを実行でき、氏名・薬を含めない', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = NotificationService(),
        c = AppController.withDemoForTesting(
          MemoryStore(),
          NotificationService(),
        );
    // Use the initialized service consistently for both controller and page.
    final controller = AppController.withDemoForTesting(c.store, service);
    await controller.init();
    await tester.pumpWidget(
      MaterialApp(home: NotificationDiagnosticsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('通知の準備：完了'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('show-test-notification')));
    await tester.pumpAndSettle();
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData')
            copied = call.arguments['text'];
          return null;
        });
    await tester.tap(
      find.byKey(const ValueKey('copy-notification-diagnostics')),
    );
    await tester.pumpAndSettle();
    expect(copied, contains('TEST SHOW accepted by OS'));
    expect(copied, contains('Pixel 6a'));
    expect(copied, isNot(contains(controller.data.profile['name']!)));
    expect(copied, isNot(contains(controller.data.medicines.single.name)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
  });
}
