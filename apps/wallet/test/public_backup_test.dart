import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/transaction_history.dart';
import 'package:wallet/screens/public_backup_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet/services/public_backup.dart';

const _account = AccountDescriptor(
    masterFingerprint: '73c5da0a',
    derivationPath: "m/44'/60'/0'/0/0",
    address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
    chainId: 31337,
    label: '公開帳戶',
    compressedPublicKeyHex:
        '0237b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299',
);
Map<String, dynamic> _record() => {
      'requestId': '11' * 16,
      'sessionId': 'original-session',
      'account': _account.address,
      'chainId': 31337,
      'rpcUrl': 'https://rpc.invalid/?api_key=never-export',
      'unsignedPayload': '11',
      'signatureUr': 'ur:eth-signature/public',
      'signedRaw': '0x22',
      'hash': '0x${'33' * 32}',
      'state': 'confirmed',
      'updatedAt': '2026-10-15T00:00:00Z',
};

class _BackupNative implements WalletFfiService {
  bool rejectSignature = false;
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress,
  }) =>
      compressedPubkeyHex == _account.compressedPublicKeyHex &&
      expectedAddress == _account.address;
  @override
  Map<String, dynamic> buildEthSignRequestUr(
          {required String sessionId,
          required String requestIdHex,
          required String rawTxHex,
          required int chainId,
          required String derivationPath,
          required String masterFingerprintHex,
          required String expectedAddress,
          int maxFragmentLen = 120,
  }) =>
      {'status': 'PENDING_REGISTERED'};
  @override
  Map<String, dynamic> verifyAndAssembleEthSignatureUr(
          {required String sessionId,
          required String expectedRequestIdHex,
          required String urOrFrames,
  }) =>
      rejectSignature
          ? {'status': 'ERROR'}
          : {
              'status': 'SIGNED_TX_READY',
              'verified': true,
              'signed_raw_tx_hex': '0x22',
              'local_tx_hash': '0x${'33' * 32}',
              'recovered_address': _account.address,
          };
  @override
  void cancelPendingSession(String sessionId) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BackupBitcoin implements BitcoinFfiService {
  Map<String, dynamic> canonical = {};
  Map<String, dynamic> built = {};
  @override
  Map<String, dynamic> describe(Map<String, dynamic> request) => canonical;
  @override
  Map<String, dynamic> build(Map<String, dynamic> request) => built;
  @override
  Map<String, dynamic> verify(Map<String, dynamic> request) =>
      {'status': 'VERIFIED', 'txid': built['txid']};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Map<String, dynamic> emptyBackup() => {
        'schema': 'fcw-public-wallet-backup',
        'version': 1,
        'created_at': '2026-10-15T00:00:00Z',
        'chain_id': 31337,
        'accounts': [],
        'transactions': [],
        'bitcoin_records': [],
  };
  test('rejects secret or unknown fields before any validation or write', () {
    final backup = emptyBackup()..['mnemonic'] = 'never import this';
    expect(() => PublicBackupCodec.decode(jsonEncode(backup)),
        throwsFormatException,
    );
  });
  test('rejects unsupported schema, chain and oversized JSON', () {
    expect(
        () => PublicBackupCodec.decode(
            jsonEncode(emptyBackup()..['version'] = 3)),
        throwsFormatException,
    );
    expect(
        () => PublicBackupCodec.decode(
            jsonEncode(emptyBackup()..['chain_id'] = 1)),
        throwsFormatException,
    );
    expect(
        () => PublicBackupCodec.decode(' ' * (PublicBackupCodec.maxBytes + 1)),
        throwsFormatException,
    );
  });
  test('public backup excludes RPC configuration by construction', () {
    final encoded = PublicBackupCodec.encode(
        chainId: 31337, accounts: [], transactions: [], bitcoinRecords: [],
    );
    final raw = jsonDecode(encoded) as Map;
    expect(
        raw.keys,
        unorderedEquals([
          'schema',
          'version',
          'created_at',
          'chain_id',
          'accounts',
          'transactions',
          'bitcoin_records',
      ]),
    );
    expect(PublicBackupCodec.decode(encoded).accounts, isEmpty);
  });
  group('public backup persistence and App flow', () {
    late Directory directory;
    late TransactionHistory history;
    late _BackupNative native;
    late PublicBackupService service;
    late String source;
    late List<AccountDescriptor> localAccounts;
    late String? exported;
    setUp(() {
      directory = Directory.systemTemp.createTempSync('public_backup_');
      history = TransactionHistory(
          pathOverride: '${directory.path}/public_transactions.json',
      );
      native = _BackupNative();
      service = PublicBackupService(
          ffi: native, history: history, directoryOverride: directory.path,
      );
      source = PublicBackupCodec.encode(
          chainId: 31337,
          accounts: [_account],
          transactions: [_record()],
          bitcoinRecords: [],
      );
      localAccounts = [];
      exported = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('fcw/platform'),
              (call,
          ) async {
        if (call.method == 'readPublicBackup') return source;
        if (call.method == 'savePublicBackup') {
          exported = (call.arguments as Map)['json'] as String;
          return true;
        }
        throw StateError('unexpected platform method');
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('fcw/platform'), null);
      directory.deleteSync(recursive: true);
    });
    test(
      'pending overlay scopes EVM reservations and ignores done flags',
      () async {
        final progress = await service.beginImport(source);
        progress.accountsStarted = true;
        progress.accountsDone = true;
        progress.evmDone = true;
        await service.saveProgress(progress);
        bool blocked(
          String family,
          String address, {
          int? chainId,
          String? fingerprint,
        }) => PublicImportProgress.blocksPaymentAt(
          directory.path,
          assetFamily: family,
          account: address,
          chainId: chainId,
          masterFingerprint: fingerprint,
        );
        expect(blocked('EVM', _account.address, chainId: 31337), isTrue);
        expect(blocked('EVM', _account.address, chainId: 11155111), isFalse);
        expect(blocked('BTC', 'bcrt1qother', fingerprint: '12345678'), isFalse);
        await expectLater(service.clearProgress, throwsStateError);
        final file = File('${directory.path}/public_import_progress.json');
        final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        raw.remove('accounts_started');
        file.writeAsStringSync(jsonEncode(raw));
        expect(blocked('EVM', _account.address, chainId: 31337), isTrue);
        file.writeAsStringSync('{');
        expect(blocked('BTC', 'bcrt1qother', fingerprint: '12345678'), isTrue);
      },
    );
    test(
      'preflight rejects descriptor conflict without mutating files',
      () async {
        final file = File('${directory.path}/public_transactions.json');
        await history.save(_record());
        final before = file.readAsBytesSync();
        final conflicting = AccountDescriptor(
          masterFingerprint: 'abcdef01',
          derivationPath: _account.derivationPath,
          address: _account.address,
          chainId: _account.chainId,
          compressedPublicKeyHex: _account.compressedPublicKeyHex,
        );
        await expectLater(
          () => service.preflightImport(
            PublicBackupCodec.decode(source),
            AccountSnapshot(accounts: [conflicting], chainId: 31337),
          ),
          throwsFormatException,
        );
        expect(file.readAsBytesSync(), before);
        expect(
          File('${directory.path}/public_import_progress.json').existsSync(),
          isFalse,
        );
      },
    );
    test(
      'preflight rejects conflicting existing EVM signature without writes',
      () async {
        final row = _record()..['signedRaw'] = '0x44';
        await history.save(row);
        final file = File('${directory.path}/public_transactions.json');
        final before = file.readAsBytesSync();
        await expectLater(
          () => service.preflightImport(
            PublicBackupCodec.decode(source),
            const AccountSnapshot(accounts: [_account], chainId: 31337),
          ),
          throwsFormatException,
        );
        expect(file.readAsBytesSync(), before);
        expect(
          File('${directory.path}/public_import_progress.json').existsSync(),
          isFalse,
        );
      },
    );
    test('BTC history overlay blocks its fingerprint only', () async {
      const btc = AccountDescriptor(
        masterFingerprint: '12345678',
        derivationPath: "m/84'/1'/0'/0/0",
        address: 'bcrt1qreceive',
        chainId: 0,
        assetFamily: 'BTC',
        extendedPublicKey: 'tpubTest',
      );
      final btcSource = PublicBackupCodec.encode(
        chainId: 31337,
        accounts: [btc],
        transactions: [],
        bitcoinRecords: [
          {
            'account_address': btc.address,
            'master_fingerprint': btc.masterFingerprint,
            'state': 'draft',
            'request': null,
            'built': null,
            'response_ur': null,
            'history': [
              {
                'txid': '33' * 32,
                'state': 'confirmed',
                'amount_sat': '1000',
                'recipient_address': 'bcrt1qother',
              },
            ],
          },
        ],
      );
      await service.saveProgress(
        PublicImportProgress(
          btcSource,
          accountsStarted: true,
          accountsDone: true,
          evmDone: true,
          bitcoinDone: {'12345678'},
        ),
      );
      expect(
        PublicImportProgress.blocksPaymentAt(
          directory.path,
          assetFamily: 'BTC',
          account: btc.address,
          masterFingerprint: '12345678',
        ),
        isTrue,
      );
      expect(
        PublicImportProgress.blocksPaymentAt(
          directory.path,
          assetFamily: 'BTC',
          account: 'bcrt1qother',
          masterFingerprint: '87654321',
        ),
        isFalse,
      );
      expect(
        PublicImportProgress.blocksPaymentAt(
          directory.path,
          assetFamily: 'EVM',
          account: _account.address,
          chainId: 31337,
        ),
        isFalse,
      );
    });
    for (final scenario in ['summary mismatch', 'terminal missing inputs', 'active signatures']) {
      test('BTC preflight rejects $scenario without writes', () async {
        const btc = AccountDescriptor(masterFingerprint: '12345678',
            derivationPath: "m/84'/1'/0'/0/0", address: 'bcrt1qreceive',
            chainId: 0, assetFamily: 'BTC', extendedPublicKey: 'tpubTest');
        final request = <String, dynamic>{'account_xpub': 'tpubTest',
          'master_fingerprint': '12345678', 'recipient_address': 'bcrt1qother',
          'amount_sat': '1000', 'fee_sat': '50', 'change_index': 0, 'utxos': [
            {'txid': '44' * 32, 'vout': 0, 'previous_tx_hex': '00', 'branch': 0, 'address_index': 0}]};
        final built = <String, dynamic>{'status': 'SUCCESS', 'network': 'regtest',
          'psbt_hex': '00', 'unsigned_tx_hex': '00', 'expected_digest': '11' * 32,
          'txid': '33' * 32, 'recipient_address': 'bcrt1qother',
          'change_address': 'bcrt1qchange', 'amount_sat': '1000',
          'change_sat': '100', 'fee_sat': '50', 'ur_frames': ['ur:psbt/test']};
        final btcNative = _BackupBitcoin()..canonical = {'status': 'SUCCESS',
          'address': btc.address, 'receive_address_regtest': null,
          'change_address': null, 'descriptor': null, 'derivation_path': btc.derivationPath}
          ..built = built;
        final btcService = PublicBackupService(ffi: native, bitcoin: btcNative,
            history: history, directoryOverride: directory.path);
        Map<String, dynamic> summary(String state, String amount) => {
          'txid': '33' * 32, 'state': state, 'amount_sat': amount,
          'recipient_address': 'bcrt1qother'};
        Map<String, dynamic> record(String response, List<dynamic> rows) => {
          'account_address': btc.address, 'master_fingerprint': btc.masterFingerprint,
          'state': scenario == 'active signatures' ? 'unknown' : 'draft',
          'request': scenario == 'active signatures' ? request : null,
          'built': scenario == 'active signatures' ? built : null,
          'response_ur': scenario == 'active signatures' ? response : null,
          'history': rows};
        final local = record('ur:signature/local', [if (scenario != 'active signatures')
          summary('confirmed', '1000')]);
        if (scenario == 'terminal missing inputs') {
          (local['history'] as List).single['recovery'] =
              {'request': request, 'built': built, 'response_ur': null};
        }
        final incoming = record('ur:signature/backup', [if (scenario != 'active signatures')
          summary('unknown', scenario == 'summary mismatch' ? '2000' : '1000')]);
        final source = PublicBackupCodec.encode(chainId: 31337, accounts: [btc],
            transactions: [], bitcoinRecords: [incoming]);
        final file = File('${directory.path}/bitcoin_12345678.json');
        file.writeAsStringSync(jsonEncode({...local, 'schema_version': 2}));
        final before = file.readAsBytesSync();
        await expectLater(() async {
          await btcService.preflightImport(PublicBackupCodec.decode(source),
              const AccountSnapshot(accounts: [], chainId: 31337));
          await btcService.beginImport(source);
        }, throwsFormatException);
        expect(file.readAsBytesSync(), before);
        expect(File('${directory.path}/public_import_progress.json').existsSync(), isFalse);
      });
    }
    for (final (incomingState, state) in [
      ('pending', 'confirmed'), ('pending', 'failed'), ('confirmed', 'confirmed')
    ]) {
      test('completion preserves locally queried legacy BTC summary $incomingState to $state', () async {
        const btc = AccountDescriptor(masterFingerprint: '12345678',
            derivationPath: "m/84'/1'/0'/0/0", address: 'bcrt1qreceive',
            chainId: 0, assetFamily: 'BTC', extendedPublicKey: 'tpubTest');
        final btcNative = _BackupBitcoin()..canonical = {'status': 'SUCCESS',
          'address': btc.address, 'receive_address_regtest': null,
          'change_address': null, 'descriptor': null, 'derivation_path': btc.derivationPath};
        final btcService = PublicBackupService(ffi: native, bitcoin: btcNative,
            history: history, directoryOverride: directory.path);
        final record = <String, dynamic>{'account_address': btc.address,
          'master_fingerprint': btc.masterFingerprint, 'state': 'draft',
          'request': null, 'built': null, 'response_ur': null,
          'history': [{'txid': '33' * 32, 'state': incomingState,
            'amount_sat': '1000', 'recipient_address': 'bcrt1qother'}]};
        final backup = PublicBackupCodec.encode(chainId: 31337, accounts: [btc],
            transactions: [], bitcoinRecords: [record]);
        final bundle = PublicBackupCodec.decode(backup);
        const snapshot = AccountSnapshot(accounts: [btc], chainId: 31337);
        final store = AccountStore('${directory.path}/accounts.json');
        await btcService.preflightImport(bundle, const AccountSnapshot(accounts: [], chainId: 31337));
        final progress = await btcService.beginImport(backup);
        progress.accountsStarted = true;
        await btcService.saveProgress(progress);
        store.save(snapshot);
        progress.accountsDone = true;
        await btcService.saveProgress(progress);
        await btcService.importBitcoinRecord(bundle, bundle.bitcoinRecords.single);
        final file = File('${directory.path}/bitcoin_12345678.json');
        final local = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect((local['history'] as List).single['state'], 'unknown');
        (local['history'] as List).single['state'] = state;
        (local['history'] as List).single['confirmations'] = state == 'confirmed' ? 1 : -1;
        (local['history'] as List).single['checked_at'] = '2026-10-15T00:00:00Z';
        file.writeAsStringSync(jsonEncode(local));
        final before = file.readAsBytesSync();
        progress.evmDone = true;
        progress.bitcoinDone.add(btc.masterFingerprint);
        await btcService.saveProgress(progress);
        await btcService.completeImport(progress, snapshot, persistedSnapshotProvider: store.load);
        expect(file.readAsBytesSync(), before);
        expect((jsonDecode(file.readAsStringSync())['history'] as List).single['state'], state);
        expect(PublicImportProgress.isPendingAt(directory.path), isFalse);
      });
    }

    test('completion rejects conflicting BTC summary and retains marker and bytes', () async {
      const btc = AccountDescriptor(masterFingerprint: '12345678',
          derivationPath: "m/84'/1'/0'/0/0", address: 'bcrt1qreceive',
          chainId: 0, assetFamily: 'BTC', extendedPublicKey: 'tpubTest');
      final btcNative = _BackupBitcoin()..canonical = {'status': 'SUCCESS',
        'address': btc.address, 'receive_address_regtest': null,
        'change_address': null, 'descriptor': null, 'derivation_path': btc.derivationPath};
      final btcService = PublicBackupService(ffi: native, bitcoin: btcNative,
          history: history, directoryOverride: directory.path);
      final record = <String, dynamic>{'account_address': btc.address,
        'master_fingerprint': btc.masterFingerprint, 'state': 'draft',
        'request': null, 'built': null, 'response_ur': null,
        'history': [{'txid': '33' * 32, 'state': 'unknown',
          'amount_sat': '1000', 'recipient_address': 'bcrt1qother'}]};
      final backup = PublicBackupCodec.encode(chainId: 31337, accounts: [btc],
          transactions: [], bitcoinRecords: [record]);
      final bundle = PublicBackupCodec.decode(backup);
      final progress = await btcService.beginImport(backup);
      const snapshot = AccountSnapshot(accounts: [btc], chainId: 31337);
      final store = AccountStore('${directory.path}/accounts.json')..save(snapshot);
      progress.accountsStarted = true;
      progress.accountsDone = true;
      await btcService.saveProgress(progress);
      await btcService.importBitcoinRecord(bundle, bundle.bitcoinRecords.single);
      final file = File('${directory.path}/bitcoin_12345678.json');
      final local = jsonDecode(file.readAsStringSync()) as Map;
      (local['history'] as List).single['state'] = 'confirmed';
      (local['history'] as List).single['amount_sat'] = '2000';
      file.writeAsStringSync(jsonEncode(local));
      final before = file.readAsBytesSync();
      progress.evmDone = true;
      progress.bitcoinDone.add(btc.masterFingerprint);
      await btcService.saveProgress(progress);
      final marker = File('${directory.path}/public_import_progress.json');
      final markerBefore = marker.readAsBytesSync();
      await expectLater(() => btcService.completeImport(progress, snapshot,
          persistedSnapshotProvider: store.load), throwsFormatException);
      expect(file.readAsBytesSync(), before);
      expect(marker.readAsBytesSync(), markerBefore);
    });

    test('preflight preserves unrelated orphan EVM record', () async {
      final orphan = _record()..['requestId'] = '44' * 16
        ..['account'] = '0x${'55' * 20}';
      await history.save(orphan);
      final file = File('${directory.path}/public_transactions.json');
      final before = file.readAsBytesSync();
      await service.preflightImport(PublicBackupCodec.decode(source),
          const AccountSnapshot(accounts: [], chainId: 31337));
      expect(file.readAsBytesSync(), before);
      await service.importTransactions(PublicBackupCodec.decode(source),
          snapshot: const AccountSnapshot(accounts: [], chainId: 31337));
      expect((await history.read()).any((row) => row['requestId'] == orphan['requestId'] &&
          row['account'] == orphan['account']), isTrue);
    });
    test('preflight rejects orphan sharing incoming request ID', () async {
      final orphan = _record()..['account'] = '0x${'55' * 20}';
      await history.save(orphan);
      final file = File('${directory.path}/public_transactions.json');
      final before = file.readAsBytesSync();
      await expectLater(() => service.preflightImport(PublicBackupCodec.decode(source),
          const AccountSnapshot(accounts: [], chainId: 31337)), throwsFormatException);
      expect(file.readAsBytesSync(), before);
    });
    test('completion accepts exact signed active BTC already archived', () async {
      const btc = AccountDescriptor(masterFingerprint: '12345678',
          derivationPath: "m/84'/1'/0'/0/0", address: 'bcrt1qreceive',
          chainId: 0, assetFamily: 'BTC', extendedPublicKey: 'tpubTest');
      final request = <String, dynamic>{'account_xpub': 'tpubTest',
        'master_fingerprint': '12345678', 'recipient_address': 'bcrt1qother',
        'amount_sat': '1000', 'fee_sat': '50', 'change_index': 0, 'utxos': []};
      final built = <String, dynamic>{'status': 'SUCCESS', 'network': 'regtest',
        'psbt_hex': '00', 'unsigned_tx_hex': '00', 'expected_digest': '11' * 32,
        'txid': '33' * 32, 'recipient_address': 'bcrt1qother',
        'change_address': 'bcrt1qchange', 'amount_sat': '1000',
        'change_sat': '100', 'fee_sat': '50', 'ur_frames': ['ur:psbt/test']};
      final btcNative = _BackupBitcoin()..canonical = {'status': 'SUCCESS',
        'address': btc.address, 'receive_address_regtest': null, 'change_address': null,
        'descriptor': null, 'derivation_path': btc.derivationPath}..built = built;
      final btcService = PublicBackupService(ffi: native, bitcoin: btcNative,
          history: history, directoryOverride: directory.path);
      final active = {'account_address': btc.address, 'master_fingerprint': '12345678',
        'state': 'unknown', 'request': request, 'built': built,
        'response_ur': 'ur:signature/backup', 'history': []};
      final source = PublicBackupCodec.encode(chainId: 31337, accounts: [btc],
          transactions: [], bitcoinRecords: [active]);
      final progress = await btcService.beginImport(source);
      progress.accountsStarted = true; progress.accountsDone = true;
      progress.evmDone = true; progress.bitcoinDone.add('12345678');
      await btcService.saveProgress(progress);
      final file = File('${directory.path}/bitcoin_12345678.json');
      file.writeAsStringSync(jsonEncode({...active, 'schema_version': 2,
        'state': 'draft', 'request': null, 'built': null, 'response_ur': null,
        'history': [{'txid': built['txid'], 'state': 'unknown',
          'amount_sat': '1000', 'recipient_address': 'bcrt1qother',
          'recovery': {'request': request, 'built': built, 'response_ur': 'ur:signature/backup'}}]}));
      final before = file.readAsBytesSync();
      const snapshot = AccountSnapshot(accounts: [btc], chainId: 31337);
      await btcService.completeImport(progress, snapshot, persistedSnapshotProvider: () => snapshot);
      expect(file.readAsBytesSync(), before);
      expect(PublicImportProgress.isPendingAt(directory.path), isFalse);
    });
    test('preflight preserves malformed existing Bitcoin record', () async {
      const btc = AccountDescriptor(
        masterFingerprint: '12345678',
        derivationPath: "m/84'/1'/0'/0/0",
        address: 'bcrt1qreceive',
        chainId: 0,
        assetFamily: 'BTC',
        extendedPublicKey: 'tpubTest',
      );
      final btcNative =
          _BackupBitcoin()
            ..canonical = {
              'status': 'SUCCESS',
              'address': btc.address,
              'receive_address_regtest': null,
              'change_address': null,
              'descriptor': null,
              'derivation_path': btc.derivationPath,
            };
      final btcService = PublicBackupService(
        ffi: native,
        bitcoin: btcNative,
        history: history,
        directoryOverride: directory.path,
      );
      final source = PublicBackupCodec.encode(
        chainId: 31337,
        accounts: [btc],
        transactions: [],
        bitcoinRecords: [
          {
            'account_address': btc.address,
            'master_fingerprint': btc.masterFingerprint,
            'state': 'draft',
            'request': null,
            'built': null,
            'response_ur': null,
            'history': [],
          },
        ],
      );
      final file = File('${directory.path}/bitcoin_12345678.json');
      file.writeAsStringSync('{');
      await expectLater(
        () => btcService.preflightImport(
          PublicBackupCodec.decode(source),
          const AccountSnapshot(accounts: [], chainId: 31337),
        ),
        throwsFormatException,
      );
      expect(file.readAsStringSync(), '{');
      expect(
        File('${directory.path}/public_import_progress.json').existsSync(),
        isFalse,
      );
    });
    test(
      'completion requires the full Bitcoin record before clearing',
      () async {
        const btc = AccountDescriptor(
          masterFingerprint: '12345678',
          derivationPath: "m/84'/1'/0'/0/0",
          address: 'bcrt1qreceive',
          chainId: 0,
          assetFamily: 'BTC',
          extendedPublicKey: 'tpubTest',
        );
        final btcNative =
            _BackupBitcoin()
              ..canonical = {
                'status': 'SUCCESS',
                'address': btc.address,
                'receive_address_regtest': null,
                'change_address': null,
                'descriptor': null,
                'derivation_path': btc.derivationPath,
              };
        final btcService = PublicBackupService(
          ffi: native,
          bitcoin: btcNative,
          history: history,
          directoryOverride: directory.path,
        );
        final record = <String, dynamic>{
          'account_address': btc.address,
          'master_fingerprint': btc.masterFingerprint,
          'state': 'draft',
          'request': null,
          'built': null,
          'response_ur': null,
          'history': [
            {
              'txid': '33' * 32,
              'state': 'unknown',
              'amount_sat': '1000',
              'recipient_address': 'bcrt1qother',
            },
          ],
        };
        final source = PublicBackupCodec.encode(
          chainId: 31337,
          accounts: [btc],
          transactions: [],
          bitcoinRecords: [record],
        );
        final progress = await btcService.beginImport(source);
        progress.accountsStarted = true;
        progress.accountsDone = true;
        progress.evmDone = true;
        progress.bitcoinDone.add(btc.masterFingerprint);
        await btcService.saveProgress(progress);
        const snapshot = AccountSnapshot(accounts: [btc], chainId: 31337);
        final store = AccountStore('${directory.path}/accounts.json');
        store.save(snapshot);
        await expectLater(
          () => btcService.completeImport(
            progress,
            snapshot,
            persistedSnapshotProvider: store.load,
          ),
          throwsStateError,
        );
        final file = File('${directory.path}/bitcoin_12345678.json');
        file.writeAsStringSync(jsonEncode({...record, 'schema_version': 2}));
        final before = file.readAsBytesSync();
        await btcService.completeImport(
          progress,
          snapshot,
          persistedSnapshotProvider: store.load,
        );
        expect(file.readAsBytesSync(), before);
        expect(PublicImportProgress.isPendingAt(directory.path), isFalse);
      },
    );
    test(
      'existing account recovery verifies terminal signature and preserves bytes',
      () async {
        await history.save(_record());
        final file = File('${directory.path}/public_transactions.json');
        final before = file.readAsBytesSync();
        native.rejectSignature = true;
        await expectLater(
          service.recoverLegacyEvmBindings(
            const AccountSnapshot(accounts: [_account]),
          ),
          throwsFormatException,
        );
        expect(file.readAsBytesSync(), before);
      },
    );
    test(
      'export strips endpoint query secrets; bad signature refuses import',
        () async {
      await history.save(_record());
      final output = await service.export(const AccountSnapshot(
          accounts: [_account],
          chainId: 31337,
          rpcUrl: 'https://private-rpc.invalid/?password=private',
          ),
        );
      expect(output.contains('never-export'), false);
      expect(output.contains('private-rpc'), false);
      expect(output.contains('rpcUrl'), false);
      native.rejectSignature = true;
      await expectLater(
          () => service.beginImport(output), throwsFormatException,
        );
      expect(File('${directory.path}/public_import_progress.json').existsSync(),
          false,
        );
      expect((await history.read()).single['state'], 'confirmed');
    },
    );
    test('BTC tpub descriptor and change address must match native derivation',
        () async {
      const btc = AccountDescriptor(
          masterFingerprint: '73c5da0a',
          derivationPath: "m/84'/1'/0'/0/0",
          address: 'bcrt1qreceive',
          chainId: 0,
          assetFamily: 'BTC',
          extendedPublicKey: 'tpubTest',
          btcReceiveAddressRegtest: 'bcrt1qreceive',
          btcChangeAddress: 'bcrt1qchange',
          btcDescriptor: 'wpkh(tpubTest/0/*)',
        );
      final bitcoin = _BackupBitcoin()
        ..canonical = {
          'status': 'SUCCESS',
          'address': btc.address,
          'receive_address_regtest': btc.address,
          'change_address': 'bcrt1qwrong',
          'descriptor': btc.btcDescriptor,
          'derivation_path': btc.derivationPath,
              };
      final backupService = PublicBackupService(
          ffi: native,
          bitcoin: bitcoin,
          history: history,
          directoryOverride: directory.path,
        );
      final bundle = PublicBackupCodec.decode(PublicBackupCodec.encode(
          chainId: 31337,
          accounts: [btc],
          transactions: [],
          bitcoinRecords: [],
          ),
        );
      await expectLater(
          () => backupService.validate(bundle), throwsFormatException,
        );
      bitcoin.canonical['change_address'] = btc.btcChangeAddress;
      await backupService.validate(bundle);
    },
    );
    test('history restore is atomic/idempotent and always starts unknown',
        () async {
      final bundle = PublicBackupCodec.decode(source);
      await service.importTransactions(bundle);
      await service.importTransactions(bundle);
      final saved = await history.read();
      expect(saved.length, 1);
      expect(saved.single['state'], 'unknown');
      expect(saved.single['rpcUrl'], '');
    },
    );
    Future<PublicBackupScreenState> mount(WidgetTester tester,
        {bool failAccountSave = false,
    }) async {
      tester.view.physicalSize = const Size(1200, 2300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AccountSnapshot snapshot() => AccountSnapshot(
          accounts: [...localAccounts],
          chainId: 31337,
          rpcUrl: 'http://127.0.0.1:8545',
      );
      late PublicBackupScreenState result;
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            home: PublicBackupScreen(
                snapshot: snapshot(),
                snapshotProvider: snapshot,
              persistedSnapshotProvider:
                  () => AccountStore('${directory.path}/accounts.json').load(),
              service: service,
                importAccounts: (incoming) {
                final progress =
                    jsonDecode(
                          File(
                            '${directory.path}/public_import_progress.json',
                          ).readAsStringSync(),
                        )
                        as Map<String, dynamic>;
                expect(progress['accounts_started'], isTrue);
                if (failAccountSave) return false;
                  final ids = localAccounts.map((a) => a.address).toSet();
                  final next = [...localAccounts];
                  for (final a in incoming) {
                    if (ids.add(a.address)) next.add(a);
                  }
                  AccountStore('${directory.path}/accounts.json',
                )
                      .save(AccountSnapshot(accounts: next, chainId: 31337));
                  localAccounts = next;
                  return true;
                },
            ),
          ),
        );
        result = tester
            .state<PublicBackupScreenState>(find.byType(PublicBackupScreen),
        );
        await result.initialized;
      });
      await tester.pumpAndSettle();
      return result;
    }

    Future<void> approve(
        WidgetTester tester, Future<void> Function() action,
    ) async {
      final operation = tester.runAsync(action);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm_public_import')));
      await operation;
      await tester.pumpAndSettle();
    }

    testWidgets(
        'preview makes no account write; independent confirmations resume after restart',
        (tester) async {
      var state = await mount(tester);
      await tester.runAsync(state.readBackup);
      await tester.pumpAndSettle();
      expect(localAccounts, isEmpty);
      expect(await tester.runAsync(history.read), isEmpty);
      expect(find.textContaining('匯入摘要：1 個帳戶'), findsOneWidget);
      expect(find.textContaining('主指紋 73C5DA0A'), findsOneWidget);
      expect(find.textContaining('73c5da0a'), findsNothing);
      await approve(tester, state.importAccountPhase);
      expect(localAccounts.length, 1);
      expect(await tester.runAsync(history.read), isEmpty);
      await tester.pumpWidget(const SizedBox());
      state = await mount(tester);
      expect(find.text('帳戶已保存'), findsOneWidget);
      await approve(tester, state.importHistoryPhase);
      expect((await tester.runAsync(history.read))!.single['state'], 'unknown',
        );
      expect(File('${directory.path}/public_import_progress.json').existsSync(),
          false,
        );
      expect(find.textContaining('還原完成'), findsOneWidget);
    },
    );
    testWidgets(
      'partially imported backup remains resumable after cancel and restart',
      (tester) async {
        var state = await mount(tester);
        await tester.runAsync(state.readBackup);
        await tester.pumpAndSettle();
        await approve(tester, state.importAccountPhase);
        expect(localAccounts, hasLength(1));
        expect(await tester.runAsync(history.read), isEmpty);

        await state.cancelImport();
        await tester.pump();
        expect(
          File('${directory.path}/public_import_progress.json').existsSync(),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
        state = await mount(tester);
        expect(find.text('帳戶已保存'), findsOneWidget);
        await approve(tester, state.importHistoryPhase);
        expect(
          (await tester.runAsync(history.read))!.single['state'],
          'unknown',
        );
        expect(
          File('${directory.path}/public_import_progress.json').existsSync(),
          isFalse,
        );
      },
    );
    test('forged done flags do not clear missing history', () async {
      final progress = await service.beginImport(source);
      progress.accountsStarted = true;
      progress.accountsDone = true;
      progress.evmDone = true;
      await service.saveProgress(progress);
      final store = AccountStore('${directory.path}/accounts.json');
      store.save(const AccountSnapshot(accounts: [_account], chainId: 31337));
      await expectLater(
        () => service.completeImport(
          progress,
          const AccountSnapshot(accounts: [_account], chainId: 31337),
          persistedSnapshotProvider: store.load,
        ),
        throwsStateError,
      );
      expect(PublicImportProgress.isPendingAt(directory.path), isTrue);
    });
    test(
      'completion retains marker when account was not saved on disk',
      () async {
        final progress = await service.beginImport(source);
        await service.importTransactions(PublicBackupCodec.decode(source));
        progress.accountsStarted = true;
        progress.accountsDone = true;
        progress.evmDone = true;
        await service.saveProgress(progress);
        final store = AccountStore('${directory.path}/accounts.json');
        await expectLater(
          () => service.completeImport(
            progress,
            const AccountSnapshot(accounts: [_account], chainId: 31337),
            persistedSnapshotProvider: store.load,
          ),
          throwsStateError,
        );
        expect(PublicImportProgress.isPendingAt(directory.path), isTrue);
      },
    );
    test(
      'unstarted preview can be cleared; malformed progress cannot',
      () async {
        await service.beginImport(source);
        final file = File('${directory.path}/public_import_progress.json');
        expect(PublicImportProgress.isPendingAt(directory.path), isTrue);
        await service.clearProgress();
        expect(PublicImportProgress.isPendingAt(directory.path), isFalse);
        file.writeAsStringSync('{');
        expect(
          () => PublicImportProgress.requireCompleteAt(directory.path),
          throwsStateError,
        );
        await expectLater(service.clearProgress, throwsFormatException);
        await expectLater(
          () => service.beginImport(source),
          throwsFormatException,
        );
        expect(file.readAsStringSync(), '{');
      },
    );
    test(
      'old pending progress is retained when its start state is unknown',
      () async {
        await service.beginImport(source);
        final file = File('${directory.path}/public_import_progress.json');
        final saved =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        saved.remove('accounts_started');
        file.writeAsStringSync(jsonEncode(saved));
        await expectLater(service.clearProgress, throwsStateError);
        expect(file.existsSync(), isTrue);
      },
    );
    testWidgets(
        'failed account persistence cannot advance to history confirmation',
        (tester) async {
      final state = await mount(tester, failAccountSave: true);
      await tester.runAsync(state.readBackup);
      await tester.pumpAndSettle();
      await approve(tester, state.importAccountPhase);
      expect(localAccounts, isEmpty);
      expect(await tester.runAsync(history.read), isEmpty);
      expect(
          (await tester.runAsync(service.readProgress))!.accountsDone, false,
        );
      expect(find.textContaining('帳戶原子保存失敗'), findsOneWidget);
    },
    );
    testWidgets(
        'export uses native save picker and visibly reports cancellation',
        (tester) async {
      localAccounts = [_account];
      final state = await mount(tester);
      Future<void> approvePreparedExport() async {
        await tester.runAsync(() async {
          final operation = state.exportBackup();
          final watch = Stopwatch()..start();
          final confirmation = find.byKey(const Key('confirm_public_import'));
          while (confirmation.evaluate().isEmpty &&
              watch.elapsed < const Duration(seconds: 5)) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            await tester.pump();
          }
          expect(confirmation, findsOneWidget);
          await tester.pumpAndSettle();
          await tester.tap(confirmation);
          await operation;
        });
        await tester.pumpAndSettle();
      }

      await approvePreparedExport();
      await tester.pumpAndSettle();
      expect(exported, isNotNull);
      expect(find.textContaining('已儲存公開帳戶'), findsOneWidget);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('fcw/platform'),
              (_) async => throw PlatformException(code: 'cancelled'),
            );
      await approvePreparedExport();
      await tester.pumpAndSettle();
      expect(find.textContaining('公開備份未完成'), findsOneWidget);
    },
    );
  });
}
