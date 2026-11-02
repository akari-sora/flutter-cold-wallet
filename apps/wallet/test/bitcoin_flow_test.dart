import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/screens/bitcoin_send_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';

import 'app_lifecycle.dart';
import 'denied_camera.dart';

class _BitcoinNative implements BitcoinFfiService {
  Map<String, dynamic>? lastBuild;
  bool rejectSignature = false;
  @override
  Map<String, dynamic> describe(Map<String, dynamic> request) =>
      throw UnimplementedError();
  @override
  Map<String, dynamic> build(Map<String, dynamic> request) {
    lastBuild = request;
    return {
      'status': 'SUCCESS',
      'psbt_hex': '70736274ff0${request['change_index']}',
      'expected_digest': '11' * 32,
      'ur_frames': ['ur:crypto-psbt/test'],
      'txid': '22' * 32,
      'recipient_address': request['recipient_address'],
      'amount_sat': request['amount_sat'],
      'fee_sat': request['fee_sat'],
      'change_address': 'bcrt1qchange',
      'change_sat': '10000'
    };
  }

  @override
  Map<String, dynamic> verify(Map<String, dynamic> request) => rejectSignature
      ? {'status': 'ERROR', 'error': 'invalid signature'}
      : {'status': 'VERIFIED', 'tx_hex': '01000000', 'txid': '22' * 32};
}

class _BitcoinNode extends BitcoinRpcClient {
  bool unavailable = false;
  int changeIndex = 0;
  _BitcoinNode() : super(endpoint: 'http://localhost:18443');
  @override
  Future<int> unusedChangeIndex(AccountDescriptor account) async => changeIndex;
  @override
  Future<List<Map<String, dynamic>>> loadUtxos(
          AccountDescriptor account) async =>
      [
        {
          'txid': '33' * 32,
          'vout': 0,
          'previous_tx_hex': '00',
          'branch': 0,
          'address_index': 0
        }
      ];
  @override
  Future<String> broadcast(String rawTransaction,
          {bool Function()? canDispatch}) async =>
      throw const BitcoinRpcException('offline', uncertain: true);
  @override
  Future<Map<String, dynamic>> transactionStatus(String txid) async =>
      throw const BitcoinRpcException('not found');
}

/// Node that refuses every request as Bitcoin Core does without valid RPC
/// credentials: HTTP 401 with an empty body.
class _UnauthorizedNode extends _BitcoinNode {
  final methods = <String>[];
  late final BitcoinRpcClient _real = BitcoinRpcClient(
      endpoint: endpoint,
      client: MockClient((request) async {
        methods.add((jsonDecode(request.body) as Map)['method'] as String);
        return http.Response('', 401);
      }));
  @override
  Future<String> broadcast(String rawTransaction,
          {bool Function()? canDispatch}) =>
      _real.broadcast(rawTransaction, canDispatch: canDispatch);
  @override
  Future<Map<String, dynamic>> transactionStatus(String txid) =>
      _real.transactionStatus(txid);
}

/// Proxy in front of a txindex node: it answers the first
/// sendrawtransaction with an empty HTTP 403 (or holds it in [firstSend]),
/// so the device cannot tell whether the node received it. The node itself
/// has no copy until a later send gets through.
class _RefusingProxyNode extends _BitcoinNode {
  final sent = <String>[];
  Completer<http.Response>? firstSend;

  /// Holds the next getblockchaininfo, the check before dispatch.
  Completer<http.Response>? chainCheck;

  /// Holds the next getrawtransaction, a lookup's reply.
  Completer<http.Response>? lookup;
  static http.Response _reply(Object? result, [Object? error]) =>
      http.Response(jsonEncode({'result': result, 'error': error}),
          error == null ? 200 : 404);
  late final BitcoinRpcClient _real = BitcoinRpcClient(
      endpoint: endpoint,
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        switch (body['method']) {
          case 'getblockchaininfo':
            final held = chainCheck;
            chainCheck = null;
            return held == null ? _reply({'chain': 'regtest'}) : await held.future;
          case 'sendrawtransaction':
            sent.add((body['params'] as List).single as String);
            if (sent.length == 1) {
              return firstSend == null
                  ? http.Response('', 403)
                  : await firstSend!.future;
            }
            return _reply('22' * 32);
          case 'getrawtransaction':
            final held = lookup;
            lookup = null;
            if (held != null) return await held.future;
            return sent.length < 2
                ? _reply(null, {
                    'code': -5,
                    'message':
                        'No such mempool or blockchain transaction. Use gettransaction for wallet transactions.'
                  })
                : _reply({'txid': '22' * 32});
        }
        throw StateError('Unexpected RPC method: ${body['method']}');
      }));
  @override
  Future<String> broadcast(String rawTransaction,
          {bool Function()? canDispatch}) =>
      _real.broadcast(rawTransaction, canDispatch: canDispatch);
  @override
  Future<Map<String, dynamic>> transactionStatus(String txid) =>
      _real.transactionStatus(txid);
}

void main() {
  test('refuses non-regtest before querying funds', () async {
    final called = <String>[];
    final rpc = BitcoinRpcClient(
        endpoint: 'http://localhost:18443',
        client: MockClient((r) async {
          final req = jsonDecode(r.body) as Map;
          called.add(req['method'] as String);
          return http.Response(
              jsonEncode({
                'result': {'chain': 'main'},
                'error': null
              }),
              200);
        }));
    await expectLater(rpc.verifyRegtest, throwsA(isA<BitcoinRpcException>()));
    expect(called, ['getblockchaininfo']);
  });
  test('broadcast rejection is an error and credentials only enter auth header',
      () async {
    final rpc = BitcoinRpcClient(
        endpoint: 'http://localhost:18443',
        username: 'rpcuser',
        password: 'private',
        client: MockClient((r) async {
          final req = jsonDecode(r.body) as Map;
          expect(r.headers['authorization'],
              'Basic ${base64Encode(utf8.encode('rpcuser:private'))}');
          if (req['method'] == 'getblockchaininfo') {
            return http.Response(
                '{"result":{"chain":"regtest"},"error":null}', 200);
          }
          return http.Response(
              '{"result":null,"error":{"code":-26,"message":"rejected"}}', 500);
        }));
    await expectLater(
        () => rpc.broadcast('00'), throwsA(isA<BitcoinRpcException>()));
  });
  test('only imported descriptor UTXOs used; previous bytes fetched', () async {
    const account = AccountDescriptor(
        masterFingerprint: '73c5da0a',
        derivationPath: "m/84'/1'/0'",
        address: 'bcrt1qreceive',
        chainId: 0,
        assetFamily: 'BTC',
        btcReceiveAddressRegtest: 'bcrt1qreceive',
        btcChangeAddress: 'bcrt1qchange');
    final rpc = BitcoinRpcClient(
        endpoint: 'http://localhost:18443',
        client: MockClient((r) async {
          final req = jsonDecode(r.body) as Map;
          final result = switch (req['method']) {
            'getblockchaininfo' => {'chain': 'regtest'},
            'getwalletinfo' => {'private_keys_enabled': false},
            'listunspent' => [
                {'txid': '11' * 32, 'vout': 1, 'address': account.address},
                {'txid': '22' * 32, 'vout': 0, 'address': 'bcrt1qunrelated'},
              ],
            'getrawtransaction' => '01000000',
            _ => throw StateError('unexpected method'),
          };
          return http.Response(
              jsonEncode({'result': result, 'error': null}), 200);
        }));
    final utxos = await rpc.loadUtxos(account);
    expect(utxos.length, 1);
    expect(utxos.single['previous_tx_hex'], '01000000');
    expect(utxos.single['branch'], 0);
  });
  group('Bitcoin App transaction flow', () {
    late Directory directory;
    late String path;
    late _BitcoinNative native;
    const account = AccountDescriptor(
        masterFingerprint: '73c5da0a',
        derivationPath: "m/84'/1'/0'",
        address: 'bcrt1qreceive',
        chainId: 0,
        assetFamily: 'BTC',
        extendedPublicKey: 'tpubTest',
        btcReceiveAddressRegtest: 'bcrt1qreceive',
        btcChangeAddress: 'bcrt1qchange');
    setUp(() {
      directory = Directory.systemTemp.createTempSync('bitcoin_ui_');
      path = '${directory.path}/bitcoin.json';
      native = _BitcoinNative();
    });
    tearDown(() => directory.deleteSync(recursive: true));
    Future<BitcoinSendScreenState> mount(WidgetTester tester,
        {BitcoinRpcClient? rpc, Size size = const Size(1000, 2200)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: BitcoinSendScreen(
              account: account,
              rpcOverride: rpc ?? _BitcoinNode(),
              ffiOverride: native,
              storagePathOverride: path)));
      await tester.pumpAndSettle();
      return tester
          .state<BitcoinSendScreenState>(find.byType(BitcoinSendScreen));
    }

    Future<void> input(WidgetTester tester, String amount) async {
      await tester.enterText(
          find.byKey(const Key('btc_recipient')), 'bcrt1qrecipient');
      await tester.enterText(find.byKey(const Key('btc_amount')), amount);
      await tester.enterText(find.byKey(const Key('btc_fee')), '500');
    }

    testWidgets(
        'exact amount builds durable request; invalid precision never defaults',
        (tester) async {
      final state = await mount(tester);
      await input(tester, '0.000000001');
      await state.createRequest();
      await tester.pump();
      expect(native.lastBuild, isNull);
      expect(File(path).existsSync(), false);
      await input(tester, '0.10000001');
      await state.createRequest();
      await tester.pump();
      expect(native.lastBuild!['amount_sat'], '10000001');
      expect(File(path).existsSync(), true);
      expect(find.text('交易狀態：待離線簽章'), findsOneWidget);
      await tester.tap(find.text('請求資料'));
      await tester.pumpAndSettle();
      expect(find.text('ur:crypto-psbt/test'), findsOneWidget);
    });
    testWidgets(
        'invalid signed response stays unsigned; verified response survives restart',
        (tester) async {
      final state = await mount(tester);
      await input(tester, '0.1');
      await state.createRequest();
      native.rejectSignature = true;
      await state.ingestSignature('bad');
      await tester.pump();
      expect(find.textContaining('簽章未通過'), findsOneWidget);
      expect(find.byKey(const Key('btc_broadcast')), findsNothing);
      native.rejectSignature = false;
      await state.ingestSignature('signed-response');
      await tester.pump();
      expect(find.byKey(const Key('btc_broadcast')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(find.text('交易狀態：簽章已驗證，尚未廣播'), findsOneWidget);
    });
    testWidgets('uncertain broadcast cannot create replacement or show success',
        (tester) async {
      final state = await mount(tester);
      await input(tester, '0.1');
      await state.createRequest();
      await state.ingestSignature('signed');
      await tester.pump();
      final send = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pumpAndSettle();
      await send;
      expect(find.text('交易狀態：結果待查'), findsOneWidget);
      state.newDraft();
      await tester.pump();
      expect(find.byKey(const Key('btc_create')), findsNothing);
      expect(find.textContaining('廣播未確認'), findsOneWidget);
      final saved = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(saved['state'], 'unknown');
    });
    testWidgets('cleared RPC credentials explain the 401, not an outage',
        (tester) async {
      final node = _UnauthorizedNode();
      final state = await mount(tester, rpc: node);
      await input(tester, '0.1');
      await state.createRequest();
      await state.ingestSignature('signed');
      await tester.pump();
      final send = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pumpAndSettle();
      await send;
      expect(node.methods, ['getblockchaininfo']);
      expect(find.text('交易狀態：簽章已驗證，尚未廣播'), findsOneWidget);
      expect(find.text('確認並廣播交易'), findsOneWidget);
      final error =
          tester.widget<SelectableText>(find.byKey(const Key('btc_error')));
      expect(error.data, startsWith('廣播尚未送出：'));
      expect(error.data, contains('RPC 使用者名稱與密碼皆為空白'));
      expect(error.data, isNot(contains('無法連線')));
      await state.checkStatus();
      await tester.pump();
      expect(
          tester
              .widget<SelectableText>(find.byKey(const Key('btc_error')))
              .data,
          allOf(startsWith('同一筆交易結果待查：'), contains('請在節點設定重新輸入')));
      expect((jsonDecode(File(path).readAsStringSync()) as Map)['state'],
          'verified');
    });
    testWidgets(
        'an HTTP 403 to the send itself must be queried before anything else',
        (tester) async {
      final node = _RefusingProxyNode();
      final state = await mount(tester, rpc: node);
      await input(tester, '0.1');
      await state.createRequest();
      await state.ingestSignature('signed');
      await tester.pump();
      final send = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pumpAndSettle();
      await send;
      expect(node.sent, ['01000000']);
      expect(find.text('交易狀態：結果待查'), findsOneWidget);
      expect(
          tester
              .widget<SelectableText>(find.byKey(const Key('btc_error')))
              .data,
          allOf(startsWith('廣播未確認：'), contains('HTTP 403')));
      // A proxy may have forwarded it: no resend and no archive or new draft.
      expect(find.byKey(const Key('btc_broadcast')), findsNothing);
      expect(find.byKey(const Key('btc_archive')), findsNothing);
      state.newDraft();
      await tester.pump();
      expect(find.text('交易狀態：結果待查'), findsOneWidget);
      expect((jsonDecode(File(path).readAsStringSync()) as Map)['state'],
          'unknown');

      // Only a lookup proving the node lacks it allows the identical bytes.
      await state.checkStatus();
      await tester.pump();
      expect(find.textContaining('節點查無此交易'), findsOneWidget);
      expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);
      final resend = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pumpAndSettle();
      await resend;
      expect(node.sent, ['01000000', '01000000']);
      expect(find.text('交易狀態：待確認'), findsOneWidget);
    });
    testWidgets('a late HTTP 403 to a revoked send cannot make it sendable',
        (tester) async {
      final node = _RefusingProxyNode()..firstSend = Completer();
      final state = await mount(tester, rpc: node);
      await input(tester, '0.1');
      await state.createRequest();
      await state.ingestSignature('signed');
      await tester.pump();
      final send = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(node.sent, ['01000000']);
      leaveApp(tester);
      returnToApp(tester);
      node.firstSend!.complete(http.Response('', 403));
      await send;
      await tester.pump();
      expect(find.text('交易狀態：結果待查'), findsOneWidget);
      expect(find.byKey(const Key('btc_broadcast')), findsNothing);
      expect(find.byKey(const Key('btc_archive')), findsNothing);
      expect((jsonDecode(File(path).readAsStringSync()) as Map)['state'],
          'unknown',
          reason: 'Only a lookup may allow a resend');
    });
    testWidgets('a built request shows its whole QR on a short phone',
        (tester) async {
      tester.view.padding = const FakeViewPadding(top: 24);
      addTearDown(tester.view.resetPadding);
      final state = await mount(tester, size: const Size(360, 640));
      await input(tester, '0.1');
      await state.createRequest();
      // The QR may animate, so the scroll is pumped explicitly.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('交易狀態：待離線簽章'), findsOneWidget);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final qr = tester.getRect(find.byType(AnimatedFountainQr));
      expect(qr.height, lessThanOrEqualTo(viewport.height));
      expect(qr.top, greaterThanOrEqualTo(viewport.top),
          reason: 'The whole QR card must be on screen after building');
      expect(qr.bottom, lessThanOrEqualTo(viewport.bottom),
          reason: 'The whole QR card must be on screen after building');
      await tester.pumpWidget(const SizedBox());
    });
    for (final (dispatched, focusOnly) in [
      (true, false),
      (false, false),
      (true, true),
      (false, true)
    ]) {
      testWidgets(
          '${focusOnly ? 'losing focus' : 'leaving the app'} ${dispatched ? 'during' : 'before'} a BTC send is explained',
          (tester) async {
        final node = _RefusingProxyNode();
        final held = Completer<http.Response>();
        if (dispatched) {
          node.firstSend = held;
        } else {
          node.chainCheck = held;
        }
        final state = await mount(tester, rpc: node);
        await input(tester, '0.1');
        await state.createRequest();
        await state.ingestSignature('signed');
        await tester.pump();
        final send = state.broadcast();
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認廣播'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(node.sent, dispatched ? ['01000000'] : isEmpty);
        if (focusOnly) {
          // e.g. the notification shade: inactive without hidden or paused.
          loseAndRegainFocus(tester);
        } else {
          leaveApp(tester);
          returnToApp(tester);
        }
        await tester.pump();
        String error() => tester
            .widget<SelectableText>(find.byKey(const Key('btc_error')))
            .data!;
        String saved() =>
            (jsonDecode(File(path).readAsStringSync()) as Map)['state']
                as String;
        if (dispatched) {
          // It may have reached the node: 結果待查 at once, saved, query-only.
          expect(find.text('交易狀態：結果待查'), findsOneWidget);
          expect(saved(), 'unknown');
          expect(error(), startsWith('廣播未確認：送出期間已離開前景，結果待查'));
          expect(find.byKey(const Key('btc_broadcast')), findsNothing);
          expect(find.byKey(const Key('btc_archive')), findsNothing);
          // The lookup works before the revoked send's answer arrives.
          await state.checkStatus();
          await tester.pump();
          expect(error(), startsWith('節點查無此交易'));
          expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);
          // Its late acceptance is discarded.
          held.complete(http.Response(
              jsonEncode({'result': '22' * 32, 'error': null}), 200));
          await send;
          await tester.pump();
          expect(find.text('交易狀態：結果待查'), findsOneWidget);
          expect(saved(), 'unknown');
          expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);
        } else {
          // Nothing was sent: back to the sendable state at once.
          expect(find.text('交易狀態：簽章已驗證，尚未廣播'), findsOneWidget);
          expect(saved(), 'verified');
          expect(error(), startsWith('廣播尚未送出：送出前已離開前景'));
          // The late chain check finds the send revoked and changes nothing.
          held.complete(http.Response(
              jsonEncode({
                'result': {'chain': 'regtest'},
                'error': null
              }),
              200));
          await send;
          await tester.pump();
          expect(node.sent, isEmpty);
          expect(find.text('交易狀態：簽章已驗證，尚未廣播'), findsOneWidget);
          expect(error(), startsWith('廣播尚未送出：送出前已離開前景'));
          // It can be sent again right away, and is sent once.
          final again = state.broadcast();
          await tester.pumpAndSettle();
          await tester.tap(find.text('確認廣播'));
          await tester.pumpAndSettle();
          await again;
          expect(node.sent, ['01000000']);
        }
      });
    }
    testWidgets('a retired BTC send cannot end the busy state of a later lookup',
        (tester) async {
      final node = _RefusingProxyNode()..firstSend = Completer();
      final state = await mount(tester, rpc: node);
      await input(tester, '0.1');
      await state.createRequest();
      await state.ingestSignature('signed');
      await tester.pump();
      final send = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(node.sent, ['01000000']);
      // Losing focus retires the dispatched send and releases `_busy`.
      loseAndRegainFocus(tester);
      await tester.pump();
      expect(find.text('交易狀態：結果待查'), findsOneWidget);
      VoidCallback? queryButton() => tester
          .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '查詢交易與確認數'))
          .onPressed;
      expect(queryButton(), isNotNull);

      // A lookup starts and waits for the node.
      final lookup = node.lookup = Completer();
      final query = state.checkStatus();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(queryButton(), isNull);

      // The retired send's late reply must not end the lookup's busy state.
      node.firstSend!.complete(http.Response(
          jsonEncode({'result': '22' * 32, 'error': null}), 200));
      await send;
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(queryButton(), isNull, reason: 'The lookup is still running');

      lookup.complete(http.Response(
          jsonEncode({
            'result': null,
            'error': {
              'code': -5,
              'message': 'No such mempool or blockchain transaction.'
            }
          }),
          404));
      await query;
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(queryButton(), isNotNull);
      expect(find.textContaining('節點查無此交易'), findsOneWidget);
    });
    testWidgets('a BTC resend revoked before dispatch asks for another lookup',
        (tester) async {
      final node = _RefusingProxyNode()..firstSend = Completer();
      final state = await mount(tester, rpc: node);
      await input(tester, '0.1');
      await state.createRequest();
      await state.ingestSignature('signed');
      await tester.pump();
      final send = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(node.sent, ['01000000']);
      // Leaving settles the dispatched send as 結果待查; a lookup finds
      // nothing and offers the same bytes again.
      leaveApp(tester);
      returnToApp(tester);
      await tester.pump();
      await state.checkStatus();
      await tester.pump();
      expect(find.text('確認重新傳送同一筆已簽交易'), findsOneWidget);

      // The resend waits for its chain check and is revoked by leaving.
      final held = node.chainCheck = Completer();
      final resend = state.broadcast();
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認廣播'));
      await tester.pump();
      leaveApp(tester);
      returnToApp(tester);
      await tester.pump();
      final error = tester
          .widget<SelectableText>(find.byKey(const Key('btc_error')))
          .data!;
      expect(error, startsWith('這次重新傳送沒有送出；前一次送出的結果仍待查'));
      expect(error, contains('再查詢同一筆交易'));
      expect(find.text('交易狀態：結果待查'), findsOneWidget);
      expect(
          (jsonDecode(File(path).readAsStringSync()) as Map)['state'], 'unknown');

      held.complete(http.Response(
          jsonEncode({
            'result': {'chain': 'regtest'},
            'error': null
          }),
          200));
      await resend;
      node.firstSend!.complete(http.Response(
          jsonEncode({'result': '22' * 32, 'error': null}), 200));
      await send;
      await tester.pump();
      expect(node.sent, ['01000000'], reason: 'The revoked resend sent nothing');
      expect(find.text('交易狀態：結果待查'), findsOneWidget);
    });
    testWidgets('change goes to the unused index and is kept for recovery',
        (tester) async {
      final node = _BitcoinNode()..changeIndex = 3;
      final state = await mount(tester, rpc: node);
      await input(tester, '0.1');
      await state.createRequest();
      await tester.pump();
      expect(native.lastBuild!['change_index'], 3);
      final saved = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(saved['request']['change_index'], 3);
      expect(saved['built']['psbt_hex'], '70736274ff03');
      native.lastBuild = null;
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      // The saved request rebuilds the identical PSBT, change index included.
      expect(native.lastBuild!['change_index'], 3);
      expect(find.text('交易狀態：待離線簽章'), findsOneWidget);
      expect(find.byKey(const Key('btc_error')), findsNothing);
    });
    testWidgets(
        'a failed record save keeps the typed recipient, amount and fee',
        (tester) async {
      final state = await mount(tester);
      await input(tester, '0.1');
      // A directory at the temporary path makes the atomic write fail.
      final blocker = Directory('$path.tmp')..createSync();
      await state.createRequest();
      await tester.pump();
      expect(find.byKey(const Key('btc_error')), findsOneWidget);
      expect(find.text('交易狀態：草稿'), findsOneWidget);
      expect(File(path).existsSync(), isFalse);
      String text(String key) =>
          tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
      expect(text('btc_recipient'), 'bcrt1qrecipient');
      expect(text('btc_amount'), '0.1');
      expect(text('btc_fee'), '500');
      blocker.deleteSync();
      await state.createRequest();
      await tester.pump();
      expect(find.text('交易狀態：待離線簽章'), findsOneWidget);
      expect(native.lastBuild!['amount_sat'], '10000000');
    });
    testWidgets('denied camera on the BTC signature scan opens the app settings',
        (tester) async {
      mockDeniedCamera(tester);
      final platformCalls = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('fcw/platform'),
          (call) async {
        platformCalls.add(call.method);
        return call.method == 'openAppSettings' ? true : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(
          const MethodChannel('fcw/platform'), null));
      final state = await mount(tester);
      await input(tester, '0.1');
      await state.createRequest();
      await tester.pumpAndSettle();
      final scan = find.text('掃描簽署結果');
      await tester.ensureVisible(scan);
      await tester.pumpAndSettle();
      await tester.tap(scan);
      await tester.pumpAndSettle();
      // This scanner restarts on return, so the shared guidance holds.
      expect(find.textContaining('返回後即可掃描'), findsOneWidget);
      await tester.tap(find.byKey(const Key('scanner_open_app_settings_btn')));
      await tester.pump();
      expect(platformCalls.where((m) => m == 'openAppSettings'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the signature scanner leaves no field to refocus on return',
        (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      const events =
          MethodChannel('dev.steenbakker.mobile_scanner/scanner/event');
      const methods =
          MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');
      messenger.setMockMethodCallHandler(events, (_) async => null);
      messenger.setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'state') return 1;
        if (call.method == 'start') {
          return {
            'textureId': 1,
            'numberOfCameras': 1,
            'size': {'width': 640.0, 'height': 480.0}
          };
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(events, null);
        messenger.setMockMethodCallHandler(methods, null);
      });
      final state = await mount(tester);
      await input(tester, '0.1');
      await state.createRequest();
      await tester.pumpAndSettle();
      await tester.tap(find.text('節點設定'));
      await tester.pumpAndSettle();
      // On device the RPC password was the field that reopened the keyboard.
      final password = find.widgetWithText(TextField, 'RPC 密碼');
      await tester.ensureVisible(password);
      await tester.pumpAndSettle();
      await tester.tap(password);
      await tester.pump();
      final focus = tester
          .widget<EditableText>(find.descendant(
              of: password, matching: find.byType(EditableText)))
          .focusNode;
      expect(focus.hasPrimaryFocus, isTrue);
      final scan = find.text('掃描簽署結果');
      await tester.ensureVisible(scan);
      await tester.pumpAndSettle();
      await tester.tap(scan);
      await tester.pumpAndSettle();
      expect(find.byType(AirGapScanner), findsOneWidget);
      // Popping the scanner refocuses whatever the screen's scope remembers.
      expect(focus.enclosingScope?.focusedChild, isNot(same(focus)));
      await tester.tap(find.byTooltip('取消掃描'));
      await tester.pumpAndSettle();
      expect(find.byType(AirGapScanner), findsNothing);
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });
    testWidgets('damaged pending record is visible and preserved',
        (tester) async {
      File(path).writeAsStringSync('{broken');
      await mount(tester);
      expect(find.textContaining('Bitcoin 無法啟用'), findsOneWidget);
      expect(File(path).readAsStringSync(), '{broken');
    });
  });
}
