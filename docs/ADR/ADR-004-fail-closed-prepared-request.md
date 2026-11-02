# ADR-004: Fail-Closed 交易解析政策與反盲簽規範 (Fail-Closed Policy & Anti-Blind Signing)

- **狀態**：ACCEPTED
- **日期**：2026-10-12
- **決策者**：FCW Architecture Team
- **工作包**：FCW-OKX-20261012

---

## 1. 背景與問題脈絡 (Context)

盲簽（Blind Signing）是指使用者在未能理解原始交易內容與底層參數的情況下，簽署未經結構化解析的任意 Hash 或 Digest。盲簽是去中心化資產失竊的最主要根源。
若底層 FFI 介面或 Rust 核心暴露通用的 `sign_hash(digest: [u8; 32])` 或 `sign_message(bytes: &[u8])` 函式：
1. 一旦前端 Dart UI 遭到惡意套件污染或代碼注入，攻擊者可自行計算惡意交易的 Hash 並直接向 Rust 請求簽名；
2. 攻擊者可構造釣魚網頁，透過 QR 碼傳入假冒為純文字轉帳的合約授權（如 ERC-20 `approve` 或 EIP-2612 `permit`）；
3. 若 Vault 未嚴格核對內外層 ChainId，可能導致測試網簽章被重放到以太坊主網執行。

---

## 2. 決策內容 (Decision)

### 2.1 嚴禁通用盲簽 API (Zero Blind-Signing API)
`crates/vault_ffi` 與 `crates/vault_core` **嚴格禁止暴露任何接受任意 Digest/Hash 的簽署介面**。所有簽名操作必須始於原始未簽名交易二進位位元組，並經由嚴格受控的不可變狀態機完成。

### 2.2 不可變 `PreparedRequest` 狀態機生命週期
簽署流程嚴格拆分為三個循序階段：

```text
       Raw Bytes
           │
           ▼
┌─────────────────────────┐
│ 1. Ingestion & Filter   │ ──► 違反白名單/深度/尺寸 ──► 立即拒絕 (Signature Count = 0)
└────────────┬────────────┘
             │ 結構與政策校驗通過
             ▼
┌─────────────────────────┐
│ 2. PreparedRequest (Arc)│ (單調 UUID, 不可變 Digest, 唯讀 Display DTO)
└────────────┬────────────┘
             │
     ┌───────┴─────────────────────────────────────────┐
     │                                                 │
     ▼ 使用者於螢幕確認                                 ▼ 取消 / 鎖屏 / 背景 / 新 QR
┌─────────────────────────┐                         ┌─────────────────────────┐
│ 3. Controlled Signing   │                         │ Discard / Invalidate    │
│    - 檢查 120s 超時     │                         │ - 狀態置為 Cancelled    │
│    - 重新比對公鑰與摘要 │                         │ - 釋放記憶體            │
│    - secp256k1 簽署     │                         └────────────┬────────────┘
│    - ecrecover 自校驗   │                                      │
│    - 狀態置為 Consumed  │                                      ▼
└────────────┬────────────┘                         (底層簽章呼叫次數恆為 0)
             │
             ▼
     回傳 65B 簽章結果
```

1. **階段 1 (解析與入冊)**：
   - 接收原始 QR bytes -> 執行資源有界檢查（$\le 128\text{ KiB}, \le 16\text{ 深度}$）-> 執行 Fail-Closed 白名單政策 -> Rust 計算不可變簽章 Preimage Digest -> 生成唯一單調遞增 `handle_id` -> 註冊為 `ReadyForReview`。
2. **階段 2 (唯讀展示)**：
   - FFI 向 Dart 暴露 `handle_id` 與只讀 `ParsedTransactionDisplay` DTO。
   - 所有金額以基本整數單位（Wei / Satoshi）與固定十進位字串表示，**嚴格禁用浮點數**。
3. **階段 3 (重核與受控簽署)**：
   - 使用者於離線螢幕肉眼審核並點擊確認 -> Dart 僅傳入 `handle_id` -> Rust 驗證該 handle 存在且處於 `ReadyForReview` -> 檢查 120 秒超時視窗 -> 重新驗證派生公鑰與摘要 -> 執行軟體 secp256k1 簽署 -> **執行 `ecrecover` 簽後自核驗** -> 狀態切換為 `Consumed` -> 回傳 65-byte `r || s || v`。

### 2.3 Fail-Closed 政策白名單規則 (Strict Whitelisting)
1. **ChainId 網路白名單**：
   - 僅允許本機註冊之本地測試鏈（如 Hardhat/Anvil 31337）與官方測試網（Sepolia 11155111）。未知網路堅決拒絕。
2. **內外層一致性強制核對**：
   - UR 外層 metadata 所聲明之 `chain_id` 與 RLP 交易內層編碼之 `chain_id` 必須 100% 相符。若不一致直接拒絕。
3. **交易型態白名單**：
   - 僅允許 Legacy (EIP-155) 與 EIP-1559 Type 2。
   - **堅決拒絕 Type 1、拒絕 Blob Type 3、拒絕 EIP-7702 Type 4**。
4. **合約與互動限制**：
   - 原生幣轉帳：RLP `data` 必須嚴格為空。
   - ERC-20 轉帳：僅允許白名單 Mock 合約之 `transfer(address,uint256)`，嚴格拒絕 `approve`、EIP-2612 `permit`、NFT 全域授權與合約部署。

### 2.4 狀態失效與負向安全保證
任何非正常中斷事件（使用者點擊取消、App 切換至背景、螢幕休眠鎖定、相機掃入新 QR 碼、或逾時），系統立即呼叫 `vault_discard(handle_id)`：
$$\text{Cancellation / Disruption} \implies \text{SignatureCounter} \equiv 0$$

---

## 3. 後果評估 (Consequences)

### 正面影響 (Positive)
- 在數學與協定層面徹底杜絕盲簽與 UI 篡改攻擊，使用者「所見即所簽（WYSIWYS）」。
- 簽章前重核與簽後自校驗保證了無效簽章絕不離開 Vault。

### 負面影響與代價 (Trade-offs)
- 首版無法支援複雜 DeFi 協議（如 Uniswap Swap、Aave 借貸），符合專用安全冷端簽章器之預期設計目標。
