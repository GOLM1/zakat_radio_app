import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zakat_radio_app/main.dart';

void main() {
  testWidgets('radio home shows modern playback UI', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('إذاعة\nصندوق الزكاة الليبي'), findsOneWidget);
    expect(find.text('البث المباشر'), findsOneWidget);
    expect(find.text('تشغيل البث'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
  });
}
