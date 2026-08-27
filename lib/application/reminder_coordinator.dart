import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/notification_adapter.dart';

enum ReminderEnableResult { enabled, savedDeliveryPending, denied }

enum ReminderUpdateResult { updated, savedDeliveryPending, notEnabled }

final class ReminderCoordinator {
  ReminderCoordinator({
    required this.notifications,
    required this.reminders,
    required this.clock,
    this.platformIdFor = _stablePlatformId,
  });

  final NotificationAdapter notifications;
  final ReminderRepository reminders;
  final Clock clock;
  final int Function(ExchangeId id) platformIdFor;
  Future<void> _enableTail = Future<void>.value();

  Future<ReminderEnableResult> enable({
    required ExchangeId exchangeId,
    required String itemName,
    required String personName,
    required DateTime scheduledAt,
  }) => _serializeEnable(() async {
    if ((await reminders.reminders()).isEmpty) {
      final NotificationPermission permission = await notifications
          .requestPermission();
      if (permission != NotificationPermission.granted) {
        return ReminderEnableResult.denied;
      }
    } else if (await notifications.permissionStatus() !=
        NotificationPermission.granted) {
      return ReminderEnableResult.denied;
    }
    final Reminder? existing = await reminders.getReminder(exchangeId);
    final int platformId =
        existing?.platformSchedulingId ?? await _allocatePlatformId(exchangeId);
    final Reminder reminder = Reminder(
      exchangeId: exchangeId,
      requestedAt: clock.now(),
      scheduledAt: scheduledAt,
      platformSchedulingId: platformId,
      title: 'Lend Loop reminder',
      body: '$itemName with $personName is due',
      deliveryState: ReminderDeliveryState.pending,
    );
    await reminders.saveReminder(reminder);
    try {
      await notifications.schedule(_scheduled(reminder));
      await reminders.saveReminder(
        reminder.withDeliveryState(ReminderDeliveryState.scheduled),
      );
      return ReminderEnableResult.enabled;
    } on Object {
      // Desired local state is authoritative; reconciliation can retry.
      return ReminderEnableResult.savedDeliveryPending;
    }
  });

  Future<ReminderUpdateResult> update({
    required ExchangeId exchangeId,
    required String itemName,
    required String personName,
    required DateTime scheduledAt,
  }) async {
    final Reminder? existing = await reminders.getReminder(exchangeId);
    if (existing == null) return ReminderUpdateResult.notEnabled;
    final Reminder reminder = Reminder(
      exchangeId: exchangeId,
      requestedAt: clock.now(),
      scheduledAt: scheduledAt,
      platformSchedulingId: existing.platformSchedulingId,
      title: existing.title,
      body: '$itemName with $personName is due',
      deliveryState: ReminderDeliveryState.pending,
    );
    await reminders.saveReminder(reminder);
    try {
      await notifications.schedule(_scheduled(reminder));
      await reminders.saveReminder(
        reminder.withDeliveryState(ReminderDeliveryState.scheduled),
      );
      return ReminderUpdateResult.updated;
    } on Object {
      // Desired local state is authoritative; reconciliation can retry.
      return ReminderUpdateResult.savedDeliveryPending;
    }
  }

  Future<void> cancel(ExchangeId exchangeId) async {
    final Reminder? reminder = await reminders.getReminder(exchangeId);
    if (reminder == null) return;
    await reminders.deleteReminder(exchangeId);
    try {
      await notifications.cancel(reminder.platformSchedulingId);
    } on Object {
      // Persisted state is authoritative. Reconciliation will retry removal.
    }
  }

  Future<void> reconcile() async {
    final List<Reminder> stored = await reminders.reminders();
    for (final Reminder reminder in stored) {
      if (!await reminders.reminderEligible(reminder.exchangeId) ||
          !reminder.scheduledAt.isAfter(clock.now())) {
        await reminders.deleteReminder(reminder.exchangeId);
      }
    }
    final List<Reminder> eligible = await reminders.reminders();
    final Set<int> wanted = eligible
        .map((Reminder value) => value.platformSchedulingId)
        .toSet();
    final Set<int> pending = await notifications.pendingIds();
    for (final int stale in pending.difference(wanted)) {
      await notifications.cancel(stale);
    }
    for (final Reminder reminder in eligible) {
      // Replacing every eligible future request is idempotent on both
      // supported adapters and also repairs stale same-ID payload or dates.
      await notifications.schedule(_scheduled(reminder));
      await reminders.saveReminder(
        reminder.withDeliveryState(ReminderDeliveryState.scheduled),
      );
    }
  }

  Future<Reminder?> reminder(ExchangeId exchangeId) =>
      reminders.getReminder(exchangeId);

  Future<T> _serializeEnable<T>(Future<T> Function() operation) {
    final Future<void> previous = _enableTail;
    final Future<T> result = previous.then((_) => operation());
    _enableTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  ScheduledNotification _scheduled(Reminder reminder) => ScheduledNotification(
    id: reminder.platformSchedulingId,
    exchangeId: reminder.exchangeId,
    title: reminder.title,
    body: reminder.body,
    scheduledAt: reminder.scheduledAt,
  );

  Future<int> _allocatePlatformId(ExchangeId exchangeId) async {
    final Set<int> used = (await reminders.reminders())
        .map((Reminder value) => value.platformSchedulingId)
        .toSet();
    int candidate = platformIdFor(exchangeId) & 0x7fffffff;
    if (candidate == 0) candidate = 1;
    final int first = candidate;
    while (used.contains(candidate)) {
      candidate = candidate == 0x7fffffff ? 1 : candidate + 1;
      if (candidate == first) {
        throw StateError('No platform notification IDs are available.');
      }
    }
    return candidate;
  }
}

int _stablePlatformId(ExchangeId id) {
  int hash = 0x811c9dc5;
  for (final int unit in id.value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
  }
  return hash == 0 ? 1 : hash;
}
