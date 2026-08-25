import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/application/exchange_workflow.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';

final class MutableClock implements Clock {
  MutableClock(this.value);

  DateTime value;

  @override
  DateTime now() => value;
}

final class SequenceIds implements IdGenerator {
  int value = 0;

  @override
  String nextId() => 'id-${value++}';
}

void main() {
  late LendLoopDatabase database;
  late MutableClock clock;
  late ExchangeWorkflow workflow;

  setUp(() {
    database = LendLoopDatabase(NativeDatabase.memory());
    clock = MutableClock(DateTime.utc(2026, 8, 25, 12));
    workflow = ExchangeWorkflow(
      repository: DriftExchangeRepository(database),
      clock: clock,
      ids: SequenceIds(),
    );
  });

  tearDown(() => database.close());

  test('records and hydrates a private text-only handoff', () async {
    final ExchangeRecord saved = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Cordless drill',
        personName: 'Sam',
        handedOffAt: DateTime.utc(2026, 8, 24),
        dueAt: DateTime.utc(2026, 8, 27),
        notes: '18V battery included',
      ),
    );

    expect(saved.item.name, 'Cordless drill');
    expect(saved.item.description, '18V battery included');
    expect(saved.person.displayName, 'Sam');
    expect(saved.exchange.direction, ExchangeDirection.lent);
    expect(saved.dueState, DueState.dueSoon);
    expect(saved.attachments, isEmpty);
    expect(
      saved.events.map((ExchangeEvent event) => event.type),
      <ExchangeEventType>[ExchangeEventType.created],
    );

    final List<ExchangeRecord> open = await workflow.openExchanges();
    expect(open.single.exchange.id, saved.exchange.id);
    expect(open.single.item.name, 'Cordless drill');
  });

  test(
    'stores portable attachment metadata without requiring a photo',
    () async {
      final ExchangeRecord saved = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.borrowed,
          itemName: 'Book',
          personName: 'Alex',
          handedOffAt: clock.now(),
        ),
        attachment: const AttachmentDraft(
          relativePath: 'attachments/book.jpg',
          mediaType: 'image/jpeg',
          byteSize: 42,
          digest: 'sha256:test',
        ),
      );

      expect(saved.attachments.single.relativePath, 'attachments/book.jpg');
    },
  );

  test('filters open exchanges by due state', () async {
    for (final (String name, DateTime? dueAt) in <(String, DateTime?)>[
      ('Overdue', clock.value.subtract(const Duration(days: 1))),
      ('Due soon', clock.value.add(const Duration(days: 2))),
      ('Later', clock.value.add(const Duration(days: 8))),
      ('No due date', null),
    ]) {
      await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: name,
          personName: 'Sam',
          handedOffAt: clock.value.subtract(const Duration(days: 2)),
          dueAt: dueAt,
        ),
      );
    }

    expect(
      (await workflow.openExchanges(filter: OpenExchangeFilter.overdue))
          .map((ExchangeRecord record) => record.item.name),
      <String>['Overdue'],
    );
    expect(
      (await workflow.openExchanges(filter: OpenExchangeFilter.dueSoon))
          .map((ExchangeRecord record) => record.item.name),
      <String>['Due soon'],
    );
  });

  test('return and reopen preserve append-only history', () async {
    final ExchangeRecord open = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.borrowed,
        itemName: 'Tent',
        personName: 'Taylor',
        handedOffAt: clock.now(),
      ),
    );

    clock.value = clock.value.add(const Duration(hours: 1));
    final ExchangeRecord returned = await workflow.markReturned(
      open.exchange.id,
    );
    expect(returned.exchange.status, ExchangeStatus.returned);
    expect(returned.dueState, DueState.returned);

    clock.value = clock.value.add(const Duration(minutes: 1));
    final ExchangeRecord reopened = await workflow.reopen(open.exchange.id);
    expect(reopened.exchange.status, ExchangeStatus.open);
    expect(
      reopened.events.map((ExchangeEvent event) => event.type),
      <ExchangeEventType>[
        ExchangeEventType.created,
        ExchangeEventType.returned,
        ExchangeEventType.reopened,
      ],
    );
  });

  test(
    'returned records remain reachable for an explicit later reopen',
    () async {
      final ExchangeRecord open = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'Saw',
          personName: 'Robin',
          handedOffAt: clock.now(),
        ),
      );
      await workflow.markReturned(open.exchange.id);

      final List<ExchangeRecord> returned = await workflow.openExchanges(
        filter: OpenExchangeFilter.returned,
      );

      expect(returned.single.exchange.id, open.exchange.id);
      expect(returned.single.exchange.status, ExchangeStatus.returned);
    },
  );

  test('rejects inconsistent handoff and due dates before writing', () async {
    await expectLater(
      workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'Drill',
          personName: 'Sam',
          handedOffAt: DateTime.utc(2026, 8, 25),
          dueAt: DateTime.utc(2026, 8, 24),
        ),
      ),
      throwsA(isA<InvalidValue>()),
    );
    expect(await workflow.openExchanges(), isEmpty);
  });
}
