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
const _settingsButton = Key('scanner_open_app_settings_btn');

/// mobile_scanner's real platform side over a synthetic plugin channel: the
/// scanner asks for the camera itself and records a denial, so the paths
/// after a denial run on that record rather than on start()'s.
class _Plugin {
  _Plugin(WidgetTester tester) {
    MobileScannerPlatform.instance = MethodChannelMobileScanner();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'state':
          return granted ? 1 : 2;
        case 'request':
          if (requestThrows) {
            throw PlatformException(
                code: 'MOBILE_SCANNER_CAMERA_PERMISSION_REQUEST_PENDING');
          }
          return granted;
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
  }

  bool granted = false;
  bool requestThrows = false;
  bool running = false;
  final calls = <String>[];
  int count(String method) => calls.where((c) => c == method).length;
}

/// Leaves the app, e.g. for the system settings, and comes back.
Future<void> _leaveAndReturn(WidgetTester tester,
    {void Function()? away}) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
  away?.call();
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, {List<bool>? reports}) async {
  await tester.pumpWidget(MaterialApp(
      home: AirGapScanner(
          expectedType: 'eth-signature',
          onPayloadComplete: (_) {},
          onOpenAppSettings: () async {},
          onPermissionRequest: reports?.add)));
  await tester.pumpAndSettle();
}

void main() {
  late MobileScannerPlatform originalPlatform;
  setUp(() => originalPlatform = MobileScannerPlatform.instance);
  tearDown(() => MobileScannerPlatform.instance = originalPlatform);

  testWidgets('a camera enabled in the settings scans after the return',
      (tester) async {
    final plugin = _Plugin(tester);
    await _open(tester);
    expect(plugin.count('request'), 1);
    expect(find.textContaining('返回後即可掃描'), findsOneWidget);
    expect(find.byKey(_settingsButton), findsOneWidget);
    await _leaveAndReturn(tester, away: () => plugin.granted = true);
    expect(plugin.running, isTrue);
    expect(find.textContaining('返回後即可掃描'), findsNothing);
    expect(find.byKey(_settingsButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(plugin.running, isFalse);
  });

  testWidgets(
      'a denied camera is not asked for in a loop; a return and the retry '
      'ask once each', (tester) async {
    final plugin = _Plugin(tester);
    await _open(tester);
    for (var i = 0; i < 5; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }
    expect(plugin.count('request'), 1);
    await _leaveAndReturn(tester);
    expect(plugin.count('request'), 2);
    await tester.tap(find.text('清除並重新掃描'));
    await tester.pumpAndSettle();
    expect(plugin.count('request'), 3);
    expect(plugin.calls, isNot(contains('start')));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling manual input does not ask for a denied camera again',
      (tester) async {
    final plugin = _Plugin(tester);
    await _open(tester);
    await tester.tap(find.byKey(const Key('manual_ur_dialog_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(plugin.count('request'), 1);
    expect(find.textContaining('返回後即可掃描'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a request that throws ends the report and is left to start()',
      (tester) async {
    final plugin = _Plugin(tester)..requestThrows = true;
    final reports = <bool>[];
    await _open(tester, reports: reports);
    expect(reports, [true, false],
        reason: 'The report must end even when the request throws');
    expect(plugin.count('request'), 2, reason: 'start() asks a second time');
    expect(find.textContaining('genericError'), findsOneWidget,
        reason: 'A failed request is not recorded as a denial');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
