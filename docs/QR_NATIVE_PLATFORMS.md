# QR 核心版本的原生平台接線

Android：兩個 App 均使用 `fcw/platform` 的 `storageDirectory`。Wallet 存公開帳戶於私有 filesDir；Vault 使用 noBackupFilesDir、FLAG_SECURE、停用備份並在 release 合併時移除 INTERNET、ACCESS_NETWORK_STATE、NFC 權限。相機解碼器明確採 bundled ML Kit，首次離線掃描不需下載模型。Wallet 的節點網址規則在 Dart 端：`apps/wallet/lib/services/node_url_policy.dart` 是唯一規則，EVM 與 Bitcoin 的網址欄位在輸入時、EVM 設定在儲存前、`NodeRpcClient` 與 `BitcoinRpcClient` 在每次送出請求前都用它檢查；不依賴 `network_security_config.xml`。`https://` 可用於任何主機；`http://` 只允許 `localhost`、`127.0.0.0/8`、`::1`、`10.0.0.0/8`（含模擬器主機 10.0.2.2）、`172.16.0.0/12`、`192.168.0.0/16`、`169.254.0.0/16`、`fc00::/7`、`fe80::/10`、不含點的主機名稱與結尾為 `.local` 的名稱，其他主機一律拒絕；使用 `http://` 時，欄位下方會說明連線只在手機內（回送位址），或同一網路上的其他裝置看得到（其他允許的主機）。對使用者的完整說明見隱私權政策第 3.4 節（[繁體中文](privacy/privacy-policy.zh-TW.md)、[English](privacy/privacy-policy.en.md)）。實機可透過 adb reverse 存取本機測試鏈。

Android 金庫檔案先在同目錄完成寫入及 sync，再用 `renameat2(RENAME_NOREPLACE)` 原子發布；不覆寫既有檔案。實機 SELinux 會拒絕 hard link，這項差異已由 S8 建庫失敗追查並修正。其餘平台保留原子 no-clobber 發布；iOS 的檔案系統行為仍須在 Mac／真機驗證。

Wallet 的 `savePublicBackup`／`readPublicBackup` 使用原生本機檔案挑選器，與 Vault 加密秘密備份分離。公開備份仍含隱私資料，排除 RPC 設定與帳密；匯入先驗證公開派生資料及簽章，再分步明確確認。交易恢復為結果待查，需重新查詢及驗章。

Vault 平台通道：
- `authenticateWithDevice`：Android 30+ 若已註冊 class-3 生物識別則使用 BiometricPrompt 的 strong biometric 或裝置密碼；若裝置已設定鎖定但沒有 class-3 生物識別則僅使用裝置密碼；未設定鎖定則拒絕。Android 29 使用系統生物識別/裝置密碼提示，Android 28 使用系統生物識別提示（無裝置密碼 fallback）；Vault minSdk 28，因此不提供 Android 23–27 安裝；原生層仍對不支援的 API 明確拒絕，再執行要求近期認證的 KeyStore AES-GCM 操作；iOS 存取帶 userPresence、WhenPasscodeSetThisDeviceOnly 的 Keychain 項目。成功才傳回 true；拒絕、取消、逾時或背景均回傳錯誤。這個機制是解鎖門禁，資產仍由 Rust 軟體核心簽署，沒有聲稱硬體內簽章。S8 裝置驗證成功仍未實機核對，此變更不是繞過 owner authentication。
- `saveEncryptedBackup({json})`：系統檔案選擇器匯出已加密 JSON，成功回傳 true。
- `readEncryptedBackup`：系統檔案選擇器讀取 UTF-8 JSON，回傳字串；最多 2 MiB。取消拋出 cancelled，不寫 Clipboard。通道本身不解密備份；格式與完整性由核心檢查。

Android 的 LOCAL_ONLY 選項限制系統檔案選擇器使用本機供應者。iOS document picker 由使用者選擇位置，系統可能提供 iCloud 等供應者；操作畫面應說明只匯出加密資料並選擇離線媒體。App 沒有實作雲端傳輸或授權。

iOS 已新增 Flutter 原生 target、camera/Face ID 說明、Application Support 的完整檔案保護與 Vault 目錄備份排除、Keychain/LocalAuthentication、document picker、背景隱私遮罩。iOS 無法由一般 App 保證阻止使用者截圖；遮罩用於背景預覽，不能宣稱等同 Android FLAG_SECURE。

在 Mac 上：
1. 安裝 Xcode 並完成 command line tools、Rust、Flutter、CocoaPods 設定。
2. 於 repo root 執行 `bash tools/build_ios_core.sh`，建立兩個 App 的 device 與 simulator 靜態庫。
3. 分別在 apps/wallet、apps/vault 執行 `flutter pub get`，再 `flutter build ios --no-codesign` 或 `flutter build ios --simulator`。
4. 使用真機簽名配置，驗證首次離線相機、裝置驗證取消/背景/鎖屏、備份寫入與拒絕損毀資料、完整 QR 交易。

Native.xcconfig 用 -force_load 保留 Dart FFI 查找的 C exports；Wallet 只連 wallet_ffi，Vault 只連 vault_ffi。缺少靜態庫會在連結失敗，不會改用測試金庫。這些 iOS 原生程式在 Windows 僅能做結構檢查，未經 Xcode 編譯、模擬器或真機驗證。Android 亦必須以合併後 APK 的權限與實機驗證為準。

NFC Probe 的 JNI 與 fixture 匯出保留於兩個 FFI crate 的明確 `test-fixtures` feature。只有獨立 Probe／舊 fixture 測試才使用 `--features vault_ffi/test-fixtures,wallet_ffi/test-fixtures`；正式 QR APK／iOS archive 不啟用此 feature。這是建置範圍調整，沒有刪除 NFC 實作或改寫歷史驗收結果。
