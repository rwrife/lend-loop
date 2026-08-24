import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

final class FixedClock implements Clock {
  const FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

final class SequenceIds implements IdGenerator {
  SequenceIds([this.value = 0]);
  int value;
  @override
  String nextId() => 'event-${value++}';
}

void main() {
  late LendLoopDatabase database;
  late DriftExchangeRepository repository;
  final DateTime base = DateTime.utc(2026, 8, 1);

  setUp(() {
    database = LendLoopDatabase(NativeDatabase.memory());
    repository = DriftExchangeRepository(database);
  });

  tearDown(() => database.close());

  Future<Exchange> add({
    required String suffix,
    required String personName,
    required String itemName,
    required ExchangeDirection direction,
    DateTime? dueAt,
    ExchangeStatus status = ExchangeStatus.open,
  }) async {
    final PersonAlias person = PersonAlias(
      id: PersonId('person-$suffix'),
      displayName: personName,
      createdAt: base,
      updatedAt: base,
    );
    final Item item = Item(
      id: ItemId('item-$suffix'),
      name: itemName,
      createdAt: base,
      updatedAt: base,
    );
    final ExchangeTransitions transitions = ExchangeTransitions(
      clock: FixedClock(base),
      ids: SequenceIds(int.parse(suffix) * 10),
    );
    final (Exchange open, ExchangeEvent created) = transitions.create(
      id: ExchangeId('exchange-$suffix'),
      itemId: item.id,
      personId: person.id,
      direction: direction,
      handedOffAt: base,
      dueAt: dueAt,
    );
    await repository.create(person, item, open, created);
    if (status == ExchangeStatus.returned) {
      final (Exchange returned, ExchangeEvent event) = transitions.markReturned(
        open,
      );
      await repository.saveTransition(open, returned, event);
      return returned;
    }
    return open;
  }

  test(
    'filters text, person, direction, status, due date and sorts null due last',
    () async {
      final Exchange drill = await add(
        suffix: '1',
        personName: 'Sam Rivera',
        itemName: 'Cordless Drill',
        direction: ExchangeDirection.lent,
        dueAt: base.add(const Duration(days: 4)),
      );
      await add(
        suffix: '2',
        personName: 'Alex',
        itemName: 'Book',
        direction: ExchangeDirection.borrowed,
        dueAt: base.add(const Duration(days: 2)),
      );
      await add(
        suffix: '3',
        personName: 'Taylor',
        itemName: 'Tent',
        direction: ExchangeDirection.lent,
      );
      await add(
        suffix: '4',
        personName: 'Sam',
        itemName: 'Saw',
        direction: ExchangeDirection.lent,
        dueAt: base.add(const Duration(days: 1)),
        status: ExchangeStatus.returned,
      );

      expect(
        (await repository.find(
          const ExchangeQuery(status: ExchangeStatus.open),
        )).map((Exchange value) => value.id.value),
        <String>['exchange-2', 'exchange-1', 'exchange-3'],
      );
      expect(
        (await repository.find(const ExchangeQuery(text: 'drill'))).single.id,
        drill.id,
      );
      expect(
        (await repository.find(ExchangeQuery(personId: drill.personId)))
            .single
            .id,
        drill.id,
      );
      expect(
        (await repository.find(
          const ExchangeQuery(direction: ExchangeDirection.borrowed),
        )).single.id.value,
        'exchange-2',
      );
      expect(
        (await repository.find(
          ExchangeQuery(dueBefore: base.add(const Duration(days: 2))),
        )).map((Exchange value) => value.id.value),
        <String>['exchange-4', 'exchange-2'],
      );
    },
  );

  test(
    'return event and projection roll back together after injected failure',
    () async {
      final Exchange open = await add(
        suffix: '1',
        personName: 'Sam',
        itemName: 'Drill',
        direction: ExchangeDirection.lent,
      );
      final ExchangeTransitions transitions = ExchangeTransitions(
        clock: FixedClock(base.add(const Duration(days: 1))),
        ids: SequenceIds(99),
      );
      final (Exchange returned, ExchangeEvent event) = transitions.markReturned(
        open,
      );
      await database.close();
      database = LendLoopDatabase(
        NativeDatabase.memory(),
        beforeProjectionUpdate: () async =>
            throw StateError('injected failure'),
      );
      repository = DriftExchangeRepository(database);
      // Re-seed the replacement database.
      final PersonAlias person = PersonAlias(
        id: open.personId,
        displayName: 'Sam',
        createdAt: base,
        updatedAt: base,
      );
      final Item item = Item(
        id: open.itemId,
        name: 'Drill',
        createdAt: base,
        updatedAt: base,
      );
      await repository.create(
        person,
        item,
        open,
        ExchangeEvent(
          id: ExchangeEventId('created'),
          exchangeId: open.id,
          type: ExchangeEventType.created,
          occurredAt: base,
        ),
      );

      await expectLater(
        repository.saveTransition(open, returned, event),
        throwsStateError,
      );
      expect((await repository.get(open.id))!.status, ExchangeStatus.open);
      expect(
        (await repository.events(open.id))
            .map((ExchangeEvent value) => value.type),
        <ExchangeEventType>[ExchangeEventType.created],
      );
    },
  );

  test(
    'create reuses a person, an item, or both and updates mutable fields',
    () async {
      final Exchange first = await add(
        suffix: '1',
        personName: 'Original person',
        itemName: 'Original item',
        direction: ExchangeDirection.lent,
      );

      for (final (String suffix, bool samePerson, bool sameItem)
          in <(String, bool, bool)>[
            ('2', true, false),
            ('3', false, true),
            ('4', true, true),
          ]) {
        final DateTime updated = base.add(Duration(days: int.parse(suffix)));
        final PersonAlias person = PersonAlias(
          id: samePerson ? first.personId : PersonId('person-$suffix'),
          displayName: 'Person $suffix',
          privateNote: 'private $suffix',
          createdAt: updated,
          updatedAt: updated,
        );
        final Item item = Item(
          id: sameItem ? first.itemId : ItemId('item-$suffix'),
          name: 'Item $suffix',
          description: 'description $suffix',
          createdAt: updated,
          updatedAt: updated,
        );
        final (Exchange exchange, ExchangeEvent event) =
            ExchangeTransitions(
              clock: FixedClock(updated),
              ids: SequenceIds(100 + int.parse(suffix)),
            ).create(
              id: ExchangeId('exchange-$suffix'),
              itemId: item.id,
              personId: person.id,
              direction: ExchangeDirection.borrowed,
              handedOffAt: base,
            );
        await repository.create(person, item, exchange, event);
      }

      final PersonRow person =
          await (database.select(
                database.people,
              )..where((People table) => table.id.equals(first.personId.value)))
              .getSingle();
      final ItemRow item =
          await (database.select(database.items)
                ..where((Items table) => table.id.equals(first.itemId.value)))
              .getSingle();
      expect(person.displayName, 'Person 4');
      expect(person.privateNote, 'private 4');
      expect(
        person.createdAt.isAtSameMomentAs(base),
        isTrue,
        reason: 'upsert must not rewrite identity creation time',
      );
      expect(item.name, 'Item 4');
      expect(item.description, 'description 4');
      expect(
        item.createdAt.isAtSameMomentAs(base),
        isTrue,
        reason: 'upsert must not rewrite identity creation time',
      );
      expect(await database.select(database.exchanges).get(), hasLength(4));
    },
  );

  test('rejects mismatched create and transition event associations', () async {
    final PersonAlias person = PersonAlias(
      id: PersonId('person'),
      displayName: 'Sam',
      createdAt: base,
      updatedAt: base,
    );
    final Item item = Item(
      id: ItemId('item'),
      name: 'Drill',
      createdAt: base,
      updatedAt: base,
    );
    final ExchangeTransitions transitions = ExchangeTransitions(
      clock: FixedClock(base),
      ids: SequenceIds(),
    );
    final (Exchange exchange, ExchangeEvent created) = transitions.create(
      id: ExchangeId('exchange'),
      itemId: item.id,
      personId: person.id,
      direction: ExchangeDirection.lent,
      handedOffAt: base,
    );

    await expectLater(
      repository.create(
        person,
        item,
        exchange,
        ExchangeEvent(
          id: created.id,
          exchangeId: ExchangeId('other'),
          type: created.type,
          occurredAt: created.occurredAt,
        ),
      ),
      throwsA(isA<InvalidValue>()),
    );
    await repository.create(person, item, exchange, created);
    await expectLater(
      repository.saveTransition(
        exchange,
        exchange,
        ExchangeEvent(
          id: ExchangeEventId('wrong-exchange-event'),
          exchangeId: ExchangeId('other'),
          type: ExchangeEventType.edited,
          occurredAt: base,
        ),
      ),
      throwsA(isA<InvalidValue>()),
    );
    expect((await repository.events(exchange.id)).length, 1);
  });

  test(
    'return and reopen append history while atomically updating projection',
    () async {
      final Exchange open = await add(
        suffix: '1',
        personName: 'Sam',
        itemName: 'Drill',
        direction: ExchangeDirection.lent,
      );
      final ExchangeTransitions transitions = ExchangeTransitions(
        clock: FixedClock(base.add(const Duration(days: 1))),
        ids: SequenceIds(99),
      );
      final (Exchange returned, ExchangeEvent returnEvent) = transitions
          .markReturned(open);
      await repository.saveTransition(open, returned, returnEvent);
      final (Exchange reopened, ExchangeEvent reopenEvent) = transitions.reopen(
        returned,
      );
      await repository.saveTransition(returned, reopened, reopenEvent);
      expect((await repository.get(open.id))!.status, ExchangeStatus.open);
      expect(
        (await repository.events(open.id))
            .map((ExchangeEvent value) => value.type),
        <ExchangeEventType>[
          ExchangeEventType.created,
          ExchangeEventType.returned,
          ExchangeEventType.reopened,
        ],
      );
    },
  );

  test('rejects mismatched and stale transition projections', () async {
    final Exchange open = await add(
      suffix: '1',
      personName: 'Sam',
      itemName: 'Drill',
      direction: ExchangeDirection.lent,
    );
    final DateTime nextDay = base.add(const Duration(days: 1));
    final ExchangeTransitions transitions = ExchangeTransitions(
      clock: FixedClock(nextDay),
      ids: SequenceIds(200),
    );
    final (Exchange returned, ExchangeEvent returnedEvent) = transitions
        .markReturned(open);
    await expectLater(
      repository.saveTransition(
        open,
        returned,
        ExchangeEvent(
          id: ExchangeEventId('wrong-type'),
          exchangeId: open.id,
          type: ExchangeEventType.edited,
          occurredAt: nextDay,
        ),
      ),
      throwsA(isA<InvalidTransition>()),
    );
    expect((await repository.get(open.id))!.status, ExchangeStatus.open);

    await repository.saveTransition(open, returned, returnedEvent);
    await expectLater(
      repository.saveTransition(
        open,
        returned,
        ExchangeEvent(
          id: ExchangeEventId('repeated-return'),
          exchangeId: open.id,
          type: ExchangeEventType.returned,
          occurredAt: nextDay,
        ),
      ),
      throwsA(isA<InvalidTransition>()),
    );
    expect(await repository.events(open.id), hasLength(2));
  });

  test('rejects an edit derived from a stale projection', () async {
    final Exchange open = await add(
      suffix: '1',
      personName: 'Sam',
      itemName: 'Drill',
      direction: ExchangeDirection.lent,
    );
    final (Exchange editA, ExchangeEvent eventA) = ExchangeTransitions(
      clock: FixedClock(base.add(const Duration(days: 1))),
      ids: SequenceIds(300),
    ).edit(open, dueAt: base.add(const Duration(days: 5)));
    final (Exchange editB, ExchangeEvent eventB) = ExchangeTransitions(
      clock: FixedClock(base.add(const Duration(days: 2))),
      ids: SequenceIds(400),
    ).edit(open, dueAt: base.add(const Duration(days: 6)));

    await repository.saveTransition(open, editA, eventA);
    await expectLater(
      repository.saveTransition(open, editB, eventB),
      throwsA(isA<InvalidTransition>()),
    );
    expect(
      (await repository.get(open.id))!.dueAt!.isAtSameMomentAs(editA.dueAt!),
      isTrue,
    );
    expect(
      (await repository.events(open.id))
          .map((ExchangeEvent value) => value.type),
      <ExchangeEventType>[ExchangeEventType.created, ExchangeEventType.edited],
    );
  });

  test('migrates synthetic version 1 fixture and preserves its exchange', () async {
    await database.close();
    database = LendLoopDatabase(
      NativeDatabase.memory(setup: _createVersionOneFixture),
    );
    repository = DriftExchangeRepository(database);
    final Exchange? migrated = await repository.get(
      ExchangeId('fixture-exchange'),
    );
    expect(migrated?.status, ExchangeStatus.open);
    final List<QueryRow> tables = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type IN ('table', 'index')",
        )
        .get();
    final Set<Object?> names = tables
        .map((QueryRow row) => row.read<String>('name'))
        .toSet();
    expect(
      names,
      containsAll(<String>[
        'attachments',
        'reminders',
        'exchanges_open_due_idx',
        'people_name_idx',
      ]),
    );

    final List<QueryRow> schemas = await database
        .customSelect(
          "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('exchanges', 'exchange_events')",
        )
        .get();
    final Map<String, String> sql = <String, String>{
      for (final QueryRow row in schemas)
        row.read<String>('name'): row.read<String>('sql').toLowerCase(),
    };
    expect(
      sql['exchanges'],
      contains('due_at is null or due_at >= handed_off_at'),
    );
    expect(
      sql['exchanges'],
      contains("status = 'open' and returned_at is null"),
    );
    expect(
      sql['exchange_events'],
      contains(
        "type in ('created', 'edited', 'reminded', 'returned', 'reopened')",
      ),
    );
    expect(sql['exchange_events'], contains('references exchanges (id)'));

    for (final String statement in <String>[
      "INSERT INTO exchanges VALUES ('bad-due','fixture-item','fixture-person','lent',$baseSeconds,$baseSeconds - 1,'open',NULL,$baseSeconds,$baseSeconds)",
      "INSERT INTO exchanges VALUES ('bad-status','fixture-item','fixture-person','lent',$baseSeconds,NULL,'invalid',NULL,$baseSeconds,$baseSeconds)",
      "INSERT INTO exchange_events VALUES ('bad-event','fixture-exchange','invalid',$baseSeconds,NULL)",
      "INSERT INTO exchange_events VALUES ('bad-fk','missing','edited',$baseSeconds,NULL)",
    ]) {
      await expectLater(
        database.customStatement(statement),
        throwsA(isA<sqlite.SqliteException>()),
      );
    }
  });

  test(
    'version 1 migration fails closed when legacy rows are invalid',
    () async {
      await database.close();
      database = LendLoopDatabase(
        NativeDatabase.memory(
          setup: (sqlite.Database raw) {
            _createVersionOneFixture(raw);
            raw.execute(
              "INSERT INTO exchange_events VALUES ('invalid-event','fixture-exchange','unknown',0,NULL)",
            );
          },
        ),
      );
      repository = DriftExchangeRepository(database);
      await expectLater(
        repository.get(ExchangeId('fixture-exchange')),
        throwsA(isA<StateError>()),
      );
    },
  );
}

final int baseSeconds = DateTime.utc(2026, 8, 1).millisecondsSinceEpoch ~/ 1000;

void _createVersionOneFixture(sqlite.Database database) {
  database.execute('PRAGMA foreign_keys = ON');
  database.execute(
    'CREATE TABLE people (id TEXT NOT NULL PRIMARY KEY, display_name TEXT NOT NULL, private_note TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
  );
  database.execute(
    'CREATE TABLE items (id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, description TEXT, category TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)',
  );
  database.execute(
    "CREATE TABLE exchanges (id TEXT NOT NULL PRIMARY KEY, item_id TEXT NOT NULL REFERENCES items(id), person_id TEXT NOT NULL REFERENCES people(id), direction TEXT NOT NULL CHECK(direction IN ('lent','borrowed')), handed_off_at INTEGER NOT NULL, due_at INTEGER, status TEXT NOT NULL CHECK(status IN ('open','returned')), returned_at INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
  );
  database.execute(
    "CREATE TABLE exchange_events (id TEXT NOT NULL PRIMARY KEY, exchange_id TEXT NOT NULL REFERENCES exchanges(id), type TEXT NOT NULL, occurred_at INTEGER NOT NULL, metadata TEXT)",
  );
  final int timestamp = DateTime.utc(2026, 8, 1).millisecondsSinceEpoch ~/ 1000;
  database.execute(
    "INSERT INTO people VALUES ('fixture-person','Synthetic Person',NULL,$timestamp,$timestamp)",
  );
  database.execute(
    "INSERT INTO items VALUES ('fixture-item','Synthetic Item',NULL,NULL,$timestamp,$timestamp)",
  );
  database.execute(
    "INSERT INTO exchanges VALUES ('fixture-exchange','fixture-item','fixture-person','lent',$timestamp,NULL,'open',NULL,$timestamp,$timestamp)",
  );
  database.execute(
    "INSERT INTO exchange_events VALUES ('fixture-event','fixture-exchange','created',$timestamp,NULL)",
  );
  database.userVersion = 1;
}
