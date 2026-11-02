import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';
import 'package:wallet/services/node_rpc_client.dart';

const _privateDetail = 'private-endpoint-token-and-transaction';

void main() {
  for (final status in [301, 302, 303, 307, 308]) {
    test('RPC clients never follow HTTP $status redirects', () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var redirected = 0;
      final requests = <String>[];
      target.listen((request) async {
        redirected++;
        await request.drain<void>();
        request.response.write('{}');
        await request.response.close();
      });
      origin.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final method = body['method'] as String;
        requests.add(method);
        if (method == 'getblockchaininfo') {
          request.response.write(jsonEncode({
            'result': {'chain': 'regtest'},
            'error': null,
          }));
        } else {
          request.response.statusCode = status;
          request.response.headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:${target.port}/$_privateDetail');
        }
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${origin.port}/$_privateDetail';
      final evm = NodeRpcClient(rpcUrl: url);
      final btc = BitcoinRpcClient(
          endpoint: url, username: 'fixture-user', password: _privateDetail);
      try {
        await expectLater(evm.getChainId(), throwsA(isA<RpcException>()));
        await expectLater(
            btc.broadcast('signed-fixture'),
            throwsA(isA<BitcoinRpcException>()
                .having((e) => e.uncertain, 'uncertain', isTrue)
                .having((e) => e.notSent, 'notSent', isFalse)));
        expect(requests,
            ['eth_chainId', 'getblockchaininfo', 'sendrawtransaction']);
        expect(redirected, 0);
      } finally {
        evm.close();
        btc.close();
        await origin.close(force: true);
        await target.close(force: true);
      }
    });
  }

  for (final scenario in ['transport', 'http', 'json', 'rpc', 'quantity']) {
    test('EVM $scenario errors omit endpoint and remote content', () async {
      final client = MockClient((request) async {
        if (scenario == 'transport') {
          throw http.ClientException(_privateDetail, request.url);
        }
        return switch (scenario) {
          'http' => http.Response(_privateDetail, 502),
          'json' => http.Response(_privateDetail, 200),
          'rpc' => http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'error': {'code': -32000, 'message': _privateDetail},
              }),
              200),
          _ => http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'result': _privateDetail,
              }),
              200),
        };
      });
      final rpc = NodeRpcClient(
          rpcUrl: 'https://rpc.invalid/$_privateDetail', client: client);
      await expectLater(
          rpc.getChainId(),
          throwsA(isA<RpcException>().having((e) => e.toString(),
              'presentation', isNot(contains(_privateDetail)))));
      client.close();
    });
  }

  test('EVM malformed token balance and broadcast omit remote content',
      () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': _privateDetail}),
        200));
    final rpc = NodeRpcClient(rpcUrl: 'https://rpc.invalid', client: client);
    for (final request in [
      () => rpc.getErc20Balance(tokenContract: '0x00', holderAddress: '0x01'),
      () => rpc.sendRawTransaction('signed-fixture'),
    ]) {
      await expectLater(
          request,
          throwsA(isA<RpcException>().having((e) => e.toString(),
              'presentation', isNot(contains(_privateDetail)))));
    }
    client.close();
  });

  test('Bitcoin node error retains classification without displaying content',
      () async {
    final rpc = BitcoinRpcClient(
        endpoint: 'https://rpc.invalid/$_privateDetail',
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'result': null,
              'error': {
                'code': -5,
                'message':
                    'No such mempool or blockchain transaction $_privateDetail',
              },
            }),
            500)));
    await expectLater(
        rpc.verifyRegtest(),
        throwsA(isA<BitcoinRpcException>()
            .having((e) => e.transactionNotFound, 'transactionNotFound', isTrue)
            .having((e) => e.toString(), 'presentation',
                isNot(contains(_privateDetail)))));
    rpc.close();
  });
}
