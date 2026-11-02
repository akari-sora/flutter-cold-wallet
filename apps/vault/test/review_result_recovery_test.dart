import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/review_screen.dart';
import 'package:vault/screens/signed_result_screen.dart';

// Public display fixtures only: this file never calls native signing APIs.
PreparedReviewDto _review() => PreparedReviewDto(
      handleId: 'public-review-handle',
      sessionId: 'public-session',
      requestId: 'public-request',
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
      signingDigestHex: 'ab' * 32,
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

class _ReviewBoundary extends Fake implements VaultFfiService {
  final cancellations = <String?>[];

  @override
  bool cancel([String? handleId]) {
    cancellations.add(handleId);
    return true;
  }

  @override
  SignatureResultDto approveAndSignResult([String? handleId]) =>
      throw StateError('This public-only test must never request signing');
}

Future<void> _open(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => screen,
          )),
          child: const Text('Public test home'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Public test home'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final action in ['header', 'footer']) {
    testWidgets('$action cancel leaves review and revokes its public handle',
        (tester) async {
      final boundary = _ReviewBoundary();
      await _open(tester, ReviewScreen(review: _review(), ffi: boundary));
      await _tap(
          tester,
          action == 'header'
              ? find.byTooltip('取消簽署')
              : find.byKey(const Key('vault_cancel_review_btn')));
      expect(find.byType(ReviewScreen), findsNothing);
      expect(find.text('Public test home'), findsOneWidget);
      expect(boundary.cancellations, isNotEmpty);
      expect(boundary.cancellations, everyElement('public-review-handle'));
    });
  }

  testWidgets(
      'reservation error remains readable on retry and can be cancelled',
      (tester) async {
    final boundary = _ReviewBoundary();
    var reservations = 0;
    await _open(
        tester,
        ReviewScreen(
          review: _review(),
          ffi: boundary,
          beforeSigning: (_) {
            reservations++;
            return '公開紀錄目前無法保存，請稍後再試。';
          },
        ));
    for (var attempt = 1; attempt <= 2; attempt++) {
      await _tap(tester, find.byKey(const Key('vault_explicit_approve_btn')));
      expect(reservations, attempt);
      final error = find.text('公開紀錄目前無法保存，請稍後再試。');
      expect(error, findsOneWidget);
      await tester.ensureVisible(error);
      expect(error.hitTestable(), findsOneWidget);
      expect(find.byType(SignedResultScreen), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }
    await _tap(tester, find.byKey(const Key('vault_cancel_review_btn')));
    expect(find.text('Public test home'), findsOneWidget);
  });

  for (final bitcoin in [false, true]) {
    testWidgets(
        '${bitcoin ? 'Bitcoin' : 'EVM'} public result copies exact UR and returns home',
        (tester) async {
      final copies = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copies.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final ur = bitcoin
          ? 'ur:crypto-psbt/public-display-fixture'
          : 'ur:eth-signature/public-display-fixture';
      final result = SignatureResultDto(
        status: 'SUCCESS',
        handleId: '',
        address: '',
        signatureHex: '',
        signatureUr: bitcoin ? null : ur,
        signedPsbtUr: bitcoin ? ur : null,
      );
      await _open(
          tester,
          SignedResultScreen(
            result: result,
            requestId: 'original-public-request',
            signingDigest: 'ab' * 32,
            keysRemainLocked: true,
          ));
      expect(find.byType(AnimatedFountainQr), findsOneWidget);
      expect(
          find.byKey(const Key('public_result_keys_locked')), findsOneWidget);
      await _tap(tester, find.widgetWithText(OutlinedButton, '複製公開簽章 UR'));
      expect(copies, [ur]);
      expect(find.text('已複製公開簽章 UR'), findsOneWidget);
      expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
      // At 2x text the confirmation SnackBar temporarily covers the footer.
      // Wait for its normal dismissal before interacting with that footer.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('signature_done_return_btn')));
      expect(find.byType(SignedResultScreen), findsNothing);
      expect(find.text('Public test home'), findsOneWidget);
    });
  }

  testWidgets(
      'missing public result hides QR and copy but leaves return usable',
      (tester) async {
    await _open(
        tester,
        const SignedResultScreen(
          result: SignatureResultDto(
            status: 'ERROR',
            handleId: '',
            address: '',
            signatureHex: '',
          ),
          keysRemainLocked: true,
        ));
    expect(find.text('無法顯示已簽結果'), findsOneWidget);
    expect(find.byType(AnimatedFountainQr), findsNothing);
    expect(find.widgetWithText(OutlinedButton, '複製公開簽章 UR'), findsNothing);
    await _tap(tester, find.byKey(const Key('signature_done_return_btn')));
    expect(find.text('Public test home'), findsOneWidget);
  });
}
