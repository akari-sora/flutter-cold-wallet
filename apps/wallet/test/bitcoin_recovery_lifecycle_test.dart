import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/screens/bitcoin_send_screen.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';

import 'app_lifecycle.dart';

// Synthetic public-only boundaries: no native crypto, keys, network or sending.
const account = AccountDescriptor(
    masterFingerprint: '12345678',
    derivationPath: "m/84'/1'/0'",
    address: 'bcrt1qpublic',
    chainId: 0,
    assetFamily: 'BTC',
    extendedPublicKey: 'tpubPublicFixture',
    btcReceiveAddressRegtest: 'bcrt1qpublic',
    btcChangeAddress: 'bcrt1qchange');

class PublicNative implements BitcoinFfiService {
  int builds = 0;
  int verifies = 0;
  final builtAmounts = <String>[];
  @override
  Map<String, dynamic> build(Map<String, dynamic> request) {
    builds++;
    builtAmounts.add(request['amount_sat'] as String);
    final tag = request['amount_sat'] == '10000000' ? '11' : '22';
    return {
      'status': 'SUCCESS',
      'network': 'regtest',
      'psbt_hex': '70736274ff$tag',
      'expected_digest': tag * 32,
      'txid': tag * 32,
      'ur_frames': ['ur:crypto-psbt/public-fixture'],
      'recipient_address': request['recipient_address'],
      'amount_sat': request['amount_sat'],
      'fee_sat': request['fee_sat'],
      'change_address': 'bcrt1qchange',
      'change_sat': '10000'
    };
  }

  @override
  Map<String, dynamic> verify(Map<String, dynamic> request) {
    verifies++;
    final tag =
        (request['original_psbt_hex'] as String).endsWith('11') ? '11' : '22';
    return {
      'status': 'VERIFIED',
      'tx_hex': 'public-display-only',
      'txid': tag * 32
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}

class PublicNode extends BitcoinRpcClient {
  PublicNode() : super(endpoint: 'https://public-fixture.invalid');
  Completer<Map<String, dynamic>>? pending;
  Completer<List<Map<String, dynamic>>>? pendingUtxos;
  final lookups = <String>[];
  int loads = 0;
  String utxoTag = '33';

  /// confirmed: block result; mempool: verbose result without confirmations;
  /// notFound: Bitcoin Core -5 for bytes that never reached this node.
  String status = 'confirmed';

  /// forbidden: any send fails the test; revoked/offline: rejected before
  /// sendrawtransaction; accept: the synthetic bytes are recorded and accepted.
  String send = 'forbidden';
  final sent = <String>[];
  @override
  Future<int> unusedChangeIndex(AccountDescriptor account) async => 0;

  @override
  Future<List<Map<String, dynamic>>> loadUtxos(
      AccountDescriptor account) async {
    loads++;
    if (pendingUtxos != null) return await pendingUtxos!.future;
    return [
      {
        'txid': utxoTag * 32,
        'vout': 0,
        'previous_tx_hex': '00',
        'branch': 0,
        'address_index': 0
      }
    ];
  }

  @override
  Future<Map<String, dynamic>> transactionStatus(String txid) async {
    lookups.add(txid);
    if (pending != null) return await pending!.future;
    switch (status) {
      case 'mempool':
        return {'txid': txid, 'hex': '00'};
      case 'notFound':
        throw const BitcoinRpcException(
            'Bitcoin RPC getrawtransaction 拒絕：-5 No such mempool or blockchain transaction',
            code: -5,
            rpcMessage:
                'No such mempool or blockchain transaction. Use gettransaction for wallet transactions.');
      case 'noTxindex':
        throw const BitcoinRpcException(
            'Bitcoin RPC getrawtransaction 拒絕：-5 No such mempool transaction',
            code: -5,
            rpcMessage:
                'No such mempool transaction. Use -txindex or provide a block hash to enable blockchain transaction queries. Use gettransaction for wallet transactions.');
    }
    return {'confirmations': 3};
  }

  @override
  Future<String> broadcast(String rawTransaction,
      {bool Function()? canDispatch}) async {
    switch (send) {
      case 'revoked':
        throw const BitcoinRpcException('廣播授權已撤銷，交易尚未傳送', notSent: true);
      case 'offline':
        throw const BitcoinRpcException(
            'Bitcoin RPC getblockchaininfo 無法連線；交易尚未傳送',
            notSent: true);
      case 'accept':
        sent.add(rawTransaction);
        return '11' * 32;
    }
    throw StateError('Sending is forbidden in this fixture');
  }
}

void main() {
  late Directory directory;
  late File file;
  late PublicNode node;
  late PublicNative native;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('fcw_public_btc_recovery_');
    file = File('${directory.path}/bitcoin.json');
    node = PublicNode();
    native = PublicNative();
  });
  tearDown(() {
    node.close();
    directory.deleteSync(recursive: true);
  });

  Future<BitcoinSendScreenState> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: BitcoinSendScreen(
            account: account,
            rpcOverride: node,
            ffiOverride: native,
            storagePathOverride: file.path)));
    await tester.pumpAndSettle();
    return tester.state<BitcoinSendScreenState>(find.byType(BitcoinSendScreen));
  }

  Future<void> create(WidgetTester tester, BitcoinSendScreenState state,
      {String amount = '0.1', bool verified = true}) async {
    await tester.enterText(
        find.byKey(const Key('btc_recipient')), 'bcrt1qrecipient');
    await tester.enterText(find.byKey(const Key('btc_amount')), amount);
    await tester.enterText(find.byKey(const Key('btc_fee')), '500');
    await state.createRequest();
    if (verified) await state.ingestSignature('synthetic-public-response');
    await tester.pump();
  }

  testWidgets('pending restore blocks BTC creation before node access', (
    tester,
  ) async {
    File(
      '${directory.path}/public_import_progress.json',
    ).writeAsStringSync('{');
    final state = await mount(tester);
    await create(tester, state, verified: false);
    expect(node.loads, 0);
    expect(native.builds, 0);
    expect(file.existsSync(), isFalse);
    expect(find.textContaining('公開備份仍保留此帳戶'), findsOneWidget);
  });

  testWidgets('restore started while loading UTXOs blocks BTC creation', (
    tester,
  ) async {
    node.pendingUtxos = Completer<List<Map<String, dynamic>>>();
    final state = await mount(tester);
    await tester.enterText(
      find.byKey(const Key('btc_recipient')),
      'bcrt1qrecipient',
    );
    await tester.enterText(find.byKey(const Key('btc_amount')), '0.1');
    await tester.enterText(find.byKey(const Key('btc_fee')), '500');
    final operation = state.createRequest();
    await tester.pump();
    expect(node.loads, 1);
    File(
      '${directory.path}/public_import_progress.json',
    ).writeAsStringSync('{');
    node.pendingUtxos!.complete([
      {
        'txid': '33' * 32,
        'vout': 0,
        'previous_tx_hex': '00',
        'branch': 0,
        'address_index': 0,
      },
    ]);
    await operation;
    await tester.pump();
    expect(native.builds, 0);
    expect(file.existsSync(), isFalse);
    expect(find.textContaining('公開備份仍保留此帳戶'), findsOneWidget);
  });

  Map<String, dynamic> requestWith(List<Map<String, dynamic>> utxos) => {
        'account_xpub': account.extendedPublicKey,
        'master_fingerprint': account.masterFingerprint,
        'recipient_address': 'bcrt1qarchived',
        'amount_sat': '10000000',
        'fee_sat': '500',
        'change_index': 0,
        'utxos': utxos,
      };

  Map<String, dynamic> builtWith(String tag) => {
        'status': 'SUCCESS',
        'network': 'regtest',
        'psbt_hex': '70736274ff$tag',
        'expected_digest': tag * 32,
        'txid': tag * 32,
        'ur_frames': ['ur:crypto-psbt/public-fixture'],
        'recipient_address': 'bcrt1qarchived',
        'amount_sat': '10000000',
        'fee_sat': '500',
        'change_address': 'bcrt1qchange',
        'change_sat': '10000'
      };

  void writeDraftWithHistory(List<Map<String, dynamic>> history) {
    file.writeAsStringSync(jsonEncode({
      'schema_version': 2,
      'account_address': account.address,
      'master_fingerprint': account.masterFingerprint,
      'rpc_endpoint': 'https://public-fixture.invalid',
      'state': 'draft',
      'request': null,
      'built': null,
      'response_ur': null,
      'history': history,
    }));
  }

  testWidgets('pending import refuses a new signature and preserves the request',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state, verified: false);
    final before = file.readAsBytesSync();
    File('${directory.path}/public_import_progress.json').writeAsStringSync('{');
    await state.ingestSignature('ur:crypto-psbt/new-signature');
    expect(native.verifies, 0);
    expect(file.readAsBytesSync(), before);
  });

  testWidgets('pending import permits query and preserves the complete archive',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    final active = jsonDecode(file.readAsStringSync()) as Map;
    File('${directory.path}/public_import_progress.json').writeAsStringSync('{');
    await state.checkStatus();
    expect(node.lookups, isNotEmpty);
    state.newDraft();
    final archived = jsonDecode(file.readAsStringSync()) as Map;
    final recovery = (archived['history'] as List).single['recovery'] as Map;
    expect(recovery['request'], active['request']);
    expect(recovery['built'], active['built']);
    expect(recovery['response_ur'], active['response_ur']);
    expect(archived['request'], isNull);
  });

  testWidgets('pending archive rejects a same-TXID collision without writes',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    state.restoreHistory(0);
    await state.checkStatus();
    final before = file.readAsBytesSync();
    File('${directory.path}/public_import_progress.json').writeAsStringSync('{');
    state.newDraft();
    expect(file.readAsBytesSync(), before);
    await tester.pump();
    expect(find.textContaining('相同 TXID'), findsOneWidget);
  });

  testWidgets('pending archive rejects unknown historical inputs without writes',
      (tester) async {
    writeDraftWithHistory([{
      'txid': '55' * 32, 'state': 'confirmed', 'amount_sat': '1',
      'recipient_address': 'bcrt1qpublic'
    }]);
    final state = await mount(tester);
    await create(tester, state);
    final before = file.readAsBytesSync();
    File('${directory.path}/public_import_progress.json').writeAsStringSync('{');
    state.newDraft();
    expect(file.readAsBytesSync(), before);
    await tester.pump();
    expect(find.textContaining('缺少可核對的保留輸入'), findsOneWidget);
  });

  testWidgets('archive survives restart and restores signed bytes query-only',
      (tester) async {
    var state = await mount(tester);
    await create(tester, state);
    final active = jsonDecode(file.readAsStringSync()) as Map;
    state.newDraft();
    await tester.pump();
    final archived = jsonDecode(file.readAsStringSync()) as Map;
    final recovery = archived['history'][0]['recovery'] as Map;
    expect(recovery['request'], active['request']);
    expect(recovery['built'], active['built']);
    expect(recovery['response_ur'], active['response_ur']);
    expect(archived['request'], isNull);
    await tester.pumpWidget(const SizedBox());
    state = await mount(tester);
    state.restoreHistory(0);
    await tester.pump();
    expect(node.lookups, isEmpty,
        reason: 'Restore must not access a node automatically');
    expect(find.text('交易狀態：結果待查'), findsOneWidget);
    expect(find.byKey(const Key('btc_broadcast')), findsNothing);
    expect((jsonDecode(file.readAsStringSync()) as Map)['response_ur'],
        active['response_ur']);
    await state.checkStatus();
    await tester.pump();
    expect(node.lookups, ['11' * 32]);
    expect(find.textContaining('確認數：3'), findsOneWidget);
    expect((jsonDecode(file.readAsStringSync()) as Map)['confirmations'], 3);
  });

  testWidgets('a new draft starts with an empty recipient, amount and fee',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    await tester.pump();
    for (final key in ['btc_recipient', 'btc_amount', 'btc_fee']) {
      expect(
          tester.widget<TextField>(find.byKey(Key(key))).controller!.text, '',
          reason: '$key must not carry over into the next transaction');
    }
  });

  testWidgets(
      'archived exported PSBT keeps its inputs reserved from a new payment',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state, verified: false);
    expect(native.builds, 1);
    state.newDraft();
    await tester.pump();
    final archived = jsonDecode(file.readAsStringSync()) as Map;
    expect(archived['history'][0]['state'], 'awaitingSignature');
    await tester.enterText(
        find.byKey(const Key('btc_recipient')), 'bcrt1qrecipient2');
    await tester.enterText(find.byKey(const Key('btc_amount')), '0.2');
    await tester.enterText(find.byKey(const Key('btc_fee')), '500');
    await state.createRequest();
    await tester.pump();
    expect(native.builtAmounts, isNot(contains('20000000')),
        reason: 'The native builder must never receive a reserved input');
    expect(find.textContaining('仍被先前交易保留'), findsOneWidget);
  });

  for (final fixture
      in <({String error, String name, Map<String, dynamic> row})>[
    (
      error: 'Bitcoin 歷史',
      name: 'legacy cancelled without recovery',
      row: {
        'txid': '11' * 32,
        'state': 'cancelled',
        'amount_sat': '10000000',
        'recipient_address': 'bcrt1qarchived',
      }
    ),
    (
      error: 'Bitcoin 歷史',
      name: 'empty input list',
      row: {
        'txid': '11' * 32,
        'state': 'awaitingSignature',
        'recovery': {
          'request': requestWith(const []),
          'built': builtWith('11'),
          'response_ur': null,
        }
      }
    ),
    (
      error: 'Bitcoin 歷史',
      name: 'non-hex txid',
      row: {
        'txid': '11' * 32,
        'state': 'awaitingSignature',
        'recovery': {
          'request': requestWith([
            {'txid': 'not-a-txid', 'vout': 0}
          ]),
          'built': builtWith('11'),
          'response_ur': null,
        }
      }
    ),
    (
      error: 'Bitcoin 歷史',
      name: 'negative vout',
      row: {
        'txid': '11' * 32,
        'state': 'awaitingSignature',
        'recovery': {
          'request': requestWith([
            {'txid': '44' * 32, 'vout': -1}
          ]),
          'built': builtWith('11'),
          'response_ur': null,
        }
      }
    ),
    (
      error: 'PSBT',
      name: 'PSBT mismatch',
      row: {
        'txid': '22' * 32,
        'state': 'awaitingSignature',
        'recovery': {
          'request': requestWith([
            {'txid': '44' * 32, 'vout': 0}
          ]),
          'built': builtWith('22'),
          'response_ur': null,
        }
      }
    ),
  ]) {
    testWidgets('${fixture.name} blocks a competing payment', (tester) async {
      writeDraftWithHistory([fixture.row]);
      final before = file.readAsStringSync();
      final state = await mount(tester);
      await create(tester, state, amount: '0.2', verified: false);
      expect(native.builtAmounts, isNot(contains('20000000')),
          reason: 'Malformed archived evidence must fail before a new PSBT');
      expect(file.readAsStringSync(), before,
          reason: 'The original reconciliation evidence must be preserved');
      expect(find.textContaining(fixture.error), findsOneWidget);
    });
  }

  for (final archivedState in ['verified', 'cancelled']) {
    testWidgets('valid $archivedState archive keeps its input reserved',
        (tester) async {
      writeDraftWithHistory([
        {
          'txid': '11' * 32,
          'state': archivedState,
          'recovery': {
            'request': requestWith([
              {'txid': '33' * 32, 'vout': 0}
            ]),
            'built': builtWith('11'),
            'response_ur': archivedState == 'verified'
                ? 'synthetic-public-response'
                : null,
          }
        }
      ]);
      final state = await mount(tester);
      await create(tester, state, amount: '0.2', verified: false);
      expect(native.builtAmounts, isNot(contains('20000000')));
      expect(find.textContaining('仍被先前交易保留'), findsOneWidget);
    });
  }

  testWidgets(
      'unsigned archive can receive its existing response after restore',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state, verified: false);
    state.newDraft();
    await tester.pump();
    state.restoreHistory(0);
    await tester.pump();
    expect(find.text('交易狀態：待離線簽章'), findsOneWidget);
    await state.ingestSignature('synthetic-public-response');
    await tester.pump();
    expect(find.text('交易狀態：簽章已驗證，尚未廣播'), findsOneWidget);
    expect(node.lookups, isEmpty);
  });

  testWidgets('unsigned same-TXID archive preserves an existing signed bundle',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    await tester.pump();
    final signedRow =
        (jsonDecode(file.readAsStringSync()) as Map)['history'][0];
    await create(tester, state, verified: false);
    state.newDraft();
    await tester.pump();
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['history'], [signedRow]);
    state.restoreHistory(0);
    await tester.pump();
    expect((jsonDecode(file.readAsStringSync()) as Map)['response_ur'],
        'synthetic-public-response');
    expect(find.text('交易狀態：結果待查'), findsOneWidget);
    expect(node.lookups, isEmpty);
  });

  testWidgets(
      're-archive preserves recovery and the newest confirmation status',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    await tester.pump();
    final original = (jsonDecode(file.readAsStringSync()) as Map)['history'][0];
    state.restoreHistory(0);
    await state.checkStatus();
    state.newDraft();
    await tester.pump();
    final row = (jsonDecode(file.readAsStringSync()) as Map)['history'][0];
    expect(row['recovery'], original['recovery']);
    expect(row['state'], 'confirmed');
    expect(row['confirmations'], 3);
    expect(DateTime.tryParse(row['checked_at']), isNotNull);
  });

  testWidgets('archive capacity failure preserves the active bundle and file',
      (tester) async {
    file.writeAsStringSync(jsonEncode({
      'schema_version': 2,
      'account_address': account.address,
      'master_fingerprint': account.masterFingerprint,
      'rpc_endpoint': 'https://public-fixture.invalid',
      'state': 'draft',
      'request': null,
      'built': null,
      'response_ur': null,
      'history': List.generate(
          1000,
          (_) => {
                'txid': '33' * 32,
                'state': 'confirmed',
                'amount_sat': '1',
                'recipient_address': 'bcrt1qpublic'
              }),
    }));
    final state = await mount(tester);
    await create(tester, state);
    final before = file.readAsBytesSync();
    state.newDraft();
    await tester.pump();
    expect(file.readAsBytesSync(), before);
    expect((jsonDecode(file.readAsStringSync()) as Map)['request'], isNotNull);
    expect(find.textContaining('紀錄儲存失敗'), findsOneWidget);
  });

  testWidgets('status lookup locks conflicting archive and create operations',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    final before = file.readAsStringSync();
    node.pending = Completer();
    final query = state.checkStatus();
    await tester.pump();
    state.newDraft();
    await state.createRequest();
    await tester.pump();
    expect(file.readAsStringSync(), before);
    expect(
        tester
            .widget<TextButton>(find.byKey(const Key('btc_archive')))
            .onPressed,
        isNull);
    node.pending!.complete({'confirmations': 2});
    await query;
    await tester.pump();
    expect((jsonDecode(file.readAsStringSync()) as Map)['state'], 'confirmed');
  });

  testWidgets('background revokes a late status result without writing',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    final before = file.readAsStringSync();
    node.pending = Completer();
    final query = state.checkStatus();
    await tester.pump();
    leaveApp(tester);
    returnToApp(tester);
    node.pending!.complete({'confirmations': 6});
    await query;
    await tester.pump();
    expect(file.readAsStringSync(), before);
    expect(find.text('交易狀態：簽章已驗證，尚未廣播'), findsOneWidget);
    node.pending = null;
    await state.checkStatus();
    await tester.pump();
    expect((jsonDecode(file.readAsStringSync()) as Map)['confirmations'], 3);
  });

  testWidgets('disposed lookup cannot overwrite a new screen transaction',
      (tester) async {
    final old = await mount(tester);
    await create(tester, old);
    node.pending = Completer();
    final query = old.checkStatus();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    final current = await mount(tester);
    current.newDraft();
    await tester.pump();
    node.utxoTag = '44';
    await create(tester, current, amount: '0.2', verified: false);
    final before = file.readAsStringSync();
    node.pending!.complete({'confirmations': 99});
    await query;
    await tester.pump();
    expect(file.readAsStringSync(), before);
    final saved = jsonDecode(before) as Map;
    expect(saved['state'], 'awaitingSignature');
    expect(saved['built']['txid'], '22' * 32);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy summary keeps a read-only txid query after upgrade',
      (tester) async {
    file.writeAsStringSync(jsonEncode({
      'schema_version': 1,
      'account_address': account.address,
      'master_fingerprint': account.masterFingerprint,
      'state': 'draft',
      'request': null,
      'built': null,
      'response_ur': null,
      'rpc_endpoint': 'https://public-fixture.invalid',
      'history': [
        {
          'txid': '44' * 32,
          'state': 'cancelled',
          'amount_sat': '1000',
          'recipient_address': 'bcrt1qlegacy'
        }
      ]
    }));
    final state = await mount(tester);
    expect(find.textContaining('舊摘要僅支援查詢 TXID'), findsOneWidget);
    await state.checkArchivedStatus(0);
    await tester.pump();
    expect(node.lookups, ['44' * 32]);
    expect(native.builds, 0);
    expect(
        (jsonDecode(file.readAsStringSync()) as Map)['history'][0]
            ['confirmations'],
        3);
    expect(find.byKey(const Key('btc_broadcast')), findsNothing);
  });

  testWidgets(
      'malformed confirmation count is an error rather than pending success',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    final before = file.readAsStringSync();
    node.pending = Completer()..complete({'confirmations': '3'});
    await state.checkStatus();
    await tester.pump();
    expect(file.readAsStringSync(), before);
    expect(find.textContaining('節點未回傳有效確認數'), findsOneWidget);
    // A present-but-null count is malformed too; only an absent key is mempool.
    node.pending = Completer()..complete({'confirmations': null});
    await state.checkStatus();
    await tester.pump();
    expect(file.readAsStringSync(), before);
    expect(find.textContaining('節點未回傳有效確認數'), findsOneWidget);
  });

  testWidgets('fee policy is rejected before loading funds', (tester) async {
    final state = await mount(tester);
    await tester.enterText(
        find.byKey(const Key('btc_recipient')), 'bcrt1qrecipient');
    await tester.enterText(find.byKey(const Key('btc_amount')), '0.1');
    await tester.enterText(find.byKey(const Key('btc_fee')), '5000001');
    await state.createRequest();
    await tester.pump();
    expect(node.loads, 0);
    expect(find.textContaining('1 與 5000000 sat'), findsOneWidget);
  });

  testWidgets('mempool result without confirmations is pending, not an error',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    node.status = 'mempool';
    await state.checkStatus();
    await tester.pump();
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['state'], 'pending');
    expect(saved['confirmations'], 0);
    expect(find.text('交易狀態：待確認'), findsOneWidget);
    expect(find.byKey(const Key('btc_error')), findsNothing);
    state.newDraft();
    await tester.pump();
    final archived = jsonDecode(file.readAsStringSync()) as Map;
    expect(archived['request'], isNull);
    expect(archived['history'][0]['state'], 'pending');
    node.status = 'mempool';
    await state.checkArchivedStatus(0);
    await tester.pump();
    expect((jsonDecode(file.readAsStringSync()) as Map)['history'][0]['state'],
        'pending');
  });

  Future<void> confirmDialog(WidgetTester tester, Future<void> action) async {
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, '確認廣播'));
    await tester.pumpAndSettle();
    await action;
    await tester.pump();
  }

  testWidgets(
      'restored never-sent signature can resend the same bytes after not-found',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    await tester.pump();
    expect((jsonDecode(file.readAsStringSync()) as Map)['history'][0]['state'],
        'verified');
    state.restoreHistory(0);
    await tester.pump();
    expect(find.text('交易狀態：結果待查'), findsOneWidget);
    expect(find.byKey(const Key('btc_broadcast')), findsNothing);
    // Without a not-found lookup the resend path stays closed.
    await state.broadcast();
    expect(node.sent, isEmpty);
    node.status = 'notFound';
    await state.checkStatus();
    await tester.pump();
    expect(find.textContaining('節點查無此交易'), findsOneWidget);
    expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);
    expect((jsonDecode(file.readAsStringSync()) as Map)['state'], 'unknown');
    node.send = 'accept';
    node.status = 'mempool';
    await confirmDialog(tester, state.broadcast());
    expect(node.sent, ['public-display-only']);
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['state'], 'pending');
    expect(saved['response_ur'], 'synthetic-public-response');
    expect(find.byKey(const Key('btc_broadcast')), findsNothing);
  });

  for (final focusOnly in [false, true]) {
  testWidgets(
      '${focusOnly ? 'losing focus' : 'leaving the foreground'} clears a resend permission',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    state.restoreHistory(0);
    node.status = 'notFound';
    await state.checkStatus();
    await tester.pump();
    expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);
    if (focusOnly) {
      loseAndRegainFocus(tester);
    } else {
      leaveApp(tester);
      returnToApp(tester);
    }
    await tester.pump();
    expect(find.byKey(const Key('btc_broadcast')), findsNothing);
    node.send = 'accept';
    await state.broadcast();
    expect(node.sent, isEmpty);
  });
  }

  for (final mode in ['revoked', 'offline']) {
    testWidgets('$mode before dispatch returns to verified and stays sendable',
        (tester) async {
      final state = await mount(tester);
      await create(tester, state);
      node.send = mode;
      await confirmDialog(tester, state.broadcast());
      final saved = jsonDecode(file.readAsStringSync()) as Map;
      expect(saved['state'], 'verified');
      expect(find.text('交易狀態：簽章已驗證，尚未廣播'), findsOneWidget);
      expect(find.textContaining('廣播尚未送出'), findsOneWidget);
      expect(find.text('確認並廣播交易'), findsOneWidget);
      node.send = 'accept';
      node.status = 'mempool';
      await confirmDialog(tester, state.broadcast());
      expect(node.sent, ['public-display-only']);
      expect((jsonDecode(file.readAsStringSync()) as Map)['state'], 'pending');
    });
  }

  testWidgets(
      'a possibly sent transaction archives only after a not-found lookup',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    state.restoreHistory(0);
    await tester.pump();
    // Uncertain state: query first, never archive into a replacement.
    expect(find.byKey(const Key('btc_archive')), findsNothing);
    state.newDraft();
    expect((jsonDecode(file.readAsStringSync()) as Map)['request'], isNotNull);
    node.status = 'notFound';
    await state.checkStatus();
    await tester.pump();
    expect(find.byKey(const Key('btc_archive')), findsOneWidget);
    expect(find.textContaining('此交易可能已送出'), findsOneWidget);
    state.newDraft();
    await tester.pump();
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['request'], isNull);
    expect(saved['history'], hasLength(1));
    expect(saved['history'][0]['state'], 'unknown');
    expect(saved['history'][0]['recovery']['response_ur'],
        'synthetic-public-response');
  });

  testWidgets('archived not-found lookup reports without changing the record',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state, verified: false);
    state.newDraft();
    await tester.pump();
    final before = file.readAsStringSync();
    node.status = 'notFound';
    await state.checkArchivedStatus(0);
    await tester.pump();
    expect(file.readAsStringSync(), before);
    expect(find.textContaining('節點查無此交易'), findsOneWidget);
  });

  testWidgets('-5 without a synced txindex never opens resend or archive',
      (tester) async {
    final state = await mount(tester);
    await create(tester, state);
    state.newDraft();
    state.restoreHistory(0);
    await tester.pump();
    final before = file.readAsStringSync();
    node.status = 'noTxindex';
    await state.checkStatus();
    await tester.pump();
    expect(find.textContaining('此節點無法證明交易不存在'), findsOneWidget);
    expect(find.byKey(const Key('btc_broadcast')), findsNothing);
    expect(find.byKey(const Key('btc_archive')), findsNothing);
    node.send = 'accept';
    await state.broadcast();
    state.newDraft();
    expect(node.sent, isEmpty);
    expect(file.readAsStringSync(), before);
  });

  test('only the synced-index -5 message proves absence', () {
    const proven = BitcoinRpcException('x',
        code: -5,
        rpcMessage:
            'No such mempool or blockchain transaction. Use gettransaction for wallet transactions.');
    const indexing = BitcoinRpcException('x',
        code: -5,
        rpcMessage:
            'No such mempool transaction. Blockchain transactions are still in the process of being indexed. Use gettransaction for wallet transactions.');
    const other = BitcoinRpcException('x',
        code: -8, rpcMessage: 'No such mempool or blockchain transaction');
    expect(proven.transactionNotFound, isTrue);
    expect(indexing.transactionNotFound, isFalse);
    expect(indexing.lookupInconclusive, isTrue);
    expect(other.transactionNotFound, isFalse);
    expect(other.lookupInconclusive, isFalse);
  });
}
