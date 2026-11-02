import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/review_screen.dart';
import 'package:vault/screens/signed_result_screen.dart';

const _recipient = '0x2222222222222222222222222222222222222222';
const _signer = '0x1111111111111111111111111111111111111111';
const _contract = '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238';
const _path = "m/44'/60'/0'/0/0";
final _digest = 'ab' * 32;

PreparedReviewDto _evmReview({bool rejected = false}) => PreparedReviewDto(
      handleId: 'review-layout-handle',
      sessionId: 'review-layout-session',
      requestId: 'review-layout-original-request',
      chainId: 11155111,
      recipient: _recipient,
      signerAddress: _signer,
      tokenContract: _contract,
      rawAmount: '123456789',
      displayAmount: '123.456789',
      tokenSymbol: 'USDC',
      decimals: 6,
      feeCapWei: '42000000000000',
      verdict:
          rejected ? ReviewVerdictType.rejected : ReviewVerdictType.approved,
      rejectionReason: rejected ? '合約不在允許清單：EVM-09' : null,
      warnings: const ['此為測試網交易，請核對收款地址。'],
      derivationPath: _path,
      signingDigestHex: _digest,
      evmDetails: EvmReviewDetails.fromJson({
        'type': 'EIP-1559',
        'chain_id': '11155111',
        'nonce': '362',
        'gas_limit': '21000',
        'max_fee_per_gas_wei': '2000000000',
        'max_priority_fee_per_gas_wei': '1000000000',
        'to': _contract,
        'value_wei': '0',
        'data_hex':
            '0xa9059cbb${'0' * 24}${_recipient.substring(2)}${BigInt.from(123456789).toRadixString(16).padLeft(64, '0')}',
        'access_list': [
          {
            'address': _contract,
            'storage_keys': ['0x${'12' * 32}', '0x${'34' * 32}'],
          }
        ],
      }),
    );

PreparedReviewDto _bitcoinReview({bool incomplete = false}) =>
    PreparedReviewDto.fromJson({
      'status': 'SUCCESS',
      'type': 'BITCOIN_PSBT',
      'handle_id': 'bitcoin-layout-handle',
      'session_id': 'bitcoin-layout-session',
      'request_id': 'bitcoin-layout-original-request',
      'network': 'regtest',
      'signing_digest': _digest,
      'total_input_sat': 100000,
      'total_output_sat': 99000,
      if (!incomplete) 'fee_sat': 1000,
      'inputs_count': 2,
      'destinations': [
        {
          'address': 'bcrt1qrecipientfirstpubliclayoutfixture',
          'amount_sat': 10000,
          'is_change': false,
        },
        {
          'address': 'bcrt1qrecipientsecondpubliclayoutfixture',
          'amount_sat': 20000,
          'is_change': false,
        },
      ],
      'changes': [
        {
          'address': 'bcrt1qchangepubliclayoutfixture',
          'amount_sat': 69000,
          'is_change': true,
        },
      ],
    });

SignatureResultDto _signatureResult() => const SignatureResultDto(
      status: 'SUCCESS',
      handleId: 'review-layout-handle',
      address: _signer,
      derivationPath: _path,
      signatureHex: '',
      signatureUr: 'ur:eth-signature/public-layout-fixture',
      signatureUrFrames: [
        'ur:eth-signature/1-2/public-layout-fixture',
        'ur:eth-signature/2-2/public-layout-fixture',
      ],
    );

class _ReviewBoundary implements VaultFfiService {
  int signingCalls = 0;
  final events = <String>[];

  @override
  SignatureResultDto approveAndSignResult([String? handleId]) {
    signingCalls++;
    events.add('native:$handleId');
    return _signatureResult();
  }

  @override
  bool cancel([String? handleId]) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _mount(
  WidgetTester tester, {
  required Widget home,
  required Brightness brightness,
  required double scale,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: brightness == Brightness.light
        ? ColdWalletTheme.light(role: FcwRole.vault)
        : ColdWalletTheme.dark(role: FcwRole.vault),
    builder: (context, child) => MediaQuery(
      data:
          MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: home,
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void _assertFullFieldBeforeApproval(
    WidgetTester tester, String key, String value) {
  final field = find.byKey(Key(key));
  expect(field, findsOneWidget);
  final text = tester.widget<SelectableText>(field);
  expect(text.data, value);
  expect(text.maxLines, isNull, reason: '$key must not truncate review data');
  expect(
      tester.getTopLeft(field).dy,
      lessThan(tester
          .getTopLeft(find.byKey(const Key('vault_slide_to_confirm')))
          .dy));
  expect(tester.getSize(field).width, lessThanOrEqualTo(288));
}

void main() {
  testWidgets('incomplete EVM parameters never expose an approval action',
      (tester) async {
    final ffi = _ReviewBoundary();
    final review = PreparedReviewDto.fromJson({
      'handle_id': 'incomplete-evm-handle',
      'chain_id': 11155111,
      'raw_signing_digest': List.filled(32, 17),
      'policy_verdict': {
        'Approved': {'amount_display': '1 ETH'}
      },
      'intent': {
        'NativeTransfer': {
          'chain_id': 11155111,
          'recipient': _recipient,
          'value_wei': '1000000000000000000',
          'fee_cap_wei': '21000',
        }
      },
    });
    await _mount(tester,
        home: ReviewScreen(review: review, ffi: ffi),
        brightness: Brightness.light,
        scale: 2);
    expect(review.isSignable, isFalse);
    expect(find.textContaining('缺少完整的原生 EVM 交易參數'), findsOneWidget);
    expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
    expect(
        tester
            .widget<SlideToConfirm>(
                find.byKey(const Key('vault_slide_to_confirm')))
            .enabled,
        isFalse);
    final thumb = find.byIcon(Icons.arrow_forward_ios);
    await tester.ensureVisible(thumb);
    await tester.drag(thumb, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(ffi.signingCalls, 0);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'EVM review keeps complete critical fields before approval at 320dp $brightness $scale',
          (tester) async {
        final ffi = _ReviewBoundary();
        await _mount(tester,
            home: ReviewScreen(review: _evmReview(), ffi: ffi),
            brightness: brightness,
            scale: scale);

        expect(find.text('確認交易'), findsOneWidget);
        _assertFullFieldBeforeApproval(
            tester, 'review_amount', '123.456789 USDC');
        _assertFullFieldBeforeApproval(tester, 'review_recipient', _recipient);
        _assertFullFieldBeforeApproval(
            tester, 'review_network', 'Ethereum Sepolia Testnet (11155111)');
        _assertFullFieldBeforeApproval(tester, 'review_signer', _signer);
        _assertFullFieldBeforeApproval(tester, 'review_contract', _contract);
        _assertFullFieldBeforeApproval(tester, 'review_evm_type', 'EIP-1559');
        _assertFullFieldBeforeApproval(tester, 'review_evm_nonce', '362');
        _assertFullFieldBeforeApproval(tester, 'review_evm_gas_limit', '21000');
        _assertFullFieldBeforeApproval(tester, 'review_evm_max_fee_per_gas',
            '2000000000 wei / Gas (2 Gwei)');
        _assertFullFieldBeforeApproval(tester,
            'review_evm_priority_fee_per_gas', '1000000000 wei / Gas (1 Gwei)');
        _assertFullFieldBeforeApproval(tester, 'review_evm_to', _contract);
        _assertFullFieldBeforeApproval(
            tester, 'review_evm_native_value', '0 ETH (0 wei)');
        _assertFullFieldBeforeApproval(
            tester, 'review_evm_data', _evmReview().evmDetails!.dataHex);
        _assertFullFieldBeforeApproval(tester, 'review_evm_access_list', '1 筆');
        _assertFullFieldBeforeApproval(
            tester, 'review_evm_access_address_0', _contract);
        _assertFullFieldBeforeApproval(
            tester, 'review_evm_storage_key_0_0', '0x${'12' * 32}');
        _assertFullFieldBeforeApproval(
            tester, 'review_evm_storage_key_0_1', '0x${'34' * 32}');
        _assertFullFieldBeforeApproval(
            tester, 'review_fee', '0.000042 ETH (42000000000000 wei)');
        _assertFullFieldBeforeApproval(
            tester, 'review_request_id', 'review-layout-original-request');
        _assertFullFieldBeforeApproval(
            tester, 'review_signing_digest', _digest);
        expect(find.text(_path), findsOneWidget);
        expect(find.textContaining('此為測試網交易'), findsOneWidget);
        expect(find.byType(ExpansionTile), findsNothing);
        expect(
            tester.getTopLeft(find.byKey(const Key('review_amount'))).dy,
            lessThan(tester
                .getTopLeft(find.byKey(const Key('review_recipient')))
                .dy));
        expect(
            tester.getTopLeft(find.byKey(const Key('review_recipient'))).dy,
            lessThan(
                tester.getTopLeft(find.byKey(const Key('review_network'))).dy));
        final approve = find.byKey(const Key('vault_explicit_approve_btn'));
        await tester.ensureVisible(approve);
        expect(tester.getSize(approve).height, greaterThanOrEqualTo(48));
        expect(ffi.signingCalls, 0);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'Bitcoin review keeps every output and invariant before approval at 320dp $brightness $scale',
          (tester) async {
        final review = _bitcoinReview();
        expect(review.isSignable, isTrue);
        await _mount(tester,
            home: ReviewScreen(review: review, ffi: _ReviewBoundary()),
            brightness: brightness,
            scale: scale);

        _assertFullFieldBeforeApproval(
            tester, 'review_amount', '0.0003 BTC (30000 sats)');
        for (var i = 0; i < review.btcOutputs.length; i++) {
          final output = review.btcOutputs[i];
          _assertFullFieldBeforeApproval(tester, 'review_btc_output_$i',
              '${output.address}\n${output.valueSats} sats');
        }
        expect(find.text('2'), findsOneWidget);
        expect(find.text('100000 sats'), findsOneWidget);
        expect(find.text('99000 sats'), findsOneWidget);
        expect(find.text('輸出 3 · 已驗證找零'), findsOneWidget);
        _assertFullFieldBeforeApproval(
            tester, 'review_fee', '1000 sats (0.00001 BTC)');
        _assertFullFieldBeforeApproval(
            tester, 'review_signing_digest', _digest);
        expect(find.byType(ExpansionTile), findsNothing);
        await tester
            .ensureVisible(find.byKey(const Key('vault_explicit_approve_btn')));
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'rejection remains readable and cannot sign at 320dp $brightness $scale',
          (tester) async {
        final ffi = _ReviewBoundary();
        await _mount(tester,
            home: ReviewScreen(review: _evmReview(rejected: true), ffi: ffi),
            brightness: brightness,
            scale: scale);
        final reason = find.text('合約不在允許清單：EVM-09');
        expect(reason, findsOneWidget);
        expect(tester.widget<Text>(reason).maxLines, isNull);
        expect(
            tester.getTopLeft(reason).dy,
            lessThan(tester
                .getTopLeft(find.byKey(const Key('vault_slide_to_confirm')))
                .dy));
        expect(
            tester
                .widget<SlideToConfirm>(
                    find.byKey(const Key('vault_slide_to_confirm')))
                .enabled,
            isFalse);
        expect(
            find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
        final thumb = find.byIcon(Icons.arrow_forward_ios);
        await tester.ensureVisible(thumb);
        await tester.drag(thumb, const Offset(400, 0));
        await tester.pumpAndSettle();
        expect(ffi.signingCalls, 0);
        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'signed public result is paused and keeps original metadata at 320dp $brightness $scale',
          (tester) async {
        await _mount(tester,
            home: SignedResultScreen(
              result: _signatureResult(),
              requestId: 'review-layout-original-request',
              signingDigest: _digest,
              chainId: 11155111,
              keysRemainLocked: true,
              persistenceError: '公開結果寫入失敗，請保留目前 QR。',
            ),
            brightness: brightness,
            scale: scale);
        expect(
            tester
                .widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr))
                .startPaused,
            isTrue);
        expect(find.byTooltip('播放'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(find.byTooltip('播放'), findsOneWidget);
        final hint = find.byKey(const Key('signed_result_play_hint'));
        expect(hint, findsOneWidget);
        // The control is a ▶ icon whose label 播放 is only its tooltip.
        expect(tester.widget<Text>(hint).data, contains('播放鍵（▶）'));
        expect(tester.getTopLeft(hint).dy,
            lessThan(tester.getTopLeft(find.byType(AnimatedFountainQr)).dy));
        expect(
            find.byKey(const Key('public_result_keys_locked')), findsOneWidget);
        expect(find.text('原始請求識別碼：review-layout-original-request'),
            findsOneWidget);
        expect(find.text('原始簽署摘要：$_digest'), findsOneWidget);
        expect(find.text('原始 Chain ID：11155111'), findsOneWidget);
        expect(find.text('簽署帳戶：$_signer'), findsOneWidget);
        expect(find.text('派生路徑：$_path'), findsOneWidget);
        for (final key in [
          'signed_result_request_id',
          'signed_result_digest'
        ]) {
          expect(tester.widget<SelectableText>(find.byKey(Key(key))).maxLines,
              isNull);
        }
        expect(find.byKey(const Key('public_result_persistence_error')),
            findsOneWidget);
        expect(find.byType(SlideToConfirm), findsNothing);
        expect(
            find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
        await tester
            .ensureVisible(find.byKey(const Key('signature_done_return_btn')));
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final multiFrame in [true, false]) {
    testWidgets('Bitcoin result never shows the stored Chain ID 0 '
        '[multi-frame: $multiFrame]', (tester) async {
      await _mount(tester,
          home: SignedResultScreen(
            result: SignatureResultDto(
              status: 'SIGNED_PSBT',
              handleId: '',
              address: '',
              signatureHex: '',
              signedPsbtUr: 'ur:crypto-psbt/public-layout-fixture',
              signedPsbtUrFrames: multiFrame
                  ? const [
                      'ur:crypto-psbt/1-2/public-layout-fixture',
                      'ur:crypto-psbt/2-2/public-layout-fixture',
                    ]
                  : const [],
            ),
            requestId: 'bitcoin-layout-original-request',
            signingDigest: _digest,
            // Stored Bitcoin metadata keeps the default 0.
            chainId: 0,
          ),
          brightness: Brightness.dark,
          scale: 1);
      expect(find.textContaining('Chain ID'), findsNothing);
      expect(find.text('原始請求識別碼：bitcoin-layout-original-request'),
          findsOneWidget);
      expect(find.byKey(const Key('signed_result_play_hint')),
          multiFrame ? findsOneWidget : findsNothing);
      expect(find.byTooltip('播放'), multiFrame ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('single-frame EVM result keeps its Chain ID and gets no play '
      'hint', (tester) async {
    await _mount(tester,
        home: const SignedResultScreen(
          result: SignatureResultDto(
            status: 'SUCCESS',
            handleId: '',
            address: _signer,
            signatureHex: '',
            signatureUr: 'ur:eth-signature/public-layout-fixture',
          ),
          chainId: 11155111,
        ),
        brightness: Brightness.light,
        scale: 1);
    expect(find.text('原始 Chain ID：11155111'), findsOneWidget);
    expect(find.byKey(const Key('signed_result_play_hint')), findsNothing);
    expect(find.byTooltip('播放'), findsNothing);
  });

  testWidgets('native prepared-request capacity reaches the review as a '
      'zh-TW capacity notice and stays unsignable', (tester) async {
    final ffi = _ReviewBoundary();
    // vault_prepare_ur_request reports the retention gate this way.
    final review = PreparedReviewDto.fromJson({
      'status': 'ERROR',
      'error_code': 'ERR_REQUEST_REJECTED',
      'error': 'Prepared request retention limit reached; '
          'existing signing history must be preserved',
    });
    await _mount(tester,
        home: ReviewScreen(review: review, ffi: ffi),
        brightness: Brightness.dark,
        scale: 2);
    expect(find.text('待簽請求已達上限'), findsOneWidget);
    expect(find.text('政策拒絕'), findsNothing);
    expect(find.textContaining('Prepared request'), findsNothing);
    expect(
        tester
            .widget<SlideToConfirm>(
                find.byKey(const Key('vault_slide_to_confirm')))
            .enabled,
        isFalse);
    expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
    expect(ffi.signingCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incomplete Bitcoin invariants keep the slider disabled',
      (tester) async {
    final review = _bitcoinReview(incomplete: true);
    final ffi = _ReviewBoundary();
    expect(review.isSignable, isFalse);
    await _mount(tester,
        home: ReviewScreen(review: review, ffi: ffi),
        brightness: Brightness.light,
        scale: 2);
    expect(find.textContaining('Bitcoin 交易摘要無法驗證'), findsOneWidget);
    expect(
        tester
            .widget<SlideToConfirm>(
                find.byKey(const Key('vault_slide_to_confirm')))
            .enabled,
        isFalse);
    expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
    final thumb = find.byIcon(Icons.arrow_forward_ios);
    await tester.ensureVisible(thumb);
    await tester.drag(thumb, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(ffi.signingCalls, 0);
  });

  testWidgets('approval preserves reservation-native-persistence ordering',
      (tester) async {
    final ffi = _ReviewBoundary();
    final review = _evmReview();
    await _mount(tester,
        home: ReviewScreen(
          review: review,
          ffi: ffi,
          beforeSigning: (original) {
            expect(identical(original, review), isTrue);
            ffi.events.add('reserve');
            return null;
          },
          onSignedResult: (original, result) {
            expect(identical(original, review), isTrue);
            expect(result.qrFrames, isNotEmpty);
            ffi.events.add('persist');
            return null;
          },
        ),
        brightness: Brightness.light,
        scale: 2);
    final approve = find.byKey(const Key('vault_explicit_approve_btn'));
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(ffi.events, ['reserve', 'native:review-layout-handle', 'persist']);
    expect(ffi.signingCalls, 1);
    expect(find.byType(SignedResultScreen), findsOneWidget);
    expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
    expect(
        tester
            .widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr))
            .startPaused,
        isTrue);
  });
}
