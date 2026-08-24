import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/domain/exchange_domain.dart';

final class FixedClock implements Clock {
  const FixedClock(this.value);
  final DateTime value;
  @override
  DateTime now() => value;
}

final class SequenceIds implements IdGenerator {
  int value = 0;
  @override
  String nextId() => 'event-${value++}';
}

void main() {
  final DateTime handoff = DateTime.utc(2026, 8, 1);
  final DateTime now = DateTime.utc(2026, 8, 10, 12);
  late ExchangeTransitions transitions;

  setUp(() {
    transitions = ExchangeTransitions(
      clock: FixedClock(now),
      ids: SequenceIds(),
    );
  });

  test('create, edit, return, and reopen produce deterministic projections and events', () {
    final (Exchange created, ExchangeEvent createdEvent) = transitions.create(
      id: ExchangeId('exchange'),
      itemId: ItemId('item'),
      personId: PersonId('person'),
      direction: ExchangeDirection.lent,
      handedOffAt: handoff,
      dueAt: DateTime.utc(2026, 8, 20),
    );
    expect(created.status, ExchangeStatus.open);
    expect(createdEvent.type, ExchangeEventType.created);
    expect(createdEvent.id.value, 'event-0');

    final (Exchange edited, ExchangeEvent editedEvent) = transitions.edit(
      created,
      dueAt: DateTime.utc(2026, 8, 22),
    );
    expect(edited.dueAt, DateTime.utc(2026, 8, 22));
    expect(editedEvent.type, ExchangeEventType.edited);

    final (Exchange returned, ExchangeEvent returnedEvent) = transitions
        .markReturned(edited);
    expect(returned.returnedAt, now);
    expect(returnedEvent.type, ExchangeEventType.returned);

    final (Exchange reopened, ExchangeEvent reopenedEvent) = transitions.reopen(
      returned,
    );
    expect(reopened.status, ExchangeStatus.open);
    expect(reopened.returnedAt, isNull);
    expect(reopenedEvent.type, ExchangeEventType.reopened);
  });

  test('invalid values and transitions expose domain errors', () {
    expect(() => PersonId('  '), throwsA(isA<InvalidValue>()));
    expect(
      () => transitions.create(
        id: ExchangeId('e'),
        itemId: ItemId('i'),
        personId: PersonId('p'),
        direction: ExchangeDirection.borrowed,
        handedOffAt: handoff,
        dueAt: handoff.subtract(const Duration(seconds: 1)),
      ),
      throwsA(isA<InvalidValue>()),
    );
    final (Exchange open, _) = transitions.create(
      id: ExchangeId('e'),
      itemId: ItemId('i'),
      personId: PersonId('p'),
      direction: ExchangeDirection.borrowed,
      handedOffAt: handoff,
    );
    expect(() => transitions.reopen(open), throwsA(isA<InvalidTransition>()));
    final (Exchange returned, _) = transitions.markReturned(open);
    expect(
      () => transitions.markReturned(returned),
      throwsA(isA<InvalidTransition>()),
    );
    expect(() => transitions.edit(returned), throwsA(isA<InvalidTransition>()));
  });

  test('due states include exact boundaries and returned precedence', () {
    const DueStatePolicy policy = DueStatePolicy(
      dueSoonWindow: Duration(days: 3),
    );
    Exchange exchange(
      DateTime? due, {
      ExchangeStatus status = ExchangeStatus.open,
    }) => Exchange(
      id: ExchangeId('e'),
      itemId: ItemId('i'),
      personId: PersonId('p'),
      direction: ExchangeDirection.lent,
      handedOffAt: handoff,
      dueAt: due,
      status: status,
      returnedAt: status == ExchangeStatus.returned ? now : null,
      createdAt: handoff,
      updatedAt: now,
    );
    expect(policy.evaluate(exchange(null), now), DueState.none);
    expect(
      policy.evaluate(
        exchange(now.subtract(const Duration(microseconds: 1))),
        now,
      ),
      DueState.overdue,
    );
    expect(policy.evaluate(exchange(now), now), DueState.dueSoon);
    expect(
      policy.evaluate(exchange(now.add(const Duration(days: 3))), now),
      DueState.dueSoon,
    );
    expect(
      policy.evaluate(
        exchange(now.add(const Duration(days: 3, microseconds: 1))),
        now,
      ),
      DueState.upcoming,
    );
    expect(
      policy.evaluate(
        exchange(
          now.subtract(const Duration(days: 1)),
          status: ExchangeStatus.returned,
        ),
        now,
      ),
      DueState.returned,
    );
  });

  test('attachment paths reject absolute and traversal forms', () {
    for (final String path in <String>[
      '/data/user/photo.jpg',
      r'C:\photos\x.jpg',
      'C:photo.jpg',
      '../x',
      'a/../x',
    ]) {
      expect(
        () => validateRelativePath(path),
        throwsA(isA<InvalidValue>()),
        reason: path,
      );
    }
    expect(
      validateRelativePath(r'attachments\exchange-1\photo.jpg'),
      'attachments/exchange-1/photo.jpg',
    );
  });
}
