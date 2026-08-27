import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/notification_adapter.dart';
import 'package:timezone/data/latest.dart' as time_zone_data;
import 'package:timezone/timezone.dart' as time_zone;

final class LocalNotificationAdapter
    implements NotificationAdapter, NotificationTapSource {
  LocalNotificationAdapter({LocalNotificationsPluginApi? plugin})
    : _plugin =
          plugin ??
          FlutterLocalNotificationsPluginApi(FlutterLocalNotificationsPlugin());

  final LocalNotificationsPluginApi _plugin;
  final StreamController<ExchangeId> _taps =
      StreamController<ExchangeId>.broadcast();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    time_zone_data.initializeTimeZones();
    final bool? initialized = await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      _onResponse,
    );
    if (initialized == false) {
      throw StateError('Local notification initialization was rejected.');
    }
    _initialized = true;
  }

  void _onResponse(NotificationResponse response) {
    final String value = response.payload?.trim() ?? '';
    if (value.isNotEmpty) _taps.add(ExchangeId(value));
  }

  @override
  Stream<ExchangeId> get taps => _taps.stream;

  @override
  Future<ExchangeId?> initialTap() async {
    await initialize();
    final NotificationAppLaunchDetails? details = await _plugin
        .getNotificationAppLaunchDetails();
    final String value = details?.notificationResponse?.payload?.trim() ?? '';
    return details?.didNotificationLaunchApp == true && value.isNotEmpty
        ? ExchangeId(value)
        : null;
  }

  @override
  Future<NotificationPermission> permissionStatus() async {
    await initialize();
    final bool? android = await _plugin.androidNotificationsEnabled();
    if (android != null) {
      return android
          ? NotificationPermission.granted
          : NotificationPermission.denied;
    }
    final bool? ios = await _plugin.iosNotificationsEnabled();
    return ios == true
        ? NotificationPermission.granted
        : NotificationPermission.notDetermined;
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    await initialize();
    final bool? android = await _plugin.requestAndroidPermission();
    if (android != null) {
      return android
          ? NotificationPermission.granted
          : NotificationPermission.denied;
    }
    return await _plugin.requestIosPermission(
              alert: true,
              badge: false,
              sound: true,
            ) ==
            true
        ? NotificationPermission.granted
        : NotificationPermission.denied;
  }

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    await initialize();
    await _plugin.zonedSchedule(
      notification.id,
      notification.title,
      notification.body,
      time_zone.TZDateTime.from(
        notification.scheduledAt.toUtc(),
        time_zone.UTC,
      ),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'due_reminders',
          'Due reminders',
          channelDescription: 'Optional reminders for item due dates',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: notification.exchangeId.value,
    );
  }

  @override
  Future<void> cancel(int id) async {
    await initialize();
    await _plugin.cancel(id);
  }

  @override
  Future<Set<int>> pendingIds() async {
    await initialize();
    return (await _plugin.pendingNotificationRequests())
        .map((PendingNotificationRequest value) => value.id)
        .toSet();
  }
}

abstract interface class LocalNotificationsPluginApi {
  Future<bool?> initialize(
    InitializationSettings settings,
    DidReceiveNotificationResponseCallback onResponse,
  );
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails();
  Future<bool?> androidNotificationsEnabled();
  Future<bool?> requestAndroidPermission();
  Future<bool?> iosNotificationsEnabled();
  Future<bool?> requestIosPermission({
    required bool alert,
    required bool badge,
    required bool sound,
  });
  Future<void> zonedSchedule(
    int id,
    String? title,
    String? body,
    time_zone.TZDateTime scheduledDate,
    NotificationDetails details, {
    required AndroidScheduleMode androidScheduleMode,
    String? payload,
  });
  Future<void> cancel(int id);
  Future<List<PendingNotificationRequest>> pendingNotificationRequests();
}

final class FlutterLocalNotificationsPluginApi
    implements LocalNotificationsPluginApi {
  FlutterLocalNotificationsPluginApi(this.plugin);

  final FlutterLocalNotificationsPlugin plugin;

  @override
  Future<bool?> initialize(
    InitializationSettings settings,
    DidReceiveNotificationResponseCallback onResponse,
  ) =>
      plugin.initialize(settings, onDidReceiveNotificationResponse: onResponse);

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() =>
      plugin.getNotificationAppLaunchDetails();

  @override
  Future<bool?> androidNotificationsEnabled() async {
    final AndroidFlutterLocalNotificationsPlugin? android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return android?.areNotificationsEnabled();
  }

  @override
  Future<bool?> requestAndroidPermission() =>
      plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      Future<bool?>.value();

  IOSFlutterLocalNotificationsPlugin? get _ios => plugin
      .resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin
      >();

  @override
  Future<bool?> iosNotificationsEnabled() async =>
      (await _ios?.checkPermissions())?.isEnabled;

  @override
  Future<bool?> requestIosPermission({
    required bool alert,
    required bool badge,
    required bool sound,
  }) =>
      _ios?.requestPermissions(alert: alert, badge: badge, sound: sound) ??
      Future<bool?>.value();

  @override
  Future<void> zonedSchedule(
    int id,
    String? title,
    String? body,
    time_zone.TZDateTime scheduledDate,
    NotificationDetails details, {
    required AndroidScheduleMode androidScheduleMode,
    String? payload,
  }) => plugin.zonedSchedule(
    id,
    title,
    body,
    scheduledDate,
    details,
    androidScheduleMode: androidScheduleMode,
    payload: payload,
  );

  @override
  Future<void> cancel(int id) => plugin.cancel(id);

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() =>
      plugin.pendingNotificationRequests();
}
