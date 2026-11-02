import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/scan_signature_screen.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/transaction_history.dart';
import 'test_storage_directory.dart';

import 'app_lifecycle.dart';

// Display-only boundary fixtures. No native crypto, valid signed transaction,
// network, devices, or signing primitives are used.
const _account = AccountDescriptor(
    masterFingerprint: '12345678',
    derivationPath: "m/44'/60'/0'/0/0",
    address: '0x1111111111111111111111111111111111111111',
    chainId: 11155111);
final _hash = '0x${'22' * 32}';
final _requestId = '33' * 16;

class _PublicNative implements WalletFfiService {
  @override
  Map<String, dynamic> decodeIntentJson(
          {required String rawRlpHex, required int declaredChainId}) =>
      {'chain_id': declaredChainId, 'recipient': _account.address};

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
        'chain_id': _account.chainId,
        'request_id': expectedRequestIdHex,
        'recovered_address': _account.address,
        'signed_raw_tx_hex': 'public-display-only',
        'local_tx_hash': _hash
      };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}

class _MemoryHistory extends TransactionHistory {
  _MemoryHistory() : super(pathOverride: testHistoryPath());
  final records = <Map<String, dynamic>>[];
  Completer<void>? pendingSave;
  @override
  Future<void> save(Map<String, dynamic> record) async {
    final snapshot = Map<String, dynamic>.from(record);
    if (pendingSave != null) await pendingSave!.future;
    records.add(snapshot);
  }
}

http.Response _evmResult(dynamic result) => http.Response(
    jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': result}), 200);

Future<ScanSignatureScreenState> _mount(
    WidgetTester tester, NodeRpcClient rpc, _MemoryHistory history,
    {String savedState = 'verified'}) async {
  await tester.pumpWidget(MaterialApp(
      home: ScanSignatureScreen(
          account: _account,
          ffiOverride: _PublicNative(),
          rpcOverride: rpc,
          historyOverride: history,
          requestId: _requestId,
          sessionId: 'public-session',
          unsignedRlpHex: 'public-unsigned-display',
          restoredRecord: {
        'account': _account.address,
        'chainId': _account.chainId,
        'derivationPath': _account.derivationPath,
        'masterFingerprint': _account.masterFingerprint.toLowerCase(),
        'compressedPublicKeyHex':
            _account.compressedPublicKeyHex?.toLowerCase(),
        'requestId': _requestId,
        'sessionId': 'public-session',
        'unsignedPayload': 'public-unsigned-display',
        'rpcUrl': rpc.rpcUrl,
        'signatureUr': 'public-response-display',
        'signedRaw': 'public-display-only',
        'hash': _hash,
        'state': savedState
      })));
  await tester.pumpAndSettle();
  if (savedState == 'verified') {
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsOneWidget);
  }
  return tester
      .state<ScanSignatureScreenState>(find.byType(ScanSignatureScreen));
}

void main() {
  test('Bitcoin checks dispatch authorization after the delayed chain check',
      () async {
    final chain = Completer<http.Response>();
    final started = Completer<void>();
    final methods = <String>[];
    var authorized = true;
    final client = MockClient((request) async {
      final method = (jsonDecode(request.body) as Map)['method'] as String;
      methods.add(method);
      if (method == 'getblockchaininfo') {
        started.complete();
        return chain.future;
      }
      return http.Response(
          jsonEncode({'result': '22' * 32, 'error': null}), 200);
    });
    addTearDown(client.close);
    final rpc =
        BitcoinRpcClient(endpoint: 'https://public.invalid', client: client);
    final operation =
        rpc.broadcast('public-display-only', canDispatch: () => authorized);
    await started.future;
    authorized = false;
    final rejected = expectLater(
        operation,
        throwsA(isA<BitcoinRpcException>()
            .having((error) => error.uncertain, 'uncertain', false)));
    chain.complete(http.Response(
        jsonEncode({
          'result': {'chain': 'regtest'},
          'error': null
        }),
        200));
    await rejected;
    expect(methods, ['getblockchaininfo']);
  });

  test('EVM checks dispatch authorization after the delayed chain check',
      () async {
    final chain = Completer<http.Response>();
    final started = Completer<void>();
    final methods = <String>[];
    var authorized = true;
    final client = MockClient((request) async {
      final method = (jsonDecode(request.body) as Map)['method'] as String;
      methods.add(method);
      if (method == 'eth_chainId') {
        started.complete();
        return chain.future;
      }
      return _evmResult(_hash);
    });
    addTearDown(client.close);
    final rpc = NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
    final operation = rpc.sendRawTransaction('public-display-only',
        expectedChainId: _account.chainId, canDispatch: () => authorized);
    await started.future;
    authorized = false;
    final rejected = expectLater(
        operation,
        throwsA(isA<RpcException>().having(
            (error) => error.method, 'method', 'eth_sendRawTransaction')));
    chain.complete(_evmResult('0xaa36a7'));
    await rejected;
    expect(methods, ['eth_chainId']);
    await expectLater(
        rpc.sendRawTransaction('public-display-only', canDispatch: () => false),
        throwsA(isA<RpcException>()));
    expect(methods, ['eth_chainId']);
  });

  for (final abandon in ['background', 'focus loss', 'dispose']) {
    testWidgets(
        'EVM revocation during chain check prevents dispatch after $abandon',
        (tester) async {
      final chain = Completer<http.Response>();
      final methods = <String>[];
      final client = MockClient((request) async {
        final method = (jsonDecode(request.body) as Map)['method'] as String;
        methods.add(method);
        if (method == 'eth_chainId') return chain.future;
        return _evmResult(_hash);
      });
      addTearDown(client.close);
      final rpc =
          NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
      final history = _MemoryHistory();
      final state = await _mount(tester, rpc, history);
      final operation = state.broadcast();
      await tester.pump();
      expect(methods, ['eth_chainId']);
      if (abandon == 'background') {
        leaveApp(tester);
        returnToApp(tester);
      } else if (abandon == 'focus loss') {
        // e.g. the notification shade: inactive without hidden or paused.
        loseAndRegainFocus(tester);
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      chain.complete(_evmResult('0xaa36a7'));
      await operation;
      await tester.pump();
      expect(methods, ['eth_chainId'],
          reason: 'No transaction send after revocation');
      if (abandon != 'dispose') {
        // Nothing was sent, so the screen is back where it was before.
        expect(history.records.last['state'], 'verified');
        expect(find.text(TransactionOutcome.label('verified')), findsOneWidget);
        expect(
            tester
                .widget<SelectableText>(
                    find.byKey(const Key('broadcast_rpc_error_text')))
                .data,
            startsWith('廣播尚未送出'));
        expect(find.byKey(const Key('confirm_broadcast_btn')), findsOneWidget);
        await state.broadcast();
        await tester.pump();
        expect(methods,
            ['eth_chainId', 'eth_chainId', 'eth_sendRawTransaction']);
        expect(history.records.last['state'], 'accepted');
      } else {
        // A closed screen's record reopens as query-only.
        expect(history.records.last['state'], 'broadcasting');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'EVM revocation during history save prevents dispatch after $abandon',
        (tester) async {
      final methods = <String>[];
      final client = MockClient((request) async {
        methods.add((jsonDecode(request.body) as Map)['method'] as String);
        return _evmResult('0xaa36a7');
      });
      addTearDown(client.close);
      final rpc =
          NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
      final history = _MemoryHistory();
      final state = await _mount(tester, rpc, history);
      history.pendingSave = Completer<void>();
      final operation = state.broadcast();
      await tester.pump();
      if (abandon == 'background') {
        leaveApp(tester);
        returnToApp(tester);
      } else if (abandon == 'focus loss') {
        loseAndRegainFocus(tester);
      } else {
        await tester.pumpWidget(const SizedBox());
      }
      history.pendingSave!.complete();
      await operation;
      await tester.pump();
      expect(methods, isEmpty);
      expect(history.records.last['state'],
          abandon == 'dispose' ? 'broadcasting' : 'verified');
      if (abandon != 'dispose') {
        expect(find.byKey(const Key('confirm_broadcast_btn')), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (fail, focusOnly) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true)
  ]) {
    testWidgets(
        'late EVM send ${fail ? 'error' : 'completion'} cannot write after revocation${focusOnly ? ' by focus loss' : ''}',
        (tester) async {
      final sent = Completer<http.Response>();
      final methods = <String>[];
      final client = MockClient((request) async {
        final method = (jsonDecode(request.body) as Map)['method'] as String;
        methods.add(method);
        if (method == 'eth_sendRawTransaction') return sent.future;
        return _evmResult('0xaa36a7');
      });
      addTearDown(client.close);
      final rpc =
          NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
      final history = _MemoryHistory();
      final state = await _mount(tester, rpc, history);
      final operation = state.broadcast();
      await tester.pump();
      expect(methods, ['eth_chainId', 'eth_sendRawTransaction']);
      if (focusOnly) {
        loseAndRegainFocus(tester);
      } else {
        leaveApp(tester);
        returnToApp(tester);
      }
      expect(history.records.last['state'], 'unknown');
      final writes = history.records.length;
      if (fail) {
        sent.completeError(StateError('synthetic transport failure'));
      } else {
        sent.complete(_evmResult(_hash));
      }
      await operation;
      await tester.pump();
      expect(history.records.length, writes);
      expect(history.records.last['state'], 'unknown');
      expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a revoked EVM chain check cannot hide a newer dispatched send',
      (tester) async {
    final staleChain = Completer<http.Response>();
    final sent = Completer<http.Response>();
    final methods = <String>[];
    final client = MockClient((request) async {
      final method = (jsonDecode(request.body) as Map)['method'] as String;
      methods.add(method);
      if (method == 'eth_chainId') {
        final first = methods.where((m) => m == 'eth_chainId').length == 1;
        return first ? await staleChain.future : _evmResult('0xaa36a7');
      }
      if (method == 'eth_sendRawTransaction') return sent.future;
      // The node has neither a receipt nor the transaction itself.
      return _evmResult(null);
    });
    addTearDown(client.close);
    final rpc = NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
    final history = _MemoryHistory();
    final state = await _mount(tester, rpc, history);

    // A waits for its chain check and is revoked by leaving the app.
    final a = state.broadcast();
    await tester.pump();
    leaveApp(tester);
    returnToApp(tester);
    await tester.pump();
    await state.queryTransaction();
    await tester.pump();
    expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);

    // B passes its own checks and reaches the node.
    final b = state.broadcast();
    await tester.pump();
    expect(methods.where((m) => m == 'eth_sendRawTransaction'), hasLength(1));

    // A's late chain check answers while B is in flight.
    staleChain.complete(_evmResult('0xaa36a7'));
    await a;
    await tester.pump();
    expect(methods.where((m) => m == 'eth_sendRawTransaction'), hasLength(1));

    // Leaving again must treat B as dispatched.
    leaveApp(tester);
    await tester.pump();
    returnToApp(tester);
    await tester.pump();
    expect(history.records.last['state'], 'unknown');
    expect(find.text(TransactionOutcome.label('unknown')), findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('broadcast_rpc_error_text')))
            .data,
        contains('送出期間已離開前景'));
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
    final writes = history.records.length;
    sent.complete(_evmResult(_hash));
    await b;
    await tester.pump();
    expect(history.records, hasLength(writes));
    expect(methods.where((m) => m == 'eth_sendRawTransaction'), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a revoked resend asks for another lookup before resending',
      (tester) async {
    Completer<http.Response>? chain;
    final methods = <String>[];
    final client = MockClient((request) async {
      final method = (jsonDecode(request.body) as Map)['method'] as String;
      methods.add(method);
      if (method == 'eth_chainId') {
        return chain == null ? _evmResult('0xaa36a7') : await chain.future;
      }
      // The node has neither a receipt nor the transaction itself.
      return _evmResult(null);
    });
    addTearDown(client.close);
    final rpc = NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
    final history = _MemoryHistory();
    final state = await _mount(tester, rpc, history, savedState: 'unknown');
    await state.queryTransaction();
    await tester.pump();
    expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);

    // The resend waits for its chain check and is revoked by leaving.
    chain = Completer<http.Response>();
    final resend = state.broadcast();
    await tester.pump();
    leaveApp(tester);
    returnToApp(tester);
    chain.complete(_evmResult('0xaa36a7'));
    await resend;
    await tester.pump();
    expect(methods, isNot(contains('eth_sendRawTransaction')));
    expect(history.records.last['state'], 'unknown');
    expect(find.text(TransactionOutcome.label('unknown')), findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('broadcast_rpc_error_text')))
            .data,
        allOf(contains('這次重新傳送沒有送出；前一次送出的結果仍待查'), contains('再查詢同一筆交易'),
            isNot(contains('廣播尚未送出'))));
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
    expect(find.byKey(const Key('query_transaction_btn')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('background during an EVM send leaves the outcome pending query',
      (tester) async {
    final sent = Completer<http.Response>();
    final methods = <String>[];
    final client = MockClient((request) async {
      final method = (jsonDecode(request.body) as Map)['method'] as String;
      methods.add(method);
      if (method == 'eth_sendRawTransaction') return sent.future;
      // The node has neither a receipt nor the transaction itself.
      return _evmResult(method == 'eth_chainId' ? '0xaa36a7' : null);
    });
    addTearDown(client.close);
    final rpc = NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
    final history = _MemoryHistory();
    final state = await _mount(tester, rpc, history);
    final operation = state.broadcast();
    await tester.pump();
    expect(methods, ['eth_chainId', 'eth_sendRawTransaction']);
    leaveApp(tester);
    await tester.pump();
    returnToApp(tester);
    await tester.pump();
    expect(find.text(TransactionOutcome.label('unknown')), findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('broadcast_rpc_error_text')))
            .data,
        contains('結果待查'));
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
    expect(find.byKey(const Key('query_transaction_btn')), findsOneWidget);
    expect(history.records.last['state'], 'unknown');
    final writes = history.records.length;

    // The revoked send's late acceptance cannot replace the pending query.
    sent.complete(_evmResult(_hash));
    await operation;
    await tester.pump();
    expect(history.records, hasLength(writes));
    expect(find.text(TransactionOutcome.label('unknown')), findsOneWidget);

    // Only a lookup of the same hash may offer to resend the same bytes.
    await state.queryTransaction();
    await tester.pump();
    expect(methods.last, 'eth_getTransactionByHash');
    expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);
    expect(methods.where((method) => method == 'eth_sendRawTransaction'),
        hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a saved broadcasting record reopens as query-only',
      (tester) async {
    // e.g. 1.1.0 left `broadcasting` on disk when the app was killed mid-send.
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add((jsonDecode(request.body) as Map)['method'] as String);
      return _evmResult('0xaa36a7');
    });
    addTearDown(client.close);
    final rpc = NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
    final history = _MemoryHistory();
    await _mount(tester, rpc, history, savedState: 'broadcasting');
    expect(find.text(TransactionOutcome.label('unknown')), findsOneWidget);
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
    expect(find.byKey(const Key('query_transaction_btn')), findsOneWidget);
    expect(history.records.last['state'], 'unknown');
    expect(methods, isEmpty, reason: 'Reopening never sends a transaction');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('revoked EVM receipt lookup cannot persist a late outcome',
      (tester) async {
    final receipt = Completer<http.Response>();
    final methods = <String>[];
    final client = MockClient((request) async {
      final method = (jsonDecode(request.body) as Map)['method'] as String;
      methods.add(method);
      if (method == 'eth_getTransactionReceipt') return receipt.future;
      return _evmResult('0xaa36a7');
    });
    addTearDown(client.close);
    final rpc = NodeRpcClient(rpcUrl: 'https://public.invalid', client: client);
    final history = _MemoryHistory();
    final state = await _mount(tester, rpc, history);
    final writes = history.records.length;
    final operation = state.queryTransaction();
    await tester.pump();
    expect(methods, ['eth_chainId', 'eth_getTransactionReceipt']);
    leaveApp(tester);
    returnToApp(tester);
    receipt.complete(_evmResult(
        {'transactionHash': _hash, 'blockNumber': '0x1', 'status': '0x1'}));
    await operation;
    await tester.pump();
    expect(history.records.length, writes);
    expect(history.records.last['state'], 'verified');
    expect(find.text('已確認（執行成功）'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
