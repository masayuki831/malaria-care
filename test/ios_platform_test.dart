import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/services/notifications.dart';

import 'engine_test.dart' show fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('dexterous.com/flutter/local_notifications');
  const zone = MethodChannel('flutter_timezone');
  final calls = <MethodCall>[];
  bool allowed = true, provisional = false;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    allowed = true;
    provisional = false;
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      zone,
      (_) async => {'identifier': 'Africa/Accra'},
    );
    messenger.setMockMethodCallHandler(native, (call) async {
      calls.add(call);
      return switch (call.method) {
        'initialize' => true,
        'getNotificationAppLaunchDetails' => {'notificationLaunchedApp': false},
        'checkPermissions' => {
          'isEnabled': allowed,
          'isProvisionalEnabled': provisional,
        },
        'requestPermissions' => allowed,
        'pendingNotificationRequests' ||
        'getActiveNotifications' => <dynamic>[],
        _ => null,
      };
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(zone, null);
  });
  test('iPhoneは直近64件、Androidは100件で、両種類を日時順に保持する', () {
    final data = fixture()..nextDay = true;
    final now = DateTime(2026, 11, 3, 9);
    final android = NotificationService.requests(
      data,
      now,
      platform: TargetPlatform.android,
    );
    final ios = NotificationService.requests(
      data,
      now,
      platform: TargetPlatform.iOS,
    );
    expect(android.length, 100);
    expect(ios, android.take(64).toList());
    expect(ios.any((n) => n.payload.startsWith('reminder:')), true);
    expect(ios.any((n) => n.payload.startsWith('check:')), true);
    for (var i = 1; i < ios.length; i++) {
      expect(ios[i].at.isBefore(ios[i - 1].at), false);
    }
  });
  test('iPhoneの通知許可ON・OFFと仮許可をOSの状態から読み取る', () async {
    final service = NotificationService();
    await service.refreshPermissionStatus();
    expect(service.permissionStatus, 'iPhoneの通知許可：ON');
    allowed = false;
    await service.refreshPermissionStatus();
    expect(service.permissionStatus, 'iPhoneの通知許可：OFF');
    provisional = true;
    await service.refreshPermissionStatus();
    expect(service.permissionStatus, 'iPhoneの通知許可：ON');
    expect(calls.where((c) => c.method == 'requestPermissions'), isEmpty);
  });
  test('初期化では許可を求めず、明示操作時だけiPhoneの許可要求へ渡す', () async {
    final service = NotificationService();
    await service.init();
    expect(service.ready, true);
    final args =
        calls.singleWhere((c) => c.method == 'initialize').arguments as Map;
    expect(args['requestAlertPermission'], false);
    expect(args['requestSoundPermission'], false);
    expect(args['requestBadgePermission'], false);
    expect(calls.any((c) => c.method == 'requestPermissions'), false);
    await service.permission();
    final permission =
        calls.singleWhere((c) => c.method == 'requestPermissions').arguments
            as Map;
    expect(permission['alert'], true);
    expect(permission['sound'], true);
    expect(permission['badge'], true);
  });
  test('iPhoneの実際の予約APIへ上限64件だけ渡し、初期OFFでは予約しない', () async {
    final service = NotificationService();
    await service.init();
    final data = fixture()..nextDay = true;
    final before = data.export();
    await service.sync(data, DateTime(2026, 11, 3, 9), demo: false);
    final scheduled = calls.where((c) => c.method == 'zonedSchedule').toList();
    expect(scheduled.length, 64);
    expect(scheduled.first.arguments['payload'], startsWith('reminder:'));
    expect(data.export(), before);
    calls.clear();
    await service.sync(AppData.empty(), DateTime(2026, 11, 3, 9), demo: false);
    expect(calls.where((c) => c.method == 'zonedSchedule'), isEmpty);
  });
}
