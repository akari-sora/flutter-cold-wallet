import 'dart:io';
import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/screens/public_backup_screen.dart';
import 'package:wallet/screens/scan_signature_screen.dart';
import 'package:wallet/screens/send_tx_screen.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/transaction_history.dart';
import 'test_storage_directory.dart';

const _address = '0x9858effd232b4033e47d90003d41ec34ecaeda94';
const _recipient = '0x1111111111111111111111111111111111111111';
const _account = AccountDescriptor(
  masterFingerprint: '12345678',
  derivationPath: "m/44'/60'/0'/0/0",
  address: _address,
  chainId: 11155111,
  label: '日常帳戶',
  compressedPublicKeyHex: '02public-test-key',
);

class _UiFfi implements WalletFfiService {
  @override
  int init() => 0;
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      true;
  @override
  void cancelPendingSession(String sessionId) {}
  @override
  Map<String, dynamic> decodeIntentJson(
          {required String rawRlpHex, required int declaredChainId}) =>
      {
        'transaction': {
          'type': 'EIP1559',
          'nonce': '7',
          'gas_limit': '21000',
          'max_fee_per_gas_wei': '1000000000',
          'max_priority_fee_per_gas_wei': '100000000',
          'data_hex': ''
        },
        'intent': {
          'NativeTransfer': {
            'recipient': _recipient,
            'value_wei': '1000000000000000000',
            'fee_cap_wei': '21000000000000'
          }
        },
      };
  @override
  Map<String, dynamic> verifyAndAssembleEthSignatureUr(
          {required String sessionId,
          required String expectedRequestIdHex,
          required String urOrFrames}) =>
      {
        'verified': true,
        'status': 'SIGNED_TX_READY',
        'chain_id': 11155111,
        'request_id': expectedRequestIdHex,
        'recovered_address': _address,
        'signed_raw_tx_hex': '0x1234',
        'local_tx_hash': '0x${'a' * 64}',
      };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OfflineRpc extends NodeRpcClient {
  @override
  Future<int> verifyChainId(int expectedChainId) async => expectedChainId;
  @override
  Future<BigInt> getBalance(String address) async =>
      throw StateError('node unavailable');
}

class _MemoryHistory extends TransactionHistory {
  _MemoryHistory() : super(pathOverride: testHistoryPath());
  @override
  Future<void> save(Map<String, dynamic> record) async {}
}

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('wallet_ui_'));
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> mount(WidgetTester tester, Widget home, ThemeData theme) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: home,
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder target,
      {bool opensBackup = false}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    if (opensBackup) {
      // Start file I/O in the real async zone, as the backup journey tests do.
      await tester.runAsync(() async {
        await tester.tap(target);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester
            .state<PublicBackupScreenState>(
                find.byType(PublicBackupScreen, skipOffstage: false))
            .initialized;
      });
    } else {
      await tester.tap(target);
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    ThemeData theme() => dark
        ? ColdWalletTheme.dark(role: FcwRole.wallet)
        : ColdWalletTheme.light(role: FcwRole.wallet);

    testWidgets('empty wallet can open backup at 320dp and 200% text ($mode)',
        (tester) async {
      await mount(
          tester,
          AccountScreen(
              ffiOverride: _UiFfi(),
              storagePathOverride: '${directory.path}/accounts.json'),
          theme());
      expect(find.byKey(const Key('no_paired_accounts_title')), findsOneWidget);
      expect(
          tester
              .getSize(find.byKey(const Key('empty_state_scan_pairing_btn')))
              .height,
          greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
      await tapVisible(tester, find.text('還原公開備份'), opensBackup: true);
      expect(find.byType(PublicBackupScreen), findsOneWidget);
      expect(find.byKey(const Key('read_public_backup')), findsOneWidget);
    });

    testWidgets(
        'paired wallet retains real RPC error and complete receive address ($mode)',
        (tester) async {
      final path = '${directory.path}/accounts.json';
      AccountStore(path).save(const AccountSnapshot(accounts: [_account]));
      await mount(
          tester,
          AccountScreen(
              ffiOverride: _UiFfi(),
              rpcOverride: _OfflineRpc(),
              storagePathOverride: path),
          theme());
      final state =
          tester.state<AccountScreenState>(find.byType(AccountScreen));
      await state.refreshBalances();
      await tester.pumpAndSettle();
      expect(find.text('ETH: 無法查詢'), findsOneWidget);
      expect(find.textContaining('node unavailable'), findsOneWidget);
      expect(find.text('ETH: 0 ETH'), findsNothing);
      expect(tester.takeException(), isNull);
      await tapVisible(tester, find.byKey(const Key('show_receive_qr_btn')));
      final address = tester.widget<SelectableText>(
          find.byKey(const Key('receive_modal_address_text')));
      expect(address.data, _address);
      expect(address.maxLines, isNull);
      expect(find.text('Ethereum Sepolia'), findsWidgets);
      await tapVisible(tester, find.text('完成'));
    });

    testWidgets('send fee controls keep entered values when collapsed ($mode)',
        (tester) async {
      await mount(
          tester,
          SendTxScreen(
              account: _account,
              ffiOverride: _UiFfi(),
              historyOverride: _MemoryHistory()),
          theme());
      await tester.enterText(
          find.byKey(const Key('tx_recipient_field')), _recipient);
      await tapVisible(tester, find.text('費用與進階設定'));
      await tester.ensureVisible(find.byKey(const Key('tx_nonce_field')));
      await tester.enterText(find.byKey(const Key('tx_nonce_field')), '42');
      await tapVisible(tester, find.text('費用與進階設定'));
      await tapVisible(tester, find.text('費用與進階設定'));
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('tx_nonce_field')))
              .controller!
              .text,
          '42');
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('tx_recipient_field')))
              .controller!
              .text,
          _recipient);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'broadcast review keeps full recipient network and fees before action ($mode)',
        (tester) async {
      await mount(
          tester,
          ScanSignatureScreen(
              account: _account,
              ffiOverride: _UiFfi(),
              rpcOverride: _OfflineRpc(),
              historyOverride: _MemoryHistory(),
              sessionId: 'ui',
              requestId: '00112233445566778899aabbccddeeff',
              unsignedRlpHex: '12'),
          theme());
      final state = tester
          .state<ScanSignatureScreenState>(find.byType(ScanSignatureScreen));
      await state.ingestSignatureUr('synthetic-public-signature');
      await tester.pumpAndSettle();
      final intent = tester.widget<SelectableText>(
          find.byKey(const Key('verified_intent_text')));
      expect(intent.data, contains(_recipient));
      expect(intent.data, contains('最高網路費：0.000021 ETH'));
      expect(intent.maxLines, isNull);
      expect(find.textContaining('網路 Chain ID：11155111'), findsOneWidget);
      expect(
          tester.getTopLeft(find.byKey(const Key('verified_intent_text'))).dy,
          lessThan(tester
              .getTopLeft(find.byKey(const Key('confirm_broadcast_btn')))
              .dy));
      await tester
          .ensureVisible(find.byKey(const Key('confirm_broadcast_btn')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
