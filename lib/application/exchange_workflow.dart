import 'package:lend_loop/domain/exchange_domain.dart';

enum OpenExchangeFilter { all, dueSoon, overdue, returned }

final class HandoffDraft {
  const HandoffDraft({
    required this.direction,
    required this.itemName,
    required this.personName,
    required this.handedOffAt,
    this.dueAt,
    this.notes,
  });

  final ExchangeDirection direction;
  final String itemName;
  final String personName;
  final DateTime handedOffAt;
  final DateTime? dueAt;
  final String? notes;
}

final class AttachmentDraft {
  const AttachmentDraft({
    required this.relativePath,
    required this.mediaType,
    required this.byteSize,
    required this.digest,
  });

  final String relativePath;
  final String mediaType;
  final int byteSize;
  final String digest;
}

final class ExchangeRecord {
  const ExchangeRecord({
    required this.exchange,
    required this.person,
    required this.item,
    required this.events,
    required this.attachments,
    required this.dueState,
  });

  final Exchange exchange;
  final PersonAlias person;
  final Item item;
  final List<ExchangeEvent> events;
  final List<Attachment> attachments;
  final DueState dueState;
}

final class ExchangeWorkflow {
  ExchangeWorkflow({
    required this.repository,
    required this.clock,
    required this.ids,
    this.dueStatePolicy = const DueStatePolicy(),
  }) : _transitions = ExchangeTransitions(clock: clock, ids: ids);

  final ExchangeRepository repository;
  final Clock clock;
  final IdGenerator ids;
  final DueStatePolicy dueStatePolicy;
  final ExchangeTransitions _transitions;

  Future<ExchangeRecord> recordHandoff(
    HandoffDraft draft, {
    AttachmentDraft? attachment,
  }) async {
    final DateTime now = clock.now();
    final PersonAlias person = PersonAlias(
      id: PersonId(ids.nextId()),
      displayName: draft.personName,
      createdAt: now,
      updatedAt: now,
    );
    final Item item = Item(
      id: ItemId(ids.nextId()),
      name: draft.itemName,
      description: draft.notes,
      createdAt: now,
      updatedAt: now,
    );
    final (Exchange exchange, ExchangeEvent event) = _transitions.create(
      id: ExchangeId(ids.nextId()),
      itemId: item.id,
      personId: person.id,
      direction: draft.direction,
      handedOffAt: draft.handedOffAt,
      dueAt: draft.dueAt,
    );
    final Attachment? storedAttachment = attachment == null
        ? null
        : Attachment(
            id: AttachmentId(ids.nextId()),
            exchangeId: exchange.id,
            itemId: item.id,
            relativePath: attachment.relativePath,
            mediaType: attachment.mediaType,
            byteSize: attachment.byteSize,
            digest: attachment.digest,
          );
    await repository.create(
      person,
      item,
      exchange,
      event,
      attachment: storedAttachment,
    );
    return _hydrate(exchange);
  }

  Future<List<ExchangeRecord>> openExchanges({
    OpenExchangeFilter filter = OpenExchangeFilter.all,
  }) async {
    final List<Exchange> exchanges = await repository.find(
      ExchangeQuery(
        status: filter == OpenExchangeFilter.returned
            ? ExchangeStatus.returned
            : ExchangeStatus.open,
      ),
    );
    final List<ExchangeRecord> records = <ExchangeRecord>[];
    for (final Exchange exchange in exchanges) {
      final ExchangeRecord record = await _hydrate(exchange);
      final bool include = switch (filter) {
        OpenExchangeFilter.all => true,
        OpenExchangeFilter.dueSoon => record.dueState == DueState.dueSoon,
        OpenExchangeFilter.overdue => record.dueState == DueState.overdue,
        OpenExchangeFilter.returned => true,
      };
      if (include) records.add(record);
    }
    return records;
  }

  Future<ExchangeRecord> details(ExchangeId id) async {
    final Exchange? exchange = await repository.get(id);
    if (exchange == null) throw NotFound('Exchange $id was not found.');
    return _hydrate(exchange);
  }

  Future<ExchangeRecord> markReturned(ExchangeId id) async {
    final ExchangeRecord record = await details(id);
    final (Exchange next, ExchangeEvent event) = _transitions.markReturned(
      record.exchange,
    );
    await repository.saveTransition(record.exchange, next, event);
    return _hydrate(next);
  }

  Future<ExchangeRecord> reopen(ExchangeId id) async {
    final ExchangeRecord record = await details(id);
    final (Exchange next, ExchangeEvent event) = _transitions.reopen(
      record.exchange,
    );
    await repository.saveTransition(record.exchange, next, event);
    return _hydrate(next);
  }

  Future<ExchangeRecord> _hydrate(Exchange exchange) async {
    final (PersonAlias? person, Item? item) = await (
      repository.getPerson(exchange.personId),
      repository.getItem(exchange.itemId),
    ).wait;
    if (person == null || item == null) {
      throw NotFound('Exchange ${exchange.id} has missing linked data.');
    }
    return ExchangeRecord(
      exchange: exchange,
      person: person,
      item: item,
      events: await repository.events(exchange.id),
      attachments: await repository.attachments(exchange.id),
      dueState: dueStatePolicy.evaluate(exchange, clock.now()),
    );
  }
}
