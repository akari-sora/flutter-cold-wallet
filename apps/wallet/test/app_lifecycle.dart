import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Leaves the app as Android reports it when another app or the system
/// settings come to the front. A system dialog over the app, such as a
/// permission request, only makes it inactive.
void leaveApp(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

/// Comes back to the app after [leaveApp].
void returnToApp(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

/// Loses and regains input focus without leaving the app, as with the
/// notification shade or another app focused in split screen.
void loseAndRegainFocus(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}
