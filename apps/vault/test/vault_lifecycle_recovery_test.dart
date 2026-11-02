import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/services/vault_lifecycle_guard.dart';

// This boundary never opens a native library or holds key material.
class _LifecycleBoundary extends Fake implements VaultFfiService {
  final events = <String>[];
  Object? cancellationError;
  Object? lockError;
  bool cancellationSucceeded = true;

  @override
  bool cancel([String? handleId]) {
    events.add('cancel:$handleId');
    if (cancellationError != null) throw cancellationError!;
    return cancellationSucceeded;
  }

  @override
  bool lock() {
    events.add('lock');
    if (lockError != null) throw lockError!;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fcw/platform');
  late List<String> platformCalls;

  setUp(() {
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      platformCalls.add(call.method);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('$state revokes then locks and reports the original reason',
        (tester) async {
      final boundary = _LifecycleBoundary();
      final guard = VaultLifecycleGuard(
        ffi: boundary,
        onSecurityLockTriggered: () => fail('Reason callback must be used'),
        onSecurityLockReason: (reason) {
          expect(reason, state);
          boundary.events.add('notify');
        },
      );
      addTearDown(guard.stopObserving);
      guard.didChangeAppLifecycleState(state);
      expect(boundary.events, ['cancel:null', 'lock', 'notify']);
    });
  }

  testWidgets('resuming rearms idle timeout without a premature second lock',
      (tester) async {
    final boundary = _LifecycleBoundary();
    final reasons = <AppLifecycleState?>[];
    final guard = VaultLifecycleGuard(
      ffi: boundary,
      idleTimeout: const Duration(seconds: 10),
      onSecurityLockTriggered: () => fail('Reason callback must be used'),
      onSecurityLockReason: reasons.add,
    );
    addTearDown(guard.stopObserving);
    guard.startObserving();
    await tester.pump(const Duration(seconds: 8));
    guard.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 10));
    expect(reasons, [AppLifecycleState.hidden]);
    guard.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 9));
    expect(reasons, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    expect(reasons, [AppLifecycleState.hidden, null]);
    expect(boundary.events, ['cancel:null', 'lock', 'cancel:null', 'lock']);
    expect(platformCalls, contains('cancelDeviceAuthentication'));
  });

  testWidgets('stopping observation cancels idle work and device auth',
      (tester) async {
    final boundary = _LifecycleBoundary();
    final guard = VaultLifecycleGuard(
      ffi: boundary,
      idleTimeout: const Duration(seconds: 1),
      onSecurityLockTriggered: () => fail('A stopped guard must not lock'),
    );
    guard.startObserving();
    guard.stopObserving();
    await tester.pump(const Duration(seconds: 2));
    expect(boundary.events, isEmpty);
    expect(platformCalls, ['cancelDeviceAuthentication']);
  });

  testWidgets(
      'unsuccessful cancellation still attempts lock and notifies screen',
      (tester) async {
    final boundary = _LifecycleBoundary()..cancellationSucceeded = false;
    final guard = VaultLifecycleGuard(
      ffi: boundary,
      onSecurityLockTriggered: () => boundary.events.add('notify'),
    );
    addTearDown(guard.stopObserving);
    guard.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(boundary.events, ['cancel:null', 'lock', 'notify']);
  });

  testWidgets('cancellation failure still locks and preserves the failure',
      (tester) async {
    final failure = StateError('Disposable cancellation service failure');
    final boundary = _LifecycleBoundary()..cancellationError = failure;
    final guard = VaultLifecycleGuard(
      ffi: boundary,
      onSecurityLockTriggered: () => boundary.events.add('notify'),
    );
    addTearDown(guard.stopObserving);
    expect(() => guard.didChangeAppLifecycleState(AppLifecycleState.hidden),
        throwsA(same(failure)));
    expect(boundary.events, ['cancel:null', 'lock', 'notify']);
  });

  testWidgets('lock failure still notifies the screen and remains observable',
      (tester) async {
    final failure = StateError('Disposable lock service failure');
    final boundary = _LifecycleBoundary()..lockError = failure;
    final guard = VaultLifecycleGuard(
      ffi: boundary,
      onSecurityLockTriggered: () => boundary.events.add('notify'),
    );
    addTearDown(guard.stopObserving);
    expect(() => guard.didChangeAppLifecycleState(AppLifecycleState.paused),
        throwsA(same(failure)));
    expect(boundary.events, ['cancel:null', 'lock', 'notify']);
  });
}
