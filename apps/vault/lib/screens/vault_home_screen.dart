import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:qr_ui/qr_ui.dart';
import 'package:public_models/public_models.dart';
import '../ffi/vault_ffi_service.dart';
import '../services/public_signed_result_store.dart';
import 'about_screen.dart';
import 'review_screen.dart';
import 'signed_result_screen.dart';

enum _PairingProfile { wallet, okxEvm }

class VaultHomeScreen extends StatefulWidget {
  final VaultFfiService ffi;
  final String? storagePath;
  final VoidCallback? onLockStateChanged;

  const VaultHomeScreen({
    super.key,
    required this.ffi,
    this.storagePath,
    this.onLockStateChanged,
  });

  @override
  State<VaultHomeScreen> createState() => VaultHomeScreenState();
}

class VaultHomeScreenState extends State<VaultHomeScreen> {
  final _actionErrorKey = GlobalKey();
  static const _platform = MethodChannel('fcw/platform');
  String? _storagePath;
  bool _authenticating = false;
  bool _deviceAuthOpen = false;
  bool _cameraPermissionPending = false;
  bool _checkingCameraPermission = false;
  int _cameraPermissionGeneration = 0;
  String? _cameraPermissionMessage;
  bool _cameraPermissionNeedsSettings = false;
  String? _lifecycleAuthError;
  int _authenticationGeneration = 0;
  bool _backupQuizVisible = false;
  final List<TextEditingController> _dialogSecretControllers = [];
  String? _previewPhrase,
      _previewPassphrase,
      _previewBackupJson,
      _previewBackupPassword;
  Map<String, dynamic>? _backupPreview;
  String _vaultState = 'LOADING'; // EMPTY, LOCKED, UNLOCKED, STORAGE_CORRUPTED
  String? _storageErrorCode;
  String? _storageErrorMessage;

  String _masterFingerprint = '';
  bool _hasPassphraseHint = false;
  Map<String, dynamic>? _multiAccountsData;
  Map<String, dynamic>? _okxAccountsData;
  _PairingProfile _pairingProfile = _PairingProfile.wallet;
  String? _pairingError;
  bool _useFountainPairing = false;
  int _requestCounter = 0;
  PublicSignedResultStore? _publicResultStore;
  PublicVaultIdentity? _publicIdentity;
  String? _publicResultError;

  // Onboarding state
  int _onboardingTab = 0; // 0: Create, 1: Restore Mnemonic, 2: Restore Backup
  int _createWordCount = 12;
  String? _generatedMnemonic;
  final TextEditingController _createPassphraseCtrl = TextEditingController();
  final TextEditingController _createPassphraseConfirmationCtrl =
      TextEditingController();
  final TextEditingController _quizFirstWordCtrl = TextEditingController();
  final TextEditingController _quizLastWordCtrl = TextEditingController();
  final TextEditingController _createPinCtrl = TextEditingController();
  final TextEditingController _createPinConfirmationCtrl =
      TextEditingController();

  final TextEditingController _restoreMnemonicCtrl = TextEditingController();
  final TextEditingController _restorePassphraseCtrl = TextEditingController();
  final TextEditingController _restorePinCtrl = TextEditingController();
  final TextEditingController _restorePinConfirmationCtrl =
      TextEditingController();
  Map<String, dynamic>? _restorePreview;

  final TextEditingController _backupJsonCtrl = TextEditingController();
  final TextEditingController _backupPassCtrl = TextEditingController();
  final TextEditingController _backupNewPinCtrl = TextEditingController();
  final TextEditingController _backupNewPinConfirmationCtrl =
      TextEditingController();

  final TextEditingController _unlockPinCtrl = TextEditingController();
  String? _actionErrorText;

  // The outcome of an encrypted-backup save that finished after its dialog
  // closed. The picker takes the foreground, so the lifecycle lock usually
  // runs first and may run again on return: unlike _actionError, locking
  // never clears this public notice. The next action does.
  ({bool saved, String message})? _backupSaveNotice;

  String? get _actionError => _actionErrorText;

  // Every reported onboarding or unlocked-view error, a repeat of the same
  // text included, is scrolled into view next to the action that caused it.
  set _actionError(String? message) {
    _actionErrorText = message;
    if (message == null) return;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        final target = _actionErrorKey.currentContext;
        if (!mounted || target == null) return;
        Scrollable.ensureVisible(target,
            duration: const Duration(milliseconds: 200),
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      })
      // Also when assigned outside setState, the reveal runs on the next frame.
      ..ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    _restoreMnemonicCtrl.addListener(_invalidateRestorePreview);
    _restorePassphraseCtrl.addListener(_invalidateRestorePreview);
    _backupJsonCtrl.addListener(_invalidateBackupPreview);
    _backupPassCtrl.addListener(_invalidateBackupPreview);
    if (widget.ffi.init() != 0) throw StateError('原生核心初始化失敗');
    if (widget.storagePath != null) {
      _storagePath = widget.storagePath;
      refreshStorageState();
    } else {
      _loadPrivateStoragePath();
    }
  }

  Future<void> _loadPrivateStoragePath() async {
    try {
      final directory =
          await _platform.invokeMethod<String>('storageDirectory');
      if (directory == null || directory.trim().isEmpty) {
        throw StateError('No private storage directory');
      }
      if (!mounted) return;
      _storagePath = '$directory/vault_protected_envelope.json';
      refreshStorageState();
    } catch (_) {
      if (mounted) {
        setState(() {
          _vaultState = 'STORAGE_CORRUPTED';
          _storageErrorMessage = '無法取得受保護的本機儲存目錄，金庫未啟用';
        });
      }
    }
  }

  bool _validPassword(String value) =>
      value.length >= 12 &&
      value.length <= 1024 &&
      !RegExp(r'^\d+$').hasMatch(value);
  static const _passwordHint = '請使用至少 12 字元且非全數字的密碼；這與助記詞 Passphrase 不同';
  static const _passwordMismatch = '兩次輸入的 App 解鎖密碼不一致，請重新確認';
  static const _passphraseMismatch = '兩次輸入的 Passphrase 不一致，請重新確認';
  List<TextEditingController> get _secretControllers => [
        _createPassphraseCtrl,
        _createPassphraseConfirmationCtrl,
        _quizFirstWordCtrl,
        _quizLastWordCtrl,
        _createPinCtrl,
        _createPinConfirmationCtrl,
        _restoreMnemonicCtrl,
        _restorePassphraseCtrl,
        _restorePinCtrl,
        _restorePinConfirmationCtrl,
        _backupJsonCtrl,
        _backupPassCtrl,
        _backupNewPinCtrl,
        _backupNewPinConfirmationCtrl,
        _unlockPinCtrl,
        ..._dialogSecretControllers
      ];

  void _clearSecrets() {
    _resetPublicPairing();
    for (final controller in _secretControllers) {
      controller.clear();
    }
    _generatedMnemonic = null;
    _backupQuizVisible = false;
    _restorePreview = null;
    _previewPhrase = null;
    _previewPassphrase = null;
    _backupPreview = null;
    _previewBackupJson = null;
    _previewBackupPassword = null;
    _actionError = null;
  }

  void _invalidateRestorePreview() {
    if (_restorePreview != null) {
      setState(() {
        _restorePreview = null;
        _previewPhrase = null;
        _previewPassphrase = null;
      });
    }
  }

  void _invalidateBackupPreview() {
    if (_backupPreview != null) {
      setState(() {
        _backupPreview = null;
        _previewBackupJson = null;
        _previewBackupPassword = null;
      });
    }
  }

  @override
  void dispose() {
    _cameraPermissionGeneration++;
    _cancelCameraPermissionRequest();
    _authenticationGeneration++;
    _cancelDeviceAuthentication();
    _restoreMnemonicCtrl.removeListener(_invalidateRestorePreview);
    _restorePassphraseCtrl.removeListener(_invalidateRestorePreview);
    _backupJsonCtrl.removeListener(_invalidateBackupPreview);
    _backupPassCtrl.removeListener(_invalidateBackupPreview);
    _clearSecrets();
    _createPassphraseCtrl.dispose();
    _createPassphraseConfirmationCtrl.dispose();
    _quizFirstWordCtrl.dispose();
    _quizLastWordCtrl.dispose();
    _createPinCtrl.dispose();
    _createPinConfirmationCtrl.dispose();
    _restoreMnemonicCtrl.dispose();
    _restorePassphraseCtrl.dispose();
    _restorePinCtrl.dispose();
    _restorePinConfirmationCtrl.dispose();
    _backupJsonCtrl.dispose();
    _backupPassCtrl.dispose();
    _backupNewPinCtrl.dispose();
    _backupNewPinConfirmationCtrl.dispose();
    _unlockPinCtrl.dispose();
    super.dispose();
  }

  void refreshStorageState() {
    _resetPublicPairing();
    _ensurePublicResultStore();
    final status = widget.ffi.checkStorageStatus(_storagePath!);
    final st = status['status'] as String? ?? 'EMPTY';
    final unlocked = status['unlocked'] as bool? ?? false;

    if (st == 'STORAGE_CORRUPTED') {
      setState(() {
        _vaultState = 'STORAGE_CORRUPTED';
        _storageErrorCode = status['error_code'] as String?;
        _storageErrorMessage = status['error'] as String?;
        _multiAccountsData = null;
      });
      return;
    }

    if (st == 'ENCRYPTED_ON_DISK') {
      _masterFingerprint = status['master_fingerprint'] as String? ?? '';
      _hasPassphraseHint = status['has_passphrase_hint'] as bool? ?? false;
      if (unlocked) {
        final exp = widget.ffi.exportMultiAccounts(maxFragmentLen: 0);
        if (exp['status'] == 'SUCCESS') {
          setState(() {
            _vaultState = 'UNLOCKED';
            _masterFingerprint =
                exp['master_fingerprint'] as String? ?? _masterFingerprint;
            _hasPassphraseHint =
                exp['has_passphrase_hint'] as bool? ?? _hasPassphraseHint;
            _multiAccountsData = exp['multi_accounts'] as Map<String, dynamic>?;
            _adoptPublicIdentity();
            _actionError = null;
          });
          return;
        }
      }
      setState(() {
        _vaultState = 'LOCKED';
        _multiAccountsData = null;
        final saved = _publicResultStore?.activeIdentity;
        _publicIdentity = saved?.fingerprint == _masterFingerprint.toLowerCase()
            ? saved
            : null;
      });
      return;
    }

    setState(() {
      _vaultState = 'EMPTY';
      _multiAccountsData = null;
      _publicIdentity = null;
    });
  }

  void _cancelDeviceAuthentication() {
    unawaited(_platform
        .invokeMethod<void>('cancelDeviceAuthentication')
        .catchError((_) {}));
  }

  void lockForLifecycle(AppLifecycleState? reason) {
    final preservePendingAuthentication =
        _deviceAuthOpen && reason == AppLifecycleState.inactive;
    final explainBackground =
        _deviceAuthOpen && reason != AppLifecycleState.inactive;
    if (explainBackground) {
      _deviceAuthOpen = false;
      _lifecycleAuthError = '應用程式已離開前景，請重新驗證，金庫維持鎖定';
    }
    lockVault(
      preservePendingAuthentication: preservePendingAuthentication,
      preservePendingCameraPermission:
          _cameraPermissionPending && reason == AppLifecycleState.inactive,
    );
    if (_lifecycleAuthError != null && mounted) {
      setState(() => _actionError = _lifecycleAuthError);
    }
  }

  void lockVault({
    bool preservePendingAuthentication = false,
    bool preservePendingCameraPermission = false,
  }) {
    if (!preservePendingCameraPermission) {
      _cameraPermissionGeneration++;
      _cameraPermissionPending = false;
      _cameraPermissionMessage = null;
      _cameraPermissionNeedsSettings = false;
      _cancelCameraPermissionRequest();
    }
    if (!preservePendingAuthentication) {
      _authenticationGeneration++;
      _cancelDeviceAuthentication();
    }
    widget.ffi.cancel(null);
    widget.ffi.lock();
    _clearSecrets();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    if (_storagePath != null) refreshStorageState();
    widget.onLockStateChanged?.call();
  }

  void _handleGenerateMnemonic() {
    final res = widget.ffi.generateMnemonic(_createWordCount);
    if (res['status'] == 'SUCCESS') {
      setState(() {
        _backupQuizVisible = false;
        _generatedMnemonic = res['mnemonic'] as String?;
        _quizFirstWordCtrl.clear();
        _quizLastWordCtrl.clear();
        _actionError = null;
      });
    } else {
      setState(() {
        _actionError = res['error'] as String? ?? '助記詞生成失敗';
      });
    }
  }

  void _handleActivateCreatedWallet() {
    final phrase = _generatedMnemonic;
    if (phrase == null || phrase.isEmpty || !_backupQuizVisible) {
      setState(() => _actionError = '請先產生助記詞');
      return;
    }
    final words = phrase.split(' ');
    final firstExpected = words.first.trim().toLowerCase();
    final lastExpected = words.last.trim().toLowerCase();

    if (_quizFirstWordCtrl.text.trim().toLowerCase() != firstExpected ||
        _quizLastWordCtrl.text.trim().toLowerCase() != lastExpected) {
      setState(() {
        _actionError = '備份抽考未通過：請正確輸入第 1 個單字與第 ${words.length} 個單字以確認您已抄寫助記詞';
      });
      return;
    }

    final pin = _createPinCtrl.text;
    if (!_validPassword(pin)) {
      setState(() => _actionError = _passwordHint);
      return;
    }
    if (pin != _createPinConfirmationCtrl.text) {
      setState(() => _actionError = _passwordMismatch);
      return;
    }
    if (_createPassphraseCtrl.text != _createPassphraseConfirmationCtrl.text) {
      setState(() => _actionError = _passphraseMismatch);
      return;
    }

    if (!_ensureStorageParentExists()) return;
    final res = widget.ffi.activateAndSaveMnemonic(
      phrase: phrase,
      passphrase: _createPassphraseCtrl.text,
      storagePath: _storagePath!,
      pinPassword: pin,
    );

    if (res['status'] == 'SUCCESS') {
      setState(() {
        _clearSecrets();
        _vaultState = 'UNLOCKED';
        _masterFingerprint = res['master_fingerprint'] as String? ?? '';
        _hasPassphraseHint = res['has_passphrase_hint'] as bool? ?? false;
        _multiAccountsData = res['multi_accounts'] as Map<String, dynamic>?;
        _adoptPublicIdentity();
        _actionError = null;
      });
    } else {
      setState(() {
        _actionError = res['error'] as String? ?? '啟用並加密儲存失敗';
      });
    }
  }

  void _handlePreviewRestoreMnemonic() {
    final phrase = _restoreMnemonicCtrl.text;
    final pass = _restorePassphraseCtrl.text;
    final res = widget.ffi.previewMnemonic(phrase, pass);
    if (res['status'] == 'SUCCESS') {
      setState(() {
        _restorePreview = res;
        _previewPhrase = phrase;
        _previewPassphrase = pass;
        _actionError = null;
      });
    } else {
      setState(() {
        _restorePreview = null;
        _actionError =
            '[${res['error_code'] ?? 'ERR_INVALID_MNEMONIC'}] ${res['error'] ?? '助記詞驗證失敗'}';
      });
    }
  }

  void _handleActivateRestoredMnemonic() {
    if (_restorePreview == null ||
        _previewPhrase != _restoreMnemonicCtrl.text ||
        _previewPassphrase != _restorePassphraseCtrl.text) {
      setState(() => _actionError = '請先點擊「預覽並驗證助記詞」確認主指紋與地址');
      return;
    }
    final pin = _restorePinCtrl.text;
    if (!_validPassword(pin)) {
      setState(() => _actionError = _passwordHint);
      return;
    }
    if (pin != _restorePinConfirmationCtrl.text) {
      setState(() => _actionError = _passwordMismatch);
      return;
    }
    if (!_ensureStorageParentExists()) return;
    final res = widget.ffi.activateAndSaveMnemonic(
      phrase: _restoreMnemonicCtrl.text.trim(),
      passphrase: _restorePassphraseCtrl.text,
      storagePath: _storagePath!,
      pinPassword: pin,
    );
    if (res['status'] == 'SUCCESS') {
      setState(() {
        _clearSecrets();
        _vaultState = 'UNLOCKED';
        _masterFingerprint = res['master_fingerprint'] as String? ?? '';
        _hasPassphraseHint = res['has_passphrase_hint'] as bool? ?? false;
        _multiAccountsData = res['multi_accounts'] as Map<String, dynamic>?;
        _adoptPublicIdentity();
        _actionError = null;
      });
    } else {
      setState(() {
        _actionError = res['error'] as String? ?? '助記詞還原失敗';
      });
    }
  }

  void _handlePreviewEncryptedBackup() {
    final backup = _backupJsonCtrl.text;
    final password = _backupPassCtrl.text;
    final result = widget.ffi.previewEncryptedBackup(backup, password);
    setState(() {
      if (result['status'] == 'SUCCESS') {
        _backupPreview = result;
        _previewBackupJson = backup;
        _previewBackupPassword = password;
        _actionError = null;
      } else {
        _backupPreview = null;
        _actionError = '備份驗證失敗：${result['error'] ?? '格式或密碼錯誤'}';
      }
    });
  }

  Future<void> _readEncryptedBackup() async {
    try {
      final json = await _platform.invokeMethod<String>('readEncryptedBackup');
      if (mounted && json != null) setState(() => _backupJsonCtrl.text = json);
    } catch (_) {
      if (mounted) setState(() => _actionError = '備份檔案未匯入，請重新選取');
    }
  }

  void _handleRestoreEncryptedBackup() {
    final bJson = _backupJsonCtrl.text,
        bPass = _backupPassCtrl.text,
        newPin = _backupNewPinCtrl.text;
    if (_backupPreview == null ||
        bJson != _previewBackupJson ||
        bPass != _previewBackupPassword) {
      setState(() => _actionError = '請先解密預覽，核對還原地址後再確認啟用');
      return;
    }
    if (!_validPassword(newPin)) {
      setState(() => _actionError = _passwordHint);
      return;
    }
    if (newPin != _backupNewPinConfirmationCtrl.text) {
      setState(() => _actionError = _passwordMismatch);
      return;
    }
    final res = widget.ffi.restoreFromEncryptedBackup(
        backupJson: bJson,
        backupPassword: bPass,
        storagePath: _storagePath!,
        newPinPassword: newPin);
    if (res['status'] == 'RESTORED') {
      _clearSecrets();
      refreshStorageState();
    } else {
      setState(() => _actionError = '備份還原失敗：${res['error'] ?? '請檢查檔案與密碼'}');
    }
  }

  String _deviceAuthenticationError(PlatformException error) {
    // Only native messages defined by our platform adapters may reach the UI.
    // Other exception messages/details can contain platform diagnostic data.
    const messagesByCode = {
      'device_not_secure': ['請先設定裝置鎖定密碼', '請先設定可用的裝置鎖定密碼'],
      'authentication_unavailable': [
        '無法執行裝置驗證',
        '此裝置沒有可用的生物識別或鎖定密碼驗證',
        '此版本需 Android 9 以上的安全裝置驗證',
        '無法建立裝置驗證保護',
        '無法讀取裝置驗證保護'
      ],
      'cancelled': ['已取消裝置驗證', '金庫視窗已關閉'],
      'backgrounded': ['應用程式已離開前景，請重新驗證'],
      'timeout': ['裝置驗證逾時，請重試'],
      'authentication_failed': ['裝置驗證未完成，金庫仍鎖定'],
    };
    final allowed = messagesByCode[error.code];
    if (allowed == null) return '無法完成裝置身分驗證，金庫維持鎖定';
    final message =
        allowed.contains(error.message) ? error.message! : allowed.first;
    return error.code == 'authentication_failed' ? message : '$message，金庫維持鎖定';
  }

  Future<void> _handleUnlockWithPin() async {
    if (_authenticating || _cameraPermissionPending) return;
    if (_backupSaveNotice != null) setState(() => _backupSaveNotice = null);
    final pin = _unlockPinCtrl.text;
    if (pin.isEmpty) {
      setState(() => _actionError = '請輸入 PIN 碼 / 密碼以解鎖金庫');
      return;
    }
    _authenticating = true;
    _deviceAuthOpen = true;
    _lifecycleAuthError = null;
    final generation = ++_authenticationGeneration;
    try {
      final authenticated =
          await _platform.invokeMethod<bool>('authenticateWithDevice');
      if (!mounted || generation != _authenticationGeneration) return;
      if (authenticated != true) {
        setState(() => _actionError = '裝置驗證取消或未通過，金庫維持鎖定');
        return;
      }
      _deviceAuthOpen = false;
    } on PlatformException catch (error) {
      if (mounted && generation == _authenticationGeneration) {
        setState(() => _actionError = _deviceAuthenticationError(error));
      }
      return;
    } catch (_) {
      if (mounted && generation == _authenticationGeneration) {
        setState(() => _actionError = '無法完成裝置身分驗證，金庫維持鎖定');
      }
      return;
    } finally {
      _authenticating = false;
    }
    final res = widget.ffi.unlockFromStorage(
      storagePath: _storagePath!,
      pinPassword: pin,
    );
    if (res['status'] == 'UNLOCKED') {
      setState(() {
        _resetPublicPairing();
        _unlockPinCtrl.clear();
        _vaultState = 'UNLOCKED';
        _masterFingerprint = res['master_fingerprint'] as String? ?? '';
        _hasPassphraseHint = res['has_passphrase_hint'] as bool? ?? false;
        _multiAccountsData = res['multi_accounts'] as Map<String, dynamic>?;
        _adoptPublicIdentity();
        _actionError = null;
      });
      widget.onLockStateChanged?.call();
    } else {
      setState(() {
        final code = res['error_code'] ?? 'ERR_AUTH_FAILED';
        _actionError = code == 'ERR_AUTH_FAILED'
            ? '[ERR_AUTH_FAILED] App 解鎖密碼錯誤或金庫儲存遭竄改，金庫維持鎖定'
            : '[$code] ${res['error'] ?? '密碼錯誤或儲存遭竄改'}';
      });
    }
  }

  bool _ensureStorageParentExists() {
    try {
      final parent = File(_storagePath!).parent;
      if (!parent.existsSync()) {
        parent.createSync(recursive: true);
      }
      return true;
    } catch (_) {
      setState(() => _actionError = '無法建立私密儲存目錄，金庫未啟用');
      return false;
    }
  }

  void ingestSignRequestUr(String urOrFramesJson) {
    if (_vaultState != 'UNLOCKED') return;
    widget.ffi.cancel(null);
    _requestCounter++;
    final sessId = 'session-$_requestCounter';
    final clean = urOrFramesJson.trim();

    final review = widget.ffi.prepareUr(
      sessionId: sessId,
      urStringOrFramesJson: clean,
    );

    final identity = _publicIdentity;
    final store = _publicResultStore;
    if (review.isSignable) {
      if (identity == null || store == null) {
        widget.ffi.cancel(review.handleId);
        setState(() => _publicResultError = '無法核對公開簽署紀錄，禁止簽署。');
        return;
      }
      final cached = store.lookup(identity, review);
      if (cached.kind != PublicResultLookupKind.newRequest) {
        widget.ffi.cancel(review.handleId);
        if (cached.kind == PublicResultLookupKind.available) {
          _showPublicResult(cached.result!);
        } else {
          setState(() => _publicResultError = cached.error);
        }
        return;
      }
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ReviewScreen(
          review: review,
          ffi: widget.ffi,
          beforeSigning: (approvedReview) {
            if (_vaultState != 'UNLOCKED' ||
                identity == null ||
                _publicIdentity?.key != identity.key ||
                store == null) {
              return '金庫已鎖定或公開身分已改變，禁止簽署。';
            }
            final error = store.reserve(identity, approvedReview);
            if (mounted && error != null) {
              setState(() => _publicResultError = error);
            }
            return error;
          },
          onSignedResult: (approvedReview, result) {
            final error = store!.complete(identity!, approvedReview, result);
            if (mounted) setState(() => _publicResultError = error);
            return error;
          },
        ),
      ),
    );
  }

  void _ensurePublicResultStore() {
    if (_publicResultStore != null || _storagePath == null) return;
    final store =
        PublicSignedResultStore('$_storagePath.public_signed_results.json');
    store.load();
    _publicResultStore = store;
    _publicResultError = store.error;
  }

  void _adoptPublicIdentity() {
    _ensurePublicResultStore();
    try {
      _publicIdentity = PublicVaultIdentity.fromAccounts(
          _masterFingerprint, _multiAccountsData!);
      _publicResultError = _publicResultStore!.activate(_publicIdentity!);
    } catch (_) {
      _publicIdentity = null;
      _publicResultError = '無法核對金庫公開身分；簽署結果保存功能未啟用。';
    }
  }

  void _showPublicResult(SignatureResultDto result) {
    final metadata = _publicResultStore?.metadataFor(result);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SignedResultScreen(
        result: result,
        persistenceError: _publicResultError,
        keysRemainLocked: _vaultState != 'UNLOCKED',
        requestId: metadata?.requestId,
        signingDigest: metadata?.signingDigest,
        chainId: metadata?.chainId,
      ),
    ));
  }

  Widget _buildPublicResultAccess() {
    final identity = _publicIdentity;
    final results = identity == null
        ? const <SignatureResultDto>[]
        : _publicResultStore?.resultsFor(identity) ??
            const <SignatureResultDto>[];
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: FcwSpace.xl),
      if (_publicResultError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: FcwSpace.sm),
          child: Text(_publicResultError!,
              key: const Key('public_result_store_error'),
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      if (results.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: FcwSpace.sm),
          child: Text('最近已完成的簽署結果（公開資料）',
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      OutlinedButton.icon(
        key: const Key('show_public_signed_result_btn'),
        icon: const Icon(Icons.qr_code_2),
        label: Text(
            _vaultState == 'UNLOCKED' ? '顯示已簽結果（不重新簽署）' : '顯示已簽結果（私鑰保持鎖定）'),
        onPressed:
            results.isEmpty ? null : () => _showPublicResult(results.first),
      ),
      if (results.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: FcwSpace.sm),
          child: Text('尚無可重顯示的已簽結果。',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      if (identity != null &&
          (_publicResultStore?.hasUnavailableFor(identity) ?? false))
        const Text('部分簽署結果無法取回或待查，請查原交易；本機不會重新簽署。',
            key: Key('public_result_unavailable')),
      for (var index = 1; index < results.length; index++)
        Padding(
          padding: const EdgeInsets.only(top: FcwSpace.sm),
          child: TextButton(
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.all(FcwSpace.md),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(FcwRadius.card),
                    side: BorderSide(color: theme.colorScheme.outlineVariant)),
                textStyle: theme.textTheme.bodyMedium,
              ),
              onPressed: () => _showPublicResult(results[index]),
              child: Text(_olderPublicResultLabel(results[index], index + 1))),
        ),
    ]);
  }

  String _olderPublicResultLabel(SignatureResultDto result, int ordinal) {
    final metadata = _publicResultStore?.metadataFor(result);
    if (metadata == null) return '較早的已完成公開結果 $ordinal（識別資訊未提供）';
    final network = metadata.chainId == 0
        ? 'Bitcoin regtest'
        : 'EVM Chain ID ${metadata.chainId}';
    return '較早的已完成公開結果 $ordinal · $network\n請求 ID：${metadata.requestId}';
  }

  void _cancelCameraPermissionRequest() {
    unawaited(_platform
        .invokeMethod<void>('cancelCameraPermissionRequest')
        .catchError((_) {}));
  }

  Future<void> _prepareCameraPermission() async {
    if (_cameraPermissionPending) return;
    // Never retain decrypted keys or secret UI while the system permission
    // activity owns focus. Permission completion only updates this public UI.
    lockVault();
    final generation = ++_cameraPermissionGeneration;
    setState(() {
      _cameraPermissionPending = true;
      _cameraPermissionMessage = null;
      _cameraPermissionNeedsSettings = false;
      _backupSaveNotice = null;
    });
    try {
      final granted =
          await _platform.invokeMethod<bool>('requestCameraPermission') ??
              false;
      if (!mounted || generation != _cameraPermissionGeneration) return;
      setState(() {
        _cameraPermissionPending = false;
        _cameraPermissionMessage =
            granted ? '相機權限已允許，請重新驗證解鎖後開始掃描。' : '相機權限未允許，金庫保持鎖定，可重試準備相機權限。';
      });
    } catch (error) {
      if (!mounted || generation != _cameraPermissionGeneration) return;
      // Android denies without a dialog once the user chose "don't ask
      // again"; only the app's system settings page can grant it then.
      final needsSettings = error is PlatformException &&
          error.code == 'camera_permission_permanently_denied';
      setState(() {
        _cameraPermissionPending = false;
        _cameraPermissionNeedsSettings = needsSettings;
        _cameraPermissionMessage = needsSettings
            ? '相機權限未允許，系統可能不會再顯示授權視窗（例如曾選擇「不再詢問」）。請開啟系統設定，在本 App 的「權限」中允許相機，再回來重新驗證解鎖。金庫保持鎖定。'
            : '無法取得相機權限，金庫保持鎖定。請稍後重試。';
      });
    }
  }

  Future<void> _openAppSettings() async {
    // Leaving for Settings locks the Vault like any other foreground change.
    try {
      if (await _platform.invokeMethod<bool>('openAppSettings') == true) return;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _cameraPermissionNeedsSettings = false;
      _cameraPermissionMessage =
          '無法開啟系統設定。請手動前往系統設定的應用程式頁面，允許本 App 使用相機，再回來重新驗證解鎖。';
    });
  }

  Future<void> _scanSignRequest() async {
    if (_vaultState != 'UNLOCKED' ||
        _checkingCameraPermission ||
        _cameraPermissionPending) {
      return;
    }
    final generation = _authenticationGeneration;
    setState(() {
      _actionError = null;
      _backupSaveNotice = null;
    });
    if (defaultTargetPlatform == TargetPlatform.android) {
      setState(() => _checkingCameraPermission = true);
      bool granted;
      try {
        granted =
            await _platform.invokeMethod<bool>('hasCameraPermission') ?? false;
      } catch (_) {
        if (mounted && generation == _authenticationGeneration) {
          setState(() => _actionError = '無法確認相機權限，請鎖定金庫後準備相機權限。');
        }
        return;
      } finally {
        if (mounted) setState(() => _checkingCameraPermission = false);
      }
      if (!mounted ||
          generation != _authenticationGeneration ||
          _vaultState != 'UNLOCKED') {
        return;
      }
      if (!granted) {
        await _prepareCameraPermission();
        return;
      }
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AirGapScanner(
          expectedType: 'eth-sign-request,crypto-psbt',
          title: '掃描待簽交易',
          onPayloadComplete: (_) {},
          onRawUrComplete: (urOrFramesJson) {
            Navigator.of(context).pop();
            ingestSignRequestUr(urOrFramesJson);
          },
        ),
      ),
    );
  }

  Future<void> _showExportBackupDialog() async {
    final passCtrl = TextEditingController(),
        passConfirmationCtrl = TextEditingController(),
        mnemonicCtrl = TextEditingController(),
        mnemonicPassCtrl = TextEditingController();
    final controllers = [
      passCtrl,
      passConfirmationCtrl,
      mnemonicCtrl,
      mnemonicPassCtrl
    ];
    _dialogSecretControllers.addAll(controllers);
    bool backupVerified = false;
    String? exportedJson;
    String? dialogErr;
    String? dialogNotice;
    setState(() => _backupSaveNotice = null);

    late final DialogRoute<void> route;
    route = DialogRoute<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('匯出加密備份'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '先重新驗證紙本助記詞與原 Passphrase。加密備份僅儲存至您選取的檔案。',
                ),
                const SizedBox(height: 12),
                TextField(
                    key: const Key('export_backup_mnemonic_field'),
                    controller: mnemonicCtrl,
                    enableInteractiveSelection: false,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: '紙本助記詞')),
                TextField(
                    key: const Key('export_backup_passphrase_field'),
                    controller: mnemonicPassCtrl,
                    enableInteractiveSelection: false,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Passphrase',
                        helperText: '原 BIP-39 Passphrase，沒有則留空。',
                        helperMaxLines: 6)),
                TextButton(
                    key: const Key('verify_export_backup_btn'),
                    onPressed: () {
                      final preview = widget.ffi.previewMnemonic(
                          mnemonicCtrl.text.trim(), mnemonicPassCtrl.text);
                      final accounts =
                          _multiAccountsData?['evm_accounts'] as List?;
                      final active = accounts != null && accounts.isNotEmpty
                          ? accounts.first as Map
                          : null;
                      final address =
                          (preview['evm_account_0'] as Map?)?['address'];
                      setDialogState(() {
                        backupVerified = preview['status'] == 'SUCCESS' &&
                            preview['master_fingerprint'] ==
                                _masterFingerprint &&
                            active?['address'] != null &&
                            active?['address'] == address;
                        dialogErr = backupVerified
                            ? null
                            : '備份與此金庫不一致，請核對助記詞及 Passphrase';
                      });
                      mnemonicCtrl.clear();
                      mnemonicPassCtrl.clear();
                    },
                    child: Text(backupVerified ? '紙本備份已重新驗證' : '重新驗證備份')),
                TextField(
                  enableInteractiveSelection: false,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  key: const Key('export_backup_password_field'),
                  controller: passCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '備份密碼',
                    helperText: '請使用獨立密碼，至少 12 字元且不可全部為數字。',
                    helperMaxLines: 8,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                _confirmationField(
                  key: const Key('export_backup_password_confirmation_field'),
                  controller: passConfirmationCtrl,
                  label: '再次輸入備份密碼',
                ),
                if (dialogErr != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    dialogErr!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ],
                if (dialogNotice != null) ...[
                  const SizedBox(height: 8),
                  FcwBanner(
                    tone: FcwTone.success,
                    content: Text(dialogNotice!,
                        key: const Key('export_backup_saved_notice')),
                  ),
                ],
                if (exportedJson != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '加密備份 JSON，請妥善保存：',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    key: const Key('exported_backup_json_text'),
                    exportedJson!,
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('關閉'),
            ),
            if (exportedJson != null)
              OutlinedButton.icon(
                  icon: const Icon(Icons.save_alt),
                  label: const Text('儲存加密備份檔'),
                  onPressed: () async {
                    String? error;
                    try {
                      final saved = await _platform.invokeMethod<bool>(
                          'saveEncryptedBackup', {'json': exportedJson});
                      if (saved != true) error = '備份檔案尚未儲存';
                    } on PlatformException catch (e) {
                      error = e.code == 'picker_unavailable'
                          ? '無法開啟本機檔案選擇器，加密備份尚未儲存'
                          : '備份儲存取消或失敗，請重試';
                    } catch (_) {
                      error = '備份儲存取消或失敗，請重試';
                    }
                    const savedMessage = '加密備份已儲存到您選取的檔案。';
                    // An opened picker locks the Vault and closes this dialog
                    // before the result arrives; a picker that never opened
                    // leaves both as they were.
                    if (route.isActive && ctx.mounted) {
                      setDialogState(() {
                        dialogErr = error;
                        dialogNotice = error == null ? savedMessage : null;
                      });
                    } else if (mounted) {
                      setState(() => _backupSaveNotice =
                          (saved: error == null, message: error ?? savedMessage));
                    }
                  }),
            ElevatedButton(
              key: const Key('generate_encrypted_backup_btn'),
              onPressed: () {
                if (!backupVerified || !_validPassword(passCtrl.text)) {
                  setDialogState(
                      () => dialogErr = '請先重新驗證紙本備份，並設定至少 12 字元非全數字密碼');
                  return;
                }
                if (passCtrl.text != passConfirmationCtrl.text) {
                  setDialogState(() => dialogErr = '兩次輸入的備份密碼不一致，請重新確認');
                  return;
                }
                final res = widget.ffi.exportEncryptedBackup(passCtrl.text);
                passCtrl.clear();
                passConfirmationCtrl.clear();
                if (res['status'] == 'SUCCESS') {
                  setDialogState(() {
                    exportedJson = res['backup_json'] as String?;
                    dialogErr = null;
                    dialogNotice = null;
                  });
                } else {
                  setDialogState(() {
                    dialogErr = res['error'] as String? ?? '匯出失敗';
                  });
                }
              },
              child: const Text('產生加密備份'),
            ),
          ],
        ),
      ),
    );
    try {
      await Navigator.of(context).push(route);
    } finally {
      exportedJson = null;
      for (final controller in controllers) {
        controller.clear();
      }
      // A popped dialog still owns its TextFields during the reverse
      // transition. Keep controllers alive and lifecycle-clearable until the
      // route's overlay entries have actually been removed.
      await route.completed;
      for (final controller in controllers) {
        _dialogSecretControllers.remove(controller);
        controller.dispose();
      }
    }
  }

  void _showReceiveVerifyModal(Map<String, dynamic> acc,
      {required bool isBtc}) {
    final addr = (acc['address'] ?? acc['receive_address'] ?? '') as String;
    final path = acc['derivation_path'] as String? ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isBtc ? 'Bitcoin 收款地址本機核對' : 'EVM 收款地址本機核對'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedFountainQr(
                  frames: [addr],
                  qrSize: 220,
                  title:
                      isBtc ? 'Bitcoin regtest · P2WPKH' : 'EVM EIP-55 Address',
                  subtitle: '請與連網錢包顯示的收款地址逐字核對',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  addr,
                  style: Theme.of(ctx).textTheme.bodyLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  '衍生路徑：$path\n主指紋：${_masterFingerprint.toUpperCase()}',
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('完成核對'),
          ),
        ],
      ),
    );
  }

  void _resetPublicPairing() {
    _okxAccountsData = null;
    _pairingProfile = _PairingProfile.wallet;
    _pairingError = null;
    _useFountainPairing = false;
  }

  Map<String, dynamic>? get _activePairingData =>
      _pairingProfile == _PairingProfile.okxEvm
          ? _okxAccountsData
          : _multiAccountsData;

  void _selectPairingProfile(_PairingProfile profile) {
    if (_vaultState != 'UNLOCKED') return;
    setState(() {
      _pairingProfile = profile;
      _pairingError = null;
      if (profile != _PairingProfile.okxEvm || _okxAccountsData != null) return;
      try {
        final result = widget.ffi.exportOkxAccounts(maxFragmentLen: 0);
        if (result['status'] != 'SUCCESS') {
          _pairingError =
              '[${result['error_code'] ?? 'ERR_OKX_PAIRING'}] ${result['error'] ?? 'OKX EVM 公開配對碼產生失敗'}';
          return;
        }
        final accounts = result['multi_accounts'];
        if (result['adapter'] != 'okx-evm-account-standard' ||
            result['master_fingerprint'] != _masterFingerprint ||
            accounts is! Map<String, dynamic> ||
            _pairingPayloadFor(accounts).displayFrames().isEmpty ||
            accounts['evm_accounts'] is! List ||
            (accounts['evm_accounts'] as List).isEmpty) {
          _pairingError = 'OKX EVM 配對資料無法核對目前金庫，未顯示配對碼';
          return;
        }
        _okxAccountsData = accounts;
      } catch (_) {
        _pairingError = 'OKX EVM 原生配對功能無法使用，未產生配對碼';
      }
    });
  }

  UrQrPayload _pairingPayloadFor(Map<String, dynamic>? accounts) {
    final single = accounts?['ur_single'];
    final frames = accounts?['fountain_frames'];
    return UrQrPayload(
      singleUr: single is String ? single : null,
      frames: frames is List
          ? frames.map((frame) => frame is String ? frame : '')
          : const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: FcwSpace.page,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FcwRoleBadge(FcwRole.vault),
            SizedBox(width: FcwSpace.md),
            Flexible(child: Text('離線金庫')),
          ],
        ),
        actions: [
          if (_vaultState == 'UNLOCKED')
            IconButton(
              key: const Key('vault_lock_btn'),
              icon: const Icon(Icons.lock_outline),
              tooltip: '立即鎖定並撤銷簽署授權',
              onPressed: lockVault,
            ),
          IconButton(
            key: const Key('vault_about_btn'),
            icon: const Icon(Icons.info_outline),
            tooltip: '關於',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const VaultAboutScreen())),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          // A new role starts at its primary action, not the previous form's
          // offset. Rebuilds within the same role preserve normal scrolling.
          key: ValueKey(_vaultState),
          padding: const EdgeInsets.fromLTRB(
              FcwSpace.page, FcwSpace.sm, FcwSpace.page, FcwSpace.xxl),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    // A role label, not a check result: nothing here verifies
                    // that the device is actually offline.
                    child: FcwStatusPill('離線簽章', icon: Icons.draw_outlined),
                  ),
                  const SizedBox(height: FcwSpace.lg),
                  _buildBodyByState(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel({required Widget child}) => FcwPanel(child: child);

  Widget _heading(String title, {String? description}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleLarge),
        if (description != null) ...[
          const SizedBox(height: FcwSpace.xs),
          Text(description,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
  }

  Widget _error(String message, {Key? key}) =>
      FcwBanner(tone: FcwTone.danger, content: Text(message, key: key));

  Widget _backupNotice(({bool saved, String message}) notice) => FcwBanner(
        tone: notice.saved ? FcwTone.success : FcwTone.danger,
        content:
            Text(notice.message, key: const Key('vault_backup_save_notice')),
      );

  Widget _buildBodyByState() {
    if (_vaultState == 'LOADING') {
      return const Center(child: CircularProgressIndicator());
    }
    switch (_vaultState) {
      case 'STORAGE_CORRUPTED':
        return _buildCorruptedView();
      case 'LOCKED':
        return _buildLockedView();
      case 'UNLOCKED':
        return _buildUnlockedView();
      case 'EMPTY':
      default:
        return _buildOnboardingView();
    }
  }

  Widget _buildCorruptedView() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('無法開啟金庫', description: '金庫加密儲存區異常或版本不相容。'),
          const SizedBox(height: 16),
          _error(
            '錯誤代碼：${_storageErrorCode ?? "ERR_STORAGE_CORRUPTED"}\n詳情：${_storageErrorMessage ?? "偵測到未授權變更或損毀"}',
          ),
          const SizedBox(height: 16),
          const Text('原金庫檔案已保留。請先保留原始檔並在乾淨的測試環境核對備份；本頁不會刪除或覆寫金庫。'),
        ],
      ),
    );
  }

  Widget _buildLockedView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading('解鎖金庫', description: '輸入 App 密碼，再完成裝置驗證。'),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FcwStatusPill('主指紋 ${_masterFingerprint.toUpperCase()}',
                    icon: Icons.fingerprint),
              ),
              const SizedBox(height: 16),
              TextField(
                enableInteractiveSelection: false,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                key: const Key('vault_unlock_pin_field'),
                controller: _unlockPinCtrl,
                enabled: !_cameraPermissionPending,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'App 解鎖密碼',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_backupSaveNotice != null) ...[
                const SizedBox(height: 12),
                _backupNotice(_backupSaveNotice!),
              ],
              if (_actionError != null) ...[
                const SizedBox(height: 12),
                _error(_actionError!),
              ],
              const SizedBox(height: 16),
              ElevatedButton.icon(
                key: const Key('vault_unlock_submit_btn'),
                icon: const Icon(Icons.lock_open),
                label: const Text('驗證並解鎖'),
                onPressed:
                    _cameraPermissionPending ? null : _handleUnlockWithPin,
              ),
              if (defaultTargetPlatform == TargetPlatform.android) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('vault_prepare_camera_permission_btn'),
                  onPressed: _cameraPermissionPending
                      ? null
                      : _prepareCameraPermission,
                  child: Text(_cameraPermissionPending ? '等待相機權限決定' : '準備相機權限'),
                ),
                if (_cameraPermissionMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(_cameraPermissionMessage!,
                      key: const Key('vault_camera_permission_status')),
                ],
                if (_cameraPermissionNeedsSettings) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('vault_open_camera_settings_btn'),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('開啟系統設定'),
                    onPressed: _openAppSettings,
                  ),
                ],
              ],
            ],
          ),
        ),
        _buildPublicResultAccess(),
        const SizedBox(height: FcwSpace.xl),
        const FcwUnauditedBanner(key: Key('vault_unaudited_notice')),
      ],
    );
  }

  Widget _buildOnboardingView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('設定離線金庫', description: '建立新的金庫，或使用既有備份還原。'),
        const SizedBox(height: FcwSpace.lg),
        const FcwBanner(
          tone: FcwTone.warning,
          icon: Icons.airplanemode_active,
          message: '請啟用飛航模式並關閉網路連線，將此裝置作為專用離線簽章器。',
        ),
        const SizedBox(height: FcwSpace.sm),
        const FcwBanner(
          tone: FcwTone.info,
          icon: Icons.phonelink_lock,
          message: '先設定裝置鎖定密碼或支援的生物識別。重開金庫時，需要裝置驗證及獨立的 App 密碼。本機不會自動載入測試助記詞。',
        ),
        const SizedBox(height: FcwSpace.xl),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const Key('onboarding_tab_create'),
              label: const Text('建立新錢包'),
              selected: _onboardingTab == 0,
              onSelected: (_) => setState(() {
                _clearSecrets();
                _onboardingTab = 0;
                _actionError = null;
              }),
            ),
            ChoiceChip(
              key: const Key('onboarding_tab_restore_mnemonic'),
              label: const Text('助記詞還原'),
              selected: _onboardingTab == 1,
              onSelected: (_) => setState(() {
                _clearSecrets();
                _onboardingTab = 1;
                _actionError = null;
              }),
            ),
            ChoiceChip(
              key: const Key('onboarding_tab_restore_backup'),
              label: const Text('加密備份還原'),
              selected: _onboardingTab == 2,
              onSelected: (_) => setState(() {
                _clearSecrets();
                _onboardingTab = 2;
                _actionError = null;
              }),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_onboardingTab == 0) _buildCreateWalletPanel(),
        if (_onboardingTab == 1) _buildRestoreMnemonicPanel(),
        if (_onboardingTab == 2) _buildRestoreBackupPanel(),
        // Shown next to the panel's action at the bottom, where the user is
        // looking after tapping it, rather than scrolled away at the top.
        if (_actionError != null) ...[
          const SizedBox(height: 12),
          KeyedSubtree(
            key: _actionErrorKey,
            child: _error(_actionError!,
                key: const Key('vault_onboarding_error_text')),
          ),
        ],
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => setState(_clearSecrets),
          child: const Text('取消並清除本次輸入'),
        ),
      ],
    );
  }

  Widget _buildCreateWalletPanel() {
    final words = _generatedMnemonic?.split(' ') ?? const [];
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            words.isEmpty
                ? '1 · 產生助記詞'
                : _backupQuizVisible
                    ? '3 · 驗證備份並啟用'
                    : '2 · 抄寫助記詞',
          ),
          const SizedBox(height: 16),
          const Text('助記詞長度'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 12, label: Text('12 字')),
                ButtonSegment(value: 24, label: Text('24 字')),
              ],
              selected: {_createWordCount},
              onSelectionChanged: (s) =>
                  setState(() => _createWordCount = s.first),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            key: const Key('generate_mnemonic_btn'),
            icon: const Icon(Icons.add),
            label: Text('產生 $_createWordCount 字助記詞'),
            onPressed: _handleGenerateMnemonic,
          ),
          if (words.isNotEmpty) ...[
            if (!_backupQuizVisible) ...[
              const SizedBox(height: FcwSpace.lg),
              const FcwBanner(
                tone: FcwTone.warning,
                icon: Icons.edit_note,
                message: '請依序抄寫在紙上並離線保存。助記詞與 Passphrase 可控制您的資產；請勿截圖或交給他人。',
              ),
              const SizedBox(height: FcwSpace.lg),
              LayoutBuilder(builder: (context, constraints) {
                const gap = FcwSpace.sm;
                // Tile chrome: horizontal padding and border.
                const chrome = FcwSpace.md * 2 + 2;
                final style = fcwMono(Theme.of(context).textTheme.bodyLarge)
                    .copyWith(fontWeight: FontWeight.w600);
                final scaler = MediaQuery.textScalerOf(context);
                var widest = 0.0;
                for (var i = 0; i < words.length; i++) {
                  final painter = TextPainter(
                    text: TextSpan(text: '${i + 1}. ${words[i]}', style: style),
                    textDirection: TextDirection.ltr,
                    textScaler: scaler,
                  )..layout();
                  widest = widest < painter.width ? painter.width : widest;
                  painter.dispose();
                }
                // As many columns (up to three) as the widest word allows.
                final columns =
                    ((constraints.maxWidth + gap) / (widest + chrome + gap))
                        .floor()
                        .clamp(1, 3);
                final width =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: List.generate(words.length, (i) {
                    return SizedBox(
                      width: width,
                      // At extreme text sizes a single column may still be
                      // narrower than a label: it wraps after the number
                      // instead of cutting the word off.
                      child: FcwCodeBlock(
                        child: Text('${i + 1}. ${words[i]}',
                            key: ValueKey('mnemonic_word_${i + 1}'),
                            style: style),
                      ),
                    );
                  }),
                );
              }),
              const SizedBox(height: FcwSpace.lg),
              OutlinedButton(
                key: const Key('start_backup_quiz_btn'),
                onPressed: () => setState(() => _backupQuizVisible = true),
                child: const Text('已抄寫，隱藏並驗證'),
              ),
            ],
            if (_backupQuizVisible) ...[
              const SizedBox(height: FcwSpace.lg),
              const FcwBanner(
                tone: FcwTone.info,
                icon: Icons.fact_check_outlined,
                message: '從紙本輸入第 1 個與最後一個單字，確認備份可用。',
              ),
              const SizedBox(height: FcwSpace.lg),
              TextField(
                enableInteractiveSelection: false,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                key: const Key('quiz_first_word_field'),
                controller: _quizFirstWordCtrl,
                // Masked like the passwords: plain text would land in
                // accessibility trees and UI hierarchy dumps.
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '第 1 個單字',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                enableInteractiveSelection: false,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                key: const Key('quiz_last_word_field'),
                controller: _quizLastWordCtrl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '第 ${words.length} 個單字',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                enableInteractiveSelection: false,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                key: const Key('create_passphrase_field'),
                controller: _createPassphraseCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Passphrase（選填）',
                  helperText:
                      'BIP-39 Passphrase 與 App 解鎖密碼不同。留空為標準金庫；不同 Passphrase 會產生完全不同的主指紋與帳戶，請另外備份。',
                  helperMaxLines: 12,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              _confirmationField(
                key: const Key('create_passphrase_confirmation_field'),
                controller: _createPassphraseConfirmationCtrl,
                label: '再次輸入 Passphrase（選填）',
              ),
              const SizedBox(height: 16),
              TextField(
                enableInteractiveSelection: false,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                key: const Key('create_pin_field'),
                controller: _createPinCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'App 解鎖密碼',
                  helperText: '至少 12 字元，且不可全部為數字。此密碼用於加密本機金庫。',
                  helperMaxLines: 8,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              _confirmationField(
                key: const Key('create_pin_confirmation_field'),
                controller: _createPinConfirmationCtrl,
                label: '再次輸入 App 解鎖密碼',
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                key: const Key('activate_created_wallet_btn'),
                icon: const Icon(Icons.check),
                label: const Text('驗證並啟用金庫'),
                onPressed: _handleActivateCreatedWallet,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildRestoreMnemonicPanel() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('1 · 輸入既有備份'),
          const SizedBox(height: 16),
          TextField(
            enableInteractiveSelection: false,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            key: const Key('restore_mnemonic_field'),
            controller: _restoreMnemonicCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '助記詞',
              helperText: '輸入 12 或 24 個 BIP-39 英文單字，以空格分隔。',
              helperMaxLines: 6,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            enableInteractiveSelection: false,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            key: const Key('restore_passphrase_field'),
            controller: _restorePassphraseCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Passphrase（選填）',
              helperText:
                  '輸入原 BIP-39 Passphrase；採 NFKD 正規化。這與 App 解鎖密碼不同，內容不同會還原到不同帳戶。',
              helperMaxLines: 12,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('preview_restore_mnemonic_btn'),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('預覽並驗證助記詞'),
            onPressed: _handlePreviewRestoreMnemonic,
          ),
          if (_restorePreview != null) ...[
            const SizedBox(height: 24),
            _heading('2 · 核對帳戶',
                description:
                    '助記詞校驗通過，共 ${_restorePreview!['word_count']} 個單字。請與原備份記錄逐字核對指紋及地址。'),
            const SizedBox(height: 12),
            Text(
              '主指紋：${_restorePreview!['master_fingerprint'].toString().toUpperCase()}',
              key: const Key('restore_preview_fingerprint_text'),
            ),
            const SizedBox(height: 8),
            Text(
              'EVM #0：${(_restorePreview!['evm_account_0'] as Map<String, dynamic>?)?['address'] ?? ''}',
              key: const Key('restore_preview_evm0_text'),
            ),
            const SizedBox(height: 8),
            Text(
                'BTC #0：${(_restorePreview!['btc_account_0'] as Map<String, dynamic>?)?['receive_address'] ?? ''}'),
            const SizedBox(height: 24),
            _heading('3 · 設定本機密碼'),
            const SizedBox(height: 16),
            TextField(
              enableInteractiveSelection: false,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              key: const Key('restore_pin_field'),
              controller: _restorePinCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'App 解鎖密碼',
                helperText: '至少 12 字元，且不可全部為數字。這與原 Passphrase 不同。',
                helperMaxLines: 8,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _confirmationField(
              key: const Key('restore_pin_confirmation_field'),
              controller: _restorePinConfirmationCtrl,
              label: '再次輸入 App 解鎖密碼',
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              key: const Key('activate_restored_mnemonic_btn'),
              icon: const Icon(Icons.check),
              label: const Text('已核對，啟用金庫'),
              onPressed: _handleActivateRestoredMnemonic,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRestoreBackupPanel() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('1 · 開啟加密備份'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _readEncryptedBackup,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('選取加密備份檔案'),
          ),
          const SizedBox(height: 12),
          TextField(
            enableInteractiveSelection: false,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            key: const Key('restore_backup_json_field'),
            controller: _backupJsonCtrl,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '加密備份 JSON',
              helperText: '也可在此貼上既有加密備份內容。',
              helperMaxLines: 6,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            enableInteractiveSelection: false,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            key: const Key('restore_backup_password_field'),
            controller: _backupPassCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '備份解密密碼',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          _heading('2 · 核對還原地址'),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _handlePreviewEncryptedBackup,
            child: const Text('解密預覽並核對地址'),
          ),
          if (_backupPreview != null) ...[
            const SizedBox(height: 12),
            Text(
                '主指紋：${_backupPreview!['master_fingerprint'].toString().toUpperCase()}\nEVM 地址：${((_backupPreview!['multi_accounts'] as Map)['evm_accounts'] as List).first['address']}\n請與原備份記錄逐字核對。'),
          ],
          const SizedBox(height: 24),
          _heading('3 · 設定本機密碼'),
          const SizedBox(height: 16),
          TextField(
            enableInteractiveSelection: false,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            key: const Key('restore_backup_new_pin_field'),
            controller: _backupNewPinCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '新 App 解鎖密碼',
              helperText: '至少 12 字元，且不可全部為數字。此密碼用於本機金庫，與備份解密密碼不同。',
              helperMaxLines: 10,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          _confirmationField(
            key: const Key('restore_backup_new_pin_confirmation_field'),
            controller: _backupNewPinConfirmationCtrl,
            label: '再次輸入新 App 解鎖密碼',
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            key: const Key('restore_backup_submit_btn'),
            icon: const Icon(Icons.restore_page_outlined),
            label: const Text('已核對，還原並啟用'),
            onPressed: _handleRestoreEncryptedBackup,
          ),
        ],
      ),
    );
  }

  Widget _confirmationField({
    required Key key,
    required TextEditingController controller,
    required String label,
  }) =>
      TextField(
        key: key,
        controller: controller,
        enableInteractiveSelection: false,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        obscureText: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: '請逐字輸入相同內容，包含大小寫與空格。',
          helperMaxLines: 6,
          border: const OutlineInputBorder(),
        ),
      );

  Widget _buildUnlockedView() {
    final payload = _pairingPayloadFor(_activePairingData);
    final frames = payload.displayFrames(preferSingle: !_useFountainPairing);
    final useFountain = _useFountainPairing || !payload.hasSingle;
    final evmAccounts =
        (_multiAccountsData?['evm_accounts'] as List<dynamic>?) ?? const [];
    final btcAccounts =
        (_multiAccountsData?['btc_accounts'] as List<dynamic>?) ?? const [];
    final copyText = payload.copyText;
    final isOkx = _pairingProfile == _PairingProfile.okxEvm;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading('金庫已解鎖', description: '掃描連網錢包的待簽交易，核對內容後簽署。'),
              const SizedBox(height: FcwSpace.lg),
              Row(
                children: [
                  Icon(Icons.fingerprint,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: FcwSpace.sm),
                  Expanded(
                    child: Text(
                      '主指紋 ${_masterFingerprint.toUpperCase()}',
                      key: const Key('active_vault_fingerprint_text'),
                      style: fcwMono(Theme.of(context).textTheme.titleMedium),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: FcwSpace.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.key_outlined,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: FcwSpace.sm),
                  Expanded(
                    child: Text(_hasPassphraseHint
                        ? 'BIP-39 Passphrase：已啟用'
                        : 'BIP-39 Passphrase：未設定（標準金庫）'),
                  ),
                ],
              ),
              const SizedBox(height: FcwSpace.xl),
              ElevatedButton.icon(
                key: const Key('scan_sign_request_btn'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('掃描待簽交易'),
                onPressed: _checkingCameraPermission ? null : _scanSignRequest,
              ),
              if (_actionError != null) ...[
                const SizedBox(height: 12),
                KeyedSubtree(
                  key: _actionErrorKey,
                  child: _error(_actionError!,
                      key: const Key('vault_unlocked_error_text')),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: FcwSpace.lg),
        _panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading('配對連網錢包'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const Key('pairing_profile_wallet'),
                    label: const Text('自有 Wallet'),
                    selected: !isOkx,
                    onSelected: (_) =>
                        _selectPairingProfile(_PairingProfile.wallet),
                  ),
                  ChoiceChip(
                    key: const Key('pairing_profile_okx'),
                    label: const Text('OKX EVM'),
                    selected: isOkx,
                    onSelected: (_) =>
                        _selectPairingProfile(_PairingProfile.okxEvm),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('僅匯出公開帳戶；請只提供給自己的連網錢包。簽章仍限本機／測試網。'),
              if (isOkx) ...[
                const SizedBox(height: 8),
                const Text('OKX EVM account.standard 格式；尚未代表指定版本 OKX 已實測通過。'),
              ],
              if (_pairingError != null) ...[
                const SizedBox(height: 12),
                _error(_pairingError!, key: const Key('pairing_profile_error')),
              ],
              if (frames.isNotEmpty) ...[
                const SizedBox(height: 16),
                AnimatedFountainQr(
                  key: ValueKey('pairing-${_pairingProfile.name}-$useFountain'),
                  frames: frames,
                  title: isOkx ? 'OKX EVM 公開帳戶配對碼' : '自有 Wallet 公開帳戶配對碼',
                  subtitle: isOkx
                      ? 'EVM account.standard · crypto-multi-accounts'
                      : 'EVM 與 Bitcoin regtest · crypto-multi-accounts',
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    key: const Key('pairing_fountain_toggle'),
                    label: Text(useFountain ? '動態多幀 QR' : '單張完整 QR'),
                    selected: useFountain,
                    onSelected: !payload.hasSingle || payload.frames.isEmpty
                        ? null
                        : (v) => setState(() => _useFountainPairing = v),
                  ),
                  TextButton.icon(
                    key: const Key('copy_pairing_ur_btn'),
                    icon: const Icon(Icons.copy, size: 20),
                    label: const Text('複製配對 UR'),
                    onPressed: copyText.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: copyText));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content:
                                      Text('已複製 crypto-multi-accounts UR')),
                            );
                          },
                  ),
                ],
              ),
              ExpansionTile(
                key: const Key('public_pairing_text_toggle'),
                tilePadding: EdgeInsets.zero,
                title: const Text('公開配對文字'),
                subtitle: const Text('僅包含公開帳戶'),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(copyText,
                        key: const Key('public_pairing_ur_text'),
                        style: fcwMono(Theme.of(context).textTheme.bodySmall)),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: FcwSpace.xl),
        _heading('核對收款地址', description: '與連網錢包顯示的地址逐字核對。'),
        const SizedBox(height: FcwSpace.md),
        for (final item in evmAccounts)
          _buildAccountTile(item as Map<String, dynamic>, isBtc: false),
        for (final item in btcAccounts)
          _buildAccountTile(item as Map<String, dynamic>, isBtc: true),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const Key('export_backup_dialog_btn'),
          icon: const Icon(Icons.save_alt),
          label: const Text('匯出加密備份'),
          onPressed: _showExportBackupDialog,
        ),
        if (_backupSaveNotice != null) ...[
          const SizedBox(height: 12),
          _backupNotice(_backupSaveNotice!),
        ],
        _buildPublicResultAccess(),
        const SizedBox(height: FcwSpace.xl),
        const FcwUnauditedBanner(key: Key('vault_unaudited_notice')),
      ],
    );
  }

  Widget _buildAccountTile(Map<String, dynamic> acc, {required bool isBtc}) {
    final idx = acc['account_index'] ?? 0;
    final path = acc['derivation_path'] as String? ?? '';
    final addr = (acc['address'] ?? acc['receive_address'] ?? '') as String;
    final desc = acc['descriptor'] as String?;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(isBtc ? Icons.currency_bitcoin : Icons.hub_outlined,
                    size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: FcwSpace.sm),
                Expanded(
                  child: Text(
                      isBtc ? 'Bitcoin regtest 帳戶 #$idx' : 'EVM 帳戶 #$idx',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: FcwSpace.md),
            FcwCodeBlock(
              child: SelectableText(addr,
                  style: fcwMono(Theme.of(context).textTheme.bodyLarge)),
            ),
            const SizedBox(height: FcwSpace.sm),
            Text('衍生路徑 $path',
                style: fcwMono(Theme.of(context).textTheme.bodySmall).copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            if (desc != null && desc.isNotEmpty) ...[
              const SizedBox(height: FcwSpace.sm),
              Text(desc,
                  style: fcwMono(Theme.of(context).textTheme.bodySmall)
                      .copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: FcwSpace.sm),
            TextButton.icon(
              icon: const Icon(Icons.qr_code_2),
              label: const Text('顯示收款 QR 並核對地址'),
              onPressed: () => _showReceiveVerifyModal(acc, isBtc: isBtc),
            ),
          ],
        ),
      ),
    );
  }
}
