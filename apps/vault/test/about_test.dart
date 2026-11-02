import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/app_info.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/main.dart';

const _platform = MethodChannel('fcw/platform');

// Public account data only; no secret is generated, decrypted or signed.
class _Boundary extends Fake implements VaultFfiService {
  _Boundary({this.unlocked = false});

  bool unlocked;

  @override
  int init() => 0;

  @override
  bool cancel([String? handleId]) => true;

  @override
  bool lock() {
    unlocked = false;
    return true;
  }

  @override
  Map<String, dynamic> checkStorageStatus(String storagePath) => {
        'status': 'ENCRYPTED_ON_DISK',
        'unlocked': unlocked,
        'master_fingerprint': '1234abcd',
        'has_passphrase_hint': false,
      };

  @override
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 120}) => {
        'status': 'SUCCESS',
        'master_fingerprint': '1234abcd',
        'has_passphrase_hint': false,
        'multi_accounts': {
          'ur_single': 'ur:crypto-multi-accounts/public-about-fixture',
          'fountain_frames': <String>[],
          'evm_accounts': [
            {
              'account_index': 0,
              'derivation_path': "m/44'/60'/0'/0/0",
              'address': '0x0000000000000000000000000000000000000001',
              'compressed_pubkey_hex':
                  '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
            }
          ],
          'btc_accounts': <dynamic>[],
        },
      };
}

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('vault_about_'));
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('the About version is the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
            .firstMatch(pubspec)
            ?.group(1),
        appVersion);
  });

  Future<void> mount(WidgetTester tester, VaultFfiService ffi) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_platform, null));
    await tester.pumpWidget(ColdWalletVaultApp(
        ffiOverride: ffi, storagePathOverride: '${directory.path}/vault.json'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> expectNotice(WidgetTester tester) async {
    final notice = find.byKey(const Key('vault_unaudited_notice'));
    await tester.ensureVisible(notice);
    await tester.pumpAndSettle();
    expect(find.descendant(of: notice, matching: find.text(fcwUnauditedNotice)),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  testWidgets('the locked Vault opens About and it shows nothing of the vault',
      (tester) async {
    await mount(tester, _Boundary());
    expect(find.byKey(const Key('vault_unlock_submit_btn')), findsOneWidget);
    expect(find.textContaining('1234ABCD'), findsOneWidget);
    await expectNotice(tester);

    await tester.tap(find.byKey(const Key('vault_about_btn')));
    await tester.pumpAndSettle();
    expect(find.byType(FcwAboutPage), findsOneWidget);
    expect(find.text('FCW Vault'), findsOneWidget);
    expect(find.text('版本 ${appVersion.replaceFirst('+', '（建置 ')}）'),
        findsOneWidget);
    expect(find.text(fcwUnauditedNotice), findsOneWidget);
    final advice = find.byKey(const Key('vault_update_advice'));
    expect(advice, findsOneWidget);
    for (final point in ['關閉 FCW Vault 的自動更新', '只在需要時手動更新', '手機連網時']) {
      expect(find.descendant(of: advice, matching: find.textContaining(point)),
          findsOneWidget);
    }
    // The home route underneath is offstage; nothing of it may show here.
    expect(find.textContaining('1234ABCD'), findsNothing);
    expect(find.byKey(const Key('vault_unlock_pin_field')), findsNothing);
    final toggle = find.byKey(const Key('about_privacy_policy_en_toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the unlocked Vault keeps the notice and the About entry',
      (tester) async {
    await mount(tester, _Boundary(unlocked: true));
    expect(find.byKey(const Key('scan_sign_request_btn')), findsOneWidget);
    await expectNotice(tester);
    expect(find.byKey(const Key('vault_about_btn')), findsOneWidget);
    expect(find.byKey(const Key('vault_lock_btn')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
