import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/review_screen.dart';
import 'package:vault/screens/vault_home_screen.dart';
import 'package:vault/services/vault_lifecycle_guard.dart';

class IsolatedVault extends Fake implements VaultFfiService {
  int cancellations = 0, locks = 0, activations = 0, unlocks = 0;
  String status = 'EMPTY';
  @override
  int init() => 0;
  @override
  bool cancel([String? handleId]) {
    cancellations++;
    return true;
  }

  @override
  bool lock() {
    locks++;
    return true;
  }

  @override
  Map<String, dynamic> checkStorageStatus(String path) =>
      {'status': status, 'unlocked': false};
  @override
  Map<String, dynamic> generateMnemonic(int count) => {
        'status': 'SUCCESS',
        'mnemonic':
            'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'
      };
  @override
  Map<String, dynamic> previewMnemonic(String phrase,
          [String passphrase = '']) =>
      {
        'status': 'SUCCESS',
        'word_count': 12,
        'master_fingerprint': '12345678',
        'evm_account_0': {'address': '0x1234'},
        'btc_account_0': {'receive_address': 'bcrt1qtest'}
      };
  @override
  Map<String, dynamic> activateAndSaveMnemonic(
      {required String phrase,
      String passphrase = '',
      required String storagePath,
      required String pinPassword}) {
    activations++;
    return {'status': 'ERROR', 'error': 'test stops activation'};
  }

  @override
  Map<String, dynamic> unlockFromStorage(
      {required String storagePath, required String pinPassword}) {
    unlocks++;
    return {'status': 'ERROR', 'error': 'test stops unlock'};
  }
}

Future<void> tapVisible(WidgetTester tester, Key key) async {
  final item = find.byKey(key);
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('idle timeout revokes keys and resets only on actual activity',
      (tester) async {
    final ffi = IsolatedVault();
    var triggers = 0;
    final guard = VaultLifecycleGuard(
        ffi: ffi,
        idleTimeout: const Duration(seconds: 5),
        onSecurityLockTriggered: () => triggers++);
    guard.startObserving();
    await tester.pump(const Duration(seconds: 4));
    guard.recordActivity();
    await tester.pump(const Duration(seconds: 4));
    expect(triggers, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(triggers, 1);
    expect(ffi.locks, 1);
    expect(ffi.cancellations, 1);
    guard.stopObserving();
  });

  testWidgets('lock clears generated mnemonic and every onboarding field',
      (tester) async {
    final ffi = IsolatedVault();
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tapVisible(tester, const Key('generate_mnemonic_btn'));
    expect(find.text('1. abandon'), findsOneWidget);
    final home =
        tester.state<VaultHomeScreenState>(find.byType(VaultHomeScreen));
    home.lockVault();
    await tester.pumpAndSettle();
    expect(find.text('1. abandon'), findsNothing);
    expect(find.byKey(const Key('activate_created_wallet_btn')), findsNothing);
    await tapVisible(tester, const Key('onboarding_tab_restore_mnemonic'));
    await tester.enterText(
        find.byKey(const Key('restore_mnemonic_field')), 'secret mnemonic');
    home.lockVault();
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('restore_mnemonic_field')))
            .controller!
            .text,
        isEmpty);
  });

  testWidgets('changing mnemonic or passphrase invalidates address approval',
      (tester) async {
    final ffi = IsolatedVault();
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tapVisible(tester, const Key('onboarding_tab_restore_mnemonic'));
    await tester.enterText(
        find.byKey(const Key('restore_mnemonic_field')), 'original phrase');
    await tapVisible(tester, const Key('preview_restore_mnemonic_btn'));
    expect(find.byKey(const Key('activate_restored_mnemonic_btn')),
        findsOneWidget);
    await tester.enterText(find.byKey(const Key('restore_passphrase_field')),
        'different passphrase');
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('activate_restored_mnemonic_btn')), findsNothing);
    expect(ffi.activations, 0);
  });

  testWidgets('system back revokes an unsigned review handle', (tester) async {
    final ffi = IsolatedVault();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: nav, home: const Scaffold(body: Text('home'))));
    nav.currentState!.push(MaterialPageRoute(
        builder: (_) => ReviewScreen(
            ffi: ffi,
            review: PreparedReviewDto(
                handleId: 'bound-request',
                sessionId: 'session',
                requestId: 'request',
                chainId: 11155111,
                recipient: '0x2222222222222222222222222222222222222222',
                rawAmount: '1',
                displayAmount: '1',
                tokenSymbol: 'ETH',
                decimals: 18,
                feeCapWei: '21000',
                verdict: ReviewVerdictType.approved,
                evmDetails: EvmReviewDetails.fromJson({
                  'type': 'Legacy EIP-155',
                  'chain_id': '11155111',
                  'nonce': '0',
                  'gas_limit': '21000',
                  'gas_price_wei': '1',
                  'to': '0x2222222222222222222222222222222222222222',
                  'value_wei': '1',
                  'data_hex': '0x',
                  'access_list': <dynamic>[],
                })))));
    await tester.pumpAndSettle();
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(ffi.cancellations, 1);
  });

  testWidgets('late successful device auth cannot unlock after security lock',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    final completer = Completer<bool>();
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'authenticateWithDevice' ? completer.future : null);
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tester.tap(find.byKey(const Key('vault_unlock_submit_btn')));
    await tester.pump();
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .lockVault();
    completer.complete(true);
    await tester.pumpAndSettle();
    expect(ffi.unlocks, 0);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
      'native auth prompt inactive event preserves only its current attempt',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    final completer = Completer<bool>();
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'authenticateWithDevice' ? completer.future : null);
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tester.tap(find.byKey(const Key('vault_unlock_submit_btn')));
    await tester.pump();
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .lockForLifecycle(AppLifecycleState.inactive);
    completer.complete(true);
    await tester.pumpAndSettle();
    expect(ffi.unlocks, 1);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('leaving foreground during device auth explains the lock',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    final completer = Completer<bool>();
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') return completer.future;
      if (call.method == 'cancelDeviceAuthentication') return null;
      return null;
    });
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tester.tap(find.byKey(const Key('vault_unlock_submit_btn')));
    await tester.pump();
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .lockForLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(find.textContaining('應用程式已離開前景，請重新驗證'), findsOneWidget);
    completer.complete(true);
    await tester.pumpAndSettle();
    expect(ffi.unlocks, 0);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('foreground leave explains auth after the platform result',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    final completer = Completer<bool>();
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') return completer.future;
      if (call.method == 'cancelDeviceAuthentication') return null;
      return null;
    });
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tester.tap(find.byKey(const Key('vault_unlock_submit_btn')));
    await tester.pump();
    completer.completeError(PlatformException(
        code: 'authentication_failed', message: '裝置驗證未完成，金庫仍鎖定'));
    await tester.pump();
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .lockForLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(find.textContaining('應用程式已離開前景，請重新驗證'), findsOneWidget);
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .lockForLifecycle(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.textContaining('應用程式已離開前景，請重新驗證'), findsOneWidget);
    expect(ffi.unlocks, 0);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('cancelled native device authentication cannot unlock keys',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tapVisible(tester, const Key('vault_unlock_submit_btn'));
    expect(ffi.unlocks, 0);
    expect(find.textContaining('裝置驗證取消'), findsOneWidget);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('device lock prerequisite is displayed and keys stay locked',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') {
        throw PlatformException(
            code: 'device_not_secure', message: '請先設定裝置鎖定密碼');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tapVisible(tester, const Key('vault_unlock_submit_btn'));
    expect(find.textContaining('請先設定裝置鎖定密碼'), findsOneWidget);
    expect(ffi.unlocks, 0);
  });

  testWidgets(
      'unavailable authenticator error is displayed and keys stay locked',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') {
        throw PlatformException(
            code: 'authentication_unavailable',
            message: '此裝置沒有可用的生物識別或鎖定密碼驗證');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tapVisible(tester, const Key('vault_unlock_submit_btn'));
    expect(find.textContaining('此裝置沒有可用的生物識別或鎖定密碼驗證'),
        findsOneWidget);
    expect(find.textContaining('無法執行裝置驗證'), findsNothing);
    expect(ffi.unlocks, 0);
  });

  testWidgets('backgrounded device authentication stays locked with its own message',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') {
        throw PlatformException(
            code: 'backgrounded', message: '應用程式已離開前景，請重新驗證');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tapVisible(tester, const Key('vault_unlock_submit_btn'));
    expect(find.textContaining('應用程式已離開前景，請重新驗證'), findsOneWidget);
    expect(find.textContaining('無法完成裝置身分驗證'), findsNothing);
    expect(ffi.unlocks, 0);
  });

  testWidgets('untrusted backgrounded diagnostics are not displayed',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') {
        throw PlatformException(
            code: 'backgrounded',
            message: 'secret native details',
            details: 'secret stack');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tapVisible(tester, const Key('vault_unlock_submit_btn'));
    expect(find.textContaining('應用程式已離開前景，請重新驗證'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    expect(ffi.unlocks, 0);
  });

  testWidgets('device authentication timeout stays locked with its own message',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') {
        throw PlatformException(code: 'timeout', message: '裝置驗證逾時，請重試');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tapVisible(tester, const Key('vault_unlock_submit_btn'));
    expect(find.textContaining('裝置驗證逾時，請重試'), findsOneWidget);
    expect(find.textContaining('無法完成裝置身分驗證'), findsNothing);
    expect(ffi.unlocks, 0);
  });

  testWidgets('untrusted authentication error text is never displayed',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'authenticateWithDevice') {
        throw PlatformException(
            code: 'device_not_secure',
            message: 'secret native details',
            details: 'secret stack');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tapVisible(tester, const Key('vault_unlock_submit_btn'));
    expect(find.textContaining('請先設定裝置鎖定密碼'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    expect(ffi.unlocks, 0);
  });

  testWidgets('late device authentication error cannot replace security lock',
      (tester) async {
    final ffi = IsolatedVault()..status = 'ENCRYPTED_ON_DISK';
    final completer = Completer<bool>();
    const channel = MethodChannel('fcw/platform');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'authenticateWithDevice' ? completer.future : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(MaterialApp(
        home: VaultHomeScreen(ffi: ffi, storagePath: 'test-isolated-path')));
    await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
        'Strong-local-password-2026');
    await tester.tap(find.byKey(const Key('vault_unlock_submit_btn')));
    await tester.pump();
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .lockVault();
    completer.completeError(
        PlatformException(code: 'device_not_secure', message: '請先設定裝置鎖定密碼'));
    await tester.pumpAndSettle();
    expect(find.textContaining('裝置身分驗證'), findsNothing);
    expect(find.textContaining('請先設定裝置鎖定密碼'), findsNothing);
    expect(ffi.unlocks, 0);
  });
}
