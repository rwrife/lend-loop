import 'package:flutter/widgets.dart';
import 'package:lend_loop/app/lend_loop_app.dart';
import 'package:lend_loop/app/startup_error_app.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/application/runtime_dependencies.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/data/database_factory.dart';
import 'package:lend_loop/platform/image_picker_photo_adapter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final LendLoopDatabase database = await openLendLoopDatabase();
    const SystemClock clock = SystemClock();
    final ExchangeWorkflow workflow = ExchangeWorkflow(
      repository: DriftExchangeRepository(database),
      clock: clock,
      ids: SecureIdGenerator(),
    );
    runApp(
      LendLoopApp(workflow: workflow, photoAdapter: ImagePickerPhotoAdapter()),
    );
  } on Object {
    runApp(const StartupErrorApp());
  }
}
