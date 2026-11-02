import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import '../ffi/vault_ffi_service.dart';

/// App Lifecycle watchdog for offline Vault.
/// Guarantees LIFE-02: automatically revokes pending handles, zeroizes in-memory
/// seed material, and blanks out screen whenever the app enters background,
/// lock screen, or loses focus.
class VaultLifecycleGuard with WidgetsBindingObserver {
  final VaultFfiService _ffi;
  final Duration idleTimeout;
  Timer? _idleTimer;
  final VoidCallback onSecurityLockTriggered;
  final ValueChanged<AppLifecycleState?>? onSecurityLockReason;

  VaultLifecycleGuard({
    required VaultFfiService ffi,
    required this.onSecurityLockTriggered,
    this.onSecurityLockReason,
    this.idleTimeout = const Duration(minutes: 2),
  }) : _ffi = ffi;

  void startObserving() {
    WidgetsBinding.instance.addObserver(this);
    recordActivity();
  }

  void _cancelDeviceAuthentication() {
    unawaited(const MethodChannel('fcw/platform')
        .invokeMethod<void>('cancelDeviceAuthentication')
        .catchError((_) {}));
  }

  void stopObserving() {
    _cancelDeviceAuthentication();
    _idleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  void recordActivity() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      _cancelDeviceAuthentication();
      _securityLock();
    });
  }

  void _securityLock([AppLifecycleState? reason]) {
    _idleTimer?.cancel();
    try {
      try {
        _ffi.cancel(null);
      } finally {
        // A cancellation failure must not prevent a separate lock attempt.
        // Service exceptions still propagate to the caller.
        _ffi.lock();
      }
    } finally {
      if (onSecurityLockReason != null) {
        onSecurityLockReason!(reason);
      } else {
        onSecurityLockTriggered();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) recordActivity();
    // LIFE-02: App transitions to background / inactive / paused
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _securityLock(state);
    }
  }
}
