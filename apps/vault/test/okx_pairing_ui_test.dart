import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/vault_home_screen.dart';

// Public-only fixtures exercise the native/UI boundary. Protocol and address
// derivation are covered separately by the production native adapter tests.
const _ownUr = 'ur:crypto-multi-accounts/own-wallet-public-fixture';
const _okxUr = 'ur:crypto-multi-accounts/okx-evm-public-fixture';
const _fingerprint = '1234abcd';

Map<String, dynamic> _publicAccounts(String ur, String framePrefix,
        {int frameCount = 2}) =>
    {
      'ur_single': ur,
      'fountain_frames': List.generate(
          frameCount,
          (index) =>
              'ur:crypto-multi-accounts/${index + 1}-$frameCount/$framePrefix'),
      'evm_accounts': [
        {
          'account_index': 0,
          'derivation_path': "m/44'/60'/0'/0/0",
          'address': '0x0000000000000000000000000000000000000001',
        }
      ],
      'btc_accounts': <dynamic>[],
    };

class _PairingBoundary implements VaultFfiService {
  bool unlocked = true;
  int okxExports = 0;
  Map<String, dynamic>? okxResponse;
  bool missingOkxSymbol = false;
  int ownFrameCount = 2;

  @override
  int init() => 0;

  @override
  Map<String, dynamic> checkStorageStatus(String storagePath) => {
        'status': 'ENCRYPTED_ON_DISK',
        'unlocked': unlocked,
        'master_fingerprint': _fingerprint,
        'has_passphrase_hint': false,
      };

  @override
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 120}) => {
        'status': 'SUCCESS',
        'master_fingerprint': _fingerprint,
        'has_passphrase_hint': false,
        'multi_accounts': _publicAccounts(_ownUr, 'own-public-frames',
            frameCount: ownFrameCount),
      };

  @override
  Map<String, dynamic> exportOkxAccounts({int maxFragmentLen = 120}) {
    okxExports++;
    if (missingOkxSymbol) throw ArgumentError('Missing native adapter symbol');
    return okxResponse ??
        {
          'status': 'SUCCESS',
          'adapter': 'okx-evm-account-standard',
          'master_fingerprint': _fingerprint,
          'has_passphrase_hint': false,
          'multi_accounts': _publicAccounts(_okxUr, 'okx-public-frames'),
        };
  }

  @override
  bool cancel([String? handleId]) => true;

  @override
  bool lock() {
    unlocked = false;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _mount(WidgetTester tester, _PairingBoundary ffi) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fcw/platform'), (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('fcw/platform'), null));
  await tester.pumpWidget(MaterialApp(
      home: VaultHomeScreen(ffi: ffi, storagePath: 'public-boundary-fixture')));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

List<String> _qrFrames(WidgetTester tester) =>
    tester.widget<AnimatedFountainQr>(find.byType(AnimatedFountainQr)).frames;

void main() {
  testWidgets(
      'own profile stays default and OKX QR text and copy stay isolated',
      (tester) async {
    final ffi = _PairingBoundary();
    String? clipboard;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _mount(tester, ffi);

    expect(_qrFrames(tester), [_ownUr]);
    expect(ffi.okxExports, 0, reason: 'OKX native lookup must be lazy');
    await _tap(tester, 'pairing_profile_okx');
    expect(ffi.okxExports, 1);
    expect(_qrFrames(tester), [_okxUr]);
    expect(find.textContaining('僅匯出公開帳戶'), findsOneWidget);
    expect(find.textContaining('簽章仍限本機／測試網'), findsOneWidget);
    expect(find.textContaining('尚未代表指定版本 OKX 已實測通過'), findsOneWidget);

    await _tap(tester, 'public_pairing_text_toggle');
    expect(
        tester
            .widget<SelectableText>(
                find.byKey(const Key('public_pairing_ur_text')))
            .data,
        _okxUr);
    await _tap(tester, 'copy_pairing_ur_btn');
    expect(clipboard, _okxUr);

    await _tap(tester, 'pairing_fountain_toggle');
    expect(_qrFrames(tester), [
      'ur:crypto-multi-accounts/1-2/okx-public-frames',
      'ur:crypto-multi-accounts/2-2/okx-public-frames'
    ]);
    await _tap(tester, 'pairing_profile_wallet');
    expect(_qrFrames(tester), [
      'ur:crypto-multi-accounts/1-2/own-public-frames',
      'ur:crypto-multi-accounts/2-2/own-public-frames'
    ]);
    await _tap(tester, 'copy_pairing_ur_btn');
    expect(clipboard, _ownUr);
    await _tap(tester, 'pairing_profile_okx');
    expect(ffi.okxExports, 1,
        reason: 'Same unlocked vault may reuse public QR');
  });

  testWidgets('paused late frame resets when profile or QR mode changes',
      (tester) async {
    final ffi = _PairingBoundary()..ownFrameCount = 4;
    await _mount(tester, ffi);
    await _tap(tester, 'pairing_fountain_toggle');
    await tester.tap(find.byTooltip('暫停'));
    await tester.pump();
    for (var step = 0;
        step < 4 && find.text('幀 4 / 4').evaluate().isEmpty;
        step++) {
      await tester.tap(find.byTooltip('下一幀 (步進)'));
      await tester.pump();
    }
    expect(find.text('幀 4 / 4'), findsOneWidget);
    expect(find.byTooltip('播放'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pairing_profile_okx')));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'A previous four-frame index cannot index two OKX frames');
    expect(_qrFrames(tester), [
      'ur:crypto-multi-accounts/1-2/okx-public-frames',
      'ur:crypto-multi-accounts/2-2/okx-public-frames'
    ]);
    expect(find.text('幀 1 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('下一幀 (步進)'));
    await tester.pump();
    expect(find.text('幀 2 / 2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pairing_fountain_toggle')));
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'A previous multi-frame index cannot index a single QR');
    expect(_qrFrames(tester), [_okxUr]);
    expect(find.byTooltip('下一幀 (步進)'), findsNothing,
        reason: 'A single QR has no multi-frame playback controls');
  });

  for (final failure in ['native', 'missing-symbol', 'different-vault']) {
    testWidgets('OKX $failure failure never falls back to own pairing QR',
        (tester) async {
      final ffi = _PairingBoundary();
      if (failure == 'native') {
        ffi.okxResponse = {
          'status': 'ERROR',
          'error_code': 'ERR_VAULT_LOCKED',
          'error': '金庫已鎖定',
        };
      } else if (failure == 'missing-symbol') {
        ffi.missingOkxSymbol = true;
      } else {
        ffi.okxResponse = {
          'status': 'SUCCESS',
          'adapter': 'okx-evm-account-standard',
          'master_fingerprint': 'ffffffff',
          'multi_accounts': _publicAccounts(_okxUr, 'okx-public-frames'),
        };
      }
      await _mount(tester, ffi);
      await _tap(tester, 'pairing_profile_okx');

      expect(find.byKey(const Key('pairing_profile_error')), findsOneWidget);
      expect(find.byType(AnimatedFountainQr), findsNothing);
      final copy = tester
          .widget<TextButton>(find.byKey(const Key('copy_pairing_ur_btn')));
      expect(copy.onPressed, isNull);
      await _tap(tester, 'public_pairing_text_toggle');
      expect(
          tester
              .widget<SelectableText>(
                  find.byKey(const Key('public_pairing_ur_text')))
              .data,
          isEmpty);
      await _tap(tester, 'pairing_profile_wallet');
      expect(_qrFrames(tester), [_ownUr]);
      expect(find.byKey(const Key('pairing_profile_error')), findsNothing);
    });
  }

  testWidgets('locking clears OKX profile cache and hides all pairing controls',
      (tester) async {
    final ffi = _PairingBoundary();
    await _mount(tester, ffi);
    await _tap(tester, 'pairing_profile_okx');
    expect(ffi.okxExports, 1);
    await _tap(tester, 'vault_lock_btn');
    expect(find.byKey(const Key('pairing_profile_okx')), findsNothing);
    expect(find.byType(AnimatedFountainQr), findsNothing);
    expect(ffi.okxExports, 1);

    ffi.unlocked = true;
    tester
        .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
        .refreshStorageState();
    await tester.pumpAndSettle();
    expect(_qrFrames(tester), [_ownUr]);
    await _tap(tester, 'pairing_profile_okx');
    expect(ffi.okxExports, 2,
        reason: 'Re-unlock must regenerate public export');
  });
}
