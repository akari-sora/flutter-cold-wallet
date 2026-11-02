// Run this file alone from apps/vault with its existing package configuration.
// This suite never loads native FFI: every value below is a public placeholder.
import 'dart:async';
import 'dart:io';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/ffi/vault_ffi_service.dart';
import 'package:vault/main.dart';

const _channel = MethodChannel('fcw/platform');
const _fingerprint = '1234abcd';
const _address = '0x0000000000000000000000000000000000000001';
// Deliberately invalid BIP-39 text; the fake boundary only compares it.
const _placeholder = 'not-a-bip39-word another-invalid-word';
const _password = 'public-ui-test-password';
const _backupJson = '{"public":"backup-save-feedback-fixture"}';
const _saved = '加密備份已儲存到您選取的檔案。';
const _failed = '備份儲存取消或失敗，請重試';
const _noticeKey = Key('vault_backup_save_notice');
const _saveLabel = '儲存加密備份檔';

class _BackupBoundary implements VaultFfiService {
  bool unlocked = true;
  int locks = 0;
  final forbiddenCalls = <Symbol>[];

  @override
  int init() => 0;

  @override
  bool cancel([String? handleId]) => true;

  @override
  bool lock() {
    locks++;
    unlocked = false;
    return true;
  }

  @override
  Map<String, dynamic> checkStorageStatus(String path) => {
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
        'multi_accounts': {
          'ur_single': '',
          'fountain_frames': <String>[],
          'btc_accounts': <dynamic>[],
          'evm_accounts': [
            {
              'account_index': 0,
              'derivation_path': "m/44'/60'/0'/0/0",
              'address': _address,
            },
          ],
        },
      };

  @override
  Map<String, dynamic> previewMnemonic(String phrase,
      [String passphrase = '']) {
    expect(phrase, _placeholder);
    return {
      'status': 'SUCCESS',
      'master_fingerprint': _fingerprint,
      'evm_account_0': {'address': _address},
    };
  }

  @override
  Map<String, dynamic> exportEncryptedBackup(String backupPassword) {
    expect(backupPassword, _password);
    return {'status': 'SUCCESS', 'backup_json': _backupJson};
  }

  // Unlock, activation and signing APIs are never reached by this suite.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    forbiddenCalls.add(invocation.memberName);
    throw StateError('Unexpected FFI call: ${invocation.memberName}');
  }
}

class _BackupChannel {
  final saves = <Completer<bool>>[];
  final savedJson = <String?>[];
  final forbiddenCalls = <String>[];
  int permissionRequests = 0;

  Future<dynamic> handle(MethodCall call) async {
    switch (call.method) {
      case 'saveEncryptedBackup':
        savedJson.add((call.arguments as Map)['json'] as String?);
        final save = Completer<bool>();
        saves.add(save);
        return save.future;
      case 'requestCameraPermission':
        permissionRequests++;
        return false;
      case 'cancelDeviceAuthentication':
      case 'cancelCameraPermissionRequest':
        return null;
      default:
        forbiddenCalls.add(call.method);
        throw StateError('Unexpected platform call: ${call.method}');
    }
  }
}

Future<void> _changeLifecycle(
    WidgetTester tester, AppLifecycleState target) async {
  // Follow Flutter's real transition graph, including the intermediate inactive
  // lock. AppLifecycleListener deliberately rejects resumed -> paused jumps.
  const next = <AppLifecycleState, List<AppLifecycleState>>{
    AppLifecycleState.detached: [AppLifecycleState.resumed],
    AppLifecycleState.resumed: [AppLifecycleState.inactive],
    AppLifecycleState.inactive: [
      AppLifecycleState.hidden,
      AppLifecycleState.resumed,
    ],
    AppLifecycleState.hidden: [
      AppLifecycleState.paused,
      AppLifecycleState.inactive,
    ],
    AppLifecycleState.paused: [
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ],
  };
  final current = tester.binding.lifecycleState;
  final routes = <List<AppLifecycleState>>[
    if (current != null) [current] else [target],
  ];
  final seen = <AppLifecycleState>{if (current != null) current};
  while (routes.first.last != target) {
    final route = routes.removeAt(0);
    for (final state in next[route.last]!) {
      if (seen.add(state)) routes.add([...route, state]);
    }
  }
  final route = current == null ? routes.first : routes.first.skip(1);
  for (final state in route) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pumpAndSettle();
  }
}

Future<(_BackupBoundary, _BackupChannel)> _mount(WidgetTester tester) async {
  final vault = _BackupBoundary();
  final platform = _BackupChannel();
  final directory = Directory.systemTemp.createTempSync('fcw_backup_save_');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, platform.handle);
  tester.view.physicalSize = const Size(600, 1100);
  tester.view.devicePixelRatio = 1;
  await _changeLifecycle(tester, AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final save in platform.saves) {
      if (!save.isCompleted) save.complete(false);
    }
    await tester.pumpAndSettle();
    await _changeLifecycle(tester, AppLifecycleState.resumed);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    // The path is the explicitly created test directory only.
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  await tester.pumpWidget(ColdWalletVaultApp(
    ffiOverride: vault,
    storagePathOverride: '${directory.path}/public_fixture.json',
  ));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('scan_sign_request_btn')), findsOneWidget);
  return (vault, platform);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _enter(WidgetTester tester, String key, String text) async {
  final field = find.byKey(Key(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

/// Opens the export dialog, verifies the placeholder and requests a save.
Future<void> _requestSave(WidgetTester tester, _BackupChannel platform) async {
  await _tap(tester, find.byKey(const Key('export_backup_dialog_btn')));
  await _enter(tester, 'export_backup_mnemonic_field', _placeholder);
  await _tap(tester, find.byKey(const Key('verify_export_backup_btn')));
  await _enter(tester, 'export_backup_password_field', _password);
  await _enter(tester, 'export_backup_password_confirmation_field', _password);
  await _tap(tester, find.byKey(const Key('generate_encrypted_backup_btn')));
  await _tap(tester, find.text(_saveLabel));
  expect(platform.saves, hasLength(1));
  expect(platform.savedJson, [_backupJson]);
}

FcwTone _noticeTone(WidgetTester tester) => tester
    .widget<FcwBanner>(
        find.ancestor(of: find.byKey(_noticeKey), matching: find.byType(FcwBanner)))
    .tone;

void _expectLockScreen(WidgetTester tester, _BackupBoundary vault) {
  expect(vault.unlocked, isFalse);
  expect(find.byType(AlertDialog), findsNothing);
  expect(find.byKey(const Key('vault_unlock_submit_btn')), findsOneWidget);
}

void _expectNoUnexpectedCalls(_BackupBoundary vault, _BackupChannel platform) {
  expect(vault.forbiddenCalls, isEmpty);
  expect(platform.forbiddenCalls, isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final arrival in ['while paused', 'after resume']) {
    testWidgets('a save that completes $arrival is confirmed on the lock '
        'screen and survives the return locks', (tester) async {
      final (vault, platform) = await _mount(tester);
      await _requestSave(tester, platform);

      // The system picker takes the foreground: the Vault locks and the
      // dialog closes before the native write reports back.
      await _changeLifecycle(tester, AppLifecycleState.paused);
      _expectLockScreen(tester, vault);
      if (arrival == 'while paused') platform.saves.single.complete(true);
      await tester.pumpAndSettle();
      final locksBeforeReturn = vault.locks;
      await _changeLifecycle(tester, AppLifecycleState.resumed);
      expect(vault.locks, greaterThan(locksBeforeReturn));
      if (arrival == 'after resume') {
        platform.saves.single.complete(true);
        await tester.pumpAndSettle();
      }

      _expectLockScreen(tester, vault);
      expect(find.text(_saved), findsOneWidget);
      expect(_noticeTone(tester), FcwTone.success);
      expect(find.text(_failed), findsNothing);

      // The next unlock attempt replaces the notice with its own feedback.
      await _tap(tester, find.byKey(const Key('vault_unlock_submit_btn')));
      expect(find.byKey(_noticeKey), findsNothing);
      expect(find.text('請輸入 PIN 碼 / 密碼以解鎖金庫'), findsOneWidget);
      _expectNoUnexpectedCalls(vault, platform);
    });
  }

  for (final code in ['cancelled', 'backup_io_failed']) {
    testWidgets('a $code save after the lifecycle lock keeps its error on the '
        'lock screen', (tester) async {
      final (vault, platform) = await _mount(tester);
      await _requestSave(tester, platform);
      await _changeLifecycle(tester, AppLifecycleState.paused);
      platform.saves.single.completeError(
          PlatformException(code: code, message: 'native diagnostic text'));
      await tester.pumpAndSettle();
      await _changeLifecycle(tester, AppLifecycleState.resumed);

      _expectLockScreen(tester, vault);
      expect(find.text(_failed), findsOneWidget);
      expect(_noticeTone(tester), FcwTone.danger);
      expect(find.text(_saved), findsNothing);
      expect(find.textContaining('native diagnostic'), findsNothing);

      // Preparing the camera is a new action; the stale save error goes away.
      await _tap(tester,
          find.byKey(const Key('vault_prepare_camera_permission_btn')));
      expect(platform.permissionRequests, 1);
      expect(find.byKey(_noticeKey), findsNothing);
      _expectNoUnexpectedCalls(vault, platform);
    });
  }

  for (final code in ['picker_unavailable', 'busy']) {
    testWidgets('$code before the picker opens is shown in the still-open '
        'dialog of the still-unlocked Vault', (tester) async {
      final (vault, platform) = await _mount(tester);
      await _requestSave(tester, platform);
      platform.saves.single.completeError(
          PlatformException(code: code, message: 'native diagnostic text'));
      await tester.pumpAndSettle();

      expect(vault.unlocked, isTrue);
      expect(find.byType(AlertDialog), findsOneWidget);
      final error = code == 'picker_unavailable'
          ? '無法開啟本機檔案選擇器，加密備份尚未儲存'
          : _failed;
      expect(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.text(error)),
          findsOneWidget);
      expect(find.byKey(_noticeKey), findsNothing);
      expect(find.textContaining('native diagnostic'), findsNothing);
      // The dialog keeps its generated backup, so the user can retry.
      expect(find.text(_saveLabel), findsOneWidget);
      _expectNoUnexpectedCalls(vault, platform);
    });
  }

  testWidgets('a save confirmed while the dialog is still open is shown in '
      'the dialog', (tester) async {
    final (vault, platform) = await _mount(tester);
    await _requestSave(tester, platform);
    platform.saves.single.complete(true);
    await tester.pumpAndSettle();

    expect(vault.unlocked, isTrue);
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text(_saved)),
        findsOneWidget);
    await _tap(tester, find.text('關閉'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(_saved), findsNothing);
    _expectNoUnexpectedCalls(vault, platform);
  });
}
