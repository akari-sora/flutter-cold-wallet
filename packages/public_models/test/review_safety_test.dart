import 'package:public_models/public_models.dart';
import 'package:test/test.dart';

void main() {
  test(
      'EVM native raw signing digest bytes are retained exactly for replay binding',
      () {
    final json = <String, dynamic>{
      ..._nativeEvmReview(),
      'handle_id': 'handle',
      'chain_id': 31337,
      'policy_verdict': {
        'Approved': {'amount_display': '1 ETH'}
      },
      'raw_signing_digest': List.generate(32, (index) => index),
    };
    final review = PreparedReviewDto.fromJson(json);
    expect(review.signingDigestHex,
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    json['signing_digest'] = 'ff' * 32;
    expect(PreparedReviewDto.fromJson(json).signingDigestHex, isNull,
        reason:
            'Conflicting native digest representations must not match a cache');
    expect(PreparedReviewDto.fromJson(json).isSignable, isFalse);
  });

  for (final raw in <dynamic>[
    null,
    List.filled(31, 0),
    List.filled(33, 0),
    [...List.filled(31, 0), -1],
    [...List.filled(31, 0), 256],
    [...List.filled(31, 0), 1.0],
    [...List.filled(31, 0), '1'],
  ]) {
    test(
        'EVM malformed native digest cannot enable approval: ${raw.runtimeType}',
        () {
      final review = PreparedReviewDto.fromJson({
        ..._nativeEvmReview(),
        'handle_id': 'handle',
        'policy_verdict': {
          'Approved': {'amount_display': '1 ETH'}
        },
        'raw_signing_digest': raw,
      });
      expect(review.isSignable, isFalse);
      expect(review.signingDigestHex, isNull);
    });
  }
  test('EVM missing native digest cannot enable approval', () {
    final review = PreparedReviewDto.fromJson({
      ...(_nativeEvmReview()..remove('raw_signing_digest')),
      'handle_id': 'handle',
      'policy_verdict': {
        'Approved': {'amount_display': '1 ETH'}
      },
    });
    expect(review.isSignable, isFalse);
  });

  test('review retains signer and token contract independently from recipient',
      () {
    final review = PreparedReviewDto.fromJson({
      'handle_id': 'handle',
      'raw_signing_digest': List.filled(32, 17),
      'chain_id': 11155111,
      'signer_address': '0x1111111111111111111111111111111111111111',
      'policy_verdict': {
        'Approved': {'amount_display': '1 USDC'}
      },
      'intent': {
        'Erc20Transfer': {
          'recipient': '0x2222222222222222222222222222222222222222',
          'token_contract': '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
          'token_amount_raw': '1000000',
          'fee_cap_wei': '21000',
          'chain_id': 11155111,
        }
      },
      'transaction': {
        'type': 'Legacy EIP-155',
        'chain_id': '11155111',
        'nonce': '0',
        'gas_limit': '21000',
        'gas_price_wei': '1',
        'to': '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
        'value_wei': '0',
        'data_hex':
            '0xa9059cbb${'0' * 24}${'22' * 20}${BigInt.from(1000000).toRadixString(16).padLeft(64, '0')}',
        'access_list': <dynamic>[],
      },
    });
    expect(review.toJson()['signer_address'],
        '0x1111111111111111111111111111111111111111');
    expect(review.toJson()['token_contract'],
        '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238');
    expect(review.recipient, '0x2222222222222222222222222222222222222222');
  });

  for (final sample in [
    (
      type: 'Legacy EIP-155',
      feeWei: '39378675000000',
      feeEth: '0.000039378675',
      gas: '21000',
      price: '1875175000',
    ),
    (
      type: 'EIP-1559',
      feeWei: '12000000240000',
      feeEth: '0.00001200000024',
      gas: '12000',
      price: '1000000020',
    ),
  ]) {
    test('${sample.type} fee display preserves exact ETH and wei', () {
      final json = _nativeEvmReview();
      final transaction = json['transaction'] as Map;
      transaction['type'] = sample.type;
      transaction['gas_limit'] = sample.gas;
      if (sample.type == 'Legacy EIP-155') {
        transaction['gas_price_wei'] = sample.price;
      } else {
        transaction.remove('gas_price_wei');
        transaction['max_fee_per_gas_wei'] = sample.price;
        transaction['max_priority_fee_per_gas_wei'] = '20';
      }
      ((json['intent'] as Map)['NativeTransfer'] as Map)['fee_cap_wei'] =
          sample.feeWei;
      final review = PreparedReviewDto.fromJson(json);
      expect(review.isSignable, isTrue);
      expect(review.evmDetails!.maximumFeeWei, BigInt.parse(sample.feeWei));
      expect(review.feeCapWei, sample.feeWei);
      expect(review.formattedFeeCap,
          '${sample.feeEth} ETH (${sample.feeWei} wei)');
      expect(
          DecimalAmountParser.parseToBaseUnits(
              review.formattedFeeCap.split(' ').first,
              decimals: 18),
          BigInt.parse(sample.feeWei));
    });
  }

  test('Bitcoin review retains every native output and external total', () {
    final review = PreparedReviewDto.fromJson({
      'type': 'BITCOIN_PSBT',
      'status': 'SUCCESS',
      'handle_id': 'btc',
      'session_id': 'btc-session',
      'request_id': 'btc-request',
      'network': 'regtest',
      'signing_digest': 'ab' * 32,
      'psbt_summary': {
        'total_input_sat': 3600,
        'total_output_sat': 3500,
        'destinations': [
          {'address': 'bcrt1first', 'amount_sat': 1000, 'is_change': false},
          {'address': 'bcrt1second', 'amount_sat': 2000, 'is_change': false}
        ],
        'changes': [
          {'address': 'bcrt1change', 'amount_sat': 500, 'is_change': true}
        ],
        'fee_sat': 100,
        'inputs_count': 2,
      },
    });
    expect(review.toJson()['btc_outputs'], hasLength(3));
    expect(review.isSignable, isTrue);
    expect(review.rawAmount, '3000');
    expect(review.displayAmount, '0.00003 BTC (3000 sats)');
    expect(review.btcOutputs.map((output) => output.valueSats),
        ['1000', '2000', '500']);
    expect(review.derivationPath, "m/84'/1'/0'");
  });

  test('actual top-level native PSBT fields exclude change from amount', () {
    final review = PreparedReviewDto.fromJson(_nativeBitcoinReview());
    expect(review.isSignable, isTrue);
    expect(review.rawAmount, '1000000');
    expect(review.displayAmount, '0.01 BTC (1000000 sats)');
    expect(review.btcInputsCount, 1);
    expect(review.btcChangeAmountSats, '98999000');
    expect(review.feeCapWei, '1000');
    expect(review.formattedFeeCap, '1000 sats (0.00001 BTC)');
    expect(review.btcOutputs.first.toJson()['amount_sat'], '1000000');
    expect(review.btcOutputs.last.toJson()['is_change'], isTrue);
  });

  for (final field in [
    'status',
    'network',
    'handle_id',
    'session_id',
    'request_id',
    'signing_digest'
  ]) {
    test('Bitcoin rejects missing binding or network $field', () {
      _expectRejectedBitcoin(_nativeBitcoinReview()..remove(field));
    });
  }
  for (final network in ['mainnet', 'testnet', 'bcrt', '', null]) {
    test('Bitcoin rejects unsupported or absent network $network', () {
      _expectRejectedBitcoin(_nativeBitcoinReview()..['network'] = network);
    });
  }

  for (final field in [
    'total_input_sat',
    'total_output_sat',
    'fee_sat',
    'inputs_count',
    'destinations',
    'changes'
  ]) {
    for (final missing in [true, false]) {
      test('Bitcoin rejects ${missing ? 'missing' : 'null'} $field', () {
        final json = _nativeBitcoinReview();
        if (missing) {
          json.remove(field);
        } else {
          json[field] = null;
        }
        _expectRejectedBitcoin(json);
      });
    }
  }

  for (final value in <dynamic>[
    -1,
    1.5,
    1000.0,
    true,
    '',
    ' 1000',
    '01000',
    '+1000',
    '1e3',
    '1000.0',
    'null',
    '18446744073709551616',
  ]) {
    test('Bitcoin rejects noncanonical fee ${value.runtimeType}: $value', () {
      _expectRejectedBitcoin(_nativeBitcoinReview()..['fee_sat'] = value);
    });
    test('Bitcoin rejects noncanonical output ${value.runtimeType}: $value',
        () {
      final json = _nativeBitcoinReview();
      (json['destinations'] as List).first['amount_sat'] = value;
      _expectRejectedBitcoin(json);
    });
  }

  test('Bitcoin accepts canonical exact decimal strings', () {
    final json = _nativeBitcoinReview();
    for (final field in [
      'total_input_sat',
      'total_output_sat',
      'fee_sat',
      'inputs_count'
    ]) {
      json[field] = json[field].toString();
    }
    (json['destinations'] as List).first['amount_sat'] = '1000000';
    (json['changes'] as List).first['amount_sat'] = '98999000';
    final review = PreparedReviewDto.fromJson(json);
    expect(review.isSignable, isTrue);
    expect(review.rawAmount, '1000000');
    expect(review.btcInputsCount, 1);
  });

  for (final invalid in [
    'missing-amount',
    'value-sat-alias',
    'missing-change-flag',
    'wrong-change-flag',
    'empty-address',
    'null-output',
    'input-sum',
    'output-sum',
    'zero-inputs',
    'oversized-inputs',
    'malformed-list',
    'money-supply-overflow',
    'recipient-total',
    'bad-digest',
  ]) {
    test('Bitcoin fails closed for $invalid', () {
      final json = _nativeBitcoinReview();
      final destination = (json['destinations'] as List).first as Map;
      switch (invalid) {
        case 'missing-amount':
          destination.remove('amount_sat');
        case 'value-sat-alias':
          destination['value_sat'] = destination.remove('amount_sat');
        case 'missing-change-flag':
          destination.remove('is_change');
        case 'wrong-change-flag':
          destination['is_change'] = true;
        case 'empty-address':
          destination['address'] = '';
        case 'null-output':
          json['destinations'] = [null];
        case 'input-sum':
          json['total_input_sat'] = 100000001;
        case 'output-sum':
          json['total_output_sat'] = 99999001;
        case 'zero-inputs':
          json['inputs_count'] = 0;
        case 'oversized-inputs':
          json['inputs_count'] = '4294967296';
        case 'malformed-list':
          json['changes'] = {};
        case 'money-supply-overflow':
          json['total_input_sat'] = '2100000000000001';
        case 'recipient-total':
          json['recipient_amount_sats'] = '99999000';
        case 'bad-digest':
          json['signing_digest'] = 'not-a-digest';
      }
      _expectRejectedBitcoin(json);
    });
  }

  test('decimal amounts reject uint256 overflow and oversized input', () {
    final max = (BigInt.one << 256) - BigInt.one;
    expect(
        DecimalAmountParser.parseToBaseUnits(max.toString(), decimals: 0), max);
    expect(
        () => DecimalAmountParser.parseToBaseUnits(
            (max + BigInt.one).toString(),
            decimals: 0),
        throwsA(isA<AmountParseException>()));
    expect(
        () => DecimalAmountParser.parseToBaseUnits('0' * 10000 + '1',
            decimals: 0),
        throwsA(isA<AmountParseException>()));
  });
}

Map<String, dynamic> _nativeEvmReview() => {
      'handle_id': 'handle',
      'chain_id': 31337,
      'policy_verdict': {
        'Approved': {'amount_display': '1 ETH'}
      },
      'raw_signing_digest': List.filled(32, 17),
      'intent': {
        'NativeTransfer': {
          'chain_id': 31337,
          'recipient': '0x${'22' * 20}',
          'value_wei': '1000000000000000000',
          'fee_cap_wei': '21000',
        }
      },
      'transaction': {
        'type': 'Legacy EIP-155',
        'chain_id': '31337',
        'nonce': '0',
        'gas_limit': '21000',
        'gas_price_wei': '1',
        'to': '0x${'22' * 20}',
        'value_wei': '1000000000000000000',
        'data_hex': '0x',
        'access_list': <dynamic>[],
      },
    };

Map<String, dynamic> _nativeBitcoinReview() => {
      'status': 'SUCCESS',
      'type': 'BITCOIN_PSBT',
      'handle_id': 'h_psbt_1',
      'session_id': 'physical-regtest-session',
      'request_id': 'psbt_req_1',
      'network': 'regtest',
      'signing_digest': 'ab' * 32,
      'total_input_sat': 100000000,
      'total_output_sat': 99999000,
      'fee_sat': 1000,
      'inputs_count': 1,
      'recipient_amount_sats': 1000000,
      'destinations': [
        {
          'address': 'bcrt1destination',
          'amount_sat': 1000000,
          'is_change': false
        }
      ],
      'changes': [
        {'address': 'bcrt1change', 'amount_sat': 98999000, 'is_change': true}
      ],
    };

void _expectRejectedBitcoin(Map<String, dynamic> json) {
  final review = PreparedReviewDto.fromJson(json);
  expect(review.isSignable, isFalse);
  expect(review.verdict, ReviewVerdictType.rejected);
  expect(review.rejectionReason, isNotEmpty);
  expect(review.rawAmount, isEmpty,
      reason: 'No invented amount on parse failure');
  expect(review.btcOutputs, isEmpty);
}
