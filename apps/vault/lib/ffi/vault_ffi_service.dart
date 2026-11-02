import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:public_models/public_models.dart';

typedef _VaultInitC = Int32 Function();
typedef _VaultInitDart = int Function();

typedef _VaultLockC = Int32 Function();
typedef _VaultLockDart = int Function();

typedef _VaultGenerateMnemonicC = Pointer<Utf8> Function(Uint32 wordCount);
typedef _VaultGenerateMnemonicDart = Pointer<Utf8> Function(int wordCount);

typedef _VaultPreviewMnemonicC = Pointer<Utf8> Function(
  Pointer<Utf8> phrase,
  Pointer<Utf8> passphrase,
);
typedef _VaultPreviewMnemonicDart = Pointer<Utf8> Function(
  Pointer<Utf8> phrase,
  Pointer<Utf8> passphrase,
);

typedef _VaultActivateAndSaveC = Pointer<Utf8> Function(
  Pointer<Utf8> phrase,
  Pointer<Utf8> passphrase,
  Pointer<Utf8> storagePath,
  Pointer<Utf8> pinPassword,
);
typedef _VaultActivateAndSaveDart = Pointer<Utf8> Function(
  Pointer<Utf8> phrase,
  Pointer<Utf8> passphrase,
  Pointer<Utf8> storagePath,
  Pointer<Utf8> pinPassword,
);

typedef _VaultCheckStorageStatusC = Pointer<Utf8> Function(
  Pointer<Utf8> storagePath,
);
typedef _VaultCheckStorageStatusDart = Pointer<Utf8> Function(
  Pointer<Utf8> storagePath,
);

typedef _VaultUnlockFromStorageC = Pointer<Utf8> Function(
  Pointer<Utf8> storagePath,
  Pointer<Utf8> pinPassword,
);
typedef _VaultUnlockFromStorageDart = Pointer<Utf8> Function(
  Pointer<Utf8> storagePath,
  Pointer<Utf8> pinPassword,
);

typedef _VaultExportMultiAccountsC = Pointer<Utf8> Function(
  Uint32 maxFragmentLen,
);
typedef _VaultExportMultiAccountsDart = Pointer<Utf8> Function(
  int maxFragmentLen,
);

typedef _VaultExportEncryptedBackupC = Pointer<Utf8> Function(
  Pointer<Utf8> backupPassword,
);
typedef _VaultExportEncryptedBackupDart = Pointer<Utf8> Function(
  Pointer<Utf8> backupPassword,
);

typedef _VaultRestoreEncryptedBackupC = Pointer<Utf8> Function(
  Pointer<Utf8> backupJson,
  Pointer<Utf8> backupPassword,
  Pointer<Utf8> storagePath,
  Pointer<Utf8> newPinPassword,
);
typedef _VaultRestoreEncryptedBackupDart = Pointer<Utf8> Function(
  Pointer<Utf8> backupJson,
  Pointer<Utf8> backupPassword,
  Pointer<Utf8> storagePath,
  Pointer<Utf8> newPinPassword,
);

typedef _VaultPrepareUrC = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> urString,
);
typedef _VaultPrepareUrDart = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> urString,
);

typedef _VaultPreparePsbtC = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> requestId,
  Pointer<Utf8> psbtUrOrHex,
);
typedef _VaultPreparePsbtDart = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> requestId,
  Pointer<Utf8> psbtUrOrHex,
);

typedef _VaultPrepareLegacyTxC = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> requestId,
  Pointer<Utf8> rawRlpHex,
  Uint64 declaredChainId,
);
typedef _VaultPrepareLegacyTxDart = Pointer<Utf8> Function(
  Pointer<Utf8> sessionId,
  Pointer<Utf8> requestId,
  Pointer<Utf8> rawRlpHex,
  int declaredChainId,
);

typedef _VaultApproveAndSignC = Pointer<Utf8> Function(Pointer<Utf8> handleId);
typedef _VaultApproveAndSignDart = Pointer<Utf8> Function(
  Pointer<Utf8> handleId,
);

typedef _VaultCancelC = Int32 Function(Pointer<Utf8> handleId);
typedef _VaultCancelDart = int Function(Pointer<Utf8> handleId);

typedef _VaultGetRequestStateC = Pointer<Utf8> Function(Pointer<Utf8> handleId);
typedef _VaultGetRequestStateDart = Pointer<Utf8> Function(
  Pointer<Utf8> handleId,
);

typedef _VaultFreeStringC = Void Function(Pointer<Utf8> s);
typedef _VaultFreeStringDart = void Function(Pointer<Utf8> s);

/// FFI Bridge for offline Cold Wallet Vault.
/// Strictly uses vault_ffi: opaque handles, policy verification, monotonic state machine,
/// CSPRNG BIP-39 onboarding, PBKDF2+AEAD encrypted storage, and real CBOR UR encoding.
class VaultFfiService {
  late final DynamicLibrary _lib;
  late final _VaultInitDart _init;
  late final _VaultLockDart _lock;
  late final _VaultGenerateMnemonicDart _generateMnemonic;
  late final _VaultPreviewMnemonicDart _previewMnemonic;
  late final _VaultActivateAndSaveDart _activateAndSave;
  late final _VaultCheckStorageStatusDart _checkStorageStatus;
  late final _VaultUnlockFromStorageDart _unlockFromStorage;
  late final _VaultExportMultiAccountsDart _exportMultiAccounts;
  _VaultExportMultiAccountsDart? _exportOkxAccounts;
  late final _VaultExportEncryptedBackupDart _exportEncryptedBackup;
  late final _VaultRestoreEncryptedBackupDart _restoreEncryptedBackup;
  late final _VaultPreviewMnemonicDart _previewBackup;
  late final _VaultPrepareUrDart _prepareUr;
  late final _VaultPreparePsbtDart _preparePsbt;
  late final _VaultPrepareLegacyTxDart _prepareTx;
  late final _VaultApproveAndSignDart _approveAndSign;
  late final _VaultCancelDart _cancel;
  late final _VaultGetRequestStateDart _getRequestState;
  late final _VaultFreeStringDart _freeString;

  VaultFfiService([DynamicLibrary? lib]) {
    _lib = lib ?? NativeLibraryLoader.loadVaultLib();
    _init = _lib
        .lookup<NativeFunction<_VaultInitC>>('vault_init')
        .asFunction<_VaultInitDart>();
    _lock = _lib
        .lookup<NativeFunction<_VaultLockC>>('vault_lock')
        .asFunction<_VaultLockDart>();
    _generateMnemonic = _lib
        .lookup<NativeFunction<_VaultGenerateMnemonicC>>(
          'vault_generate_mnemonic_json',
        )
        .asFunction<_VaultGenerateMnemonicDart>();
    _previewMnemonic = _lib
        .lookup<NativeFunction<_VaultPreviewMnemonicC>>(
          'vault_preview_mnemonic_json',
        )
        .asFunction<_VaultPreviewMnemonicDart>();
    _activateAndSave = _lib
        .lookup<NativeFunction<_VaultActivateAndSaveC>>(
          'vault_activate_and_save_mnemonic_json',
        )
        .asFunction<_VaultActivateAndSaveDart>();
    _checkStorageStatus = _lib
        .lookup<NativeFunction<_VaultCheckStorageStatusC>>(
          'vault_check_storage_status_json',
        )
        .asFunction<_VaultCheckStorageStatusDart>();
    _unlockFromStorage = _lib
        .lookup<NativeFunction<_VaultUnlockFromStorageC>>(
          'vault_unlock_from_storage_json',
        )
        .asFunction<_VaultUnlockFromStorageDart>();
    _exportMultiAccounts = _lib
        .lookup<NativeFunction<_VaultExportMultiAccountsC>>(
          'vault_export_multi_accounts_json',
        )
        .asFunction<_VaultExportMultiAccountsDart>();
    _exportEncryptedBackup = _lib
        .lookup<NativeFunction<_VaultExportEncryptedBackupC>>(
          'vault_export_encrypted_backup_json',
        )
        .asFunction<_VaultExportEncryptedBackupDart>();
    _restoreEncryptedBackup = _lib
        .lookup<NativeFunction<_VaultRestoreEncryptedBackupC>>(
          'vault_restore_from_encrypted_backup_json',
        )
        .asFunction<_VaultRestoreEncryptedBackupDart>();
    _previewBackup = _lib
        .lookup<NativeFunction<_VaultPreviewMnemonicC>>(
            'vault_preview_encrypted_backup_json')
        .asFunction<_VaultPreviewMnemonicDart>();
    _prepareUr = _lib
        .lookup<NativeFunction<_VaultPrepareUrC>>('vault_prepare_ur_request')
        .asFunction<_VaultPrepareUrDart>();
    _preparePsbt = _lib
        .lookup<NativeFunction<_VaultPreparePsbtC>>(
            'vault_prepare_psbt_request')
        .asFunction<_VaultPreparePsbtDart>();
    _prepareTx = _lib
        .lookup<NativeFunction<_VaultPrepareLegacyTxC>>(
          'vault_prepare_legacy_tx',
        )
        .asFunction<_VaultPrepareLegacyTxDart>();
    _approveAndSign = _lib
        .lookup<NativeFunction<_VaultApproveAndSignC>>('vault_approve_and_sign')
        .asFunction<_VaultApproveAndSignDart>();
    _cancel = _lib
        .lookup<NativeFunction<_VaultCancelC>>('vault_cancel')
        .asFunction<_VaultCancelDart>();
    _getRequestState = _lib
        .lookup<NativeFunction<_VaultGetRequestStateC>>(
          'vault_get_request_state',
        )
        .asFunction<_VaultGetRequestStateDart>();
    _freeString = _lib
        .lookup<NativeFunction<_VaultFreeStringC>>('vault_free_string')
        .asFunction<_VaultFreeStringDart>();
  }

  Map<String, dynamic> _readAndFreeJson(Pointer<Utf8> ptr, String fallbackErr) {
    if (ptr == nullptr) {
      return {'status': 'ERROR', 'error': fallbackErr};
    }
    try {
      final str = ptr.toDartString();
      final decoded = jsonDecode(str);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Native response must be an object');
      }
      return decoded;
    } on FormatException {
      return {
        'status': 'ERROR',
        'error_code': 'ERR_NATIVE_RESPONSE',
        'error': '原生核心回傳無法驗證的資料，操作未完成'
      };
    } finally {
      _freeString(ptr);
    }
  }

  int init() => _init();

  /// Zeroizes active in-memory KeyVault seed and revokes any active signing handle.
  bool lock() => _lock() == 0;

  /// Generates a fresh CSPRNG BIP-39 mnemonic (12 or 24 words).
  Map<String, dynamic> generateMnemonic(int wordCount) {
    final ptr = _generateMnemonic(wordCount);
    return _readAndFreeJson(
        ptr, 'Null pointer from vault_generate_mnemonic_json');
  }

  /// Validates mnemonic (word count, wordlist, checksum) and previews derived fingerprint & accounts
  /// without activating or persisting the key.
  Map<String, dynamic> previewMnemonic(String phrase,
      [String passphrase = '']) {
    final pPtr = phrase.toNativeUtf8();
    final passPtr = passphrase.toNativeUtf8();
    try {
      final resPtr = _previewMnemonic(pPtr, passPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from vault_preview_mnemonic_json',
      );
    } finally {
      _freeSecret(pPtr, phrase);
      _freeSecret(passPtr, passphrase);
    }
  }

  /// Activates a validated mnemonic, encrypts seed with [pinPassword], and atomically writes to [storagePath].
  Map<String, dynamic> activateAndSaveMnemonic({
    required String phrase,
    String passphrase = '',
    required String storagePath,
    required String pinPassword,
  }) {
    final pPtr = phrase.toNativeUtf8();
    final passPtr = passphrase.toNativeUtf8();
    final pathPtr = storagePath.toNativeUtf8();
    final pinPtr = pinPassword.toNativeUtf8();
    try {
      final resPtr = _activateAndSave(pPtr, passPtr, pathPtr, pinPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from vault_activate_and_save_mnemonic_json',
      );
    } finally {
      _freeSecret(pPtr, phrase);
      _freeSecret(passPtr, passphrase);
      calloc.free(pathPtr);
      _freeSecret(pinPtr, pinPassword);
    }
  }

  /// Checks the status of the encrypted storage envelope at [storagePath].
  Map<String, dynamic> checkStorageStatus(String storagePath) {
    final pathPtr = storagePath.toNativeUtf8();
    try {
      final resPtr = _checkStorageStatus(pathPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from vault_check_storage_status_json',
      );
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Unlocks the encrypted vault from [storagePath] using [pinPassword].
  Map<String, dynamic> unlockFromStorage({
    required String storagePath,
    required String pinPassword,
  }) {
    final pathPtr = storagePath.toNativeUtf8();
    final pinPtr = pinPassword.toNativeUtf8();
    try {
      final resPtr = _unlockFromStorage(pathPtr, pinPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from vault_unlock_from_storage_json',
      );
    } finally {
      calloc.free(pathPtr);
      _freeSecret(pinPtr, pinPassword);
    }
  }

  /// Exports the own-Wallet `crypto-multi-accounts` UR and public accounts.
  Map<String, dynamic> exportMultiAccounts({int maxFragmentLen = 0}) {
    final resPtr = _exportMultiAccounts(maxFragmentLen);
    return _readAndFreeJson(
      resPtr,
      'Null pointer from vault_export_multi_accounts_json',
    );
  }

  /// Exports the separate OKX EVM account-standard public pairing adapter.
  /// Lookup is lazy so a missing adapter cannot break own-Wallet onboarding.
  Map<String, dynamic> exportOkxAccounts({int maxFragmentLen = 0}) {
    final export = _exportOkxAccounts ??= _lib
        .lookup<NativeFunction<_VaultExportMultiAccountsC>>(
          'vault_export_okx_accounts_json',
        )
        .asFunction<_VaultExportMultiAccountsDart>();
    return _readAndFreeJson(
      export(maxFragmentLen),
      'Null pointer from vault_export_okx_accounts_json',
    );
  }

  /// Exports a password-protected AEAD JSON backup of the active vault seed.
  Map<String, dynamic> exportEncryptedBackup(String backupPassword) {
    final pwPtr = backupPassword.toNativeUtf8();
    try {
      final resPtr = _exportEncryptedBackup(pwPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from vault_export_encrypted_backup_json',
      );
    } finally {
      _freeSecret(pwPtr, backupPassword);
    }
  }

  /// Restores the vault from an encrypted JSON backup and saves to [storagePath] with [newPinPassword].
  Map<String, dynamic> restoreFromEncryptedBackup({
    required String backupJson,
    required String backupPassword,
    required String storagePath,
    required String newPinPassword,
  }) {
    final bPtr = backupJson.toNativeUtf8();
    final pwPtr = backupPassword.toNativeUtf8();
    final pathPtr = storagePath.toNativeUtf8();
    final pinPtr = newPinPassword.toNativeUtf8();
    try {
      final resPtr = _restoreEncryptedBackup(bPtr, pwPtr, pathPtr, pinPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer from vault_restore_from_encrypted_backup_json',
      );
    } finally {
      _freeSecret(bPtr, backupJson);
      _freeSecret(pwPtr, backupPassword);
      calloc.free(pathPtr);
      _freeSecret(pinPtr, newPinPassword);
    }
  }

  /// Decrypts a backup for local address verification without activating keys.
  Map<String, dynamic> previewEncryptedBackup(
      String backupJson, String password) {
    final backup = backupJson.toNativeUtf8();
    final pass = password.toNativeUtf8();
    try {
      return _readAndFreeJson(
          _previewBackup(backup, pass), 'Backup preview failed');
    } finally {
      _freeSecret(backup, backupJson);
      _freeSecret(pass, password);
    }
  }

  void _freeSecret(Pointer<Utf8> pointer, String value) {
    final length = utf8.encode(value).length;
    pointer.cast<Uint8>().asTypedList(length).fillRange(0, length, 0);
    calloc.free(pointer);
  }

  /// Ingests a real `ur:eth-sign-request/...` or `ur:crypto-psbt/...` (single UR or JSON array of fountain frames).
  PreparedReviewDto prepareUr({
    required String sessionId,
    required String urStringOrFramesJson,
  }) {
    final sPtr = sessionId.toNativeUtf8();
    final uPtr = urStringOrFramesJson.toNativeUtf8();
    try {
      final resPtr = _prepareUr(sPtr, uPtr);
      final map =
          _readAndFreeJson(resPtr, 'Null pointer from vault_prepare_ur');
      return PreparedReviewDto.fromJson(map);
    } finally {
      calloc.free(sPtr);
      calloc.free(uPtr);
    }
  }

  /// Ingests a Bitcoin PSBT (`ur:crypto-psbt/...` or raw PSBT hex).
  PreparedReviewDto preparePsbt({
    required String sessionId,
    String requestId = '',
    required String psbtUrOrHex,
    String networkHrp = 'bcrt',
  }) {
    final sPtr = sessionId.toNativeUtf8();
    final pPtr = psbtUrOrHex.toNativeUtf8();
    final hPtr = networkHrp.toNativeUtf8();
    try {
      final resPtr = _preparePsbt(sPtr, pPtr, hPtr);
      final map = _readAndFreeJson(
        resPtr,
        'Null pointer from vault_prepare_psbt_request',
      );
      return PreparedReviewDto.fromJson(map);
    } finally {
      calloc.free(sPtr);
      calloc.free(pPtr);
      calloc.free(hPtr);
    }
  }

  /// Ingests unsigned RLP transaction, validates policy, invalidates previous active handle (LIFE-01),
  /// and returns immutable PreparedReviewDto.
  PreparedReviewDto prepareLegacyTx({
    required String sessionId,
    required String requestId,
    required String rawRlpHex,
    required int declaredChainId,
  }) {
    final sPtr = sessionId.toNativeUtf8();
    final rPtr = requestId.toNativeUtf8();
    final rlpPtr = rawRlpHex.toNativeUtf8();
    try {
      final resPtr = _prepareTx(sPtr, rPtr, rlpPtr, declaredChainId);
      final map = _readAndFreeJson(
        resPtr,
        'Null pointer returned from prepare_legacy_tx',
      );
      return PreparedReviewDto.fromJson(map);
    } finally {
      calloc.free(sPtr);
      calloc.free(rPtr);
      calloc.free(rlpPtr);
    }
  }

  /// Performs user-confirmed signing.
  /// Enforces LIFE-03: transitions handle to Consumed to prevent double signing or replay.
  Map<String, dynamic> approveAndSign([String? handleId]) {
    final hPtr = handleId != null ? handleId.toNativeUtf8() : nullptr;
    try {
      final resPtr = _approveAndSign(hPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer returned from approve_and_sign',
      );
    } finally {
      if (hPtr != nullptr) calloc.free(hPtr);
    }
  }

  SignatureResultDto approveAndSignResult([String? handleId]) {
    final map = approveAndSign(handleId);
    return SignatureResultDto.fromJson(map);
  }

  /// Revokes active handle and ensures signing count is strictly 0 (LIFE-02).
  bool cancel([String? handleId]) {
    final hPtr = handleId != null ? handleId.toNativeUtf8() : nullptr;
    try {
      return _cancel(hPtr) == 0;
    } finally {
      if (hPtr != nullptr) calloc.free(hPtr);
    }
  }

  Map<String, dynamic> getRequestState([String? handleId]) {
    final hPtr = handleId != null ? handleId.toNativeUtf8() : nullptr;
    try {
      final resPtr = _getRequestState(hPtr);
      return _readAndFreeJson(
        resPtr,
        'Null pointer returned from vault_get_request_state',
      );
    } finally {
      if (hPtr != nullptr) calloc.free(hPtr);
    }
  }
}
