import 'package:drift/drift.dart';
import 'package:lend_loop/domain/exchange_domain.dart' as domain;

part 'database.g.dart';

@DataClassName('PersonRow')
class People extends Table {
  TextColumn get id => text().withLength(min: 1, max: 128)();
  TextColumn get displayName => text().withLength(min: 1)();
  TextColumn get privateNote => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('ItemRow')
class Items extends Table {
  TextColumn get id => text().withLength(min: 1, max: 128)();
  TextColumn get name => text().withLength(min: 1)();
  TextColumn get description => text().nullable()();
  TextColumn get category => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('ExchangeRow')
class Exchanges extends Table {
  TextColumn get id => text().withLength(min: 1, max: 128)();
  TextColumn get itemId => text().references(Items, #id)();
  TextColumn get personId => text().references(People, #id)();
  TextColumn get direction => text().customConstraint(
    "NOT NULL CHECK (direction IN ('lent', 'borrowed'))",
  )();
  DateTimeColumn get handedOffAt => dateTime()();
  DateTimeColumn get dueAt => dateTime().nullable()();
  TextColumn get status => text().customConstraint(
    "NOT NULL CHECK (status IN ('open', 'returned'))",
  )();
  DateTimeColumn get returnedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
  @override
  List<String> get customConstraints => <String>[
    'CHECK (due_at IS NULL OR due_at >= handed_off_at)',
    "CHECK ((status = 'open' AND returned_at IS NULL) OR "
        "(status = 'returned' AND returned_at IS NOT NULL))",
  ];
}

@DataClassName('ExchangeEventRow')
class ExchangeEvents extends Table {
  TextColumn get id => text().withLength(min: 1, max: 128)();
  TextColumn get exchangeId => text().references(Exchanges, #id)();
  TextColumn get type => text().customConstraint(
    "NOT NULL CHECK (type IN ('created', 'edited', 'reminded', 'returned', 'reopened'))",
  )();
  DateTimeColumn get occurredAt => dateTime()();
  TextColumn get metadata => text().nullable()();
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('AttachmentRow')
class Attachments extends Table {
  TextColumn get id => text().withLength(min: 1, max: 128)();
  TextColumn get exchangeId => text().references(Exchanges, #id)();
  TextColumn get itemId => text().nullable().references(Items, #id)();
  TextColumn get relativePath => text().customConstraint(
    "NOT NULL CHECK (relative_path <> '' AND relative_path NOT LIKE '/%' "
    "AND relative_path <> '.' AND relative_path <> '..' "
    "AND relative_path NOT LIKE './%' AND relative_path NOT LIKE '../%' "
    "AND relative_path NOT LIKE '%/./%' AND relative_path NOT LIKE '%/../%' "
    "AND relative_path NOT LIKE '%/.' AND relative_path NOT LIKE '%/..' "
    "AND relative_path NOT LIKE '%//%' "
    "AND relative_path NOT GLOB '[A-Za-z]:*' AND relative_path NOT GLOB '*\\*')",
  )();
  TextColumn get mediaType => text().withLength(min: 1)();
  IntColumn get byteSize =>
      integer().customConstraint('NOT NULL CHECK (byte_size >= 0)')();
  TextColumn get digest => text().withLength(min: 1)();
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{id};
}

@DataClassName('ReminderRow')
class Reminders extends Table {
  TextColumn get exchangeId => text().references(Exchanges, #id)();
  DateTimeColumn get requestedAt => dateTime()();
  DateTimeColumn get scheduledAt => dateTime()();
  IntColumn get platformSchedulingId => integer().unique()();
  TextColumn get title => text().withLength(min: 1)();
  TextColumn get body => text().withLength(min: 1)();
  TextColumn get deliveryState => text().customConstraint(
    "NOT NULL CHECK (delivery_state IN ('pending', 'scheduled'))",
  )();
  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{exchangeId};
}

@DriftDatabase(
  tables: <Type>[
    People,
    Items,
    Exchanges,
    ExchangeEvents,
    Attachments,
    Reminders,
  ],
)
class LendLoopDatabase extends _$LendLoopDatabase {
  LendLoopDatabase(super.executor, {this.beforeProjectionUpdate});

  /// Test seam invoked inside the transaction, after its event insert.
  final Future<void> Function()? beforeProjectionUpdate;

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator migrator) async {
      await migrator.createAll();
      await _createIndexes();
    },
    onUpgrade: (Migrator migrator, int from, int to) async {
      if (from < 2) {
        await _upgradeVersionOneCoreTables(migrator);
        await migrator.createTable(attachments);
        await migrator.createTable(reminders);
        await _createIndexes();
      }
      if (from >= 2 && from < 3) {
        // Version 2 did not retain enough information to safely recreate a
        // reminder after an OS restart, so discard those incomplete rows.
        await migrator.deleteTable('reminders');
        await migrator.createTable(reminders);
      }
    },
    beforeOpen: (OpeningDetails details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _createIndexes() async {
    for (final String statement in <String>[
      'CREATE INDEX IF NOT EXISTS exchanges_open_due_idx ON exchanges(status, due_at)',
      'CREATE INDEX IF NOT EXISTS exchanges_person_idx ON exchanges(person_id)',
      'CREATE INDEX IF NOT EXISTS exchanges_direction_idx ON exchanges(direction)',
      'CREATE INDEX IF NOT EXISTS exchanges_updated_idx ON exchanges(updated_at DESC)',
      'CREATE INDEX IF NOT EXISTS people_name_idx ON people(display_name COLLATE NOCASE)',
      'CREATE INDEX IF NOT EXISTS items_name_idx ON items(name COLLATE NOCASE)',
      'CREATE INDEX IF NOT EXISTS events_exchange_time_idx ON exchange_events(exchange_id, occurred_at)',
    ]) {
      await customStatement(statement);
    }
  }

  Future<void> _upgradeVersionOneCoreTables(Migrator migrator) async {
    final QueryRow invalid = await customSelect('''
SELECT
  (SELECT COUNT(*) FROM exchanges e
    LEFT JOIN people p ON p.id = e.person_id
    LEFT JOIN items i ON i.id = e.item_id
    WHERE p.id IS NULL OR i.id IS NULL
       OR e.direction NOT IN ('lent', 'borrowed')
       OR e.status NOT IN ('open', 'returned')
       OR (e.due_at IS NOT NULL AND e.due_at < e.handed_off_at)
       OR NOT ((e.status = 'open' AND e.returned_at IS NULL)
            OR (e.status = 'returned' AND e.returned_at IS NOT NULL))) AS bad_exchanges,
  (SELECT COUNT(*) FROM exchange_events ev
    LEFT JOIN exchanges e ON e.id = ev.exchange_id
    WHERE e.id IS NULL
       OR ev.type NOT IN ('created', 'edited', 'reminded', 'returned', 'reopened')) AS bad_events
''').getSingle();
    if (invalid.read<int>('bad_exchanges') != 0 ||
        invalid.read<int>('bad_events') != 0) {
      throw StateError('Version 1 data violates version 2 constraints.');
    }

    await customStatement(
      'ALTER TABLE exchange_events RENAME TO exchange_events_v1',
    );
    await customStatement('ALTER TABLE exchanges RENAME TO exchanges_v1');
    await migrator.createTable(exchanges);
    await migrator.createTable(exchangeEvents);
    await customStatement('''
INSERT INTO exchanges
SELECT id, item_id, person_id, direction, handed_off_at, due_at, status,
       returned_at, created_at, updated_at
FROM exchanges_v1
''');
    await customStatement('''
INSERT INTO exchange_events
SELECT id, exchange_id, type, occurred_at, metadata
FROM exchange_events_v1
''');
    await customStatement('DROP TABLE exchange_events_v1');
    await customStatement('DROP TABLE exchanges_v1');
  }
}

final class DriftExchangeRepository
    implements domain.ExchangeRepository, domain.ReminderRepository {
  const DriftExchangeRepository(this.database);
  final LendLoopDatabase database;

  @override
  Future<void> create(
    domain.PersonAlias person,
    domain.Item item,
    domain.Exchange exchange,
    domain.ExchangeEvent event, {
    domain.Attachment? attachment,
  }) => database.transaction(() async {
    if (person.id != exchange.personId || item.id != exchange.itemId) {
      throw const domain.InvalidValue(
        'Person and item IDs must match the exchange projection.',
      );
    }
    if (event.exchangeId != exchange.id ||
        event.type != domain.ExchangeEventType.created) {
      throw const domain.InvalidValue(
        'A new exchange requires its matching created event.',
      );
    }
    if (attachment != null &&
        (attachment.exchangeId != exchange.id ||
            attachment.itemId != item.id)) {
      throw const domain.InvalidValue(
        'Attachment associations must match the new exchange and item.',
      );
    }
    await database.customInsert(
      'INSERT INTO people (id, display_name, private_note, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'display_name = excluded.display_name, private_note = excluded.private_note, '
      'updated_at = excluded.updated_at',
      variables: <Variable<Object>>[
        Variable<String>(person.id.value),
        Variable<String>(person.displayName),
        Variable<String>(person.privateNote),
        Variable<DateTime>(person.createdAt),
        Variable<DateTime>(person.updatedAt),
      ],
      updates: <TableInfo<Table, Object?>>{database.people},
    );
    await database.customInsert(
      'INSERT INTO items (id, name, description, category, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET '
      'name = excluded.name, description = excluded.description, '
      'category = excluded.category, updated_at = excluded.updated_at',
      variables: <Variable<Object>>[
        Variable<String>(item.id.value),
        Variable<String>(item.name),
        Variable<String>(item.description),
        Variable<String>(item.category),
        Variable<DateTime>(item.createdAt),
        Variable<DateTime>(item.updatedAt),
      ],
      updates: <TableInfo<Table, Object?>>{database.items},
    );
    await database
        .into(database.exchanges)
        .insert(_exchangeCompanion(exchange));
    await database.into(database.exchangeEvents).insert(_eventCompanion(event));
    if (attachment != null) {
      await database
          .into(database.attachments)
          .insert(
            AttachmentsCompanion.insert(
              id: attachment.id.value,
              exchangeId: attachment.exchangeId.value,
              itemId: Value<String?>(attachment.itemId?.value),
              relativePath: attachment.relativePath,
              mediaType: attachment.mediaType,
              byteSize: attachment.byteSize,
              digest: attachment.digest,
            ),
          );
    }
  });

  @override
  Future<domain.Exchange?> get(domain.ExchangeId id) async {
    final ExchangeRow? row = await (database.select(
      database.exchanges,
    )..where((Exchanges table) => table.id.equals(id.value))).getSingleOrNull();
    return row == null ? null : _exchange(row);
  }

  @override
  Future<domain.PersonAlias?> getPerson(domain.PersonId id) async {
    final PersonRow? row = await (database.select(
      database.people,
    )..where((People table) => table.id.equals(id.value))).getSingleOrNull();
    return row == null
        ? null
        : domain.PersonAlias(
            id: domain.PersonId(row.id),
            displayName: row.displayName,
            privateNote: row.privateNote,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
          );
  }

  @override
  Future<domain.Item?> getItem(domain.ItemId id) async {
    final ItemRow? row = await (database.select(
      database.items,
    )..where((Items table) => table.id.equals(id.value))).getSingleOrNull();
    return row == null
        ? null
        : domain.Item(
            id: domain.ItemId(row.id),
            name: row.name,
            description: row.description,
            category: row.category,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
          );
  }

  @override
  Future<List<domain.Exchange>> find(domain.ExchangeQuery query) async {
    final StringBuffer sql = StringBuffer(
      'SELECT e.* FROM exchanges e '
      'JOIN people p ON p.id = e.person_id JOIN items i ON i.id = e.item_id WHERE 1=1',
    );
    final List<Variable<Object>> variables = <Variable<Object>>[];
    void add(String clause, Object value) {
      sql.write(clause);
      variables.add(Variable<Object>(value));
    }

    if (query.status != null) {
      add(' AND e.status = ?', query.status!.name);
    }
    if (query.direction != null) {
      add(' AND e.direction = ?', query.direction!.name);
    }
    if (query.personId != null) {
      add(' AND e.person_id = ?', query.personId!.value);
    }
    if (query.dueBefore != null) {
      add(' AND e.due_at IS NOT NULL AND e.due_at <= ?', query.dueBefore!);
    }
    if (query.handedOffFrom != null) {
      add(' AND e.handed_off_at >= ?', query.handedOffFrom!);
    }
    if (query.handedOffThrough != null) {
      add(' AND e.handed_off_at <= ?', query.handedOffThrough!);
    }
    final String text = query.text?.trim() ?? '';
    if (text.isNotEmpty) {
      sql.write(
        " AND (p.display_name LIKE ? ESCAPE '\\' COLLATE NOCASE "
        "OR i.name LIKE ? ESCAPE '\\' COLLATE NOCASE "
        "OR COALESCE(i.description, '') LIKE ? ESCAPE '\\' COLLATE NOCASE)",
      );
      final String pattern = '%${_escapeLike(text)}%';
      variables.addAll(<Variable<Object>>[
        Variable<String>(pattern),
        Variable<String>(pattern),
        Variable<String>(pattern),
      ]);
    }
    sql.write(
      ' ORDER BY CASE WHEN e.due_at IS NULL THEN 1 ELSE 0 END, '
      'e.due_at ASC, e.handed_off_at DESC, e.id ASC',
    );
    final List<ExchangeRow> rows = await database
        .customSelect(
          sql.toString(),
          variables: variables,
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            database.exchanges,
            database.people,
            database.items,
          },
        )
        .map((QueryRow row) => database.exchanges.map(row.data))
        .get();
    return rows.map(_exchange).toList(growable: false);
  }

  @override
  Future<List<domain.ExchangeEvent>> events(domain.ExchangeId id) async {
    final List<ExchangeEventRow> rows = await database
        .customSelect(
          'SELECT * FROM exchange_events WHERE exchange_id = ? '
          'ORDER BY occurred_at ASC, rowid ASC',
          variables: <Variable<Object>>[Variable<String>(id.value)],
          readsFrom: <ResultSetImplementation<Table, Object?>>{
            database.exchangeEvents,
          },
        )
        .map((QueryRow row) => database.exchangeEvents.map(row.data))
        .get();
    return rows.map(_event).toList(growable: false);
  }

  @override
  Future<List<domain.Attachment>> attachments(domain.ExchangeId id) async {
    final List<AttachmentRow> rows = await (database.select(
      database.attachments,
    )..where((Attachments table) => table.exchangeId.equals(id.value))).get();
    return rows.map(_attachment).toList(growable: false);
  }

  @override
  Future<void> saveTransition(
    domain.Exchange previous,
    domain.Exchange next,
    domain.ExchangeEvent event,
  ) => saveTransitionAndReminder(previous, next, event);

  @override
  Future<void> saveTransitionAndReminder(
    domain.Exchange previous,
    domain.Exchange next,
    domain.ExchangeEvent event, {
    domain.Reminder? reminder,
    bool deleteReminder = false,
  }) => database.transaction(() async {
    if (previous.id != next.id || event.exchangeId != next.id) {
      throw const domain.InvalidValue(
        'Previous, next, and transition event exchange IDs must match.',
      );
    }
    if (event.type == domain.ExchangeEventType.created) {
      throw const domain.InvalidTransition(
        'Created events can only be stored with a new exchange.',
      );
    }
    final ExchangeRow? currentRow =
        await (database.select(database.exchanges)
              ..where((Exchanges table) => table.id.equals(next.id.value)))
            .getSingleOrNull();
    if (currentRow == null) {
      throw domain.NotFound('Exchange ${next.id} was not found.');
    }
    final domain.Exchange current = _exchange(currentRow);
    if (!_sameExchange(current, previous)) {
      throw const domain.InvalidTransition(
        'The exchange changed after this transition was created.',
      );
    }
    _validateTransition(current, next, event);
    final int inserted = await database
        .into(database.exchangeEvents)
        .insert(_eventCompanion(event));
    if (inserted == 0) throw StateError('Event insert failed.');
    await database.beforeProjectionUpdate?.call();
    final int changed =
        await (database.update(database.exchanges)
              ..where((Exchanges table) => _matchesProjection(table, previous)))
            .write(_exchangeCompanion(next));
    if (changed != 1) {
      throw const domain.InvalidTransition(
        'The exchange changed while this transition was being saved.',
      );
    }
    if (deleteReminder) {
      await (database.delete(
            database.reminders,
          )..where((Reminders table) => table.exchangeId.equals(next.id.value)))
          .go();
    } else if (reminder != null) {
      if (reminder.exchangeId != next.id) {
        throw const domain.InvalidValue(
          'Reminder must belong to the transitioned exchange.',
        );
      }
      await saveReminder(reminder);
    }
  });

  @override
  Future<void> addAttachment(domain.Attachment attachment) => database
      .into(database.attachments)
      .insert(
        AttachmentsCompanion.insert(
          id: attachment.id.value,
          exchangeId: attachment.exchangeId.value,
          itemId: Value<String?>(attachment.itemId?.value),
          relativePath: attachment.relativePath,
          mediaType: attachment.mediaType,
          byteSize: attachment.byteSize,
          digest: attachment.digest,
        ),
      );

  @override
  Future<domain.Attachment> deleteAttachment(domain.AttachmentId id) =>
      database.transaction(() async {
        final AttachmentRow? row =
            await (database.select(database.attachments)
                  ..where((Attachments table) => table.id.equals(id.value)))
                .getSingleOrNull();
        if (row == null) {
          throw domain.NotFound('Attachment $id was not found.');
        }
        await (database.delete(
          database.attachments,
        )..where((Attachments table) => table.id.equals(id.value))).go();
        return _attachment(row);
      });

  @override
  Future<List<domain.Attachment>> deleteExchange(
    domain.ExchangeId id,
  ) => database.transaction(() async {
    final ExchangeRow? exchange = await (database.select(
      database.exchanges,
    )..where((Exchanges table) => table.id.equals(id.value))).getSingleOrNull();
    if (exchange == null) {
      throw domain.NotFound('Exchange $id was not found.');
    }
    final List<domain.Attachment> removed = await attachments(id);
    await (database.delete(
      database.reminders,
    )..where((Reminders table) => table.exchangeId.equals(id.value))).go();
    await (database.delete(
      database.attachments,
    )..where((Attachments table) => table.exchangeId.equals(id.value))).go();
    await (database.delete(
      database.exchangeEvents,
    )..where((ExchangeEvents table) => table.exchangeId.equals(id.value))).go();
    await (database.delete(
      database.exchanges,
    )..where((Exchanges table) => table.id.equals(id.value))).go();
    await database.customStatement(
      'DELETE FROM people WHERE id = ? AND NOT EXISTS '
      '(SELECT 1 FROM exchanges WHERE person_id = ?)',
      <Object?>[exchange.personId, exchange.personId],
    );
    await database.customStatement(
      'DELETE FROM items WHERE id = ? AND NOT EXISTS '
      '(SELECT 1 FROM exchanges WHERE item_id = ?)',
      <Object?>[exchange.itemId, exchange.itemId],
    );
    return removed;
  });

  @override
  Future<List<domain.Attachment>> deleteAllLocalData() =>
      database.transaction(() async {
        final List<domain.Attachment> removed =
            (await database.select(database.attachments).get())
                .map(_attachment)
                .toList(growable: false);
        await database.delete(database.reminders).go();
        await database.delete(database.attachments).go();
        await database.delete(database.exchangeEvents).go();
        await database.delete(database.exchanges).go();
        await database.delete(database.items).go();
        await database.delete(database.people).go();
        return removed;
      });

  @override
  Future<domain.Reminder?> getReminder(domain.ExchangeId id) async {
    final ReminderRow? row =
        await (database.select(database.reminders)
              ..where((Reminders table) => table.exchangeId.equals(id.value)))
            .getSingleOrNull();
    return row == null ? null : _reminder(row);
  }

  @override
  Future<List<domain.Reminder>> reminders() async =>
      (await database.select(database.reminders).get())
          .map(_reminder)
          .toList(growable: false);

  @override
  Future<void> saveReminder(domain.Reminder reminder) => database
      .into(database.reminders)
      .insertOnConflictUpdate(
        RemindersCompanion.insert(
          exchangeId: reminder.exchangeId.value,
          requestedAt: reminder.requestedAt,
          scheduledAt: reminder.scheduledAt,
          platformSchedulingId: reminder.platformSchedulingId,
          title: reminder.title,
          body: reminder.body,
          deliveryState: reminder.deliveryState.name,
        ),
      );

  @override
  Future<void> deleteReminder(domain.ExchangeId id) => (database.delete(
    database.reminders,
  )..where((Reminders table) => table.exchangeId.equals(id.value))).go();

  @override
  Future<bool> reminderEligible(domain.ExchangeId id) async {
    final ExchangeRow? row = await (database.select(
      database.exchanges,
    )..where((Exchanges table) => table.id.equals(id.value))).getSingleOrNull();
    return row?.status == domain.ExchangeStatus.open.name;
  }
}

String _escapeLike(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_');

ExchangesCompanion _exchangeCompanion(domain.Exchange value) =>
    ExchangesCompanion.insert(
      id: value.id.value,
      itemId: value.itemId.value,
      personId: value.personId.value,
      direction: value.direction.name,
      handedOffAt: value.handedOffAt,
      dueAt: Value<DateTime?>(value.dueAt),
      status: value.status.name,
      returnedAt: Value<DateTime?>(value.returnedAt),
      createdAt: value.createdAt,
      updatedAt: value.updatedAt,
    );

ExchangeEventsCompanion _eventCompanion(domain.ExchangeEvent value) =>
    ExchangeEventsCompanion.insert(
      id: value.id.value,
      exchangeId: value.exchangeId.value,
      type: value.type.name,
      occurredAt: value.occurredAt,
      metadata: Value<String?>(value.metadata),
    );

domain.Exchange _exchange(ExchangeRow row) => domain.Exchange(
  id: domain.ExchangeId(row.id),
  itemId: domain.ItemId(row.itemId),
  personId: domain.PersonId(row.personId),
  direction: domain.ExchangeDirection.values.byName(row.direction),
  handedOffAt: row.handedOffAt,
  dueAt: row.dueAt,
  status: domain.ExchangeStatus.values.byName(row.status),
  returnedAt: row.returnedAt,
  createdAt: row.createdAt,
  updatedAt: row.updatedAt,
);

domain.ExchangeEvent _event(ExchangeEventRow row) => domain.ExchangeEvent(
  id: domain.ExchangeEventId(row.id),
  exchangeId: domain.ExchangeId(row.exchangeId),
  type: domain.ExchangeEventType.values.byName(row.type),
  occurredAt: row.occurredAt,
  metadata: row.metadata,
);

domain.Attachment _attachment(AttachmentRow row) => domain.Attachment(
  id: domain.AttachmentId(row.id),
  exchangeId: domain.ExchangeId(row.exchangeId),
  itemId: row.itemId == null ? null : domain.ItemId(row.itemId!),
  relativePath: row.relativePath,
  mediaType: row.mediaType,
  byteSize: row.byteSize,
  digest: row.digest,
);

domain.Reminder _reminder(ReminderRow row) => domain.Reminder(
  exchangeId: domain.ExchangeId(row.exchangeId),
  requestedAt: row.requestedAt,
  scheduledAt: row.scheduledAt,
  platformSchedulingId: row.platformSchedulingId,
  title: row.title,
  body: row.body,
  deliveryState: domain.ReminderDeliveryState.values.byName(row.deliveryState),
);

void _validateTransition(
  domain.Exchange current,
  domain.Exchange next,
  domain.ExchangeEvent event,
) {
  final bool immutableFieldsMatch =
      current.id == next.id &&
      current.itemId == next.itemId &&
      current.personId == next.personId &&
      current.direction == next.direction &&
      _sameTime(current.handedOffAt, next.handedOffAt) &&
      _sameTime(current.createdAt, next.createdAt);
  if (!immutableFieldsMatch || !_sameTime(next.updatedAt, event.occurredAt)) {
    throw const domain.InvalidTransition(
      'Transition does not match the stored exchange projection.',
    );
  }

  final bool valid = switch (event.type) {
    domain.ExchangeEventType.edited =>
      current.status == domain.ExchangeStatus.open &&
          next.status == domain.ExchangeStatus.open &&
          next.returnedAt == null &&
          !_sameNullableTime(current.dueAt, next.dueAt),
    domain.ExchangeEventType.returned =>
      current.status == domain.ExchangeStatus.open &&
          next.status == domain.ExchangeStatus.returned &&
          next.returnedAt != null &&
          _sameTime(next.returnedAt!, event.occurredAt) &&
          _sameNullableTime(current.dueAt, next.dueAt),
    domain.ExchangeEventType.reopened =>
      current.status == domain.ExchangeStatus.returned &&
          next.status == domain.ExchangeStatus.open &&
          next.returnedAt == null &&
          _sameNullableTime(current.dueAt, next.dueAt),
    domain.ExchangeEventType.created ||
    domain.ExchangeEventType.reminded => false,
  };
  if (!valid || next.updatedAt.isBefore(current.updatedAt)) {
    throw const domain.InvalidTransition(
      'Event type is inconsistent with the stored exchange transition.',
    );
  }
}

bool _sameTime(DateTime left, DateTime right) => left.isAtSameMomentAs(right);

bool _sameNullableTime(DateTime? left, DateTime? right) =>
    left == null ? right == null : right != null && _sameTime(left, right);

bool _sameExchange(domain.Exchange left, domain.Exchange right) =>
    left.id == right.id &&
    left.itemId == right.itemId &&
    left.personId == right.personId &&
    left.direction == right.direction &&
    _sameTime(left.handedOffAt, right.handedOffAt) &&
    _sameNullableTime(left.dueAt, right.dueAt) &&
    left.status == right.status &&
    _sameNullableTime(left.returnedAt, right.returnedAt) &&
    _sameTime(left.createdAt, right.createdAt) &&
    _sameTime(left.updatedAt, right.updatedAt);

Expression<bool> _matchesProjection(Exchanges table, domain.Exchange value) {
  Expression<bool> matches =
      table.id.equals(value.id.value) &
      table.itemId.equals(value.itemId.value) &
      table.personId.equals(value.personId.value) &
      table.direction.equals(value.direction.name) &
      table.handedOffAt.equals(value.handedOffAt) &
      table.status.equals(value.status.name) &
      table.createdAt.equals(value.createdAt) &
      table.updatedAt.equals(value.updatedAt);
  matches &= value.dueAt == null
      ? table.dueAt.isNull()
      : table.dueAt.equals(value.dueAt!);
  matches &= value.returnedAt == null
      ? table.returnedAt.isNull()
      : table.returnedAt.equals(value.returnedAt!);
  return matches;
}
