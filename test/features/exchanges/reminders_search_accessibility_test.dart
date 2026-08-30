import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/app/lend_loop_app.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/application/reminder_coordinator.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/platform/notification_adapter.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

final class _Clock implements Clock {
  const _Clock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

final class _Ids implements IdGenerator {
  int value = 0;
  @override
  String nextId() => 'a11y-${value++}';
}

final class _Photos implements PhotoAdapter {
  @override
  Future<void> discard(String relativePath) async {}
  @override
  Future<bool> deleteWithRollback(
    Iterable<String> relativePaths,
    Future<void> Function() deleteDatabase,
  ) async {
    await deleteDatabase();
    return true;
  }

  @override
  Future<PhotoPickResult> pickPhoto() async =>
      const PhotoPickResult.cancelled();
  @override
  Future<String?> resolve(String relativePath) async => null;
}

final class _Notifications
    implements NotificationAdapter, NotificationTapSource {
  _Notifications(this.permission);
  NotificationPermission permission;
  ExchangeId? initial;
  int requests = 0;
  bool failSchedule = false;
  int scheduleCalls = 0;
  final StreamController<ExchangeId> controller =
      StreamController<ExchangeId>.broadcast();
  @override
  Stream<ExchangeId> get taps => controller.stream;
  @override
  Future<ExchangeId?> initialTap() => SynchronousFuture<ExchangeId?>(initial);
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<Set<int>> pendingIds() async => <int>{};
  @override
  Future<NotificationPermission> permissionStatus() async => permission;
  @override
  Future<NotificationPermission> requestPermission() async {
    requests += 1;
    return permission;
  }

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    scheduleCalls += 1;
    if (failSchedule) throw StateError('adapter scheduling failed');
  }

  Future<void> close() => controller.close();
}

void main() {
  late LendLoopDatabase database;
  late DriftExchangeRepository repository;
  late ExchangeWorkflow workflow;
  late _Notifications notifications;
  final DateTime now = DateTime.utc(2026, 8, 26, 12);

  setUp(() {
    database = LendLoopDatabase(NativeDatabase.memory());
    repository = DriftExchangeRepository(database);
    workflow = ExchangeWorkflow(
      repository: repository,
      clock: _Clock(now),
      ids: _Ids(),
    );
    notifications = _Notifications(NotificationPermission.denied);
  });
  tearDown(() async {
    await notifications.close();
    await database.close();
  });

  Widget app() => LendLoopApp(
    workflow: workflow,
    photoAdapter: _Photos(),
    reminderCoordinator: ReminderCoordinator(
      notifications: notifications,
      reminders: repository,
      clock: _Clock(now),
    ),
    notificationTaps: notifications,
  );

  testWidgets('denied reminder permission leaves details and return usable', (
    WidgetTester tester,
  ) async {
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Drill',
        personName: 'Sam',
        handedOffAt: now,
        dueAt: now.add(const Duration(days: 2)),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('You lent Drill to Sam'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enableReminderButton')));
    await tester.pumpAndSettle();

    expect(notifications.requests, 1);
    expect(
      find.text('Notifications are off. Your exchange is still available.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('markReturnedButton')), findsOneWidget);
  });

  testWidgets(
    'adapter failure persists status and retry reports failure then success',
    (WidgetTester tester) async {
      notifications.permission = NotificationPermission.granted;
      notifications.failSchedule = true;
      final ExchangeRecord record = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'Drill',
          personName: 'Sam',
          handedOffAt: now,
          dueAt: now.add(const Duration(days: 2)),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('You lent Drill to Sam'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('enableReminderButton')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Reminder saved, but delivery is pending.'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Retry reminder delivery'), findsOneWidget);
      expect(await repository.getReminder(record.exchange.id), isNotNull);
      expect(
        (await repository.getReminder(record.exchange.id))!.deliveryState,
        ReminderDeliveryState.pending,
      );
      expect(find.textContaining('Reminder enabled'), findsNothing);

      await tester.tap(find.text('Retry reminder delivery'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Retry failed.'), findsOneWidget);
      expect(notifications.scheduleCalls, 2);

      notifications.failSchedule = false;
      await tester.tap(find.text('Retry reminder delivery'));
      await tester.pumpAndSettle();
      expect(find.text('Reminder delivery restored.'), findsOneWidget);
      expect(find.text('Retry reminder delivery'), findsNothing);
      expect(notifications.scheduleCalls, 3);
      expect(
        (await repository.getReminder(record.exchange.id))!.deliveryState,
        ReminderDeliveryState.scheduled,
      );
    },
  );

  testWidgets('persisted pending delivery survives details reconstruction', (
    WidgetTester tester,
  ) async {
    notifications.permission = NotificationPermission.granted;
    notifications.failSchedule = true;
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Drill',
        personName: 'Sam',
        handedOffAt: now,
        dueAt: now.add(const Duration(days: 2)),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('You lent Drill to Sam'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('enableReminderButton')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('You lent Drill to Sam'));
    await tester.pumpAndSettle();

    expect(find.textContaining('delivery is pending'), findsOneWidget);
    expect(find.bySemanticsLabel('Retry reminder delivery'), findsOneWidget);
  });

  testWidgets(
    'failed due-date reschedule keeps desired date and exposes retry',
    (WidgetTester tester) async {
      notifications.permission = NotificationPermission.granted;
      final ExchangeRecord record = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'Drill',
          personName: 'Sam',
          handedOffAt: now,
          dueAt: DateTime.utc(2026, 8, 28),
        ),
      );
      final ReminderCoordinator coordinator = ReminderCoordinator(
        notifications: notifications,
        reminders: repository,
        clock: _Clock(now),
      );
      await coordinator.enable(
        exchangeId: record.exchange.id,
        itemName: record.item.name,
        personName: record.person.displayName,
        scheduledAt: record.exchange.dueAt!,
      );
      notifications.failSchedule = true;

      await tester.pumpWidget(
        LendLoopApp(
          workflow: workflow,
          photoAdapter: _Photos(),
          reminderCoordinator: coordinator,
          notificationTaps: notifications,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('You lent Drill to Sam'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editDueDateButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('29'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Due date: 2026-08-29'), findsOneWidget);
      expect(
        find.textContaining(
          'Due date saved, but reminder delivery is pending.',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Retry reminder delivery'), findsOneWidget);
      expect(
        (await repository.getReminder(record.exchange.id))!.scheduledAt,
        DateTime(2026, 8, 29),
      );
    },
  );

  testWidgets('search and direction/status filters combine across history', (
    WidgetTester tester,
  ) async {
    final ExchangeRecord returned = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Cordless drill',
        personName: 'Sam',
        handedOffAt: now,
      ),
    );
    await workflow.markReturned(returned.exchange.id);
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.borrowed,
        itemName: 'Book',
        personName: 'Alex',
        handedOffAt: now,
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('searchField')), 'drill');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('statusFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Returned').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('directionFilter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lent').last);
    await tester.pumpAndSettle();

    expect(find.text('You lent Cordless drill to Sam'), findsOneWidget);
    expect(find.text('You borrowed Book from Alex'), findsNothing);
  });

  testWidgets('status is semantic text and core screens survive large text', (
    WidgetTester tester,
  ) async {
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Very long cordless drilling machine',
        personName: 'Sam Rivera',
        handedOffAt: now.subtract(const Duration(days: 2)),
        dueAt: now.subtract(const Duration(days: 1)),
      ),
    );
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: app(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final SemanticsNode node = tester.getSemantics(
      find.byKey(const Key('exchange-a11y-2')),
    );
    expect(node.label, contains('Overdue'));
    expect(node.hint, contains('Open exchange details'));
  });

  testWidgets('record handoff and details survive 2x large text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: app(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recordHandoffButton')));
    await tester.pumpAndSettle();
    expect(find.text('Record handoff'), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Record handoff'))).pop();
    await tester.pumpAndSettle();

    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.borrowed,
        itemName: 'Very long camping tent name',
        personName: 'Alexandra Rivera',
        handedOffAt: now,
        dueAt: now.add(const Duration(days: 2)),
      ),
    );
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Record handoff'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Very long camping tent name'));
    await tester.pumpAndSettle();
    expect(find.text('Exchange details'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('core controls follow logical keyboard traversal order', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final List<Finder> controls = <Finder>[
      find.byKey(const Key('searchField')),
      find.byKey(const Key('personFilter')),
      find.byKey(const Key('directionFilter')),
      find.byKey(const Key('statusFilter')),
    ];
    for (int index = 0; index < controls.length; index += 1) {
      final SemanticsNode node = tester.getSemantics(controls[index]);
      expect((node.sortKey! as OrdinalSortKey).order, index.toDouble());
    }
  });

  testWidgets('core interactive targets are at least 48 logical pixels', (
    WidgetTester tester,
  ) async {
    final ExchangeRecord record = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Drill',
        personName: 'Sam',
        handedOffAt: now,
        dueAt: now.add(const Duration(days: 2)),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    void expectTarget(Finder finder) {
      final Size size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    expectTarget(find.byKey(const Key('recordHandoffButton')));
    expectTarget(find.byKey(Key('exchange-${record.exchange.id.value}')));
    await tester.tap(find.byKey(const Key('recordHandoffButton')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('addPhotoButton')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expectTarget(find.byKey(const Key('addPhotoButton')));
    await tester.scrollUntilVisible(
      find.byKey(const Key('saveHandoffButton')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expectTarget(find.byKey(const Key('saveHandoffButton')));
    Navigator.of(tester.element(find.text('Record handoff'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('You lent Drill to Sam'));
    await tester.pumpAndSettle();
    expectTarget(find.byKey(const Key('editDueDateButton')));
    expectTarget(find.byKey(const Key('enableReminderButton')));
    expectTarget(find.byKey(const Key('markReturnedButton')));
  });

  testWidgets('exchange semantics node exposes tap and opens details', (
    WidgetTester tester,
  ) async {
    final ExchangeRecord record = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Drill',
        personName: 'Sam',
        handedOffAt: now,
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final Finder row = find.byKey(Key('exchange-${record.exchange.id.value}'));
    final SemanticsNode node = tester.getSemantics(row);

    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.performAction(
      find.semantics.byLabel(node.label),
      SemanticsAction.tap,
    );
    await tester.pumpAndSettle();

    expect(find.text('Exchange details'), findsOneWidget);
  });

  testWidgets(
    'notification tap opens existing exchange and missing tap is safe',
    (WidgetTester tester) async {
      final ExchangeRecord record = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.borrowed,
          itemName: 'Tent',
          personName: 'Alex',
          handedOffAt: now,
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      notifications.controller.add(record.exchange.id);
      await tester.pumpAndSettle();
      expect(find.text('Exchange details'), findsOneWidget);

      Navigator.of(tester.element(find.text('Exchange details'))).pop();
      await tester.pumpAndSettle();
      notifications.controller.add(ExchangeId('missing'));
      await tester.pumpAndSettle();
      expect(
        find.text('That exchange is no longer available.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('synchronous cold-start tap waits for navigator readiness', (
    WidgetTester tester,
  ) async {
    final ExchangeRecord record = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.borrowed,
        itemName: 'Tent',
        personName: 'Alex',
        handedOffAt: now,
      ),
    );
    notifications.initial = record.exchange.id;

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Exchange details'), findsOneWidget);
    expect(find.text('You borrowed Tent from Alex'), findsOneWidget);
  });
}
