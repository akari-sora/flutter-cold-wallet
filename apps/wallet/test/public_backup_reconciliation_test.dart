import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/public_backup_screen.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/public_backup.dart';
import 'package:wallet/services/transaction_history.dart';

const account = AccountDescriptor(
    masterFingerprint: '73c5da0a', derivationPath: "m/44'/60'/0'/0/0",
    address: '0x9858effd232b4033e47d90003d41ec34ecaeda94', chainId: 31337,
    compressedPublicKeyHex: '0237b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299');

class BackupNative implements WalletFfiService {
  @override
  bool verifyPubkeyAddress({required String compressedPubkeyHex, required String expectedAddress}) => true;
  @override
  Map<String, dynamic> buildEthSignRequestUr({required String sessionId, required String requestIdHex,
      required String rawTxHex, required int chainId, required String derivationPath,
      required String masterFingerprintHex, required String expectedAddress, int maxFragmentLen = 120}) =>
      {'status': 'PENDING_REGISTERED'};
  @override
  void cancelPendingSession(String sessionId) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late PublicBackupService service;
  late AccountStore store;
  late AccountSnapshot current;
  late String source;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('backup_ui_retry_');
    store = AccountStore('${dir.path}/accounts.json');
    current = const AccountSnapshot(accounts: [], chainId: 31337);
    service = PublicBackupService(ffi: BackupNative(), directoryOverride: dir.path,
        history: TransactionHistory(pathOverride: '${dir.path}/history.json'));
    source = PublicBackupCodec.encode(chainId: 31337, accounts: [account], transactions: [{
      'requestId': '11' * 16, 'sessionId': 'original', 'account': account.address,
      'chainId': 31337, 'rpcUrl': '', 'unsignedPayload': '11',
      'state': 'awaitingSignature', 'updatedAt': '2026-10-15T00:00:00Z'
    }], bitcoinRecords: []);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), (call) async => call.method == 'readPublicBackup' ? source : null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null);
    dir.deleteSync(recursive: true);
  });

  Future<PublicBackupScreenState> mount(WidgetTester tester) async {
    late PublicBackupScreenState state;
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: PublicBackupScreen(snapshot: current,
          snapshotProvider: () => current, persistedSnapshotProvider: store.load, service: service,
          importAccounts: (accounts) {
            final marker = File('${dir.path}/public_import_progress.json').readAsStringSync();
            expect(marker, contains('"accounts_started":true'));
            current = AccountSnapshot(accounts: [...accounts], chainId: 31337);
            store.save(current);
            return true;
          })));
      state = tester.state<PublicBackupScreenState>(find.byType(PublicBackupScreen));
      await state.initialized;
    });
    await tester.pumpAndSettle();
    return state;
  }

  Future<void> approve(WidgetTester tester, Future<void> Function() action) async {
    final result = tester.runAsync(action);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_public_import')));
    await result;
    await tester.pumpAndSettle();
  }

  testWidgets('a removed account can be reconciled before completion', (tester) async {
    final state = await mount(tester);
    await tester.runAsync(state.readBackup);
    await tester.pumpAndSettle();
    await approve(tester, state.importAccountPhase);
    current = const AccountSnapshot(accounts: [], chainId: 31337);
    store.save(current);
    await approve(tester, state.importHistoryPhase);
    expect(File('${dir.path}/public_import_progress.json').existsSync(), isTrue);
    expect(tester.widget<FilledButton>(find.byKey(const Key('import_public_accounts'))).onPressed, isNotNull);
    await approve(tester, state.importAccountPhase);
    expect(current.accounts.single.address, account.address);
    await approve(tester, state.importHistoryPhase);
    expect(File('${dir.path}/public_import_progress.json').existsSync(), isFalse);
    expect(store.load().accounts.single.address, account.address);
  });

  testWidgets('unreadable progress explains global block', (tester) async {
    File('${dir.path}/public_import_progress.json').writeAsStringSync('{');
    final state = await mount(tester);
    expect(find.textContaining('所有帳戶的新付款'), findsOneWidget);
    expect(find.textContaining('其他帳戶不受此限制'), findsNothing);
    source = '{';
    await tester.runAsync(state.readBackup);
    await tester.pumpAndSettle();
    expect(find.textContaining('所有帳戶的新付款'), findsOneWidget);
  });

  testWidgets('failed selection before progress does not offer pause', (tester) async {
    source = '{';
    final state = await mount(tester);
    await tester.runAsync(state.readBackup);
    await tester.pumpAndSettle();
    expect(File('${dir.path}/public_import_progress.json').existsSync(), isFalse);
    expect(find.text('暫停未完成的還原'), findsNothing);
    expect(find.text('取消未開始的還原'), findsNothing);
  });
}
