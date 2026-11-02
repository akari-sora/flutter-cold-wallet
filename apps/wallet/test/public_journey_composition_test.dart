import 'dart:convert';
import 'dart:ffi';
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
import 'package:wallet/services/transaction_builder.dart';
import 'package:wallet/services/transaction_history.dart';

const _a = AccountDescriptor(
  masterFingerprint: 'f4ba9382',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x1F94AB1673e24d000D51493FE86d723D9FDc0A30',
  compressedPublicKeyHex:
      '025badc135bcb98eae9f8e031e0f3cd1c7e9a7dfcedccc0b1cddb3765fd11da6d6',
  chainId: 11155111,
  label: 'Account A',
);
const _b = AccountDescriptor(
  masterFingerprint: '73c5da0a',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
  compressedPublicKeyHex:
      '0237b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299',
  chainId: 11155111,
  label: 'Account B',
);
final _c = _a.copyWith(
    address: '0x1111111111111111111111111111111111111111', label: 'Account C');

// This first case composes production UI/storage/backup code with an explicitly
// mocked PUBLIC validation boundary. It proves no cryptographic acceptance.
class _MockPublicValidation implements WalletFfiService {
  int registrations = 0;
  int cancellations = 0;
  @override
  int init() => 0;
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      [_a, _b, _c].any((account) =>
          account.compressedPublicKeyHex == compressedPubkeyHex &&
          account.address.toLowerCase() == expectedAddress.toLowerCase());
  @override
  Map<String, dynamic> buildEthSignRequestUr(
      {required String sessionId,
      required String requestIdHex,
      required String rawTxHex,
      required int chainId,
      required String derivationPath,
      required String masterFingerprintHex,
      required String expectedAddress,
      int maxFragmentLen = 0}) {
    registrations++;
    return {'status': 'PENDING_REGISTERED'};
  }

  @override
  void cancelPendingSession(String sessionId) => cancellations++;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation: ${invocation.memberName}');
}

Map<String, dynamic> _unsignedRecord(
        String id, AccountDescriptor account, int chain) =>
    {
      'requestId': id,
      'sessionId': 'composition-$id',
      'account': account.address.toLowerCase(),
      'chainId': chain,
      'unsignedPayload': TransactionBuilder.buildLegacyUnsignedRlp(
          nonce: 1,
          gasPriceWei: BigInt.from(2000000000),
          gasLimit: 21000,
          toAddress: account.address,
          valueWei: BigInt.one,
          calldata: Uint8List(0),
          chainId: chain),
      'state': 'cancelled',
      'rpcUrl': 'http://127.0.0.1:8545',
    };

void main() {
  testWidgets(
      'mocked public boundary: accounts and chains survive restart and confirmed backup retry',
      (tester) async {
    final directory =
        Directory.systemTemp.createTempSync('fcw_public_journey_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = AccountStore('${directory.path}/paired_accounts.json');
    final history = TransactionHistory(
        pathOverride: '${directory.path}/public_transactions.json');
    final native = _MockPublicValidation();
    store.save(const AccountSnapshot(accounts: [_a, _b]));
    await tester.runAsync(() async {
      for (final row in [
        _unsignedRecord('01' * 16, _a, 11155111),
        _unsignedRecord('02' * 16, _b, 11155111),
        _unsignedRecord('03' * 16, _a, 31337),
        _unsignedRecord('04' * 16, _b, 31337),
        _unsignedRecord('05' * 16, _c, 31337),
      ]) {
        await history.save(row);
      }
    });
    final originalHistory = File(history.pathOverride!).readAsBytesSync();
    final orphanBitcoin = File('${directory.path}/bitcoin_aabbccdd.json');
    orphanBitcoin.writeAsStringSync(jsonEncode({
      'schema_version': 1,
      'account_address': 'bcrt1qpublicarchived',
      'master_fingerprint': 'aabbccdd',
      'state': 'draft',
      'request': null,
      'built': null,
      'response_ur': null,
      'history': [],
    }));
    final originalBitcoin = orphanBitcoin.readAsBytesSync();
    final importSource = PublicBackupCodec.encode(chainId: 31337, accounts: [
      _a.copyWith(chainId: 31337),
      _b.copyWith(chainId: 31337),
      _c.copyWith(chainId: 31337)
    ], transactions: [
      _unsignedRecord('05' * 16, _c, 31337),
      _unsignedRecord('06' * 16, _b, 31337)
    ], bitcoinRecords: []);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('fcw/platform'),
        (call) async {
      if (call.method == 'storageDirectory') return directory.path;
      if (call.method == 'readPublicBackup') return importSource;
      throw StateError('Unexpected platform/network action: ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null));
    Future<AccountScreenState> mount() async {
      await tester.pumpWidget(MaterialApp(
          home: AccountScreen(
              ffiOverride: native, storagePathOverride: store.path)));
      await tester.pumpAndSettle();
      return tester.state<AccountScreenState>(find.byType(AccountScreen));
    }

    var state = await mount();
    state.selectAccount(1);
    state.renameAccount(1, 'My public B');
    state.selectAccount(0);
    expect(state.currentAccount!.address, _a.address);
    state.selectAccount(1);
    state.selectChainId(31337);
    await tester.pumpWidget(const SizedBox());
    final restarted = AccountStore(store.path).load();
    expect(restarted.selectedIndex, 1);
    expect(restarted.chainId, 31337);
    expect(
        restarted.accounts.map((account) => account.chainId),
        [11155111, 11155111, 31337, 31337],
        reason: 'Restart recovers only the native-validated legacy bindings; '
            'selecting a network does not rewrite either identity');
    expect(restarted.accounts[1].label, 'My public B');
    state = await mount();
    expect(state.currentAccount!.address, _b.address);
    expect(File(history.pathOverride!).readAsBytesSync(), originalHistory);
    final service = PublicBackupService(
        ffi: native, history: history, directoryOverride: directory.path);
    final before =
        await tester.runAsync(() => service.prepareExport(restarted));
    expect(before!.includedEvmTransactionCount, 4);
    expect(before.excludedEvmCount, 1);
    expect(before.evmExclusionReasons, {'unpaired_account': 1});
    expect(before.evmExclusionReasons, isNot(contains('other_chain')),
        reason: 'Network selection is independent of per-account binding');
    expect(before.excludedBitcoinRecordCount, 1);
    expect(before.bitcoinExclusionReasons, {'unpaired_account': 1});
    final originalAccounts = File(store.path).readAsBytesSync();

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
    await tester.runAsync(backup.readBackup);
    await tester.pumpAndSettle();
    final cancelled = tester.runAsync(backup.importAccountPhase);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await cancelled;
    await tester.pumpAndSettle();
    expect(File(store.path).readAsBytesSync(), originalAccounts);
    expect(File(history.pathOverride!).readAsBytesSync(), originalHistory);

    Future<void> confirm(Future<void> Function() action) async {
      final operation = tester.runAsync(action);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_public_import')));
      await operation;
      await tester.pumpAndSettle();
    }

    await confirm(backup.importAccountPhase);
    await confirm(backup.importHistoryPhase);
    final firstImport = await tester.runAsync(history.read);
    expect(firstImport, hasLength(6));
    expect(
        firstImport!
            .singleWhere((row) => row['requestId'] == '05' * 16)['state'],
        'cancelled');
    expect(
        firstImport
            .singleWhere((row) => row['requestId'] == '06' * 16)['state'],
        'unknown');
    await tester.runAsync(backup.readBackup);
    await tester.pumpAndSettle();
    await confirm(backup.importAccountPhase);
    await confirm(backup.importHistoryPhase);
    expect(await tester.runAsync(history.read), firstImport);
    final finalSnapshot = AccountStore(store.path).load();
    expect(finalSnapshot.accounts, hasLength(5));
    expect(finalSnapshot.selectedIndex, 1);
    expect(finalSnapshot.accounts[1].label, 'My public B');
    expect(finalSnapshot.chainId, 31337);
    expect(
        finalSnapshot.accounts
            .where((account) =>
                account.address.toLowerCase() == _a.address.toLowerCase())
            .map((account) => account.chainId),
        unorderedEquals([11155111, 31337]),
        reason: 'The same verified address remains independently chain-bound');
    expect(
        finalSnapshot.accounts
            .where((account) =>
                account.address.toLowerCase() == _b.address.toLowerCase())
            .map((account) => account.chainId),
        unorderedEquals([11155111, 31337]));
    expect(
        finalSnapshot.accounts
            .singleWhere((account) => account.address == _c.address)
            .chainId,
        31337);
    final after =
        await tester.runAsync(() => service.prepareExport(finalSnapshot));
    expect(after!.includedEvmTransactionCount, 6);
    expect(after.excludedEvmCount, 0);
    expect(after.evmExclusionReasons, isEmpty);
    expect(after.excludedBitcoinRecordCount, 1);
    expect(orphanBitcoin.readAsBytesSync(), originalBitcoin);
    expect(native.registrations, native.cancellations);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  final dllPath = Platform.environment['WALLET_FFI_PATH'];
  test(
      'explicit candidate native verifier accepts existing public response and backup retry',
      () async {
    // The optional case never invokes NativeLibraryLoader or its fallback paths.
    // Supplying a path requires its exact expected SHA-256 as a second input.
    expect(dllPath, isNotNull);
    final dll = File(dllPath!);
    expect(dll.isAbsolute, isTrue);
    expect(dll.existsSync(), isTrue);
    final expectedHash = Platform.environment['FCW_JOURNEY_WALLET_FFI_SHA256'];
    expect(expectedHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    final hashResult = Platform.isWindows
        ? Process.runSync('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r"([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.IO.File]::ReadAllBytes($env:FCW_JOURNEY_DLL_FILE)))).Replace('-','').ToLowerInvariant()"
          ], environment: {
            'FCW_JOURNEY_DLL_FILE': dll.absolute.path
          })
        : Platform.isMacOS
            ? Process.runSync('shasum', ['-a', '256', dll.absolute.path])
            : Process.runSync('sha256sum', [dll.absolute.path]);
    expect(hashResult.exitCode, 0);
    // shasum and sha256sum print "<hash>  <path>"; powershell prints the hash.
    expect('${hashResult.stdout}'.trim().split(RegExp(r'\s+')).first,
        expectedHash);
    final fixture = jsonDecode(
        File('test/fixtures/existing_signature_public.json')
            .readAsStringSync()) as Map<String, dynamic>;
    final account = AccountDescriptor.fromJson(
            Map<String, dynamic>.from(fixture['account'] as Map))
        .copyWith(chainId: 11155111);
    final native = WalletFfiService(DynamicLibrary.open(dll.absolute.path));
    expect(native.init(), 0);
    expect(
        native.verifyPubkeyAddress(
            compressedPubkeyHex: account.compressedPublicKeyHex!,
            expectedAddress: account.address),
        isTrue);
    const session = 'composition-existing-public-return';
    try {
      final registered = native.buildEthSignRequestUr(
          sessionId: session,
          requestIdHex: fixture['requestId'] as String,
          rawTxHex: fixture['unsignedPayload'] as String,
          chainId: 11155111,
          derivationPath: account.derivationPath,
          masterFingerprintHex: account.masterFingerprint,
          expectedAddress: account.address);
      expect(registered['status'], 'PENDING_REGISTERED');
      final verified = native.verifyAndAssembleEthSignatureUr(
          sessionId: session,
          expectedRequestIdHex: fixture['requestId'] as String,
          urOrFrames: fixture['signatureUr'] as String);
      expect(verified['verified'], isTrue);
      expect(verified['signed_raw_tx_hex'], fixture['signedRaw']);
      expect(verified['local_tx_hash'], fixture['hash']);
    } finally {
      native.cancelPendingSession(session);
    }
    final directory =
        Directory.systemTemp.createTempSync('fcw_native_public_journey_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final history =
        TransactionHistory(pathOverride: '${directory.path}/history.json');
    final service = PublicBackupService(
        ffi: native, history: history, directoryOverride: directory.path);
    final bundle = PublicBackupCodec.decode(
        PublicBackupCodec.encode(chainId: 11155111, accounts: [
      account
    ], transactions: [
      {
        'requestId': fixture['requestId'],
        'sessionId': fixture['sessionId'],
        'account': account.address.toLowerCase(),
        'chainId': 11155111,
        'unsignedPayload': fixture['unsignedPayload'],
        'signatureUr': fixture['signatureUr'],
        'signedRaw': fixture['signedRaw'],
        'hash': fixture['hash'],
        'state': 'confirmed',
      }
    ], bitcoinRecords: []));
    await service.importTransactions(bundle);
    final imported = await history.read();
    await service.importTransactions(bundle);
    expect(await history.read(), imported);
    expect(imported.single['state'], 'unknown');
    expect(imported.single['signedRaw'], fixture['signedRaw']);
    expect(imported.single['hash'], fixture['hash']);
  },
      skip: dllPath == null
          ? 'Requires explicit WALLET_FFI_PATH and FCW_JOURNEY_WALLET_FFI_SHA256; no DLL fallback.'
          : false);
}
