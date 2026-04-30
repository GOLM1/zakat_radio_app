import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release assets exist', () {
    expect(File('assets/images/logo.png').existsSync(), isTrue);
    expect(File('assets/images/wasl.png').existsSync(), isTrue);
    expect(File('assets/images/now_playing.png').existsSync(), isTrue);
  });
}
