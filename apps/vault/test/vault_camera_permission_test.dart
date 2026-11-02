// Run this file alone from apps/vault with its existing package configuration.
// This suite never loads native FFI or creates/unlocks/signs with key material.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/main.dart';
import 'package:vault/screens/vault_home_screen.dart';

const _scanKey = Key('scan_sign_request_btn');
const _unlockKey = Key('vault_unlock_submit_btn');
const _pinKey = Key('vault_unlock_pin_field');
const _prepareKey = Key('vault_prepare_camera_permission_btn');
const _statusKey = Key('vault_camera_permission_status');
const _settingsKey = Key('vault_open_camera_settings_btn');
const _channel = MethodChannel('fcw/platform');

class _PublicVault implements VaultFfiService {
  _PublicVault(this.events);

  final List<String> events;
  final forbiddenCalls = <Symbol>[];
  bool unlocked = true;
  int locks = 0;
  int cancellations = 0;

  // App and Home both call init. It never restores an already locked fixture.
  @override
  int init() => 0;

  @override
  bool cancel([String? handleId]) {
    cancellations++;
    events.add('ffi.cancel:${handleId ?? "all"}');
    return true;
  }

  @override
  bool lock() {
    locks++;
    unlocked = false;
    events.add('ffi.lock');
    return true;
  }

  @override
  Map<String, dynamic> checkStorageStatus(String path) => {
        'status': 'ENCRYPTED_ON_DISK',
        'unlocked': unlocked,
        'master_fingerprint': '1234abcd',
        'has_passphrase_hint': false,
      };

  @override
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 120}) => const {
        'status': 'SUCCESS',
        'master_fingerprint': '1234abcd',
        'has_passphrase_hint': false,
        'multi_accounts': {
          'ur_single': '',
          'fountain_frames': <String>[],
          'btc_accounts': <dynamic>[],
          'evm_accounts': [
            {
              'account_index': 0,
              'derivation_path': "m/44'/60'/0'/0/0",
              'address': '0x0000000000000000000000000000000000000001',
              'compressed_pubkey_hex':
                  '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
            },
          ],
        },
      };

  // All other FFI methods, including every credential, unlock, preparation and
  // signing API, fail before any native call. Caught errors remain detectable.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    forbiddenCalls.add(invocation.memberName);
    throw StateError('Unexpected FFI call: ${invocation.memberName}');
  }
}

class _PermissionChannel {
  _PermissionChannel(this.vault, this.events,
      {required this.granted, required this.deferPermissionCheck});

  final _PublicVault vault;
  final List<String> events;
  final bool deferPermissionCheck;
  final checks = <Completer<bool>>[];
  final requests = <Completer<bool>>[];
  final requestSawLocked = <bool>[];
  final requestSawEmptyPublicInput = <bool?>[];
  final forbiddenCalls = <String>[];
  bool Function()? publicInputIsEmpty;
  bool granted;
  int hasChecks = 0;
  int cancellations = 0;
  int settingsOpens = 0;
  bool settingsOpenResult = true;

  Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'hasCameraPermission':
        events.add('platform.hasCameraPermission');
        hasChecks++;
        if (deferPermissionCheck) {
          final check = Completer<bool>();
          checks.add(check);
          return check.future;
        }
        return granted;
      case 'requestCameraPermission':
        events.add('platform.requestCameraPermission');
        requestSawLocked.add(!vault.unlocked);
        requestSawEmptyPublicInput.add(publicInputIsEmpty?.call());
        final request = Completer<bool>();
        requests.add(request);
        return request.future;
      case 'cancelCameraPermissionRequest':
        events.add('platform.cancelCameraPermissionRequest');
        cancellations++;
        // Deliberately retain the future so tests can send an adversarial late
        // grant after cancellation. Product code must invalidate that result.
        return null;
      case 'cancelDeviceAuthentication':
        return null;
      case 'openAppSettings':
        events.add('platform.openAppSettings');
        requestSawLocked.add(!vault.unlocked);
        settingsOpens++;
        return settingsOpenResult;
      default:
        forbiddenCalls.add(call.method);
        throw StateError('Unexpected platform call: ${call.method}');
    }
  }

  void complete(int index, bool result) {
    granted = result;
    requests[index].complete(result);
  }

  void completeCheck(int index, bool result) {
    granted = result;
    checks[index].complete(result);
  }
}

class _CameraPlatform extends MobileScannerPlatform {
  int starts = 0;
  int stops = 0;

  @override
  Stream<BarcodeCapture?> get barcodesStream =>
      const Stream<BarcodeCapture?>.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream<TorchState>.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream<double>.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    return const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        numberOfCameras: 1,
        size: Size(640, 480));
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> resetZoomScale() async {}
  @override
  Future<void> setZoomScale(double scale) async {}
  @override
  Future<void> toggleTorch() async {}
}

class _Fixture {
  _Fixture(this.directory, this.vault, this.permissions, this.camera, this.events);
  final Directory directory;
  final _PublicVault vault;
  final _PermissionChannel permissions;
  final _CameraPlatform camera;
  final List<String> events;
}

Future<void> _changeLifecycle(
    WidgetTester tester, AppLifecycleState target) async {
  // Follow Flutter's real transition graph, including the intermediate inactive
  // lock. AppLifecycleListener deliberately rejects resumed -> paused jumps.
  const next = <AppLifecycleState, List<AppLifecycleState>>{
    AppLifecycleState.detached: [AppLifecycleState.resumed],
    AppLifecycleState.resumed: [AppLifecycleState.inactive],
    AppLifecycleState.inactive: [
      AppLifecycleState.hidden,
      AppLifecycleState.resumed,
    ],
    AppLifecycleState.hidden: [
      AppLifecycleState.paused,
      AppLifecycleState.inactive,
    ],
    AppLifecycleState.paused: [
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ],
  };
  final current = tester.binding.lifecycleState;
  final routes = <List<AppLifecycleState>>[
    if (current != null) [current] else [target],
  ];
  final seen = <AppLifecycleState>{if (current != null) current};
  while (routes.first.last != target) {
    final route = routes.removeAt(0);
    for (final state in next[route.last]!) {
      if (seen.add(state)) routes.add([...route, state]);
    }
  }
  final route = current == null ? routes.first : routes.first.skip(1);
  for (final state in route) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pumpAndSettle();
  }
}

Future<_Fixture> _mount(WidgetTester tester,
    {bool granted = false, bool deferPermissionCheck = false}) async {
  final events = <String>[];
  final vault = _PublicVault(events);
  final permissions = _PermissionChannel(vault, events,
      granted: granted, deferPermissionCheck: deferPermissionCheck);
  final camera = _CameraPlatform();
  final previousCamera = MobileScannerPlatform.instance;
  final directory = Directory.systemTemp.createTempSync('fcw_camera_widget_');
  final fixture = _Fixture(directory, vault, permissions, camera, events);
  MobileScannerPlatform.instance = camera;
  expect(defaultTargetPlatform, TargetPlatform.android);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, permissions.handle);
  tester.view.physicalSize = const Size(600, 1100);
  tester.view.devicePixelRatio = 1;
  await _changeLifecycle(tester, AppLifecycleState.resumed);

  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final pending in [...permissions.checks, ...permissions.requests]) {
      if (!pending.isCompleted) pending.complete(false);
    }
    await tester.pumpAndSettle();
    await _changeLifecycle(tester, AppLifecycleState.resumed);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    MobileScannerPlatform.instance = previousCamera;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    _deleteOwnTemporaryDirectory(directory);
  });

  await tester.pumpWidget(ColdWalletVaultApp(
    ffiOverride: vault,
    storagePathOverride: '${directory.path}/public_fixture.json',
  ));
  await tester.pumpAndSettle();
  expect(find.byKey(_scanKey), findsOneWidget);
  expect(tester.takeException(), isNull);
  return fixture;
}

void _deleteOwnTemporaryDirectory(Directory directory) {
  if (!directory.existsSync()) return;
  final root = Directory.systemTemp.resolveSymbolicLinksSync();
  final target = directory.resolveSymbolicLinksSync();
  String normalized(String value) => Platform.isWindows ? value.toLowerCase() : value;
  final expectedPrefix = normalized('$root${Platform.pathSeparator}fcw_camera_widget_');
  if (!normalized(target).startsWith(expectedPrefix)) {
    throw StateError('Refusing to remove a directory outside this test prefix');
  }
  directory.deleteSync(recursive: true);
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void _expectLocked(WidgetTester tester, _Fixture fixture) {
  expect(fixture.vault.unlocked, isFalse);
  expect(find.byType(AirGapScanner), findsNothing);
  expect(find.byKey(_scanKey), findsNothing);
  expect(find.byKey(_unlockKey), findsOneWidget);
  expect(find.byKey(_prepareKey), findsOneWidget);
  final field = tester.widget<TextField>(find.byKey(_pinKey));
  expect(field.controller!.text, isEmpty);
}

bool _buttonEnabled(WidgetTester tester, Key key) =>
    tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

void _expectPending(WidgetTester tester, _Fixture fixture) {
  _expectLocked(tester, fixture);
  expect(_buttonEnabled(tester, _unlockKey), isFalse);
  expect(tester.widget<TextField>(find.byKey(_pinKey)).enabled, isFalse);
}

String? _permissionStatusText(WidgetTester tester) {
  final status = find.byKey(_statusKey);
  if (status.evaluate().isEmpty) return null;
  return tester
      .widgetList<Text>(find.descendant(
          of: status, matching: find.byType(Text), matchRoot: true))
      .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
      .join('\n');
}

void _expectPermissionStatus(WidgetTester tester) {
  expect(find.byKey(_statusKey), findsOneWidget);
  expect(_permissionStatusText(tester), isNotEmpty);
}

void _expectNoSecretCalls(_Fixture fixture) {
  expect(fixture.vault.forbiddenCalls, isEmpty);
  expect(fixture.permissions.forbiddenCalls, isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first permission request locks before the platform request; '
      'inactive preserves only the public future and grant stays locked',
      (tester) async {
    final fixture = await _mount(tester);
    final before = fixture.events.length;
    await _tap(tester, _scanKey);
    final sequence = fixture.events.sublist(before);
    final hasIndex = sequence.indexOf('platform.hasCameraPermission');
    final lockIndex = sequence.indexOf('ffi.lock');
    final requestIndex = sequence.indexOf('platform.requestCameraPermission');
    expect(hasIndex, greaterThanOrEqualTo(0));
    expect(lockIndex, greaterThan(hasIndex));
    expect(requestIndex, greaterThan(lockIndex));
    expect(fixture.permissions.requests, hasLength(1));
    expect(fixture.permissions.requestSawLocked, [true]);
    _expectPending(tester, fixture);

    final priorLocks = fixture.vault.locks;
    final priorCancellations = fixture.permissions.cancellations;
    await _changeLifecycle(tester, AppLifecycleState.inactive);
    expect(fixture.vault.locks, greaterThan(priorLocks));
    expect(fixture.permissions.cancellations, priorCancellations);
    _expectPending(tester, fixture);
    await _changeLifecycle(tester, AppLifecycleState.resumed);
    _expectPending(tester, fixture);

    fixture.permissions.complete(0, true);
    await tester.pumpAndSettle();
    _expectLocked(tester, fixture);
    expect(_buttonEnabled(tester, _unlockKey), isTrue);
    expect(tester.widget<TextField>(find.byKey(_pinKey)).enabled, isNot(false));
    _expectPermissionStatus(tester);
    expect(fixture.camera.starts, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled old grant cannot finish or overwrite a newer '
      'locked preflight retry', (tester) async {
    final fixture = await _mount(tester);
    await _tap(tester, _scanKey);
    await _changeLifecycle(tester, AppLifecycleState.paused);
    await _changeLifecycle(tester, AppLifecycleState.resumed);
    _expectLocked(tester, fixture);
    expect(_buttonEnabled(tester, _prepareKey), isTrue);

    await _tap(tester, _prepareKey);
    expect(fixture.permissions.requests, hasLength(2));
    _expectPending(tester, fixture);
    final currentStatus = _permissionStatusText(tester);
    fixture.permissions.complete(0, true);
    await tester.pumpAndSettle();
    _expectPending(tester, fixture);
    expect(_permissionStatusText(tester), currentStatus);
    expect(fixture.permissions.requests[1].isCompleted, isFalse);
    expect(fixture.camera.starts, 0);

    fixture.permissions.complete(1, false);
    await tester.pumpAndSettle();
    _expectLocked(tester, fixture);
    _expectPermissionStatus(tester);
    expect(_buttonEnabled(tester, _unlockKey), isTrue);
    expect(_buttonEnabled(tester, _prepareKey), isTrue);
    expect(fixture.permissions.requests, hasLength(2));
    expect(fixture.camera.starts, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('denial stays locked and explicit locked preflight retry is possible',
      (tester) async {
    final fixture = await _mount(tester);
    await _tap(tester, _scanKey);
    fixture.permissions.complete(0, false);
    await tester.pumpAndSettle();
    _expectLocked(tester, fixture);
    _expectPermissionStatus(tester);
    expect(_buttonEnabled(tester, _prepareKey), isTrue);
    expect(fixture.permissions.requests, hasLength(1));
    expect(fixture.camera.starts, 0);

    // This fixed public marker is never submitted to a credential API. It
    // proves retry clears existing input before requesting OS permission.
    final publicInput = tester.widget<TextField>(find.byKey(_pinKey)).controller!;
    fixture.permissions.publicInputIsEmpty = () => publicInput.text.isEmpty;
    await tester.enterText(find.byKey(_pinKey), 'PUBLIC_UI_CLEAR_SENTINEL');
    expect(publicInput.text, isNotEmpty);
    await _tap(tester, _prepareKey);
    expect(fixture.permissions.requests, hasLength(2));
    expect(fixture.permissions.requestSawLocked, [true, true]);
    expect(fixture.permissions.requestSawEmptyPublicInput.last, isTrue);
    _expectPending(tester, fixture);
    fixture.permissions.complete(1, true);
    await tester.pumpAndSettle();
    _expectLocked(tester, fixture);
    _expectPermissionStatus(tester);
    expect(_buttonEnabled(tester, _prepareKey), isTrue);
    expect(fixture.permissions.requests, hasLength(2));
    expect(fixture.camera.starts, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission check pending across paused cannot push a scanner '
      'when its late answer is granted', (tester) async {
    final fixture = await _mount(tester, deferPermissionCheck: true);
    await _tap(tester, _scanKey);
    expect(fixture.permissions.checks, hasLength(1));
    expect(fixture.permissions.requests, isEmpty);
    expect(find.byType(AirGapScanner), findsNothing);
    final previousLocks = fixture.vault.locks;

    await _changeLifecycle(tester, AppLifecycleState.paused);
    expect(fixture.vault.locks, greaterThan(previousLocks));
    _expectLocked(tester, fixture);
    fixture.permissions.completeCheck(0, true);
    await _changeLifecycle(tester, AppLifecycleState.resumed);

    _expectLocked(tester, fixture);
    expect(fixture.permissions.requests, isEmpty);
    expect(fixture.camera.starts, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed permission check shows its error under the scan '
      'button of the still-unlocked Vault; the next scan clears it',
      (tester) async {
    final fixture = await _mount(tester, deferPermissionCheck: true);
    await _tap(tester, _scanKey);
    fixture.permissions.checks.single
        .completeError(PlatformException(code: 'error', message: 'diagnostic'));
    await tester.pumpAndSettle();

    const message = '無法確認相機權限，請鎖定金庫後準備相機權限。';
    final error = find.text(message);
    expect(error, findsOneWidget);
    expect(find.textContaining('diagnostic'), findsNothing);
    expect(fixture.vault.unlocked, isTrue);
    expect(_buttonEnabled(tester, _scanKey), isTrue);
    expect(tester.getTopLeft(error).dy,
        greaterThan(tester.getBottomLeft(find.byKey(_scanKey)).dy));
    expect(tester.getBottomLeft(error).dy, lessThanOrEqualTo(1100));

    await _tap(tester, _scanKey);
    expect(fixture.permissions.checks, hasLength(2));
    expect(error, findsNothing);
    expect(fixture.permissions.requests, isEmpty);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permanent denial explains system settings and opens the app '
      'settings page while the Vault stays locked', (tester) async {
    final fixture = await _mount(tester);
    await _tap(tester, _scanKey);
    fixture.permissions.requests.single.completeError(PlatformException(
        code: 'camera_permission_permanently_denied',
        message: 'native diagnostic'));
    await tester.pumpAndSettle();
    _expectLocked(tester, fixture);
    _expectPermissionStatus(tester);
    expect(_permissionStatusText(tester), contains('系統設定'));
    expect(find.textContaining('native diagnostic'), findsNothing);
    expect(_buttonEnabled(tester, _unlockKey), isTrue);
    expect(_buttonEnabled(tester, _prepareKey), isTrue);

    await _tap(tester, _settingsKey);
    expect(fixture.permissions.settingsOpens, 1);
    expect(fixture.permissions.requestSawLocked.last, isTrue);
    _expectLocked(tester, fixture);

    // A retry from the lock screen stays possible; its answer replaces the
    // settings guidance.
    await _tap(tester, _prepareKey);
    expect(fixture.permissions.requests, hasLength(2));
    _expectPending(tester, fixture);
    expect(find.byKey(_settingsKey), findsNothing);
    fixture.permissions.complete(1, true);
    await tester.pumpAndSettle();
    _expectLocked(tester, fixture);
    expect(_permissionStatusText(tester), isNot(contains('系統設定')));
    expect(find.byKey(_settingsKey), findsNothing);
    expect(fixture.camera.starts, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a settings page that cannot open leaves manual guidance',
      (tester) async {
    final fixture = await _mount(tester);
    fixture.permissions.settingsOpenResult = false;
    await _tap(tester, _scanKey);
    fixture.permissions.requests.single.completeError(
        PlatformException(code: 'camera_permission_permanently_denied'));
    await tester.pumpAndSettle();
    await _tap(tester, _settingsKey);
    expect(fixture.permissions.settingsOpens, 1);
    expect(find.byKey(_settingsKey), findsNothing);
    expect(_permissionStatusText(tester), contains('手動'));
    _expectLocked(tester, fixture);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late permanent denial after a background cancellation '
      'cannot show settings guidance', (tester) async {
    final fixture = await _mount(tester);
    await _tap(tester, _scanKey);
    await _changeLifecycle(tester, AppLifecycleState.paused);
    fixture.permissions.requests.single.completeError(
        PlatformException(code: 'camera_permission_permanently_denied'));
    await _changeLifecycle(tester, AppLifecycleState.resumed);
    _expectLocked(tester, fixture);
    expect(find.byKey(_settingsKey), findsNothing);
    expect(find.byKey(_statusKey), findsNothing);
    expect(fixture.permissions.settingsOpens, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  for (final background in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('${background.name} cancels pending permission; late grant '
        'and resumed cannot reopen or unlock', (tester) async {
      final fixture = await _mount(tester);
      await _tap(tester, _scanKey);
      final previousCancels = fixture.permissions.cancellations;
      final previousLocks = fixture.vault.locks;
      await _changeLifecycle(tester, background);
      expect(fixture.permissions.cancellations, greaterThan(previousCancels));
      expect(fixture.vault.locks, greaterThan(previousLocks));
      _expectLocked(tester, fixture);

      fixture.permissions.complete(0, true);
      await _changeLifecycle(tester, AppLifecycleState.resumed);
      _expectLocked(tester, fixture);
      expect(fixture.camera.starts, 0);
      expect(fixture.permissions.requests, hasLength(1));
      _expectNoSecretCalls(fixture);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('explicit manual lock cancels pending permission and ignores late grant',
      (tester) async {
    final fixture = await _mount(tester);
    await _tap(tester, _scanKey);
    final previousCancels = fixture.permissions.cancellations;
    // The public permission flow is already locked, so its unlocked toolbar
    // button is absent. Invoke that same existing public Home action directly.
    tester.state<VaultHomeScreenState>(find.byType(VaultHomeScreen)).lockVault();
    await tester.pumpAndSettle();
    expect(fixture.permissions.cancellations, greaterThan(previousCancels));
    fixture.permissions.complete(0, true);
    await tester.pumpAndSettle();
    _expectLocked(tester, fixture);
    expect(fixture.camera.starts, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing the app cancels pending permission and rejects late grant',
      (tester) async {
    final fixture = await _mount(tester);
    await _tap(tester, _scanKey);
    final previousCancels = fixture.permissions.cancellations;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(fixture.permissions.cancellations, greaterThan(previousCancels));
    fixture.permissions.complete(0, true);
    await tester.pumpAndSettle();
    expect(find.byType(ColdWalletVaultApp), findsNothing);
    expect(find.byType(AirGapScanner), findsNothing);
    expect(fixture.camera.starts, 0);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('popped scanner cannot restart camera on a quick resume before '
      'its reverse transition finishes', (tester) async {
    final fixture = await _mount(tester, granted: true);
    await _tap(tester, _scanKey);
    final scannerState = tester.state(find.byType(AirGapScanner));
    final scannerRoute = ModalRoute.of(scannerState.context)!;
    expect(scannerRoute.isCurrent, isTrue);
    expect(fixture.camera.starts, 1);
    final initialStarts = fixture.camera.starts;

    // These are valid adjacent lifecycle states. Do not use the settling helper:
    // Home's guard pops synchronously, while the outgoing scanner stays mounted
    // throughout its route's reverse animation.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(fixture.vault.unlocked, isFalse);
    expect(fixture.camera.stops, greaterThanOrEqualTo(1));
    expect(scannerRoute.isCurrent, isFalse);
    expect(scannerState.mounted, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(); // Flush callbacks without advancing the reverse timer.
    expect(scannerState.mounted, isTrue);
    final startsDuringReverse = fixture.camera.starts;

    await tester.pumpAndSettle();
    expect(scannerState.mounted, isFalse);
    _expectLocked(tester, fixture);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
    expect(startsDuringReverse, initialStarts,
        reason: 'A popped scanner must not reopen camera while still mounted');
    expect(fixture.camera.starts, initialStarts,
        reason: 'Finishing route disposal must not introduce another start');
  });

  testWidgets('already granted permission opens fresh autostart scanners; '
      'cancel returns to the still-ready public fixture', (tester) async {
    final fixture = await _mount(tester, granted: true);
    final previousLocks = fixture.vault.locks;
    await _tap(tester, _scanKey);
    expect(find.byType(AirGapScanner), findsOneWidget);
    final firstState = tester.state(find.byType(AirGapScanner));
    expect(fixture.camera.starts, 1);
    expect(fixture.permissions.requests, isEmpty);
    expect(fixture.vault.locks, previousLocks);

    await tester.tap(find.byTooltip('取消掃描'));
    await tester.pumpAndSettle();
    expect(find.byType(AirGapScanner), findsNothing);
    expect(find.byKey(_scanKey), findsOneWidget);
    expect(fixture.vault.unlocked, isTrue);
    expect(fixture.camera.stops, greaterThanOrEqualTo(1));

    await _tap(tester, _scanKey);
    expect(find.byType(AirGapScanner), findsOneWidget);
    expect(identical(tester.state(find.byType(AirGapScanner)), firstState), isFalse);
    expect(fixture.camera.starts, 2);
    expect(fixture.permissions.hasChecks, 2);
    expect(fixture.permissions.requests, isEmpty);
    await tester.tap(find.byTooltip('取消掃描'));
    await tester.pumpAndSettle();
    expect(find.byKey(_scanKey), findsOneWidget);
    _expectNoSecretCalls(fixture);
    expect(tester.takeException(), isNull);
  });
}
