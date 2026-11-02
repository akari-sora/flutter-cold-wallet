import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/services/public_signed_result_store.dart';

final _identity = PublicVaultIdentity('1234abcd', '02${'12' * 32}');

PreparedReviewDto _review(
        {int index = 1,
        String handle = 'handle',
        String session = 'session',
        String? digest}) =>
    PreparedReviewDto(
      handleId: handle,
      sessionId: session,
      requestId: 'request-$index',
      chainId: 31337,
      recipient: '0x${'22' * 20}',
      signerAddress: '0x${'11' * 20}',
      rawAmount: '1000',
      displayAmount: '0.000000000000001 ETH',
      tokenSymbol: 'ETH',
      decimals: 18,
      feeCapWei: '21000',
      verdict: ReviewVerdictType.approved,
      derivationPath: "m/44'/60'/0'/0/0",
      signingDigestHex: digest ?? index.toRadixString(16).padLeft(64, '0'),
      evmDetails: EvmReviewDetails.fromJson({
        'type': 'Legacy EIP-155',
        'chain_id': '31337',
        'nonce': '0',
        'gas_limit': '21000',
        'gas_price_wei': '1',
        'to': '0x${'22' * 20}',
        'value_wei': '1000',
        'data_hex': '0x',
        'access_list': <dynamic>[],
      }),
    );

SignatureResultDto _result() => SignatureResultDto(
        status: 'SUCCESS',
        handleId: 'handle',
        address: '0x${'11' * 20}',
        signatureHex: '0x${'34' * 64}1b',
        signatureUr: 'ur:eth-signature/public-fixture',
        signatureUrFrames: const [
          'ur:eth-signature/1-2/public-fixture',
          'ur:eth-signature/2-2/public-fixture'
        ]);

void main() {
  late Directory directory;
  late String path;
  late PublicSignedResultStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('fcw_public_store_');
    path = '${directory.path}/public_results.json';
    store = PublicSignedResultStore(path)..load();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
      'atomic public result reload excludes secrets and ephemeral native handles',
      () {
    expect(store.activate(_identity), isNull);
    expect(store.reserve(_identity, _review()), isNull);
    expect(store.complete(_identity, _review(), _result()), isNull);
    final saved = File(path).readAsStringSync();
    for (final forbidden in [
      'mnemonic',
      'seed',
      'password',
      'handle_id',
      'session_id'
    ]) {
      expect(saved.contains(forbidden), isFalse);
    }
    expect(File('$path.tmp').existsSync(), isFalse);
    final reloaded = PublicSignedResultStore(path)..load();
    final replay = reloaded.lookup(
        _identity, _review(handle: 'new-handle', session: 'new-session'));
    expect(replay.kind, PublicResultLookupKind.available);
    expect(replay.result!.handleId, isEmpty);
    expect(replay.result!.qrFrames, _result().qrFrames);
    expect(() => replay.result!.signatureUrFrames.add('modified'),
        throwsUnsupportedError);
  });

  test('real native sign is retained for read-only locked reload', () {
    final ffi = VaultFfiService();
    expect(ffi.init(), 0);
    expect(ffi.lock(), isTrue);
    addTearDown(ffi.lock);
    final generated = ffi.generateMnemonic(12);
    if (generated['status'] != 'SUCCESS') {
      throw StateError('Test key generation failed');
    }
    final activated = ffi.activateAndSaveMnemonic(
        phrase: generated['mnemonic'],
        storagePath: '${directory.path}/vault.json',
        pinPassword: 'Disposable-public-cache-native-test-2026!');
    expect(activated['status'], 'SUCCESS');
    final identity = PublicVaultIdentity.fromAccounts(
        activated['master_fingerprint'], activated['multi_accounts']);
    final review = ffi.prepareLegacyTx(
        sessionId: 'public-cache-session',
        requestId: '00112233445566778899aabbccddeeff',
        declaredChainId: 11155111,
        rawRlpHex:
            'ef808504a817c800825208949858effd232b4033e47d90003d41ec34ecaeda9488016345785d8a00008083aa36a78080');
    expect(review.isSignable, isTrue);
    expect(store.activate(identity), isNull);
    expect(store.reserve(identity, review), isNull);
    final result = ffi.approveAndSignResult(review.handleId);
    expect(result.isSuccess, isTrue);
    expect(store.complete(identity, review, result), isNull);
    expect(
        ffi.getRequestState(review.handleId)['primitive_sign_invocations'], 1);
    expect(ffi.lock(), isTrue);
    final reloaded = PublicSignedResultStore(path)..load();
    expect(reloaded.lookup(identity, review).result!.qrFrames, result.qrFrames);
    expect(ffi.exportMultiAccounts()['status'], 'ERROR');
    expect(ffi.getRequestState(review.handleId)['sign_command_count'], 1);
  });

  test('different full identity or digest cannot replay an old result', () {
    store.activate(_identity);
    store.reserve(_identity, _review());
    store.complete(_identity, _review(), _result());
    expect(
        store
            .lookup(
                PublicVaultIdentity('1234abcd', '03${'45' * 32}'), _review())
            .kind,
        PublicResultLookupKind.newRequest);
    expect(store.lookup(_identity, _review(digest: 'ff' * 32)).kind,
        PublicResultLookupKind.newRequest);
  });

  test('native-shaped Bitcoin SUCCESS response survives locked public reload',
      () {
    final review = PreparedReviewDto.fromJson({
      'status': 'SUCCESS',
      'type': 'BITCOIN_PSBT',
      'handle_id': 'psbt-handle',
      'session_id': 'psbt-session',
      'request_id': 'psbt-${'ab' * 32}',
      'network': 'regtest',
      'signing_digest': 'ab' * 32,
      'total_input_sat': 100000,
      'total_output_sat': 99000,
      'fee_sat': 1000,
      'inputs_count': 1,
      'destinations': [
        {'address': 'bcrt1recipient', 'amount_sat': 10000, 'is_change': false}
      ],
      'changes': [
        {'address': 'bcrt1change', 'amount_sat': 89000, 'is_change': true}
      ],
    });
    const response = SignatureResultDto(
        status: 'SUCCESS',
        handleId: 'psbt-handle',
        address: '',
        signatureHex: '',
        signedPsbtHex: '70736274ff',
        signedPsbtUr: 'ur:crypto-psbt/public-psbt-fixture',
        signedPsbtUrFrames: [
          'ur:crypto-psbt/1-2/public-fixture',
          'ur:crypto-psbt/2-2/public-fixture'
        ]);
    expect(review.isSignable, isTrue);
    store.activate(_identity);
    expect(store.reserve(_identity, review), isNull);
    expect(store.complete(_identity, review, response), isNull);
    final reloaded = PublicSignedResultStore(path)..load();
    final cached = reloaded.lookup(_identity, review);
    expect(cached.kind, PublicResultLookupKind.available);
    expect(cached.result!.isPsbt, isTrue);
    expect(cached.result!.signedPsbtHex, response.signedPsbtHex);
    expect(cached.result!.qrFrames, response.qrFrames);
  });

  test('missing cache is empty and corrupt cache blocks approval truthfully',
      () {
    expect(store.resultsFor(_identity), isEmpty);
    expect(store.lookup(_identity, _review()).kind,
        PublicResultLookupKind.newRequest);
    File(path).writeAsStringSync('{corrupt');
    store.load();
    expect(store.error, contains('損毀'));
    expect(store.lookup(_identity, _review()).kind,
        PublicResultLookupKind.blocked);
    expect(store.reserve(_identity, _review()), isNotNull);
    expect(File(path).readAsStringSync(), '{corrupt');
  });

  test('interrupted reserved signing remains known unavailable after restart',
      () {
    store.activate(_identity);
    store.reserve(_identity, _review());
    final reloaded = PublicSignedResultStore(path)..load();
    expect(reloaded.lookup(_identity, _review()).kind,
        PublicResultLookupKind.unavailable);
    expect(reloaded.reserve(_identity, _review()), contains('請查原交易'));
    expect(reloaded.resultsFor(_identity), isEmpty);
    expect(reloaded.hasUnavailableFor(_identity), isTrue);
    expect(reloaded.lookup(_identity, _review()).error, contains('結果待查'));
  });

  test('response write failure retains public memory and durable reservation',
      () {
    store.activate(_identity);
    store.reserve(_identity, _review());
    Directory('$path.tmp').createSync();
    expect(store.complete(_identity, _review(), _result()), contains('寫入失敗'));
    expect(store.lookup(_identity, _review()).kind,
        PublicResultLookupKind.available);
    expect(store.resultsFor(_identity), hasLength(1));
    final reloaded = PublicSignedResultStore(path)..load();
    expect(reloaded.lookup(_identity, _review()).kind,
        PublicResultLookupKind.unavailable);
    expect(store.lookup(_identity, _review(index: 2)).kind,
        PublicResultLookupKind.blocked);
  });

  test('old bodies expire but their signing markers never become new requests',
      () {
    store.activate(_identity);
    for (var index = 1; index <= 21; index++) {
      expect(store.reserve(_identity, _review(index: index)), isNull);
      expect(
          store.complete(_identity, _review(index: index), _result()), isNull);
    }
    final reloaded = PublicSignedResultStore(path)..load();
    expect(reloaded.resultsFor(_identity), hasLength(20));
    expect(reloaded.lookup(_identity, _review(index: 1)).kind,
        PublicResultLookupKind.unavailable);
    expect(reloaded.lookup(_identity, _review(index: 1)).error,
        contains('已簽結果無法取回'));
    expect(reloaded.lookup(_identity, _review(index: 21)).kind,
        PublicResultLookupKind.available);
    expect((jsonDecode(File(path).readAsStringSync())['markers'] as List),
        hasLength(21));
  });

  test('full marker capacity refuses new signing without deleting old history',
      () {
    store.activate(_identity);
    for (var index = 1; index <= PublicSignedResultStore.maxMarkers; index++) {
      expect(store.reserve(_identity, _review(index: index)), isNull);
    }
    expect(store.lookup(_identity, _review(index: 129)).kind,
        PublicResultLookupKind.blocked);
    expect(store.reserve(_identity, _review(index: 129)), contains('上限'));
    final reloaded = PublicSignedResultStore(path)..load();
    expect(reloaded.lookup(_identity, _review()).kind,
        PublicResultLookupKind.unavailable);
    expect((jsonDecode(File(path).readAsStringSync())['markers'] as List),
        hasLength(128));
  });

  test('oversized response keeps durable marker and respects file byte limit',
      () {
    store.activate(_identity);
    store.reserve(_identity, _review());
    final huge = SignatureResultDto(
        status: 'SUCCESS',
        handleId: 'handle',
        address: '0x${'11' * 20}',
        signatureHex: '0x${'34' * 64}1b',
        signatureUr:
            'ur:eth-signature/${'a' * PublicSignedResultStore.maxBytes}',
        signatureUrFrames: _result().signatureUrFrames);
    expect(store.complete(_identity, _review(), huge), contains('寫入失敗'));
    expect(File(path).lengthSync(),
        lessThanOrEqualTo(PublicSignedResultStore.maxBytes));
    expect(store.lookup(_identity, _review()).kind,
        PublicResultLookupKind.available);
    final reloaded = PublicSignedResultStore(path)..load();
    expect(reloaded.lookup(_identity, _review()).kind,
        PublicResultLookupKind.unavailable);
  });

  test('unexpected secret-shaped fields invalidate a loaded public response',
      () {
    store.activate(_identity);
    store.reserve(_identity, _review());
    store.complete(_identity, _review(), _result());
    final json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    json['markers'][0]['result']['mnemonic'] = 'isolated-test-value';
    File(path).writeAsStringSync(jsonEncode(json));
    final reloaded = PublicSignedResultStore(path)..load();
    expect(reloaded.error, isNotNull);
    expect(reloaded.lookup(_identity, _review()).kind,
        PublicResultLookupKind.blocked);
  });
}
