import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/data/database.dart';
import 'package:lend_loop/domain/exchange_domain.dart';

void main() {
  late LendLoopDatabase database;
  late DriftExchangeRepository repository;
  final DateTime now = DateTime.utc(2026, 8, 28);

  setUp(() {
    database = LendLoopDatabase(NativeDatabase.memory());
    repository = DriftExchangeRepository(database);
  });

  tearDown(() => database.close());

  Future<Exchange> seed(String suffix) async {
    final PersonAlias person = PersonAlias(
      id: PersonId('person-$suffix'),
      displayName: 'Person $suffix',
      createdAt: now,
      updatedAt: now,
    );
    final Item item = Item(
      id: ItemId('item-$suffix'),
      name: 'Item $suffix',
      createdAt: now,
      updatedAt: now,
    );
    final Exchange exchange = Exchange(
      id: ExchangeId('exchange-$suffix'),
      itemId: item.id,
      personId: person.id,
      direction: ExchangeDirection.lent,
      handedOffAt: now,
      dueAt: null,
      status: ExchangeStatus.open,
      returnedAt: null,
      createdAt: now,
      updatedAt: now,
    );
    await repository.create(
      person,
      item,
      exchange,
      ExchangeEvent(
        id: ExchangeEventId('event-$suffix'),
        exchangeId: exchange.id,
        type: ExchangeEventType.created,
        occurredAt: now,
      ),
      attachment: Attachment(
        id: AttachmentId('attachment-$suffix'),
        exchangeId: exchange.id,
        itemId: item.id,
        relativePath: 'attachments/$suffix.jpg',
        mediaType: 'image/jpeg',
        byteSize: 1,
        digest:
            '4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7c67e2d2d0a1d7',
      ),
    );
    return exchange;
  }

  test('deletes an attachment without deleting its text record', () async {
    final Exchange exchange = await seed('one');

    final Attachment removed = await repository.deleteAttachment(
      AttachmentId('attachment-one'),
    );

    expect(removed.relativePath, 'attachments/one.jpg');
    expect(await repository.attachments(exchange.id), isEmpty);
    expect(await repository.get(exchange.id), isNotNull);
  });

  test('deletes one exchange history and returns files to remove', () async {
    final Exchange first = await seed('one');
    final Exchange second = await seed('two');

    final List<Attachment> removed = await repository.deleteExchange(first.id);

    expect(removed.single.id, AttachmentId('attachment-one'));
    expect(await repository.get(first.id), isNull);
    expect(await repository.events(first.id), isEmpty);
    expect(await repository.getPerson(first.personId), isNull);
    expect(await repository.getItem(first.itemId), isNull);
    expect(await repository.get(second.id), isNotNull);
  });

  test(
    'deletes all local database records and returns attachment paths',
    () async {
      await seed('one');
      await seed('two');

      final List<Attachment> removed = await repository.deleteAllLocalData();

      expect(removed, hasLength(2));
      expect(await repository.find(const ExchangeQuery()), isEmpty);
      expect(await database.select(database.people).get(), isEmpty);
      expect(await database.select(database.items).get(), isEmpty);
    },
  );
}
