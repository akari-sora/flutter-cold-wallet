import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/bitcoin_send_screen.dart';
import 'package:wallet/screens/send_tx_screen.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/transaction_history.dart';

import 'app_lifecycle.dart';

// Public display fixtures only. Neither fake initializes native code or signs.
const _evmAccount = AccountDescriptor(
  masterFingerprint: '12345678',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x1111111111111111111111111111111111111111',
  chainId: 11155111,
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

class _NoNativeCalls implements WalletFfiService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

late Directory _historyDirectory;

class _EmptyHistory extends TransactionHistory {
  _EmptyHistory() : super(pathOverride: '${_historyDirectory.path}/history.json');
  @override
  Future<List<Map<String, dynamic>>> read() async => [];
}

class _DelayedHistory extends TransactionHistory {
  _DelayedHistory() : super(pathOverride: '${_historyDirectory.path}/history.json');
  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();
  final records = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> read() async {
    if (!readStarted.isCompleted) readStarted.complete();
    await releaseRead.future;
    return [];
  }

  @override
  Future<void> save(Map<String, dynamic> record) async {
    records.add(Map<String, dynamic>.from(record));
  }
}

class _TrackingNative implements WalletFfiService {
  int registrations = 0;
  int cancellations = 0;

  @override
  void cancelPendingSession(String sessionId) => cancellations++;

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
      {
        'status': 'PENDING_REGISTERED',
        'request_id': requestIdHex,
        'expected_digest': '11' * 32,
        'ur_single': 'ur:eth-sign-request/public-fixture',
        'fountain_frames': ['ur:eth-sign-request/public-fixture'],
        '_registration': registrations++,
      };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

class _UnsignedBitcoinNative implements BitcoinFfiService {
  int builds = 0;

  @override
  Map<String, dynamic> build(Map<String, dynamic> request) {
    builds++;
    return {
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
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

void main() {
  setUp(() => _historyDirectory = Directory.systemTemp.createTempSync('rpc_history_'));
  tearDown(() => _historyDirectory.deleteSync(recursive: true));
  Future<SendTxScreenState> mountAdmissionFixture(WidgetTester tester,
      _DelayedHistory history, _TrackingNative native, List<String> methods) async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final method = body['method'] as String;
      methods.add(method);
      final result = switch (method) {
        'eth_chainId' => '0xaa36a7',
        'eth_getTransactionCount' => '0x0',
        'eth_gasPrice' => '0x3b9aca00',
        'eth_maxPriorityFeePerGas' => '0x0',
        'eth_estimateGas' => '0x5208',
        _ => throw StateError('Unexpected RPC method: $method'),
      };
      return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
          200);
    });
    addTearDown(client.close);
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: _evmAccount,
            ffiOverride: native,
            rpcOverride: NodeRpcClient(
                rpcUrl: 'https://lifecycle.invalid', client: client),
            historyOverride: history)));
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), _evmAccount.address);
    await tester.enterText(find.byKey(const Key('tx_amount_field')), '1');
    await tester.ensureVisible(find.byKey(const Key('tx_fee_settings_toggle')));
    await tester.tap(find.byKey(const Key('tx_fee_settings_toggle')));
    await tester.pumpAndSettle();
    for (final field in [
      ('tx_nonce_field', '0'),
      ('tx_gas_limit_field', '21000'),
      ('tx_max_fee_gwei_field', '1'),
      ('tx_priority_fee_gwei_field', '0'),
    ]) {
      await tester.enterText(find.byKey(Key(field.$1)), field.$2);
    }
    return tester.state<SendTxScreenState>(find.byType(SendTxScreen));
  }

  for (final action in ['sync', 'generate']) {
    testWidgets('$action stops when history admission finishes in background',
        (tester) async {
      final history = _DelayedHistory();
      final native = _TrackingNative();
      final methods = <String>[];
      final state =
          await mountAdmissionFixture(tester, history, native, methods);
      final operation = action == 'sync'
          ? state.syncFromRpc()
          : state.generateUnsignedTx();
      await history.readStarted.future;
      leaveApp(tester);
      history.releaseRead.complete();
      await operation;
      returnToApp(tester);
      await tester.pump();

      expect(methods, isEmpty);
      expect(native.registrations, 0);
      expect(history.records, isEmpty);
      expect(find.byType(AnimatedFountainQr), findsNothing);
      expect(find.byKey(const Key('proceed_scan_signature_btn')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('generated history saves the immutable account binding',
      (tester) async {
    final history = _DelayedHistory()..releaseRead.complete();
    final native = _TrackingNative();
    final state = await mountAdmissionFixture(tester, history, native, []);
    await state.generateUnsignedTx();
    await tester.pump();

    expect(native.registrations, 1);
    expect(history.records, hasLength(1));
    expect(history.records.single, containsPair(
        'derivationPath', _evmAccount.derivationPath));
    expect(history.records.single, containsPair(
        'masterFingerprint', _evmAccount.masterFingerprint.toLowerCase()));
    expect(history.records.single,
        containsPair('compressedPublicKeyHex', isNull));
    expect(find.byType(AnimatedFountainQr), findsOneWidget);
  });

  testWidgets(
      'fee summary uses exact ETH units and edits revoke its RPC source',
      (tester) async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      final result = switch (body['method']) {
        'eth_chainId' => '0xaa36a7',
        'eth_getTransactionCount' => '0x0',
        'eth_gasPrice' => '0x3b9aca00',
        'eth_maxPriorityFeePerGas' => '0x0',
        'eth_estimateGas' => '0x5208',
        _ => throw StateError('Unexpected RPC method'),
      };
      return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
          200);
    });
    addTearDown(client.close);
    await tester.pumpWidget(MaterialApp(
        home: SendTxScreen(
            account: _evmAccount,
            ffiOverride: _NoNativeCalls(),
            rpcOverride: NodeRpcClient(
                rpcUrl: 'https://public.invalid/path?token=synthetic-hidden',
                client: client),
            historyOverride: _EmptyHistory())));
    await tester.enterText(
        find.byKey(const Key('tx_recipient_field')), _evmAccount.address);
    await tester.enterText(find.byKey(const Key('tx_amount_field')), '1');
    final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
    await state.syncFromRpc();
    await tester.pump();
    expect(find.textContaining('最高網路費：0.000042 ETH'), findsOneWidget);
    expect(find.textContaining('來源：https://public.invalid；'), findsOneWidget);
    expect(find.textContaining('synthetic-hidden'), findsNothing);
    await tester.enterText(find.byKey(const Key('tx_amount_field')), '2');
    await tester.pump();
    expect(find.textContaining('來源：'), findsNothing);
    expect(find.byKey(const Key('tx_fee_estimate_stale')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final abandon in ['edit', 'background', 'dispose']) {
    testWidgets('EVM RPC sync discards late fee data after $abandon',
        (tester) async {
      final estimate = Completer<http.Response>();
      final methods = <String>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final method = body['method'] as String;
        methods.add(method);
        if (method == 'eth_estimateGas') return estimate.future;
        final result = switch (method) {
          'eth_chainId' => '0xaa36a7',
          'eth_getTransactionCount' => '0x7',
          'eth_gasPrice' => '0x3b9aca00',
          'eth_maxPriorityFeePerGas' => '0x1',
          _ => throw StateError('Unexpected RPC method: $method'),
        };
        return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
            200);
      });
      addTearDown(client.close);
      await tester.pumpWidget(MaterialApp(
          home: SendTxScreen(
        account: _evmAccount,
        ffiOverride: _NoNativeCalls(),
        rpcOverride:
            NodeRpcClient(rpcUrl: 'https://lifecycle.invalid', client: client),
        historyOverride: _EmptyHistory(),
      )));
      await tester.enterText(
          find.byKey(const Key('tx_recipient_field')), _evmAccount.address);
      await tester.enterText(
          find.byKey(const Key('tx_amount_field')), '0.000000000000000001');
      await tester
          .ensureVisible(find.byKey(const Key('tx_fee_settings_toggle')));
      await tester.tap(find.byKey(const Key('tx_fee_settings_toggle')));
      await tester.pumpAndSettle();
      final state = tester.state<SendTxScreenState>(find.byType(SendTxScreen));
      final sync = state.syncFromRpc();
      await tester.pump();
      expect(methods.last, 'eth_estimateGas');

      if (abandon == 'edit') {
        await tester.enterText(
            find.byKey(const Key('tx_amount_field')), '0.000000000000000002');
      } else if (abandon == 'background') {
        leaveApp(tester);
        returnToApp(tester);
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      estimate.complete(http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': '0x7530'}), 200));
      await sync;
      await tester.pump();

      if (abandon != 'dispose') {
        for (final key in [
          'tx_nonce_field',
          'tx_gas_limit_field',
          'tx_max_fee_gwei_field',
          'tx_priority_fee_gwei_field',
        ]) {
          expect(
              tester.widget<TextField>(find.byKey(Key(key))).controller!.text,
              isEmpty,
              reason: 'A revoked RPC result must not repopulate $key');
        }
        expect(find.textContaining('來源：'), findsNothing);
        expect(
            find.byKey(const Key('proceed_scan_signature_btn')), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final abandon in ['background', 'dispose']) {
    testWidgets('Bitcoin ignores late UTXOs after $abandon and permits retry',
        (tester) async {
      final directory =
          Directory.systemTemp.createTempSync('fcw_rpc_lifecycle_');
      final path = '${directory.path}/bitcoin.json';
      addTearDown(() => directory.deleteSync(recursive: true));
      final utxos = Completer<http.Response>();
      final methods = <String>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final method = body['method'] as String;
        methods.add(method);
        if (method == 'listunspent') return utxos.future;
        final result = switch (method) {
          'getblockchaininfo' => {'chain': 'regtest'},
          'getwalletinfo' => {'private_keys_enabled': false},
          'getrawtransaction' => '01000000',
          'getdescriptorinfo' => {
              'descriptor': '${body['params'][0]}#public01',
              'isrange': true,
              'hasprivatekeys': false
            },
          'listdescriptors' => {
              'descriptors': [
                {
                  'desc': 'wpkh([12345678/84h/1h/0h]public-test-xpub/1/*)',
                  'range': [0, 100]
                }
              ]
            },
          'deriveaddresses' => List.generate(101, (i) => 'bcrt1qchange$i'),
          'getreceivedbyaddress' => 0,
          _ => throw StateError('Unexpected RPC method: $method'),
        };
        return http.Response(
            jsonEncode({'result': result, 'error': null}), 200);
      });
      addTearDown(client.close);
      final native = _UnsignedBitcoinNative();
      await tester.pumpWidget(MaterialApp(
          home: BitcoinSendScreen(
        account: _btcAccount,
        rpcOverride: BitcoinRpcClient(
            endpoint: 'https://lifecycle.invalid', client: client),
        ffiOverride: native,
        storagePathOverride: path,
      )));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('btc_recipient')), 'bcrt1qrecipient');
      await tester.enterText(find.byKey(const Key('btc_amount')), '0.1');
      await tester.enterText(find.byKey(const Key('btc_fee')), '500');
      final state =
          tester.state<BitcoinSendScreenState>(find.byType(BitcoinSendScreen));
      final creation = state.createRequest();
      await tester.pump();
      expect(methods.last, 'listunspent');
      for (final key in ['btc_recipient', 'btc_amount', 'btc_fee']) {
        expect(tester.widget<TextField>(find.byKey(Key(key))).enabled, isFalse);
      }
      if (abandon == 'background') {
        leaveApp(tester);
        returnToApp(tester);
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      utxos.complete(http.Response(
          jsonEncode({
            'result': [
              {'txid': '33' * 32, 'vout': 0, 'address': _btcAccount.address}
            ],
            'error': null,
          }),
          200));
      await creation;
      await tester.pump();
      expect(native.builds, 0);
      expect(File(path).existsSync(), isFalse);
      if (abandon == 'background') {
        expect(find.text('交易狀態：草稿'), findsOneWidget);
        await state.createRequest();
        await tester.pump();
        expect(native.builds, 1);
        final saved = jsonDecode(File(path).readAsStringSync()) as Map;
        expect(saved['state'], 'awaitingSignature');
        expect(saved['request']['amount_sat'], '10000000');
        expect(saved['response_ur'], isNull);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
