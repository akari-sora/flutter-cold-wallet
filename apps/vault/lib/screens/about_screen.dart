import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../app_info.dart';

/// Built from constants only: it shows nothing from the vault, so it can be
/// opened while the vault is locked.
class VaultAboutScreen extends StatelessWidget {
  const VaultAboutScreen({super.key});

  @override
  Widget build(BuildContext context) => const FcwAboutPage(
        appName: appName,
        version: appVersion,
        notes: [
          // Installing or updating from Google Play needs the network, the
          // one time this phone is online.
          FcwBanner(
            key: Key('vault_update_advice'),
            tone: FcwTone.info,
            icon: Icons.system_update_outlined,
            title: '更新與連網',
            message: '建議在 Google Play 關閉 FCW Vault 的自動更新，只在需要時手動更新。\n'
                '手機連網時（包括安裝或更新期間）不要解鎖金庫；更新完成後先關閉網路，再解鎖。',
          ),
        ],
      );
}
