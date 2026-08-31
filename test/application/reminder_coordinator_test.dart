import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/application/reminder_coordinator.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/notification_adapter.dart';

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

final class _Notifications implements NotificationAdapter {
  NotificationPermission permission = NotificationPermission.notDetermined;
  int permissionRequests = 0;
  bool failCancel = false;
  bool failSchedule = false;
  final Map<int, ScheduledNotification> scheduled =
      <int, ScheduledNotification>{};

  @override
  Future<NotificationPermission> permissionStatus() async => permission;

  @override
  Future<NotificationPermission> requestPermission() async {
    permissionRequests += 1;
    return permission;
  }

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    if (failSchedule) throw StateError('OS scheduling failed');
    scheduled[notification.id] = notification;
  }

  @override
  Future<void> cancel(int id) async {
    if (failCancel) throw StateError('OS cancellation failed');
    scheduled.remove(id);
  }

  @override
  Future<Set<int>> pendingIds() async => scheduled.keys.toSet();
}

final class _Reminders implements ReminderRepository {
  final Map<ExchangeId, Reminder> values = <ExchangeId, Reminder>{};
  final Set<ExchangeId> returned = <ExchangeId>{};
  Future<void>? saveGate;

  @override
  Future<void> deleteReminder(ExchangeId id) async => values.remove(id);

  @override
  Future<Reminder?> getReminder(ExchangeId id) async => values[id];

  @override
  Future<List<Reminder>> reminders() async => values.values.toList();

  @override
  Future<bool> reminderEligible(ExchangeId id) async => !returned.contains(id);

  @override
  Future<void> saveReminder(Reminder reminder) async {
    await saveGate;
    values[reminder.exchangeId] = reminder;
  }
}

void main() {
  final DateTime now = DateTime.utc(2026, 8, 26, 12);
  late _Notifications notifications;
  late _Reminders reminders;
  late ReminderCoordinator coordinator;

  setUp(() {
    notifications = _Notifications();
    reminders = _Reminders();
    coordinator = ReminderCoordinator(
      notifications: notifications,
      reminders: reminders,
      clock: _Clock(now),
    );
  });

  test('requests permission only when enabling the first reminder', () async {
    notifications.permission = NotificationPermission.granted;

    final ReminderEnableResult first = await coordinator.enable(
      exchangeId: ExchangeId('exchange-1'),
      itemName: 'Drill',
      personName: 'Sam',
      scheduledAt: now.add(const Duration(days: 1)),
    );
    await coordinator.enable(
      exchangeId: ExchangeId('exchange-2'),
      itemName: 'Book',
      personName: 'Alex',
      scheduledAt: now.add(const Duration(days: 2)),
    );

    expect(first, ReminderEnableResult.enabled);
    expect(notifications.permissionRequests, 1);
    expect(reminders.values, hasLength(2));
  });

  test('forced platform ID collision probes without overwriting', () async {
    notifications.permission = NotificationPermission.granted;
    coordinator = ReminderCoordinator(
      notifications: notifications,
      reminders: reminders,
      clock: _Clock(now),
      platformIdFor: (_) => 41,
    );

    await coordinator.enable(
      exchangeId: ExchangeId('exchange-1'),
      itemName: 'Drill',
      personName: 'Sam',
      scheduledAt: now.add(const Duration(days: 1)),
    );
    await coordinator.enable(
      exchangeId: ExchangeId('exchange-2'),
      itemName: 'Book',
      personName: 'Alex',
      scheduledAt: now.add(const Duration(days: 2)),
    );

    expect(
      reminders.values.values
          .map((Reminder value) => value.platformSchedulingId)
          .toSet(),
      <int>{41, 42},
    );
    expect(notifications.scheduled, hasLength(2));
  });

  test('concurrent forced collisions allocate distinct platform IDs', () async {
    notifications.permission = NotificationPermission.granted;
    coordinator = ReminderCoordinator(
      notifications: notifications,
      reminders: reminders,
      clock: _Clock(now),
      platformIdFor: (_) => 41,
    );

    await Future.wait(<Future<ReminderEnableResult>>[
      coordinator.enable(
        exchangeId: ExchangeId('exchange-1'),
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 1)),
      ),
      coordinator.enable(
        exchangeId: ExchangeId('exchange-2'),
        itemName: 'Book',
        personName: 'Alex',
        scheduledAt: now.add(const Duration(days: 2)),
      ),
    ]);

    expect(
      reminders.values.values
          .map((Reminder value) => value.platformSchedulingId)
          .toSet(),
      <int>{41, 42},
    );
  });

  test('denial stores no reminder and schedules nothing', () async {
    notifications.permission = NotificationPermission.denied;

    final ReminderEnableResult result = await coordinator.enable(
      exchangeId: ExchangeId('exchange-1'),
      itemName: 'Drill',
      personName: 'Sam',
      scheduledAt: now.add(const Duration(days: 1)),
    );

    expect(result, ReminderEnableResult.denied);
    expect(reminders.values, isEmpty);
    expect(notifications.scheduled, isEmpty);
  });

  test(
    'scheduling failure is reported while desired reminder is retained',
    () async {
      notifications.permission = NotificationPermission.granted;
      notifications.failSchedule = true;

      final ReminderEnableResult result = await coordinator.enable(
        exchangeId: ExchangeId('exchange-1'),
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 1)),
      );

      expect(result, ReminderEnableResult.savedDeliveryPending);
      expect(reminders.values, hasLength(1));
      expect(
        reminders.values.values.single.deliveryState,
        ReminderDeliveryState.pending,
      );
      expect(notifications.scheduled, isEmpty);
    },
  );

  test(
    'successful scheduling and reconciliation persist scheduled state',
    () async {
      notifications.permission = NotificationPermission.granted;
      final ExchangeId id = ExchangeId('exchange-state');
      await coordinator.enable(
        exchangeId: id,
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 1)),
      );
      expect(
        reminders.values[id]!.deliveryState,
        ReminderDeliveryState.scheduled,
      );

      reminders.values[id] = Reminder(
        exchangeId: id,
        requestedAt: now,
        scheduledAt: now.add(const Duration(days: 1)),
        platformSchedulingId: reminders.values[id]!.platformSchedulingId,
        title: 'Lend Loop reminder',
        body: 'Drill with Sam is due',
        deliveryState: ReminderDeliveryState.pending,
      );
      await coordinator.reconcile();
      expect(
        reminders.values[id]!.deliveryState,
        ReminderDeliveryState.scheduled,
      );
    },
  );

  test('reconcile repairs stale content and date under the same ID', () async {
    final ExchangeId id = ExchangeId('exchange-1');
    final Reminder desired = Reminder(
      exchangeId: id,
      requestedAt: now,
      scheduledAt: now.add(const Duration(days: 3)),
      platformSchedulingId: 17,
      title: 'Lend Loop reminder',
      body: 'Drill with Sam is due',
    );
    reminders.values[id] = desired;
    notifications.scheduled[17] = ScheduledNotification(
      id: 17,
      exchangeId: id,
      title: 'Old title',
      body: 'Old body',
      scheduledAt: now.add(const Duration(days: 1)),
    );

    await coordinator.reconcile();

    final ScheduledNotification repaired = notifications.scheduled[17]!;
    expect(repaired.title, desired.title);
    expect(repaired.body, desired.body);
    expect(repaired.scheduledAt, desired.scheduledAt);
  });

  test(
    'reconcile removes an expired desired reminder from both states',
    () async {
      final ExchangeId id = ExchangeId('expired');
      reminders.values[id] = Reminder(
        exchangeId: id,
        requestedAt: now.subtract(const Duration(days: 2)),
        scheduledAt: now.subtract(const Duration(days: 1)),
        platformSchedulingId: 18,
        title: 'Lend Loop reminder',
        body: 'Expired item is due',
      );
      notifications.scheduled[18] = ScheduledNotification(
        id: 18,
        exchangeId: id,
        title: 'Lend Loop reminder',
        body: 'Expired item is due',
        scheduledAt: now.subtract(const Duration(days: 1)),
      );

      await coordinator.reconcile();

      expect(reminders.values, isEmpty);
      expect(notifications.scheduled, isEmpty);
    },
  );

  test(
    'update keeps ID, cancel removes it, and reconcile repairs drift',
    () async {
      notifications.permission = NotificationPermission.granted;
      final ExchangeId id = ExchangeId('exchange-1');
      await coordinator.enable(
        exchangeId: id,
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 1)),
      );
      final int platformId = reminders.values[id]!.platformSchedulingId;

      await coordinator.update(
        exchangeId: id,
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 3)),
      );
      expect(reminders.values[id]!.platformSchedulingId, platformId);

      notifications.scheduled.clear();
      await coordinator.reconcile();
      expect(notifications.scheduled.keys, <int>{platformId});

      notifications.scheduled[999] = ScheduledNotification(
        id: 999,
        exchangeId: ExchangeId('missing'),
        title: 'stale',
        body: 'stale',
        scheduledAt: now.add(const Duration(days: 1)),
      );
      await coordinator.reconcile();
      expect(notifications.scheduled.containsKey(999), isFalse);

      await coordinator.cancel(id);
      expect(reminders.values, isEmpty);
      expect(notifications.scheduled, isEmpty);
    },
  );

  test(
    'update persists desired state before best-effort platform scheduling',
    () async {
      final ExchangeId id = ExchangeId('exchange-1');
      reminders.values[id] = Reminder(
        exchangeId: id,
        requestedAt: now,
        scheduledAt: now.add(const Duration(days: 1)),
        platformSchedulingId: 12,
        title: 'Reminder',
        body: 'Old body',
      );
      notifications.failSchedule = true;
      final DateTime changed = now.add(const Duration(days: 4));

      final ReminderUpdateResult result = await coordinator.update(
        exchangeId: id,
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: changed,
      );

      expect(result, ReminderUpdateResult.savedDeliveryPending);
      expect(reminders.values[id]!.scheduledAt, changed);
    },
  );

  test('update explicitly reports updated and not enabled', () async {
    final ExchangeId id = ExchangeId('exchange-1');

    expect(
      await coordinator.update(
        exchangeId: id,
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 2)),
      ),
      ReminderUpdateResult.notEnabled,
    );

    reminders.values[id] = Reminder(
      exchangeId: id,
      requestedAt: now,
      scheduledAt: now.add(const Duration(days: 1)),
      platformSchedulingId: 12,
      title: 'Reminder',
      body: 'Old body',
    );

    expect(
      await coordinator.update(
        exchangeId: id,
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 2)),
      ),
      ReminderUpdateResult.updated,
    );
  });

  test('reconcile deletes and never schedules a returned exchange', () async {
    final ExchangeId id = ExchangeId('returned');
    reminders.values[id] = Reminder(
      exchangeId: id,
      requestedAt: now,
      scheduledAt: now.add(const Duration(days: 1)),
      platformSchedulingId: 45,
      title: 'Reminder',
      body: 'Item is due',
    );
    reminders.returned.add(id);

    await coordinator.reconcile();

    expect(reminders.values, isEmpty);
    expect(notifications.scheduled, isEmpty);
  });

  test(
    'cancel keeps persisted desired state off if the OS call fails',
    () async {
      notifications.permission = NotificationPermission.granted;
      final ExchangeId id = ExchangeId('exchange-1');
      await coordinator.enable(
        exchangeId: id,
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 1)),
      );
      notifications.failCancel = true;

      await coordinator.cancel(id);

      expect(reminders.values, isEmpty);
    },
  );

  test('app relaunch reconciliation repairs lost platform state', () async {
    notifications.permission = NotificationPermission.granted;
    final ExchangeId id = ExchangeId('survives-relaunch');
    await coordinator.enable(
      exchangeId: id,
      itemName: 'Travel adapter',
      personName: 'Sam',
      scheduledAt: now.add(const Duration(days: 2)),
    );
    final int platformId = reminders.values[id]!.platformSchedulingId;
    notifications.scheduled.clear();

    final ReminderCoordinator relaunched = ReminderCoordinator(
      notifications: notifications,
      reminders: reminders,
      clock: _Clock(now),
    );
    await relaunched.reconcile();

    expect(notifications.scheduled.keys, <int>{platformId});
    expect(
      reminders.values[id]!.deliveryState,
      ReminderDeliveryState.scheduled,
    );
  });

  test(
    'revoked permission rejects another enable without losing records',
    () async {
      notifications.permission = NotificationPermission.granted;
      await coordinator.enable(
        exchangeId: ExchangeId('existing'),
        itemName: 'Drill',
        personName: 'Sam',
        scheduledAt: now.add(const Duration(days: 1)),
      );
      notifications.permission = NotificationPermission.denied;

      expect(
        await coordinator.enable(
          exchangeId: ExchangeId('after-revoke'),
          itemName: 'Book',
          personName: 'Alex',
          scheduledAt: now.add(const Duration(days: 2)),
        ),
        ReminderEnableResult.denied,
      );
      expect(reminders.values.keys, <ExchangeId>{ExchangeId('existing')});
    },
  );
}
