import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:wallet/screens/scan_signature_screen.dart';
import 'package:wallet/services/transaction_history.dart';
import 'transaction_flow_test.dart' as fixtures;

class PathHistory extends TransactionHistory {
  PathHistory(String path) : super(pathOverride: path);
  @override
  Future<void> save(Map<String, dynamic> record) async {}
}

void main() {
  testWidgets('pending import prevents signature scanner and acceptance', (tester) async {
    final dir = Directory.systemTemp.createTempSync('fcw_evm_pending_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/public_import_progress.json').writeAsStringSync('{');
    final ffi = fixtures.FakeFfi();
    final rpc = fixtures.FakeRpc();
    addTearDown(rpc.close);
    await tester.pumpWidget(MaterialApp(home: ScanSignatureScreen(
      account: fixtures.account, ffiOverride: ffi, rpcOverride: rpc,
      historyOverride: PathHistory('${dir.path}/transactions.json'),
      unsignedRlpHex: '12', requestId: '12', sessionId: 'test')));
    await tester.pump();
    expect(find.byType(AirGapScanner), findsNothing);
    final state = tester.state<ScanSignatureScreenState>(find.byType(ScanSignatureScreen));
    await state.ingestSignatureUr('ur:eth-signature/test');
    expect(ffi.verifications, 0);
  });

  testWidgets('pending import permits query but refuses broadcast', (tester) async {
    final dir = Directory.systemTemp.createTempSync('fcw_evm_pending_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final ffi = fixtures.FakeFfi();
    final rpc = fixtures.FakeRpc();
    addTearDown(rpc.close);
    await tester.pumpWidget(MaterialApp(home: ScanSignatureScreen(
      account: fixtures.account, ffiOverride: ffi, rpcOverride: rpc,
      historyOverride: PathHistory('${dir.path}/transactions.json'),
      unsignedRlpHex: '12', requestId: '12', sessionId: 'test')));
    await tester.pump();
    final state = tester.state<ScanSignatureScreenState>(find.byType(ScanSignatureScreen));
    await state.ingestSignatureUr('ur:eth-signature/test');
    await tester.pump();
    File('${dir.path}/public_import_progress.json').writeAsStringSync('{');
    await state.broadcast();
    expect(rpc.sends, 0);
    await state.queryTransaction();
    expect(rpc.queries, 1);
  });
}
