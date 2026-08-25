/// UI- and persistence-independent exchange domain model.
library;

abstract interface class Clock {
  DateTime now();
}

abstract interface class IdGenerator {
  String nextId();
}

sealed class DomainError implements Exception {
  const DomainError(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class InvalidValue extends DomainError {
  const InvalidValue(super.message);
}

final class InvalidTransition extends DomainError {
  const InvalidTransition(super.message);
}

final class NotFound extends DomainError {
  const NotFound(super.message);
}

abstract base class TypedId {
  TypedId(String value) : value = _validateId(value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is TypedId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;
}

String _validateId(String value) {
  final String normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 128) {
    throw const InvalidValue('IDs must contain 1 to 128 characters.');
  }
  return normalized;
}

final class PersonId extends TypedId {
  PersonId(super.value);
}

final class ItemId extends TypedId {
  ItemId(super.value);
}

final class ExchangeId extends TypedId {
  ExchangeId(super.value);
}

final class ExchangeEventId extends TypedId {
  ExchangeEventId(super.value);
}

final class AttachmentId extends TypedId {
  AttachmentId(super.value);
}

enum ExchangeDirection { lent, borrowed }

enum ExchangeStatus { open, returned }

enum ExchangeEventType { created, edited, reminded, returned, reopened }

enum DueState { none, upcoming, dueSoon, overdue, returned }

final class DueStatePolicy {
  const DueStatePolicy({this.dueSoonWindow = const Duration(days: 3)});

  final Duration dueSoonWindow;

  DueState evaluate(Exchange exchange, DateTime now) {
    if (exchange.status == ExchangeStatus.returned) return DueState.returned;
    final DateTime? dueAt = exchange.dueAt;
    if (dueAt == null) return DueState.none;
    if (dueAt.isBefore(now)) return DueState.overdue;
    if (!dueAt.isAfter(now.add(dueSoonWindow))) return DueState.dueSoon;
    return DueState.upcoming;
  }
}

String _requiredText(String value, String field) {
  final String normalized = value.trim();
  if (normalized.isEmpty) throw InvalidValue('$field must not be blank.');
  return normalized;
}

String? _optionalText(String? value) {
  final String? normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

final class PersonAlias {
  PersonAlias({
    required this.id,
    required String displayName,
    String? privateNote,
    required this.createdAt,
    required this.updatedAt,
  }) : displayName = _requiredText(displayName, 'Display name'),
       privateNote = _optionalText(privateNote);
  final PersonId id;
  final String displayName;
  final String? privateNote;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class Item {
  Item({
    required this.id,
    required String name,
    String? description,
    String? category,
    required this.createdAt,
    required this.updatedAt,
  }) : name = _requiredText(name, 'Item name'),
       description = _optionalText(description),
       category = _optionalText(category);
  final ItemId id;
  final String name;
  final String? description;
  final String? category;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class Exchange {
  const Exchange({
    required this.id,
    required this.itemId,
    required this.personId,
    required this.direction,
    required this.handedOffAt,
    required this.dueAt,
    required this.status,
    required this.returnedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  final ExchangeId id;
  final ItemId itemId;
  final PersonId personId;
  final ExchangeDirection direction;
  final DateTime handedOffAt;
  final DateTime? dueAt;
  final ExchangeStatus status;
  final DateTime? returnedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class ExchangeEvent {
  const ExchangeEvent({
    required this.id,
    required this.exchangeId,
    required this.type,
    required this.occurredAt,
    this.metadata,
  });
  final ExchangeEventId id;
  final ExchangeId exchangeId;
  final ExchangeEventType type;
  final DateTime occurredAt;
  final String? metadata;
}

final class Attachment {
  Attachment({
    required this.id,
    required this.exchangeId,
    this.itemId,
    required String relativePath,
    required String mediaType,
    required this.byteSize,
    required String digest,
  }) : relativePath = validateRelativePath(relativePath),
       mediaType = _requiredText(mediaType, 'Media type'),
       digest = _requiredText(digest, 'Digest') {
    if (byteSize < 0) throw const InvalidValue('Byte size cannot be negative.');
  }
  final AttachmentId id;
  final ExchangeId exchangeId;
  final ItemId? itemId;
  final String relativePath;
  final String mediaType;
  final int byteSize;
  final String digest;
}

String validateRelativePath(String path) {
  final String value = path.trim().replaceAll('\\', '/');
  final bool drivePath = RegExp(r'^[A-Za-z]:').hasMatch(value);
  if (value.isEmpty ||
      value.startsWith('/') ||
      drivePath ||
      value
          .split('/')
          .any((String part) => part.isEmpty || part == '.' || part == '..')) {
    throw const InvalidValue(
      'Attachment paths must be portable relative paths.',
    );
  }
  return value;
}

final class Reminder {
  const Reminder({
    required this.exchangeId,
    required this.requestedAt,
    required this.platformSchedulingId,
    required this.state,
  });
  final ExchangeId exchangeId;
  final DateTime requestedAt;
  final int platformSchedulingId;
  final String state;
}

final class ExchangeTransitions {
  const ExchangeTransitions({required this.clock, required this.ids});
  final Clock clock;
  final IdGenerator ids;

  (Exchange, ExchangeEvent) create({
    required ExchangeId id,
    required ItemId itemId,
    required PersonId personId,
    required ExchangeDirection direction,
    required DateTime handedOffAt,
    DateTime? dueAt,
  }) {
    if (dueAt != null && dueAt.isBefore(handedOffAt)) {
      throw const InvalidValue('Due time cannot be before handoff time.');
    }
    final DateTime now = clock.now();
    final Exchange exchange = Exchange(
      id: id,
      itemId: itemId,
      personId: personId,
      direction: direction,
      handedOffAt: handedOffAt,
      dueAt: dueAt,
      status: ExchangeStatus.open,
      returnedAt: null,
      createdAt: now,
      updatedAt: now,
    );
    return (exchange, _event(id, ExchangeEventType.created, now));
  }

  (Exchange, ExchangeEvent) edit(
    Exchange exchange, {
    DateTime? dueAt,
    bool clearDueAt = false,
  }) {
    if (exchange.status != ExchangeStatus.open) {
      throw const InvalidTransition('Only an open exchange can be edited.');
    }
    final DateTime? nextDueAt = clearDueAt ? null : dueAt ?? exchange.dueAt;
    if (nextDueAt != null && nextDueAt.isBefore(exchange.handedOffAt)) {
      throw const InvalidValue('Due time cannot be before handoff time.');
    }
    final DateTime now = clock.now();
    return (
      Exchange(
        id: exchange.id,
        itemId: exchange.itemId,
        personId: exchange.personId,
        direction: exchange.direction,
        handedOffAt: exchange.handedOffAt,
        dueAt: nextDueAt,
        status: exchange.status,
        returnedAt: null,
        createdAt: exchange.createdAt,
        updatedAt: now,
      ),
      _event(exchange.id, ExchangeEventType.edited, now),
    );
  }

  (Exchange, ExchangeEvent) markReturned(Exchange exchange) {
    if (exchange.status != ExchangeStatus.open) {
      throw const InvalidTransition('Only an open exchange can be returned.');
    }
    final DateTime now = clock.now();
    return (
      Exchange(
        id: exchange.id,
        itemId: exchange.itemId,
        personId: exchange.personId,
        direction: exchange.direction,
        handedOffAt: exchange.handedOffAt,
        dueAt: exchange.dueAt,
        status: ExchangeStatus.returned,
        returnedAt: now,
        createdAt: exchange.createdAt,
        updatedAt: now,
      ),
      _event(exchange.id, ExchangeEventType.returned, now),
    );
  }

  (Exchange, ExchangeEvent) reopen(Exchange exchange) {
    if (exchange.status != ExchangeStatus.returned) {
      throw const InvalidTransition(
        'Only a returned exchange can be reopened.',
      );
    }
    final DateTime now = clock.now();
    return (
      Exchange(
        id: exchange.id,
        itemId: exchange.itemId,
        personId: exchange.personId,
        direction: exchange.direction,
        handedOffAt: exchange.handedOffAt,
        dueAt: exchange.dueAt,
        status: ExchangeStatus.open,
        returnedAt: null,
        createdAt: exchange.createdAt,
        updatedAt: now,
      ),
      _event(exchange.id, ExchangeEventType.reopened, now),
    );
  }

  ExchangeEvent _event(ExchangeId id, ExchangeEventType type, DateTime at) =>
      ExchangeEvent(
        id: ExchangeEventId(ids.nextId()),
        exchangeId: id,
        type: type,
        occurredAt: at,
      );
}

final class ExchangeQuery {
  const ExchangeQuery({
    this.status,
    this.direction,
    this.personId,
    this.text,
    this.dueBefore,
  });
  final ExchangeStatus? status;
  final ExchangeDirection? direction;
  final PersonId? personId;
  final String? text;
  final DateTime? dueBefore;
}

abstract interface class ExchangeRepository {
  Future<void> create(
    PersonAlias person,
    Item item,
    Exchange exchange,
    ExchangeEvent event, {
    Attachment? attachment,
  });
  Future<Exchange?> get(ExchangeId id);
  Future<PersonAlias?> getPerson(PersonId id);
  Future<Item?> getItem(ItemId id);
  Future<List<Exchange>> find(ExchangeQuery query);
  Future<List<ExchangeEvent>> events(ExchangeId id);
  Future<List<Attachment>> attachments(ExchangeId id);
  Future<void> saveTransition(
    Exchange previous,
    Exchange next,
    ExchangeEvent event,
  );
  Future<void> addAttachment(Attachment attachment);
}
