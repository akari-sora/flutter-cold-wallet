import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/vault_home_screen.dart';

// Deliberately invalid BIP-39 text: UI staging never creates or imports a key.
const _placeholder = 'not-a-bip39-word another-invalid-word';
const _password = 'public-ui-test-password';
const _address = '0x0000000000000000000000000000000000000001';
const _appMismatch = '兩次輸入的 App 解鎖密碼不一致，請重新確認';
const _passphraseMismatch = '兩次輸入的 Passphrase 不一致，請重新確認';
const _exportMismatch = '兩次輸入的備份密碼不一致，請重新確認';

Map<String, dynamic> _publicAccounts() => {
      'ur_single': 'ur:crypto-multi-accounts/public-confirmation-fixture',
      'fountain_frames': <String>[],
      'evm_accounts': [
        {
          'account_index': 0,
          'derivation_path': "m/44'/60'/0'/0/0",
          'address': _address,
        }
      ],
      'btc_accounts': <dynamic>[],
    };

class _ConfirmationBoundary extends Fake implements VaultFfiService {
  _ConfirmationBoundary({this.unlocked = false});

  bool unlocked;
  int blockedSecretCalls = 0;

  @override
  int init() => 0;

  @override
  Map<String, dynamic> checkStorageStatus(String storagePath) => {
        'status': unlocked ? 'ENCRYPTED_ON_DISK' : 'EMPTY',
        'unlocked': unlocked,
        'master_fingerprint': '1234abcd',
      };

  @override
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 120}) => {
        'status': 'SUCCESS',
        'master_fingerprint': '1234abcd',
        'multi_accounts': _publicAccounts(),
      };

  // These three methods only stage the real form using invalid text and public
  // data. This class never constructs VaultFfiService or loads a native library.
  @override
  Map<String, dynamic> generateMnemonic(int wordCount) => {
        'status': 'SUCCESS',
        'mnemonic': _placeholder,
      };

  @override
  Map<String, dynamic> previewMnemonic(String phrase,
      [String passphrase = '']) {
    expect(phrase, _placeholder);
    return {
      'status': 'SUCCESS',
      'word_count': 2,
      'master_fingerprint': '1234abcd',
      'evm_account_0': {'address': _address},
      'btc_account_0': {'receive_address': 'public-placeholder'},
    };
  }

  @override
  Map<String, dynamic> previewEncryptedBackup(
      String backupJson, String backupPassword) {
    expect(backupJson, 'public-invalid-backup-placeholder');
    return {
      'status': 'SUCCESS',
      'master_fingerprint': '1234abcd',
      'multi_accounts': _publicAccounts(),
    };
  }

  Never _forbidden() {
    blockedSecretCalls++;
    throw StateError('Secret operation forbidden in public UI boundary test');
  }

  @override
  Map<String, dynamic> activateAndSaveMnemonic({
    required String phrase,
    String passphrase = '',
    required String storagePath,
    required String pinPassword,
  }) =>
      _forbidden();

  @override
  Map<String, dynamic> restoreFromEncryptedBackup({
    required String backupJson,
    required String backupPassword,
    required String storagePath,
    required String newPinPassword,
  }) =>
      _forbidden();

  @override
  Map<String, dynamic> exportEncryptedBackup(String backupPassword) =>
      _forbidden();

  @override
  bool cancel([String? handleId]) => true;

  @override
  bool lock() {
    unlocked = false;
    return true;
  }
}

Future<void> _mount(WidgetTester tester, _ConfirmationBoundary ffi) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final directory =
      Directory.systemTemp.createTempSync('fcw_public_confirmation_');
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    // The path is the verified, explicitly created test directory only.
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('fcw/platform'), (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('fcw/platform'), null));
  await tester.pumpWidget(MaterialApp(
      home: VaultHomeScreen(
          ffi: ffi, storagePath: '${directory.path}/public-fixture.json')));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

TextEditingController _controller(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!;

Future<void> _stageCreate(WidgetTester tester) async {
  await _tap(tester, 'generate_mnemonic_btn');
  await _tap(tester, 'start_backup_quiz_btn');
  await _enter(tester, 'quiz_first_word_field', 'not-a-bip39-word');
  await _enter(tester, 'quiz_last_word_field', 'another-invalid-word');
}

Future<void> _stageMnemonicRestore(WidgetTester tester) async {
  await _tap(tester, 'onboarding_tab_restore_mnemonic');
  await _enter(tester, 'restore_mnemonic_field', _placeholder);
  await _tap(tester, 'preview_restore_mnemonic_btn');
}

Future<void> _stageBackupRestore(WidgetTester tester) async {
  await _tap(tester, 'onboarding_tab_restore_backup');
  await _enter(
      tester, 'restore_backup_json_field', 'public-invalid-backup-placeholder');
  await _enter(tester, 'restore_backup_password_field', 'public-placeholder');
  await tester.ensureVisible(find.text('解密預覽並核對地址'));
  await tester.tap(find.text('解密預覽並核對地址'));
  await tester.pumpAndSettle();
}

void main() {
  for (final confirmation in [
    '',
    ' $_password',
    '$_password ',
    'public-ui-test-PASSWORD'
  ]) {
    testWidgets('create rejects App password mismatch [$confirmation]',
        (tester) async {
      final ffi = _ConfirmationBoundary();
      await _mount(tester, ffi);
      await _stageCreate(tester);
      await _enter(tester, 'create_pin_field', _password);
      await _enter(tester, 'create_pin_confirmation_field', confirmation);
      await _tap(tester, 'activate_created_wallet_btn');
      expect(find.text(_appMismatch), findsOneWidget);
      expect(ffi.blockedSecretCalls, 0);
    });
  }

  for (final values in [
    ['public-passphrase', ''],
    ['', 'stale-public-passphrase'],
    [' public-passphrase', 'public-passphrase'],
    ['\u00e9-public-passphrase', 'e\u0301-public-passphrase'],
  ]) {
    testWidgets('create requires exact optional passphrase [${values.first}]',
        (tester) async {
      final ffi = _ConfirmationBoundary();
      await _mount(tester, ffi);
      await _stageCreate(tester);
      await _enter(tester, 'create_passphrase_field', values.first);
      await _enter(tester, 'create_passphrase_confirmation_field', values.last);
      await _enter(tester, 'create_pin_field', _password);
      await _enter(tester, 'create_pin_confirmation_field', _password);
      await _tap(tester, 'activate_created_wallet_btn');
      expect(find.text(_passphraseMismatch), findsOneWidget);
      expect(ffi.blockedSecretCalls, 0);
    });
  }

  testWidgets('mnemonic restore rejects new App password mismatch',
      (tester) async {
    final ffi = _ConfirmationBoundary();
    await _mount(tester, ffi);
    await _stageMnemonicRestore(tester);
    expect(find.byKey(const Key('restore_passphrase_confirmation_field')),
        findsNothing);
    await _enter(tester, 'restore_pin_field', _password);
    await _enter(tester, 'restore_pin_confirmation_field', '$_password ');
    await _tap(tester, 'activate_restored_mnemonic_btn');
    expect(find.text(_appMismatch), findsOneWidget);
    expect(ffi.blockedSecretCalls, 0);
  });

  testWidgets('encrypted restore rejects new App password mismatch',
      (tester) async {
    final ffi = _ConfirmationBoundary();
    await _mount(tester, ffi);
    await _stageBackupRestore(tester);
    await _enter(tester, 'restore_backup_new_pin_field', _password);
    await _enter(
        tester, 'restore_backup_new_pin_confirmation_field', ' $_password');
    await _tap(tester, 'restore_backup_submit_btn');
    expect(find.text(_appMismatch), findsOneWidget);
    expect(ffi.blockedSecretCalls, 0);
  });

  testWidgets('export rejects independent backup password mismatch',
      (tester) async {
    final ffi = _ConfirmationBoundary(unlocked: true);
    await _mount(tester, ffi);
    await _tap(tester, 'export_backup_dialog_btn');
    await _enter(tester, 'export_backup_mnemonic_field', _placeholder);
    await _tap(tester, 'verify_export_backup_btn');
    await _enter(tester, 'export_backup_password_field', _password);
    await _enter(
        tester, 'export_backup_password_confirmation_field', '$_password ');
    await _tap(tester, 'generate_encrypted_backup_btn');
    expect(find.text(_exportMismatch), findsOneWidget);
    expect(ffi.blockedSecretCalls, 0);
  });

  testWidgets('backup quiz answers are obscured in the semantics tree',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final ffi = _ConfirmationBoundary();
      await _mount(tester, ffi);
      await _stageCreate(tester);
      for (final entry in {
        'quiz_first_word_field': 'not-a-bip39-word',
        'quiz_last_word_field': 'another-invalid-word',
      }.entries) {
        final finder = find.byKey(Key(entry.key));
        final field = tester.widget<TextField>(finder);
        expect(field.controller!.text, entry.value);
        expect(field.obscureText, isTrue);
        expect(field.maxLines, 1);
        expect(field.autocorrect, isFalse);
        expect(field.enableSuggestions, isFalse);
        expect(field.enableIMEPersonalizedLearning, isFalse);
        expect(field.enableInteractiveSelection, isFalse);
        // What UI dumps and accessibility services read for this field.
        final node = tester.getSemantics(
            find.descendant(of: finder, matching: find.byType(EditableText)));
        expect(node.value, isNot(contains(entry.value)));
        expect(node.value, isNotEmpty);
      }
      expect(ffi.blockedSecretCalls, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('restore previews show the master fingerprint in uppercase',
      (tester) async {
    final ffi = _ConfirmationBoundary();
    await _mount(tester, ffi);
    await _stageMnemonicRestore(tester);
    expect(find.text('主指紋：1234ABCD'), findsOneWidget);
    expect(find.textContaining('1234abcd'), findsNothing);
    await _stageBackupRestore(tester);
    expect(find.textContaining('主指紋：1234ABCD\n'), findsOneWidget);
    expect(find.textContaining('1234abcd'), findsNothing);
    expect(ffi.blockedSecretCalls, 0);
  });

  testWidgets('receive address check shows the master fingerprint in '
      'uppercase', (tester) async {
    final ffi = _ConfirmationBoundary(unlocked: true);
    await _mount(tester, ffi);
    expect(find.text('主指紋 1234ABCD'), findsOneWidget);
    await tester.ensureVisible(find.text('顯示收款 QR 並核對地址'));
    await tester.tap(find.text('顯示收款 QR 並核對地址'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('主指紋：1234ABCD')),
        findsOneWidget);
    expect(find.textContaining('1234abcd'), findsNothing);
    expect(ffi.blockedSecretCalls, 0);
  });

  for (final stage in ['create', 'mnemonic', 'backup']) {
    testWidgets('$stage confirmation clears on lifecycle lock', (tester) async {
      final ffi = _ConfirmationBoundary();
      await _mount(tester, ffi);
      final keys = <String>[];
      if (stage == 'create') {
        await _stageCreate(tester);
        keys.addAll([
          'create_passphrase_confirmation_field',
          'create_pin_confirmation_field'
        ]);
      } else if (stage == 'mnemonic') {
        await _stageMnemonicRestore(tester);
        keys.add('restore_pin_confirmation_field');
      } else {
        await _stageBackupRestore(tester);
        keys.add('restore_backup_new_pin_confirmation_field');
      }
      final controllers = <TextEditingController>[];
      for (final key in keys) {
        await _enter(tester, key, 'public-confirmation-placeholder');
        controllers.add(_controller(tester, key));
      }
      tester
          .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
          .lockForLifecycle(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(controllers.map((controller) => controller.text),
          everyElement(isEmpty));
      expect(ffi.blockedSecretCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final dismiss in ['close', 'back', 'lifecycle']) {
    testWidgets(
        'export $dismiss clears safely through reverse route transition',
        (tester) async {
      final ffi = _ConfirmationBoundary(unlocked: true);
      await _mount(tester, ffi);
      await _tap(tester, 'export_backup_dialog_btn');
      await _enter(tester, 'export_backup_password_field', _password);
      await _enter(
          tester, 'export_backup_password_confirmation_field', _password);
      final password = _controller(tester, 'export_backup_password_field');
      final confirmation =
          _controller(tester, 'export_backup_password_confirmation_field');
      if (dismiss == 'close') {
        await tester.tap(find.text('關閉'));
      } else if (dismiss == 'back') {
        Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      } else {
        tester
            .state<VaultHomeScreenState>(find.byType(VaultHomeScreen))
            .lockForLifecycle(AppLifecycleState.paused);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(password.text, isEmpty);
      expect(confirmation.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(ffi.blockedSecretCalls, 0);
    });
  }
}
