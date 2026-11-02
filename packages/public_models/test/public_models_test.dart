import 'package:public_models/public_models.dart';
import 'package:test/test.dart';

void main() {
  group('public_models test suite', () {
    test('AccountDescriptor roundtrip and copyWith', () {
      const desc = AccountDescriptor(
        masterFingerprint: '73c5da0a',
        derivationPath: "m/44'/60'/0'/0/0",
        address: '0x9858EfFD232B4033E47d90003D41EC34EcaEda94',
        chainId: 11155111,
        label: 'Sepolia Cold 1',
        compressedPublicKeyHex:
            '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      );

      final json = desc.toJson();
      final recovered = AccountDescriptor.fromJson(json);

      expect(recovered.masterFingerprint, '73c5da0a');
      expect(recovered.derivationPath, "m/44'/60'/0'/0/0");
      expect(recovered.address, '0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
      expect(recovered.chainId, 11155111);
      expect(recovered.label, 'Sepolia Cold 1');
      expect(
        recovered.compressedPublicKeyHex,
        '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      );

      final renamed = recovered.copyWith(label: 'Renamed Vault #0');
      expect(renamed.label, 'Renamed Vault #0');
      expect(renamed.address, recovered.address);
    });

    test('DecimalAmountParser exact BigInt parsing without double', () {
      // ETH 18 decimals
      expect(
        DecimalAmountParser.parseToBaseUnits('1', decimals: 18),
        BigInt.parse('1000000000000000000'),
      );
      expect(
        DecimalAmountParser.parseToBaseUnits('0.1', decimals: 18),
        BigInt.parse('100000000000000000'),
      );
      expect(
        DecimalAmountParser.parseToBaseUnits(
          '0.123456789123456789',
          decimals: 18,
        ),
        BigInt.parse('123456789123456789'),
      );

      // USDC 6 decimals
      expect(
        DecimalAmountParser.parseToBaseUnits('100.5', decimals: 6),
        BigInt.parse('100500000'),
      );
      expect(
        DecimalAmountParser.parseToBaseUnits('0.000001', decimals: 6),
        BigInt.one,
      );

      // Formatting roundtrip
      expect(
        DecimalAmountParser.formatBaseUnits(
          BigInt.parse('100500000'),
          decimals: 6,
        ),
        '100.5',
      );
      expect(
        DecimalAmountParser.formatBaseUnits(
          BigInt.parse('100000000000000000'),
          decimals: 18,
        ),
        '0.1',
      );
    });

    test(
        'DecimalAmountParser rejects invalid, negative, zero, and excess precision',
        () {
      expect(
        () => DecimalAmountParser.parseToBaseUnits('', decimals: 18),
        throwsA(isA<AmountParseException>()),
      );
      expect(
        () => DecimalAmountParser.parseToBaseUnits('-0.5', decimals: 18),
        throwsA(isA<AmountParseException>()),
      );
      expect(
        () => DecimalAmountParser.parseToBaseUnits('0', decimals: 18),
        throwsA(isA<AmountParseException>()),
      );
      expect(
        () => DecimalAmountParser.parseToBaseUnits('0.000000', decimals: 6),
        throwsA(isA<AmountParseException>()),
      );
      expect(
        () => DecimalAmountParser.parseToBaseUnits('1e-5', decimals: 18),
        throwsA(isA<AmountParseException>()),
      );
      expect(
        () => DecimalAmountParser.parseToBaseUnits('1.1234567', decimals: 6),
        throwsA(isA<AmountParseException>()),
      );
    });

    test('PreparedReviewDto parses approved ERC-20 transfer', () {
      final json = {
        'handle_id': 'handle-1-req_test',
        'session_id': 'sess_1',
        'request_id': 'req_test',
        'raw_signing_digest': List.filled(32, 17),
        'chain_id': 11155111,
        'account_address': '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        'policy_verdict': {
          'Approved': {
            'amount_display': '100.5 USDC',
            'chain_id': 11155111,
            'fee_cap_wei': '210000000000000',
            'recipient': '0x9858effd232b4033e47d90003d41ec34ecaeda94',
          }
        },
        'intent': {
          'Erc20Transfer': {
            'chain_id': 11155111,
            'token_contract': '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
            'recipient': '0x9858effd232b4033e47d90003d41ec34ecaeda94',
            'token_amount_raw': '100500000',
            'fee_cap_wei': '210000000000000',
          }
        },
        'transaction': {
          'type': 'Legacy EIP-155',
          'chain_id': '11155111',
          'nonce': '0',
          'gas_limit': '70000',
          'gas_price_wei': '3000000000',
          'to': '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
          'value_wei': '0',
          'data_hex':
              '0xa9059cbb${'0' * 24}9858effd232b4033e47d90003d41ec34ecaeda94${BigInt.from(100500000).toRadixString(16).padLeft(64, '0')}',
          'access_list': <dynamic>[],
        },
      };

      final dto = PreparedReviewDto.fromJson(json);
      expect(dto.isSignable, isTrue);
      expect(dto.tokenSymbol, 'USDC');
      expect(dto.decimals, 6);
      expect(dto.displayAmount, '100.5 USDC');
      expect(dto.rawAmount, '100500000');
    });

    test('PreparedReviewDto parses rejected unknown contract (EVM-09)', () {
      final json = {
        'error':
            'Token contract 0xdeadbeef is not in the approved whitelist (EVM-09 Fail-Closed)'
      };

      final dto = PreparedReviewDto.fromJson(json);
      expect(dto.isSignable, isFalse);
      expect(dto.verdict, ReviewVerdictType.rejected);
      expect(dto.rejectionReason, contains('EVM-09 Fail-Closed'));
    });

    test('SignatureResultDto parses 65-byte hex signature and real UR frames',
        () {
      final r = '11' * 32;
      final s = '22' * 32;
      const v = '1b';
      final sigHex = '0x$r$s$v';

      final json = {
        'status': 'SUCCESS',
        'handle_id': 'handle-1-req',
        'address': '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        'signature': sigHex,
        'signature_ur': 'ur:eth-signature/oyad...',
        'signature_ur_frames': ['ur:eth-signature/oyad...'],
      };

      final res = SignatureResultDto.fromJson(json);
      expect(res.isSuccess, isTrue);
      expect(res.rHex, r);
      expect(res.sHex, s);
      expect(res.v, 27);
      expect(res.qrFrames, ['ur:eth-signature/oyad...']);
    });
  });
}
