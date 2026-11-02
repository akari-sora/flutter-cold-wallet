import 'package:flutter_test/flutter_test.dart';

/// Worker isolates use real events; pumpAndSettle alone advances fake time and
/// can finish before compute returns (or time out on its progress animation).
Future<void> waitForNativeWidgetWork(
    WidgetTester tester, bool Function() completed) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  do {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (completed()) {
      await tester.pumpAndSettle();
      return;
    }
  } while (DateTime.now().isBefore(deadline));
  fail('Native worker did not complete within 10 seconds');
}
