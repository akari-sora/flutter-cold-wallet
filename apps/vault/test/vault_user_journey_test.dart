import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/main.dart';

// These are host widget journeys through the production App and native core.
// Only the operating system's device-authentication boundary is simulated.
// Fresh generated test secrets stay in memory and never appear in assertions.
const _platform = MethodChannel('fcw/platform');

Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

final _mnemonicWords = find.byWidgetPredicate((widget) =>
    widget is Text &&
    widget.key is ValueKey<String> &&
    (widget.key! as ValueKey<String>).value.startsWith('mnemonic_word_'));

List<String> _readGeneratedTestWords(WidgetTester tester) {
  final numberedWord = RegExp(r'^([0-9]+)\. ([a-z]+)$');
  final words = <int, String>{};
  for (final label in tester.widgetList<Text>(_mnemonicWords)) {
    final match = numberedWord.firstMatch(label.data ?? '');
    if (match != null) {
      words[int.parse(match.group(1)!)] = match.group(2)!;
    }
  }
  // Do not pass the words or the widget tree to a matcher: assertion diagnostics
  // must not disclose even these disposable, randomly generated test secrets.
  if (words.length != 12 ||
      List.generate(12, (index) => index + 1)
          .any((index) => !words.containsKey(index))) {
    throw StateError('Expected a complete generated test mnemonic');
  }
  return List.generate(12, (index) => words[index + 1]!);
}

Future<List<String>> _generateAndStartQuiz(WidgetTester tester) async {
  await _tap(tester, const Key('generate_mnemonic_btn'));
  final words = _readGeneratedTestWords(tester);
  await _tap(tester, const Key('start_backup_quiz_btn'));
  expect(_mnemonicWords, findsNothing,
      reason: 'The backup quiz must hide the displayed mnemonic');
  return words;
}

Future<void> _answerQuiz(WidgetTester tester, List<String> words) async {
  await tester.enterText(
      find.byKey(const Key('quiz_first_word_field')), words.first);
  await tester.enterText(
      find.byKey(const Key('quiz_last_word_field')), words.last);
}

Future<void> _mountApp(
    WidgetTester tester, VaultFfiService ffi, String storagePath) async {
  await tester.pumpWidget(ColdWalletVaultApp(
    ffiOverride: ffi,
    storagePathOverride: storagePath,
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VaultFfiService ffi;
  late Directory temporaryDirectory;
  late String storagePath;

  setUp(() {
    ffi = VaultFfiService();
    expect(ffi.init(), 0);
    expect(ffi.lock(), isTrue);
    temporaryDirectory =
        Directory.systemTemp.createTempSync('fcw_vault_ui_journey_');
    storagePath = '${temporaryDirectory.path}/protected/vault.json';
  });

  tearDown(() {
    ffi.lock();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_platform, null);
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  testWidgets(
      'create, prove backup, persist, reopen locked, and authenticate native decrypt',
      (tester) async {
    // A host-sized surface keeps this a state/persistence test, not a mobile
    // screenshot claim. The production widgets still handle every interaction.
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var authenticated = false;
    var deviceAuthAttempts = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_platform,
        (call) async {
      if (call.method == 'authenticateWithDevice') {
        deviceAuthAttempts++;
        return authenticated;
      }
      if (call.method == 'cancelDeviceAuthentication') return null;
      throw MissingPluginException('Unexpected platform operation');
    });

    try {
      await _mountApp(tester, ffi, storagePath);
      expect(find.byKey(const Key('generate_mnemonic_btn')), findsOneWidget);
      expect(File(storagePath).existsSync(), isFalse);

      final words = await _generateAndStartQuiz(tester);
      final phrase = words.join(' ');
      const password = 'Disposable-Vault-Password-2026!';

      // Submission without the backup answers must neither create a file nor
      // expose signing keys. A strong password alone is not backup approval.
      await tester.enterText(
          find.byKey(const Key('create_pin_field')), password);
      await _tap(tester, const Key('activate_created_wallet_btn'));
      expect(File(storagePath).existsSync(), isFalse);
      expect(ffi.exportMultiAccounts()['status'], 'ERROR');
      expect(
          find.byKey(const Key('vault_onboarding_error_text')), findsOneWidget);

      await _answerQuiz(tester, words);
      // A confirmation that differs from the password must not create a vault.
      await tester.enterText(
          find.byKey(const Key('create_pin_confirmation_field')),
          '${password}x');
      await _tap(tester, const Key('activate_created_wallet_btn'));
      expect(File(storagePath).existsSync(), isFalse);
      expect(find.text('兩次輸入的 App 解鎖密碼不一致，請重新確認'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('create_pin_confirmation_field')), password);
      await _tap(tester, const Key('activate_created_wallet_btn'));
      expect(File(storagePath).existsSync(), isTrue);
      expect(find.byKey(const Key('active_vault_fingerprint_text')),
          findsOneWidget);
      expect(find.byKey(const Key('scan_sign_request_btn')), findsOneWidget);

      final publicAccounts = ffi.exportMultiAccounts();
      expect(publicAccounts['status'], 'SUCCESS');
      final expectedFingerprint = publicAccounts['master_fingerprint'];
      final expectedAddress =
          ((publicAccounts['multi_accounts'] as Map)['evm_accounts'] as List)
              .first['address'];
      expect((expectedAddress as String).startsWith('0x'), isTrue);
      final encryptedFile = File(storagePath).readAsStringSync();
      expect(encryptedFile.contains(phrase), isFalse,
          reason: 'The vault file must not contain the mnemonic');
      expect(encryptedFile.contains(password), isFalse,
          reason: 'The vault file must not contain the unlock password');

      // Dispose the App and initialize another native context. No in-memory
      // key from the creating App may make a reopened vault appear unlocked.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      ffi.lock();
      ffi = VaultFfiService();
      await _mountApp(tester, ffi, storagePath);
      expect(find.byKey(const Key('vault_unlock_submit_btn')), findsOneWidget);
      expect(find.byKey(const Key('scan_sign_request_btn')), findsNothing);
      expect(ffi.exportMultiAccounts()['status'], 'ERROR');

      // The platform declines authentication: even the correct local password
      // must leave native keys locked.
      await tester.enterText(
          find.byKey(const Key('vault_unlock_pin_field')), password);
      await _tap(tester, const Key('vault_unlock_submit_btn'));
      expect(deviceAuthAttempts, 1);
      expect(find.byKey(const Key('scan_sign_request_btn')), findsNothing);
      expect(ffi.exportMultiAccounts()['status'], 'ERROR');

      // Passing platform authentication is still insufficient with a wrong
      // password: the real native encrypted-envelope authentication must fail.
      authenticated = true;
      await tester.enterText(find.byKey(const Key('vault_unlock_pin_field')),
          'Incorrect-Disposable-Password-2026!');
      await _tap(tester, const Key('vault_unlock_submit_btn'));
      expect(deviceAuthAttempts, 2);
      expect(find.byKey(const Key('scan_sign_request_btn')), findsNothing);
      expect(ffi.exportMultiAccounts()['status'], 'ERROR');

      await tester.enterText(
          find.byKey(const Key('vault_unlock_pin_field')), password);
      await _tap(tester, const Key('vault_unlock_submit_btn'));
      expect(deviceAuthAttempts, 3);
      expect(find.byKey(const Key('scan_sign_request_btn')), findsOneWidget);
      final reopened = ffi.exportMultiAccounts();
      expect(reopened['status'], 'SUCCESS');
      expect(reopened['master_fingerprint'], expectedFingerprint);
      expect(
          ((reopened['multi_accounts'] as Map)['evm_accounts'] as List)
              .first['address'],
          expectedAddress);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  for (final event in ['cancel', 'background']) {
    testWidgets('$event before activation clears secrets and leaves no vault',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_platform,
          (call) async {
        if (call.method == 'cancelDeviceAuthentication') return null;
        throw MissingPluginException('Unexpected platform operation');
      });
      try {
        await _mountApp(tester, ffi, storagePath);
        final words = await _generateAndStartQuiz(tester);
        await _answerQuiz(tester, words);
        await tester.enterText(find.byKey(const Key('create_pin_field')),
            'Cancelled-Disposable-Password-2026!');
        await tester.enterText(find.byKey(const Key('create_passphrase_field')),
            'Disposable test passphrase');

        if (event == 'cancel') {
          final cancel = find.widgetWithText(TextButton, '取消並清除本次輸入');
          await tester.ensureVisible(cancel);
          await tester.tap(cancel);
          await tester.pumpAndSettle();
        } else {
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await tester.pumpAndSettle();
          tester.binding
              .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pumpAndSettle();
        }

        expect(File(storagePath).existsSync(), isFalse);
        expect(
            find.byKey(const Key('activate_created_wallet_btn')), findsNothing);
        expect(_mnemonicWords, findsNothing);
        expect(ffi.exportMultiAccounts()['status'], 'ERROR');
        expect(find.byKey(const Key('generate_mnemonic_btn')), findsOneWidget);
        // Generate afresh: prior quiz answers, password and passphrase must not
        // survive cancellation or the App's actual lifecycle observer.
        await _generateAndStartQuiz(tester);
        for (final key in [
          'quiz_first_word_field',
          'quiz_last_word_field',
          'create_pin_field',
          'create_passphrase_field'
        ]) {
          final controller =
              tester.widget<TextField>(find.byKey(Key(key))).controller!;
          expect(controller.text.isEmpty, isTrue,
              reason: 'A cancelled onboarding field must be cleared');
        }
        expect(File(storagePath).existsSync(), isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }
}
