import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:public_models/public_models.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/vault_home_screen.dart';

class _PublicResultBoundary implements VaultFfiService {
  bool unlocked = true;
  int signingCalls = 0, prepareCalls = 0, cancellations = 0;
  String digest = 'ab' * 32;
  String identity = '02${'12' * 32}';
  VoidCallback? afterSigning;

  @override
  int init() => 0;

  @override
  Map<String, dynamic> checkStorageStatus(String path) => {
        'status': 'ENCRYPTED_ON_DISK',
        'unlocked': unlocked,
        'master_fingerprint': '1234abcd',
      };

  @override
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 120}) => {
        'status': 'SUCCESS',
        'master_fingerprint': '1234abcd',
        'multi_accounts': {
          'ur_single': 'ur:crypto-multi-accounts/public-test-fixture',
          'evm_accounts': [
            {
              'account_index': 0,
              'derivation_path': "m/44'/60'/0'/0/0",
              'address': '0x${'11' * 20}',
              'compressed_pubkey_hex': identity,
            }
          ],
        },
      };

  @override
  PreparedReviewDto prepareUr({
    required String sessionId,
    required String urStringOrFramesJson,
  }) {
    prepareCalls++;
    return PreparedReviewDto(
      handleId: 'handle-$prepareCalls',
      sessionId: sessionId,
      requestId: 'public-result-request',
      chainId: 31337,
      recipient: '0x${'22' * 20}',
      signerAddress: '0x${'11' * 20}',
      rawAmount: '1000000000000000',
      displayAmount: '0.001 ETH',
      tokenSymbol: 'ETH',
      decimals: 18,
      feeCapWei: '21000000000000',
      verdict: ReviewVerdictType.approved,
      derivationPath: "m/44'/60'/0'/0/0",
      signingDigestHex: digest,
      evmDetails: EvmReviewDetails.fromJson({
        'type': 'Legacy EIP-155',
        'chain_id': '31337',
        'nonce': '0',
        'gas_limit': '21000',
        'gas_price_wei': '1000000000',
        'to': '0x${'22' * 20}',
        'value_wei': '1000000000000000',
        'data_hex': '0x',
        'access_list': <dynamic>[],
      }),
    );
  }

  @override
  SignatureResultDto approveAndSignResult([String? handleId]) {
    signingCalls++;
    afterSigning?.call();
    return SignatureResultDto(
      status: 'SUCCESS',
      handleId: handleId!,
      address: '0x${'11' * 20}',
      derivationPath: "m/44'/60'/0'/0/0",
      signatureHex: '0x${'34' * 64}1b',
      signatureUr: 'ur:eth-signature/public-signed-result-fixture',
      signatureUrFrames: const [
        'ur:eth-signature/1-2/public-signed-result-fixture',
        'ur:eth-signature/2-2/public-signed-result-fixture',
      ],
    );
  }

  @override
  bool cancel([String? handleId]) {
    cancellations++;
    return true;
  }

  @override
  bool lock() {
    unlocked = false;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  late Directory temporaryDirectory;
  late String storagePath;

  setUp(() {
    temporaryDirectory =
        Directory.systemTemp.createTempSync('fcw_public_result_');
    storagePath = '${temporaryDirectory.path}/vault.json';
  });
  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  Future<void> mount(WidgetTester tester, _PublicResultBoundary ffi) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('fcw/platform'), (call) async => null);
    await tester.pumpWidget(
        MaterialApp(home: VaultHomeScreen(ffi: ffi, storagePath: storagePath)));
    await tester.pumpAndSettle();
  }

  for (final background in [false, true]) {
    testWidgets(
        'sign once then ${background ? 'background' : 'lock'} and redisplay public result with keys locked',
        (tester) async {
      final ffi = _PublicResultBoundary();
      await mount(tester, ffi);
      final home =
          tester.state<VaultHomeScreenState>(find.byType(VaultHomeScreen));
      home.ingestSignRequestUr('ur:eth-sign-request/public-fixture');
      await tester.pumpAndSettle();
      await _tap(tester, 'vault_explicit_approve_btn');
      expect(ffi.signingCalls, 1);
      if (background) {
        home.lockForLifecycle(AppLifecycleState.paused);
      } else {
        home.lockVault();
      }
      await tester.pumpAndSettle();
      expect(ffi.unlocked, isFalse);
      await _tap(tester, 'show_public_signed_result_btn');
      expect(
          find.byKey(const Key('generated_signature_ur_text')), findsOneWidget);
      expect(find.textContaining('私鑰保持鎖定'), findsOneWidget);
      expect(find.text('原始請求識別碼：public-result-request'), findsOneWidget);
      expect(find.text('原始簽署摘要：${ffi.digest}'), findsOneWidget);
      expect(find.byTooltip('播放'), findsOneWidget);
      expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
      expect(ffi.signingCalls, 1);
      expect(ffi.unlocked, isFalse);
    });
  }

  testWidgets('fresh App loads saved public result without unlocking',
      (tester) async {
    final ffi = _PublicResultBoundary();
    await mount(tester, ffi);
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .ingestSignRequestUr('ur:eth-sign-request/public-fixture');
    await tester.pumpAndSettle();
    await _tap(tester, 'vault_explicit_approve_btn');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    ffi.unlocked = false;
    await mount(tester, ffi);
    await _tap(tester, 'show_public_signed_result_btn');
    expect(
        find.byKey(const Key('generated_signature_ur_text')), findsOneWidget);
    expect(ffi.signingCalls, 1);
    expect(ffi.unlocked, isFalse);
  });

  testWidgets(
      'same audited request replays after prepare without native re-sign',
      (tester) async {
    final ffi = _PublicResultBoundary();
    await mount(tester, ffi);
    final home =
        tester.state<VaultHomeScreenState>(find.byType(VaultHomeScreen));
    home.ingestSignRequestUr('ur:eth-sign-request/public-fixture');
    await tester.pumpAndSettle();
    await _tap(tester, 'vault_explicit_approve_btn');
    await _tap(tester, 'signature_done_return_btn');
    home.ingestSignRequestUr('ur:eth-sign-request/public-fixture');
    await tester.pumpAndSettle();
    expect(ffi.prepareCalls, 2);
    expect(ffi.signingCalls, 1);
    expect(ffi.cancellations, greaterThan(1));
    expect(
        find.byKey(const Key('generated_signature_ur_text')), findsOneWidget);
    expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
  });

  for (final mutation in ['digest', 'identity']) {
    testWidgets('changed $mutation cannot replay previous public result',
        (tester) async {
      final ffi = _PublicResultBoundary();
      await mount(tester, ffi);
      final home =
          tester.state<VaultHomeScreenState>(find.byType(VaultHomeScreen));
      home.ingestSignRequestUr('ur:eth-sign-request/public-fixture');
      await tester.pumpAndSettle();
      await _tap(tester, 'vault_explicit_approve_btn');
      await _tap(tester, 'signature_done_return_btn');
      if (mutation == 'digest') {
        ffi.digest = 'ff' * 32;
      } else {
        ffi.identity = '03${'45' * 32}';
        home.refreshStorageState();
        await tester.pumpAndSettle();
      }
      home.ingestSignRequestUr('ur:eth-sign-request/public-fixture');
      await tester.pumpAndSettle();
      expect(
          find.byKey(const Key('vault_explicit_approve_btn')), findsOneWidget);
      expect(
          find.byKey(const Key('generated_signature_ur_text')), findsNothing);
      expect(ffi.signingCalls, 1);
    });
  }

  testWidgets('reservation write failure blocks native approval',
      (tester) async {
    final ffi = _PublicResultBoundary();
    await mount(tester, ffi);
    Directory('$storagePath.public_signed_results.json.tmp').createSync();
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .ingestSignRequestUr('ur:eth-sign-request/public-fixture');
    await tester.pumpAndSettle();
    await _tap(tester, 'vault_explicit_approve_btn');
    expect(ffi.signingCalls, 0);
    expect(find.textContaining('寫入失敗'), findsWidgets);
    expect(find.byKey(const Key('generated_signature_ur_text')), findsNothing);
  });

  testWidgets('corrupt saved cache never becomes a fresh signing request',
      (tester) async {
    File('$storagePath.public_signed_results.json')
        .writeAsStringSync('{corrupt');
    final ffi = _PublicResultBoundary();
    await mount(tester, ffi);
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .ingestSignRequestUr('ur:eth-sign-request/public-fixture');
    await tester.pumpAndSettle();
    expect(find.textContaining('損毀'), findsWidgets);
    expect(find.byKey(const Key('vault_explicit_approve_btn')), findsNothing);
    expect(ffi.signingCalls, 0);
  });

  testWidgets(
      'result write failure keeps current public QR and restart shows unknown result',
      (tester) async {
    final ffi = _PublicResultBoundary();
    await mount(tester, ffi);
    ffi.afterSigning = () =>
        Directory('$storagePath.public_signed_results.json.tmp').createSync();
    final home =
        tester.state<VaultHomeScreenState>(find.byType(VaultHomeScreen));
    home.ingestSignRequestUr('ur:eth-sign-request/public-fixture');
    await tester.pumpAndSettle();
    await _tap(tester, 'vault_explicit_approve_btn');
    expect(ffi.signingCalls, 1);
    expect(
        find.byKey(const Key('generated_signature_ur_text')), findsOneWidget);
    expect(find.byKey(const Key('public_result_persistence_error')),
        findsOneWidget);
    home.lockVault();
    await tester.pumpAndSettle();
    await _tap(tester, 'show_public_signed_result_btn');
    expect(
        find.byKey(const Key('generated_signature_ur_text')), findsOneWidget);
    expect(ffi.unlocked, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await mount(tester, ffi);
    expect(find.byKey(const Key('public_result_unavailable')), findsOneWidget);
    final redisplay = tester.widget<OutlinedButton>(
        find.byKey(const Key('show_public_signed_result_btn')));
    expect(redisplay.onPressed, isNull);
    expect(ffi.signingCalls, 1);
  });
}
