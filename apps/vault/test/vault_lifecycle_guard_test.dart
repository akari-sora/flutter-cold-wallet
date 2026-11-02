import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/services/vault_lifecycle_guard.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/screens/vault_home_screen.dart';
import 'package:vault/screens/review_screen.dart';

// Test mock for VaultFfiService in unit lifecycle guard tests
class MockVaultFfiService implements VaultFfiService {
  int cancelCallCount = 0;
  int lockCallCount = 0;
  String? lastCancelledHandle;

  @override
  bool cancel([String? handleId]) {
    cancelCallCount++;
    lastCancelledHandle = handleId;
    return true;
  }

  @override
  bool lock() {
    lockCallCount++;
    return true;
  }

  @override
  int init() => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('VaultLifecycleGuard tests (LIFE-02)', () {
    test(
        'Invokes cancel, lock, and security lock when app lifecycle transitions to paused',
        () {
      final mockFfi = MockVaultFfiService();
      bool lockTriggered = false;

      final guard = VaultLifecycleGuard(
        ffi: mockFfi,
        onSecurityLockTriggered: () {
          lockTriggered = true;
        },
      );

      guard.didChangeAppLifecycleState(AppLifecycleState.paused);

      expect(mockFfi.cancelCallCount, 1);
      expect(mockFfi.lockCallCount, 1);
      expect(mockFfi.lastCancelledHandle, isNull);
      expect(lockTriggered, isTrue);
    });

    test(
        'Invokes cancel, lock, and security lock when app lifecycle transitions to inactive',
        () {
      final mockFfi = MockVaultFfiService();
      bool lockTriggered = false;

      final guard = VaultLifecycleGuard(
        ffi: mockFfi,
        onSecurityLockTriggered: () {
          lockTriggered = true;
        },
      );

      guard.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(mockFfi.cancelCallCount, 1);
      expect(mockFfi.lockCallCount, 1);
      expect(lockTriggered, isTrue);
    });
  });

  group('Real VaultFfiService & Vault UI Onboarding / Storage / Signing tests',
      () {
    late VaultFfiService ffi;
    late Directory tempDir;
    late String storagePath;

    setUp(() {
      ffi = VaultFfiService();
      ffi.init();
      ffi.lock();
      tempDir = Directory.systemTemp.createTempSync('fcw_vault_test_');
      storagePath = '${tempDir.path}/vault_envelope.json';
    });

    tearDown(() {
      ffi.lock();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'CSPRNG mnemonic generation (12 & 24 words), validation, passphrase separation, encrypted storage, and backup',
        () {
      // 1. Uninitialized storage status
      final st0 = ffi.checkStorageStatus(storagePath);
      expect(st0['status'], 'EMPTY');
      expect(st0['initialized'], isFalse);

      // 2. Generate 12-word and 24-word mnemonics
      final gen12 = ffi.generateMnemonic(12);
      expect(gen12['status'], 'SUCCESS');
      final words12 = (gen12['mnemonic'] as String).split(' ');
      expect(words12.length, 12);

      final gen24 = ffi.generateMnemonic(24);
      expect(gen24['status'], 'SUCCESS');
      expect((gen24['mnemonic'] as String).split(' ').length, 24);

      // 3. Invalid word count & checksum rejected
      final badCount = ffi.previewMnemonic('abandon abandon abandon');
      expect(badCount['status'], 'ERROR');
      expect(badCount['error_code'], 'ERR_INVALID_MNEMONIC');
      expect(
          (badCount['error'] as String).toLowerCase(), contains('word count'));

      final badChecksum = ffi.previewMnemonic(
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon',
      );
      expect(badChecksum['status'], 'ERROR');
      expect(badChecksum['error_code'], 'ERR_INVALID_MNEMONIC');
      expect(
          (badChecksum['error'] as String).toLowerCase(), contains('checksum'));

      // 4. Passphrase separation changes master fingerprint and derived accounts
      const validPhrase =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final prevEmpty = ffi.previewMnemonic(validPhrase, '');
      final prevPass =
          ffi.previewMnemonic(validPhrase, 'vault-passphrase-2026');
      expect(prevEmpty['status'], 'SUCCESS');
      expect(prevPass['status'], 'SUCCESS');
      expect(prevEmpty['master_fingerprint'],
          isNot(equals(prevPass['master_fingerprint'])));
      expect(prevEmpty['evm_account_0']['address'],
          isNot(equals(prevPass['evm_account_0']['address'])));

      // 5. Activate and save with PIN/password (separate from BIP-39 passphrase)
      final act = ffi.activateAndSaveMnemonic(
        phrase: validPhrase,
        passphrase: 'vault-passphrase-2026',
        storagePath: storagePath,
        pinPassword: 'pin-password-9988',
      );
      expect(act['status'], 'SUCCESS');
      expect(act['has_passphrase_hint'], isTrue);
      final expectedFp = act['master_fingerprint'] as String;
      expect(File(storagePath).existsSync(), isTrue);

      // 6. Export encrypted backup (rejects short password < 8 chars)
      final badBackup = ffi.exportEncryptedBackup('1234');
      expect(badBackup['status'], 'ERROR');

      final goodBackup = ffi.exportEncryptedBackup('StrongBackupPass#2026');
      expect(goodBackup['status'], 'SUCCESS');
      final backupJson = goodBackup['backup_json'] as String;
      expect(backupJson.contains(validPhrase), isFalse);

      // 7. Lock vault -> export fails closed while locked
      expect(ffi.lock(), isTrue);
      final lockedExport = ffi.exportMultiAccounts();
      expect(lockedExport['status'], 'ERROR');
      expect(lockedExport['error_code'], 'ERR_VAULT_LOCKED');

      // 8. Unlock with wrong PIN fails closed
      final badUnlock = ffi.unlockFromStorage(
        storagePath: storagePath,
        pinPassword: 'Wrong-Strong-Password-2026',
      );
      expect(badUnlock['status'], 'ERROR');
      expect(badUnlock['error_code'], 'ERR_AUTH_FAILED');

      // 9. Unlock with right PIN succeeds and derives identical fingerprint
      final goodUnlock = ffi.unlockFromStorage(
        storagePath: storagePath,
        pinPassword: 'pin-password-9988',
      );
      expect(goodUnlock['status'], 'UNLOCKED');
      expect(goodUnlock['master_fingerprint'], expectedFp);

      // 10. Restore from encrypted backup to a new storage file
      final restoredPath = '${tempDir.path}/restored_envelope.json';
      ffi.lock();
      final previewBackup =
          ffi.previewEncryptedBackup(backupJson, 'StrongBackupPass#2026');
      expect(previewBackup['master_fingerprint'], expectedFp);
      expect(File(restoredPath).existsSync(), isFalse);
      expect(ffi.exportMultiAccounts()['status'], 'ERROR');
      final restored = ffi.restoreFromEncryptedBackup(
        backupJson: backupJson,
        backupPassword: 'StrongBackupPass#2026',
        storagePath: restoredPath,
        newPinPassword: 'new-Vault-password-7766',
      );
      expect(restored['status'], 'RESTORED');
      expect(restored['master_fingerprint'], expectedFp);

      // 11. Tamper storage file -> checkStorageStatus detects corruption fail-closed
      File(storagePath)
          .writeAsStringSync('{"schema_version": 999, "corrupted": true}');
      final corruptedSt = ffi.checkStorageStatus(storagePath);
      expect(corruptedSt['status'], 'STORAGE_CORRUPTED');
    });

    testWidgets(
        'VaultHomeScreen starts in EMPTY onboarding without auto-loading test mnemonic, and fails closed on corrupted storage',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VaultHomeScreen(
            ffi: ffi,
            storagePath: storagePath,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verifies onboarding screen is shown and no test mnemonic was loaded
      expect(find.textContaining('設定離線金庫'), findsOneWidget);
      expect(find.byKey(const Key('onboarding_tab_create')), findsOneWidget);
      expect(find.byKey(const Key('onboarding_tab_restore_mnemonic')),
          findsOneWidget);

      // Now simulate corrupted storage file and refresh
      File(storagePath).writeAsStringSync('{corrupted_json');
      final state =
          tester.state<VaultHomeScreenState>(find.byType(VaultHomeScreen));
      state.refreshStorageState();
      await tester.pumpAndSettle();

      expect(find.textContaining('金庫加密儲存區異常或版本不相容。'), findsOneWidget);
    });

    testWidgets(
        'ReviewScreen displays transaction details and generates eth-signature QR upon approval',
        (WidgetTester tester) async {
      const validPhrase =
          'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      ffi.activateAndSaveMnemonic(
        phrase: validPhrase,
        passphrase: '',
        storagePath: storagePath,
        pinPassword: 'test-Vault-password-1234',
      );

      // Prepare a valid Legacy EIP-155 transaction on Sepolia (11155111)
      // 47-byte RLP list (0xc0 + 47 = 0xef): nonce=0, gasPrice=20gwei, gasLimit=21000, to=0x9858effd232b4033e47d90003d41ec34ecaeda94, value=0.1 ETH, data=empty, chainId=11155111
      const rawRlpHex =
          'ef808504a817c800825208949858effd232b4033e47d90003d41ec34ecaeda9488016345785d8a00008083aa36a78080';
      final dto = ffi.prepareLegacyTx(
        sessionId: 'sess-review-test',
        requestId: '00112233445566778899aabbccddeeff',
        rawRlpHex: rawRlpHex,
        declaredChainId: 11155111,
      );
      expect(dto.isSignable, isTrue);
      expect(dto.handleId, isNotEmpty);

      await tester.pumpWidget(
        MaterialApp(
          home: ReviewScreen(
            review: dto,
            ffi: ffi,
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Sepolia'), findsWidgets);
      final approveBtn = find.byKey(const Key('vault_explicit_approve_btn'));
      expect(approveBtn, findsOneWidget);

      await tester.ensureVisible(approveBtn);
      await tester.tap(approveBtn);
      await tester.pump();

      // Should transition to signed QR view with ur:eth-signature
      expect(find.textContaining('簽署結果'), findsOneWidget);
      expect(find.textContaining('ur:eth-signature/'), findsOneWidget);
    });
  });
}
