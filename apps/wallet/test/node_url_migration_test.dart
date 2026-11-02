import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/scan_signature_screen.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/transaction_history.dart';
import 'test_storage_directory.dart';

// A record saved before 1.2.1 against a public http:// node, reopened after
// the user moved that node to https:// as the refusal message asks.
// Public display fixtures only; nothing is signed and no network is used.
const _account = AccountDescriptor(
    masterFingerprint: '12345678',
    derivationPath: "m/44'/60'/0'/0/0",
    address: '0x1111111111111111111111111111111111111111',
    chainId: 11155111);
final _hash = '0x${'22' * 32}';
final _requestId = '33' * 16;
const _oldUrl = 'http://example.com:8545';
const _newUrl = 'https://example.com:8545';

class _PublicNative implements WalletFfiService {
  int registrations = 0;
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
      int maxFragmentLen = 120}) {
    registrations++;
    return {'status': 'PENDING_REGISTERED'};
  }

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
  @override
  Future<void> save(Map<String, dynamic> record) async =>
      records.add(Map<String, dynamic>.from(record));
}

/// Answers `eth_chainId` with [chainId] and records every method asked.
NodeRpcClient _node(String url, List<String> methods,
        {int chainId = 11155111}) =>
    NodeRpcClient(
        rpcUrl: url,
        client: MockClient((request) async {
          methods.add((jsonDecode(request.body) as Map)['method'] as String);
          return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'result': '0x${chainId.toRadixString(16)}'
              }),
              200);
        }));

Map<String, dynamic> _record(String rpcUrl, String state,
        {bool signed = true}) =>
    {
      'account': _account.address,
      'chainId': _account.chainId,
      'derivationPath': _account.derivationPath,
      'masterFingerprint': _account.masterFingerprint.toLowerCase(),
      'compressedPublicKeyHex':
          _account.compressedPublicKeyHex?.toLowerCase(),
      'requestId': _requestId,
      'sessionId': 'public-session',
      'unsignedPayload': 'public-unsigned-display',
      'rpcUrl': rpcUrl,
      if (signed) ...{
        'signatureUr': 'public-response-display',
        'signedRaw': 'public-display-only',
        'hash': _hash,
      },
      'state': state
    };

Future<void> _mount(WidgetTester tester, NodeRpcClient rpc,
    _MemoryHistory history, Map<String, dynamic> record,
    {_PublicNative? native}) async {
  await tester.pumpWidget(MaterialApp(
      home: ScanSignatureScreen(
          account: _account,
          ffiOverride: native ?? _PublicNative(),
          rpcOverride: rpc,
          historyOverride: history,
          requestId: _requestId,
          sessionId: 'public-session',
          unsignedRlpHex: 'public-unsigned-display',
          restoredRecord: record)));
  await tester.pumpAndSettle();
}

String? _error(WidgetTester tester) {
  for (final key in [
    'broadcast_rpc_error_text',
    'signature_verification_error_text'
  ]) {
    final found = find.byKey(Key(key));
    if (found.evaluate().isNotEmpty) {
      return tester.widget<SelectableText>(found).data;
    }
  }
  return null;
}

void main() {
  // Same node moved to https, and another provider on the same chain.
  for (final (saved, from, to) in [
    ('verified', _oldUrl, _newUrl),
    ('unknown', _oldUrl, _newUrl),
    ('verified', 'http://a.example:8545', 'https://b.example'),
  ]) {
    testWidgets('a record saved as $saved moves from $from to $to',
        (tester) async {
      final methods = <String>[];
      final history = _MemoryHistory();
      await _mount(tester, _node(to, methods), history, _record(from, saved));

      expect(_error(tester), isNull);
      expect(methods, ['eth_chainId'], reason: 'the new node proves its chain');
      expect(find.byKey(const Key('verified_tx_hash_text')), findsOneWidget);
      // The move is said, not silent.
      expect(
          find.descendant(
              of: find.byKey(const Key('refused_rpc_migration_notice')),
              matching: find.text(
                  '原請求綁定的節點使用公開網路上的 http://，已不再允許。已核對目前 RPC 的 Chain ID，並改用此 RPC。')),
          findsOneWidget);
      final rebound = history.records.single;
      expect(rebound['rpcUrl'], to);
      expect(rebound['state'], saved);
      expect(rebound['hash'], _hash);
      expect(rebound['signedRaw'], 'public-display-only');
      expect(rebound['signatureUr'], 'public-response-display');
      expect(rebound['unsignedPayload'], 'public-unsigned-display');
      expect(rebound['account'], _account.address);
      // Possibly sent: only a lookup may decide whether it can be resent.
      expect(find.byKey(const Key('confirm_broadcast_btn')),
          saved == 'verified' ? findsOneWidget : findsNothing);
      expect(find.byKey(const Key('query_transaction_btn')),
          saved == 'verified' ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('an unsigned record moves to the https node on confirmation',
      (tester) async {
    final methods = <String>[];
    final native = _PublicNative();
    await _mount(tester, _node(_newUrl, methods), _MemoryHistory(),
        _record(_oldUrl, 'awaitingSignature', signed: false),
        native: native);
    expect(_error(tester), isNull);
    expect(
        find.descendant(
            of: find.byKey(const Key('refused_rpc_migration_notice')),
            matching: find.textContaining('節點使用公開網路上的 http://，已不再允許')),
        findsOneWidget);
    final confirm = find.byKey(const Key('confirm_existing_signature_btn'));
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(_error(tester), isNull);
    expect(methods, ['eth_chainId']);
    expect(native.registrations, 1,
        reason: 'the original request, not a new one');
  });

  testWidgets('the new node must report the record chain before rebinding',
      (tester) async {
    final methods = <String>[];
    final history = _MemoryHistory();
    await _mount(tester, _node(_newUrl, methods, chainId: 1), history,
        _record(_oldUrl, 'verified'));
    expect(_error(tester), contains('無法還原交易'));
    expect(history.records, isEmpty);
    expect(find.byKey(const Key('confirm_broadcast_btn')), findsNothing);
  });

  for (final (from, to) in [
    ('https://old.example.com', _newUrl),
    ('http://192.168.1.5:8545', _newUrl),
    (_oldUrl, 'http://203.0.113.9:8545'),
  ]) {
    testWidgets('any other RPC change still refuses replay ($from -> $to)',
        (tester) async {
      final methods = <String>[];
      final history = _MemoryHistory();
      await _mount(
          tester, _node(to, methods), history, _record(from, 'verified'));
      expect(_error(tester), contains('原始請求、帳戶、網路或 RPC 已變更，拒絕重播'));
      expect(methods, isEmpty);
      expect(history.records, isEmpty);
    });
  }
}
