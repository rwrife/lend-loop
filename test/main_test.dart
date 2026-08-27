import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/app/lend_loop_app.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/main.dart' as entrypoint;
import 'package:lend_loop/platform/notification_adapter.dart';

final class _BrokenNotifications
    implements NotificationAdapter, NotificationTapSource {
  Future<void> initialize() async => throw StateError('plugin unavailable');

  @override
  Future<void> cancel(int id) async {}
  @override
  Future<ExchangeId?> initialTap() async => null;
  @override
  Future<Set<int>> pendingIds() async => <int>{};
  @override
  Future<NotificationPermission> permissionStatus() async =>
      NotificationPermission.denied;
  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.denied;
  @override
  Future<void> schedule(ScheduledNotification notification) async {}
  @override
  Stream<ExchangeId> get taps => const Stream<ExchangeId>.empty();
}

final class _RetryableInitializationNotifications
    implements NotificationAdapter, NotificationTapSource {
  int initializeCalls = 0;
  int failuresRemaining;
  int pendingCalls = 0;
  final StreamController<ExchangeId> controller =
      StreamController<ExchangeId>.broadcast();

  _RetryableInitializationNotifications(this.failuresRemaining);

  Future<void> initialize() async {
    initializeCalls += 1;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('initialization failed');
    }
  }

  @override
  Future<void> cancel(int id) async {}
  @override
  Future<ExchangeId?> initialTap() async {
    if (failuresRemaining > 0) {
      throw StateError('initial tap unavailable before initialization');
    }
    return null;
  }

  @override
  Future<Set<int>> pendingIds() async {
    pendingCalls += 1;
    return <int>{};
  }

  @override
  Future<NotificationPermission> permissionStatus() async =>
      NotificationPermission.granted;
  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.granted;
  @override
  Future<void> schedule(ScheduledNotification notification) async {}
  @override
  Stream<ExchangeId> get taps => controller.stream;

  Future<void> close() => controller.close();
}

final class _TransientReconcileNotifications
    implements NotificationAdapter, NotificationTapSource {
  int pendingCalls = 0;

  @override
  Future<void> cancel(int id) async {}
  @override
  Future<ExchangeId?> initialTap() async => null;
  @override
  Future<Set<int>> pendingIds() async {
    pendingCalls += 1;
    if (pendingCalls == 1) throw StateError('transient reconcile failure');
    return <int>{};
  }

  @override
  Future<NotificationPermission> permissionStatus() async =>
      NotificationPermission.granted;
  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.granted;
  @override
  Future<void> schedule(ScheduledNotification notification) async {}
  @override
  Stream<ExchangeId> get taps => const Stream<ExchangeId>.empty();
}

final class _AsyncErrorNotifications
    implements NotificationAdapter, NotificationTapSource {
  bool failInitialTap = true;
  int initialTapCalls = 0;
  ExchangeId? initialAfterFailure;
  int setupCalls = 0;
  final StreamController<ExchangeId> controller =
      StreamController<ExchangeId>.broadcast();

  @override
  Stream<ExchangeId> get taps => controller.stream;
  @override
  Future<ExchangeId?> initialTap() async {
    initialTapCalls += 1;
    if (failInitialTap) throw StateError('initial tap failed');
    return initialAfterFailure;
  }

  @override
  Future<Set<int>> pendingIds() async => <int>{};
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<NotificationPermission> permissionStatus() async =>
      NotificationPermission.granted;
  @override
  Future<NotificationPermission> requestPermission() async =>
      NotificationPermission.granted;
  @override
  Future<void> schedule(ScheduledNotification notification) async {}

  Future<void> initialize() async => setupCalls += 1;
  Future<void> close() => controller.close();
}

void main() {
  testWidgets('initial tap and stream errors degrade and retry recovers', (
    WidgetTester tester,
  ) async {
    final LendLoopDatabase database = LendLoopDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final _AsyncErrorNotifications notifications = _AsyncErrorNotifications();
    addTearDown(notifications.close);
    final LendLoopApp app = await entrypoint.buildRootApp(
      openDatabase: () async => database,
      createNotifications: () => notifications,
      initializeNotifications: (_) => notifications.initialize(),
    ) as LendLoopApp;
    expect(app.retryNotificationSetup, isNotNull);
    final ExchangeRecord record = await app.workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.borrowed,
        itemName: 'Tent',
        personName: 'Alex',
        handedOffAt: DateTime.utc(2026, 8, 26),
      ),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Retry reminder setup'), findsOneWidget);
    expect(find.byKey(const Key('recordHandoffButton')), findsOneWidget);
    notifications.failInitialTap = false;
    notifications.initialAfterFailure = record.exchange.id;
    await tester.tap(find.text('Retry reminder setup'));
    await tester.pumpAndSettle();
    expect(find.text('Retry reminder setup'), findsNothing);
    expect(notifications.initialTapCalls, 2);
    expect(find.text('Exchange details'), findsOneWidget);
    expect(find.text('You borrowed Tent from Alex'), findsOneWidget);

    Navigator.of(tester.element(find.text('Exchange details'))).pop();
    await tester.pumpAndSettle();

    notifications.controller.addError(StateError('tap stream failed'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Retry reminder setup'), findsOneWidget);
    expect(find.byKey(const Key('recordHandoffButton')), findsOneWidget);
  });
  test(
    'notification startup failure still builds the core application',
    () async {
      final LendLoopDatabase database = LendLoopDatabase(
        NativeDatabase.memory(),
      );
      addTearDown(database.close);

      final Widget root = await entrypoint.buildRootApp(
        openDatabase: () async => database,
        createNotifications: _BrokenNotifications.new,
        initializeNotifications: (Object value) =>
            (value as _BrokenNotifications).initialize(),
      );

      expect(root, isA<LendLoopApp>());
      expect((root as LendLoopApp).reminderCoordinator, isNotNull);
      expect(root.notificationTaps, isNotNull);
      expect(
        root.notificationFeatureMessage,
        'Reminder delivery is unavailable until setup succeeds. Your local records still work.',
      );
      expect(root.retryNotificationSetup, isNotNull);
    },
  );

  testWidgets(
    'initialization retry reports repeated failure then reconciles on success',
    (WidgetTester tester) async {
      final LendLoopDatabase database = LendLoopDatabase(
        NativeDatabase.memory(),
      );
      addTearDown(database.close);
      final _RetryableInitializationNotifications notifications =
          _RetryableInitializationNotifications(2);
      addTearDown(notifications.close);

      final LendLoopApp app = await entrypoint.buildRootApp(
        openDatabase: () async => database,
        createNotifications: () => notifications,
        initializeNotifications: (Object value) =>
            (value as _RetryableInitializationNotifications).initialize(),
      ) as LendLoopApp;
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Retry reminder setup'), findsOneWidget);
      await tester.tap(find.text('Retry reminder setup'));
      await tester.pumpAndSettle();
      expect(notifications.initializeCalls, 2);
      expect(notifications.pendingCalls, 0);
      expect(find.textContaining('still needs attention'), findsOneWidget);

      await tester.tap(find.text('Retry reminder setup'));
      await tester.pumpAndSettle();
      expect(notifications.initializeCalls, 3);
      expect(notifications.pendingCalls, 1);
      expect(find.text('Retry reminder setup'), findsNothing);

      notifications.controller.add(ExchangeId('missing-after-retry'));
      await tester.pumpAndSettle();
      expect(
        find.text('That exchange is no longer available.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'constructor failure keeps core flow with honest unavailable text',
    (WidgetTester tester) async {
      final LendLoopDatabase database = LendLoopDatabase(
        NativeDatabase.memory(),
      );
      addTearDown(database.close);

      final LendLoopApp app = await entrypoint.buildRootApp(
        openDatabase: () async => database,
        createNotifications: () => throw StateError('constructor failed'),
      ) as LendLoopApp;

      expect(app.reminderCoordinator, isNull);
      expect(app.notificationTaps, isNull);
      expect(app.retryNotificationSetup, isNull);
      expect(
        app.notificationFeatureMessage,
        'Reminders are unavailable on this device. Your local records still work.',
      );
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(
          'Reminders are unavailable on this device. Your local records still work.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reconcile failure retains reminders and offers an accessible retry',
    (WidgetTester tester) async {
      final LendLoopDatabase database = LendLoopDatabase(
        NativeDatabase.memory(),
      );
      addTearDown(database.close);
      final _TransientReconcileNotifications notifications =
          _TransientReconcileNotifications();

      final Widget root = await entrypoint.buildRootApp(
        openDatabase: () async => database,
        createNotifications: () => notifications,
        initializeNotifications: (_) async {},
      );
      final LendLoopApp app = root as LendLoopApp;
      expect(app.reminderCoordinator, isNotNull);
      expect(app.notificationTaps, same(notifications));

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      expect(find.text('No open exchanges'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Reminder delivery needs attention. Retry reminder setup.',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Retry reminder setup'), findsOneWidget);
      await tester.tap(find.text('Retry reminder setup'));
      await tester.pumpAndSettle();

      expect(notifications.pendingCalls, 2);
      expect(find.text('Retry reminder setup'), findsNothing);
      expect(find.byKey(const Key('recordHandoffButton')), findsOneWidget);
    },
  );
}
