import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/screens/account_screen.dart';
import 'package:wallet/screens/public_backup_screen.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/public_backup.dart';

class _PublicAccountNative implements WalletFfiService {
  @override
  int init() => 0;

  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native call: ${invocation.memberName}');
}

void main() {
  testWidgets('renaming keeps account within public backup label limit',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('fcw_label_backup_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = AccountStore('${directory.path}/accounts.json');
    final account = AccountDescriptor(
      masterFingerprint: '12345678',
      derivationPath: "m/44'/60'/0'/0/0",
      address: '0x1111111111111111111111111111111111111111',
      chainId: 11155111,
      compressedPublicKeyHex: '02${'11' * 32}',
      label: 'Original',
    );
    store.save(AccountSnapshot(accounts: [account]));
    await tester.pumpWidget(MaterialApp(
        home: AccountScreen(
      ffiOverride: _PublicAccountNative(),
      storagePathOverride: store.path,
    )));
    await tester.pumpAndSettle();
    final state = tester.state<AccountScreenState>(find.byType(AccountScreen));
    final maximumLabel = '名' * 100;
    state.renameAccount(0, '  $maximumLabel  ');
    await tester.pump();
    expect(state.currentAccount!.label, maximumLabel);
    final savedAtLimit = File(store.path).readAsStringSync();
    final source = PublicBackupCodec.encode(
        chainId: 11155111,
        accounts: state.accounts,
        transactions: [],
        bitcoinRecords: []);
    expect(
        PublicBackupCodec.decode(source).accounts.single.label, maximumLabel);

    state.renameAccount(0, '$maximumLabel名');
    await tester.pump();
    expect(state.currentAccount!.label, maximumLabel);
    expect(File(store.path).readAsStringSync(), savedAtLimit);
    expect(find.textContaining('100'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'public account recovery preserves original through cancel and save',
      (tester) async {
    final directory =
        Directory.systemTemp.createTempSync('fcw_account_recovery_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = AccountStore('${directory.path}/accounts.json');
    final account = AccountDescriptor(
      masterFingerprint: '12345678',
      derivationPath: "m/44'/60'/0'/0/0",
      address: '0x1111111111111111111111111111111111111111',
      chainId: 31337,
      compressedPublicKeyHex: '02${'11' * 32}',
      label: 'Restored public account',
    );
    store.save(AccountSnapshot(accounts: [account]));
    final file = File(store.path);
    final original = file.readAsBytesSync();
    final truncated = original.sublist(0, original.length - 1);
    file.writeAsBytesSync(truncated);
    final source = PublicBackupCodec.encode(
        chainId: 11155111,
        accounts: [account],
        transactions: [],
        bitcoinRecords: []);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('fcw/platform'),
        (call) async {
      if (call.method == 'readPublicBackup') return source;
      throw StateError('Unexpected platform call: ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null));
    await tester.pumpWidget(MaterialApp(
        home: AccountScreen(
      ffiOverride: _PublicAccountNative(),
      storagePathOverride: store.path,
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wallet_fatal_error')), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byKey(const Key('public_backup_btn')))
            .onPressed,
        isNotNull);
    late PublicBackupScreenState backup;
    await tester.runAsync(() async {
      tester
          .widget<IconButton>(find.byKey(const Key('public_backup_btn')))
          .onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      backup = tester
          .state<PublicBackupScreenState>(find.byType(PublicBackupScreen));
      await backup.initialized;
    });
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('export_public_backup')))
            .onPressed,
        isNull);
    await tester.runAsync(backup.readBackup);
    await tester.pumpAndSettle();
    expect(file.readAsBytesSync(), truncated);
    expect(directory.listSync().where((f) => f.path.endsWith('.bak')), isEmpty);

    final cancelled = tester.runAsync(backup.importAccountPhase);
    await tester.pumpAndSettle();
    expect(find.text('確認還原無法讀取的帳戶資料'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await cancelled;
    await tester.pumpAndSettle();
    expect(file.readAsBytesSync(), truncated);
    expect(directory.listSync().where((f) => f.path.endsWith('.bak')), isEmpty);

    final confirmed = tester.runAsync(backup.importAccountPhase);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_public_import')));
    await confirmed;
    await tester.pumpAndSettle();
    final preserved =
        directory.listSync().where((f) => f.path.endsWith('.bak')).toList();
    expect(preserved, hasLength(1));
    expect(File(preserved.single.path).readAsBytesSync(), truncated);
    expect(store.load().accounts.single.address, account.address);
    expect(store.load().accounts.single.chainId, 31337,
        reason: 'Import preserves immutable account network metadata');
    expect(store.load().chainId, 11155111,
        reason: 'The selected network remains an independent preference');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wallet_fatal_error')), findsNothing);
    expect(find.byKey(const Key('account_recovery_notice')), findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('account_recovery_notice')))
            .data!
            .replaceAll('/', r'\'),
        contains(preserved.single.path.replaceAll('/', r'\')));
    await tester.pumpWidget(const SizedBox());
  });

  test('failed recovery publish keeps original bytes and preserved sidecar',
      () {
    final directory =
        Directory.systemTemp.createTempSync('fcw_recovery_failure_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = AccountStore('${directory.path}/accounts.json');
    final original = <int>[123, 34, 97, 34, 58];
    File(store.path).writeAsBytesSync(original);
    Directory('${store.path}.tmp').createSync();
    expect(() => store.recoverWithSnapshot(const AccountSnapshot(accounts: [])),
        throwsA(isA<FileSystemException>()));
    expect(File(store.path).readAsBytesSync(), original);
    final preserved =
        directory.listSync().where((f) => f.path.endsWith('.bak')).toList();
    expect(preserved, hasLength(1));
    expect(File(preserved.single.path).readAsBytesSync(), original);
  });
}
