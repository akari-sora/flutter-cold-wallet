import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/main.dart';

const _platform = MethodChannel('fcw/platform');
const _address = '0x0000000000000000000000000000000000000001';

// This boundary contains public account data only. Secret generation, backup
// verification and activation remain covered by the native journey tests.
class _LayoutBoundary extends Fake implements VaultFfiService {
  _LayoutBoundary(this.status, {this.unlocked = false});

  final String status;
  bool unlocked;

  @override
  int init() => 0;

  @override
  bool cancel([String? handleId]) => true;

  @override
  bool lock() {
    unlocked = false;
    return true;
  }

  @override
  Map<String, dynamic> checkStorageStatus(String storagePath) => {
        'status': status,
        'unlocked': unlocked,
        'master_fingerprint': '1234abcd',
        'has_passphrase_hint': false,
      };

  @override
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 120}) => {
        'status': 'SUCCESS',
        'master_fingerprint': '1234abcd',
        'has_passphrase_hint': false,
        'multi_accounts': {
          'ur_single': 'ur:crypto-multi-accounts/public-layout-fixture',
          'fountain_frames': <String>[],
          'evm_accounts': [
            {
              'account_index': 0,
              'derivation_path': "m/44'/60'/0'/0/0",
              'address': _address,
              'compressed_pubkey_hex':
                  '0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
            }
          ],
          'btc_accounts': <dynamic>[],
        },
      };

  @override
  Map<String, dynamic> previewMnemonic(String phrase,
          [String passphrase = '']) =>
      {
        'status': 'ERROR',
        'error_code': 'ERR_INVALID_MNEMONIC',
        'error': '請輸入有效助記詞',
      };
}

final _mnemonicWords = find.byWidgetPredicate((widget) =>
    widget is Text &&
    widget.key is ValueKey<String> &&
    (widget.key! as ValueKey<String>).value.startsWith('mnemonic_word_'));

Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _mountNarrow(
    WidgetTester tester, VaultFfiService ffi, String storagePath) async {
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_platform, null));
  await tester.pumpWidget(ColdWalletVaultApp(
    ffiOverride: ffi,
    storagePathOverride: storagePath,
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('fcw_vault_layout_');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  testWidgets('320dp and 2x text keep all onboarding routes reachable',
      (tester) async {
    await _mountNarrow(
        tester, _LayoutBoundary('EMPTY'), '${directory.path}/vault.json');
    expect(find.text('離線金庫'), findsOneWidget);
    expect(find.text('離線簽章'), findsOneWidget);
    final create = find.byKey(const Key('onboarding_tab_create'));
    final restore = find.byKey(const Key('onboarding_tab_restore_mnemonic'));
    final backup = find.byKey(const Key('onboarding_tab_restore_backup'));
    expect(tester.getTopLeft(restore).dy,
        greaterThan(tester.getTopLeft(create).dy));
    expect(tester.getTopLeft(backup).dy,
        greaterThan(tester.getTopLeft(restore).dy));

    await _tap(tester, const Key('onboarding_tab_restore_mnemonic'));
    await _tap(tester, const Key('preview_restore_mnemonic_btn'));
    expect(find.textContaining('ERR_INVALID_MNEMONIC'), findsOneWidget);
    expect(
        find.byKey(const Key('activate_restored_mnemonic_btn')), findsNothing);

    await _tap(tester, const Key('onboarding_tab_restore_backup'));
    for (final key in [
      'restore_backup_json_field',
      'restore_backup_password_field',
      'restore_backup_new_pin_field',
      'restore_backup_submit_btn',
    ]) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await _tap(tester, const Key('restore_backup_submit_btn'));
    expect(find.textContaining('請先解密預覽'), findsOneWidget);
    await _tap(tester, const Key('onboarding_tab_create'));
    expect(find.byKey(const Key('generate_mnemonic_btn')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the Vault stays dark and keeps its title name on a light system',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final semantics = tester.ensureSemantics();
    try {
      await _mountNarrow(
          tester, _LayoutBoundary('EMPTY'), '${directory.path}/vault.json');
      expect(Theme.of(tester.element(find.text('離線金庫'))).brightness,
          Brightness.dark);
      expect(find.bySemanticsLabel('離線金庫'), findsOneWidget);
      expect(find.bySemanticsLabel('離線簽章裝置'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('320dp and 2x text keep unlock primary and native errors visible',
      (tester) async {
    await _mountNarrow(tester, _LayoutBoundary('ENCRYPTED_ON_DISK'),
        '${directory.path}/vault.json');
    final unlock = find.byKey(const Key('vault_unlock_submit_btn'));
    final publicResult = find.byKey(const Key('show_public_signed_result_btn'));
    expect(tester.getTopLeft(unlock).dy,
        lessThan(tester.getTopLeft(publicResult).dy));
    expect(tester.getSize(unlock).height, greaterThanOrEqualTo(48));
    await _tap(tester, const Key('vault_unlock_submit_btn'));
    final error = find.textContaining('請輸入 PIN 碼 / 密碼');
    expect(error, findsOneWidget);
    await tester.ensureVisible(error);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('scan_sign_request_btn')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('320dp and 2x text place scanning before public pairing',
      (tester) async {
    await _mountNarrow(
        tester,
        _LayoutBoundary('ENCRYPTED_ON_DISK', unlocked: true),
        '${directory.path}/vault.json');
    final scan = find.byKey(const Key('scan_sign_request_btn'));
    final pairing = find.byKey(const Key('pairing_profile_wallet'));
    expect(tester.getTopLeft(scan).dy, lessThan(tester.getTopLeft(pairing).dy));
    expect(tester.getSize(scan).height, greaterThanOrEqualTo(48));
    await tester.ensureVisible(find.text('核對收款地址'));
    await tester.pumpAndSettle();
    final address = tester
        .widget<SelectableText>(find.widgetWithText(SelectableText, _address));
    expect(address.maxLines, isNull,
        reason: 'The full receive address must remain available for checking');
    expect(tester.takeException(), isNull);
    await _tap(tester, const Key('vault_lock_btn'));
    expect(find.byKey(const Key('pairing_profile_wallet')), findsNothing);
    expect(find.byKey(const Key('vault_unlock_submit_btn')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final count in [12, 24]) {
    testWidgets('320dp and 2x text show all $count generated words whole',
        (tester) async {
      final ffi = VaultFfiService();
      expect(ffi.init(), 0);
      ffi.lock();
      final storagePath = '${directory.path}/vault.json';
      try {
        await _mountNarrow(tester, ffi, storagePath);
        if (count == 24) {
          final length = find.text('24 字');
          await tester.ensureVisible(length);
          await tester.tap(length);
          await tester.pumpAndSettle();
        }
        // Measures layout only; the words never reach a matcher or diagnostic.
        await _tap(tester, const Key('generate_mnemonic_btn'));
        final tiles = _mnemonicWords;
        expect(tiles, findsNWidgets(count));
        final rowWidth = tester
            .getSize(
                find.ancestor(of: tiles.first, matching: find.byType(Wrap)))
            .width;
        var broken = 0;
        var checked = 0;
        for (final tile in tiles.evaluate()) {
          final paragraph = tile.findRenderObject()! as RenderParagraph;
          final label = paragraph.text.toPlainText();
          final start = label.indexOf(' ') + 1;
          final word = TextPainter(
            text: TextSpan(
                text: label.substring(start), style: paragraph.text.style),
            textDirection: TextDirection.ltr,
            textScaler: paragraph.textScaler,
          )..layout();
          final lines = paragraph
              .getBoxesForSelection(
                  TextSelection(baseOffset: start, extentOffset: label.length))
              .map((box) => box.top.round())
              .toSet();
          if (paragraph.didExceedMaxLines) {
            broken++;
          } else if (word.width <= paragraph.size.width + 0.5) {
            // A label may wrap after its number, never inside a word that fits.
            checked++;
            if (lines.length != 1) broken++;
          } else if (tester
                  .getSize(find
                      .ancestor(
                          // By key: a widget finder would put the word in a
                          // failure message.
                          of: find.byKey(tile.widget.key!),
                          matching: find.byType(SizedBox))
                      .first)
                  .width <
              rowWidth - 0.5) {
            // A word wider than its tile is only acceptable at full row width.
            broken++;
          }
          word.dispose();
        }
        expect(broken, 0,
            reason: 'A mnemonic word was cut off or split across lines');
        expect(checked, greaterThan(0), reason: 'No word was measured');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        ffi.lock();
      }
    });
  }

  testWidgets('a repeated onboarding error is brought back into view',
      (tester) async {
    await _mountNarrow(
        tester, _LayoutBoundary('EMPTY'), '${directory.path}/vault.json');
    await _tap(tester, const Key('onboarding_tab_restore_mnemonic'));
    final preview = find.byKey(const Key('preview_restore_mnemonic_btn'));
    final error = find.byKey(const Key('vault_onboarding_error_text'));
    for (var attempt = 1; attempt <= 2; attempt++) {
      // Leave the action at the bottom edge, so the error area is below it.
      Scrollable.ensureVisible(tester.element(preview), alignment: 1);
      await tester.pumpAndSettle();
      if (attempt == 2) {
        expect(tester.getRect(error).top, greaterThan(900),
            reason: 'Precondition: the earlier error is out of view');
      }
      await tester.tap(preview);
      await tester.pumpAndSettle();
      final rect = tester.getRect(error);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(900),
          reason: 'Attempt $attempt must show its error without scrolling');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('320dp and 2x text keep the native backup quiz usable',
      (tester) async {
    final ffi = VaultFfiService();
    expect(ffi.init(), 0);
    ffi.lock();
    final storagePath = '${directory.path}/vault.json';
    try {
      await _mountNarrow(tester, ffi, storagePath);
      // Production native generation supplies a fresh test secret in memory.
      // Do not read, print, capture or put its words in assertion diagnostics.
      await _tap(tester, const Key('generate_mnemonic_btn'));
      await _tap(tester, const Key('start_backup_quiz_btn'));
      expect(_mnemonicWords, findsNothing);
      for (final key in [
        'quiz_first_word_field',
        'quiz_last_word_field',
        'create_passphrase_field',
        'create_pin_field',
      ]) {
        final field = find.byKey(Key(key));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.widget<TextField>(field).controller, isNotNull);
      }
      await _tap(tester, const Key('activate_created_wallet_btn'));
      final error = find.byKey(const Key('vault_onboarding_error_text'));
      expect(error, findsOneWidget);
      final rect = tester.getRect(error);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(900),
          reason: 'The error must appear where the action was, unscrolled');
      expect(File(storagePath).existsSync(), isFalse,
          reason: 'Reaching activation cannot bypass backup confirmation');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      ffi.lock();
    }
  });

  testWidgets('restoring from a scrolled form lands at the unlocked actions',
      (tester) async {
    final ffi = VaultFfiService();
    expect(ffi.init(), 0);
    ffi.lock();
    final storagePath = '${directory.path}/vault.json';
    try {
      await _mountNarrow(tester, ffi, storagePath);
      await _tap(tester, const Key('onboarding_tab_restore_mnemonic'));
      // Generate this isolated test's secret through the production native core.
      // Keep it in memory and out of assertion diagnostics.
      final generated = ffi.generateMnemonic(12);
      if (generated['status'] != 'SUCCESS' ||
          generated['mnemonic'] is! String) {
        throw StateError('Native test mnemonic generation failed');
      }
      await tester.enterText(find.byKey(const Key('restore_mnemonic_field')),
          generated['mnemonic'] as String);
      await _tap(tester, const Key('preview_restore_mnemonic_btn'));
      await _tap(tester, const Key('activate_restored_mnemonic_btn'));
      await tester.ensureVisible(
          find.byKey(const Key('activate_restored_mnemonic_btn')));
      await tester.pumpAndSettle();
      final formScroll =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      final formOffset = formScroll.position.pixels;
      expect(formOffset, greaterThan(0));
      // Validation updates within onboarding must preserve the form position.
      await tester.tap(find.byKey(const Key('activate_restored_mnemonic_btn')));
      await tester.pumpAndSettle();
      expect(tester.state<ScrollableState>(find.byType(Scrollable).first),
          same(formScroll));
      expect(formScroll.position.pixels, formOffset);
      final password = find.byKey(const Key('restore_pin_field'));
      await tester.ensureVisible(password);
      await tester.enterText(password, 'Disposable-Layout-Password-2026!');
      final confirmation =
          find.byKey(const Key('restore_pin_confirmation_field'));
      await tester.ensureVisible(confirmation);
      await tester.enterText(confirmation, 'Disposable-Layout-Password-2026!');
      final activate = find.byKey(const Key('activate_restored_mnemonic_btn'));
      await tester.ensureVisible(activate);
      await tester.pumpAndSettle();
      expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          greaterThan(0));
      await tester.tap(activate);
      await tester.pumpAndSettle();

      expect(find.text('金庫已解鎖').hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('scan_sign_request_btn')).hitTestable(),
          findsOneWidget);
      expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          0);

      // The app-bar lock must also return to the start of its new role rather
      // than retaining the position of the long public-account section.
      await tester.drag(
          find.byType(SingleChildScrollView).first, const Offset(0, -1500));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_lock_btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vault_unlock_submit_btn')).hitTestable(),
          findsOneWidget);
      expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      ffi.lock();
    }
  });
}
