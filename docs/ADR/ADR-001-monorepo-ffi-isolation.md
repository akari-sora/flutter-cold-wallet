# ADR-001: Monorepo 模組劃分與 FFI 邊界隔離 (Monorepo Layout & FFI Isolation)

- **狀態**：ACCEPTED
- **日期**：2026-10-12
- **決策者**：FCW Architecture Team
- **工作包**：FCW-OKX-20261012

---

## 1. 背景與問題脈絡 (Context)

本專案為包含連網 Companion Wallet (`apps/wallet`) 與專用離線 Vault (`apps/vault`) 的雙 App 架構。
雙端雖共享部分公開資料模型（如帳戶描述元、BC-UR 傳輸協定編解碼），但具備截然相反的安全等級：
- 連網端錢包運行於一般聯網手機環境，容易遭受惡意軟體監聽或網路攻擊；
- 離線端金庫運行於專用氣隙隔離裝置，掌控所有私密金鑰與簽署權限。

在單一代碼倉庫（Monorepo）中，最常見的架構隱患為：
1. 雙端共用同一個 FFI Crate 或透過 Cargo Feature 開關區分功能；
2. 在編譯期間由於 Cargo Feature Unification 或代碼共用，連網端二進位產物（`libwallet_ffi.so`）意外包含 `vault_core`、BIP-39 助記詞匯入、私鑰生成或密碼學簽署符號；
3. 開發者可能僅靠隱藏 UI 按鈕來實現「只讀觀察」，而非在編譯期達成物理隔離。

---

## 2. 決策內容 (Decision)

### 2.1 物理級模組隔離 (Physical Separation of Crates)
在 Rust Workspace 中建立五個職責明確、依賴剛性隔離的獨立 Crates：

1. **`crates/public_core`**：
   - 職責：公鑰計算、地址推導（EIP-55）、RLP 編解碼、簽章公開核驗（`ecrecover`）。
   - 限制：**完全不含任何 seed 匯入、助記詞生成、私鑰儲存或私鑰簽章 API**。
2. **`crates/ur_adapter`**：
   - 職責：BC-UR 編解碼、Fountain 碼切片、CBOR 有界解析（<=128 KiB, 深度 <=16）。
   - 限制：純傳輸格式適配，不包含業務簽署邏輯。
3. **`crates/vault_core`**：
   - 職責：助記詞種子管理、BIP-32 HD 派生、政策引擎白名單、不可變 `PreparedRequest` 狀態機、受控簽署。
   - 限制：依賴 `zeroize` 實施記憶體抹除，**絕對不引入任何 HTTP Client 或網路傳輸程式庫**。
4. **`crates/wallet_ffi`**：
   - 職責：供連網端 `apps/wallet` 調用，產生帳戶配對 QR、構建未簽名交易、驗證並廣播回傳簽章。
   - 限制：**`Cargo.toml` 嚴格禁止依賴 `vault_core`**，僅允許依賴 `public_core` 與 `ur_adapter`。
5. **`crates/vault_ffi`**：
   - 職責：供離線端 `apps/vault` 調用，接收原始 QR bytes，建立不可變 Opaque Handle，使用者確認後執行簽署。
   - 限制：依賴 `vault_core`，但僅導出不可變句柄狀態機 API，嚴禁暴露通用盲簽接口。

### 2.2 編譯期與建置期靜態防禦 (Build-Time Verification)
1. **依賴樹剛性稽核**：
   CI 與 release checks 腳本執行 `cargo tree -p wallet_ffi`。若依賴樹中出現 `vault_core`、`secp256k1/sign`、`bip39`，建置立即中斷失敗。
2. **二進位符號掃描**：
   產出 `libwallet_ffi.so` / `WalletFfi.framework` 後，透過符號表分析工具掃描，確認二進位產物完全無 `sign`、`private_key`、`mnemonic` 等符號。

### 2.3 Flutter 模組劃分對應
- `packages/public_models`：純 Dart DTO，不含秘密欄位。
- `packages/qr_ui`：純相機掃描與 QR 噴泉碼渲染，不含網路與業務狀態。
- `apps/wallet` 僅引入 `wallet_ffi`；`apps/vault` 僅引入 `vault_ffi`。

---

## 3. 後果評估 (Consequences)

### 正面影響 (Positive)
- **架構安全性**：從編譯與鏈結期保證 Watch-only Companion 在物理二進位層級無法簽署交易或洩漏私鑰。
- **安全審查清晰**：審查者可透過單一 `Cargo.toml` 依賴樹直接證明連網端無金鑰風險，無需逐行審查 UI 代碼。

### 負面影響與代價 (Trade-offs)
- 需要分別維護兩套 FFI 導出介面與獨立的動態函式庫建置管線。
- 部分型別需在 `public_core` 中定義後跨模組引用，增加初始化配置工作量。
