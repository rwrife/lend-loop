import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/application/runtime_dependencies.dart';
import 'package:lend_loop/domain/exchange_domain.dart';

void main() {
  test('secure ID generator creates compact unique portable IDs', () {
    final IdGenerator ids = SecureIdGenerator(
      random: Random(7),
      microseconds: () => 123456789,
    );

    final Set<String> values = <String>{
      for (int index = 0; index < 100; index += 1) ids.nextId(),
    };

    expect(values, hasLength(100));
    expect(values.every((String value) => value.length <= 128), isTrue);
    expect(values.every((String value) => !value.contains('/')), isTrue);
  });

  test('system clock returns a current instant', () {
    final DateTime before = DateTime.now();
    final DateTime actual = const SystemClock().now();
    final DateTime after = DateTime.now();

    expect(actual.isBefore(before), isFalse);
    expect(actual.isAfter(after), isFalse);
  });
}
