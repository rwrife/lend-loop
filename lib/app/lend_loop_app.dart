import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/application/reminder_coordinator.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/features/exchanges/exchange_details_screen.dart';
import 'package:lend_loop/features/exchanges/open_exchanges_screen.dart';
import 'package:lend_loop/platform/notification_adapter.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

class LendLoopApp extends StatefulWidget {
  const LendLoopApp({
    required this.workflow,
    required this.photoAdapter,
    this.reminderCoordinator,
    this.notificationTaps,
    this.notificationFeatureMessage,
    this.retryNotificationSetup,
    super.key,
  });

  final ExchangeWorkflow workflow;
  final PhotoAdapter photoAdapter;
  final ReminderCoordinator? reminderCoordinator;
  final NotificationTapSource? notificationTaps;
  final String? notificationFeatureMessage;
  final Future<void> Function()? retryNotificationSetup;

  @override
  State<LendLoopApp> createState() => _LendLoopAppState();
}

class _LendLoopAppState extends State<LendLoopApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<ExchangeId>? _tapSubscription;
  late String? _notificationFeatureMessage;

  @override
  void initState() {
    super.initState();
    _notificationFeatureMessage = widget.notificationFeatureMessage;
    final NotificationTapSource? taps = widget.notificationTaps;
    _tapSubscription = taps?.taps.listen(
      _queueNotificationOpen,
      onError: (Object _, StackTrace _) => _setNotificationDegraded(),
    );
    if (taps != null) unawaited(_loadInitialTap(taps));
  }

  Future<void> _loadInitialTap(NotificationTapSource source) async {
    try {
      final ExchangeId? id = await source.initialTap();
      if (id != null && mounted) _queueNotificationOpen(id);
    } on Object {
      _setNotificationDegraded();
    }
  }

  void _setNotificationDegraded() {
    if (!mounted) return;
    setState(() {
      _notificationFeatureMessage =
          'Reminder delivery needs attention. Retry reminder setup.';
    });
  }

  Future<void> _retryNotificationSetup() async {
    try {
      await widget.retryNotificationSetup?.call();
      final NotificationTapSource? taps = widget.notificationTaps;
      if (taps != null) {
        final ExchangeId? id = await taps.initialTap();
        if (id != null && mounted) _queueNotificationOpen(id);
      }
      if (mounted) setState(() => _notificationFeatureMessage = null);
    } on Object {
      if (mounted) {
        setState(() {
          _notificationFeatureMessage =
              'Reminder delivery still needs attention. Retry reminder setup.';
        });
      }
    }
  }

  void _queueNotificationOpen(ExchangeId id) {
    if (_navigatorKey.currentState != null) {
      unawaited(_openFromNotification(id));
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) unawaited(_openFromNotification(id));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    unawaited(_tapSubscription?.cancel());
    super.dispose();
  }

  Future<void> _openFromNotification(ExchangeId id) async {
    try {
      await widget.workflow.details(id);
      if (!mounted) return;
      final NavigatorState? navigator = _navigatorKey.currentState;
      if (navigator == null) return;
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => ExchangeDetailsScreen(
            exchangeId: id,
            workflow: widget.workflow,
            photoAdapter: widget.photoAdapter,
            reminderCoordinator: widget.reminderCoordinator,
          ),
        ),
      );
    } on NotFound {
      if (!mounted) return;
      final BuildContext? context = _navigatorKey.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That exchange is no longer available.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Lend Loop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF24513F),
          contrastLevel: 0.5,
        ),
        useMaterial3: true,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: _NoMotionTransitions(),
            TargetPlatform.iOS: _NoMotionTransitions(),
          },
        ),
      ),
      home: OpenExchangesScreen(
        workflow: widget.workflow,
        photoAdapter: widget.photoAdapter,
        reminderCoordinator: widget.reminderCoordinator,
        notificationFeatureMessage: _notificationFeatureMessage,
        onRetryNotificationSetup: widget.retryNotificationSetup == null
            ? null
            : _retryNotificationSetup,
      ),
    );
  }
}

final class _NoMotionTransitions extends PageTransitionsBuilder {
  const _NoMotionTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
