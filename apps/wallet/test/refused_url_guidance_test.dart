import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/screens/bitcoin_send_screen.dart';
import 'package:wallet/screens/scan_signature_screen.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/node_url_policy.dart';
import 'package:wallet/services/transaction_history.dart';

// Every place that meets a refused public http:// URL gives the same
// guidance, and the Bitcoin record never stores one. Public display
// fixtures only; nothing is signed and no network is used.
const _evmAccount = AccountDescriptor(
  masterFingerprint: '12345678',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
  chainId: 11155111,
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
const _refusedUrl = 'http://example.com:8545';
const _localBtcUrl = 'http://127.0.0.1:18443/wallet/fcw_watch';
const _oldBtcUrl = 'http://example.com:18443/wallet/old';

String _guidance(String outcome, String settings) =>
    '已不再允許使用此節點網址：公開網路上的節點請使用 https://。本次$outcome，請到$settings修改網址。';

class _PublicFfi implements WalletFfiService {
  @override
  int init() => 0;
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      true;
  @override
  Map<String, dynamic> decodeIntentJson(
          {required String rawRlpHex, required int declaredChainId}) =>
      {'chain_id': declaredChainId, 'recipient': _evmAccount.address};
  @override
  void cancelPendingSession(String sessionId) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}

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

class _MemoryHistory extends TransactionHistory {
  final records = <Map<String, dynamic>>[];
  @override
  Future<void> save(Map<String, dynamic> record) async =>
      records.add(Map<String, dynamic>.from(record));
}

NodeRpcClient _refusedRpc(List<String> requests) => NodeRpcClient(
    rpcUrl: _refusedUrl,
    client: MockClient((request) async {
      requests.add((jsonDecode(request.body) as Map)['method'] as String);
      return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': '0xaa36a7'}), 200);
    }));

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('refused_url_'));
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> expandAndType(
      WidgetTester tester, Key toggle, Key field, String url) async {
    await tester.ensureVisible(find.byKey(toggle));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(toggle));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(field));
    await tester.enterText(find.byKey(field), url);
    await tester.pumpAndSettle();
  }

  // (endpoint in the record, text typed before archiving, endpoint expected)
  for (final (stored, typed, expected) in [
    (_localBtcUrl, 'http://example.com:18443/wallet/x', _localBtcUrl),
    // A record from before 1.2.1 has no allowed URL to fall back to.
    (_oldBtcUrl, 'http://example.com:18443/wallet/x', ''),
    (_oldBtcUrl, null, ''),
    (
      _oldBtcUrl,
      'http://192.168.1.5:18443/wallet/x',
      'http://192.168.1.5:18443/wallet/x'
    ),
  ]) {
    testWidgets(
        'the Bitcoin record never stores a refused node URL '
        '($stored, typed $typed)', (tester) async {
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
        'rpc_endpoint': stored,
        'state': 'verified',
        'request': request,
        'built': _ReplayNative().build(request),
        'response_ur': 'ur:crypto-psbt/public-signed-fixture',
        'history': <dynamic>[],
      }));
      await tester.pumpWidget(MaterialApp(
          home: BitcoinSendScreen(
              account: _btcAccount,
              ffiOverride: _ReplayNative(),
              storagePathOverride: path)));
      await tester.pumpAndSettle();
      if (typed != null) {
        await expandAndType(tester, const Key('btc_node_settings_toggle'),
            const Key('btc_rpc_endpoint'), typed);
      }

      // Archiving writes the record: everything but a refused URL.
      tester
          .state<BitcoinSendScreenState>(find.byType(BitcoinSendScreen))
          .newDraft();
      await tester.pumpAndSettle();
      final saved = jsonDecode(File(path).readAsStringSync()) as Map;
      expect((saved['history'] as List).single['txid'], '22' * 32);
      expect(saved['rpc_endpoint'], expected);
      expect(NodeUrlPolicy.classify(saved['rpc_endpoint'] as String),
          isNot(NodeUrlKind.publicHttp));
      // The field keeps what the user sees, so it can be corrected.
      expect(
          tester
              .widget<TextField>(find.byKey(const Key('btc_rpc_endpoint'),
                  skipOffstage: false))
              .controller!
              .text,
          typed ?? stored);
    });
  }

  testWidgets('Bitcoin sync and request building give the URL guidance',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: BitcoinSendScreen(
            account: _btcAccount,
            ffiOverride: _ReplayNative(),
            storagePathOverride: '${directory.path}/bitcoin.json')));
    await tester.pumpAndSettle();
    await expandAndType(tester, const Key('btc_node_settings_toggle'),
        const Key('btc_rpc_endpoint'), 'http://example.com:18443/wallet/x');
    final state =
        tester.state<BitcoinSendScreenState>(find.byType(BitcoinSendScreen));
    String error() =>
        tester.widget<SelectableText>(find.byKey(const Key('btc_error'))).data!;

    await state.syncDescriptors();
    await tester.pumpAndSettle();
    expect(error(), _guidance('沒有連線到節點', '節點設定'));

    await tester.enterText(
        find.byKey(const Key('btc_recipient')), 'bcrt1qrecipient');
    await tester.enterText(find.byKey(const Key('btc_amount')), '0.0001');
    await tester.enterText(find.byKey(const Key('btc_fee')), '200');
    await state.createRequest();
    await tester.pumpAndSettle();
    expect(error(), _guidance('未建立交易', '節點設定'));
    expect(File('${directory.path}/bitcoin.json').existsSync(), isFalse);
  });

  testWidgets('EVM balances give the URL guidance, not an outage',
      (tester) async {
    final path = '${directory.path}/accounts.json';
    AccountStore(path).save(
        const AccountSnapshot(accounts: [_evmAccount], rpcUrl: _refusedUrl));
    final requests = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: AccountScreen(
            ffiOverride: _PublicFfi(),
            rpcOverride: _refusedRpc(requests),
            storagePathOverride: path)));
    await tester.pumpAndSettle();
    await tester
        .state<AccountScreenState>(find.byType(AccountScreen))
        .refreshBalances();
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(
        tester
            .widget<Text>(find.byKey(const Key('rpc_status_message_text')))
            .data,
        _guidance('沒有連線到節點', '網路與節點設定'));
  });

  testWidgets('a backup-restored EVM record gives the URL guidance',
      (tester) async {
    final requests = <String>[];
    final history = _MemoryHistory();
    await tester.pumpWidget(MaterialApp(
        home: ScanSignatureScreen(
            account: _evmAccount,
            ffiOverride: _PublicFfi(),
            rpcOverride: _refusedRpc(requests),
            historyOverride: history,
            requestId: '33' * 16,
            sessionId: 'public-session',
            unsignedRlpHex: 'public-unsigned-display',
            restoredRecord: {
          'account': _evmAccount.address,
          'chainId': _evmAccount.chainId,
          'derivationPath': _evmAccount.derivationPath,
          'masterFingerprint': _evmAccount.masterFingerprint.toLowerCase(),
          'compressedPublicKeyHex':
              _evmAccount.compressedPublicKeyHex?.toLowerCase(),
          'requestId': '33' * 16,
          'sessionId': 'public-session',
          'unsignedPayload': 'public-unsigned-display',
          'rpcUrl': '',
          'signatureUr': 'public-response-display',
          'signedRaw': 'public-display-only',
          'hash': '0x${'22' * 32}',
          'state': 'unknown'
        })));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(history.records, isEmpty);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('signature_verification_error_text')))
            .data,
        _guidance('沒有連線到節點', '網路與節點設定'));
  });
}
