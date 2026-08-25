import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/app/lend_loop_app.dart';
import 'package:lend_loop/app/startup_error_app.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:lend_loop/features/exchanges/record_handoff_screen.dart';
import 'package:lend_loop/platform/photo_adapter.dart';

final class FixedClock implements Clock {
  const FixedClock(this.value);

  final DateTime value;

  @override
  DateTime now() => value;
}

final class SequenceIds implements IdGenerator {
  int value = 0;

  @override
  String nextId() => 'widget-${value++}';
}

final class DeniedPhotoAdapter implements PhotoAdapter {
  int requests = 0;

  @override
  Future<PhotoPickResult> pickPhoto() async {
    requests += 1;
    return const PhotoPickResult.denied();
  }

  @override
  Future<void> discard(String relativePath) async {}

  @override
  Future<String?> resolve(String relativePath) async => null;
}

final class FailingExchangeRepository implements ExchangeRepository {
  StateError get _error => StateError('injected storage failure');

  @override
  Future<void> addAttachment(Attachment attachment) async => throw _error;

  @override
  Future<List<Attachment>> attachments(ExchangeId id) async => throw _error;

  @override
  Future<void> create(
    PersonAlias person,
    Item item,
    Exchange exchange,
    ExchangeEvent event, {
    Attachment? attachment,
  }) async => throw _error;

  @override
  Future<List<ExchangeEvent>> events(ExchangeId id) async => throw _error;

  @override
  Future<List<Exchange>> find(ExchangeQuery query) async => throw _error;

  @override
  Future<Exchange?> get(ExchangeId id) async => throw _error;

  @override
  Future<Item?> getItem(ItemId id) async => throw _error;

  @override
  Future<PersonAlias?> getPerson(PersonId id) async => throw _error;

  @override
  Future<void> saveTransition(
    Exchange previous,
    Exchange next,
    ExchangeEvent event,
  ) async => throw _error;
}

void main() {
  late LendLoopDatabase database;
  late DeniedPhotoAdapter photos;
  late ExchangeWorkflow workflow;

  setUp(() {
    database = LendLoopDatabase(NativeDatabase.memory());
    photos = DeniedPhotoAdapter();
    workflow = ExchangeWorkflow(
      repository: DriftExchangeRepository(database),
      clock: FixedClock(DateTime.utc(2026, 8, 25, 12)),
      ids: SequenceIds(),
    );
  });

  tearDown(() => database.close());

  testWidgets(
    'records, returns, and undoes a text-only handoff after photo denial',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        LendLoopApp(workflow: workflow, photoAdapter: photos),
      );
      await tester.pumpAndSettle();

      expect(find.text('No open exchanges'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recordHandoffButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Borrowed'));
      await tester.enterText(
        find.byKey(const Key('itemNameField')),
        'Camping tent',
      );
      await tester.enterText(
        find.byKey(const Key('personNameField')),
        'Taylor',
      );
      await tester.enterText(
        find.byKey(const Key('notesField')),
        'Green two-person tent',
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('addPhotoButton')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('addPhotoButton')));
      await tester.pumpAndSettle();

      expect(photos.requests, 1);
      expect(
        find.text(
          'Photo access was denied. You can still save a text-only record.',
        ),
        findsOneWidget,
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const Key('saveHandoffButton')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.byKey(const Key('saveHandoffButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saveHandoffButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('You borrowed Camping tent from Taylor'),
        findsOneWidget,
      );
      await tester.tap(find.text('You borrowed Camping tent from Taylor'));
      await tester.pumpAndSettle();

      expect(find.text('Green two-person tent'), findsOneWidget);
      expect(find.text('No photo attached'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('markReturnedButton')));
      await tester.tap(find.byKey(const Key('markReturnedButton')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Marked returned'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('Status: Open'), findsOneWidget);
      expect(find.text('Returned'), findsOneWidget);
      expect(find.text('Reopened'), findsOneWidget);
    },
  );

  testWidgets('associates inline required-field errors with the form fields', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      LendLoopApp(workflow: workflow, photoAdapter: photos),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recordHandoffButton')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('saveHandoffButton')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.byKey(const Key('saveHandoffButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveHandoffButton')));
    await tester.pump();

    expect(find.text('Item name is required.'), findsOneWidget);
    expect(find.text('Person alias is required.'), findsOneWidget);
  });

  testWidgets('shows an honest local-storage startup error', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const StartupErrorApp());

    expect(find.text('Local storage could not be opened'), findsOneWidget);
    expect(
      find.text(
        'Lend Loop did not change your records. Close and reopen the app, '
        'or check available device storage.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows a safe missing-photo state for portable metadata', (
    WidgetTester tester,
  ) async {
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Camera',
        personName: 'Morgan',
        handedOffAt: DateTime.utc(2026, 8, 25),
      ),
      attachment: const AttachmentDraft(
        relativePath: 'attachments/missing.jpg',
        mediaType: 'image/jpeg',
        byteSize: 100,
        digest: 'missing',
      ),
    );
    await tester.pumpWidget(
      LendLoopApp(workflow: workflow, photoAdapter: photos),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('You lent Camera to Morgan'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Photo unavailable on this device. The text record is still usable.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows a retryable storage error without claiming data loss', (
    WidgetTester tester,
  ) async {
    final ExchangeWorkflow failedWorkflow = ExchangeWorkflow(
      repository: FailingExchangeRepository(),
      clock: FixedClock(DateTime.utc(2026, 8, 25)),
      ids: SequenceIds(),
    );

    await tester.pumpWidget(
      LendLoopApp(workflow: failedWorkflow, photoAdapter: photos),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not load local records. Your existing data was not changed.',
      ),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('shows an inline inconsistent-date error', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RecordHandoffScreen(
          workflow: workflow,
          photoAdapter: photos,
          initialHandoffAt: DateTime.utc(2026, 8, 25),
          initialDueAt: DateTime.utc(2026, 8, 24),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('itemNameField')), 'Drill');
    await tester.enterText(find.byKey(const Key('personNameField')), 'Sam');
    await tester.scrollUntilVisible(
      find.byKey(const Key('saveHandoffButton')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.byKey(const Key('saveHandoffButton')));
    await tester.tap(find.byKey(const Key('saveHandoffButton')));
    await tester.pump();

    expect(
      find.text('Due date must be on or after the handoff date.'),
      findsOneWidget,
    );
  });

  testWidgets('reports a return storage failure and keeps the record open', (
    WidgetTester tester,
  ) async {
    await database.close();
    database = LendLoopDatabase(
      NativeDatabase.memory(),
      beforeProjectionUpdate: () async =>
          throw StateError('injected return failure'),
    );
    workflow = ExchangeWorkflow(
      repository: DriftExchangeRepository(database),
      clock: FixedClock(DateTime.utc(2026, 8, 25)),
      ids: SequenceIds(),
    );
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Saw',
        personName: 'Robin',
        handedOffAt: DateTime.utc(2026, 8, 25),
      ),
    );
    await tester.pumpWidget(
      LendLoopApp(workflow: workflow, photoAdapter: photos),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('You lent Saw to Robin'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('markReturnedButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Could not mark this exchange returned.'), findsOneWidget);
    expect(find.text('Status: Open'), findsOneWidget);
  });
}
