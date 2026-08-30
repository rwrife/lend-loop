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

  test('editing an open due date persists an edited event', () async {
    final ExchangeRecord open = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Drill',
        personName: 'Sam',
        handedOffAt: DateTime.utc(2026, 8, 20),
        dueAt: DateTime.utc(2026, 8, 27),
      ),
    );

    final ExchangeRecord edited = await workflow.editDueDate(
      open.exchange.id,
      DateTime.utc(2026, 8, 30),
    );

    expect(edited.exchange.dueAt, DateTime.utc(2026, 8, 30));
    expect(edited.events.last.type, ExchangeEventType.edited);
  });

  test(
    'due-date edit atomically aligns an existing desired reminder',
    () async {
      final ExchangeRecord open = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'Drill',
          personName: 'Sam',
          handedOffAt: DateTime.utc(2026, 8, 20),
          dueAt: DateTime.utc(2026, 8, 27),
        ),
      );
      final DriftExchangeRepository repository = DriftExchangeRepository(
        database,
      );
      await repository.saveReminder(
        Reminder(
          exchangeId: open.exchange.id,
          requestedAt: clock.now(),
          scheduledAt: DateTime.utc(2026, 8, 27),
          platformSchedulingId: 72,
          title: 'Reminder',
          body: 'Drill with Sam is due',
        ),
      );

      await workflow.editDueDate(open.exchange.id, DateTime.utc(2026, 8, 30));

      expect(
        (await repository.getReminder(open.exchange.id))!.scheduledAt
            .isAtSameMomentAs(DateTime.utc(2026, 8, 30)),
        isTrue,
      );
      expect(
        (await repository.getReminder(open.exchange.id))!.deliveryState,
        ReminderDeliveryState.pending,
      );
    },
  );

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

  test(
    'search combines text, person, direction, status, and date filters',
    () async {
      final ExchangeRecord drill = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'Cordless drill',
          personName: 'Sam Rivera',
          handedOffAt: DateTime.utc(2026, 8, 20),
        ),
      );
      await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.borrowed,
          itemName: 'Drill bits',
          personName: 'Alex',
          handedOffAt: DateTime.utc(2026, 8, 21),
        ),
      );
      await workflow.markReturned(drill.exchange.id);

      final List<ExchangeRecord> result = await workflow.search(
        ExchangeSearchFilter(
          text: 'drill',
          personId: drill.person.id,
          direction: ExchangeDirection.lent,
          status: ExchangeStatus.returned,
          from: DateTime.utc(2026, 8, 19),
          through: DateTime.utc(2026, 8, 20, 23, 59),
        ),
      );

      expect(
        result.map((ExchangeRecord value) => value.exchange.id),
        <ExchangeId>[drill.exchange.id],
      );
    },
  );

  test(
    'deletion commands remove records but return attachment paths',
    () async {
      final ExchangeRecord saved = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.lent,
          itemName: 'Camera',
          personName: 'Morgan',
          handedOffAt: clock.now(),
        ),
        attachment: const AttachmentDraft(
          relativePath: 'attachments/camera.jpg',
          mediaType: 'image/jpeg',
          byteSize: 12,
          digest: 'digest',
        ),
      );

      expect(
        await workflow.deleteAttachment(saved.attachments.single.id),
        'attachments/camera.jpg',
      );
      expect((await workflow.details(saved.exchange.id)).attachments, isEmpty);
      expect(await workflow.deleteExchange(saved.exchange.id), isEmpty);
      expect(await workflow.openExchanges(), isEmpty);

      final ExchangeRecord another = await workflow.recordHandoff(
        HandoffDraft(
          direction: ExchangeDirection.borrowed,
          itemName: 'Book',
          personName: 'Alex',
          handedOffAt: clock.now(),
        ),
        attachment: const AttachmentDraft(
          relativePath: 'attachments/book.jpg',
          mediaType: 'image/jpeg',
          byteSize: 2,
          digest: 'digest',
        ),
      );
      expect(await workflow.deleteAllLocalData(), <String>[
        another.attachments.single.relativePath,
      ]);
      expect(await workflow.openExchanges(), isEmpty);
    },
  );

  test('search combines person text with handoff date bounds', () async {
    final ExchangeRecord matching = await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Drill',
        personName: 'Sam Rivera',
        handedOffAt: DateTime.utc(2026, 8, 20),
      ),
    );
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Saw',
        personName: 'Sam Rivera',
        handedOffAt: DateTime.utc(2026, 8, 10),
      ),
    );
    await workflow.recordHandoff(
      HandoffDraft(
        direction: ExchangeDirection.lent,
        itemName: 'Book',
        personName: 'Alex',
        handedOffAt: DateTime.utc(2026, 8, 20),
      ),
    );

    final List<ExchangeRecord> result = await workflow.search(
      ExchangeSearchFilter(
        personName: 'sam',
        from: DateTime.utc(2026, 8, 19),
        through: DateTime.utc(2026, 8, 21),
      ),
    );

    expect(
      result.map((ExchangeRecord value) => value.exchange.id),
      <ExchangeId>[matching.exchange.id],
    );
  });
}
