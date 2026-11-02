import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';

void main() {
  group('design_system widget tests', () {
    testWidgets('public review values expose complete semantics labels',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        const recipient = '0x2222222222222222222222222222222222222222';
        const contract = '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238';
        final review = PreparedReviewDto(
          handleId: 'public-semantics-handle',
          sessionId: 'public-semantics-session',
          requestId: 'public-semantics-request',
          chainId: 11155111,
          recipient: recipient,
          signerAddress: '0x1111111111111111111111111111111111111111',
          tokenContract: contract,
          rawAmount: '100500000',
          displayAmount: '100.5',
          tokenSymbol: 'USDC',
          decimals: 6,
          feeCapWei: '21000000000000',
          verdict: ReviewVerdictType.approved,
          derivationPath: "m/44'/60'/0'/0/0",
          signingDigestHex: 'ab' * 32,
          evmDetails: EvmReviewDetails.fromJson({
            'type': 'EIP-1559',
            'chain_id': '11155111',
            'nonce': '362',
            'gas_limit': '21000',
            'max_fee_per_gas_wei': '1000000000',
            'max_priority_fee_per_gas_wei': '500000000',
            'to': contract,
            'value_wei': '0',
            'data_hex':
                '0xa9059cbb${'0' * 24}${recipient.substring(2)}${BigInt.from(100500000).toRadixString(16).padLeft(64, '0')}',
            'access_list': [
              {
                'address': contract,
                'storage_keys': ['0x${'12' * 32}'],
              }
            ],
          }),
        );
        await tester.pumpWidget(MaterialApp(
          theme: ColdWalletTheme.light(role: FcwRole.wallet),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TransactionReviewCard(review: review),
            ),
          ),
        ));
        final values = tester
            .widgetList<SelectableText>(find.descendant(
                of: find.byType(TransactionReviewCard),
                matching: find.byType(SelectableText)))
            .toList();
        expect(values, isNotEmpty);
        for (final text in values) {
          final field = find.byWidget(text);
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          expect(text.semanticsLabel, text.data,
              reason: 'The full public value must have an explicit label');
          expect(find.bySemanticsLabel(text.data!), findsWidgets);
          expect(text.enableInteractiveSelection, isTrue);
          expect(text.maxLines, isNull);
        }
        final recipientField = find.byKey(const Key('review_recipient'));
        await tester.ensureVisible(recipientField);
        await tester.longPress(recipientField);
        await tester.pumpAndSettle();
        final editable = tester.widget<EditableText>(find.descendant(
            of: recipientField, matching: find.byType(EditableText)));
        expect(editable.controller.selection.isCollapsed, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets(
        'Bitcoin card shows external amount once and exact native outputs',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final review = PreparedReviewDto.fromJson({
        'status': 'SUCCESS',
        'type': 'BITCOIN_PSBT',
        'handle_id': 'btc-handle',
        'session_id': 'btc-session',
        'request_id': 'btc-request',
        'network': 'regtest',
        'signing_digest': 'ab' * 32,
        'total_input_sat': 100000000,
        'total_output_sat': 99999000,
        'fee_sat': 1000,
        'inputs_count': 1,
        'destinations': [
          {
            'address': 'bcrt1recipient',
            'amount_sat': 1000000,
            'is_change': false
          }
        ],
        'changes': [
          {'address': 'bcrt1change', 'amount_sat': 98999000, 'is_change': true}
        ],
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: TransactionReviewCard(review: review)))));

      expect(find.text('0.01 BTC (1000000 sats)'), findsOneWidget);
      expect(find.textContaining('sats) BTC'), findsNothing);
      expect(find.text('外部收款總額'), findsOneWidget);
      expect(find.text('bcrt1recipient\n1000000 sats'), findsOneWidget);
      expect(find.text('bcrt1change\n98999000 sats'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('1000 sats (0.00001 BTC)'), findsOneWidget);
      expect(find.text('交易手續費'), findsOneWidget);
      expect(find.text('100000000 sats'), findsOneWidget);
      expect(find.text('99999000 sats'), findsOneWidget);
      expect(find.textContaining('null sats'), findsNothing);
      expect(find.text('等待確認'), findsOneWidget);
    });

    testWidgets('incomplete Bitcoin card rejects without invented amounts',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final review = PreparedReviewDto.fromJson({
        'type': 'BITCOIN_PSBT',
        'handle_id': 'btc-handle',
        'destinations': [
          {'address': 'bcrt1recipient', 'amount_sat': null}
        ],
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: TransactionReviewCard(review: review)))));
      expect(find.text('政策拒絕'), findsOneWidget);
      expect(find.textContaining('null sats'), findsNothing);
      expect(find.textContaining('0 BTC'), findsNothing);
      expect(find.textContaining('無法驗證'), findsWidgets);
    });

    testWidgets('TransactionReviewCard renders approved transaction', (
      tester,
    ) async {
      final review = PreparedReviewDto(
        handleId: 'handle-1',
        sessionId: 'sess-1',
        requestId: 'req-1',
        chainId: 11155111,
        recipient: '0x9858effd232b4033e47d90003d41ec34ecaeda94',
        rawAmount: '100500000',
        displayAmount: '100.5',
        tokenSymbol: 'USDC',
        decimals: 6,
        feeCapWei: '21000000000000',
        verdict: ReviewVerdictType.approved,
        tokenContract: '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238',
        evmDetails: EvmReviewDetails.fromJson({
          'type': 'Legacy EIP-155',
          'chain_id': '11155111',
          'nonce': '7',
          'gas_limit': '21000',
          'gas_price_wei': '1000000000',
          'to': '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238',
          'value_wei': '0',
          'data_hex':
              '0xa9059cbb${'0' * 24}9858effd232b4033e47d90003d41ec34ecaeda94${BigInt.from(100500000).toRadixString(16).padLeft(64, '0')}',
          'access_list': <dynamic>[],
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: TransactionReviewCard(review: review))),
        ),
      );

      expect(find.text('等待確認'), findsOneWidget);
      expect(find.text('100.5 USDC'), findsOneWidget);
      expect(find.text('Legacy EIP-155'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(find.text('21000'), findsOneWidget);
      expect(find.text('1000000000 wei / Gas (1 Gwei)'), findsOneWidget);
      expect(find.text('0 ETH (0 wei)'), findsOneWidget);
      expect(find.text(review.evmDetails!.dataHex), findsOneWidget);
      expect(find.text('空（0 筆）'), findsOneWidget);
      expect(
        find.text('0x9858effd232b4033e47d90003d41ec34ecaeda94'),
        findsOneWidget,
      );
    });

    testWidgets('TransactionReviewCard renders rejected warning (EVM-09)', (
      tester,
    ) async {
      const review = PreparedReviewDto(
        handleId: 'handle-1',
        sessionId: 'sess-1',
        requestId: 'req-1',
        chainId: 11155111,
        recipient: '0xDeadBeef00000000000000000000000000000000',
        rawAmount: '1000',
        displayAmount: '0',
        tokenSymbol: 'UNKNOWN',
        decimals: 18,
        feeCapWei: '0',
        verdict: ReviewVerdictType.rejected,
        rejectionReason:
            'Token contract is not in the approved whitelist (EVM-09 Fail-Closed)',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: TransactionReviewCard(review: review))),
        ),
      );

      expect(find.text('政策拒絕'), findsOneWidget);
      expect(find.textContaining('EVM-09 Fail-Closed'), findsOneWidget);
    });

    for (final code in ['ERR_REQUEST_REJECTED', 'ERR_REQUEST_RETENTION']) {
      testWidgets('native prepared-request capacity is explained, not shown '
          'as a policy rejection [$code]', (tester) async {
        final review = PreparedReviewDto.fromJson({
          'status': 'ERROR',
          'error_code': code,
          'error': 'Prepared request retention limit reached; '
              'existing signing history must be preserved',
        });
        expect(review.isSignable, isFalse);
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: SingleChildScrollView(
                    child: TransactionReviewCard(review: review)))));

        expect(find.text('待簽請求已達上限'), findsOneWidget);
        expect(find.text('政策拒絕'), findsNothing);
        expect(find.textContaining('retention limit'), findsNothing);
        expect(find.textContaining('請完全關閉金庫 App 後重新開啟'), findsOneWidget);
        expect(find.textContaining('只鎖定金庫不會清除'), findsOneWidget);
      });
    }

    testWidgets('SlideToConfirm slider gesture triggers onConfirmed', (
      tester,
    ) async {
      bool confirmed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: SlideToConfirm(onConfirmed: () => confirmed = true),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(SlideToConfirm), findsOneWidget);
      expect(confirmed, isFalse);

      // Drag the slider arrow from left to right
      final iconFinder = find.byIcon(Icons.arrow_forward_ios);
      expect(iconFinder, findsOneWidget);

      await tester.drag(iconFinder, const Offset(260.0, 0.0));
      await tester.pumpAndSettle();

      expect(confirmed, isTrue);
      expect(find.text('已確認授權'), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
            'slider preserves gesture at 320dp $brightness text scale $scale',
            (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var confirmations = 0;
          await tester.pumpWidget(MaterialApp(
            theme: brightness == Brightness.light
                ? ColdWalletTheme.light(role: FcwRole.wallet)
                : ColdWalletTheme.dark(role: FcwRole.wallet),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: SlideToConfirm(onConfirmed: () => confirmations++),
              ),
            ),
          ));
          expect(tester.takeException(), isNull);
          final thumb = find.byIcon(Icons.arrow_forward_ios);
          expect(tester.getSize(find.byType(SlideToConfirm)).height,
              greaterThanOrEqualTo(56));

          await tester.tap(thumb);
          await tester.drag(thumb, const Offset(70, 0));
          await tester.pumpAndSettle();
          expect(confirmations, 0);

          await tester.drag(thumb, const Offset(250, 0));
          await tester.pumpAndSettle();
          expect(confirmations, 1);
          expect(find.text('已確認授權'), findsOneWidget);
          await tester.drag(find.byIcon(Icons.check), const Offset(-250, 0));
          await tester.drag(find.byIcon(Icons.check), const Offset(250, 0));
          await tester.pumpAndSettle();
          expect(confirmations, 1);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('disabled slider cannot approve through tap or drag',
        (tester) async {
      var confirmations = 0;
      await tester.pumpWidget(MaterialApp(
        theme: ColdWalletTheme.light(role: FcwRole.wallet),
        home: Scaffold(
          body: SizedBox(
            width: 288,
            child: SlideToConfirm(
              enabled: false,
              onConfirmed: () => confirmations++,
            ),
          ),
        ),
      ));
      final thumb = find.byIcon(Icons.arrow_forward_ios);
      await tester.tap(thumb);
      await tester.drag(thumb, const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(confirmations, 0);
      expect(find.text('已確認授權'), findsNothing);
    });

    testWidgets('locked overlay hides child semantics and fits enlarged text',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        var unlocks = 0;
        await tester.pumpWidget(MaterialApp(
          theme: ColdWalletTheme.light(role: FcwRole.wallet),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SecurityOverlay(
              isLocked: true,
              onUnlock: () => unlocks++,
              child: const Center(child: Text('hidden transaction details')),
            ),
          ),
        ));
        expect(
            find.bySemanticsLabel('hidden transaction details'), findsNothing);
        expect(find.text('金庫已鎖定'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final unlockButton = find.widgetWithText(FilledButton, '解鎖並重新掃描');
        await tester.ensureVisible(unlockButton);
        await tester.tap(unlockButton);
        expect(unlocks, 1);
      } finally {
        semantics.dispose();
      }
    });
  });
}
