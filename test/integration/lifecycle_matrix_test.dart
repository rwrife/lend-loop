import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/application/reminder_coordinator.dart';
import 'package:lend_loop/data/backup_service.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/notification_adapter.dart';

final class _Clock implements Clock {
  _Clock(this.value);
  DateTime value;
  @override
  DateTime now() => value;
}

final class _Ids implements IdGenerator {
  int next = 0;
  @override
  String nextId() => 'integration-${next++}';
}

final class _Notifications implements NotificationAdapter {
  final Map<int, ScheduledNotification> pending =
      <int, ScheduledNotification>{};
  final List<int> cancelled = <int>[];
  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    pending.remove(id);
  }

  @override
  Future<Set<int>> pendingIds() async => pending.keys.toSet();
  @override
  Future<NotificationPermission> permissionStatus() async =>
      NotificationPermission.granted;
  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.granted;
  @override
  Future<void> schedule(ScheduledNotification notification) async {
    pending[notification.id] = notification;
  }
}

void main() {
  test(
    'record -> reminder adapter -> return -> export -> clean restore',
    () async {
      final Directory sourceRoot = await Directory.systemTemp.createTemp(
        'lend-loop-integration-source-',
      );
      final Directory restoredRoot = await Directory.systemTemp.createTemp(
        'lend-loop-integration-restored-',
      );
      final LendLoopDatabase source = LendLoopDatabase(NativeDatabase.memory());
      addTearDown(source.close);
      addTearDown(() async {
        await sourceRoot.delete(recursive: true);
        await restoredRoot.delete(recursive: true);
      });
      final _Clock clock = _Clock(DateTime.utc(2026, 10, 31, 23, 30));
      final DriftExchangeRepository sourceRepository = DriftExchangeRepository(
        source,
      );
      final ExchangeWorkflow sourceWorkflow = ExchangeWorkflow(
        repository: sourceRepository,
        clock: clock,
        ids: _Ids(),
      );
      final _Notifications notifications = _Notifications();
      final ReminderCoordinator reminders = ReminderCoordinator(
        notifications: notifications,
        reminders: sourceRepository,
        clock: clock,
      );

      final ExchangeRecord recorded = await sourceWorkflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'DST travel adapter',
          personName: 'Sam',
          handedOffAt: clock.now(),
          dueAt: DateTime.utc(2026, 11, 1, 7, 30),
          notes: 'Local-only lifecycle evidence',
        ),
      );
      expect(
        await reminders.enable(
          exchangeId: recorded.exchange.id,
          itemName: recorded.item.name,
          personName: recorded.person.displayName,
          scheduledAt: recorded.exchange.dueAt!,
        ),
        ReminderEnableResult.enabled,
      );
      expect(notifications.pending, hasLength(1));

      clock.value = DateTime.utc(2026, 11, 1, 8);
      final ExchangeRecord returned = await sourceWorkflow.markReturned(
        recorded.exchange.id,
      );
      expect(returned.exchange.status, ExchangeStatus.returned);
      expect(await sourceRepository.getReminder(recorded.exchange.id), isNull);
      await reminders.reconcile();
      expect(notifications.pending, isEmpty);
      expect(notifications.cancelled, hasLength(1));

      final BackupService exporter = BackupService(
        database: source,
        rootDirectory: () async => sourceRoot,
        clock: clock,
      );
      final BackupArtifact csv = await exporter.createCsvExport();
      expect(String.fromCharCodes(csv.bytes), contains('DST travel adapter'));
      expect(String.fromCharCodes(csv.bytes), contains(',returned,'));
      final BackupArtifact backup = await exporter.createBackup(
        includeAttachments: false,
      );
      await source.close();

      final LendLoopDatabase restored = LendLoopDatabase(
        NativeDatabase.memory(),
      );
      addTearDown(restored.close);

      final BackupService importer = BackupService(
        database: restored,
        rootDirectory: () async => restoredRoot,
        clock: clock,
      );
      final RestorePreview preview = await importer.previewRestore(
        backup.bytes,
      );
      expect((preview.adds, preview.updates, preview.conflicts), (1, 0, 0));
      final RestoreResult result = await importer.applyRestore(preview);
      expect((result.added, result.updated, result.conflictsKept), (1, 0, 0));

      final ExchangeWorkflow restoredWorkflow = ExchangeWorkflow(
        repository: DriftExchangeRepository(restored),
        clock: clock,
        ids: _Ids(),
      );
      final ExchangeRecord clean = await restoredWorkflow.details(
        recorded.exchange.id,
      );
      expect(clean.exchange.status, ExchangeStatus.returned);
      expect(
        clean.events.map((ExchangeEvent event) => event.type),
        <ExchangeEventType>[
          ExchangeEventType.created,
          ExchangeEventType.returned,
        ],
      );
      expect(clean.item.description, 'Local-only lifecycle evidence');
    },
  );
}
