import 'package:fastride/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the ride app', (WidgetTester tester) async {
    await tester.pumpWidget(const RideApp());

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
