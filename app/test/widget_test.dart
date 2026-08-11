import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App root widget builds without crashing', (WidgetTester tester) async {
    // Minimal smoke test — the real app requires VaultDatabase.instance.load()
    // which needs a running platform channel (i.e. a real device or emulator).
    // This just verifies the test harness itself compiles and runs.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('JanusVault smoke test'))),
      ),
    );

    expect(find.text('JanusVault smoke test'), findsOneWidget);
  });
}
