import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/screens/send_tx_screen.dart';
import 'package:wallet/screens/transaction_history_screen.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/node_rpc_client.dart';

// Public metadata, fake native validation, and fake HTTP only.
const _account = AccountDescriptor(
    masterFingerprint: '12345678',
    derivationPath: "m/44'/60'/0'/0/0",
    address: '0x1111111111111111111111111111111111111111',
    compressedPublicKeyHex:
        '021111111111111111111111111111111111111111111111111111111111111111',
    chainId: 11155111);

class _PublicNative implements WalletFfiService {
  @override
  int init() => 0;
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      true;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}

class _TrackedRpc extends NodeRpcClient {
  int closes = 0;
  _TrackedRpc(String url)
      : super(
            rpcUrl: url,
            client: MockClient((_) async => throw StateError(
                'HTTP must not run in route ownership tests')));
  @override
  void close() {
    closes++;
    super.close();
  }
}

void main() {
  for (final history in [false, true]) {
    for (final shared in [false, true]) {
      testWidgets(
          '${history ? 'history' : 'send'} route ${shared ? 'preserves shared RPC' : 'closes owned RPC after transition'}',
          (tester) async {
        final directory =
            Directory.systemTemp.createTempSync('public_route_rpc_');
        addTearDown(() => directory.deleteSync(recursive: true));
        final path = '${directory.path}/accounts.json';
        AccountStore(path).save(const AccountSnapshot(accounts: [_account]));
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('fcw/platform'), (call) async {
          if (call.method == 'storageDirectory') return directory.path;
          throw StateError('Unexpected platform operation');
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('fcw/platform'), null));
        final created = <_TrackedRpc>[];
        final external = _TrackedRpc('https://public.invalid');
        await tester.pumpWidget(MaterialApp(
            home: AccountScreen(
                ffiOverride: _PublicNative(),
                storagePathOverride: path,
                rpcOverride: shared ? external : null,
                routeRpcFactory: (url) {
                  final rpc = _TrackedRpc(url);
                  created.add(rpc);
                  return rpc;
                })));
        await tester.pumpAndSettle();
        final target = history
            ? find.text('交易紀錄')
            : find.byKey(const Key('create_unsigned_tx_btn'));
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pump();
        // Finish the route transition without waiting for the unrelated
        // asynchronous history file read and its loading indicator.
        await tester.pump(const Duration(seconds: 1));
        expect(created.length, shared ? 0 : 1);
        final rpc = shared ? external : created.single;
        expect(rpc.closes, 0);
        final child = history
            ? find.byType(TransactionHistoryScreen)
            : find.byType(SendTxScreen);
        expect(child, findsOneWidget);
        Navigator.of(tester.element(child)).pop();
        // Navigator.push's result has completed, but the outgoing route still
        // owns its client until its reverse transition and disposal complete.
        await tester.pump();
        expect(rpc.closes, 0);
        await tester.pumpAndSettle();
        expect(rpc.closes, shared ? 0 : 1);
        await tester.pumpWidget(const SizedBox());
        expect(rpc.closes, shared ? 0 : 1);
      });
    }
  }
}
