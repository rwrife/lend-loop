import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/local_notification_adapter.dart';
import 'package:lend_loop/platform/notification_adapter.dart';
import 'package:timezone/timezone.dart' as time_zone;

final class _ScheduleCall {
  const _ScheduleCall({
    required this.id,
    required this.title,
    required this.body,
    required this.date,
    required this.details,
    required this.mode,
    required this.payload,
  });
  final int id;
  final String? title;
  final String? body;
  final time_zone.TZDateTime date;
  final NotificationDetails details;
  final AndroidScheduleMode mode;
  final String? payload;
}

final class _Plugin implements LocalNotificationsPluginApi {
  int initializeCalls = 0;
  bool? initializeResult = true;
  InitializationSettings? settings;
  DidReceiveNotificationResponseCallback? responseCallback;
  bool? androidEnabled;
  bool? androidRequest;
  bool? iosEnabled;
  bool? iosRequest;
  ({bool alert, bool badge, bool sound})? iosRequestArguments;
  NotificationAppLaunchDetails? launchDetails;
  final Map<int, _ScheduleCall> scheduled = <int, _ScheduleCall>{};
  final List<int> cancelled = <int>[];
  List<PendingNotificationRequest> pending = <PendingNotificationRequest>[];

  @override
  Future<bool?> initialize(
    InitializationSettings settings,
    DidReceiveNotificationResponseCallback onResponse,
  ) async {
    initializeCalls += 1;
    this.settings = settings;
    responseCallback = onResponse;
    return initializeResult;
  }

  @override
  Future<bool?> androidNotificationsEnabled() async => androidEnabled;
  @override
  Future<bool?> requestAndroidPermission() async => androidRequest;
  @override
  Future<bool?> iosNotificationsEnabled() async => iosEnabled;
  @override
  Future<bool?> requestIosPermission({
    required bool alert,
    required bool badge,
    required bool sound,
  }) async {
    iosRequestArguments = (alert: alert, badge: badge, sound: sound);
    return iosRequest;
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async => launchDetails;

  @override
  Future<void> zonedSchedule(
    int id,
    String? title,
    String? body,
    time_zone.TZDateTime scheduledDate,
    NotificationDetails details, {
    required AndroidScheduleMode androidScheduleMode,
    String? payload,
  }) async {
    scheduled[id] = _ScheduleCall(
      id: id,
      title: title,
      body: body,
      date: scheduledDate,
      details: details,
      mode: androidScheduleMode,
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<List<PendingNotificationRequest>>
  pendingNotificationRequests() async => pending;
}

NotificationResponse _response(String? payload) => NotificationResponse(
  notificationResponseType: NotificationResponseType.selectedNotification,
  payload: payload,
);

void main() {
  late _Plugin plugin;
  late LocalNotificationAdapter adapter;

  setUp(() {
    plugin = _Plugin();
    adapter = LocalNotificationAdapter(plugin: plugin);
  });

  test(
    'initialization configures both platforms without eager permission',
    () async {
      await adapter.initialize();
      await adapter.initialize();

      expect(plugin.initializeCalls, 1);
      expect(plugin.settings!.android!.defaultIcon, '@mipmap/ic_launcher');
      expect(plugin.settings!.iOS!.requestAlertPermission, isFalse);
      expect(plugin.settings!.iOS!.requestBadgePermission, isFalse);
      expect(plugin.settings!.iOS!.requestSoundPermission, isFalse);
      expect(plugin.iosRequestArguments, isNull);
    },
  );

  test('a plugin-declared initialization failure remains retryable', () async {
    plugin.initializeResult = false;

    await expectLater(adapter.initialize(), throwsStateError);
    plugin.initializeResult = true;
    await adapter.initialize();

    expect(plugin.initializeCalls, 2);
  });

  test('maps and requests Android permission', () async {
    plugin.androidEnabled = false;
    plugin.androidRequest = true;

    expect(await adapter.permissionStatus(), NotificationPermission.denied);
    expect(await adapter.requestPermission(), NotificationPermission.granted);
    expect(plugin.iosRequestArguments, isNull);
  });

  test('maps and requests iOS permission with intended capabilities', () async {
    plugin.iosEnabled = false;
    plugin.iosRequest = false;

    expect(
      await adapter.permissionStatus(),
      NotificationPermission.notDetermined,
    );
    expect(await adapter.requestPermission(), NotificationPermission.denied);
    expect(plugin.iosRequestArguments, (
      alert: true,
      badge: false,
      sound: true,
    ));
  });

  test('schedules UTC fields and replaces the same platform ID', () async {
    final ScheduledNotification first = ScheduledNotification(
      id: 42,
      exchangeId: ExchangeId('exchange-1'),
      title: 'Reminder',
      body: 'First body',
      scheduledAt: DateTime.parse('2026-09-01T14:30:00-04:00'),
    );
    await adapter.schedule(first);
    await adapter.schedule(
      ScheduledNotification(
        id: 42,
        exchangeId: first.exchangeId,
        title: first.title,
        body: 'Replacement body',
        scheduledAt: DateTime.utc(2026, 9, 3, 9),
      ),
    );

    expect(plugin.scheduled, hasLength(1));
    final _ScheduleCall call = plugin.scheduled[42]!;
    expect(call.body, 'Replacement body');
    expect(call.date.location, time_zone.UTC);
    expect(call.date.toUtc(), DateTime.utc(2026, 9, 3, 9));
    expect(call.payload, 'exchange-1');
    expect(call.mode, AndroidScheduleMode.inexactAllowWhileIdle);
    expect(call.details.android!.channelId, 'due_reminders');
    expect(call.details.android!.importance, Importance.high);
    expect(call.details.iOS, isNotNull);
  });

  test('DST repeated local hour remains two distinct UTC instants', () async {
    final DateTime first = DateTime.parse('2026-11-01T01:30:00-04:00');
    final DateTime second = DateTime.parse('2026-11-01T01:30:00-05:00');

    await adapter.schedule(
      ScheduledNotification(
        id: 1,
        exchangeId: ExchangeId('before-fallback'),
        title: 'Before fallback',
        body: 'First local 1:30',
        scheduledAt: first,
      ),
    );
    await adapter.schedule(
      ScheduledNotification(
        id: 2,
        exchangeId: ExchangeId('after-fallback'),
        title: 'After fallback',
        body: 'Second local 1:30',
        scheduledAt: second,
      ),
    );

    expect(plugin.scheduled[1]!.date.toUtc(), DateTime.utc(2026, 11, 1, 5, 30));
    expect(plugin.scheduled[2]!.date.toUtc(), DateTime.utc(2026, 11, 1, 6, 30));
  });

  test('cancels and maps pending platform IDs', () async {
    plugin.pending = const <PendingNotificationRequest>[
      PendingNotificationRequest(2, 'two', null, null),
      PendingNotificationRequest(7, 'seven', null, null),
    ];

    expect(await adapter.pendingIds(), <int>{2, 7});
    await adapter.cancel(7);
    expect(plugin.cancelled, <int>[7]);
  });

  test('maps foreground response taps and ignores empty payloads', () async {
    await adapter.initialize();
    final Future<ExchangeId> tap = adapter.taps.first;
    plugin.responseCallback!(_response(' exchange-9 '));

    expect(await tap, ExchangeId('exchange-9'));
    plugin.responseCallback!(_response('  '));
  });

  test('returns only a valid notification launch payload', () async {
    plugin.launchDetails = NotificationAppLaunchDetails(
      true,
      notificationResponse: _response(' cold-start '),
    );
    expect(await adapter.initialTap(), ExchangeId('cold-start'));

    plugin.launchDetails = NotificationAppLaunchDetails(
      false,
      notificationResponse: _response('ignored'),
    );
    expect(await adapter.initialTap(), isNull);
  });
}
