# 尚未完成與後續工作清單（Remaining Work）

本文件彙整 `1.2.1` 發版時所有尚未完成的主網工作、實機驗收、已知缺陷、技術債、平台依賴限制與發版項目。
「來源」欄提到的「UI 改版審查」、「發版審查」、各輪審查、修正回報、模擬器走查與「第三輪 Mac 驗收紀錄」都是私有存檔中的報告，不在公開倉庫內；摘要收錄於 `docs/FCW_REMEDIATION_2026-10-18.md`。
依類別分組，組內依優先級（`P1` 最高、`P2` 次之、`P3` 改善項目）排序。`1.2.0` 清單中已在 `1.2.1` 修正的項目已移除，改列於 `CHANGELOG.md`。

---

## 目前順序：Android 優先

2026-10-22 持有人指定 Android 優先。先補 r20 測試網候選的本輪流程驗收與 Play／封閉測試證據；Phase 0 是分開的開發基礎，沒有包含在 r20 產物中。iOS 排在 Android 工作之後；各項實機與發布缺口仍維持開放。分支、既有證據與執行順序見 [ANDROID_STATUS.md](ANDROID_STATUS.md)。

## 主網支援

### 1. [P1] EVM 與 Bitcoin 主網
- **內容**：兩個 App 目前刻意只支援測試網：EVM 簽署白名單只有 Sepolia、本機 1337 與 31337，Bitcoin 只接受連到使用者自架節點的 `regtest`。持有人已於 2026-10-20 決定：
  - 開放 Ethereum 主網、Arbitrum One、OP Mainnet、Base、Polygon PoS 與 Bitcoin 主網。
  - Bitcoin 改用 Esplora 公開服務，預設 mempool.space，可改自訂網址。
  - 正式版保留 Sepolia 與 Bitcoin signet，並清楚標示為測試網；本機 Anvil／Hardhat 與 `regtest` 只留在開發版。
  - 上架前不做第三方安全稽核，App 與商店說明須標示「未經第三方安全稽核，請先小額使用」。
- **位置**：`crates/public_core/src/policy.rs`（`allowed_chain_ids`）、`crates/vault_ffi/src/lib.rs`（測試網拒絕點）、`crates/public_core/src/bitcoin.rs`、`apps/wallet/lib/services/bitcoin_rpc_client.dart`（`verifyRegtest`）、兩個 App 的網路與帳戶設定。
- **原因**：開放主網後簽錯就是真實資產損失。主網盤點找出的高風險點包括：代幣表未依鏈區分（小數位數錯誤會讓金額差上兆倍）、非 P2WPKH 輸出只顯示 `script:hex`、Vault 在簽署時才從 PSBT 路徑反推網路，以及固定的手續費上限。
- **建議下一步**：[ADR-005](ADR/ADR-005-mainnet-networks.md) 已於 `69674e5` 接受，本文收錄該文件的原始內容。Phase 0 補完快照 `fc955d6` 已通過限定範圍的審查與驗證，整合入口為 [MR !2](https://gitlab.com/aa22396584/mobile_cold_wallet/-/merge_requests/2)（目標 `phase-0`）；測試網 release 表與後續主網階段仍分開。先依 Android 優先順序驗收，後續各期完成並通過審查前不發布主網版本。
- **來源**：2026-10-20 與 2026-10-21 持有人決定；主網盤點、外部事實查核與 ADR-005 審查（私有存檔中的報告）。

---

## 需要實體設備的驗收

持有人已決定以 Android 模擬器驗收，加上 Google Play 封閉測試的測試者回報，取代專用實機。以下項目在取得實機結果前仍視為未驗證。

### 1. [P1] 實體相機對相機雙向光學掃描驗收
- **內容**：在兩支實體裝置之間，以真實相機與螢幕完成配對、待簽交易（單幀與多幀動態 UR）及簽章回傳的雙向光學掃描。
- **位置**：`packages/qr_ui/lib/src/scanner/airgap_scanner.dart`、`apps/wallet`、`apps/vault` 掃描與 QR 顯示畫面。
- **原因**：目前僅完成手動貼上 UR 與模擬器 gRPC `setEnvironment` 影片注入驗證，未涵蓋真實鏡頭對焦、環境光線反射與螢幕摩爾紋（moiré）。
- **建議下一步**：在兩支實體手機安裝最新候選版本，執行 EVM 與 BTC 雙向相機掃描並保存驗收收據；Vault 的多幀簽章需先按「播放」（`1.2.0` 起畫面有提示）。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第二輪、第三輪「仍未完成」）、第三輪 Mac 驗收紀錄（模擬光學限制）。

### 2. [P1] 實體 ARM64 手機簽署與真實裝置生物識別驗證
- **內容**：在實體 ARM64 Android 手機上完成 Vault 真實裝置生物識別／鎖定密碼解鎖、交易審查、滑動簽署，以及前景切換時的自動上鎖驗證。
- **位置**：`apps/vault/lib/screens/vault_home_screen.dart`、`apps/vault` 原生裝置驗證與簽署流程。
- **原因**：S24 上一輪因前景被其他 App 占用而中止簽署；目前 ARM64 簽署與指紋驗證僅在模擬器完成，不能替代實體硬體與系統生物識別驗證。
- **建議下一步**：在 ARM64 實機保持前景完成完整簽署流程，並驗證生物識別與前景離開自動上鎖；同時確認 `1.2.0` 的備份存檔結果提示與「開啟系統設定」流程。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第二輪、第三輪「仍未完成」）、第三輪 Mac 驗收紀錄。

### 3. [P1] Samsung Galaxy S8 實機驗收
- **內容**：在 S8 實體手機上安裝最新候選版本，驗證裝置驗證、金庫操作、備份還原與簽署流程。
- **位置**：`apps/vault`、`apps/wallet`。
- **原因**：S8 為相容性矩陣中的目標實機裝置，尚未對本輪候選版本執行實機驗收。
- **建議下一步**：於 S8 實機安裝最新測試候選並執行標準驗收案例。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第二輪、第三輪「仍未完成」）、第三輪 Mac 驗收紀錄。

### 4. [P1] stock OKX 簽章回傳與廣播驗收
- **內容**：將 Vault 簽署後的回傳 QR 由 stock OKX 掃描收回，並在測試網完成交易廣播與節點確認。
- **位置**：`apps/vault`（OKX EVM 配對與回傳）、`crates/ur_adapter`。
- **原因**：目前僅完成 OKX 雙 key adapter 配對，以及讀取 stock OKX 畫面上的待簽 QR（當時由另一座新金庫讀取並拒絕，沒有核准、回傳或廣播），尚未驗證簽章回傳至 OKX 及後續廣播。
- **建議下一步**：以和 stock OKX 配對的同一座測試金庫（持有人自備、只用於測試網；新建立的金庫會拒絕簽署那張請求，不能替代）與 stock OKX 6.192.0 完成簽章掃回與廣播驗收；或改用公開 BIP-39 測試向量金庫（主指紋 `73C5DA0A`）重新與 stock OKX 配對後，以新的請求完成同一流程，讓結果可由他人重現。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第二輪、第三輪「仍未完成」）、第三輪 Mac 驗收紀錄。

### 5. [P2] 實體裝置連接 bitcoind 的 BTC 流程驗收
- **內容**：在實體 Android 手機上連接 Bitcoin Core（`regtest`、`txindex=1`）完成 descriptor 匯入、PSBT 建立、簽署、廣播及斷線重查流程。
- **位置**：`apps/wallet/lib/screens/bitcoin_send_screen.dart`、`apps/wallet/lib/services/bitcoin_rpc_client.dart`。
- **原因**：BTC 修正僅在單元／widget 測試與 Mac ARM64 模擬器驗證，尚未在實體手機執行。主網改用 Esplora 後，驗收對象會改為 signet／主網的 Esplora 後端。
- **建議下一步**：透過 `adb reverse` 將實體手機連接本機 `bitcoind` regtest 節點，執行完整 BTC 轉帳與異常恢復驗收。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第二輪、第三輪「仍未完成」）。

### 6. [P2] iOS 實機執行與雲端備份排除驗證
- **內容**：在實體 iOS 裝置上簽署並執行 Wallet 與 Vault，驗證相機掃描、生物識別、簽署流程及儲存目錄排除自動雲端備份設定。
- **位置**：`apps/wallet/ios`、`apps/vault/ios`。
- **原因**：目前僅完成 `flutter build ios --no-codesign --release` 編譯通過，尚未在 iOS 實機或模擬器上執行。
- **建議下一步**：在測試用 iPhone／iPad 配置開發者簽章並執行端到端實機測試。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第二輪、第三輪「仍未完成」）、第三輪 Mac 驗收紀錄（發現 2）。

### 7. [P2] UI 改版細節（面板漣漪與焦點框）實機確認
- **內容**：在實體裝置上確認 `FcwPanel` 改為 `Material` 後，交易紀錄列表與展開區段的點擊漣漪（ink）與外接鍵盤焦點框視覺表現。
- **位置**：`packages/design_system/lib/src/components.dart`、`apps/wallet`、`apps/vault`。
- **原因**：`58ed674` 的面板漣漪與焦點框已有 widget 測試，模擬器走查沒有特別記錄點擊漣漪，也尚未在實機螢幕確認實際觸控回饋。
- **建議下一步**：於實機驗收時一併檢查列表點擊漣漪、展開區段與掃描器頂部控制列亮度。
- **來源**：UI 改版審查第 3 輪（Opus）（不阻擋的觀察 2）、UI 改版審查第 4 輪（Opus）（D3）。

### 8. [P2] 相機權限流程的實機時序
- **內容**：`1.2.1` 的相機權限修正在模擬器與測試中驗證過，但權限視窗、透明權限畫面（永久拒絕時）與焦點事件的先後順序依裝置與 Android 版本而異。待確認的情境：永久拒絕相機後在「掃描簽署結果」按「清除並重新掃描」；第一次允許相機後、相機還在啟動時拉下通知欄（預期撤銷接收授權）；到系統設定開啟相機再返回。
- **位置**：`packages/qr_ui/lib/src/scanner/airgap_scanner.dart`、`apps/wallet/lib/screens/scan_signature_screen.dart`。
- **原因**：豁免只在權限請求開著時生效。若系統先產生 inactive 事件，但 Dart 較晚才處理，事件可能恰好落在一次沒有對話框、尚未回覆的 `request` 期間而被豁免；若 Dart 在請求前或回覆後處理 inactive，則會撤銷授權（安全方向）。實機測試要區分系統事件產生時間與 Dart 收到事件的時間。
- **建議下一步**：封閉測試時在至少兩種 Android 版本上走過上述情境並保存紀錄。
- **來源**：第 19 輪審查（Opus O14、Grok Minor 2）。

---

## 已知缺陷（使用者看得到）

### 1. [P2] EVM 前一筆「結果待查」時仍可建立下一筆請求
- **內容**：送出頁以 `eth_getTransactionCount(…, 'pending')` 取得 nonce；同一帳戶前一筆仍是「結果待查」或「廣播中」時，仍可用下一個 nonce 建立另一筆請求。目前沒有阻擋或「不要建立新請求」提示；該提示只出現在離開前景後的廣播錯誤流程。
- **位置**：`apps/wallet/lib/screens/send_tx_screen.dart`、`apps/wallet/lib/services/node_rpc_client.dart`（`getTransactionCount`）。
- **原因**：若前一筆其實已送出，兩筆都會執行，造成重複付款（目前只有測試網）。
- **建議下一步**：同一帳戶有「結果待查」或「廣播中」紀錄時，阻擋建立新請求或要求先查詢；主網前必修（ADR-005 第 2.5 節的 EVM 付款嘗試模型）。
- **來源**：第 12 輪審查（Opus O3）、第 13 輪審查（Opus）、`1.2.0` 文件審查。

### 2. [P3] 交易紀錄清單仍把舊的「廣播中」紀錄顯示為廣播中
- **內容**：`1.2.0` 之前留在磁碟上的 EVM `broadcasting` 紀錄，在交易紀錄清單仍顯示「廣播中」，點開後才會改為只能查詢同一筆交易。
- **位置**：`apps/wallet/lib/services/transaction_history.dart`（狀態標籤）、`apps/wallet/lib/screens/scan_signature_screen.dart`（`_restore`）。
- **原因**：清單文字與實際狀態不一致，使用者可能以為交易還在送出中。點開後的行為正確，不會重送或建立新請求。
- **建議下一步**：清單顯示時把無法確認是否送出的舊紀錄標為「結果待查」，並補測試。
- **來源**：`1.2.0` Wallet 介面修正回報。

### 3. [P3] iOS 沒有「開啟系統設定」
- **內容**：相機權限被拒時的「開啟系統設定」按鈕只在 Android 提供；iOS 的 `AppDelegate` 沒有對應方法，畫面只顯示「無法使用相機：permissionDenied…」；`1.2.0` 新加的權限說明（包括 EVM 的恢復說明）只在有設定按鈕時才顯示，所以 iOS 也看不到。
- **位置**：`apps/wallet/ios/Runner/AppDelegate.swift`、`apps/vault/ios/Runner/AppDelegate.swift`、各掃描入口的 `onOpenAppSettings`。
- **原因**：iOS 使用者需自行前往系統設定。
- **建議下一步**：iOS 實機驗收時一併以 `UIApplication.openSettingsURLString` 實作並測試。
- **來源**：`1.2.0` Wallet 介面修正回報。

### 4. [P3] 相機設定返回後沒有原地重新接收簽章的入口
- **內容**：首次接收 EVM 簽章時相機權限被拒、到系統設定開啟後返回，這次接收授權已撤銷，必須自行到交易紀錄找回原請求；`1.2.0` 只補了說明文字。`1.2.1` 起，權限視窗本身不再撤銷授權，但到系統設定（離開 App）再返回仍會撤銷。
- **位置**：`apps/wallet/lib/screens/scan_signature_screen.dart`。
- **原因**：多一個操作步驟，使用者可能誤以為要重新簽署。
- **建議下一步**：返回時提供「前往原請求紀錄」按鈕，或在同一畫面重新授權接收。
- **來源**：第 12、13 輪審查（Codex M1）。

### 5. [P3] Vault 審查頁不顯示找零的派生路徑
- **內容**：BTC 審查頁對找零只顯示地址與「已驗證找零」，不顯示 `/1/i` 路徑。
- **位置**：`packages/design_system/lib/src/review_card.dart`、`apps/vault`。
- **原因**：不影響安全（Vault 自己驗證找零屬於本帳戶），但顯示路徑更符合「所見即所簽」，也方便和 Wallet 對照。
- **建議下一步**：在找零列加上派生路徑。
- **來源**：`1.2.0` 模擬器走查（r16）。

### 6. [P3] 舊 BTC 紀錄的被拒網址只在第一次開啟時顯示
- **內容**：`1.2.1` 以前存下公開 `http://` 節點網址的 BTC 紀錄，第一次開啟時網址仍顯示在欄位上並附改網址的指引；但紀錄只保存規則允許的網址，存檔一次後下次開啟欄位是空白，也沒有指引，需整串重新輸入。
- **位置**：`apps/wallet/lib/screens/bitcoin_send_screen.dart`（載入與存檔）。
- **原因**：只在同一個安裝留有 `1.2.1` 以前的 BTC 紀錄時發生。官方 `1.2.0` 測試建置與 `1.2.1` 簽章不同，必須先解除安裝（資料一併刪除），公開備份也不帶 `rpc_endpoint`，所以一般安裝者不會保留該紀錄；自行建置且沿用相同 debug keystore 或自備簽章者仍可能覆蓋升級並遇到。不影響資金安全。
- **建議下一步**：在紀錄加一個只供顯示、永遠不拿來連線的欄位保存被拒網址（同時調整公開備份的欄位白名單），或在網址為空時顯示指引；補「存檔 → 重新開啟」的測試。
- **來源**：第 18 輪審查（Opus M18-2）。

### 7. [P3] 舊 EVM 紀錄改網址指引有資料綁定例外
- **內容**：舊紀錄與目前 RPC 分別是不同的公開 `http://` 網址時，資料綁定檢查可能先以「RPC 綁定已變更」拒絕重播，未必會顯示改用允許網址的指引。
- **位置**：`apps/wallet/lib/screens/scan_signature_screen.dart`。
- **原因**：使用者會知道紀錄不能重播，但不一定知道下一步是修改節點網址；不會繞過資料綁定或送出請求。
- **建議下一步**：在綁定拒絕文案中偵測被網址政策拒絕的舊 RPC，補上修改節點網址指引，並涵蓋「舊網址與目前網址不同」的測試。
- **來源**：第 19 輪審查（Opus O5）、第 20 輪審查（Codex M20-2）。

### 8. [P3] loopback 說明未涵蓋 `adb reverse`
- **內容**：App 把 loopback `http://` 網址說明為本機流量；開發者依文件使用 `adb reverse` 時，手機 loopback 連線會轉送到電腦。
- **位置**：節點網址欄下方說明、`docs/QR_NATIVE_PLATFORMS.md`。
- **原因**：網址仍受開發者明確設定控制，但「只在手機內」的絕對敘述對此開發情境不準確。
- **建議下一步**：把文案改為「通常只在本機；開發轉送可送到電腦」，並補文件／Widget 斷言。
- **來源**：第 19 輪審查（Opus O6）、第 20 輪審查（Codex M20-2）。

### 9. [P2] RPC 自動轉址目標未重新套用網址政策
- **內容**：EVM 與 Bitcoin RPC 用戶端會檢查設定的初始 URL，但目前交由 HTTP client 自動跟隨轉址，沒有在每一個轉址目標重新套用 `https://`／私人網路政策。
- **位置**：`apps/wallet/lib/services/node_rpc_client.dart`、`apps/wallet/lib/services/bitcoin_rpc_client.dart`。
- **原因**：允許的初始網址可回傳指向公開 `http://` 的轉址；第 20 輪以本機代理重現 303 後跟隨 GET，沒有接觸公開主機，也沒有證明交易本文或憑證外洩。
- **建議下一步**：關閉自動轉址並逐跳驗證 `Location`，或提供套用相同政策的 redirect handler；補 EVM／Bitcoin 回歸測試。
- **來源**：第 19 輪審查（Opus O7）、第 20 輪審查（Codex I20-2）。

---

## 主網設計審查確認的現行程式缺陷

[ADR-005 第 15 節](ADR/ADR-005-mainnet-networks.md)（C-01～C-22）逐項核對了原始程式基線在主網前必須修正的問題，並排入各期。已接受的設計文件現已收錄；Phase 0 的完成不代表後續各期缺陷都已修正。下列幾項在本分支的測試網基線也看得到：

- **[P2] C-01**：BTC 建立新草稿時，把已匯出或已驗證但未廣播的請求封存為「已取消」，其輸入不再保留；Vault 若已簽署，舊交易仍可能上鏈。
- **[P2] C-20**：EVM 表單一變動就把已匯出的請求標成「已取消」，nonce 不再保留。
- **[P3] C-09**：公開備份只匯出目前選擇網路的 EVM 紀錄，匯入時把 EVM 帳戶的 Chain ID 覆寫成目前網路。
- **[P3] C-17**：RPC 錯誤訊息會帶出完整網址與遠端回應本文。

C-22（Wallet 對任何主機都接受 `http://`）已在 `1.2.1` 修正，見 `CHANGELOG.md`。

---

## 改善與技術債

### 1. [P2] 助記詞無障礙樹政策與多行助記詞輸入欄
- **內容**：
  - `1.2.0` 已把備份抽考的兩個單字欄改為遮罩輸入。
  - 助記詞單字仍保留在預設無障礙樹中（與 `1.0.0` 相同）；是否對螢幕閱讀器隱藏屬於持有人政策決定。
  - 助記詞還原（`restore_mnemonic_field`）與匯出前重新驗證（`export_backup_mnemonic_field`）是多行明文欄位，`obscureText` 不能用在多行欄位，內容會出現在無障礙樹與 UI 傾印中。
- **位置**：`apps/vault/lib/screens/vault_home_screen.dart`。
- **原因**：無障礙服務可讀取助記詞；測試或除錯工具傾印畫面階層時可能意外留存助記詞明文。
- **建議下一步**：由持有人決定無障礙政策；多行欄位可評估改為逐字輸入格或自訂遮罩元件。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第三輪「已知、未在本輪處理」）、第三輪 Mac 驗收紀錄（發現 4）、`1.2.0` Vault 修正回報。

### 2. [P2] 簽署後 UR 編碼失敗順序、逐幀 `compute()` 效能與實際容量邊界
- **內容**：
  - 檢視 Vault 簽署完成後若 UR 編碼失敗時的狀態保存順序。
  - 優化多幀 UR 掃描逐幀呼叫 `compute()` 的 isolate 開銷，以及大檔案實際容量（2 MiB 邊界）的壓力測試。
- **位置**：`apps/vault`、`packages/qr_ui`、`crates/ur_adapter`。
- **原因**：低階手機連續掃描多幀 QR 時，每幀建立 isolate 可能影響解碼流暢度。
- **建議下一步**：改用長駐 worker isolate 處理多幀 UR 幀解碼，並補齊簽署後編碼失敗順序與大容量備份的邊界測試。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第二輪「已知延後項目」）。

### 3. [P2] 發版檢查工具的剩餘缺口
- **內容**：`1.2.1` 已加入跨平台的 AAB 檢查（`verify_play_bundle.py`）與 Android 工具定位（`android_sdk.py`），並修正 APK 檢查的憑證標示與 `assert`。仍待處理：
  - `verify_qr_apks.py` 仍寫死 Windows 的工具路徑與 `LOCALAPPDATA`。
  - `verify_qr_apks.py` 的 `--expect-cert-sha256` 只能指定一張憑證、同時套用到兩個 APK；正式版兩個 App 各用自己的應用程式簽署金鑰，目前只能不帶這個參數執行，再逐一比對它記錄的簽章者。
  - `check_env.py` 碰到不存在的預設路徑（例如沒有設定 `RUSTUP_HOME` 時的 `~/.rustup`）在 Windows 上會直接拋出例外，而不是回報 FAIL；它也只檢查 NDK 27.0.12077973 的目錄、`source.properties` 與 clang 是否存在，不比對 `source.properties` 裡的版本。
- **位置**：`tools/release_checks/verify_qr_apks.py`、`tools/release_checks/check_env.py`。
- **原因**：發版時要能在任何建置主機以正式憑證直接驗證產物，工具鏈檢查也應明確失敗而不是中斷。
- **建議下一步**：讓 `verify_qr_apks.py` 改用 `android_sdk.py` 並接受每個 App 各自的憑證 pin；`check_env.py` 把路徑錯誤記成 FAIL，並比對 NDK 的 `Pkg.Revision`。
- **來源**：ADR-005 C-15、第 13 輪審查（Opus N1、N2）、`1.2.1` 建置。

### 4. [P3] 待簽請求上限錯誤改用穩定錯誤碼
- **內容**：`1.2.0` 把原生「待簽請求已達上限」錯誤翻成中文，但只能比對 Rust 的英文訊息開頭：UR 路徑把它包成 `ERR_REQUEST_REJECTED`，`PreparedReviewDto.fromJson` 又丟掉 `error_code`。
- **位置**：`crates/vault_ffi/src/lib.rs`（`MAX_RETAINED_PREPARED_REQUESTS`）、`packages/public_models`（`PreparedReviewDto`）、`packages/design_system/lib/src/review_card.dart`。
- **原因**：Rust 改動訊息文字後，畫面會悄悄退回「政策拒絕」並顯示英文。
- **建議下一步**：讓 UR 路徑保留專用錯誤碼並由 DTO 帶出，Dart 改以錯誤碼判斷。
- **來源**：`1.2.0` Vault 修正回報。

### 5. [P3] BTC 找零索引查詢成本
- **內容**：`1.2.0` 起找零改用第一個未收過款的 `/1/i`。查詢方式是推導節點追蹤範圍內約 1000 個找零地址，再依序對已用過的索引各呼叫一次 `getreceivedbyaddress`。
- **位置**：`apps/wallet/lib/services/bitcoin_rpc_client.dart`（`unusedChangeIndex`）。
- **原因**：連到使用者自架的 regtest 節點時可接受，但不適合公開服務。
- **建議下一步**：改用 Esplora 後端時改為 gap-limit 掃描（ADR-005）。
- **來源**：`1.2.0` BTC 修正回報。

### 6. [P3] 助記詞欄寬計算與 `FcwCodeBlock` 內距的隱性耦合（Review Nit N2）
- **內容**：`vault_home_screen.dart` 計算助記詞欄寬時假設水平邊框與內距為 `FcwSpace.md * 2 + 2`，與 `FcwCodeBlock` 內部實作隱性耦合；另 `FcwCodeBlock` 的垂直內距 `10` 未對齊間距刻度。
- **位置**：`apps/vault/lib/screens/vault_home_screen.dart`（助記詞欄寬計算）、`packages/design_system/lib/src/components.dart`（`FcwCodeBlock`）。
- **原因**：若日後調整 `FcwCodeBlock` 內距而未同步更新 Vault 欄寬算式，可能導致欄數少算與單字折行（現有版面測試可捕獲）。
- **建議下一步**：在 `FcwCodeBlock` 公開內距／chrome 寬度常數供 Vault 引用，並將垂直內距改用 token。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第三輪）、UI 改版審查第 3 輪（Opus）（N2）、UI 改版審查第 4 輪（Opus）。

### 7. [P3] 主題 `ExpansionTile` 頂部內距範圍收斂
- **內容**：全域主題為 `ExpansionTile` 展開內容加上 `top: 16` 內距，使第一個子元件不是浮動標籤輸入框的其餘 6 個展開區段也多出 16px 頂部空白。
- **位置**：`packages/design_system/lib/src/app_theme.dart`、`apps/wallet/lib/screens/bitcoin_send_screen.dart`、`apps/wallet/lib/screens/account_screen.dart`。
- **原因**：不影響功能，但讓不以輸入框開頭的展開區段標題下方留白偏大。
- **建議下一步**：改為僅在首個子元件為具浮動標籤輸入框的兩個展開區段（BTC「節點設定」與「網路與節點設定」）設定頂部內距。
- **來源**：UI 改版審查第 3 輪（Opus）（不阻擋的觀察 1）。

### 8. [P3] Wallet 掃描入口共用開啟函式
- **內容**：Wallet 的三個掃描入口（配對、EVM 簽章、BTC 簽章）各自寫一次「先取消焦點」與 `onOpenAppSettings` 的設定。`1.2.0` 已為 BTC 的取消焦點與三個入口的系統設定按鈕補上測試。
- **位置**：`apps/wallet/lib/screens/account_screen.dart`、`apps/wallet/lib/screens/scan_signature_screen.dart`、`apps/wallet/lib/screens/bitcoin_send_screen.dart`。
- **原因**：日後新增掃描入口時容易漏掉其中一項。
- **建議下一步**：抽出共用的開啟掃描器函式。
- **來源**：UI 改版審查第 3 輪（Opus）（C2-M3、C2-M4）、`1.2.0` 修正回報。

### 9. [P3] BTC 找零「從未收款」對未成熟 coinbase 的例外
- **內容**：選找零索引時以 `getreceivedbyaddress(address, 0)` 判斷是否收過款；Bitcoin Core 不把未成熟的 coinbase 輸出算進去，所以剛挖到、尚未成熟的找零地址可能被再次選用。
- **位置**：`apps/wallet/lib/services/bitcoin_rpc_client.dart`（`unusedChangeIndex`）。
- **原因**：只在 regtest 由找零地址直接挖礦時會發生，造成地址重用，不影響找零所有權驗證。
- **建議下一步**：改用 Esplora 後以地址歷史判斷（ADR-005 第 6.4 節）。
- **來源**：第 12、13 輪審查（Codex M2）。

### 10. [P3] 極端字級的助記詞斷字與 BTC 建立 QR 的螢幕閱讀器播報
- **內容**：
  - 極端字級下若單一單字寬於單欄 tile，換行時沒有連字號（hyphen）。
  - `1.2.0` 已在 EVM 建好待簽請求 QR 時發出螢幕閱讀器播報（`8ff1b18`），BTC 尚未加入。
- **位置**：`apps/vault/lib/screens/vault_home_screen.dart`、`apps/wallet/lib/screens/bitcoin_send_screen.dart`。
- **原因**：影響極端放大字級的閱讀，以及使用螢幕閱讀器的使用者在 BTC 建立 QR 後的即時感知。
- **建議下一步**：檢視超寬單字的斷字處理；BTC 建立 QR 後比照 EVM 發出 `SemanticsService` 播報。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第三輪「已知、未在本輪處理」）、UI 改版審查第 3 輪（Codex）、`1.2.0` 文件審查。

### 11. [P3] 共用狀態框元件
- **內容**：BTC 交易狀態與交易詳情的狀態框仍是各自手刻的樣式。
- **位置**：`apps/wallet/lib/screens/bitcoin_send_screen.dart`、`apps/wallet/lib/screens/scan_signature_screen.dart`。
- **原因**：調整樣式時兩處容易不一致。
- **建議下一步**：抽出共用的狀態標題元件放進 `packages/design_system`。
- **來源**：UI 改版審查第 2 輪（Opus，C1-M4 剩餘部分）。

### 12. [P3] 掃描器相機佇列與 `mobile_scanner` 內部細節
- **內容**：
  - 所有掃描器的相機啟動、停止與釋放依序排在一個全域佇列；原生 `start` 若永遠不回覆，佇列會卡住，之後的掃描器都無法啟動相機，需重開 App。尚未在實機觀察到。
  - 掃描器在權限查詢或權限視窗期間被移除時不會再請求或啟動相機，但若已進入外掛的 `start()`，外掛自己的權限查詢與啟動仍會跑完，之後由排在後面的釋放停掉。
  - `request` 拋出錯誤時交給 `start()` 重試，這次重試不在豁免範圍內（安全方向），可能多出一次權限請求。
  - 程式依賴 `mobile_scanner` 6.0.11 的內部細節：channel 名稱、`state`／`request` 的語意、`start()` 被拒時寫入的欄位。`pubspec.yaml` 已精確鎖定版本，升級時要重新核對，`scanner_dispose_test.dart` 與 `scanner_method_channel_denied_test.dart` 會在行為改變時失敗。
  - 佇列是全域狀態，測試失敗時未完成的 Future 會連帶讓同檔後面的測試失敗，只影響診斷。
- **位置**：`packages/qr_ui/lib/src/scanner/airgap_scanner.dart`。
- **原因**：都不影響資金安全，但會影響可用性與升級成本。
- **建議下一步**：佇列操作加上逾時；評估以 `@visibleForTesting` 重設佇列；升級 `mobile_scanner` 時一併檢視（見依賴與平台第 1 項）。
- **來源**：第 18、19 輪審查（Opus O3、O12、O13、O15，Codex M18-1 延續項，Grok Minor 1）。

---

## 依賴與平台

### 1. [P2] iOS Apple Silicon 模擬器受阻於 `mobile_scanner` 6.0.11
- **內容**：`mobile_scanner` 6.0.11 在 iOS 依賴的 Google ML Kit pod 排除了 `arm64` 模擬器架構；Xcode 26 的模擬器僅支援 `arm64`，導致模擬器建置失敗（`Module 'mobile_scanner' not found`）。
- **位置**：`packages/qr_ui/pubspec.yaml`、`apps/wallet/ios`、`apps/vault/ios`。
- **原因**：無法在 Apple Silicon Mac 的 iOS 模擬器上編譯與執行 App（`--no-codesign --release` 實機架構建置則可通過）。
- **建議下一步**：評估升級至 `mobile_scanner` 7.x（iOS 改用系統 Vision 框架），並重新執行 Android 離線條碼模型與 16 KiB 對齊檢查。
- **來源**：`docs/FCW_REMEDIATION_2026-10-18.md`（第三輪）、第三輪 Mac 驗收紀錄（發現 2）。

### 2. [P3] iOS 核心建置腳本的工具與符號檢查
- **內容**：`1.2.0` 已讓 `tools/build_ios_core.sh` 優先使用 Rust 工具鏈的 `llvm-nm` 並容忍 Xcode `nm` 讀不了的成員，但腳本沒有確保 `llvm-tools-preview` 已安裝；符號檢查只看裝置靜態庫是否有 `_${app}_init`，沒有檢查模擬器靜態庫，也沒有確認測試用符號不在產物中；建置也沒有帶 `--no-default-features`（ADR-005 C-21）。
- **位置**：`tools/build_ios_core.sh`。
- **原因**：iOS 上架前需要和 Android 一樣的產物符號檢查。
- **建議下一步**：安裝並使用 `llvm-tools-preview`，對裝置與模擬器靜態庫都檢查必要匯出與不得出現的測試符號，並改用 `--no-default-features` 建置。
- **來源**：UI 改版審查第 12、13 輪（Argon M-03）、ADR-005 C-21。

### 3. [P3] 已延後的傳輸與硬體目標（NFC、Ledger、硬體金鑰封裝）
- **內容**：NFC（BL15）傳輸、Ledger USB／BLE 整合，以及手機硬體安全模組金鑰封裝（hardware key wrapping，現行架構為 Rust 軟體簽署、密碼衍生加密儲存與裝置驗證 gate）。
- **位置**：`crates/`、`apps/wallet`、`apps/vault`、`docs/architecture.md`。
- **原因**：屬於原始工作包（G0–G7）中尚未結案的延伸目標；NFC 已依使用者決定延後。
- **建議下一步**：待主網版本完成驗收後，依持有人需求另行排程。
- **來源**：`README.md`、`docs/FCW_CORE_WALLET_FIRST.md`、`docs/FCW_REMEDIATION_2026-10-18.md`。

---

## 發版與上架

### 1. [P1] Google Play 上架
- **內容**：`1.2.0` 已加入上傳金鑰簽章設定：存在 `android/key.properties`（或 `FCW_KEY_PROPERTIES` 指定的檔案）時，release 建置改用上傳金鑰；指定的檔案不存在或欄位空白時建置失敗；兩者都沒有時仍以 debug 憑證簽署，屬於測試建置。進度：
  - 已完成：Wallet 與 Vault 各自的上傳金鑰與預定供 Play 採用的應用程式簽署金鑰（app signing key）已產生，存放於持有人的密碼管理器；GitLab 候選 APK 已用後者簽署。`FCW_KEY_PROPERTIES` 同時套用到兩個 App，用兩把上傳金鑰建置時要分別設定，或改用各 App 的 `android/key.properties`。
  - 持有人決定商店與桌面名稱改為「FCW Watch」「FCW Vault」，套件名稱不變。
  - `1.2.1` 已完成：兩個 App 的「關於」頁（內含隱私權政策全文，Vault 離線也能看）與「未經第三方安全稽核，請先小額使用」標示、Wallet 移除 ML Kit 的診斷資料傳送元件、節點資料揭露、節點網址規則與改名；AAB 以上傳金鑰簽署並通過 `verify_play_bundle.py`（含 16 KB 對齊）。
  - 尚待完成：商店截圖、隱私權政策公開網址（公開倉庫建立後以 GitLab Pages 提供）、資料安全性表單與金融功能聲明的填寫、在 Play Console 建立兩個 App（需持有人操作）、匯入並核對 Play App integrity 的應用程式簽署憑證、實際驗證 GitLab APK 與 Play 套件能跨管道更新、確認個人開發者帳號是否需要先完成封閉測試（12 位測試者、14 天）與封閉測試本身。封閉測試先只上架台灣。
- **位置**：`apps/wallet/android/app/build.gradle.kts`、`apps/vault/android/app/build.gradle.kts`、`tools/build_android_qr.ps1`。
- **原因**：debug 憑證簽署的測試包僅供測試網驗證，不可上架或用於真實資產保管。
- **建議下一步**：以 `1.2.1`（測試網預覽版）開始封閉測試，主網版本再送正式軌道。任何上傳或送審前先經持有人確認。
- **來源**：`CHANGELOG.md`（已知限制）、2026-10-20 持有人決定。

### 2. [P2] 公開原始碼
- **內容**：公開前檢查確認 git 歷史沒有秘密；私有倉庫的樹含本機路徑、裝置序號、內部工作素材與驗收證據，公開版的樹已移除或改寫這些內容。持有人已決定：以 AGPL-3.0-or-later 加 Google ML Kit／Play services 額外許可授權；以清理後的樹開新的公開 GitLab 專案（單一 commit、noreply 作者），GitHub 作為鏡像；目前的私有 repo 保留為完整歷史與證據的存檔。
- **位置**：倉庫根目錄（`LICENSE`、`SECURITY.md`、`CONTRIBUTING.md`、`README.md`）、`.gitignore`。
- **原因**：公開原始碼讓社群檢視，也是隱私權政策公開網址的所在。
- **建議下一步**：持有人已同意在 `1.2.1` 的審查、建置與模擬器走查都通過後直接公開；以 `1.2.1` 的樹建立新的公開專案（GitLab 為主、GitHub 鏡像）。
- **來源**：公開前檢查報告（私有存檔）、2026-10-20 持有人決定。
