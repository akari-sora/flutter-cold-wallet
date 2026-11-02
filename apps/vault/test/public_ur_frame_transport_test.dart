import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/signed_result_screen.dart';
import 'package:vault/screens/vault_home_screen.dart';

// Public display placeholders exercise transport selection/copy only. There is
// no key intake, device authentication, native decoding, or signing in this file.
const _ownSingle = 'ur:crypto-multi-accounts/public-small-own';
const _pairingFrames = [
  'ur:crypto-multi-accounts/1-3/public-one',
  'ur:crypto-multi-accounts/2-3/public-two',
  'ur:crypto-multi-accounts/3-3/public-three',
];

class _PublicPairingBoundary extends Fake implements VaultFfiService {
  bool ownFramesOnly = true;
  String? ownSingle;
  final ownFragmentLimits = <int>[];
  final okxFragmentLimits = <int>[];

  Map<String, dynamic> accounts({required bool framesOnly, String? single}) => {
        if (single != null || !framesOnly) 'ur_single': single ?? _ownSingle,
        'fountain_frames': _pairingFrames,
        'evm_accounts': [
          {
            'account_index': 0,
            'derivation_path': "m/44'/60'/0'/0/0",
            'address': '0x${'11' * 20}',
            'compressed_pubkey_hex': '02${'12' * 32}',
          }
        ],
        'btc_accounts': <dynamic>[],
      };

  @override
  int init() => 0;
  @override
  bool cancel([String? handleId]) => true;
  @override
  bool lock() => true;
  @override
  Map<String, dynamic> checkStorageStatus(String path) => {
        'status': 'ENCRYPTED_ON_DISK',
        'unlocked': true,
        'master_fingerprint': '1234abcd',
      };
  @override
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 120}) {
    ownFragmentLimits.add(maxFragmentLen);
    return {
      'status': 'SUCCESS',
      'master_fingerprint': '1234abcd',
      'multi_accounts': accounts(framesOnly: ownFramesOnly, single: ownSingle),
    };
  }

  @override
  Map<String, dynamic> exportOkxAccounts({int maxFragmentLen = 120}) {
    okxFragmentLimits.add(maxFragmentLen);
    return {
      'status': 'SUCCESS',
      'adapter': 'okx-evm-account-standard',
      'master_fingerprint': '1234abcd',
      'multi_accounts': accounts(framesOnly: true),
    };
  }
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _mount(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: home));
  await tester.pumpAndSettle();
}

void main() {
  late Directory directory;
  late List<String> clipboard;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('fcw_public_ur_frames_');
    clipboard = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), (call) async => null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    directory.deleteSync(recursive: true);
  });

  for (final oversizedSingle in [false, true]) {
    testWidgets(
        'own pairing uses all frames when single is ${oversizedSingle ? 'too large' : 'absent'}',
        (tester) async {
      final boundary = _PublicPairingBoundary();
      if (oversizedSingle) {
        boundary.ownSingle = 'ur:crypto-multi-accounts/${'a' * 2400}';
      }
      await _mount(
          tester,
          VaultHomeScreen(
              ffi: boundary, storagePath: '${directory.path}/public-state'));
      final qr =
          tester.widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr));
      expect(qr.frames, _pairingFrames);
      final toggle = tester
          .widget<FilterChip>(find.byKey(const Key('pairing_fountain_toggle')));
      expect(toggle.selected, isTrue);
      expect(toggle.onSelected, isNull);
      expect(find.text('動態多幀 QR'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('copy_pairing_ur_btn')));
      expect(jsonDecode(clipboard.single), _pairingFrames);
      await _tap(tester, find.byKey(const Key('public_pairing_text_toggle')));
      expect(
          jsonDecode(tester
              .widget<SelectableText>(
                  find.byKey(const Key('public_pairing_ur_text')))
              .data!),
          _pairingFrames);
      expect(boundary.ownFragmentLimits, [0]);
    });
  }

  testWidgets('OKX frame-only pairing stays distinct from small own single UR',
      (tester) async {
    final boundary = _PublicPairingBoundary()..ownFramesOnly = false;
    await _mount(
        tester,
        VaultHomeScreen(
            ffi: boundary, storagePath: '${directory.path}/public-state'));
    expect(
        tester
            .widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr))
            .frames,
        [_ownSingle]);
    await _tap(tester, find.byKey(const Key('pairing_profile_okx')));
    expect(find.byKey(const Key('pairing_profile_error')), findsNothing);
    expect(
        tester
            .widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr))
            .frames,
        _pairingFrames);
    expect(
        tester
            .widget<FilterChip>(
                find.byKey(const Key('pairing_fountain_toggle')))
            .onSelected,
        isNull);
    await _tap(tester, find.byKey(const Key('copy_pairing_ur_btn')));
    expect(jsonDecode(clipboard.single), _pairingFrames);
    expect(boundary.okxFragmentLimits, [0]);
    await _tap(tester, find.byKey(const Key('pairing_profile_wallet')));
    expect(
        tester
            .widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr))
            .frames,
        [_ownSingle]);
  });

  for (final variant in [
    (bitcoin: false, oversizedSingle: false),
    (bitcoin: false, oversizedSingle: true),
    (bitcoin: true, oversizedSingle: false),
    (bitcoin: true, oversizedSingle: true),
  ]) {
    testWidgets(
        '${variant.bitcoin ? 'Bitcoin' : 'EVM'} result copies every frame with ${variant.oversizedSingle ? 'oversized' : 'absent'} single UR',
        (tester) async {
      final bitcoin = variant.bitcoin;
      final type = bitcoin ? 'crypto-psbt' : 'eth-signature';
      final frames = [
        'ur:$type/1-3/public-first',
        'ur:$type/2-3/public-second',
        'ur:$type/3-3/public-third',
      ];
      final single = variant.oversizedSingle ? 'ur:$type/${'a' * 2400}' : null;
      final result = SignatureResultDto(
        status: bitcoin ? 'SIGNED_PSBT' : 'SUCCESS',
        handleId: '',
        address: '',
        signatureHex: '',
        signatureUr: bitcoin ? null : single,
        signatureUrFrames: bitcoin ? const [] : frames,
        signedPsbtUr: bitcoin ? single : null,
        signedPsbtUrFrames: bitcoin ? frames : const [],
      );
      await _mount(
          tester, SignedResultScreen(result: result, keysRemainLocked: true));
      final qr =
          tester.widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr));
      expect(qr.frames, frames);
      expect(qr.startPaused, isTrue);
      expect(
          find.byKey(const Key('public_result_keys_locked')), findsOneWidget);
      expect(
          tester
              .widget<SelectableText>(
                  find.byKey(const Key('generated_signature_ur_text')))
              .data,
          jsonEncode(frames));
      await _tap(tester, find.widgetWithText(OutlinedButton, '複製公開簽章 UR'));
      expect(jsonDecode(clipboard.single), frames);
      expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
    });
  }

  for (final bitcoin in [false, true]) {
    testWidgets(
        'historical ${bitcoin ? 'Bitcoin' : 'EVM'} single-only public result remains copyable without QR',
        (tester) async {
      final type = bitcoin ? 'crypto-psbt' : 'eth-signature';
      final ur = 'ur:$type/${'a' * 2400}';
      final result = SignatureResultDto(
        status: bitcoin ? 'SIGNED_PSBT' : 'SUCCESS',
        handleId: '',
        address: '',
        signatureHex: '',
        signatureUr: bitcoin ? null : ur,
        signedPsbtUr: bitcoin ? ur : null,
      );
      await _mount(
          tester, SignedResultScreen(result: result, keysRemainLocked: true));
      expect(find.byType(AnimatedFountainQr), findsNothing);
      expect(find.byKey(const Key('public_result_qr_unavailable')),
          findsOneWidget);
      expect(
          tester
              .widget<SelectableText>(
                  find.byKey(const Key('generated_signature_ur_text')))
              .data,
          ur);
      await _tap(tester, find.widgetWithText(OutlinedButton, '複製公開簽章 UR'));
      expect(clipboard, [ur]);
      expect(
          find.byKey(const Key('public_result_keys_locked')), findsOneWidget);
      expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
      expect(
          find.byKey(const Key('signature_done_return_btn')), findsOneWidget);
    });
  }
}
