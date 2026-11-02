import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/bitcoin_send_screen.dart';
import 'package:wallet/screens/scan_signature_screen.dart';
import 'package:wallet/screens/send_tx_screen.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/transaction_history.dart';
import 'test_storage_directory.dart';

import 'transaction_flow_test.dart' as fixtures;

// A profile saved before 1.2.1 may still hold a public plaintext node URL.
// Public display fixtures only; nothing is signed and no network is used.
const _evmAccount = AccountDescriptor(
    masterFingerprint: '12345678',
    derivationPath: "m/44'/60'/0'/0/0",
    address: '0x1111111111111111111111111111111111111111',
    chainId: 11155111);
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
final _hash = '0x${'22' * 32}';
final _requestId = '33' * 16;
const _evmRefusal = '已不再允許使用此節點網址：公開網路上的節點請使用 https://。本次未傳送交易，請到網路與節點設定修改網址。';

class _PublicNative implements WalletFfiService {
  @override
  Map<String, dynamic> decodeIntentJson(
          {required String rawRlpHex, required int declaredChainId}) =>
      {'chain_id': declaredChainId, 'recipient': _evmAccount.address};
  @override
  void cancelPendingSession(String sessionId) {}
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
  Map<String, dynamic> verifyAndAssembleEthSignatureUr(
          {required String sessionId,
          required String expectedRequestIdHex,
          required String urOrFrames}) =>
      {
        'verified': true,
        'status': 'SIGNED_TX_READY',
        'chain_id': _evmAccount.chainId,
        'request_id': expectedRequestIdHex,
        'recovered_address': _evmAccount.address,
        'signed_raw_tx_hex': 'public-display-only',
        'local_tx_hash': _hash
      };
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}

class _MemoryHistory extends TransactionHistory {
  _MemoryHistory({String? path}) : super(pathOverride: path ?? testHistoryPath());
  final records = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> read() async =>
      records.map((record) => Map<String, dynamic>.from(record)).toList();

  @override
  Future<void> save(Map<String, dynamic> record) async =>
      records.add(Map<String, dynamic>.from(record));
}

/// Bitcoin Core-shaped node that records every method it is asked to run.
MockClient _node(List<String> methods) => MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      methods.add(body['method'] as String);
      return http.Response(
          jsonEncode({
            'result': body['method'] == 'getblockchaininfo'
                ? {'chain': 'regtest'}
                : '22' * 32,
            'error': null
          }),
          200);
    });

class _ReplayNative implements BitcoinFfiService {
  @override
  Map<String, dynamic> build(Map<String, dynamic> request) => {
        'status': 'SUCCESS',
        'psbt_hex': '70736274ff',
        'expected_digest': '11' * 32,
        'ur_frames': ['ur:crypto-psbt/public-fixture'],
        'txid': '22' * 32,
        'recipient_address': request['recipient_address'],
        'amount_sat': request['amount_sat'],
        'fee_sat': request['fee_sat'],
        'change_address': 'bcrt1qchange',
        'change_sat': '10000',
      };
  @override
  Map<String, dynamic> verify(Map<String, dynamic> request) => {
        'status': 'VERIFIED',
        'tx_hex': '02000000public',
        'txid': '22' * 32,
      };
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

void main() {
  for (final saved in ['verified', 'unknown']) {
    testWidgets(
        'an old public http EVM URL never reaches broadcasting ($saved)',
        (tester) async {
      final requests = <String>[];
      final client = MockClient((request) async {
        requests.add((jsonDecode(request.body) as Map)['method'] as String);
        return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': _hash}), 200);
      });
      final rpc =
          NodeRpcClient(rpcUrl: 'http://example.com:8545', client: client);
      final history = _MemoryHistory();
      await tester.pumpWidget(MaterialApp(
          home: ScanSignatureScreen(
              account: _evmAccount,
              ffiOverride: _PublicNative(),
              rpcOverride: rpc,
              historyOverride: history,
              requestId: _requestId,
              sessionId: 'public-session',
              unsignedRlpHex: 'public-unsigned-display',
              restoredRecord: {
            'account': _evmAccount.address,
            'chainId': _evmAccount.chainId,
            'derivationPath': _evmAccount.derivationPath,
            'masterFingerprint': _evmAccount.masterFingerprint.toLowerCase(),
            'compressedPublicKeyHex':
                _evmAccount.compressedPublicKeyHex?.toLowerCase(),
            'requestId': _requestId,
            'sessionId': 'public-session',
            'unsignedPayload': 'public-unsigned-display',
            'rpcUrl': rpc.rpcUrl,
            'signatureUr': 'public-response-display',
            'signedRaw': 'public-display-only',
            'hash': _hash,
            'state': saved
          })));
      await tester.pumpAndSettle();
      final state = tester
          .state<ScanSignatureScreenState>(find.byType(ScanSignatureScreen));
      final before = history.records.length;

      if (saved == 'verified') {
        await state.broadcast();
      } else {
        await state.queryTransaction();
      }
      await tester.pumpAndSettle();

      expect(requests, isEmpty);
      expect(history.records.skip(before), isEmpty,
          reason: 'neither broadcasting nor unknown may be persisted');
      expect(
          tester
              .widget<SelectableText>(
                  find.byKey(const Key('broadcast_rpc_error_text')))
              .data,
          saved == 'verified'
              ? _evmRefusal
              : _evmRefusal.replaceFirst('傳送交易', '查詢交易'));
      if (saved == 'verified') {
        expect(find.byKey(const Key('confirm_broadcast_btn')), findsOneWidget);
      }
    });
  }

  testWidgets('an old public http EVM URL is not asked for nonce or gas',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('saved_evm_history_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add((jsonDecode(request.body) as Map)['method'] as String);
      return http.Response('{}', 500);
    });
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: _evmAccount,
            ffiOverride: _PublicNative(),
            historyOverride: _MemoryHistory(path: '${directory.path}/history.json'),
            rpcOverride: NodeRpcClient(
                rpcUrl: 'http://example.com:8545', client: client))));
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), _evmAccount.address);
    await tester.enterText(find.byKey(const Key('tx_amount_field')), '1');
    await tester.pumpAndSettle();
    await tester
        .state<SendTxScreenState>(find.byType(SendTxScreen))
        .syncFromRpc();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(find.text(_evmRefusal.replaceFirst('未傳送交易', '沒有連線到節點')),
        findsOneWidget);
  });

  testWidgets('an old public http Bitcoin URL is refused before send or lookup',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('saved_btc_url_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/bitcoin.json';
    const request = {
      'account_xpub': 'public-test-xpub',
      'master_fingerprint': '12345678',
      'recipient_address': 'bcrt1qrecipient',
      'amount_sat': '1000',
      'fee_sat': '200',
      'change_index': 0,
      'utxos': <dynamic>[],
    };
    File(path).writeAsStringSync(jsonEncode({
      'schema_version': 2,
      'account_address': _btcAccount.address,
      'master_fingerprint': _btcAccount.masterFingerprint,
      'rpc_endpoint': 'http://example.com:18443/wallet/fcw_watch',
      'state': 'verified',
      'request': request,
      'built': _ReplayNative().build(request),
      'response_ur': 'ur:crypto-psbt/public-signed-fixture',
      'history': [
        {'txid': '44' * 32, 'state': 'pending', 'amount_sat': '1'}
      ],
    }));
    final methods = <String>[];
    final client = _node(methods);
    addTearDown(client.close);
    await tester.pumpWidget(MaterialApp(
        home: BitcoinSendScreen(
            account: _btcAccount,
            ffiOverride: _ReplayNative(),
            rpcOverride: BitcoinRpcClient(
                endpoint: 'http://example.com:18443/wallet/fcw_watch',
                client: client),
            storagePathOverride: path)));
    await tester.pumpAndSettle();
    final state =
        tester.state<BitcoinSendScreenState>(find.byType(BitcoinSendScreen));
    const refusal = '已不再允許使用此節點網址：公開網路上的節點請使用 https://。本次未傳送交易，請到節點設定修改網址。';

    unawaited(state.broadcast());
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing,
        reason: 'a refused URL is not offered for confirmation');
    expect(
        tester.widget<SelectableText>(find.byKey(const Key('btc_error'))).data,
        refusal);
    expect(jsonDecode(File(path).readAsStringSync())['state'], 'verified');

    await state.checkStatus();
    await tester.pumpAndSettle();
    expect(
        tester.widget<SelectableText>(find.byKey(const Key('btc_error'))).data,
        refusal.replaceFirst('傳送交易', '查詢交易'));
    await state.checkArchivedStatus(0);
    await tester.pumpAndSettle();
    expect(
        tester.widget<SelectableText>(find.byKey(const Key('btc_error'))).data,
        refusal.replaceFirst('傳送交易', '查詢交易'));
    expect(jsonDecode(File(path).readAsStringSync())['state'], 'verified');
    expect(methods, isEmpty);
  });

  testWidgets(
      'an old public http EVM URL is refused before recovering a request',
      (tester) async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add((jsonDecode(request.body) as Map)['method'] as String);
      return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': '0xaa36a7'}), 200);
    });
    final rpc =
        NodeRpcClient(rpcUrl: 'http://example.com:8545', client: client);
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            account: _evmAccount,
            ffiOverride: _PublicNative(),
            rpcOverride: rpc,
            historyOverride: _MemoryHistory(),
            requestId: _requestId,
            sessionId: 'public-session',
            unsignedRlpHex: 'public-unsigned-display',
            restoredRecord: {
          'account': _evmAccount.address,
          'chainId': _evmAccount.chainId,
          'derivationPath': _evmAccount.derivationPath,
          'masterFingerprint': _evmAccount.masterFingerprint.toLowerCase(),
          'compressedPublicKeyHex':
              _evmAccount.compressedPublicKeyHex?.toLowerCase(),
          'requestId': _requestId,
          'sessionId': 'public-session',
          'unsignedPayload': 'public-unsigned-display',
          'rpcUrl': rpc.rpcUrl,
          'state': 'awaitingSignature'
        })));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('confirm_existing_signature_btn'));
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('signature_verification_error_text')))
            .data,
        _evmRefusal.replaceFirst('未傳送交易', '沒有連線到節點'));
    expect(confirm, findsOneWidget, reason: 'still the recovery step');
  });

  testWidgets('an old public http EVM URL builds no request from typed fees',
      (tester) async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add((jsonDecode(request.body) as Map)['method'] as String);
      return http.Response('{}', 500);
    });
    final ffi = fixtures.FakeFfi();
    final history = fixtures.MemoryHistory();
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: fixtures.account,
            ffiOverride: ffi,
            historyOverride: history,
            rpcOverride: NodeRpcClient(
                rpcUrl: 'http://example.com:8545', client: client))));
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), fixtures.address);
    await tester.enterText(find.byKey(const Key('tx_amount_field')), '0.001');
    final toggle = find.byKey(const Key('tx_fee_settings_toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    for (final (key, value) in [
      ('tx_nonce_field', '7'),
      ('tx_gas_limit_field', '21000'),
      ('tx_max_fee_gwei_field', '2'),
      ('tx_priority_fee_gwei_field', '1'),
    ]) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.enterText(find.byKey(Key(key)), value);
    }
    await tester.pumpAndSettle();
    await tester
        .state<SendTxScreenState>(find.byType(SendTxScreen))
        .generateUnsignedTx();
    await tester.pumpAndSettle();
    expect(ffi.builds, 0);
    expect(history.records, isEmpty);
    expect(requests, isEmpty);
    expect(find.text(_evmRefusal.replaceFirst('傳送交易', '建立交易')), findsOneWidget);
  });
}
