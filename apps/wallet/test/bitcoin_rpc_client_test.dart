import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';

const account = AccountDescriptor(
    masterFingerprint: '73c5da0a',
    derivationPath: "m/84'/1'/0'",
    address: 'bcrt1qreceive',
    chainId: 0,
    assetFamily: 'BTC',
    extendedPublicKey: 'tpubPublicFixture',
    btcDescriptor: "wpkh([73c5da0a/84'/1'/0']tpubPublicFixture/0/*)",
    btcReceiveAddressRegtest: 'bcrt1qreceive',
    btcChangeAddress: 'bcrt1qchange');

/// Synthetic watch-only Bitcoin Core wallet holding public descriptors only.
/// Like Core, `getdescriptorinfo` keeps the caller's `'` while
/// `listdescriptors` prints `h`, and a re-import must cover the current range.
class WatchOnlyNode {
  final requests = <(String, List<dynamic>)>[];

  /// Descriptors already in the wallet, as `listdescriptors` prints them.
  final descriptors = <Map<String, dynamic>>[];

  /// BTC received per change index, spent or in the mempool included.
  final received = <int, num>{};
  List<dynamic> unspent = [];

  static String _id(String descriptor) =>
      descriptor.split('#').first.replaceAll("'", 'h');

  late final client = MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final method = body['method'] as String;
    final params = body['params'] as List<dynamic>;
    requests.add((method, params));
    final result = switch (method) {
      'getblockchaininfo' => {'chain': 'regtest'},
      'getwalletinfo' => {'private_keys_enabled': false},
      'getdescriptorinfo' => {
          'descriptor': '${params[0]}#fixture1',
          'isrange': true,
          'hasprivatekeys': false
        },
      'listdescriptors' => {
          'wallet_name': 'fcw_watch',
          'descriptors': descriptors
        },
      'importdescriptors' => [
          for (final item in params[0] as List) _import(item as Map),
        ],
      'deriveaddresses' => [
          for (var i = params[1][0] as int; i <= (params[1][1] as int); i++)
            'bcrt1qchange$i',
        ],
      'getreceivedbyaddress' =>
        received[int.parse((params[0] as String).substring(12))] ?? 0,
      'listunspent' => unspent,
      'getrawtransaction' => '01000000',
      _ => throw StateError('Unexpected RPC method: $method'),
    };
    return http.Response(jsonEncode({'result': result, 'error': null}), 200);
  });

  Map<String, dynamic> _import(Map item) {
    final range = item['range'] as List;
    for (final current in descriptors) {
      final held = current['range'] as List;
      if (_id(current['desc'] as String) == _id(item['desc'] as String) &&
          (range[0] > held[0] || range[1] < held[1])) {
        return {
          'success': false,
          'error': {
            'code': -4,
            'message': 'new range must include current range = $held'
          }
        };
      }
    }
    return {'success': true};
  }

  List<dynamic> get imported => requests
      .where((request) => request.$1 == 'importdescriptors')
      .single
      .$2[0] as List<dynamic>;

  BitcoinRpcClient rpc() =>
      BitcoinRpcClient(endpoint: 'http://localhost:18443', client: client);
}

/// Replies with HTTP 401/403 and an empty body for [denied] methods, as
/// Bitcoin Core does before running them (or a proxy in front of it may do
/// after forwarding them).
BitcoinRpcClient deniedNode(Map<String, int> denied, List<String> methods,
        {String username = '', String password = ''}) =>
    BitcoinRpcClient(
        endpoint: 'http://localhost:18443',
        username: username,
        password: password,
        client: MockClient((request) async {
          final method = (jsonDecode(request.body) as Map)['method'] as String;
          methods.add(method);
          final status = denied[method];
          if (status != null) return http.Response('', status);
          final result = switch (method) {
            'getblockchaininfo' => {'chain': 'regtest'},
            'sendrawtransaction' => '44' * 32,
            _ => throw StateError('Unexpected RPC method: $method'),
          };
          return http.Response(
              jsonEncode({'result': result, 'error': null}), 200);
        }));

void main() {
  group('node authentication', () {
    test('cleared credentials are named instead of a connection failure',
        () async {
      final rpc = deniedNode({'getblockchaininfo': 401}, []);
      await expectLater(
          rpc.verifyRegtest,
          throwsA(isA<BitcoinRpcException>().having(
              (e) => e.message,
              'message',
              allOf(contains('使用者名稱與密碼皆為空白'), contains('重新輸入'),
                  isNot(contains('無法連線'))))));
    });

    test('rejected credentials ask to re-enter them', () async {
      final rpc = deniedNode({'getblockchaininfo': 401}, [],
          username: 'rpcuser', password: 'stale');
      await expectLater(
          rpc.verifyRegtest,
          throwsA(isA<BitcoinRpcException>().having((e) => e.message, 'message',
              allOf(contains('拒絕此 RPC 使用者名稱或密碼'), contains('重新輸入')))));
    });

    for (final status in [401, 403]) {
      test('HTTP $status before dispatch leaves the transaction unsent',
          () async {
        final methods = <String>[];
        final rpc = deniedNode({'getblockchaininfo': status}, methods);
        await expectLater(
            () => rpc.broadcast('public-display-only'),
            throwsA(isA<BitcoinRpcException>()
                .having((e) => e.notSent, 'notSent', isTrue)
                .having((e) => e.uncertain, 'uncertain', isFalse)
                .having(
                    (e) => e.message,
                    'message',
                    allOf(
                        contains('HTTP $status'),
                        // Before dispatch the node's own refusal is named.
                        contains(status == 403 ? '遭節點拒絕' : '未通過節點認證')))));
        expect(methods, ['getblockchaininfo']);
      });

      test('sendrawtransaction refused with HTTP $status stays uncertain',
          () async {
        // The request already left the device; only a lookup can tell
        // whether a proxy forwarded it to the node.
        final methods = <String>[];
        final rpc = deniedNode({'sendrawtransaction': status}, methods,
            username: 'rpcuser', password: 'limited');
        await expectLater(
            () => rpc.broadcast('public-display-only'),
            throwsA(isA<BitcoinRpcException>()
                .having((e) => e.notSent, 'notSent', isFalse)
                .having((e) => e.uncertain, 'uncertain', isTrue)
                .having(
                    (e) => e.message,
                    'message',
                    allOf(
                        contains('sendrawtransaction'),
                        contains('HTTP $status'),
                        // Not attributed to the node: a proxy may have sent it.
                        contains('可能來自節點或其前方的代理'),
                        isNot(contains('遭節點拒絕')),
                        isNot(contains('未通過節點認證'))))));
        expect(methods, ['getblockchaininfo', 'sendrawtransaction']);
      });
    }

    test('an unreadable sendrawtransaction reply stays uncertain', () async {
      for (final reply in [
        http.Response('', 500),
        http.Response('<html>Bad Gateway</html>', 502),
      ]) {
        final rpc = BitcoinRpcClient(
            endpoint: 'http://localhost:18443',
            client: MockClient((request) async =>
                (jsonDecode(request.body) as Map)['method'] ==
                        'getblockchaininfo'
                    ? http.Response(
                        '{"result":{"chain":"regtest"},"error":null}', 200)
                    : reply));
        await expectLater(
            () => rpc.broadcast('public-display-only'),
            throwsA(isA<BitcoinRpcException>()
                .having((e) => e.uncertain, 'uncertain', isTrue)
                .having((e) => e.notSent, 'notSent', isFalse)));
      }
    });
  });

  group('change index', () {
    Map<String, dynamic> held(String branch, List<int> range) => {
          'desc':
              'wpkh([73c5da0a/84h/1h/0h]tpubPublicFixture/$branch/*)#held0001',
          'timestamp': 1,
          'active': false,
          'range': range
        };

    test('is the lowest tracked internal index that never received funds',
        () async {
      final node = WatchOnlyNode();
      node.descriptors.addAll([
        held('0', [0, 1000]),
        held('1', [0, 1004])
      ]);
      // 1 only holds unconfirmed change; 2 was received and already spent.
      node.received.addAll({0: 0.3, 1: 0.14999718, 2: 0.2, 4: 0.1});
      expect(await node.rpc().unusedChangeIndex(account), 3);
      final derive =
          node.requests.singleWhere((r) => r.$1 == 'deriveaddresses');
      expect(derive.$2, [
        "wpkh([73c5da0a/84'/1'/0']tpubPublicFixture/1/*)#fixture1",
        [0, 1004]
      ]);
      expect(
          node.requests
              .where((r) => r.$1 == 'getreceivedbyaddress')
              .map((r) => r.$2),
          [
            for (var i = 0; i <= 3; i++) ['bcrt1qchange$i', 0]
          ]);
    });

    test('requires the change descriptor to be imported first', () async {
      final node = WatchOnlyNode();
      node.descriptors.add(held('0', [0, 1000]));
      await expectLater(
          () => node.rpc().unusedChangeIndex(account),
          throwsA(isA<BitcoinRpcException>()
              .having((e) => e.message, 'message', contains('請先同步公開描述'))));
      expect(
          node.requests.map((r) => r.$1), isNot(contains('deriveaddresses')));
    });

    test('never picks an index outside the tracked range', () async {
      final node = WatchOnlyNode();
      node.descriptors.add(held('1', [0, 2]));
      node.received.addAll({0: 1, 1: 1, 2: 1});
      await expectLater(() => node.rpc().unusedChangeIndex(account),
          throwsA(isA<BitcoinRpcException>()));
    });

    test('UTXOs on any internal index are recognised by their origin',
        () async {
      final node = WatchOnlyNode();
      node.unspent = [
        {
          'txid': '55' * 32,
          'vout': 1,
          'address': 'bcrt1qchange7',
          'desc': 'wpkh([73c5da0a/84h/1h/0h/1/7]02${'66' * 32})#utxo0001'
        }
      ];
      final utxos = await node.rpc().loadUtxos(account);
      expect(utxos.single['branch'], 1);
      expect(utxos.single['address_index'], 7);
    });
  });

  group('public descriptor import', () {
    test('keeps a larger range the watch-only wallet already holds', () async {
      final node = WatchOnlyNode();
      node.descriptors.addAll([
        {
          'desc': 'wpkh([73c5da0a/84h/1h/0h]tpubPublicFixture/0/*)#heldext1',
          'timestamp': 1,
          'active': false,
          'range': [0, 1000]
        },
        {
          'desc': 'wpkh([73c5da0a/84h/1h/0h]tpubPublicFixture/1/*)#heldint1',
          'timestamp': 1,
          'active': false,
          'range': [0, 1004]
        },
      ]);
      await node.rpc().importPublicDescriptors(account);
      expect(node.imported.map((item) => item['range']), [
        [0, 1000],
        [0, 1004]
      ]);
      expect(node.imported.map((item) => item['internal']), [false, true]);
    });

    test('a new or unrelated descriptor uses the default range', () async {
      final node = WatchOnlyNode();
      node.descriptors.add({
        'desc': 'wpkh([73c5da0a/84h/1h/1h]tpubOtherAccount/0/*)#other001',
        'timestamp': 1,
        'active': false,
        'range': [0, 5000]
      });
      await node.rpc().importPublicDescriptors(account);
      expect(node.imported.map((item) => item['range']), [
        [0, 100],
        [0, 100]
      ]);
    });
  });
}
