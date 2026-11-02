import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/method_channel/mobile_scanner_method_channel.dart';
import 'package:qr_ui/qr_ui.dart';

const _method = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
const _events = EventChannel('dev.steenbakker.mobile_scanner/scanner/event');
const _orientation = EventChannel(
    'dev.steenbakker.mobile_scanner/scanner/deviceOrientation');

/// mobile_scanner's real platform side, shared by every controller, over a
/// synthetic plugin channel the test controls.
class _Plugin {
  _Plugin(WidgetTester tester, {this.authorization = 1}) {
    MobileScannerPlatform.instance = MethodChannelMobileScanner();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'state':
          await stateGate?.future;
          return authorization;
        case 'request':
          return dialog.future;
        case 'start':
          await startGate?.future;
          running = true;
          return {
            'textureId': 7,
            'numberOfCameras': 1,
            'cameraDirection': 1,
            'initialDeviceOrientation': 'PORTRAIT_UP',
            'handlesCropAndRotation': true,
            'naturalDeviceOrientation': 'PORTRAIT_UP',
            'sensorOrientation': 90,
            'size': {'width': 640.0, 'height': 480.0}
          };
        case 'stop':
          running = false;
      }
      return null;
    });
    messenger.setMockStreamHandler(
        _events, MockStreamHandler.inline(onListen: (_, __) {}));
    messenger.setMockStreamHandler(
        _orientation, MockStreamHandler.inline(onListen: (_, __) {}));
    addTearDown(() {
      messenger.setMockMethodCallHandler(_method, null);
      messenger.setMockStreamHandler(_events, null);
      messenger.setMockStreamHandler(_orientation, null);
    });
  }

  /// mobile_scanner's authorization state: 1 granted, 2 denied.
  int authorization;
  final dialog = Completer<bool>();
  Completer<void>? stateGate;
  Completer<void>? startGate;
  bool running = false;
  final calls = <String>[];
}

/// An adversarial one-camera platform: a start meeting a running camera
/// fails with controllerAlreadyInitialized, and any dispose stops the camera.
/// It retains legacy shared-disposal behavior so FCW's interleaving guard is
/// exercised independently of the current method-channel implementation.
class _OneCameraPlatform extends MobileScannerPlatform {
  bool running = false;
  final calls = <String>[];

  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox();
  @override
  Future<void> updateScanWindow(Rect? window) async {}

  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    calls.add('start');
    if (running) {
      throw const MobileScannerException(
          errorCode: MobileScannerErrorCode.controllerAlreadyInitialized);
    }
    running = true;
    return const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.unavailable,
        numberOfCameras: 1,
        size: Size(640, 480));
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    running = false;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    running = false;
  }
}

Widget _scanner(String key, {ValueChanged<bool>? onPermissionRequest}) =>
    MaterialApp(
        home: AirGapScanner(
            key: Key(key),
            expectedType: 'eth-signature',
            onPayloadComplete: (_) {},
            onPermissionRequest: onPermissionRequest));

void main() {
  late MobileScannerPlatform originalPlatform;
  setUp(() => originalPlatform = MobileScannerPlatform.instance);
  tearDown(() => MobileScannerPlatform.instance = originalPlatform);

  testWidgets(
      'a scanner removed during the permission dialog leaves no camera running',
      (tester) async {
    // mobile_scanner's real platform side, shared by every controller, over
    // a synthetic plugin whose permission dialog the test answers.
    MobileScannerPlatform.instance = MethodChannelMobileScanner();
    var authorization = 2; // denied: start() asks again
    var dialog = Completer<bool>();
    var running = false;
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'state':
          return authorization;
        case 'request':
          return dialog.future;
        case 'start':
          running = true;
          return {
            'textureId': 7,
            'numberOfCameras': 1,
            'cameraDirection': 1,
            'initialDeviceOrientation': 'PORTRAIT_UP',
            'handlesCropAndRotation': true,
            'naturalDeviceOrientation': 'PORTRAIT_UP',
            'sensorOrientation': 90,
            'size': {'width': 640.0, 'height': 480.0}
          };
        case 'stop':
          running = false;
      }
      return null;
    });
    messenger.setMockStreamHandler(
        _events, MockStreamHandler.inline(onListen: (_, __) {}));
    messenger.setMockStreamHandler(
        _orientation, MockStreamHandler.inline(onListen: (_, __) {}));
    addTearDown(() {
      messenger.setMockMethodCallHandler(_method, null);
      messenger.setMockStreamHandler(_events, null);
      messenger.setMockStreamHandler(_orientation, null);
    });
    Widget scanner() => MaterialApp(
        home: AirGapScanner(
            expectedType: 'eth-signature', onPayloadComplete: (_) {}));

    await tester.pumpWidget(scanner());
    await tester.pump();
    expect(calls, contains('request'), reason: 'The dialog is open');

    // The screen removes the scanner while the dialog is still open, then
    // the user allows the camera.
    await tester.pumpWidget(const SizedBox());
    authorization = 1;
    dialog.complete(true);
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('start')),
        reason: 'The late answer must not start the camera');
    expect(running, isFalse);

    // The next scanner starts normally.
    dialog = Completer<bool>();
    await tester.pumpWidget(scanner());
    await tester.pumpAndSettle();
    expect(running, isTrue);
    expect(find.textContaining('無法使用相機'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(running, isFalse);
  });

  testWidgets(
      'a scanner removed during its permission dialog cannot stop a newer one',
      (tester) async {
    MobileScannerPlatform.instance = MethodChannelMobileScanner();
    var authorization = 2; // denied: start() asks
    final dialog = Completer<bool>();
    var running = false;
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'state':
          return authorization;
        case 'request':
          return dialog.future;
        case 'start':
          running = true;
          return {
            'textureId': 7,
            'numberOfCameras': 1,
            'cameraDirection': 1,
            'initialDeviceOrientation': 'PORTRAIT_UP',
            'handlesCropAndRotation': true,
            'naturalDeviceOrientation': 'PORTRAIT_UP',
            'sensorOrientation': 90,
            'size': {'width': 640.0, 'height': 480.0}
          };
        case 'stop':
          running = false;
      }
      return null;
    });
    messenger.setMockStreamHandler(
        _events, MockStreamHandler.inline(onListen: (_, __) {}));
    messenger.setMockStreamHandler(
        _orientation, MockStreamHandler.inline(onListen: (_, __) {}));
    addTearDown(() {
      messenger.setMockMethodCallHandler(_method, null);
      messenger.setMockStreamHandler(_events, null);
      messenger.setMockStreamHandler(_orientation, null);
    });

    // A waits for its permission dialog.
    await tester.pumpWidget(MaterialApp(
        home: AirGapScanner(
            key: const Key('a'),
            expectedType: 'eth-signature',
            onPayloadComplete: (_) {})));
    await tester.pump();
    expect(calls, contains('request'));

    // A is replaced by B before its dialog is answered, and the camera is
    // allowed meanwhile (e.g. in the settings); then A's answer arrives.
    authorization = 1;
    await tester.pumpWidget(MaterialApp(
        home: AirGapScanner(
            key: const Key('b'),
            expectedType: 'eth-signature',
            onPayloadComplete: (_) {})));
    await tester.pump();
    dialog.complete(true);
    await tester.pumpAndSettle();
    expect(running, isTrue, reason: "A's cleanup must not stop B's camera");
    expect(calls.last, 'start');
    expect(find.textContaining('無法使用相機'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(running, isFalse);
  });

  testWidgets('a slow start with the camera already granted asks nothing',
      (tester) async {
    final plugin = _Plugin(tester)..startGate = Completer<void>();
    final reports = <bool>[];
    await tester.pumpWidget(_scanner('a', onPermissionRequest: reports.add));
    await tester.pump();
    expect(plugin.calls, contains('start'));
    expect(reports, isEmpty, reason: 'No permission dialog can be open');
    plugin.startGate!.complete();
    await tester.pumpAndSettle();
    expect(plugin.running, isTrue);
    expect(reports, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('only a start that asks for the camera is reported',
      (tester) async {
    final plugin = _Plugin(tester, authorization: 2);
    final reports = <bool>[];
    await tester.pumpWidget(_scanner('a', onPermissionRequest: reports.add));
    await tester.pump();
    expect(plugin.calls, contains('request'));
    expect(reports, [true], reason: 'The permission dialog is open');
    plugin.authorization = 1;
    plugin.dialog.complete(true);
    await tester.pumpAndSettle();
    expect(plugin.running, isTrue);
    expect(reports, [true, false]);
    expect(plugin.calls.where((c) => c == 'request'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('the report ends with the answer, before the camera starts',
      (tester) async {
    final plugin = _Plugin(tester, authorization: 2)
      ..startGate = Completer<void>();
    final reports = <bool>[];
    await tester.pumpWidget(_scanner('a', onPermissionRequest: reports.add));
    await tester.pump();
    expect(reports, [true]);
    plugin.authorization = 1;
    plugin.dialog.complete(true);
    await tester.pump();
    await tester.pump();
    expect(plugin.calls, contains('start'), reason: 'The camera is starting');
    expect(plugin.running, isFalse);
    expect(reports, [true, false],
        reason: 'No dialog is open while the camera starts');
    plugin.startGate!.complete();
    await tester.pumpAndSettle();
    expect(plugin.running, isTrue);
    expect(reports, [true, false]);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a denied request is recorded without asking again',
      (tester) async {
    final plugin = _Plugin(tester, authorization: 2);
    final reports = <bool>[];
    await tester.pumpWidget(_scanner('a', onPermissionRequest: reports.add));
    await tester.pump();
    plugin.dialog.complete(false);
    await tester.pumpAndSettle();
    expect(plugin.calls.where((c) => c == 'request'), hasLength(1));
    expect(plugin.calls, isNot(contains('start')));
    expect(reports, [true, false]);
    expect(find.textContaining('無法使用相機：permissionDenied'), findsOneWidget,
        reason: 'The denied camera is explained, not a generic error');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final granted in [true, false]) {
    testWidgets(
        'a scanner removed during its permission check neither asks nor '
        'starts (${granted ? 'granted' : 'denied'})', (tester) async {
      final plugin = _Plugin(tester, authorization: granted ? 1 : 2)
        ..stateGate = Completer<void>();
      final reports = <bool>[];
      await tester.pumpWidget(_scanner('a', onPermissionRequest: reports.add));
      await tester.pump();
      expect(plugin.calls, contains('state'), reason: 'The check is pending');
      await tester.pumpWidget(const SizedBox());
      plugin.stateGate!.complete();
      await tester.pumpAndSettle();
      expect(plugin.calls, isNot(contains('request')));
      expect(plugin.calls, isNot(contains('start')));
      expect(plugin.running, isFalse);
      expect(reports, isEmpty);
    });
  }

  testWidgets('a start waiting behind another scanner is not reported',
      (tester) async {
    final plugin = _Plugin(tester, authorization: 2);
    await tester.pumpWidget(_scanner('a'));
    await tester.pump();
    expect(plugin.calls, contains('request'), reason: "A's dialog is open");
    final reports = <bool>[];
    await tester.pumpWidget(_scanner('b', onPermissionRequest: reports.add));
    await tester.pump();
    expect(reports, isEmpty, reason: 'B only waits for A to finish');
    plugin.authorization = 1;
    plugin.dialog.complete(true);
    await tester.pumpAndSettle();
    expect(plugin.running, isTrue);
    expect(reports, isEmpty, reason: 'B starts with the camera granted');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a scanner route still animating out cannot stop the next one',
      (tester) async {
    final plugin = _Plugin(tester);
    final navigator = GlobalKey<NavigatorState>();
    Route<void> route(String key) => MaterialPageRoute(
        builder: (_) => AirGapScanner(
            key: Key(key),
            expectedType: 'eth-signature',
            onPayloadComplete: (_) {}));
    await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()));
    unawaited(navigator.currentState!.push(route('a')));
    await tester.pumpAndSettle();
    expect(plugin.running, isTrue);

    // 取消掃描 stops A's camera and pops; A stays mounted while it animates
    // out, and B opens meanwhile.
    tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
        .onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('a')), findsOneWidget);
    unawaited(navigator.currentState!.push(route('b')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(plugin.running, isTrue, reason: 'B started its camera');

    // A's exit animation ends and A is disposed.
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('a')), findsNothing);
    expect(plugin.running, isTrue, reason: "A's disposal must not stop B");
    expect(find.textContaining('無法使用相機'), findsNothing);

    tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
        .onPressed!();
    await tester.pumpAndSettle();
    expect(plugin.running, isFalse);
  });
  testWidgets('a start refused by a running camera does not take it over',
      (tester) async {
    final platform = _OneCameraPlatform();
    MobileScannerPlatform.instance = platform;
    final navigator = GlobalKey<NavigatorState>();
    Route<void> route(String key) => MaterialPageRoute(
        builder: (_) => AirGapScanner(
            key: Key(key),
            expectedType: 'eth-signature',
            onPayloadComplete: (_) {}));
    await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()));
    unawaited(navigator.currentState!.push(route('a')));
    await tester.pumpAndSettle();
    expect(platform.running, isTrue);

    // The system back button pops A without 取消掃描, so A's camera runs
    // while A animates out, and B's start meets it.
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    unawaited(navigator.currentState!.push(route('b')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(platform.calls.where((c) => c == 'start'), hasLength(2));
    expect(platform.running, isTrue, reason: "Still A's camera");

    // A is disposed once its exit animation ends: it still owns the camera,
    // since B never started one, so it must stop it.
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('a')), findsNothing);
    expect(platform.running, isFalse,
        reason: "A's disposal must stop the camera B could not take over");

    // B recovers with 清除並重新掃描.
    await tester.tap(find.text('清除並重新掃描'));
    await tester.pumpAndSettle();
    expect(platform.running, isTrue);
    await tester.tap(find.byTooltip('取消掃描'));
    await tester.pumpAndSettle();
    expect(platform.running, isFalse);
  });
}
