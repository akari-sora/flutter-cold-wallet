import 'package:flutter/material.dart';
import 'package:design_system/design_system.dart';
import 'app_info.dart';
import 'ffi/wallet_ffi_service.dart';
import 'screens/account_screen.dart';
import 'services/node_rpc_client.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ColdWalletWatchApp());
}

class ColdWalletWatchApp extends StatelessWidget {
  final WalletFfiService? ffiOverride;
  final NodeRpcClient? rpcOverride;
  final String? storagePathOverride;

  const ColdWalletWatchApp({
    super.key,
    this.ffiOverride,
    this.rpcOverride,
    this.storagePathOverride,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ColdWalletTheme.light(role: FcwRole.wallet),
      darkTheme: ColdWalletTheme.dark(role: FcwRole.wallet),
      themeMode: ThemeMode.system,
      home: AccountScreen(
        ffiOverride: ffiOverride,
        rpcOverride: rpcOverride,
        storagePathOverride: storagePathOverride,
      ),
    );
  }
}
