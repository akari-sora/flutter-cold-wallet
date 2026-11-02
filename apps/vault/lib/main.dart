import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'app_info.dart';
import 'ffi/vault_ffi_service.dart';
import 'screens/vault_home_screen.dart';
import 'services/vault_lifecycle_guard.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ColdWalletVaultApp());
}

class ColdWalletVaultApp extends StatefulWidget {
  final VaultFfiService? ffiOverride;
  final String? storagePathOverride;

  const ColdWalletVaultApp({
    super.key,
    this.ffiOverride,
    this.storagePathOverride,
  });

  @override
  State<ColdWalletVaultApp> createState() => _ColdWalletVaultAppState();
}

class _ColdWalletVaultAppState extends State<ColdWalletVaultApp> {
  VaultFfiService? _ffi;
  String? _ffiFatalError;
  VaultLifecycleGuard? _lifecycleGuard;
  final GlobalKey<VaultHomeScreenState> _homeKey =
      GlobalKey<VaultHomeScreenState>();

  @override
  void initState() {
    super.initState();
    try {
      final loaded = widget.ffiOverride ?? VaultFfiService();
      if (loaded.init() != 0) throw StateError('原生核心初始化失敗');
      _ffi = loaded;
      _lifecycleGuard = VaultLifecycleGuard(
        ffi: loaded,
        onSecurityLockTriggered: () {},
        onSecurityLockReason: (reason) {
          _homeKey.currentState?.lockForLifecycle(reason);
          if (mounted) {
            setState(() {});
          }
        },
      );
      _lifecycleGuard!.startObserving();
    } catch (e) {
      // Fail-closed: NEVER silently fall back or mask native cryptographic core load failure.
      _ffiFatalError = e.toString();
    }
  }

  @override
  void dispose() {
    _lifecycleGuard?.stopObserving();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ColdWalletTheme.light(role: FcwRole.vault),
      darkTheme: ColdWalletTheme.dark(role: FcwRole.vault),
      // The offline signer is dark-first so it is never mistaken for the Wallet.
      themeMode: ThemeMode.dark,
      builder: (context, child) => Listener(
        onPointerDown: (_) => _lifecycleGuard?.recordActivity(),
        onPointerMove: (_) => _lifecycleGuard?.recordActivity(),
        child: child!,
      ),
      home: Builder(
        builder: (context) => _ffiFatalError != null
            ? Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.error,
                          size: 64,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '無法啟動金庫',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _ffiFatalError!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : VaultHomeScreen(
                key: _homeKey,
                ffi: _ffi!,
                storagePath: widget.storagePathOverride,
              ),
      ),
    );
  }
}
