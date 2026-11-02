import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/public_backup_screen.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/public_backup.dart';

class _NoNativeCalls implements WalletFfiService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

class _PreparedPublicBackup extends PublicBackupService {
  _PreparedPublicBackup() : super(ffi: _NoNativeCalls());

  @override
  Future<PublicImportProgress?> readProgress() async => null;

  @override
  Future<PublicBackupExportPreview> prepareExport(
          AccountSnapshot snapshot) async =>
      PublicBackupExportPreview(
        backupJson: '{"public":"selected fixture"}',
        includedAccountCount: 2,
        includedEvmTransactionCount: 4,
        includedBitcoinRecordCount: 1,
        excludedEvmCount: 3,
        excludedBitcoinRecordCount: 2,
        evmExclusionReasons: {'unpaired_account': 1, 'other_chain': 2},
        bitcoinExclusionReasons: {'unpaired_account': 2},
      );
}

void main() {
  testWidgets('export shows exact omissions before opening save picker',
      (tester) async {
    var saves = 0;
    String? saved;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('fcw/platform'),
        (call) async {
      if (call.method != 'savePublicBackup') {
        throw StateError('Unexpected platform call: ${call.method}');
      }
      saves++;
      saved = (call.arguments as Map)['json'] as String;
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null));
    await tester.pumpWidget(MaterialApp(
        home: PublicBackupScreen(
      snapshot: const AccountSnapshot(accounts: []),
      service: _PreparedPublicBackup(),
      importAccounts: (_) => throw StateError('Unexpected account import'),
    )));
    await tester.pumpAndSettle();
    final state =
        tester.state<PublicBackupScreenState>(find.byType(PublicBackupScreen));
    final cancelled = state.exportBackup();
    await tester.pumpAndSettle();
    final summary = tester.widget<Text>(find.textContaining('此備份包含目前')).data!;
    expect(summary, contains('2 個觀察帳戶、4 筆 EVM 紀錄及 1 份 Bitcoin 紀錄'));
    expect(summary, contains('未納入 EVM 紀錄：3 筆（未配對帳戶 1、其他網路 2）'));
    expect(summary, contains('未納入 Bitcoin 紀錄：2 份（未配對帳戶 2）'));
    expect(saves, 0);
    await tester.tap(find.text('取消').last);
    await cancelled;
    await tester.pumpAndSettle();
    expect(saves, 0);

    final confirmed = state.exportBackup();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_public_import')));
    await confirmed;
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(saved, '{"public":"selected fixture"}');
    expect(find.textContaining('未納入 3 筆 EVM／2 份 Bitcoin 紀錄'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
