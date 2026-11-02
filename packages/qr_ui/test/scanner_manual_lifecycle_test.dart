import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_ui/qr_ui.dart';

import 'manual_ur_error_test.dart' show badChecksum, canonical;
import 'native_widget_wait.dart';

// The camera is synthetic. Decoding uses the existing public UR fixture and
// host native decoder; no device, key intake, or signing is involved.
class StreamCamera extends MobileScannerPlatform {
  static const publicCapture = BarcodeCapture(
    barcodes: [Barcode(format: BarcodeFormat.qrCode, rawValue: canonical)],
  );
  final captures = StreamController<BarcodeCapture?>.broadcast();
  bool running = false;

  void emitPublicQr() => captures.add(publicCapture);

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    running = true;
    return const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.unavailable, size: Size(640, 480));
  }

  @override
  Future<void> stop() async => running = false;
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async => running = false;
}

class ScannerHarness {
  final payloads = <List<int>>[];
  final rawRequests = <String>[];

  Future<void> open(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AirGapScanner(
        expectedType: 'eth-sign-request',
        onPayloadComplete: payloads.add,
        onRawUrComplete: rawRequests.add,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openManualDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('手動貼上 UR'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileScannerPlatform originalPlatform;
  late StreamCamera camera;

  setUp(() {
    originalPlatform = MobileScannerPlatform.instance;
    camera = StreamCamera();
    MobileScannerPlatform.instance = camera;
  });
  tearDown(() async {
    MobileScannerPlatform.instance = originalPlatform;
    await camera.captures.close();
  });

  testWidgets('public camera fixture completes without a manual dialog',
      (tester) async {
    final harness = ScannerHarness();
    await harness.open(tester);
    expect(camera.running, isTrue);
    camera.emitPublicQr();
    await waitForNativeWidgetWork(tester, () => harness.payloads.isNotEmpty);
    expect(harness.payloads, hasLength(1));
    expect(harness.rawRequests, [canonical]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('camera cannot complete while manual input is being edited',
      (tester) async {
    final harness = ScannerHarness();
    await harness.open(tester);
    await harness.openManualDialog(tester);
    expect(camera.running, isFalse);
    await tester.enterText(
        find.byKey(const Key('manual_ur_input_field')), 'unfinished draft');

    camera.emitPublicQr();
    // Also deliver a callback already queued before the camera stopped.
    tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .onDetect!(StreamCamera.publicCapture);
    await tester.pumpAndSettle();
    expect(harness.payloads, isEmpty,
        reason: 'A modal manual editor must own input until it is dismissed.');
    expect(harness.rawRequests, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('manual_ur_input_field')))
            .controller!
            .text,
        'unfinished draft');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    camera.emitPublicQr();
    await waitForNativeWidgetWork(tester, () => harness.payloads.isNotEmpty);
    expect(harness.payloads, hasLength(1));
    expect(harness.rawRequests, [canonical]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful manual input completes once and keeps camera stopped',
      (tester) async {
    final harness = ScannerHarness();
    await harness.open(tester);
    await harness.openManualDialog(tester);
    await tester.enterText(
        find.byKey(const Key('manual_ur_input_field')), canonical);
    await tester.tap(find.byKey(const Key('manual_ur_submit_btn')));
    await waitForNativeWidgetWork(tester, () => harness.payloads.isNotEmpty);

    expect(harness.payloads, hasLength(1));
    expect(harness.rawRequests, [canonical]);
    expect(camera.running, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    camera.emitPublicQr();
    await tester.pumpAndSettle();
    expect(harness.payloads, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'invalid manual draft keeps camera paused until explicitly cancelled',
      (tester) async {
    final harness = ScannerHarness();
    await harness.open(tester);
    await harness.openManualDialog(tester);
    await tester.enterText(
        find.byKey(const Key('manual_ur_input_field')), badChecksum);
    await tester.tap(find.byKey(const Key('manual_ur_submit_btn')));
    await waitForNativeWidgetWork(tester,
        () => find.textContaining('invalid checksum').evaluate().isNotEmpty);

    expect(find.textContaining('invalid checksum'), findsWidgets);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('manual_ur_input_field')))
            .controller!
            .text,
        badChecksum);
    expect(harness.payloads, isEmpty);
    expect(harness.rawRequests, isEmpty);
    expect(camera.running, isFalse);
    camera.emitPublicQr();
    await tester.pumpAndSettle();
    expect(harness.payloads, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(camera.running, isTrue);
    camera.emitPublicQr();
    await waitForNativeWidgetWork(tester, () => harness.payloads.isNotEmpty);
    expect(harness.payloads, hasLength(1));
    expect(harness.rawRequests, [canonical]);
    expect(find.textContaining('invalid checksum'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing manual dialog after resume restores camera scanning',
      (tester) async {
    final harness = ScannerHarness();
    await harness.open(tester);
    await harness.openManualDialog(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.running, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(camera.running, isTrue,
        reason: 'Returning to the scanner must not require an extra reset.');
    camera.emitPublicQr();
    await waitForNativeWidgetWork(tester, () => harness.payloads.isNotEmpty);
    expect(harness.payloads, hasLength(1));
    expect(harness.rawRequests, [canonical]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual editor fits a narrow phone with IME and large text',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final harness = ScannerHarness();
    await harness.open(tester, textScale: 2);
    await harness.openManualDialog(tester);
    await tester.showKeyboard(find.byKey(const Key('manual_ur_input_field')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'The editor and its actions must remain usable above the IME.');
    expect(find.byKey(const Key('manual_ur_submit_btn')).hitTestable(),
        findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);
  });
}
