import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/screens/bitcoin_send_screen.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/node_url_policy.dart';
import 'package:wallet/widgets/node_url_field.dart';

// Public display fixtures only; no native code runs and nothing is signed.
const _evmAccount = AccountDescriptor(
  masterFingerprint: '12345678',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
  chainId: 11155111,
  label: '日常帳戶',
  compressedPublicKeyHex: '02public-test-key',
);
const _btcAccount = AccountDescriptor(
  masterFingerprint: '12345678',
  derivationPath: "m/84'/1'/0'",
  address: 'bcrt1qreceive',
  chainId: 0,
  assetFamily: 'BTC',
  extendedPublicKey: 'public-test-xpub',
  btcDescriptor: "wpkh([12345678/84'/1'/0']public-test-xpub/0/*)",
  btcReceiveAddressRegtest: 'bcrt1qreceive',
  btcChangeAddress: 'bcrt1qchange',
);

class _PublicFfi implements WalletFfiService {
  @override
  int init() => 0;
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoBitcoinNative implements BitcoinFfiService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

class _CountingRpc extends NodeRpcClient {
  int verifications = 0;
  @override
  Future<int> verifyChainId(int expectedChainId) async {
    verifications++;
    return expectedChainId;
  }
}

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('node_url_'));
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> mount(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(MaterialApp(
        theme: ColdWalletTheme.light(role: FcwRole.wallet), home: home));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> type(WidgetTester tester, Key field, String text) async {
    await tester.ensureVisible(find.byKey(field));
    await tester.enterText(find.byKey(field), text);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  final warning = find.byKey(const Key('node_url_plaintext_warning'));
  final loopback = find.byKey(const Key('node_url_loopback_note'));
  final refusal = find.descendant(
      of: find.byType(NodeUrlField),
      matching: find.text(NodeUrlPolicy.publicHttpRefused));

  testWidgets('EVM node settings refuse public plaintext and warn on local',
      (tester) async {
    final path = '${directory.path}/accounts.json';
    AccountStore(path).save(const AccountSnapshot(accounts: [_evmAccount]));
    final rpc = _CountingRpc();
    await mount(
        tester,
        AccountScreen(
            ffiOverride: _PublicFfi(),
            rpcOverride: rpc,
            storagePathOverride: path));
    await tap(tester, find.byKey(const Key('node_settings_toggle')));
    // The default http://127.0.0.1:8545 never leaves the phone.
    expect(loopback, findsOneWidget);
    expect(warning, findsNothing);

    await type(
        tester, const Key('rpc_url_input_field'), 'http://203.0.113.7:8545');
    expect(refusal, findsOneWidget);
    expect(warning, findsNothing);
    expect(loopback, findsNothing);
    await tap(tester, find.byKey(const Key('save_rpc_settings_btn')));
    expect(rpc.verifications, 0);
    expect(AccountStore(path).load().rpcUrl, 'http://127.0.0.1:8545');
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('wallet_pairing_error_text')))
            .data,
        contains(NodeUrlPolicy.publicHttpRefused));

    await type(
        tester, const Key('rpc_url_input_field'), 'http://192.168.1.20:8545');
    expect(refusal, findsNothing);
    expect(warning, findsOneWidget);
    await tester.ensureVisible(warning);
    await tester.pumpAndSettle();
    // An EVM node has no credentials to expose.
    expect(find.text(NodeUrlPolicy.plaintextWarning), findsOneWidget);
    expect(find.textContaining('帳號密碼'), findsNothing);
    await tap(tester, find.byKey(const Key('save_rpc_settings_btn')));
    expect(rpc.verifications, 1);
    expect(AccountStore(path).load().rpcUrl, 'http://192.168.1.20:8545');

    await type(
        tester, const Key('rpc_url_input_field'), 'https://rpc.example.com');
    expect(warning, findsNothing);
    expect(refusal, findsNothing);
  });

  testWidgets('Bitcoin node settings refuse public plaintext before any call',
      (tester) async {
    await mount(
        tester,
        BitcoinSendScreen(
            account: _btcAccount,
            ffiOverride: _NoBitcoinNative(),
            storagePathOverride: '${directory.path}/bitcoin.json'));
    await tap(tester, find.byKey(const Key('btc_node_settings_toggle')));
    // The default http://127.0.0.1:18443/wallet/fcw_watch never leaves it.
    expect(loopback, findsOneWidget);
    expect(warning, findsNothing);

    await type(tester, const Key('btc_rpc_endpoint'),
        'http://203.0.113.7:18443/wallet/fcw_watch');
    expect(refusal, findsOneWidget);
    expect(warning, findsNothing);
    await tap(tester, find.text('驗證節點並同步公開帳戶'));
    expect(
        tester.widget<SelectableText>(find.byKey(const Key('btc_error'))).data,
        NodeUrlPolicy.savedUrlRefusal('http://203.0.113.7:18443',
            settings: '節點設定', outcome: '沒有連線到節點'));

    await type(tester, const Key('btc_rpc_endpoint'),
        'http://umbrel.local:8332/wallet/fcw_watch');
    expect(refusal, findsNothing);
    expect(warning, findsOneWidget);
    expect(find.text(NodeUrlPolicy.plaintextWarningWithCredentials),
        findsOneWidget);
    expect(NodeUrlPolicy.plaintextWarningWithCredentials,
        contains('含擴充公鑰的帳戶描述與節點帳號密碼'));
  });

  testWidgets('both node URL fields say what the node receives',
      (tester) async {
    Finder disclosure(String text) => find.descendant(
        of: find.byType(NodeUrlField), matching: find.text(text));
    final path = '${directory.path}/accounts.json';
    AccountStore(path).save(const AccountSnapshot(accounts: [_evmAccount]));
    await mount(
        tester,
        AccountScreen(
            ffiOverride: _PublicFfi(),
            rpcOverride: _CountingRpc(),
            storagePathOverride: path));
    await tap(tester, find.byKey(const Key('node_settings_toggle')));
    await tester.ensureVisible(disclosure(nodeDataDisclosure));
    await tester.pumpAndSettle();
    expect(disclosure(nodeDataDisclosure), findsOneWidget);
    expect(tester.takeException(), isNull);

    await mount(
        tester,
        BitcoinSendScreen(
            account: _btcAccount,
            ffiOverride: _NoBitcoinNative(),
            storagePathOverride: '${directory.path}/bitcoin.json'));
    await tap(tester, find.byKey(const Key('btc_node_settings_toggle')));
    await tester.ensureVisible(disclosure(bitcoinNodeDataDisclosure));
    await tester.pumpAndSettle();
    expect(disclosure(bitcoinNodeDataDisclosure), findsOneWidget);
    expect(bitcoinNodeDataDisclosure, contains('擴充公鑰'));
    expect(bitcoinNodeDataDisclosure, contains('RPC 使用者名稱與密碼'));
    expect(tester.takeException(), isNull);
  });
}
