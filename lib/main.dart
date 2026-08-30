import 'package:flutter/widgets.dart';
import 'package:lend_loop/app/lend_loop_app.dart';
import 'package:lend_loop/app/startup_error_app.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/application/reminder_coordinator.dart';
import 'package:lend_loop/application/runtime_dependencies.dart';
import 'package:lend_loop/data/backup_service.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/data/database_factory.dart';
import 'package:lend_loop/platform/backup_file_adapter.dart';
import 'package:lend_loop/platform/image_picker_photo_adapter.dart';
import 'package:lend_loop/platform/local_notification_adapter.dart';
import 'package:lend_loop/platform/notification_adapter.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await buildRootApp());
}

Future<Widget> buildRootApp({
  Future<LendLoopDatabase> Function() openDatabase = openLendLoopDatabase,
  Object Function() createNotifications = LocalNotificationAdapter.new,
  Future<void> Function(Object notifications)? initializeNotifications,
}) async {
  late final LendLoopDatabase database;
  try {
    database = await openDatabase();
  } on Object {
    return const StartupErrorApp();
  }

  const SystemClock clock = SystemClock();
  final DriftExchangeRepository repository = DriftExchangeRepository(database);
  final ExchangeWorkflow workflow = ExchangeWorkflow(
    repository: repository,
    clock: clock,
    ids: SecureIdGenerator(),
  );
  ReminderCoordinator? reminders;
  NotificationTapSource? notificationTaps;
  String? notificationFeatureMessage;
  Future<void> Function()? retryNotificationSetup;
  bool notificationInitialized = false;
  late final Object candidate;
  try {
    candidate = createNotifications();
    final NotificationAdapter notifications = candidate as NotificationAdapter;
    final NotificationTapSource taps = candidate as NotificationTapSource;
    final ReminderCoordinator coordinator = ReminderCoordinator(
      notifications: notifications,
      reminders: repository,
      clock: clock,
    );
    reminders = coordinator;
    notificationTaps = taps;

    Future<void> initialize() async {
      if (initializeNotifications != null) {
        await initializeNotifications(candidate);
      } else {
        await (candidate as LocalNotificationAdapter).initialize();
      }
    }

    Future<void> initializeAndReconcile() async {
      await initialize();
      await coordinator.reconcile();
    }

    retryNotificationSetup = initializeAndReconcile;
    await initialize();
    notificationInitialized = true;
    await coordinator.reconcile();
  } on TypeError {
    notificationFeatureMessage =
        'Reminders are unavailable on this device. '
        'Your local records still work.';
    reminders = null;
    notificationTaps = null;
    retryNotificationSetup = null;
  } on Object {
    if (reminders == null || notificationTaps == null) {
      notificationFeatureMessage =
          'Reminders are unavailable on this device. '
          'Your local records still work.';
      retryNotificationSetup = null;
    } else {
      notificationFeatureMessage = notificationInitialized
          ? 'Reminder delivery needs attention. Retry reminder setup.'
          : 'Reminder delivery is unavailable until setup succeeds. '
                'Your local records still work.';
    }
  }
  return LendLoopApp(
    workflow: workflow,
    photoAdapter: ImagePickerPhotoAdapter(),
    reminderCoordinator: reminders,
    notificationTaps: notificationTaps,
    notificationFeatureMessage: notificationFeatureMessage,
    retryNotificationSetup: retryNotificationSetup,
    backups: BackupService(
      database: database,
      rootDirectory: getApplicationSupportDirectory,
      clock: clock,
    ),
    backupFiles: FilePickerBackupFileAdapter(),
  );
}
