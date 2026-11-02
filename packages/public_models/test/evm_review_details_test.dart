import 'package:public_models/public_models.dart';
import 'package:test/test.dart';

const _recipient = '0x2222222222222222222222222222222222222222';
const _contract = '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238';

Map<String, dynamic> _transaction({bool typed = false}) => {
      'type': typed ? 'EIP-1559' : 'Legacy EIP-155',
      'chain_id': '11155111',
      'nonce': '362',
      'gas_limit': '12000',
      if (typed) ...{
        'max_fee_per_gas_wei': '2000000000',
        'max_priority_fee_per_gas_wei': '1000000000',
      } else
        'gas_price_wei': '2000000000',
      'to': _recipient,
      'value_wei': '1000000000000',
      'data_hex': '0x',
      'access_list': <dynamic>[],
    };

Map<String, dynamic> _review({bool typed = false, bool token = false}) => {
      'handle_id': 'native-handle',
      'session_id': 'native-session',
      'request_id': 'native-request',
      'chain_id': 11155111,
      'signer_address': _recipient,
      'derivation_path': "m/44'/60'/0'/0/0",
      'raw_signing_digest': List.filled(32, 17),
      'policy_verdict': {
        'Approved': {'amount_display': token ? '1 USDC' : '0.000001 ETH'}
      },
      'intent': {
        if (token)
          'Erc20Transfer': {
            'chain_id': 11155111,
            'recipient': _recipient,
            'token_contract': _contract,
            'token_amount_raw': '1000000',
            'fee_cap_wei': '24000000000000',
          }
        else
          'NativeTransfer': {
            'chain_id': 11155111,
            'recipient': _recipient,
            'value_wei': '1000000000000',
            'fee_cap_wei': '24000000000000',
          },
      },
      'transaction': token
          ? (_transaction(typed: typed)
            ..['to'] = _contract
            ..['value_wei'] = '0'
            ..['data_hex'] =
                '0xa9059cbb${'0' * 24}${_recipient.substring(2)}${BigInt.from(1000000).toRadixString(16).padLeft(64, '0')}')
          : _transaction(typed: typed),
    };

void _expectRejected(Map<String, dynamic> json) {
  final review = PreparedReviewDto.fromJson(json);
  expect(review.isSignable, isFalse);
  expect(review.rejectionReason, isNotEmpty);
}

void main() {
  for (final typed in [false, true]) {
    test('complete ${typed ? 'Type 2' : 'Legacy'} review remains signable', () {
      expect(
          PreparedReviewDto.fromJson(_review(typed: typed)).isSignable, isTrue);
    });

    test('approved ${typed ? 'Type 2' : 'Legacy'} requires transaction details',
        () {
      _expectRejected(_review(typed: typed)..remove('transaction'));
    });

    for (final field in [
      'type',
      'chain_id',
      'nonce',
      'gas_limit',
      'to',
      'value_wei',
      'data_hex',
      'access_list',
      if (typed) ...[
        'max_fee_per_gas_wei',
        'max_priority_fee_per_gas_wei',
      ] else
        'gas_price_wei',
    ]) {
      test('${typed ? 'Type 2' : 'Legacy'} rejects missing $field', () {
        final json = _review(typed: typed);
        (json['transaction'] as Map).remove(field);
        _expectRejected(json);
      });
    }

    for (final field in [
      'chain_id',
      'nonce',
      'gas_limit',
      'value_wei',
      if (typed) ...[
        'max_fee_per_gas_wei',
        'max_priority_fee_per_gas_wei',
      ] else
        'gas_price_wei',
    ]) {
      for (final invalid in <dynamic>[
        null,
        1,
        1.0,
        true,
        '',
        '-1',
        '+1',
        '01',
        ' 1',
        '1e3',
        '1.0',
        (BigInt.one << 256).toString(),
      ]) {
        test('${typed ? 'Type 2' : 'Legacy'} rejects $field = $invalid', () {
          final json = _review(typed: typed);
          (json['transaction'] as Map)[field] = invalid;
          _expectRejected(json);
        });
      }
    }
  }

  for (final mutation in [
    'zero-gas',
    'wrong-chain',
    'wrong-envelope-chain',
    'wrong-intent-chain',
    'wrong-recipient',
    'wrong-value',
    'wrong-cap',
    'priority-exceeds-max',
    'mixed-fee-fields',
    'unsupported-type',
    'odd-data',
    'missing-data-prefix',
    'invalid-data',
    'null-access-list',
    'invalid-access-address',
    'invalid-storage-key',
    'missing-storage-keys',
    'legacy-access-list',
    'erc20-native-value',
    'erc20-wrong-contract',
  ]) {
    test('review fails closed for $mutation', () {
      final isToken = mutation.startsWith('erc20-');
      final json =
          _review(typed: mutation != 'legacy-access-list', token: isToken);
      final tx = json['transaction'] as Map;
      switch (mutation) {
        case 'zero-gas':
          tx['gas_limit'] = '0';
        case 'wrong-chain':
          tx['chain_id'] = '31337';
        case 'wrong-envelope-chain':
          json['chain_id'] = '11155111';
        case 'wrong-intent-chain':
          (json['intent'] as Map)['NativeTransfer']['chain_id'] = 31337;
        case 'wrong-recipient':
          tx['to'] = _contract;
        case 'wrong-value':
          tx['value_wei'] = '1';
        case 'wrong-cap':
          (json['intent'] as Map)['NativeTransfer']['fee_cap_wei'] = '1';
        case 'priority-exceeds-max':
          tx['max_priority_fee_per_gas_wei'] = '2000000001';
        case 'mixed-fee-fields':
          tx['gas_price_wei'] = '1';
        case 'unsupported-type':
          tx['type'] = 'EIP-7702';
        case 'odd-data':
          tx['data_hex'] = '0xabc';
        case 'missing-data-prefix':
          tx['data_hex'] = 'aabb';
        case 'invalid-data':
          tx['data_hex'] = '0xgg';
        case 'null-access-list':
          tx['access_list'] = null;
        case 'invalid-access-address':
          tx['access_list'] = [
            {'address': '0x1234', 'storage_keys': <String>[]}
          ];
        case 'invalid-storage-key':
          tx['access_list'] = [
            {
              'address': _recipient,
              'storage_keys': ['0x12']
            }
          ];
        case 'missing-storage-keys':
          tx['access_list'] = [
            {'address': _recipient}
          ];
        case 'legacy-access-list':
          tx['access_list'] = [
            {'address': _recipient, 'storage_keys': <String>[]}
          ];
        case 'erc20-native-value':
          tx['value_wei'] = '1';
        case 'erc20-wrong-contract':
          tx['to'] = _recipient;
      }
      _expectRejected(json);
    });
  }

  test('direct constructor cannot bypass missing review transaction details',
      () {
    const review = PreparedReviewDto(
      handleId: 'handle',
      sessionId: 'session',
      requestId: 'request',
      chainId: 11155111,
      recipient: _recipient,
      rawAmount: '1',
      displayAmount: '0.000000000000000001 ETH',
      tokenSymbol: 'ETH',
      decimals: 18,
      feeCapWei: '24000000000000',
      verdict: ReviewVerdictType.approved,
    );
    expect(review.isSignable, isFalse);
  });

  test('access list and storage keys are detached and deeply immutable', () {
    final json = _review(typed: true);
    final transaction = json['transaction'] as Map<String, dynamic>;
    final keys = ['0x${'12' * 32}', '0x${'34' * 32}'];
    final entries = [
      {'address': _recipient, 'storage_keys': keys}
    ];
    transaction['access_list'] = entries;
    final review = PreparedReviewDto.fromJson(json);
    expect(review.isSignable, isTrue);
    final details = review.evmDetails!;
    expect(details.toJson(), transaction);
    keys.clear();
    entries.clear();
    expect(details.accessList, hasLength(1));
    expect(details.accessList.single.storageKeys,
        ['0x${'12' * 32}', '0x${'34' * 32}']);
    expect(() => details.accessList.clear(), throwsUnsupportedError);
    expect(() => details.accessList.single.storageKeys.clear(),
        throwsUnsupportedError);
    final exported = details.toJson();
    (exported['access_list'] as List).clear();
    expect(details.accessList, hasLength(1));
  });

  test('complete ERC-20 details preserve zero native value and full call data',
      () {
    final json = _review(typed: true, token: true);
    final review = PreparedReviewDto.fromJson(json);
    expect(review.isSignable, isTrue);
    expect(review.evmDetails!.valueWei, '0');
    expect(review.evmDetails!.to, _contract);
    expect(
        review.evmDetails!.dataHex, (json['transaction'] as Map)['data_hex']);
  });

  test('fee multiplication and native value stay exact beyond double precision',
      () {
    final json = _review();
    final transaction = json['transaction'] as Map;
    final maximum64 = ((BigInt.one << 64) - BigInt.one).toString();
    final maximum256 = ((BigInt.one << 256) - BigInt.one).toString();
    transaction['nonce'] = maximum64;
    transaction['gas_limit'] = maximum64;
    transaction['gas_price_wei'] = maximum64;
    transaction['value_wei'] = maximum256;
    final intent = (json['intent'] as Map)['NativeTransfer'] as Map;
    intent['value_wei'] = maximum256;
    final exactFee = BigInt.parse(maximum64) * BigInt.parse(maximum64);
    intent['fee_cap_wei'] = exactFee.toString();
    final review = PreparedReviewDto.fromJson(json);
    expect(review.isSignable, isTrue);
    expect(review.evmDetails!.maximumFeeWei, exactFee);
    expect(review.rawAmount, maximum256);
  });

  test('zero nonce, value and fee remain valid exact nonnegative integers', () {
    final json = _review();
    final transaction = json['transaction'] as Map;
    transaction['nonce'] = '0';
    transaction['gas_price_wei'] = '0';
    transaction['value_wei'] = '0';
    final intent = (json['intent'] as Map)['NativeTransfer'] as Map;
    intent['fee_cap_wei'] = '0';
    intent['value_wei'] = '0';
    expect(PreparedReviewDto.fromJson(json).isSignable, isTrue);
  });

  for (final mismatch in ['chain', 'recipient', 'amount', 'fee']) {
    test('direct constructor cannot bypass inconsistent $mismatch', () {
      final review = PreparedReviewDto(
        handleId: 'handle',
        sessionId: 'session',
        requestId: 'request',
        chainId: mismatch == 'chain' ? 31337 : 11155111,
        recipient: mismatch == 'recipient' ? _contract : _recipient,
        rawAmount: mismatch == 'amount' ? '1' : '1000000000000',
        displayAmount: '0.000001 ETH',
        tokenSymbol: 'ETH',
        decimals: 18,
        feeCapWei: mismatch == 'fee' ? '1' : '24000000000000',
        verdict: ReviewVerdictType.approved,
        evmDetails: EvmReviewDetails.fromJson(_transaction()),
      );
      expect(review.isSignable, isFalse);
      expect(review.evmValidationError, isNotEmpty);
    });
  }
}
