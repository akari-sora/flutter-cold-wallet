import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/review_screen.dart';

class _SigningBoundary implements VaultFfiService {
  int signingCalls = 0;

  @override
  SignatureResultDto approveAndSignResult([String? handleId]) {
    signingCalls++;
    throw StateError('Malformed review must never reach native signing');
  }

  @override
  bool cancel([String? handleId]) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final missing in ['inputs_count', 'fee_sat', 'amount_sat']) {
    testWidgets('incomplete Bitcoin $missing never enables Vault signing',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final summary = <String, dynamic>{
        'status': 'SUCCESS',
        'type': 'BITCOIN_PSBT',
        'handle_id': 'native-btc-handle',
        'session_id': 'native-btc-session',
        'request_id': 'native-btc-request',
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
      };
      if (missing == 'amount_sat') {
        (summary['destinations'] as List).first.remove('amount_sat');
      } else {
        summary.remove(missing);
      }
      final ffi = _SigningBoundary();
      await tester.pumpWidget(MaterialApp(
          home: ReviewScreen(
              review: PreparedReviewDto.fromJson(summary), ffi: ffi)));
      await tester.pump();
      final slider = tester.widget<SlideToConfirm>(
          find.byKey(const Key('vault_slide_to_confirm')));
      expect(slider.enabled, isFalse);
      expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
      expect(find.text('政策拒絕'), findsOneWidget);
      await tester.drag(find.byType(SlideToConfirm), const Offset(700, 0));
      await tester.pumpAndSettle();
      expect(ffi.signingCalls, 0);
    });
  }
}
