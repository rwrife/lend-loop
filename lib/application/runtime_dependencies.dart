import 'dart:math';

import 'package:lend_loop/domain/exchange_domain.dart';

final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

final class SecureIdGenerator implements IdGenerator {
  SecureIdGenerator({Random? random, int Function()? microseconds})
    : _random = random ?? Random.secure(),
      _microseconds =
          microseconds ?? (() => DateTime.now().microsecondsSinceEpoch);

  final Random _random;
  final int Function() _microseconds;

  @override
  String nextId() =>
      '${_microseconds().toRadixString(36)}-'
      '${_random.nextInt(0x7fffffff).toRadixString(36)}-'
      '${_random.nextInt(0x7fffffff).toRadixString(36)}';
}
