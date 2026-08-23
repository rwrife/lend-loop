import 'package:flutter_test/flutter_test.dart';
import 'package:lend_loop/app/development_status.dart';

void main() {
  test('current status describes the pre-release product honestly', () {
    const DevelopmentStatus status = DevelopmentStatus.current;

    expect(status.productName, 'Lend Loop');
    expect(status.headline, 'Under development');
    expect(status.detail, contains('offline'));
  });
}
