import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wallet/services/bitcoin_rpc_client.dart';
import 'package:wallet/services/node_rpc_client.dart';
import 'package:wallet/services/node_url_policy.dart';

void expectKind(List<String> urls, NodeUrlKind kind) {
  for (final url in urls) {
    expect(NodeUrlPolicy.classify(url), kind, reason: url);
  }
}

void main() {
  test('https is accepted for any host', () {
    expectKind([
      'https://public.invalid',
      'https://8.8.8.8:8545',
      'https://[2001:db8::1]:8545',
      'https://xn--80ak6aa92e.com/rpc',
    ], NodeUrlKind.https);
  });

  test('plaintext reaches this phone', () {
    expectKind([
      'http://localhost:8545',
      'HTTP://LocalHost:18443/wallet/fcw_watch',
      'http://127.0.0.1:8545',
      'http://127.255.255.254',
      'http://[::1]:8545',
      'http://[::ffff:127.0.0.1]:8545',
    ], NodeUrlKind.loopbackHttp);
  });

  test('plaintext reaches private networks at the range boundaries', () {
    expectKind([
      'http://10.0.2.2:8545',
      'http://10.255.255.255',
      'http://172.16.0.0',
      'http://172.31.255.255',
      'http://192.168.0.1:18443',
      'http://192.168.255.255',
      'http://169.254.0.1',
      'http://[fc00::1]',
      'http://[fdff:ffff::1]',
      'http://[fe80::1]',
      'http://[febf::1]',
      'http://[fe80::1%25wlan0]:8545',
      'http://[::ffff:192.168.1.2]',
    ], NodeUrlKind.privateHttp);
    expectKind([
      'http://172.15.255.255',
      'http://172.32.0.0',
      'http://100.64.0.1',
      'http://100.127.255.254',
      'http://192.167.255.255',
      'http://192.169.0.1',
      'http://169.253.255.255',
      'http://169.255.0.1',
      'http://11.0.0.1',
      'http://126.255.255.255',
      'http://128.0.0.1',
      'http://0.0.0.0',
      'http://[fbff::1]',
      'http://[fec0::1]',
      'http://[::]',
      'http://[::2]',
      'http://[::7f00:1]',
    ], NodeUrlKind.publicHttp);
  });

  test('plaintext to public hosts is refused', () {
    expectKind([
      'http://8.8.8.8:8545',
      'http://1.1.1.1',
      'http://[2001:db8::1]',
      'http://[::ffff:8.8.8.8]',
      'http://[64:ff9b::808:808]',
      'http://rpc.example.com:8545',
      'http://sepolia.infura.io/v3/key',
    ], NodeUrlKind.publicHttp);
  });

  test('single-label and .local names are local, other names are not', () {
    expectKind([
      'http://bitcoind:18443',
      'http://nas',
      'http://umbrel.local:8332',
      'http://node.home.local',
      'http://xn--nas-ab1c.local',
      'http://beef',
    ], NodeUrlKind.privateHttp);
    expectKind([
      'http://xn--80ak6aa92e.com',
      'http://local.example',
      'http://foo.localhost',
      'http://localhost.',
      'http://umbrel.local.',
      'http://例え.local',
      'http://my_node',
    ], NodeUrlKind.publicHttp);
  });

  test('numbers the resolver reads as addresses are not names', () {
    // 2130706433 and 0x7f000001 are 127.0.0.1; 134744072 is 8.8.8.8; a
    // leading zero is octal to inet_aton, so 010.0.0.1 is 8.0.0.1.
    expectKind([
      'http://2130706433',
      'http://134744072',
      'http://0x7f000001',
      'http://0x0a000001',
      'http://127.1',
      'http://10.1',
      'http://010.0.0.1',
      'http://0177.0.0.1',
      'http://192.168.1.1.1',
      'http://256.0.0.1',
    ], NodeUrlKind.publicHttp);
  });

  test('anything that is not an http(s) URL with a host is invalid', () {
    expectKind([
      '',
      'not a url',
      '127.0.0.1:8545',
      'ftp://127.0.0.1',
      'ws://localhost:8545',
      'http://',
      'http://:8545',
      'http://user:pw@127.0.0.1:8545',
      'https://token@public.invalid',
      'http://[::1',
    ], NodeUrlKind.invalid);
  });

  test('the EVM client refuses public plaintext before sending anything',
      () async {
    final sent = <Uri>[];
    final client = MockClient((request) async {
      sent.add(request.url);
      return http.Response('{"jsonrpc":"2.0","id":1,"result":"0x1"}', 200);
    });
    final rpc =
        NodeRpcClient(rpcUrl: 'http://203.0.113.7:8545', client: client);
    await expectLater(
        rpc.sendRawTransaction('0x02', expectedChainId: 1),
        throwsA(isA<RpcException>().having(
            (e) => e.message, 'message', NodeUrlPolicy.publicHttpRefused)));
    expect(sent, isEmpty);
    expect(
        await NodeRpcClient(rpcUrl: 'http://192.168.1.5:8545', client: client)
            .getChainId(),
        1);
    expect(sent.single.host, '192.168.1.5');
  });

  test('the Bitcoin client refuses public plaintext as not sent', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add((jsonDecode(request.body) as Map)['method'] as String);
      return http.Response('{"result":{"chain":"regtest"},"error":null}', 200);
    });
    final rpc = BitcoinRpcClient(
        endpoint: 'http://node.example.com:18443',
        username: 'rpc',
        password: 'synthetic',
        client: client);
    await expectLater(
        rpc.broadcast('00'),
        throwsA(isA<BitcoinRpcException>()
            .having((e) => e.notSent, 'notSent', isTrue)
            .having((e) => e.message, 'message',
                contains(NodeUrlPolicy.publicHttpRefused))));
    expect(methods, isEmpty);
    await BitcoinRpcClient(endpoint: 'http://bitcoind:18443', client: client)
        .verifyRegtest();
    expect(methods, ['getblockchaininfo']);
  });

  test('the native platform notes state this rule and where it is enforced',
      () {
    final notes = File('../../docs/QR_NATIVE_PLATFORMS.md').readAsStringSync();
    expect(notes, isNot(contains('HTTP 僅允許 localhost、127.0.0.1')));
    expect(notes, contains('apps/wallet/lib/services/node_url_policy.dart'));
    expect(notes, contains('不依賴 `network_security_config.xml`'));
    for (final allowed in [
      '`localhost`',
      '`127.0.0.0/8`',
      '`::1`',
      '`10.0.0.0/8`',
      '`172.16.0.0/12`',
      '`192.168.0.0/16`',
      '`169.254.0.0/16`',
      '`fc00::/7`',
      '`fe80::/10`',
      '`.local`',
    ]) {
      expect(notes, contains(allowed));
    }
    for (final link in [
      '(privacy/privacy-policy.zh-TW.md)',
      '(privacy/privacy-policy.en.md)'
    ]) {
      expect(notes, contains(link));
      expect(
          File('../../docs/${link.substring(1, link.length - 1)}').existsSync(),
          isTrue);
    }
  });
}
