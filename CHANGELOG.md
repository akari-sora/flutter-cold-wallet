# 更新日誌（Changelog）

本專案記錄 `apps/wallet`（連網觀察錢包）與 `apps/vault`（離線簽署金庫）的主要變更。
格式參考 Keep a Changelog，文字採用繁體中文。
文中的 commit SHA、標籤與候選編號（`r9`、`r17` 等）指向私有存檔 repo 與當時的本機建置；公開 repo 從單一起始 commit 開始，查不到這些 SHA。

## [Unreleased]

- 文件：收錄已接受的 ADR-005，更新 [Android 優先工作狀態](docs/ANDROID_STATUS.md)與後續驗收順序。r20 產品來源與產物雜湊不變；Phase 0 程式仍在獨立的 `phase-0` 分支。

## [1.2.1] - 2026-10-21

範圍：`v1.2.0` 之後到 `70d56e8`；兩個 App 的版本號為 `1.2.1+5`。`64cb711` 之後只有測試、文件與啟動器圖示變更；沒有產品流程變更。這是測試網預覽版：兩個 App 仍只支援測試網，主網支援另行開發（見已知限制）。

### 新增

- 兩個 App 改名為 FCW Watch（連網觀察錢包）與 FCW Vault（離線簽署金庫），Android 啟動器、iOS 主畫面與工作切換畫面都使用新名稱；套件名稱不變（`34c4b14`）。兩個 App 另有各自的 Android／iOS 啟動器圖示（`70d56e8`）。
- 兩個 App 新增「關於」頁：名稱、版本、未經第三方稽核的說明、原始碼網址與授權，並內嵌完整隱私權政策（英文版可展開），因為 Vault 無法開啟網頁。Vault 在任何狀態（包括尚未設定與鎖定中）都能從上方列開啟，並附 Play 更新的建議；Wallet 從首頁底部開啟。兩個首頁的最後都加上「未經第三方安全稽核，請先小額使用」（`2b5481b`）。
- 隱私權政策（`docs/privacy/`，繁體中文與英文）正式發布（`d6a80b8`、`9d8b141`、`d05bbf9`、`e76b01e`）。
- EVM 網路設定與 Bitcoin 節點設定的網址欄下方，說明節點會收到哪些資料：地址、交易與 IP 位址；Bitcoin 另含帶擴充公鑰的帳戶描述（descriptor）與 RPC 帳號密碼（`7a6d75f`、`d05bbf9`、`e76b01e`）。

### 變更

- 節點網址規則（EVM 與 Bitcoin 共用一套）：`https://` 可用於任何主機；`http://` 只限 loopback 與私人網路（RFC 1918、link-local、unique-local IPv6、單一標籤名稱、`.local`），並以嚴格的位址格式比對，十進位、八進位等數字寫法無法繞到公開位址。設定欄在輸入與儲存時就拒絕公開網路上的明文網址；使用明文時，loopback 網址顯示本機說明（開發者使用 `adb reverse` 時流量仍會轉送到電腦），私人網路網址顯示警告；兩個 RPC 用戶端在送出前會再次檢查設定的初始網址（`2fa5531`、`d05bbf9`、`1226559`）。目前不檢查 HTTP 轉址目標，見已知限制。Android 的 `network_security_config` 不約束 Flutter 的網路層，規則由 App 本身執行（`af7badd`）。
  - 1.2.1 之前存下的公開 `http://` 網址：EVM 廣播、狀態查詢、nonce／gas 同步、未簽請求的恢復、手動輸入 nonce 與 gas 建立請求、餘額更新，以及 Bitcoin 的 descriptor 同步、建立請求、廣播與狀態查詢，都會在送出任何請求前停下，紀錄維持原狀態，並說明本次沒有傳送、要到哪裡修改網址（`6726be2`、`ffdc5fb`、`4a72186`）。
  - 把同一個節點從 `http://` 改成 `https://`（或其他允許的網址）後，綁定舊網址的 EVM 紀錄可以改用新網址，條件是新節點回報的 Chain ID 與紀錄相同；原本的資料、簽章、雜湊與帳戶都保留，已驗證的紀錄維持已驗證，可能已送出的紀錄維持「結果待查」且只能查詢，畫面會說明已改用目前的 RPC（`d105315`、`e76b01e`）。若舊紀錄與目前 RPC 是不同的公開 `http://` 網址，資料綁定檢查可能先拒絕重播，未必會顯示改網址指引。
  - Bitcoin 紀錄只保存規則允許的網址；從舊紀錄載入的被拒網址會顯示在欄位上供修改，但不會再寫回，沒有允許的舊值時存成空白（`4a72186`、`e76b01e`）。
- Wallet release 建置移除 ML Kit 附帶、會把診斷與使用資料傳給 Google 的 datatransport 元件（Vault 原本就已移除）（`76becf4`）。
- 授權改為 AGPL-3.0-or-later，另附允許與 Google ML Kit 及 Google Play services 一起散布的額外許可（`LICENSE-EXCEPTION`，`b6d5e98`）。
- 兩個 App 版本號升為 `1.2.1+5`（`a8936e5`）。

### 修正

- Wallet 相機權限（`1.2.0` 已知限制）：
  - 相機權限被拒時，掃描器不再在每次回到前景時重新要求權限；只有真的離開過 App（例如到系統設定）再回來，或按「清除並重新掃描」時才再要求一次。修正前，`1.2.0` 的走查在 66 秒內看到 217 次自動拒絕，Android 最後以「rapid activity launch」把 Wallet 從畫面上關閉（`51b0842`）。
  - 權限被拒時開啟並取消「手動貼上 UR」，不再重新要求權限（`58830cd`）。
  - EVM 簽章掃描不再因相機權限視窗而撤銷接收授權。只有掃描器的權限請求開著的那段時間，失去焦點才不撤銷；掃描器會自己送出這個請求，好讓這段時間精確對應請求本身，不包括請求前的權限查詢與允許後的相機啟動。其他失去焦點的情況（通知欄、分割畫面、子母畫面、iOS 控制中心）照舊撤銷（`7fccd54`、`ec820c2`、`0017a12`、`1db5fc3`）。
  - 允許相機後第一次進入 EVM 掃描，不再顯示「無法使用相機：controllerAlreadyInitialized」：權限視窗開著時就被移除的掃描器，不會在允許後啟動相機；所有掃描器的相機啟動、停止與釋放依序執行；只有目前擁有相機的掃描器能釋放共用的相機平台（`5c266e9`、`fa404c4`、`cf4795a`、`1db5fc3`）。
- 第 13 輪審查的小問題（`1.2.0` 已知限制）：
  - 相機權限被拒的說明在極端字級下不再被底部面板遮住，放不下時可捲動（`e23323b`）。
  - EVM 重送在送出前被撤銷時，說明前一次送出仍待查、要先查詢同一筆交易（`5e9dd81`）。
  - BTC 送出期間離開前景時加上說明（`7779c8f`），之後改成與 EVM 相同的處理：已送出的立即改為「結果待查」並存檔、只能查詢；尚未送出的回到送出前的狀態並可再送出；晚到的回應不會改變畫面，也不會結束較新的查詢（`ebdec15`）。
  - `sendrawtransaction` 收到 HTTP 401／403 時，文字會保留實際狀態碼（HTTP 401 或 HTTP 403），並說明可能來自節點或其前方的代理，不再寫「遭節點拒絕」（`777a469`）。
  - APK 檢查把其他電腦的 debug 憑證標為「debug certificate」、其他憑證標為「unrecognised certificate」，並記錄簽章者 DN（`58d3a43`）；檢查不再使用 `assert`，`python -O` 下照樣生效（`851444a`）。

### 建置與檢查

- 新增 `tools/release_checks/verify_play_bundle.py`：離線檢查要上傳 Play 的 AAB（bundletool 驗證、套件名稱與版本、SDK 等級、權限白名單、禁止的元件、原生庫，`--build-apks` 時另查 16 KiB ZIP 對齊）。任何 `CN=Android Debug` 的簽章都會被拒；沒有指定上傳憑證 pin 時結果只算 DIAGNOSTIC，不算 PASS；也接受 JDK 8 keytool 的輸出格式（`44e6595`、`0752a5e`、`2be2dae`、`e79de2f`、`2e940e8`）。
- 新增 `tools/release_checks/android_sdk.py`，在 macOS、Linux、Windows 尋找 Android SDK 工具（`6c2e026`）。
- 發版檢查、參考 oracle 與整合測試改從 PATH 與環境變數找工具，裝置序號改由參數提供（`3c32eb5`）。發版檢查的測試不再依賴主機上的工具鏈；真實主機的工具鏈要另跑 `check_env.py --strict`，說明見 `tools/release_checks/README.md`（`8673e76`、`64cb711`）。

### 公開倉庫整理

- 移除內部工作資料（代理提示、驗收矩陣、證據紀錄、環境快照、APK 逆向筆記），以及只為維護它們而存在的腳本和測試；兩份公開測試向量的 OKX UI dump 移到 `tests/fixtures/okx_ui_dump/`（`3409112`）。
- 不再追蹤 `local.properties`、`.flutter-plugins-dependencies`、自動產生的 plugin registrant 與預先建好的 NFC 測試原生庫（`271db00`）。
- 測試資料中的私人測試地址換成 Anvil 預設帳戶 #0（`9673214`）。
- 改寫工程文件與 README（英文摘要、工具鏈、建置與測試指令、授權說明），新增 `SECURITY.md` 與 `CONTRIBUTING.md`，文件中的 commit SHA 註明指向私有存檔（`d59e3a8`、`b908795`、`dca6b3f`、`b7336be`、`e9708f1`、`e4db84f`、`6b9733a`）。
- `docs/screenshots/` 改用 `1.2.1` 與公開 BIP-39 測試向量金庫（主指紋 `73C5DA0A`）重拍，不再含舊 QA 金庫的資料。

### 測試

- macOS 與 Windows（host 原生庫）在 `60a070c`（`64cb711` 加上只改測試的 commit）各跑一次全套，結果相同：`design_system` 38、`qr_ui` 55、`public_models` 267、`wallet` 235、`vault` 158，共 753 項通過；五個套件 `flutter analyze` 均無問題。`tests/release_checks` 在 macOS 189 項通過、1 項略過（需手動開啟的真實主機檢查），Windows 188 項通過、2 項略過（另一項是 Windows 沒有執行權限位元而略過的測試）。
- 本輪另在 r20 來源 `70d56e8` 重新建置 macOS host 原生庫並完成 Rust workspace 144 項、Flutter 753 項測試，五個套件 `flutter analyze` 全部通過；Python 發版檢查 189 項通過、1 項略過。這些 host 測試與下方的產物、模擬器 readback 分別記錄。
- 行為修正都附回歸測試，commit 說明列出修正前會失敗的情境。App 名稱與平台設定有 `app_identity_test.dart`，節點資料揭露有 `node_url_settings_test.dart`；真實裝置上的顯示仍需另驗。沒有自動化 UI 測試的有：`network_security_config` 註解（`af7badd`）與啟動器圖示（`70d56e8`）；Wallet 移除 datatransport 元件（`76becf4`）由 `verify_qr_apks.py` 與 `verify_play_bundle.py` 在產物上檢查。

### 驗證

- 三方獨立 AI 審查（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon，以最嚴格判決為準；額度用完的一方跳過；第 18 輪起另加 cursor-agent 上的 Grok 4.7 作額外審查）：
  - 第 16 輪全面審查 `d7590f0..5c266e9`：三家都是 REQUEST CHANGES。主要問題：存有公開 `http://` 網址的舊紀錄無法恢復、權限視窗之外的失去焦點也不撤銷、舊掃描器的清理會停掉新掃描器的相機、AAB 檢查只拒絕一張 debug 憑證。
  - 第 17 輪審 `5c266e9..ebdec15`：Argon APPROVE、Opus APPROVE WITH MINOR FIXES、Codex REQUEST CHANGES（失去焦點的豁免仍涵蓋一般相機啟動；退出動畫中的舊掃描器仍會停掉新相機）。
  - 第 18 輪審 `ebdec15..8673e76`：Opus APPROVE WITH MINOR FIXES、Codex REQUEST CHANGES（豁免仍涵蓋外掛自己的權限查詢與允許後的相機啟動）；Argon 額度用完、Grok 逾時，均跳過。
  - 第 19 輪審 `8673e76..64cb711`：Codex、Opus、Grok 都是 APPROVE WITH MINOR FIXES；Argon 額度用完，跳過。該輪的小問題中，`request` 拋錯的測試與被拒路徑的直接測試已補上（`60a070c`）；其餘列入 `docs/REMAINING_WORK.md`。
- Android 模擬器走查（ARM64 16 KiB，候選 `r19`，全部是測試資料）：
  - 從 `1.2.0` 測試建置直接覆蓋安裝 `1.2.1` 會被系統拒絕（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），需先解除安裝。
  - 新名稱、兩個關於頁（含 Vault 未設定與鎖定中）、未經稽核提醒。
  - 相機權限：第一次拒絕後 30 秒內只要求 1 次權限（`1.2.0` 為 66 秒 217 次）；永久拒絕後重試只自動拒絕 1 次；取消手動輸入不再要求；到系統設定允許後返回，掃描器自動重啟並完成配對；EVM 簽章接收時跳出權限視窗並允許，接收授權保留、直接讀到簽章，沒有 `controllerAlreadyInitialized`。
  - 節點網址：公開位址的 `http://` 在 EVM 與 Bitcoin 欄位都被拒絕且不會儲存；本機網址顯示「只在手機內」；私人網路網址顯示警告。以 Mac 的區網位址實測 EVM 節點（非 loopback、不在 `network_security_config` 例外清單），儲存與餘額更新都成功，證實該設定不約束 Flutter 的連線，規則由 App 執行。
  - EVM 完整簽署與廣播（Anvil block 7）；BTC descriptor 同步、簽署與廣播，送出期間離開前景後顯示「結果待查」與說明、只能查詢，查詢後確認（regtest block 115）。
  - ML Kit 遙測：模擬器的 console pcap 只有 24 bytes，沒有可用封包；12:00 後涵蓋 12:02、12:08、12:10 三次掃描的每 UID 統計為零。10:00–12:00 有少量流量，時段與區網 RPC 測試相符，但沒有目的地封包可逐筆歸因；logcat 沒有 datatransport 的上傳紀錄。這是有限觀察，不等於完整的執行時無流量證明。
- 產物（候選 `r20`，`70d56e8`）：以既有 Windows 建置候選加入新啟動器圖示後重新產生並簽署。四組 APK／AAB 的簽署前後非簽章 ZIP entry 已在本輪完整重算，路徑、大小與內容雜湊全部相同（Wallet APK 403、AAB 414；Vault APK 399、AAB 410）；公開精簡紀錄見 `docs/evidence/r20-resign-readback.json`。APK 的 `apksigner`、`zipalign` 與 AAB 的 `jarsigner` 驗證均通過。
  - APK 以預定供 Play 採用的應用程式簽署金鑰簽署：Wallet 憑證 SHA-256 `6a5daf8cfd5059879287e3ad2174257a0d3d0ffd5d5759597006b56a4ab155fc`，APK SHA-256 `d911faf99e4edda8f3aaedf38c80e6cb104fc909448f34f4e5c67aba6ed64a73`；Vault 憑證 `146e90c96c54e21c2b74fd33f6124cdcebaf97b367adc3f634c6f2c36bcfb847`，APK `5f74983e043e32db06b8e461a4c9055df4cac523853a7d005847930be7bd9aef`。`verify_qr_apks.py` PASS。Play Console 尚未建立並核對應用程式簽署憑證，跨管道更新仍待驗證。
  - 上傳 Play 的 AAB 以上傳金鑰簽署：Wallet 上傳憑證 `d3811cdf51e01d2fa03fdf2e447525b85b165e61b995f311832952cde7586868`，AAB `0359f7eadf82ad3a78e4687e6e76b2ded5f2e36df8ff591b6d0b5ef3663a2083`；Vault 上傳憑證 `eb8dd99564bfbd693e90688f1150fc8df0ce7d692d4280e5513bd70501e9cc7e`，AAB `9151ca1a53760b610c037cff8c3dd2029dfd43d95dd73ccbcb1a5cace4ec61ac`。本輪重新執行 `verify_play_bundle.py` PASS；以丟棄式臨時 signer 產生的 Wallet 85、Vault 85 個 split APK 全部通過 16 KiB zipalign。臨時 signer 只用於對齊檢查，不代表 Play 的實際簽章。
  - r20 APK 在專用 ARM64 16 KiB 模擬器覆蓋安裝成功，裝置上 APK SHA-256 與候選一致，兩個 MainActivity 冷啟動成功；App drawer 顯示兩個新圖示與名稱。Wallet 首頁顯示正常；Vault 因 `FLAG_SECURE` 截圖為黑畫面，僅以 UI hierarchy 確認套件、離線／解鎖／關於文字與安全視窗旗標，未宣稱完成 Vault 視覺驗收。
  - 建置主機的 `check_env.py --strict` PASS。

### 已知限制

- r20 的兩個 App 只支援測試網。[ADR-005](docs/ADR/ADR-005-mainnet-networks.md) 已於 2026-10-21 接受；後續 Phase 0 補完在獨立的 `phase-0` 分支，沒有包含在本版產物。各期完成並通過審查前不發布主網版本，現況見 [Android 工作狀態](docs/ANDROID_STATUS.md)。
- 所有裝置驗證都在 Android 模擬器與測試資料上執行；實體裝置驗收（相機對掃、ARM64 簽署與生物識別、S8、實體 bitcoind 流程）改由 Google Play 封閉測試補足，尚未開始；OKX 簽章回傳與 iOS 執行（實機與模擬器）也尚未驗證。
- 從 `1.2.0` 以前的測試建置（本機開發憑證 `fde363be…` 簽署）升級：簽章不同，無法覆蓋安裝，需先解除安裝；Vault 的金庫檔會一併刪除，請先保留助記詞或加密備份。
- 既有的 P2 缺陷仍在：EVM 前一筆仍是「結果待查」或「廣播中」時，送出頁仍可用下一個 nonce 建立另一筆請求；目前沒有阻擋或「不要建立新請求」提示。若前一筆其實已送出，兩筆都會執行。主網前必修（`docs/REMAINING_WORK.md` 已知缺陷 1）。
- 其他仍開放的項目（相機設定返回後沒有原地重新接收的入口、舊 BTC 紀錄的被拒網址只在第一次開啟時顯示、不同舊／新 RPC 網址時的提示例外、`adb reverse` 的 loopback 說明例外、未檢查 HTTP 轉址目標、掃描器相機佇列與外掛內部細節等）見 `docs/REMAINING_WORK.md`。

## [1.2.0] - 2026-10-20

範圍：`v1.1.0` 之後到 `dc33b42`；兩個 App 的版本號為 `1.2.0+4`。之後的 commit 只更新文件。

### 新增

- Vault：
  - 解鎖後的畫面會顯示操作錯誤；匯出對話框在系統檔案選擇器開啟前就失敗時（例如忙碌中、無法開啟選擇器），錯誤直接顯示在對話框內（`62c0c79`）。
  - 加密備份的存檔結果：系統檔案選擇器會讓 Vault 離開前景並上鎖，所以存檔成功或失敗改在鎖定畫面顯示，下一個操作時清除（`62c0c79`）。
  - 相機權限被永久拒絕時，顯示說明與「開啟系統設定」按鈕（Android，`4a255d1`）。
- Wallet：
  - 配對、EVM 簽章、BTC 簽章三個掃描入口，在相機權限被拒時提供「開啟系統設定」（Android；mobile_scanner 分不出單次與永久拒絕，所以任何一次拒絕都會顯示，`9f67bcf`、`b655864`、`be83adc`）；系統設定無法開啟時說明如何手動開啟（`5c89ca0`）。EVM 簽章入口另外加入返回後的恢復說明（`4485adb`）。注意：`r17` 走查發現，Android 上 EVM 簽章掃描一送出權限請求就撤銷接收授權，這段說明和設定按鈕實際看不到；配對與 BTC 入口則受權限請求迴圈影響（見已知限制）。
  - EVM 建好的待簽請求 QR 會以螢幕閱讀器播報（`8ff1b18`）；BTC 尚未加入。
- 建置與檢查：
  - Android release 建置在有 `android/key.properties`（或環境變數 `FCW_KEY_PROPERTIES` 指定的檔案）時改用上傳金鑰簽署；指定的檔案不存在或欄位空白時建置失敗，不會悄悄改用 debug 憑證；兩者都沒有時仍是 debug 憑證簽署的測試建置（`e8d81b4`、`fc024fb`）。相對路徑的 `storeFile` 以該設定檔所在目錄為準（和 Flutter 範本以 `android/app` 為準不同）；`FCW_KEY_PROPERTIES` 同時套用到兩個 App；兩個 App 各用自己的上傳金鑰時，請分開建置並各自設定這個變數，或改用各 App 的 `android/key.properties`；這個變數設錯時，所有 Gradle 工作都會失敗。
  - `tools/release_checks/verify_qr_apks.py` 比對 APK 的 versionCode／versionName 與 `pubspec.yaml`，並以 apksigner 記錄實際簽章憑證，可用 `--expect-cert-sha256` 要求特定憑證（`0bd3a3e`、`4076225`）。

### 變更

- 主指紋一律以大寫顯示（Vault `7b60e49`、Wallet `70e5bcd`、簽章恢復 `1262384`）。
- 原生「待簽請求已達保留上限」的錯誤改以中文說明（`2fad31a`）。
- BTC 簽章結果不再顯示 Chain ID；多幀簽章 QR 預設暫停，畫面提示按 QR 下方的播放鍵（▶）開始輪播（`5a8135a`、`504e4ef`、`2295cb6`）。
- 備份抽考的兩個單字欄改為遮罩輸入（`8342f3a`）。
- BTC：重新同步 descriptor 時保留節點既有的範圍，不再出現「new range must include current range」（`953bd1e`）；找零改送到節點追蹤範圍內第一個從未收款的內部地址，不再固定用 `/1/0`（`de8a77e`）。同步需要 Bitcoin Core 22 以上（`listdescriptors`）。
- RPC 回 HTTP 401／403 時說明是認證或權限問題，不再當成節點無法連線（`6f3ded7`）。
- 建好的待簽請求 QR 卡會完整捲入畫面（EVM `988270a`、BTC `dc33b42`）。

### 修正

- EVM 送出狀態：
  - 送出後離開前景，紀錄改為「結果待查」並存檔，只能查詢同一筆交易，查無結果才提供重送（`c653aad`）。
  - 送出前就離開前景，回到送出前的狀態並說明本次未傳送交易（`d92181b`）。
  - 已撤銷的舊一次送出，不會清掉較新一次送出的「已送出」旗標（`46ba836`）。
- BTC：`sendrawtransaction` 收到 HTTP 401／403 時改為「結果待查」，因為節點前方的代理可能已經轉送交易；查詢確認節點沒有這筆交易後，才能重送同一份已簽交易或封存（`fb483ee`）。
- 在系統設定開啟相機權限並回到 App 後，掃描器清除舊的錯誤訊息（`6d295bc`）。
- Wallet 在備份檔案選擇器的結果回來前，拒絕開啟系統設定（`55ae946`）。

### 基礎建設

- 主機測試在 macOS／Linux 也可用 `WALLET_FFI_PATH`／`VAULT_FFI_PATH` 指定原生庫（`9adf898`）。
- 新增 `.gitattributes`，文字檔預設以 LF 簽出，Windows 的 `.bat`／`.cmd` 保留 CRLF（`c99b7f9`）。
- iOS 核心建置腳本容忍 Xcode `nm` 失敗（`717611f`）。
- 兩個 App 版本號升為 `1.2.0+4`（`e7797ae`）。

### 測試

- macOS 與 Windows（host 原生庫）在 `dc33b42` 各跑一次全套，結果相同：`design_system` 29、`qr_ui` 38、`public_models` 267、`wallet` 176、`vault` 153，共 663 項測試通過；五個套件 `flutter analyze` 均無問題；`tests/release_checks/test_verify_qr_apks.py` 12 項通過。
- 補上 BTC 建立請求時存檔失敗會保留輸入，以及開啟掃描器前取消焦點的 widget 測試（`77758a8`）。
- 行為修正大多附回歸測試；第 12、13 輪審查在獨立副本把主要修正換回修正前，對應測試都會失敗。沒有自動化測試的有：Gradle 簽章設定（`e8d81b4`、`fc024fb`，以離線 Gradle `signingReport` 手動驗證）、Wallet 原生檔案選擇器忙碌防護（`55ae946`，只做離線 Kotlin 編譯）、APK 版本號比對（`0bd3a3e`；`test_verify_qr_apks.py` 只測簽章解析）、`.gitattributes` 與 iOS 建置腳本（`c99b7f9`、`717611f`），以及文案修改（`5c89ca0`、`504e4ef`）。

### 驗證

- 三方獨立 AI 審查（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon，以最嚴格判決為準）：
  - 第 12 輪審 `97eafba..e7797ae`：Codex 與 Argon 為 REQUEST CHANGES，Opus 為 APPROVE WITH MINOR FIXES；依最嚴格判決要求修改。三家都指出 BTC 送出收到 401／403 被當成「未送出」，可能導致重複付款。
  - 修正後第 13 輪審 `e7797ae..dc33b42`：Argon APPROVE，Codex 與 Opus APPROVE WITH MINOR FIXES。第 13 輪新增的小問題預定於 `1.2.1` 修正（見已知限制）；其他既有小問題的排程見 `docs/REMAINING_WORK.md`。
- Android 模擬器走查（ARM64 16 KiB，全部是測試資料）：
  - 候選 `r16`（`e7797ae`）8 個流程通過：啟動、配對、EVM 簽署與廣播（本機 Anvil block 2）、BTC 重複同步與兩筆交易的找零索引（regtest block 111、112）、離開 BTC 畫面後清空 RPC 憑證、Vault 備份存檔結果、Vault 相機權限永久拒絕的設定流程、EVM 廣播期間離開前景（以延遲代理觸發，Anvil block 3）。
  - 候選 `r17`（`dc33b42`）補走本輪改到的流程，7 項中 6 項通過：
    - BTC 送出後節點前方回 HTTP 403（故障代理先轉送再回 403）：顯示「結果待查」，只剩查詢；查詢得到「待確認」，挖礦後「已確認」（regtest block 113）。
    - BTC 建好請求後，整張 QR 卡連同播放鍵自動進入畫面（411×914 dp 與 360×640 dp）。
    - EVM 送出前離開前景：回到「簽章已驗證」並說明本次未傳送；再廣播只送出 1 筆（Anvil block 5）。送出後離開前景仍為「結果待查」，查詢後「已確認」（block 6）。
    - Vault 多幀簽章的播放提示與播放鍵一致。
    - EVM 與 BTC 各完成一次完整簽署與廣播（Anvil block 4、regtest block 114）。
    - 未通過：相機權限被拒時的 Wallet 流程。掃描器會反覆要求相機權限，永久拒絕後 Android 會把 Wallet 從畫面上關閉（以「rapid activity launch」移除它的工作視窗）；EVM 簽章掃描遇到權限視窗就撤銷接收授權，看不到新加的說明。這兩個問題在 `1.1.0` 之前就存在，預定於 `1.2.1` 修正（見已知限制）。
- 產物（候選 `r17`，重用已檢查的 `r5` 原生庫，Rust 輸入未變；靜態來源、ELF／RELRO／ZIP 16 KiB 檢查 PASS；本機開發憑證 `fde363bec8539d5e03afca6620fa8265c28bc7445840cf3b4d821fc36f59b011` 簽署；建置主機的檢查紀錄標示 `source_dirty: true`：忽略 CR 行尾差異後，工作樹與 `dc33b42` 只剩 3 個自動產生的 `.flutter-plugins-dependencies` 有差異；其餘列出的檔案（包含為對齊重用的 `r5` 原生庫而保留 CRLF 的 Rust／Cargo 輸入，以及兩份 Android `GeneratedPluginRegistrant.java`）在忽略 CR 行尾後沒有內容差異。差異清單與建置當時的工作樹狀態保存在私有存檔的本機證據中）：Wallet SHA-256 `16fe0fe0e9cb89cbffc94a667077bcaa9e7807c306cc8041007204547fd2e89b`，Vault SHA-256 `f1add8d14f7ba0719c10f91c72924089c857054d7dc053bafa337ae58f6d6772`。`r15` 由 `e7797ae` 建置，但簽章設定檢查仍比對舊寫法而中止，未作為產物。

### 已知限制

- 兩個 App 仍只支援測試網；主網設計文件 ADR-005（`docs/ADR/ADR-005-mainnet-networks.md`，目前在私有分支，尚未併入本倉庫）仍在審查中，通過前不寫主網程式碼。
- 所有裝置測試都在 Android 模擬器與測試資料上執行；實體裝置驗收（相機對掃、ARM64 簽署與生物識別、S8、實體 bitcoind 流程）改由 Google Play 封閉測試補足，尚未開始；OKX 簽章回傳與 iOS 執行（實機與模擬器）也尚未驗證。
- APK 以本機開發憑證（`fde363be…`）簽署，為測試建置而非商店發版，不可用於真實資產保管。之後以正式金鑰簽署的版本無法覆蓋安裝本測試建置，需先解除安裝；Vault 的金庫檔會一併刪除，請先保留助記詞或加密備份。
- Wallet 相機權限被拒時（`1.1.0` 之前就有，預定於 `1.2.1` 修正）：掃描器每次回到前景都重新要求權限，永久拒絕後會在短時間內被系統自動拒絕上百次，最後 Android 會把 Wallet 從畫面上關閉（以「rapid activity launch」移除它的工作視窗）；EVM 簽章掃描遇到權限視窗（包括第一次按「允許」）就撤銷這次接收授權，需重新進入；授權後第一次重新進入 EVM 掃描會顯示「無法使用相機：controllerAlreadyInitialized」（模擬器 2/2 重現），再進入一次即正常。
- 第 13 輪審查以下小問題預定於 `1.2.1` 修正：極端字級下 EVM 簽章掃描的權限說明被底部面板遮住；EVM 重送在送出前被撤銷時的說明；BTC 送出期間離開前景時沒有說明；`sendrawtransaction` 的 401／403 文字仍寫「遭節點拒絕」；APK 檢查把不認得的憑證標成「non-debug」，且檢查使用 `assert`。另外三項仍開放、未排定版本：相機設定返回後的原地重新接收入口、未成熟 coinbase 的找零例外、待簽請求上限的穩定錯誤碼。
- 另有一項既有的 P2 缺陷：EVM 前一筆仍是「結果待查」或「廣播中」時，送出頁仍可用下一個 nonce 建立另一筆請求；目前沒有阻擋或「不要建立新請求」提示。若前一筆其實已送出，兩筆都會執行。目前只有測試網，主網前必修（見 `docs/REMAINING_WORK.md`）。
- 剩餘工作與已知問題清單見 [`docs/REMAINING_WORK.md`](docs/REMAINING_WORK.md)。

## [1.1.0] - 2026-10-18

範圍：`8117a49` 之後到標籤 `v1.1.0`；兩個 App 的版本號為 `1.1.0+3`。

### 新增

- 建立視覺識別與共用設計系統（`2264535`、`58ed674`）：
  - Wallet 採用藍色系並跟隨系統淺色／深色主題。
  - Vault 採用深綠色系並強制深色主題（`ThemeMode.dark`）。
  - 兩 App 的 AppBar 常駐角色徽章（`FcwRoleBadge`），並設為獨立無障礙語意節點（`Semantics(container: true)`），不覆寫 AppBar 標題的讀屏名稱。
  - 新增設計 token（`packages/design_system/lib/src/tokens.dart`）：間距刻度、圓角規則（按鈕膠囊形、輸入框 14、卡片／橫幅 20、底部面板／對話框 28）、語意色調 `ThemeExtension`（含完整 `copyWith` 與逐色 `lerp`）、僅使用系統字型的等寬與表格數字樣式。
  - 新增共用元件（`packages/design_system/lib/src/components.dart`）：面板（`FcwPanel`）、狀態標籤（`FcwStatusPill`）、橫幅（`FcwBanner`）、輸入欄位、金額主視覺（amount hero）、角色徽章（`FcwRoleBadge`）與等寬代碼區塊（`FcwCodeBlock`）。
- 掃描器新增取景遮罩、中央透明取景窗與四角標記，遮罩位於頂部控制列與底部 HUD 下方（`2264535`、`58ed674`）。
- 動態 QR 新增幀進度條；滑動確認（`SlideToConfirm`）新增膠囊軌道與等高進度填色（`2264535`、`281eebb`）。

### 變更

- Vault 交易審查畫面改為「所見即所簽」結構：金額置頂，地址、派生路徑與摘要使用等寬區塊，所有欄位預設展開（`2264535`）。
- 助記詞顯示改為依寬度量測 1～3 欄的 tile，在 320dp、2 倍字級的 12／24 字案例中單字不會從中間斷開，取代在 320dp 寬度、2 倍字級下會截斷單字的舊 `Chip`（`2264535`）。
- Vault 首頁「離線簽章」標籤改為中性角色標籤（`FcwTone.neutral`），避免在無法自動驗證裝置離線時呈現通過狀態（`58ed674`）。
- Wallet 帳戶卡移除多出的縮寫地址，保留收款與帳戶資料處的完整可選取地址；手刻錯誤橫幅統一改用共用橫幅（`281eebb`）。
- 主題建構函式的 `role` 改為必填參數，移除未使用的 `FcwSectionHeader` 與 `valueStyle`（`58ed674`）。
- 兩 App 版本號升為 `1.1.0+3`（build number `2` 已由測試候選 `r9`–`r12` 使用）（`7844740`）。

### 修正

- EVM 建立待簽交易後自動捲動至 QR 區塊，且建置期間停用按鈕（修正實測連點產生 3 筆請求並取消前 2 筆的問題）（`0e07fad`）。
- BTC 建立新草稿時清空收款地址、金額與手續費（`0e07fad`）。
- 開啟掃描器前先取消輸入框焦點，返回畫面時不再自動彈出鍵盤（`0e07fad`）。
- Vault onboarding 錯誤顯示於操作按鈕旁並自動捲入畫面；相同錯誤重複發生時亦重新排程畫面更新與捲動（`0e07fad`、`281eebb`、`58ed674`）。
- `FcwPanel` 改以 `Material` 為底，恢復面板內 `ListTile`／`ExpansionTile` 的點擊漣漪與鍵盤焦點框，並消除 Flutter 3.47 的 `ListTile` 背景斷言失敗（`58ed674`）。
- 主題展開區段內容頂部加上 16px 內距，修正第一個輸入框浮動標籤（如 `RPC 網址`）在 2 倍字級下被裁切的既有問題（`8117a49` 起存在）（`58ed674`）。

### 測試

- Windows（host 原生庫）：在 `58ed674`、`0dff656` 與 `51e8759` 各跑一次全套，結果相同：`design_system` 27、`qr_ui` 33、`public_models` 267、`wallet` 146、`vault` 135，共 608 項測試通過；五個套件 `flutter analyze` 均無問題。
- macOS 相容性檢查（Flutter 3.47.2）：`wallet`、`vault`、`design_system`、`qr_ui` 測試通過，`ListTile` 背景斷言失敗 0 次（修正前 `wallet` 59 項、`vault` 22 項失敗）。
- 新增測試涵蓋：兩角色淺色／深色主題 WCAG AA 對比、320dp 寬度與 2 倍字級版面、12／24 字助記詞不從單字中斷行（含變異檢查）、AppBar 標題語意、Vault 強制深色、面板漣漪、首個浮動標籤不裁切、重入建置防護（含防止取消進行中建置的測試 `16aec2a`），以及三項可用性修正的回歸測試（掃描前取消焦點以模擬器實測確認，尚無自動化測試）。

### 驗證

- 三方獨立 AI 審查（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon，以最嚴格判決為準）：UI 改版（`2264535`～`497f3d6`）共五輪，第 4 輪 Codex、Argon APPROVE、Opus 小修後可過，第 5 輪 Opus 複審後 APPROVE；發版 commit（版本號、文件與截圖）另經第 6 輪審查（Codex、Opus 小修後可過，Argon APPROVE），文字已依意見修正。
- Android 模擬器走查（均為測試資料，無真實資產）：
  - ARM64 16 KiB 模擬器（`r11`）：EVM 建立請求 → Vault 審查 → 滑動簽署 → Wallet 驗證 → 廣播（本機 Anvil，block 5）；BTC 請求建立；掃描返回不跳鍵盤；新 BTC 草稿清空；onboarding 重複錯誤捲回；24 字 tile 於 1x 與 2x 皆單行。
  - x86_64 16 KiB 模擬器（`r12`）：新建 QA 金庫（12 字 tile 與備份抽考）、配對、入金、Vault 解鎖（App 密碼加裝置 PIN）、審查、滑動簽署、接收、廣播（本機 Anvil，block 14）；另於 ARM64 驗證 `r12` 的 BTC `RPC 網址` 浮動標籤完整顯示。
- 產物（重用已檢查的 `r5` 原生庫，Rust 輸入未變；靜態來源、ELF／RELRO／ZIP 16 KiB 檢查 PASS；本機開發憑證 `fde363bec8539d5e03afca6620fa8265c28bc7445840cf3b4d821fc36f59b011` 簽署）：
  - 候選 `r12`（`58ed674`，`1.0.0+2`）：Wallet SHA-256 `1c6f204e4c7ca4b5daf6d086640ac547587fd7f766c1fc57b82ac324e93003ad`，Vault SHA-256 `0106c4b9a5b5c5fdbe99c3c81d5c43c6d1e6c0e982ff616b96a97b2bae294a5f`。
  - 發版候選 `r14`（`7844740`，`1.1.0+3`）：Wallet SHA-256 `cb35bd968f689f6c6318f35ea547c2f36c0f82738be49c699dea005195508ccd`，Vault SHA-256 `19efe1876f8c92395a2b91dfaf623f8ebbb0c83304bdbed60b3c6e656e6bf9b6`。`r13` 由同一個 commit 建置，但檢查步驟仍比對舊版本號而中止，未作為產物。
- 1.1.0（`r14`）已安裝於兩台模擬器：ARM64 完成 EVM 建立、Vault 審查、滑動簽署、驗章與廣播（本機 Anvil block 2），並以模擬相機播放多幀 QR 確認掃描器；x86_64 安裝後 Wallet 與 Vault 正常啟動，crash buffer 無紀錄。

### 已知限制

- 所有裝置測試均在 Android 模擬器與測試資料上執行，不涉及真實資產。
- 尚未完成實體相機光學對掃、實體 ARM64 手機簽署、真實裝置生物識別、S8 實機驗收、OKX 回傳路徑、實體裝置 bitcoind 流程及 iOS 執行。
- APK 以本機開發憑證（`fde363be…`）簽署，為測試建置而非商店發版，不可用於真實資產保管。
- 剩餘工作與已知問題清單見 [`docs/REMAINING_WORK.md`](docs/REMAINING_WORK.md)。

## [1.0.0] - 2026-10-18

基準 commit：`8117a49`（QR 核心版本與審查後修正，驗收候選 `r9`）。

- 完成 `apps/wallet` 與 `apps/vault` 的 local/testnet QR 離線簽署核心流程：BIP39 金庫建立與抽考、AES-256-GCM（PBKDF2-HMAC-SHA256 600,000 次）加密儲存、系統裝置驗證 gate、自有 Wallet 與 OKX EVM 公開配對、EVM（Legacy／EIP-1559／ERC-20）與 BTC（regtest PSBT v0／P2WPKH）多幀 UR 簽署與廣播、Vault 加密備份與 Wallet 公開備份分步恢復。
- 完成審查後修正：BTC 查詢世代與前景隔離、mempool 無 `confirmations` 欄位視為待確認、節點以 `-5`（`No such mempool or blockchain transaction`）證明查無交易才允許重送、公開備份封存摘要與核心重建比對、原生 UR 會話容量上限與重設、密碼欄位重輸確認與回鎖清除。
- 測試與驗收（候選 `r9`，版本 `1.0.0+2`）：Windows 4 個套件共 574 項測試與 Rust workspace 144 項測試通過；於 x86_64 與 ARM64 16 KiB 模擬器完成公開備份恢復、EIP-1559、Bitcoin Core 30.2 regtest 故障注入及模擬光學雙向流程驗證。
- 產物（`r9`，開發憑證 `fde363be…` 簽署）：Wallet SHA-256 `d9ef7009c77038c811919bc6d6086a7786ad5b0eb0ae4acbcd516e898e6abe91`，Vault SHA-256 `ec07edfd922762b7ce938677266735c4c0404311732a2f3471f9e6c5f4cd3866`。詳見 [`docs/FCW_CORE_WALLET_FIRST.md`](docs/FCW_CORE_WALLET_FIRST.md) 與 [`docs/FCW_REMEDIATION_2026-10-18.md`](docs/FCW_REMEDIATION_2026-10-18.md)。
