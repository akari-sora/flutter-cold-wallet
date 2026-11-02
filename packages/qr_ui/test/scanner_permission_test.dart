import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_ui/qr_ui.dart';

// A synthetic camera whose permission is denied until the test grants it,
// as after the user enables the camera in the system settings.
class _PermissionCamera extends MobileScannerPlatform {
  bool granted = false;
  bool running = false;

  /// Start attempts; each one requests the permission while it is denied.
  int starts = 0;

  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox.expand();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    if (!granted) {
      throw const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied);
    }
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

const _defaultMessage = '無法使用相機：permissionDenied。請檢查相機權限，或使用手動輸入。';
const _settingsButton = Key('scanner_open_app_settings_btn');
const _panel = Key('scanner_status_panel');
const _title = '掃描氣隙二維碼 (Air-Gap Scanner)';

Future<void> _open(WidgetTester tester,
    {AsyncCallback? onOpenAppSettings, String? deniedPermissionHint}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 640);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: AirGapScanner(
      expectedType: 'eth-sign-request',
      onPayloadComplete: (_) {},
      onOpenAppSettings: onOpenAppSettings,
      deniedPermissionHint: deniedPermissionHint,
    ),
  ));
  await tester.pumpAndSettle();
}

/// Leaves the app for another screen, such as the system settings, and
/// comes back; [away] runs while the app is hidden.
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

/// The camera message must be wholly reachable between the title and the
/// bottom panel: on screen, or scrollable into view with nothing over it.
Future<void> _expectReachableAbovePanel(
    WidgetTester tester, Finder message) async {
  final scroll = find.ancestor(of: message, matching: find.byType(Scrollable));
  expect(scroll, findsOneWidget, reason: 'A long message must scroll');
  final viewport = tester.getRect(scroll);
  expect(viewport.top,
      greaterThanOrEqualTo(tester.getRect(find.text(_title)).bottom));
  expect(viewport.bottom,
      lessThanOrEqualTo(tester.getRect(find.byKey(_panel)).top));
  final position = tester.state<ScrollableState>(scroll).position;
  expect(tester.getRect(message).top, greaterThanOrEqualTo(viewport.top));
  position.jumpTo(position.maxScrollExtent);
  await tester.pump();
  expect(tester.getRect(message).bottom, lessThanOrEqualTo(viewport.bottom));
  position.jumpTo(0);
  await tester.pump();
}

void main() {
  late MobileScannerPlatform originalPlatform;
  late _PermissionCamera camera;

  setUp(() {
    originalPlatform = MobileScannerPlatform.instance;
    camera = _PermissionCamera();
    MobileScannerPlatform.instance = camera;
  });
  tearDown(() => MobileScannerPlatform.instance = originalPlatform);

  testWidgets('denied camera without a settings action keeps the default text',
      (tester) async {
    await _open(tester);
    expect(find.text(_defaultMessage), findsOneWidget);
    await _expectReachableAbovePanel(tester, find.text(_defaultMessage));
    expect(find.byKey(_settingsButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('denied camera offers system settings and scans after return',
      (tester) async {
    var opened = 0;
    await _open(tester, onOpenAppSettings: () async => opened++);
    expect(find.text(_defaultMessage), findsNothing);
    expect(find.textContaining('請到系統設定'), findsOneWidget);
    await _expectReachableAbovePanel(tester, find.textContaining('請到系統設定'));
    expect(find.byKey(_settingsButton).hitTestable(), findsOneWidget,
        reason: 'The action must stay usable on a small phone at 200% text');
    await tester.tap(find.byKey(_settingsButton));
    await tester.pump();
    expect(opened, 1);

    // The user enables the camera in the settings page and comes back.
    await _leaveAndReturn(tester, away: () => camera.granted = true);
    expect(camera.running, isTrue);
    expect(find.textContaining('請到系統設定'), findsNothing);
    expect(find.byKey(_settingsButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an entry-specific hint replaces the denied-camera guidance',
      (tester) async {
    // Longer than the space between the controls at 200% text.
    final hint = '此入口離開後需由交易紀錄恢復。' * 8;
    await _open(tester,
        onOpenAppSettings: () async {}, deniedPermissionHint: hint);
    expect(find.text(hint), findsOneWidget);
    await _expectReachableAbovePanel(tester, find.text(hint));
    expect(find.textContaining('返回後即可掃描'), findsNothing);
    expect(find.byKey(_settingsButton).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a settings page that cannot open is reported in the scanner',
      (tester) async {
    await _open(tester,
        onOpenAppSettings: () async => throw StateError('no settings'));
    await tester.tap(find.byKey(_settingsButton));
    await tester.pump();
    expect(find.textContaining('無法開啟系統設定'), findsOneWidget);
    expect(find.byKey(_settingsButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a camera enabled by hand clears the settings failure on return',
      (tester) async {
    await _open(tester,
        onOpenAppSettings: () async => throw StateError('no settings'));
    await tester.tap(find.byKey(_settingsButton));
    await tester.pump();
    expect(find.textContaining('無法開啟系統設定'), findsOneWidget);

    // Still denied after returning: the failure stays.
    await _leaveAndReturn(tester);
    expect(find.textContaining('無法開啟系統設定'), findsOneWidget);

    // The user found the permission in the system settings and comes back.
    await _leaveAndReturn(tester, away: () => camera.granted = true);
    expect(camera.running, isTrue);
    expect(find.textContaining('無法開啟系統設定'), findsNothing);
    expect(find.byKey(_settingsButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a denied camera is not requested again by its own dialog',
      (tester) async {
    await _open(tester, onOpenAppSettings: () async {});
    expect(camera.starts, 1);
    // Each permission request, even one Android denies by itself, makes the
    // app inactive and then resumed again without leaving it.
    for (var i = 0; i < 5; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }
    expect(camera.starts, 1, reason: 'No request loop while denied');
    expect(find.textContaining('請到系統設定'), findsOneWidget);

    // Coming back from elsewhere tries once, as does the explicit retry.
    await _leaveAndReturn(tester);
    expect(camera.starts, 2);
    await tester.tap(find.text('清除並重新掃描'));
    await tester.pumpAndSettle();
    expect(camera.starts, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling manual input does not ask for a denied camera again',
      (tester) async {
    await _open(tester, onOpenAppSettings: () async {});
    expect(camera.starts, 1);
    await tester.tap(find.byKey(const Key('manual_ur_dialog_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(camera.starts, 1, reason: 'No new permission request');
    expect(find.textContaining('請到系統設定'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
