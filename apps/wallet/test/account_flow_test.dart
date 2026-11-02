import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/screens/public_backup_screen.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/public_backup.dart';
import 'package:wallet/services/transaction_history.dart';

import 'denied_camera.dart';

class _PublicFfi implements WalletFfiService {
  bool fail = false;
  bool missing = false;
  @override
  int init() {
    if (missing) throw StateError('native missing');
    return 0;
  }

  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      true;
  @override
  Map<String, dynamic> buildEthSignRequestUr(
          {required String sessionId,
          required String requestIdHex,
          required String rawTxHex,
          required int chainId,
          required String derivationPath,
          required String masterFingerprintHex,
          required String expectedAddress,
          int maxFragmentLen = 120}) =>
      {'status': 'PENDING_REGISTERED'};
  @override
  void cancelPendingSession(String sessionId) {}
  @override
  Map<String, dynamic> decodeAndVerifyMultiAccountsUr(String input,
          {int defaultChainId = 11155111}) =>
      fail
          ? {'status': 'ERROR', 'error': 'invalid QR'}
          : {
              'status': 'SUCCESS',
              'evm_accounts': [
                {
                  'master_fingerprint': input == 'conflict'
                      ? 'aabbccdd'
                      : '73c5da0a',
                  'derivation_path': input == 'conflict'
                      ? "m/44'/60'/1'/0/0"
                      : "m/44'/60'/0'/0/0",
                  'address': input == 'second'
                      ? '0x1111111111111111111111111111111111111111'
                      : '0x9858effd232b4033e47d90003d41ec34ecaeda94',
                  'compressed_pubkey_hex': '02${'11' * 32}',
                  'label': input == 'second' ? '第二帳戶' : '第一帳戶',
                }
              ],
              'unsupported_accounts': input == 'native-excluded'
                  ? [
                      {'chain_family': 'BTC', 'error': 'missing descriptor'}
                    ]
                  : [],
              'btc_accounts': input == 'legacy-mixed'
                  ? [
                      {
                        'master_fingerprint': '73c5da0a',
                        'derivation_path': "m/84'/1'/0'",
                        'receive_address_regtest': 'bcrt1qplaceholder'
                      }
                    ]
                  : []
            };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _btcAccount = AccountDescriptor(
    masterFingerprint: '73c5da0a',
    derivationPath: "m/84'/1'/0'/0/0",
    address: 'bcrt1qreceive',
    chainId: 0,
    label: 'Bitcoin',
    assetFamily: 'BTC',
    extendedPublicKey: 'tpubTest',
    btcReceiveAddressRegtest: 'bcrt1qreceive',
    btcChangeAddress: 'bcrt1qchange',
    btcDescriptor: 'wpkh(tpubTest/0/*)');

class _BtcPublicFfi implements BitcoinFfiService {
  @override
  Map<String, dynamic> describe(Map<String, dynamic> request) =>
      {..._btcAccount.toJson(), 'status': 'SUCCESS'};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedHistory extends TransactionHistory {
  final result = Completer<List<Map<String, dynamic>>>();

  @override
  Future<List<Map<String, dynamic>>> read() => result.future;
}

class _BalanceRpc extends NodeRpcClient {
  final Completer<BigInt>? balance;
  final BigInt? wei;
  final BigInt? usdc;
  final BigInt? dai;
  int tokenCalls = 0;
  _BalanceRpc({this.balance, this.wei, this.usdc, this.dai});
  @override
  Future<int> verifyChainId(int expectedChainId) async => expectedChainId;
  @override
  Future<BigInt> getBalance(String address) =>
      balance?.future ?? Future.value(wei ?? BigInt.from(1000000000000000000));
  @override
  Future<BigInt> getErc20Balance(
      {required String tokenContract, required String holderAddress}) async {
    tokenCalls++;
    final amount =
        tokenContract == NodeRpcClient.sepoliaUsdcContract ? usdc : dai;
    if (amount != null) return amount;
    throw StateError('token unavailable');
  }
}

void main() {
  late Directory dir;
  late AccountStore store;
  const account = AccountDescriptor(
      masterFingerprint: '73c5da0a',
      derivationPath: "m/44'/60'/0'/0/0",
      address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
      chainId: 11155111,
      compressedPublicKeyHex:
          '021111111111111111111111111111111111111111111111111111111111111111');
  setUp(() {
    dir = Directory.systemTemp.createTempSync('account_store_');
    store = AccountStore('${dir.path}/accounts.json');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });
  test('account metadata and selected network survive restart', () {
    store.save(const AccountSnapshot(
        accounts: [account],
        selectedIndex: 0,
        chainId: 31337,
        rpcUrl: 'http://localhost:8545'));
    final reloaded = AccountStore(store.path).load();
    expect(reloaded.accounts.single.address, account.address);
    expect(reloaded.chainId, 31337);
    expect(reloaded.rpcUrl, 'http://localhost:8545');
  });
  test('corrupt existing storage is an error, never an empty wallet', () {
    File(store.path).writeAsStringSync('{broken');
    expect(store.load, throwsFormatException);
    expect(File(store.path).readAsStringSync(), '{broken');
  });
  test('unsupported chain and incomplete schema are rejected', () {
    File(store.path).writeAsStringSync(
        '{"schema_version":1,"accounts":[],"selected_chain_id":1}');
    expect(store.load, throwsFormatException);
  });
  test('failed write leaves previously persisted snapshot intact', () {
    store.save(const AccountSnapshot(accounts: [account]));
    Directory('${store.path}.tmp').createSync();
    expect(() => store.save(const AccountSnapshot(accounts: [])),
        throwsA(isA<FileSystemException>()));
    expect(store.load().accounts.single.address, account.address);
  });
  Future<AccountScreenState> mount(WidgetTester tester,
      {NodeRpcClient? rpc,
      _PublicFfi? ffi,
      TransactionHistory? history}) async {
    tester.view.physicalSize = const Size(1800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: AccountScreen(
            ffiOverride: ffi ?? _PublicFfi(),
            rpcOverride: rpc,
            storagePathOverride: store.path,
            historyOverride: history,
            bitcoinFfiOverride: _BtcPublicFfi())));
    await tester.pumpAndSettle();
    return tester.state<AccountScreenState>(find.byType(AccountScreen));
  }

  testWidgets(
      'pairing waits for confirmation, merges and deduplicates, restart restores',
      (tester) async {
    final state = await mount(tester);
    expect(state.ingestPairingUr('first'), true);
    expect(state.accounts, isEmpty);
    expect(File(store.path).existsSync(), false);
    expect(state.confirmPairing(), true);
    expect(state.accounts.length, 1);
    state.ingestPairingUr('second');
    state.confirmPairing();
    state.ingestPairingUr('first');
    state.confirmPairing();
    expect(state.accounts.length, 2);
    state.renameAccount(1, '自訂名稱');
    state.selectAccount(1);
    expect(store.load().selectedIndex, 1);
    await tester.pumpWidget(const SizedBox());
    final restarted = await mount(tester);
    expect(restarted.accounts.length, 2);
    expect(restarted.currentAccount!.label, '自訂名稱');
  });
  testWidgets('conflicting QR pairing preserves the existing account file',
      (tester) async {
    final state = await mount(tester);
    expect(state.ingestPairingUr('first'), true);
    expect(state.confirmPairing(), true);
    final original = File(store.path).readAsBytesSync();

    expect(state.ingestPairingUr('conflict'), true);
    expect(state.confirmPairing(), false);

    expect(state.accounts, hasLength(1));
    expect(state.accounts.single.masterFingerprint, '73c5da0a');
    expect(File(store.path).readAsBytesSync(), original);
    await tester.pump();
    expect(find.textContaining('公開派生資料與既有帳戶衝突'), findsOneWidget);
  });
  testWidgets(
      'legacy duplicate chain address with conflicting derivation is blocked without rewrite',
      (tester) async {
    final conflicting = account.copyWith(
        masterFingerprint: 'aabbccdd',
        derivationPath: "m/44'/60'/1'/0/0",
        label: 'legacy conflict');
    store.save(AccountSnapshot(accounts: [account, conflicting]));
    final original = File(store.path).readAsBytesSync();

    final state = await mount(tester);

    expect(state.accounts, isEmpty);
    expect(find.textContaining('觀察帳戶讀取失敗'), findsOneWidget);
    expect(find.textContaining('互相衝突'), findsOneWidget);
    expect(File(store.path).readAsBytesSync(), original);
  });
  testWidgets('write failure and invalid pairing preserve prior account',
      (tester) async {
    final ffi = _PublicFfi();
    final state = await mount(tester, ffi: ffi);
    state.ingestPairingUr('first');
    state.confirmPairing();
    Directory('${store.path}.tmp').createSync();
    state.renameAccount(0, '不可儲存');
    expect(state.currentAccount!.label, '第一帳戶');
    ffi.fail = true;
    expect(state.ingestPairingUr('bad'), false);
    expect(state.currentAccount!.label, '第一帳戶');
    await tester.pump();
    expect(find.textContaining('配對失敗'), findsOneWidget);
  });
  testWidgets('corrupt storage and missing native show real errors',
      (tester) async {
    File(store.path).writeAsStringSync('{bad');
    final state = await mount(tester);
    expect(state.ingestPairingUr('first'), false);
    expect(find.textContaining('觀察帳戶讀取失敗'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await mount(tester, ffi: _PublicFfi()..missing = true);
    expect(find.textContaining('native missing'), findsOneWidget);
    expect(File(store.path).readAsStringSync(), '{bad');
  });
  testWidgets(
      'network preference does not rewrite the selected account chain metadata',
      (tester) async {
    final rpc = _BalanceRpc();
    final state = await mount(tester, rpc: rpc);
    state.ingestPairingUr('first');
    state.confirmPairing();
    await state.refreshBalances();
    await tester.pump();
    expect(find.text('USDC: 查詢失敗'), findsOneWidget);
    expect(find.text('DAI: 查詢失敗'), findsOneWidget);
    state.selectChainId(31337);
    expect(state.currentAccount!.chainId, 11155111);
    expect(store.load().accounts.single.chainId, 11155111);
    expect(store.load().chainId, 31337);
    await state.refreshBalances();
    await tester.pump();
    expect(rpc.tokenCalls, 4);
    expect(find.text('USDC: 查詢失敗'), findsOneWidget);
  });
  testWidgets(
      'restart recovers a native-validated descriptor for legacy cross-chain history',
      (tester) async {
    store.save(const AccountSnapshot(
        accounts: [account], selectedIndex: 0, chainId: 31337));
    final history = TransactionHistory(
        pathOverride: '${dir.path}/public_transactions.json');
    await tester.runAsync(() => history.save({
          'requestId': '12' * 16,
          'sessionId': 'legacy-session',
          'account': '0x9858EfFd232B4033e47D90003D41ec34EcaEda94',
          'chainId': 31337,
          'unsignedPayload': '11',
          'state': 'cancelled',
        }));

    final state = await mount(tester, history: history);
    await tester.pump();

    expect(state.accounts, hasLength(2));
    expect(state.accounts.map((entry) => entry.chainId),
        unorderedEquals([11155111, 31337]));
    final persisted = store.load();
    expect(persisted.accounts, hasLength(2));
    expect(persisted.accounts.last.address, account.address.toLowerCase());
    final records = await tester.runAsync(history.read);
    expect(records!.single['unsignedPayload'], '11',
        reason: 'Recovery must not rewrite the signed transaction bytes');
  });
  for (final historySource in [
    '{"version":1,"transactions":[',
    '{"version":1,"transactions":[{"account":"0x9858effd232b4033e47d90003d41ec34ecaeda94","chainId":31337}]}',
  ]) {
    testWidgets('unreadable history preserves account and blocks transfer: '
        '$historySource', (tester) async {
      store.save(const AccountSnapshot(accounts: [account]));
      final accountFile = File(store.path);
      final historyFile = File('${dir.path}/public_transactions.json')
        ..writeAsStringSync(historySource);
      final originalAccount = accountFile.readAsBytesSync();
      final originalHistory = historyFile.readAsBytesSync();

      final state = await mount(tester,
          history: TransactionHistory(pathOverride: historyFile.path));

      expect(state.currentAccount?.address, account.address);
      expect(find.textContaining('交易紀錄核對失敗'), findsOneWidget);
      expect(find.textContaining('觀察帳戶讀取失敗'), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(
          const Key('create_unsigned_tx_btn'))).onPressed, isNull);
      expect(tester.widget<ListTile>(find.byKey(
          const Key('account_history_btn'))).onTap, isNull);
      expect(accountFile.readAsBytesSync(), originalAccount);
      expect(historyFile.readAsBytesSync(), originalHistory);
    });
  }
  testWidgets('EVM history errors do not disable independent Bitcoin flow',
      (tester) async {
    store.save(const AccountSnapshot(accounts: [_btcAccount]));
    final historyFile = File('${dir.path}/public_transactions.json')
      ..writeAsStringSync('{"version":1,"transactions":[');

    final state = await mount(tester,
        history: TransactionHistory(pathOverride: historyFile.path));

    expect(state.currentAccount?.assetFamily, 'BTC');
    expect(find.textContaining('交易紀錄核對失敗'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(
        const Key('create_unsigned_tx_btn'))).onPressed, isNotNull);
    expect(tester.widget<ListTile>(find.byKey(
        const Key('account_history_btn'))).onTap, isNotNull);
  });
  for (final candidate in [account, _btcAccount]) {
    testWidgets('pending public import keeps ${candidate.assetFamily} history available',
        (tester) async {
      store.save(AccountSnapshot(accounts: [candidate]));
      File('${dir.path}/public_import_progress.json').writeAsStringSync('{');
      final state = await mount(tester);
      expect(state.currentAccount?.assetFamily, candidate.assetFamily);
      expect(tester.widget<FilledButton>(find.byKey(
          const Key('create_unsigned_tx_btn'))).onPressed, isNull);
      expect(tester.widget<ListTile>(find.byKey(
          const Key('account_history_btn'))).onTap, isNotNull);
    });
  }
  testWidgets('new import progress is checked again before opening a route',
      (tester) async {
    store.save(const AccountSnapshot(accounts: [account]));
    await mount(tester);
    File('${dir.path}/public_import_progress.json').writeAsStringSync('{');
    await tester.tap(find.byKey(const Key('create_unsigned_tx_btn')));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(
        const Key('create_unsigned_tx_btn'))).onPressed, isNull);
    expect(tester.widget<ListTile>(find.byKey(
        const Key('account_history_btn'))).onTap, isNotNull);
  });
  testWidgets('account backup recovery cannot bypass malformed history',
      (tester) async {
    final accountFile = File(store.path)..writeAsStringSync('{broken');
    final historyFile = File('${dir.path}/public_transactions.json')
      ..writeAsStringSync('{"version":1,"transactions":[{"chainId":31337}]}');
    final historyBytes = historyFile.readAsBytesSync();
    final source = PublicBackupCodec.encode(
        chainId: 11155111,
        accounts: [account],
        transactions: [],
        bitcoinRecords: []);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('fcw/platform'),
        (call) async {
      if (call.method == 'readPublicBackup') return source;
      throw StateError('Unexpected platform call: ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null));

    final delayedHistory = _DelayedHistory();
    final state = await mount(tester, history: delayedHistory);
    expect(find.byKey(const Key('wallet_fatal_error')), findsOneWidget);
    late PublicBackupScreenState backup;
    await tester.runAsync(() async {
      tester.widget<IconButton>(find.byKey(const Key('public_backup_btn')))
          .onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      backup = tester.state<PublicBackupScreenState>(find.byType(PublicBackupScreen));
      await backup.initialized;
    });
    await tester.runAsync(backup.readBackup);
    await tester.pumpAndSettle();
    final confirmed = tester.runAsync(backup.importAccountPhase);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_public_import')));
    await confirmed;
    await tester.pumpAndSettle();
    expect(state.currentAccount?.address, account.address);
    expect(tester.widget<FilledButton>(find.byKey(
        const Key('create_unsigned_tx_btn'), skipOffstage: false)).onPressed,
        isNull);
    expect(tester.widget<ListTile>(find.byKey(
        const Key('account_history_btn'), skipOffstage: false)).onTap, isNull);
    delayedHistory.result.completeError(const FormatException('invalid identity'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('交易紀錄核對失敗'), findsOneWidget);
    expect(historyFile.readAsBytesSync(), historyBytes);
    expect(accountFile.readAsStringSync(), isNot('{broken'));
  });
  testWidgets('late balance response cannot overwrite switched account',
      (tester) async {
    final completer = Completer<BigInt>();
    final state = await mount(tester, rpc: _BalanceRpc(balance: completer));
    state.ingestPairingUr('first');
    state.confirmPairing();
    state.ingestPairingUr('second');
    state.confirmPairing();
    final loading = state.refreshBalances();
    state.selectAccount(1);
    completer.complete(BigInt.from(1000000000000000000));
    await loading;
    await tester.pump();
    expect(find.text('ETH: --'), findsOneWidget);
  });
  testWidgets('one base unit remains visible for every supported asset',
      (tester) async {
    final state = await mount(tester,
        rpc: _BalanceRpc(wei: BigInt.one, usdc: BigInt.one, dai: BigInt.one));
    state.ingestPairingUr('first');
    state.confirmPairing();
    await state.refreshBalances();
    await tester.pump();
    expect(find.text('ETH: 0.000000000000000001 ETH'), findsOneWidget);
    expect(find.text('USDC: 0.000001 USDC'), findsOneWidget);
    expect(find.text('DAI: 0.000000000000000001 DAI'), findsOneWidget);
  });
  testWidgets('complete decimal balances fit a phone without truncation',
      (tester) async {
    final state = await mount(tester,
        rpc: _BalanceRpc(
            wei: BigInt.parse('1234567891234567891'),
            usdc: BigInt.parse('123456789123456'),
            dai: BigInt.parse('123456789123456789123456789')));
    tester.view.physicalSize = const Size(390, 844);
    state.ingestPairingUr('first');
    state.confirmPairing();
    await state.refreshBalances();
    await tester.pumpAndSettle();
    expect(find.text('ETH: 1.234567891234567891 ETH'), findsOneWidget);
    expect(find.text('USDC: 123456789.123456 USDC'), findsOneWidget);
    expect(find.text('DAI: 123456789.123456789123456789 DAI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('paired account is usable at phone width without layout errors',
      (tester) async {
    final state = await mount(tester);
    tester.view.physicalSize = const Size(390, 844);
    state.ingestPairingUr('first');
    state.confirmPairing();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'legacy mixed QR explicitly excludes incomplete BTC after native decode',
      (tester) async {
    final state = await mount(tester);
    expect(state.ingestPairingUr('legacy-mixed'), true);
    expect(state.pendingAccounts.single.assetFamily, 'EVM');
    expect(state.accounts, isEmpty);
    await tester.pump();
    expect(find.textContaining('Bitcoin 帳戶缺少公開描述'), findsOneWidget);
    expect(state.confirmPairing(), true);
    expect(state.accounts.single.assetFamily, 'EVM');
  });
  testWidgets('pairing confirmation shows the master fingerprint in uppercase',
      (tester) async {
    mockDeniedCamera(tester);
    final state = await mount(tester);
    await tester.tap(find.byKey(const Key('scan_pairing_qr_btn')));
    await tester.pumpAndSettle();
    tester
        .widget<AirGapScanner>(find.byType(AirGapScanner))
        .onRawUrComplete!('first');
    await tester.pumpAndSettle();
    expect(find.text('確認匯入公開觀察帳戶'), findsOneWidget);
    expect(find.textContaining('主指紋 73C5DA0A'), findsOneWidget);
    expect(find.textContaining('73c5da0a'), findsNothing);
    await tester.tap(find.byKey(const Key('confirm_pairing_btn')));
    await tester.pumpAndSettle();
    expect(state.accounts.single.masterFingerprint, '73c5da0a',
        reason: 'Only the display is uppercase; the stored value is unchanged');
  });
  testWidgets('denied camera on pairing opens the Wallet app settings',
      (tester) async {
    mockDeniedCamera(tester);
    final platformCalls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('fcw/platform'),
        (call) async {
      platformCalls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null));
    await mount(tester);
    await tester.tap(find.byKey(const Key('scan_pairing_qr_btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('返回後即可掃描'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scanner_open_app_settings_btn')));
    await tester.pump();
    expect(platformCalls, ['openAppSettings']);
    expect(find.textContaining('無法開啟系統設定'), findsNothing);
  });
  testWidgets('native excluded BTC warning stays visible before confirmation',
      (tester) async {
    final state = await mount(tester);
    expect(state.ingestPairingUr('native-excluded'), true);
    await tester.pump();
    expect(find.byKey(const Key('pairing_warning')), findsOneWidget);
    expect(state.accounts, isEmpty);
  });
  testWidgets(
      'restart rederives BTC address and rejects tampered public storage',
      (tester) async {
    store.save(const AccountSnapshot(accounts: [_btcAccount]));
    final original = await mount(tester);
    expect(original.currentAccount!.address, _btcAccount.address);
    await tester.pumpWidget(const SizedBox());
    store.save(AccountSnapshot(accounts: [
      _btcAccount.copyWith(
          address: 'bcrt1qtampered', btcDescriptor: 'wpkh(tpubOther/0/*)')
    ]));
    final preserved = File(store.path).readAsStringSync();
    final restored = await mount(tester);
    expect(restored.currentAccount, isNull);
    expect(find.textContaining('公開描述、地址或找零資料與 tpub 不符'), findsOneWidget);
    expect(File(store.path).readAsStringSync(), preserved);
  });
}
