import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_ui/qr_ui.dart';
import 'native_widget_wait.dart';

// Only the camera platform is replaced. UR decoding calls the real host native
// library; on Windows set WALLET_FFI_PATH to a built wallet_ffi.dll.
const badChecksum =
    'ur:eth-sign-request/taadmeonadtpdagdatatatatatatatatatatatatatatatataohddkaovolfkninlaadaolsadlnnbmwbybybybybybybybybybybybybybybybybybybybylalartaxaaaacfkninahtaaddyoyadlecsdwykcsfnykaeykaewkaewkrlhlsemk';
const canonical =
    'ur:eth-sign-request/taadmeonadtpdagdadadadadadadadadadadadadadadadadaohddkaovolfkninlaadaolsadlnnbmwbybybybybybybybybybybybybybybybybybybybylalartaxaaaacfkninahtaaddyoyadlecsdwykcsfnykaeykaewkaewkftaacsaa';
const payloadHex =
    'd90191a501d825500101010101010101010101010101010102582402e2827a69800102830186a09411111111111111111111111111111111111111118080c0030404197a6905d90130a1018a182cf5183cf500f500f400f4';

class NoCamera extends MobileScannerPlatform {
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async =>
      const MobileScannerViewAttributes(
          cameraDirection: CameraFacing.back,
          currentTorchMode: TorchState.unavailable, size: Size(640, 480));
  @override
  Future<void> stop() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async {}
}

class Harness {
  final navigator = GlobalKey<NavigatorState>();
  final payloads = <List<int>>[];
  final rawRequests = <String>[];

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => AirGapScanner(
                      expectedType: 'eth-sign-request',
                      onPayloadComplete: payloads.add,
                      onRawUrComplete: (raw) {
                        rawRequests.add(raw);
                        Navigator.of(context).pop();
                      },
                    ),
                  )),
                  child: const Text('home'),
                ),
              )),
    ));
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
  }
}

Future<void> enter(WidgetTester tester, String ur) async {
  if (find.byType(AlertDialog).evaluate().isEmpty) {
    await tester.tap(find.byTooltip('手動貼上 UR'));
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byKey(const Key('manual_ur_input_field')), ur);
}

Future<void> submit(WidgetTester tester, {bool rejected = false}) async {
  await tester.tap(find.byKey(const Key('manual_ur_submit_btn')));
  // Includes the outgoing DialogRoute animation, when the TextField may still
  // rebuild after showDialog's result Future has already completed.
  await waitForNativeWidgetWork(tester, () {
    final buttons = find.byKey(const Key('manual_ur_submit_btn')).evaluate();
    return buttons.isEmpty ||
        (buttons.single.widget as ElevatedButton).onPressed != null;
  });
  expect(tester.takeException(), isNull);
  expect(find.byType(AlertDialog), rejected ? findsOneWidget : findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileScannerPlatform originalPlatform;
  setUp(() {
    originalPlatform = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = NoCamera();
  });
  tearDown(() => MobileScannerPlatform.instance = originalPlatform);

  testWidgets('bad checksum stays in scanner with error and cancel available',
      (tester) async {
    final harness = Harness();
    await harness.open(tester);
    await enter(tester, badChecksum);
    await submit(tester, rejected: true);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('manual_ur_input_field')))
            .controller!
            .text,
        badChecksum);
    expect(find.textContaining('invalid checksum'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消掃描').hitTestable(), findsOneWidget);
    expect(harness.payloads, isEmpty);
    expect(harness.rawRequests, isEmpty);
    await tester.tap(find.byTooltip('取消掃描'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled manual dialog can reopen with a fresh input field',
      (tester) async {
    final harness = Harness();
    await harness.open(tester);
    await enter(tester, badChecksum);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(harness.payloads, isEmpty);
    expect(harness.rawRequests, isEmpty);
    await tester.tap(find.byTooltip('手動貼上 UR'));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('manual_ur_input_field'));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.enterText(field, canonical);
    await submit(tester);
    expect(harness.rawRequests, [canonical]);
    expect(harness.payloads, hasLength(1));
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('checksum rejection allows a valid request in the same scanner',
      (tester) async {
    final harness = Harness();
    await harness.open(tester);
    final scannerState = tester.state(find.byType(AirGapScanner));
    await enter(tester, badChecksum);
    await submit(tester, rejected: true);
    expect(find.textContaining('invalid checksum'), findsWidgets);
    expect(harness.payloads, isEmpty);
    expect(harness.rawRequests, isEmpty);
    await enter(tester, canonical);
    expect(tester.state(find.byType(AirGapScanner)), same(scannerState));
    await submit(tester);
    expect(harness.rawRequests, [canonical]);
    expect(harness.payloads, hasLength(1));
    expect(
        harness.payloads.single
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        payloadHex);
    expect(find.textContaining('invalid checksum'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('blank manual input stays editable with an explicit error',
      (tester) async {
    final harness = Harness();
    await harness.open(tester);
    await enter(tester, '  ');
    await submit(tester, rejected: true);
    expect(find.text('請輸入或貼上 UR 字串／多幀清單。'), findsOneWidget);
    expect(harness.payloads, isEmpty);
    await enter(tester, canonical);
    await submit(tester);
    expect(harness.rawRequests, [canonical]);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('removing scanner with an open dialog never submits its text',
      (tester) async {
    final harness = Harness();
    await harness.open(tester);
    await enter(tester, canonical);
    harness.navigator.currentState!.popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(harness.payloads, isEmpty);
    expect(harness.rawRequests, isEmpty);
  });
}
