import 'package:lend_loop/domain/exchange_domain.dart';

enum NotificationPermission { notDetermined, granted, denied }

final class ScheduledNotification {
  const ScheduledNotification({
    required this.id,
    required this.exchangeId,
    required this.title,
    required this.body,
    required this.scheduledAt,
  });

  final int id;
  final ExchangeId exchangeId;
  final String title;
  final String body;
  final DateTime scheduledAt;
}

abstract interface class NotificationAdapter {
  Future<NotificationPermission> permissionStatus();
  Future<NotificationPermission> requestPermission();
  Future<void> schedule(ScheduledNotification notification);
  Future<void> cancel(int id);
  Future<Set<int>> pendingIds();
}

abstract interface class NotificationTapSource {
  Stream<ExchangeId> get taps;
  Future<ExchangeId?> initialTap();
}
