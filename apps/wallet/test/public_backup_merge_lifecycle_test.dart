import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:wallet/ffi/bitcoin_ffi_service.dart';
import 'package:wallet/ffi/wallet_ffi_service.dart';
import 'package:wallet/services/account_store.dart';
import 'package:wallet/services/public_backup.dart';
import 'package:wallet/services/transaction_history.dart';

// Public placeholders follow the existing public_backup_test.dart and
// bitcoin_flow_test.dart fakes. No native library or signing operation is used.
const _account = AccountDescriptor(
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

const _evmAccount = AccountDescriptor(
  masterFingerprint: '73c5da0a',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
  chainId: 31337,
  compressedPublicKeyHex:
      '0237b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299',
);

const _sepoliaEvmAccount = AccountDescriptor(
  masterFingerprint: '73c5da0a',
  derivationPath: "m/44'/60'/0'/0/0",
  address: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
  chainId: 11155111,
  compressedPublicKeyHex:
      '0237b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299',
);

Map<String, dynamic> _evmRecord(String requestId,
        {String account = '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        int chainId = 31337}) =>
    {
      'requestId': requestId,
      'sessionId': 'public-session',
      'account': account,
      'chainId': chainId,
      'unsignedPayload': '11',
      'state': 'cancelled',
    };

Map<String, dynamic> _request() => {
      'account_xpub': _account.extendedPublicKey,
      'master_fingerprint': _account.masterFingerprint,
      'recipient_address': 'bcrt1qrecipient',
      'amount_sat': '5000000',
      'fee_sat': '1500',
      'change_index': 0,
      'utxos': [
        {
          'txid': '33' * 32,
          'vout': 0,
          'previous_tx_hex': '00',
          'branch': 0,
          'address_index': 0,
        }
      ],
    };

Map<String, dynamic> _built() => {
      'status': 'SUCCESS',
      'network': 'regtest',
      'psbt_hex': '70736274ff',
      'expected_digest': '11' * 32,
      'ur_frames': ['ur:crypto-psbt/test'],
      'txid': '22' * 32,
      'unsigned_tx_hex': '01000000',
      'recipient_address': 'bcrt1qrecipient',
      'change_address': _account.btcChangeAddress,
      'amount_sat': '5000000',
      'change_sat': '10000',
      'fee_sat': '1500',
    };

Map<String, dynamic> _archived() => {
      'txid': '44' * 32,
      'state': 'confirmed',
      'amount_sat': '1000',
      'recipient_address': 'bcrt1qprevious',
    };

Map<String, dynamic> _record({String? response, String state = 'confirmed'}) =>
    {
      'account_address': _account.address,
      'master_fingerprint': _account.masterFingerprint,
      'state': state,
      'request': _request(),
      'built': _built(),
      'response_ur': response,
      'history': [_archived()],
    };

class _PublicWalletNative implements WalletFfiService {
  @override
  bool verifyPubkeyAddress(
          {required String compressedPubkeyHex,
          required String expectedAddress}) =>
      compressedPubkeyHex == _evmAccount.compressedPublicKeyHex &&
      expectedAddress == _evmAccount.address;

  @override
  Map<String, dynamic> buildEthSignRequestUr(
          {required String sessionId,
          required String requestIdHex,
          required String rawTxHex,
          required int chainId,
          required String derivationPath,
          required String masterFingerprintHex,
          required String expectedAddress,
          int maxFragmentLen = 120}) =>
      {'status': 'PENDING_REGISTERED'};

  @override
  void cancelPendingSession(String sessionId) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation');
}

class _PublicBitcoinNative implements BitcoinFfiService {
  @override
  Map<String, dynamic> describe(Map<String, dynamic> request) => {
        'status': 'SUCCESS',
        'address': _account.address,
        'receive_address_regtest': _account.btcReceiveAddressRegtest,
        'change_address': _account.btcChangeAddress,
        'descriptor': _account.btcDescriptor,
        'derivation_path': _account.derivationPath,
      };

  @override
  Map<String, dynamic> build(Map<String, dynamic> request) => _built();

  @override
  Map<String, dynamic> verify(Map<String, dynamic> request) => {
        'status': 'VERIFIED',
        'tx_hex': '01000000',
        'txid': '22' * 32,
      };
}

void main() {
  late Directory directory;
  late File file;
  late TransactionHistory history;
  late PublicBackupService service;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('btc_backup_merge_');
    file = File('${directory.path}/bitcoin_${_account.masterFingerprint}.json');
    history = TransactionHistory(
        pathOverride: '${directory.path}/public_transactions.json');
    service = PublicBackupService(
      ffi: _PublicWalletNative(),
      bitcoin: _PublicBitcoinNative(),
      history: history,
      directoryOverride: directory.path,
    );
  });

  tearDown(() => directory.deleteSync(recursive: true));

  PublicBackupBundle bundle(Map<String, dynamic> record) =>
      PublicBackupCodec.decode(PublicBackupCodec.encode(
        chainId: 31337,
        accounts: [_account],
        transactions: [],
        bitcoinRecords: [record],
      ));

  void saveLocal(Map<String, dynamic> record) =>
      file.writeAsStringSync(jsonEncode({
        'schema_version': 1,
        ...record,
        'rpc_endpoint': 'http://127.0.0.1:18443/wallet/fcw_watch',
      }));

  Map<String, dynamic> recoverableArchive({String? response}) => {
        'txid': _built()['txid'],
        'state': 'cancelled',
        'amount_sat': _built()['amount_sat'],
        'recipient_address': _built()['recipient_address'],
        'recovery': {
          'request': _request(),
          'built': _built(),
          'response_ur': response
        },
        'confirmations': 2,
        'checked_at': '2026-10-18T00:00:00Z',
      };

  Map<String, dynamic> archivedRecord(Map<String, dynamic> row) => {
        'account_address': _account.address,
        'master_fingerprint': _account.masterFingerprint,
        'state': 'draft',
        'request': null,
        'built': null,
        'response_ur': null,
        'history': [row],
      };

  test(
      'recoverable BTC archive is validated and restored without trusted status',
      () async {
    final archive =
        recoverableArchive(response: 'ur:crypto-psbt/public-response');
    final imported = bundle(archivedRecord(archive));
    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['request'], isNull);
    expect(saved['history'][0]['recovery'], archive['recovery']);
    expect(saved['history'][0]['state'], 'unknown');
    expect(saved['history'][0]['confirmations'], isNull);
    expect(saved['history'][0]['checked_at'], isNull);
    final first = file.readAsStringSync();
    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);
    expect(file.readAsStringSync(), first);
  });

  test(
      'matching legacy summary gains recovery data and conflicting bundle is rejected',
      () async {
    final archive =
        recoverableArchive(response: 'ur:crypto-psbt/public-response');
    final legacy = {...archive}..remove('recovery');
    saveLocal(archivedRecord(legacy));
    final imported = bundle(archivedRecord(archive));
    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);
    expect(
        (jsonDecode(file.readAsStringSync()) as Map)['history'][0]['recovery'],
        archive['recovery']);
    final before = file.readAsStringSync();
    final conflicting = recoverableArchive(
        response: 'ur:crypto-psbt/different-public-response');
    final other = bundle(archivedRecord(conflicting));
    await expectLater(
        service.importBitcoinRecord(other, other.bitcoinRecords.single),
        throwsFormatException);
    expect(file.readAsStringSync(), before);
  });

  test('archived recovery uses the same public allowlist and account binding',
      () async {
    final archive = recoverableArchive();
    (archive['recovery'] as Map)['unexpected_secret_field'] =
        'synthetic-placeholder';
    expect(() => bundle(archivedRecord(archive)), throwsFormatException);
    final mismatched = recoverableArchive();
    ((mismatched['recovery'] as Map)['request'] as Map)['account_xpub'] =
        'tpubAnother';
    final imported = bundle(archivedRecord(mismatched));
    await expectLater(service.validate(imported), throwsFormatException);
    expect(file.existsSync(), isFalse);
  });

  test('legacy same-TXID summary conflict cannot poison recovery or export',
      () async {
    final archive = recoverableArchive();
    final legacy = {...archive, 'amount_sat': '999'}..remove('recovery');
    saveLocal(archivedRecord(legacy));
    final before = file.readAsStringSync();
    final imported = bundle(archivedRecord(archive));
    await expectLater(
        service.importBitcoinRecord(imported, imported.bitcoinRecords.single),
        throwsFormatException);
    expect(file.readAsStringSync(), before);
    PublicBackupCodec.bitcoin(archivedRecord(legacy));
  });

  test('archive summary matching stored built still must match native rebuild',
      () async {
    // Summary and stored `built` agree with each other, but not with what the
    // native core derives from the public request.
    final archive = recoverableArchive();
    archive['amount_sat'] = '4000000';
    ((archive['recovery'] as Map)['built'] as Map)['amount_sat'] = '4000000';
    final imported = bundle(archivedRecord(archive));
    await expectLater(service.validate(imported), throwsFormatException);
    expect(file.existsSync(), isFalse);
    final active = _record();
    (active['built'] as Map)['recipient_address'] = 'bcrt1qforged';
    await expectLater(
        service.validate(bundle(active)), throwsFormatException);
  });

  test('unsigned local request rejects an imported signed archive of its TXID',
      () async {
    saveLocal(_record(state: 'awaitingSignature'));
    final before = file.readAsStringSync();
    final imported = bundle(archivedRecord(
        recoverableArchive(response: 'ur:crypto-psbt/public-response')));
    await expectLater(
        service.importBitcoinRecord(imported, imported.bitcoinRecords.single),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('請先封存本機待簽交易'))));
    expect(file.readAsStringSync(), before);
  });

  test('UR framing differences do not make the same PSBT a conflict',
      () async {
    final local = _record(state: 'awaitingSignature');
    (local['built'] as Map)['ur_frames'] = [
      'ur:crypto-psbt/1-2/older-framing',
      'ur:crypto-psbt/2-2/older-framing'
    ];
    saveLocal(local);
    final imported =
        bundle(_record(response: 'ur:crypto-psbt/public-response'));
    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);
    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['response_ur'], 'ur:crypto-psbt/public-response');
    expect(saved['state'], 'unknown');
  });

  test('large public response codec roundtrip fits whole-backup bound', () {
    // Synthetic text measures serialization capacity only, not native validity.
    final response = 'ur:crypto-psbt/${'a' * 300000}';
    final decoded =
        bundle(archivedRecord(recoverableArchive(response: response)));
    expect(
        decoded.bitcoinRecords.single['history'][0]['recovery']['response_ur'],
        response);
    expect(
        () => bundle(archivedRecord(recoverableArchive(
            response: 'a' * (PublicBackupCodec.maxBytes + 1)))),
        throwsFormatException);
  });

  test('combined history limit rejects import without changing original bytes',
      () async {
    final local = archivedRecord(_archived());
    local['history'] = List.generate(1000, (_) => _archived());
    saveLocal(local);
    final before = file.readAsBytesSync();
    final incoming =
        bundle(archivedRecord({..._archived(), 'txid': '55' * 32}));
    await expectLater(
        service.importBitcoinRecord(incoming, incoming.bitcoinRecords.single),
        throwsFormatException);
    expect(file.readAsBytesSync(), before);
  });

  test('combined file byte limit rejects import and preserves original bytes',
      () async {
    // Capacity placeholders only; the injected public verifier performs no crypto.
    final response = 'ur:crypto-psbt/${'a' * 1100000}';
    saveLocal(_record(response: response));
    final before = file.readAsBytesSync();
    expect(before.length, lessThan(PublicBackupCodec.maxBytes));
    final incoming =
        bundle(archivedRecord(recoverableArchive(response: response)));
    await expectLater(
        service.importBitcoinRecord(incoming, incoming.bitcoinRecords.single),
        throwsFormatException);
    expect(file.readAsBytesSync(), before);
  });

  test('signed backup completes matching unsigned BTC request as query-only',
      () async {
    final local = _record(state: 'awaitingSignature');
    local['request'] = Map<String, dynamic>.fromEntries(
        (local['request'] as Map<String, dynamic>).entries.toList().reversed);
    local['built'] = Map<String, dynamic>.fromEntries(
        (local['built'] as Map<String, dynamic>).entries.toList().reversed);
    saveLocal(local);
    final imported =
        bundle(_record(response: 'ur:crypto-psbt/public-response'));

    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);

    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['response_ur'], 'ur:crypto-psbt/public-response');
    expect(saved['state'], 'unknown');
    expect(saved['request'], _request());
    expect(saved['built'], _built());
    expect(saved['history'], [_archived()]);
    final afterFirstImport = file.readAsStringSync();

    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);

    expect(file.readAsStringSync(), afterFirstImport,
        reason: 'Retry preserves the restored response and one history row');
  });

  test('identical backup preserves an already saved BTC response and history',
      () async {
    final local = _record(response: 'ur:crypto-psbt/local-response');
    saveLocal(local);
    final imported =
        bundle(_record(response: 'ur:crypto-psbt/local-response'));

    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);
    await service.importBitcoinRecord(imported, imported.bitcoinRecords.single);

    final saved = jsonDecode(file.readAsStringSync()) as Map;
    expect(saved['response_ur'], local['response_ur']);
    expect(saved['state'], 'confirmed');
    expect(saved['history'], [_archived()]);
  });

  test('export preserves paired EVM history across every account network',
      () async {
    await history.save(_evmRecord('55' * 16));
    await history.save(_evmRecord('66' * 16, chainId: 11155111));
    await history.save(_evmRecord('77' * 16,
        account: '0x1111111111111111111111111111111111111111'));
    final source = File(history.pathOverride!).readAsBytesSync();

    final preview = await service.prepareExport(
        const AccountSnapshot(
            accounts: [_evmAccount, _sepoliaEvmAccount], chainId: 31337));

    final decoded = PublicBackupCodec.decode(preview.backupJson);
    expect(decoded.chainId, 31337,
        reason: 'The selected UI network remains independent metadata');
    expect(decoded.accounts.map((account) => account.chainId),
        [31337, 11155111]);
    expect(decoded.transactions.map((row) => row['requestId']),
        unorderedEquals(['55' * 16, '66' * 16]));
    expect(preview.includedAccountCount, 2);
    expect(preview.includedEvmTransactionCount, 2);
    expect(preview.excludedEvmCount, 1);
    expect(preview.evmExclusionReasons, {'unpaired_account': 1});
    expect(preview.includedBitcoinRecordCount, 0);
    expect(preview.excludedBitcoinRecordCount, 0);
    expect(File(history.pathOverride!).readAsBytesSync(), source);
  });

  test('mixed-case imported EVM identity is normalized and remains idempotent',
      () async {
    final mixed = _evmRecord('88' * 16,
        account: '0x9858EfFd232B4033e47D90003D41ec34EcaEda94');
    final imported = PublicBackupCodec.decode(PublicBackupCodec.encode(
      chainId: 31337,
      accounts: const [_evmAccount],
      transactions: [mixed],
      bitcoinRecords: const [],
    ));

    await service.importTransactions(imported);
    await service.importTransactions(imported);

    final records = await history.read();
    expect(records, hasLength(1));
    expect(records.single['account'], _evmAccount.address);
    expect(
        (await history.findPotentiallyExecutable(
                account: mixed['account'] as String, chainId: 31337))!
            ['requestId'],
        '88' * 16);
  });

  test('legacy mixed-case EVM history is normalized when read', () async {
    File(history.pathOverride!).writeAsStringSync(jsonEncode({
      'version': 1,
      'transactions': [
        _evmRecord('89' * 16,
            account: '0x9858EfFd232B4033e47D90003D41ec34EcaEda94')
      ]
    }));

    final records = await history.read();

    expect(records.single['account'], _evmAccount.address);
    expect(
        (await history.findPotentiallyExecutable(
                account: _evmAccount.address, chainId: 31337))!
            ['requestId'],
        '89' * 16);
  });

  test('legacy cross-chain history recovers only a native-validated binding',
      () async {
    await history.save(_evmRecord('99' * 16,
        account: '0x9858EfFd232B4033e47D90003D41ec34EcaEda94'));
    await history.save(_evmRecord('aa' * 16,
        account: '0x1111111111111111111111111111111111111111'));
    const legacy = AccountSnapshot(
        accounts: [_sepoliaEvmAccount],
        selectedIndex: 0,
        chainId: 31337);

    final recovered = await service.recoverLegacyEvmBindings(legacy);

    expect(recovered.accounts, hasLength(2));
    expect(recovered.accounts.map((account) => account.chainId),
        unorderedEquals([11155111, 31337]));
    expect(recovered.accounts.last.address, _evmAccount.address);
    final preview = await service.prepareExport(recovered);
    expect(preview.includedEvmTransactionCount, 1);
    expect(preview.excludedEvmCount, 1);
    expect(preview.evmExclusionReasons, {'unpaired_account': 1});
    final roundTrip = PublicBackupCodec.decode(preview.backupJson);
    expect(roundTrip.accounts.map((account) => account.chainId),
        unorderedEquals([11155111, 31337]));
    expect(roundTrip.transactions.single['requestId'], '99' * 16);
  });

  test('legacy duplicate chain address conflict blocks recovery and export',
      () async {
    final conflicting = _evmAccount.copyWith(
        masterFingerprint: 'aabbccdd',
        derivationPath: "m/44'/60'/1'/0/0",
        label: 'legacy conflict');
    final snapshot = AccountSnapshot(accounts: [_evmAccount, conflicting]);

    await expectLater(
        service.recoverLegacyEvmBindings(snapshot), throwsFormatException);
    await expectLater(service.prepareExport(snapshot), throwsFormatException);
  });

  test('EVM transaction binding fields are optional but verified when present',
      () async {
    final bound = {
      ..._evmRecord('bc' * 16),
      'derivationPath': _evmAccount.derivationPath,
      'masterFingerprint': _evmAccount.masterFingerprint,
      'compressedPublicKeyHex': _evmAccount.compressedPublicKeyHex,
    };
    final bundle = PublicBackupCodec.decode(PublicBackupCodec.encode(
        chainId: 31337,
        accounts: const [_evmAccount],
        transactions: [bound],
        bitcoinRecords: const []));
    await service.validate(bundle);

    final mismatched = PublicBackupCodec.decode(PublicBackupCodec.encode(
        chainId: 31337,
        accounts: const [_evmAccount],
        transactions: [
          {...bound, 'derivationPath': "m/44'/60'/1'/0/0"}
        ],
        bitcoinRecords: const []));
    await expectLater(service.validate(mismatched), throwsFormatException);
    await history.save({
      ...bound,
      'derivationPath': "m/44'/60'/1'/0/0",
    });
    const snapshot = AccountSnapshot(accounts: [_evmAccount]);
    await expectLater(service.prepareExport(snapshot), throwsFormatException);
    await expectLater(
        service.recoverLegacyEvmBindings(snapshot), throwsFormatException);

    expect(
        () => PublicBackupCodec.decode(PublicBackupCodec.encode(
            chainId: 31337,
            accounts: const [_evmAccount],
            transactions: [
              {..._evmRecord('cd' * 16), 'derivationPath': _evmAccount.derivationPath}
            ],
            bitcoinRecords: const [])),
        throwsFormatException);
  });

  test('validation binds each EVM record to its own chain account', () async {
    final imported = PublicBackupCodec.decode(PublicBackupCodec.encode(
      chainId: 31337,
      accounts: const [_evmAccount, _sepoliaEvmAccount],
      transactions: [
        _evmRecord('55' * 16),
        _evmRecord('66' * 16, chainId: 11155111),
      ],
      bitcoinRecords: const [],
    ));

    await service.validate(imported);

    final missingOwnChain = PublicBackupCodec.decode(PublicBackupCodec.encode(
      chainId: 31337,
      accounts: const [_evmAccount],
      transactions: [_evmRecord('66' * 16, chainId: 11155111)],
      bitcoinRecords: const [],
    ));
    await expectLater(service.validate(missingOwnChain), throwsFormatException);

    final duplicateBinding = PublicBackupCodec.decode(PublicBackupCodec.encode(
      chainId: 31337,
      accounts: [
        _evmAccount,
        _evmAccount.copyWith(label: 'conflicting duplicate'),
      ],
      transactions: const [],
      bitcoinRecords: const [],
    ));
    await expectLater(service.validate(duplicateBinding), throwsFormatException);
  });

  test('export preview counts unpaired BTC bundles and preserves their files',
      () async {
    saveLocal(_record(response: 'ur:crypto-psbt/public-response'));
    final orphan = File('${directory.path}/bitcoin_aabbccdd.json');
    orphan.writeAsStringSync(jsonEncode({
      'schema_version': 1,
      'account_address': 'bcrt1qprevious',
      'master_fingerprint': 'aabbccdd',
      'rpc_endpoint': 'http://127.0.0.1:18443/wallet/previous',
      'state': 'draft',
      'request': null,
      'built': null,
      'response_ur': null,
      'history': [_archived()],
    }));
    final currentBytes = file.readAsBytesSync();
    final orphanBytes = orphan.readAsBytesSync();

    final preview = await service.prepareExport(
        const AccountSnapshot(accounts: [_account], chainId: 31337));

    expect(preview.includedBitcoinRecordCount, 1);
    expect(preview.excludedBitcoinRecordCount, 1);
    expect(preview.bitcoinExclusionReasons, {'unpaired_account': 1});
    expect(preview.excludedEvmCount, 0);
    final decoded = PublicBackupCodec.decode(preview.backupJson);
    expect(decoded.bitcoinRecords.single['account_address'], _account.address);
    expect(file.readAsBytesSync(), currentBytes);
    expect(orphan.readAsBytesSync(), orphanBytes);
    expect(preview.backupJson, isNot(contains('rpc_endpoint')));
  });

  test('export refuses an unreadable BTC source instead of guessing its count',
      () async {
    Directory('${directory.path}/bitcoin_aabbccdd.json').createSync();

    await expectLater(
        service
            .prepareExport(const AccountSnapshot(accounts: [], chainId: 31337)),
        throwsFormatException);

    expect(Directory('${directory.path}/bitcoin_aabbccdd.json').existsSync(),
        isTrue);
  });
}
