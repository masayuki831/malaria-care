import 'dart:async';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/widgets.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/model.dart';
import '../domain/engine.dart';
import 'store.dart';
import 'notification_actions.dart';

const notificationActionPort = 'malaria_care_notification_actions';
Future<void> _backgroundQueue = Future<void>.value();

@pragma('vm:entry-point')
void notificationActionBackground(NotificationResponse response) {
  WidgetsFlutterBinding.ensureInitialized();
  // Serialize repeated taps as well as relying on the database transaction.
  _backgroundQueue = _backgroundQueue
      .then((_) async {
        final handled = await NotificationActionProcessor(
          SqliteStore(),
          cancel: (payload) => FlutterLocalNotificationsPlugin().cancel(
            id: NotificationService.notificationId(payload),
          ),
        ).handle(response.payload, response.actionId, DateTime.now());
        if (handled) {
          IsolateNameServer.lookupPortByName(notificationActionPort)
              ?.send(true);
        }
      })
      .catchError((Object error) {
        // Do not dismiss a notification if saving the response failed.
        if (kDebugMode)
          debugPrint('Notification action failed: ${error.runtimeType}');
      });
}

class NotificationInitFailure implements Exception {
  final String step, code, detail;
  NotificationInitFailure(this.step, this.code, this.detail);
  String get summary => '通知の準備に失敗しました：$step（$code）。設定の通知権限ボタンから再試行してください。';
  @override
  String toString() => '$step / $code / $detail';
}

class NotificationService {
  final plugin = FlutterLocalNotificationsPlugin();
  bool ready = false;
  String status = '通知はまだ有効になっていません';
  String permissionStatus = '通知の表示可否はOS設定に従います';
  String? pendingPayload, pendingAction;
  void Function(String?, String?)? onResponse;
  static const diagnosticBuild = '0.8.0+15';
  static const _deviceChannel = MethodChannel('malaria_care/diagnostics');
  final List<String> diagnosticLines = [];
  Map<String, dynamic> device = {};
  String? timezoneId;
  NotificationInitFailure? initFailure;
  String get diagnosticReport => [
    'Malaria Care version 0.8 / build $diagnosticBuild',
    'UTC: ${DateTime.now().toUtc().toIso8601String()}',
    'Platform: ${defaultTargetPlatform.name}',
    'Ready: $ready',
    'Permission: $permissionStatus',
    'Device: $device',
    'Timezone: ${timezoneId ?? 'not read'}',
    'Failure: ${initFailure ?? 'none'}',
    '',
    ...diagnosticLines,
  ].join('\n');
  void logDiagnostic(String message) {
    if (!kDebugMode) return;
    final line = '${DateTime.now().toUtc().toIso8601String()} $message';
    diagnosticLines.add(line);
    if (diagnosticLines.length > 100) diagnosticLines.removeAt(0);
    debugPrint('MC_NOTIFICATION $line');
  }

  Future<T> _step<T>(String name, FutureOr<T> Function() action) async {
    logDiagnostic('START $name');
    try {
      final value = await Future<T>.sync(action)
          .timeout(const Duration(seconds: 12));
      logDiagnostic('OK $name');
      return value;
    } catch (error, stack) {
      final code = error is PlatformException
          ? error.code
          : error.runtimeType.toString();
      final detail = error is PlatformException
          ? error.message ?? ''
          : error.toString();
      initFailure = NotificationInitFailure(name, code, detail);
      logDiagnostic('FAIL $initFailure');
      logDiagnostic(stack.toString().split('\n').take(6).join('\n'));
      ready = false;
      status = initFailure!.summary;
      throw initFailure!;
    }
  }

  Future<void> init() async {
    ready = false;
    initFailure = null;
    logDiagnostic('INIT build=$diagnosticBuild');
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      status = 'このプレビューではOS通知を使用しません';
      return;
    }
    if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) {
      try {
        device = Map<String, dynamic>.from(
          await _deviceChannel
                  .invokeMapMethod<String, dynamic>('deviceInfo')
                  .timeout(const Duration(seconds: 5)) ??
              {},
        );
        logDiagnostic('DEVICE $device');
      } catch (error) {
        logDiagnostic('DEVICE INFO unavailable: ${error.runtimeType}');
      }
    }
    await _step<void>('タイムゾーンDBの読込', () => tzdata.initializeTimeZones());
    final zone = await _step(
      '端末のタイムゾーン取得',
      () => FlutterTimezone.getLocalTimezone(),
    );
    timezoneId = zone.identifier;
    logDiagnostic('ZONE $timezoneId');
    await _step<void>(
      'タイムゾーンの設定',
      () => tz.setLocalLocation(tz.getLocation(zone.identifier)),
    );
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          'dose_reminder',
          actions: [DarwinNotificationAction.plain('reminder_confirm', '確認')],
        ),
        DarwinNotificationCategory(
          'previous_dose',
          actions: [
            DarwinNotificationAction.plain('previous_taken', '飲んだ'),
            DarwinNotificationAction.plain('previous_missed', '飲み忘れた'),
          ],
        ),
      ],
    );
    final initialized = await _step(
      'OS通知の登録',
      () => plugin.initialize(
        settings: InitializationSettings(
          android: const AndroidInitializationSettings('ic_notification'),
          iOS: darwin,
        ),
        onDidReceiveNotificationResponse: (r) =>
            dispatch(r.payload, r.actionId),
        onDidReceiveBackgroundNotificationResponse:
            notificationActionBackground,
      ),
    );
    if (initialized != true) {
      await _step<void>(
        'OS通知の登録結果',
        () => throw StateError('通知機能の登録が完了しませんでした：$initialized'),
      );
    }
    final launch = await _step(
      '通知からの起動情報取得',
      () => plugin.getNotificationAppLaunchDetails(),
    );
    if (launch?.didNotificationLaunchApp ?? false) {
      pendingPayload = launch!.notificationResponse?.payload;
      pendingAction = launch.notificationResponse?.actionId;
    }
    ready = true;
    logDiagnostic('INIT READY');
    await refreshPermissionStatus();
    status = '通知の準備ができました。$permissionStatus';
  }

  Future<void> refreshPermissionStatus() async {
    try {
      final enabled = await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled();
      if (enabled != null)
        permissionStatus = 'Androidの通知許可：${enabled ? 'ON' : 'OFF'}';
      final ios = plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final options = await ios?.checkPermissions();
      if (options != null) {
        final allowed = options.isEnabled || options.isProvisionalEnabled;
        permissionStatus = 'iPhoneの通知許可：${allowed ? 'ON' : 'OFF'}';
      }
      logDiagnostic('PERMISSION $permissionStatus');
    } catch (error) {
      logDiagnostic('PERMISSION query failed: ${error.runtimeType}');
    }
  }

  Future<void> showTestNotification() async {
    if (!ready) await init();
    if (!ready) throw ArgumentError('この環境ではOS通知を使用できません。');
    await refreshPermissionStatus();
    logDiagnostic('TEST SHOW requested');
    try {
      await plugin.show(
        id: notificationId('reminder:notification-test'),
        title: 'Malaria Care',
        body: '飲む時間です。',
        payload: 'reminder:notification-test',
        notificationDetails: details(AppData.empty(), previous: false),
      );
      logDiagnostic('TEST SHOW accepted by OS');
    } catch (error) {
      logDiagnostic('TEST SHOW failed: $error');
      rethrow;
    }
  }

  /// Explicit preview uses isolated payloads and never alters medication records.
  Future<void> showPreviewNotification(
    AppData data,
    DateTime now, {
    required bool previous,
  }) async {
    if (!ready) await init();
    if (!ready) throw ArgumentError('この環境ではOS通知を使用できません。');
    final payload = previous ? 'preview:check' : 'preview:reminder';
    // Repeated mock tests must alert again, even while a previous preview is visible.
    await plugin.cancel(id: notificationId(payload));
    await plugin.show(
      id: notificationId(payload),
      title: previous ? '前日の服用確認（テスト）' : 'Malaria Care（テスト）',
      body: previous ? '${ymd(plusDays(now, -1))}に薬を飲みましたか？' : '飲む時間です。',
      payload: payload,
      notificationDetails: details(data, previous: previous, preview: true),
    );
  }

  void dispatch(String? payload, String? action) {
    if (onResponse != null) {
      onResponse!(payload, action);
    } else {
      pendingPayload = payload;
      pendingAction = action;
    }
  }

  Future<void> permission() async {
    if (!ready) await init();
    if (!ready) return;
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final ios = plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    final allowed =
        await android?.requestNotificationsPermission() ??
        await ios?.requestPermissions(alert: true, badge: true, sound: true);
    permissionStatus = allowed == false
        ? '通知が許可されていません。OS設定から変更できます。'
        : '通知を許可しました（端末の省電力設定も確認してください）';
    status = permissionStatus;
    logDiagnostic('PERMISSION requested: $permissionStatus');
  }

  /// Notification time is independent of date-only intake accounting.
  static List<({DateTime at, String title, String body, String payload})>
  requests(AppData data, DateTime now, {TargetPlatform? platform}) {
    final queue =
        <({DateTime at, String title, String body, String payload})>[];
    final engine = MedicationEngine(data);
    if (data.remindersEnabled)
      for (final d in engine.generate(now, plusDays(now, 3650))) {
        final at = DateTime(
          d.scheduled.year,
          d.scheduled.month,
          d.scheduled.day,
          data.reminderHour,
          data.reminderMinute,
        );
        if (!at.isAfter(now) ||
            d.explicit != null ||
            data.reminderAcknowledgements.contains('reminder:${d.id}'))
          continue;
        queue.add((
          at: at,
          title: 'Malaria Care',
          body: '飲む時間です。',
          payload: 'reminder:${d.id}',
        ));
      }
    if (data.nextDay) {
      final snapshot = engine.ledger(now);
      for (final d in engine.generate(plusDays(now, -1), plusDays(now, 3649))) {
        if (d.explicit != null) continue;
        if (!day(d.scheduled).isAfter(day(now)) &&
            snapshot.status(d) != DoseStatus.assumed)
          continue;
        final following = plusDays(d.scheduled, 1);
        final at = DateTime(
          following.year,
          following.month,
          following.day,
          data.checkHour,
          data.checkMinute,
        );
        if (!at.isAfter(now)) continue;
        queue.add((
          at: at,
          title: '前日の服用確認',
          body: '${ymd(d.scheduled)}に${d.name}を飲みましたか？',
          payload: 'check:${d.id}',
        ));
      }
    }
    queue.sort((a, b) => a.at.compareTo(b.at));
    // iOS retains only the last 64 submitted requests. Submit the nearest 64
    // chronologically so later requests cannot evict near-term reminders.
    final limit = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS
        ? 64
        : 100;
    return queue.take(limit).toList();
  }

  static int notificationId(String payload) {
    var hash = 0x811c9dc5;
    for (final unit in payload.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return 0x40000000 | (hash & 0x3fffffff);
  }

  static NotificationDetails details(
    AppData data, {
    required bool previous,
    bool preview = false,
  }) {
    final sound = previous ? data.checkSound : data.reminderSound;
    final vibrate = previous ? data.checkVibration : data.reminderVibration;
    final suffix = 's${sound ? 1 : 0}v${vibrate ? 1 : 0}';
    return NotificationDetails(
      android: AndroidNotificationDetails(
        '${previous ? 'previous_dose_v2' : 'dose_reminder_v2'}_$suffix',
        '${previous ? '前日の服用確認' : '服用リマインダー'}（音${sound ? 'ON' : 'OFF'}・バイブ${vibrate ? 'ON' : 'OFF'}）',
        channelDescription:
            '通知音${sound ? 'ON' : 'OFF'}・バイブ${vibrate ? 'ON' : 'OFF'}',
        importance: Importance.high,
        priority: Priority.high,
        playSound: sound,
        enableVibration: vibrate,
        onlyAlertOnce: !preview,
        autoCancel: previous,
        ongoing: !previous,
        actions: previous
            ? const [
                AndroidNotificationAction(
                  'previous_taken',
                  '飲んだ',
                  showsUserInterface: false,
                  cancelNotification: false,
                ),
                AndroidNotificationAction(
                  'previous_missed',
                  '飲み忘れた',
                  showsUserInterface: false,
                  cancelNotification: false,
                ),
              ]
            : const [
                AndroidNotificationAction(
                  'reminder_confirm',
                  '確認',
                  showsUserInterface: false,
                  cancelNotification: false,
                ),
              ],
      ),
      iOS: DarwinNotificationDetails(
        presentSound: sound,
        categoryIdentifier: previous ? 'previous_dose' : 'dose_reminder',
      ),
    );
  }

  Future<void> acknowledgeReminder(String payload) =>
      plugin.cancel(id: notificationId(payload));

  Future<void> sync(AppData data, DateTime now, {required bool demo}) async {
    if (!ready) return;
    final previewIds = {
      notificationId('preview:reminder'),
      notificationId('preview:check'),
    };
    // Replace future schedules, retaining explicit previews until answered.
    for (final pending in await plugin.pendingNotificationRequests()) {
      await plugin.cancel(id: pending.id);
    }
    if (demo) {
      for (final active in await plugin.getActiveNotifications()) {
        if (active.id != null && !previewIds.contains(active.id)) {
          await plugin.cancel(id: active.id!);
        }
      }
      status = '検証モード：定期通知は停止中';
      return;
    }
    final acknowledgedIds = data.reminderAcknowledgements
        .map(notificationId)
        .toSet();
    final engine = MedicationEngine(data);
    final earliest = data.medicines.isEmpty
        ? day(now)
        : data.medicines
              .map((m) => m.start)
              .reduce((a, b) => a.isBefore(b) ? a : b);
    final validReminderIds = engine
        .generate(earliest, now)
        .where((d) => d.explicit == null)
        .map((d) => notificationId('reminder:${d.id}'))
        .toSet();
    for (final active in await plugin.getActiveNotifications()) {
      if (previewIds.contains(active.id)) {
        if (active.id != null) await plugin.cancel(id: active.id!);
        continue;
      }
      final channel = active.channelId ?? '';
      final remove = channel.startsWith('dose_reminder_v2')
          ? !data.remindersEnabled ||
                acknowledgedIds.contains(active.id) ||
                !validReminderIds.contains(active.id)
          : channel.startsWith('previous_dose_v2')
          ? !data.nextDay
          : [
              'medication_v1',
              'previous_dose_v1',
              'diagnostic_v1',
            ].contains(channel);
      if (remove && active.id != null) {
        await plugin.cancel(id: active.id!);
      } else if (active.id != null &&
          active.payload != null &&
          (active.payload!.startsWith('reminder:') ||
              active.payload!.startsWith('check:'))) {
        // Refresh pre-update action PendingIntents while keeping the notification visible.
        await plugin.show(
          id: active.id!,
          title: active.title,
          body: active.body,
          payload: active.payload,
          notificationDetails: details(
            data,
            previous: active.payload!.startsWith('check:'),
          ),
        );
      }
    }
    final selected = requests(data, now);
    logDiagnostic('SYNC count=${selected.length}');
    for (final item in selected) {
      await plugin.zonedSchedule(
        id: notificationId(item.payload),
        title: item.title,
        body: item.body,
        scheduledDate: tz.TZDateTime.from(item.at, tz.local),
        payload: item.payload,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        notificationDetails: details(
          data,
          previous: item.payload.startsWith('check:'),
        ),
      );
    }
    status = '通知設定を反映しました。$permissionStatus';
  }
}
