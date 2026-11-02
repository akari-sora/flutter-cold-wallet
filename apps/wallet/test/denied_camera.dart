import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers the camera plugin's channels as a device whose camera permission
/// is denied, so a scanner route can be opened without a camera or plugin.
void mockDeniedCamera(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  const method = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
  const events = EventChannel('dev.steenbakker.mobile_scanner/scanner/event');
  messenger.setMockMethodCallHandler(
      method,
      (call) async => switch (call.method) {
            'state' => 2,
            'request' => false,
            _ => null,
          });
  messenger.setMockStreamHandler(
      events, MockStreamHandler.inline(onListen: (_, __) {}));
  addTearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });
}

/// Answers the camera plugin like a device whose camera permission is not
/// granted yet: the start asks for it and the returned completer is the
/// system dialog, answered by the test.
Completer<bool> mockCameraPermissionDialog(WidgetTester tester) {
  final dialog = Completer<bool>();
  final messenger = tester.binding.defaultBinaryMessenger;
  const method = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
  const events = EventChannel('dev.steenbakker.mobile_scanner/scanner/event');
  messenger.setMockMethodCallHandler(
      method,
      (call) async => switch (call.method) {
            'state' => 2,
            'request' => dialog.future,
            _ => null,
          });
  messenger.setMockStreamHandler(
      events, MockStreamHandler.inline(onListen: (_, __) {}));
  addTearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });
  return dialog;
}

/// Answers the camera plugin like a device whose camera permission is
/// already granted; the camera starts only when the returned completer does.
Completer<void> mockSlowGrantedCamera(WidgetTester tester) {
  final started = Completer<void>();
  final messenger = tester.binding.defaultBinaryMessenger;
  const method = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
  const events = EventChannel('dev.steenbakker.mobile_scanner/scanner/event');
  messenger.setMockMethodCallHandler(method, (call) async {
    switch (call.method) {
      case 'state':
        return 1;
      case 'start':
        await started.future;
        return {
          'textureId': 1,
          'numberOfCameras': 1,
          'size': {'width': 640.0, 'height': 480.0}
        };
    }
    return null;
  });
  messenger.setMockStreamHandler(
      events, MockStreamHandler.inline(onListen: (_, __) {}));
  addTearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });
  return started;
}

/// Answers the camera plugin like a device whose camera permission is not
/// granted yet. The first completer is the system dialog; once it allows the
/// camera, the camera starts only when the second one does.
(Completer<bool>, Completer<void>) mockCameraPermissionThenSlowStart(
    WidgetTester tester) {
  final dialog = Completer<bool>();
  final started = Completer<void>();
  final messenger = tester.binding.defaultBinaryMessenger;
  const method = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
  const events = EventChannel('dev.steenbakker.mobile_scanner/scanner/event');
  var granted = false;
  messenger.setMockMethodCallHandler(method, (call) async {
    switch (call.method) {
      case 'state':
        return granted ? 1 : 2;
      case 'request':
        return granted = await dialog.future;
      case 'start':
        await started.future;
        return {
          'textureId': 1,
          'numberOfCameras': 1,
          'size': {'width': 640.0, 'height': 480.0}
        };
    }
    return null;
  });
  messenger.setMockStreamHandler(
      events, MockStreamHandler.inline(onListen: (_, __) {}));
  addTearDown(() {
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(events, null);
  });
  return (dialog, started);
}
