# 2026-10-18 審查後修正

> 本文由私有開發存檔整理而來。文中的 commit SHA 指向私有存檔 repo，公開 repo 從單一起始 commit 開始，查不到這些 SHA。文中的「審查」「APPROVE」是 AI 模型（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon）做的程式碼審查，不是第三方安全稽核；「PASS」只代表當時那個候選在模擬器、本機節點或測試資料上的結果。

這輪從 master `35e077e0abfa44f514640fb6ee9fb49924c7efc9` 的既有 dirty 工作樹接續，保留歷史候選與 PASS／FAIL／STOPPED。修正中的來源不等於已完成實機驗收。最新候選的精確 SHA-256、建置輸入及測試結果由候選旁的獨立收據記錄，不覆寫原安裝包。

本輪主要變更：

- BTC 查詢以操作世代、交易身份、目前 RPC 及前景狀態隔離；查詢期間禁止建立或封存其他交易。
- 封存保留公開 request、PSBT、既有 response，提供原交易恢復與逐筆 TXID 查詢。恢復既有簽章只進入結果待查，不自動送出。停止本機流程不會撤銷已產生的簽章。
- 舊摘要仍可查詢；備份新增可恢復封存資料與嚴格欄位契約，讀取舊格式、寫入擴充格式。衝突匯入拒絕覆寫，同 TXID 的未簽草稿不覆蓋已保存的簽章。
- 再次封存保留最新確認數與查詢時間；合併／封存前檢查歷史數量與最終 2 MiB 容量，超限時保留原檔與主動交易。
- 手動 UR 錯誤保留草稿，可原地修正；取消後恢復相機。原生 UR 會話有數量與容量上限，逐幀解碼在 worker isolate 執行；舊批次 API 保留。
- Vault 成功的簽署前取消／撤銷回收 request、PSBT 與 path；保留有界取消收據。已送簽、已簽與結果不確定的紀錄保留並計入容量，不以回收允許重簽。
- Wallet 顯示最高 ETH 網路費、估算過期狀態、Chain ID 與 RPC origin；歷史時間及公開結果身份可讀。
- 新 App 密碼、新建時選填 Passphrase 與獨立備份密碼加入精確重輸確認，生命週期回鎖時一併清空；既有備份解密與原 Passphrase 仍依預覽地址核對，不改變原生驗證。
- 架構文件明確區分現行 Rust 軟體簽署、密碼衍生加密儲存、裝置驗證 gate 與尚未實作的硬體 wrapping 目標。

掃碼依賴固定為 mobile_scanner 6.0.11，保留 bundled ML Kit 離線模式。以實際解析的 Maven 依賴及 APK 內每顆 ELF／ZIP／RELRO 對齊收據為依據；套件更新說明不能替代產物檢查或 16 KiB runtime。此依賴的 iOS 最低版本為 15.5，本輪沒有跨機執行 Xcode 建置或 iOS 驗收。

本輪驗證只使用合成或既有公開無資產資料，不新建／匯入／匯出助記詞、密碼、資產金鑰，不產生新簽章，不送交易。Mock RPC 與合成 UI 測試不能取代持有人掌控測試金庫的完整真實認證、備份還原與新簽章旅程。較早普通主 App 的本機 EVM／BTC、Vault 認證與備份還原 PASS 保留原版本與原環境邊界。

相機對相機、實體光學、16 KiB 系統執行、完整無障礙及最新候選的全旅程，只能在各自取得收據後標示通過。NFC、Ledger 延後；OKX 完整回傳廣播與 FCW iOS 不由此輪推定完成。所有 APK 為本機測試簽章候選，沒有推送、合併、商店發布或正式資產保管就緒宣稱。

方法依據：[Android 16 KB page sizes](https://developer.android.com/guide/practices/page-sizes)、[mobile_scanner changelog](https://pub.dev/packages/mobile_scanner/changelog)、[ML Kit barcode scanning](https://developers.google.com/ml-kit/vision/barcode-scanning/android)。

## 第二輪：驗收與審查修正（2026-10-18）

接手時以 r7 候選為起點，在專用 16 KiB 模擬器 `FCW_Public16K_20261018`（API 35、x86_64）以手動貼上 UR 做實際 App 操作，交易送往隔離的本機 Anvil（chain-id 11155111，非公開 Sepolia），沒有真實資產。

- 公開備份：未完成的匯入進度在 force-stop 後保留；第一步與第二步之間重啟可接續；匯入紀錄一律「結果待查」，不採用檔案內的 confirmed；重新驗章、查詢同一雜湊、重送同一份已簽 bytes、上鏈確認、冷啟動保留；同一檔再次匯入不新增、不降級既有已確認紀錄。
- 完整簽名流程：在模擬器建立 QA 測試金庫（隨機助記詞，不輸出、不保存為證據），配對、建立 EIP-1559 請求、Vault 審查（請求 ID 與摘要一致）、簽署、Wallet 驗章、廣播、確認。負向案例：重複密碼不一致被擋、錯誤 App 密碼被拒、另一筆請求的簽章以 `ERR_REQUEST_ID_MISMATCH` 拒收。r7、r8、r9 各完成一筆（r8 用滑動確認，其餘用按鈕）。
- 三方審查（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon）第一輪均要求修改，修正如下，第三輪三方 APPROVE：
  - BTC：mempool 交易沒有 `confirmations` 欄位時視為待確認（欄位存在但非整數，或為 null，仍是格式錯誤）。
  - BTC：送出前的鏈驗證失敗或授權撤銷標為「確定未送出」，回到原狀態。只有節點以 -5 且訊息為 `No such mempool or blockchain transaction`（已同步 txindex）證明查無此交易時，才允許重送同一份 bytes，或將可能已送出的交易封存為 `unknown`。其他 -5 只顯示「無法證明交易不存在」。廣播結果不確定時，仍須先查詢才能另建交易。
  - 公開備份：封存摘要與 `built` 必須等於核心重建結果。`built` 只以 PSBT、digest、TXID 比對身分。本機未簽主動交易遇到匯入帶來的同 TXID 已簽封存時，拒絕匯入，原檔不變。
  - UR：原生 session 失效或結果被拒時完整重設；reset 釋放處理中旗標；手動批次全有或全無，若清除了相機進度會明說。
  - 測試：補上兩個 Vault 測試的確認欄位，修正 IME 測試的平台方法名稱，新增 BTC、備份與 decoder 回歸測試。
  - 文案：兩處原始錯誤字串在地化，保留錯誤碼。
- 測試（Windows、host DLL）：public_models 267、qr_ui 33、wallet 143、vault 131，共 574 項，四個 analyze 無問題。Rust workspace 144 項通過。
- 候選 r9：Wallet SHA-256 `d9ef7009c77038c811919bc6d6086a7786ad5b0eb0ae4acbcd516e898e6abe91`，Vault SHA-256 `ec07edfd922762b7ce938677266735c4c0404311732a2f3471f9e6c5f4cd3866`。版本 1.0.0+2，沿用原開發憑證 `fde363be…`。ELF、RELRO 與 ZIP 16 KiB 檢查 PASS。重用 r5 已驗證的原生庫，Rust 輸入未變。
- S24（arm64-v8a、4 KiB page）：r9 以 `install -r` 安裝，雜湊一致，Wallet 與 Vault 原生核心載入。QA 金庫建立成功，配對 UR 可由另一台 Wallet 解析。ARM64 簽署因手機前景被其他 App 占用而中止。之後以 `pm clear` 將 S24 Vault 還原為測試前的空庫，相機權限已撤回。

仍未完成：實體相機對相機、ARM64 實機簽署、真實裝置生物識別、S8、stock OKX 簽章回傳、bitcoind 實機 BTC 流程（本輪 BTC 修正只有單元與 widget 測試）、iOS Xcode。已知延後項目：逐幀 `compute()` 的效能、簽署後 UR 編碼失敗的順序、同程序 128 筆保留上限的提示、EVM 背景送出結果處理、實際容量、相機「不再詢問」、測試可攜性與 `.gitattributes`。

## 第三輪：替代驗收與 UI/UX 改版（2026-10-18）

### Mac Apple Silicon 替代驗收（r9，全部是模擬環境）

- 新建 ARM64 16 KiB AVD（`android-36` `google_apis_ps16k` arm64-v8a，`PAGE_SIZE=16384`，無轉譯）。r9 雜湊與收據一致。模擬器 37.3.4 解壓到獨立目錄，不更動共用 SDK。
- Bitcoin Core 30.2：已核對 guix 簽章與 `SHA256SUMS`。regtest、`txindex=1`、純觀察錢包，RPC 前加故障注入代理，可模擬送達前斷線與送達後丟失回應。
- PASS：
  - ARM64 建立 QA 金庫並配對。
  - 只有 PIN 的裝置驗證：錯誤 PIN、取消、正確 PIN。
  - 相機權限對話框讓 Vault 離開前景時自動上鎖。
  - BTC：未廣播先查詢、結果待查、無 txindex 時不允許重送、確認查無後才能重送、mempool 交易沒有 `confirmations` 時視為待確認、挖礦後確認；封存、冷啟動、恢復、重送。
  - EVM 簽署與廣播。
  - 模擬器指紋：註冊後可選擇生物識別或裝置密碼；未註冊的指紋被拒；加註第二枚指紋後，原驗證金鑰仍然有效。
- 模擬光學：模擬器 37 的 `environment` 相機以 gRPC `setEnvironment` 播放影片。EVM 與 BTC 都完成雙向相機流程並廣播。其中一筆 BTC 雙向都用 App 實際渲染的畫面；Vault 有 `FLAG_SECURE`，所以用主機端 `adb emu screenrecord` 擷取。這不包含鏡頭、光線、對焦與摩爾紋，不能取代實體相機。
- iOS：補上 iOS 26.3.1 platform 後，`flutter build ios --no-codesign --release` 兩個 App 都通過。模擬器版建置失敗，因為 mobile_scanner 6.0.11 的 ML Kit pod 排除了 arm64 模擬器；要在 Apple Silicon 模擬器執行，需升級到 7.x（iOS 改用 Vision）。這屬於依賴決策，本輪沒有改。

### UI/UX 改版（`ui-overhaul`，基準 `8117a49`）

| Commit | 內容 |
|---|---|
| `2264535` | 視覺識別與設計系統。Wallet 藍色、跟隨系統主題；Vault 深綠、強制深色，並常駐角色徽章。新增 token（間距、圓角規則、語意色調 ThemeExtension、等寬與表格數字）與共用元件。審查頁依「所見即所簽」：金額放最上方，地址、路徑、摘要用等寬區塊，所有欄位展開。掃描器加取景遮罩與進度，動態 QR 加幀進度，滑動確認加進度填色。助記詞改成依寬度量測欄數的 tile（舊 Chip 在 320dp、2 倍字級會截斷）。 |
| `0e07fad` | 四項可用性修正：EVM 建好請求後自動捲到 QR，建置中停用按鈕（實測連點曾產生 3 筆請求）；BTC 新草稿清空收款、金額與手續費；開掃描器前取消焦點，返回時不跳出鍵盤；Vault onboarding 錯誤顯示在操作按鈕旁並捲入畫面。 |
| `281eebb` | 第一輪審查修正：相同錯誤再次出現時也會捲入畫面；移除帳戶卡多出的縮寫地址；滑動確認改為膠囊軌道，填色與拇指等高；其餘自刻的錯誤橫幅改用共用元件；助記詞測試改為檢查單字是否在字中斷行（12、24 字，並做變異檢查）。 |
| `58ed674` | 第二輪審查修正：`FcwPanel` 改以 `Material` 為底，面板內列表的點擊漣漪與焦點框恢復可見（Flutter 3.47 會對舊寫法 assert）；角色徽章自成語意節點，不再改掉 AppBar 標題的讀屏名稱；掃描器遮罩改在控制列下方；「離線簽章」改為中性的角色標籤；展開區第一個輸入框的浮動標籤不再被裁切（`8117a49` 既有問題）；`role` 改為必填，並補上測試。 |
| `16aec2a` | 只改測試：重入測試改成確實能抓到「取消進行中的建置」。 |

- 審查（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon，以最嚴格的判決為準）：
  - 第一輪：Codex 小修後可過；Argon 要求修改；Opus 因額度用盡沒有產出。
  - 第二輪：Codex、Argon APPROVE；Opus 首次完整審查，`2264535` 要求修改（3 個 Important：1 個已由 `281eebb` 修正，其餘 2 個在 `58ed674` 修正），`0e07fad`、`281eebb` 小修後可過。
  - 第三輪：Codex、Argon APPROVE；Opus 小修後可過，不阻擋合併。其中一個 Minor 已在 `16aec2a` 修正，另一個 nit（助記詞欄寬計算與 `FcwCodeBlock` 內距的隱性耦合）列為後續。
  - 第四輪（`16aec2a`、`0dff656`）：Codex、Argon APPROVE；Opus 小修後可過（文件三處），已在 `497f3d6` 修正。
  - 第五輪：Opus 複審 `497f3d6` 後 APPROVE。
  - 第六輪（發版 commit `7844740`、`51e8759`）：Codex、Opus 小修後可過，Argon APPROVE；文件已依意見修正。
  - 第七輪（複審 `6d81aaa`，Codex、Opus）：都判小修後可過，已在 `1e654af` 修正。
  - 第八輪（複審 `1e654af`）：Codex、Argon APPROVE；Opus 小修後可過。它指出標籤可能不在 `master` 上，經核對 GitLab `master` 後確認無誤；另兩處來源標示與一處可選敘述已在 `bb0d810` 修正。
  - 第九輪（複審 `bb0d810`）：三家 APPROVE。Opus 另提兩個可選的措辭意見（上一行第八輪的寫法、`docs/releases/v1.1.0.md` 把 `r11` 與 `r12` 寫在一起），已在 1.1.0 補走查的文件 commit 修正。
- 測試（Windows、host DLL；`58ed674`、`0dff656`、`51e8759` 各跑一次，結果相同）：design_system 27、qr_ui 33、public_models 267、wallet 146、vault 135，共 608 項，五個 analyze 都沒有問題。Mac 另以 Flutter 3.47.2 跑 wallet、vault、design_system、qr_ui，ListTile 背景 assertion 為 0（修正前 wallet 59 項、vault 22 項失敗）。
- 候選：
  - r10 中止：新 worktree 簽出時 Rust 檔被轉成 CRLF，原生庫重用檢查拒絕。55 個原生輸入檔在統一換行後與 r5 完全相同；把 worktree 的這些檔案對齊為主工作樹的位元組，`git diff` 為空。
  - r11（`281eebb`）與 r12（`58ed674`；之後的 `16aec2a`、`0dff656` 只改測試與文件）的靜態檢查都 PASS。
  - r12：Wallet SHA-256 `1c6f204e4c7ca4b5daf6d086640ac547587fd7f766c1fc57b82ac324e93003ad`，Vault SHA-256 `0106c4b9a5b5c5fdbe99c3c81d5c43c6d1e6c0e982ff616b96a97b2bae294a5f`。版本 1.0.0+2，原開發憑證 `fde363be…`，重用 r5 的原生庫。
- 模擬器走查（不涉及真實資產）：
  - r11 在 ARM64 上：
    - EVM 建立後自動捲到 QR；Vault 審查、滑動確認（靜止與拖動中）、簽署。Wallet 離開前景後依設計撤銷待簽畫面，再從交易紀錄接收原請求的簽章並廣播（Mac Anvil block 5）。
    - BTC：建立請求；RPC 密碼欄取得焦點後開掃描器再返回，`mInputShown=false`；封存後新草稿的三個欄位都是空的。
    - Vault onboarding：相同錯誤再次觸發時會捲回畫面。24 字 tile 在 1 倍字級為兩欄、2 倍字級為單欄，都是單行。
  - r12 在 x86_64 16 KiB 上：建立 QA 金庫（12 字 tile 與抽考）、配對、入金、EVM 建立、Vault 解鎖（App 密碼加裝置 PIN）、審查、滑動簽署、接收、廣播（Windows Anvil block 14，status 1）。掃描器控制列不再被遮罩壓暗、「離線簽章」為中性標籤、AppBar 標題與徽章是兩個語意節點。另在 ARM64 安裝 r12，確認 BTC「節點設定」的 `RPC 網址` 標籤完整顯示。
  - 走查後，x86_64 模擬器的 Vault 還原為空庫，暫時設定的裝置 PIN 也已移除。
- 仍未完成：實體相機對相機、實體 ARM64 手機簽署、真實裝置生物識別、S8、stock OKX 簽章回傳、實體裝置上的 bitcoind BTC 流程、iOS 實機或模擬器執行。
- 已知、未在本輪處理：
  - Vault 已解鎖畫面不顯示 `_actionError`，例如加密備份檔儲存失敗的提示看不到（`8117a49` 既有）。
  - 助記詞文字仍在預設的無障礙樹中（與舊版相同；是否對讀屏隱藏屬於政策決定）。
  - 觀察錢包的 descriptor range 若已被擴大（例如 `[0,1000]`），App 以 `[0,100]` 重新匯入會被 Core 拒絕，顯示「匯入失敗」並停止。
  - BTC 找零固定回到 `/1/0`。
  - RPC 帳密離開畫面即清除，之後的錯誤訊息沒有指出是認證問題。
  - 極端字級下單字沒有連字號；建立 QR 後沒有讀屏通知；主指紋在 Vault 與配對對話框中的大小寫不一致。

### 1.1.0 發版

- 版本號在 `7844740` 升為 `1.1.0+3`（build number 跳過 2，`r9`–`r12` 已用），APK 由這個 commit 建置。標籤 `v1.1.0` 打在其後的文件 commit `6d81aaa` 上。
- 候選 `r14`：Wallet SHA-256 `cb35bd968f689f6c6318f35ea547c2f36c0f82738be49c699dea005195508ccd`，Vault SHA-256 `19efe1876f8c92395a2b91dfaf623f8ebbb0c83304bdbed60b3c6e656e6bf9b6`，靜態檢查 PASS。`r13` 由同一個 commit 建置，但檢查步驟仍比對舊版本號而中止，未作為產物。
- 模擬器走查：ARM64 完成 EVM 簽署與廣播（本機 Anvil block 2），掃描器以模擬相機讀取多幀 QR；x86_64 安裝後兩個 App 正常啟動，crash buffer 無紀錄。
- 文件：`CHANGELOG.md`、`docs/releases/v1.1.0.md`、`docs/screenshots/`（12 張，不含助記詞畫面；11 張來自 ARM64 的 r14，Vault 設定畫面來自 x86_64 的 r14）。之後的剩餘工作統一記在 `docs/REMAINING_WORK.md`。

### 1.1.0 補走查（2026-10-20）

同一份 `r14`，在 ARM64 16 KiB 模擬器（Mac）上補走發版時沒走到的 BTC 與備份流程。全部是測試資料：Bitcoin Core 30.2 regtest（`txindex=1`，觀察錢包經故障注入代理，`pass` 模式），不涉及真實資產。

- BTC 審查、簽署與廣播：PASS。
  - Wallet 建立 0.15 BTC、手續費 1500 sat 的請求（8 幀 `crypto-psbt`）。模擬相機播放由請求文字產生的 QR，Vault 掃描完成。
  - Vault 審查頁顯示金額、收款地址、網路、路徑、輸入、收款與已驗證找零輸出、手續費、請求識別碼和簽署摘要。滑動確認後簽署，產生 10 幀簽章。
  - 模擬相機把簽章傳回 Wallet，Wallet 顯示「簽章已驗證，尚未廣播」。確認廣播後為「待確認」，挖 1 個 block 後查詢為「已確認」。
  - TXID `56a016fd2ef6939b50ace12fdb0ae7c35b590073241d132184a71d554eb22314`，regtest block 109。
  - 重開模擬器時相機仍指向第三輪的舊請求影片，Vault 只重顯示既有簽章，沒有重新簽署，符合設計。
- Vault 加密備份匯出與還原：PASS。
  - 原本的 QA 金庫沒有保留助記詞，無法通過匯出前的紙本驗證，所以清除 Vault 資料，改用公開的 BIP-39 全零熵 12 字測試向量（主指紋 `73C5DA0A`）。
  - 匯出：重新驗證紙本助記詞（驗證後欄位自動清空），設定備份密碼，產生加密備份，經系統檔案選擇器存成 1530 bytes 的檔案。檔案沒有明文助記詞；除密文外，只有 KDF 參數與主指紋等信封中繼資料。
  - 還原：清除 Vault 資料，從選擇器開啟同一檔案，解密預覽主指紋與 EVM 地址，設定新 App 密碼後啟用。上鎖再解鎖後，EVM 與 BTC 地址都和匯出前相同。
- Wallet 公開備份匯出與還原：PASS。匯出前列出 3 個帳戶、7 筆 EVM 與 1 份 Bitcoin 紀錄，未納入 0 筆；存檔後顯示成功。選取同一檔案還原，分三步合併帳戶、EVM 與 Bitcoin 紀錄，每步都要確認。完成後既有紀錄保留，上面那筆 BTC 交易仍為「已確認」。
- 新發現（未修改程式碼，當時記入 `docs/REMAINING_WORK.md`；括號內是 `dc33b42` 版清單的編號，`1.2.0` 改寫清單後已不適用，這幾項都已在 `1.2.0` 修正，見 `CHANGELOG.md`）：
  - 開啟系統檔案選擇器時 Vault 會依設計上鎖，所以加密備份存檔成功後只回到鎖定畫面，沒有任何提示（已知缺陷 7）。選擇器開啟後取消，錯誤會顯示在鎖定畫面，不受已知缺陷 2（已解鎖畫面不顯示 `_actionError`）影響；選擇器無法開啟時金庫仍是解鎖的，錯誤仍然看不到。
  - Vault 簽署結果的多幀 QR 預設暫停，畫面沒有提示要按播放（`ea34151` 起的設計）；BTC 簽署結果多顯示一行「原始 Chain ID：0」（改善與技術債 9）。
  - Vault 的還原預覽也以小寫顯示主指紋，與首頁的大寫不同（已知缺陷 9）。
- 證據衛生：
  - 測試助記詞與備份密碼只放在權限 0600 的暫存檔，由測試腳本直接輸入，用完即刪。動作紀錄裡，助記詞只有字數與雜湊，密碼只有字數。
  - 助記詞欄位有內容時不存 UI 傾印、不截圖；其他欄位只在遮罩後或內容不機密時擷取。
  - 掃描 76 個檔案（72 個新 UI 傾印，加上 `_last.xml`、動作紀錄、代理紀錄與收據），沒有助記詞或任何密碼。
- 走查後，模擬器上的 Vault 是上述測試向量金庫，沒有和 Wallet 配對；Wallet 仍保留原 QA 金庫的觀察帳戶。

### 1.2.0 修正與發版（2026-10-20）

範圍 `97eafba..dc33b42`，版本 `1.2.0+4`。修正 `1.1.0` 清單中的 Vault 錯誤顯示、備份存檔提示、BTC descriptor 重新匯入與找零索引、主指紋大小寫、EVM 建立 QR 的螢幕閱讀器播報、相機權限永久拒絕的設定流程，並加入上傳金鑰簽章設定。完整清單見 `CHANGELOG.md`。

- 審查（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon，以最嚴格判決為準）：
  - 第 12 輪 Codex 與 Argon 為 REQUEST CHANGES、Opus 為 APPROVE WITH MINOR FIXES，依最嚴格判決要求修改。三家都指出的最重要一項：BTC `sendrawtransaction` 收到 HTTP 401／403 被當成「未送出」，但節點前方的代理可能已經轉送，使用者可能另建一筆交易而重複付款。另有 EVM 舊送出回呼清掉新送出旗標、送出前離開前景卡在「廣播中」、簽章設定靜默改用 debug、APK 檢查寫死簽章等。
  - 10 項修正（`fb483ee`～`dc33b42`）中，Dart 與 Python 的修正都附回歸測試，第 13 輪審查在獨立副本把主要修正換回修正前，對應測試都會失敗；Gradle 簽章設定（`fc024fb`）與 Wallet 原生忙碌防護（`55ae946`）沒有自動化測試，只以離線 Gradle 簽章報告與 Kotlin 編譯驗證。第 13 輪 Argon APPROVE、Codex 與 Opus APPROVE WITH MINOR FIXES，該輪新增的小問題排入 `1.2.1`。
- 測試：macOS 與 Windows 在 `dc33b42` 各跑全套，共 663 項通過，analyze 無問題。
- 產物：候選 `r17`（在 `dc33b42` 建置；建置主機的檢查紀錄標示 `source_dirty: true`：忽略 CR 行尾差異後，工作樹與 `dc33b42` 只剩 3 個自動產生的 `.flutter-plugins-dependencies` 有差異；其餘列出的檔案（包含為對齊重用的 `r5` 原生庫而保留 CRLF 的 Rust／Cargo 輸入，以及兩份 Android `GeneratedPluginRegistrant.java`）在忽略 CR 行尾後沒有內容差異。差異清單與建置當時的工作樹狀態保存在私有存檔的本機證據中），Wallet SHA-256 `16fe0fe0e9cb89cbffc94a667077bcaa9e7807c306cc8041007204547fd2e89b`，Vault SHA-256 `f1add8d14f7ba0719c10f91c72924089c857054d7dc053bafa337ae58f6d6772`，靜態檢查與 APK 簽章檢查 PASS。`r15` 因簽章設定檢查仍比對舊寫法而中止；`r16`（`e7797ae`，Wallet `c3c0df50…`、Vault `083a80d0…`）用於第一次走查。
- 模擬器走查（ARM64 16 KiB，測試資料）：
  - `r16`：8 個流程通過（啟動、配對、EVM、BTC 兩筆交易與找零索引、RPC 憑證清空、備份存檔結果、Vault 相機永久拒絕、EVM 廣播期間離開前景）。
  - `r17`：本輪改到的流程 7 項中 6 項通過。BTC 403 情境以故障代理先把交易轉送給節點、再回 403 重現。
  - 未通過：Wallet 相機權限被拒時，掃描器反覆要求權限，永久拒絕後 Android 會把 Wallet 從畫面上關閉（以「rapid activity launch」移除它的工作視窗）；EVM 簽章掃描遇到權限視窗就撤銷接收授權。兩者在 `1.1.0` 之前就存在，記入 `docs/REMAINING_WORK.md`，預定於 `1.2.1` 修正。
- 走查後，模擬器上的 Vault 仍是公開 BIP-39 全零熵測試向量金庫（主指紋 `73C5DA0A`），Wallet 已和它配對。

### 1.2.1 修正與發版（2026-10-21）

範圍 `d7590f0..70d56e8`，版本 `1.2.1+5`，定位為測試網預覽版。`64cb711` 之後只加入測試、文件與兩個 App 的啟動器圖示，產品流程未變。內容包括 Google Play 需要的改名、關於頁與隱私權政策、節點網址規則、Wallet 移除 ML Kit 的遙測元件、`1.2.0` 已知的相機權限問題、第 13 輪的小問題、AAB 檢查工具，以及公開倉庫的整理與授權。完整清單見 `CHANGELOG.md`。

- 審查（GPT-6.1-Sol、Opus 5.5、Gemini 4 Argon，以最嚴格判決為準；額度用完的一方跳過；第 18 輪起另加 Grok 4.7）：
  - 第 16 輪全面審查三家都是 REQUEST CHANGES。最重要的幾項：存有公開 `http://` 網址的舊紀錄在修改節點後無法恢復；Wallet 忽略所有失去焦點（不只是權限視窗），通知欄等情境下送出仍會進行；舊掃描器的清理會停掉新掃描器的相機；AAB 檢查只拒絕一張已知的 debug 憑證。
  - 第 17、18 輪 Codex 仍要求修改，兩次都是權限視窗的豁免範圍：先是涵蓋一般相機啟動與排隊時間，後是涵蓋外掛自己的權限查詢與允許後的相機啟動。最後改由掃描器自己送出權限請求，豁免只包住請求本身（`1db5fc3`）。
  - 第 19 輪 Codex、Opus、Grok 都是 APPROVE WITH MINOR FIXES；`request` 拋錯的測試與被拒路徑的直接測試已補上（`60a070c`）。第 20 輪 Codex 與 Grok 對文件證據邊界提出 REQUEST CHANGES；Opus 因額度中斷沒有報告。O5／O6／O7 與其他未修項目已明列 `docs/REMAINING_WORK.md`。
- 測試：macOS 與 Windows 在 `60a070c` 各跑全套，共 753 項通過，analyze 無問題；建置主機 `check_env.py --strict` PASS。
- 產物：候選 `r20`（`70d56e8`）。四組 APK／AAB 重新簽署前後的非簽章 ZIP entry 在本輪完整重算，Wallet APK 403、AAB 414、Vault APK 399、AAB 410 個 entry 的路徑、大小與內容雜湊全部相同；APK 的簽章與 ZIP 對齊及 AAB 的 JAR 簽章驗證均通過。精簡證據與新雜湊見 `docs/evidence/r20-resign-readback.json` 及 `docs/releases/v1.2.1.md`。Play Console 尚未完成設定及應用程式簽署憑證核對，跨管道更新仍待驗證。
- r19 模擬器走查（ARM64 16 KiB，測試資料）：名稱與關於頁、相機權限、節點網址規則、EVM／BTC 完整簽署與廣播及 BTC 失焦處理通過。流量證據限於 12:00 後三次掃描的每 UID 統計為零；pcap 沒有有效封包，較早非零統計也無法逐筆歸因。這些流程與流量結果沒有在 r20 重跑。
- r20 靜態與基本執行 readback：兩個 APK 在專用 ARM64 16 KiB 模擬器安裝成功，裝置上雜湊與候選一致，兩個 MainActivity 冷啟動成功；App drawer 顯示新圖示與名稱，Wallet 首頁顯示正常。Vault 因 `FLAG_SECURE` 截圖為黑畫面，只以 UI hierarchy 確認套件與離線／解鎖／關於標記及安全視窗旗標，未完成 Vault 視覺驗收。
- 證據衛生：
  - Vault 的 App 密碼在走查前換新，只存放在持有人的密碼管理器，由測試腳本在執行時讀取；舊密碼曾以明文寫在測試腳本裡，已從腳本移除並作廢。
  - 測試助記詞只放在權限 0600 的暫存檔。一次在助記詞欄位有內容時誤存了 UI 傾印，該檔已刪除；掃描其餘傾印與動作紀錄，沒有助記詞或密碼。
- 截圖：`docs/screenshots/` 以 `1.2.1` 與公開測試向量金庫（主指紋 `73C5DA0A`）重拍。為了截圖，本機 Anvil 在 Sepolia USDC／DAI 的位址放了只回傳固定餘額的測試合約，並把 EVM #0 的餘額設為 2.5 ETH。
