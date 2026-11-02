# ADR-003: 離線金鑰存儲、包裝金鑰與記憶體零化規範 (Key Storage, Wrapping Key & Zeroization)

- **狀態**：原始設計 ACCEPTED；下列硬體包裝設計尚未整合至現行 Android（2026-10-18 核對）
- **日期**：2026-10-12
- **決策者**：FCW Architecture Team
- **工作包**：FCW-OKX-20261012

---

## 現行實作與原始設計的差異（2026-10-18）

現行 Vault 由 Rust 軟體執行資產簽章，儲存金鑰由密碼與隨機 salt 派生；Android Keystore 的近期裝置驗證證明用於認證門禁，並非本 ADR 的硬體 KEK 包裝 DEK。下文保留 2026-10-12 原始設計決策，不能作為已實作硬體包裝、硬體資產簽署或秘密記憶體清除效果的宣傳依據。iOS Keychain／實機資格亦尚未閉合。當版可成立的保護與限制請併讀 `docs/architecture.md` 及 `docs/FCW_CORE_WALLET_FIRST.md`。

---

## 1. 背景與問題脈絡 (Context)

離線 Vault 必須持久化儲存助記詞種子，以便使用者在重新啟動手機後無需反覆手動輸入 24 個單詞。
然而：
1. 若將助記詞或私鑰以明文存於 App 私有目錄，一旦手機被惡意程式利用沙箱漏洞讀取、遭雲端備份（Google Drive / iCloud）同步、或經由 ADB / 裝置搬家萃取，將造成資產失竊；
2. Android StrongBox/TEE 與 iOS Secure Enclave (SE) 的標準演算法主要支援 NIST P-256，無法原生支援 secp256k1 私鑰簽章；
3. Flutter/Dart VM 具有垃圾回收機制（GC），不可變字串（Strings）會駐留於字串池中，受管語言無法提供可靠的即時記憶體抹除機制。

---

## 2. 決策內容 (Decision)

### 2.1 雙層金鑰包裝架構 (Key Hierarchy & Wrapping Key)
採用信封加密（Envelope Encryption）架構，將硬體安全晶片與純軟體高效加密分層結合：

1. **主包裝金鑰 (KEK - Key Encryption Key)**：
   - 於平台原生安全模組內生成非導出（Non-exportable）金鑰。
   - Android：由 Android Keystore 產生 AES-256-GCM 金鑰，優先啟用 `StrongBox` 或 `TEE` 硬體綁定。
   - iOS：由 iOS Keychain 產生非導出金鑰，設定 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。
2. **資料加密金鑰 (DEK - Data Encryption Key)**：
   - 每次加密持久化時，由 Rust CSPRNG 生成獨立之 256 位元對稱金鑰。
   - 助記詞種子明文由 DEK 透過 AES-256-GCM 進行加密。
   - DEK 本身則由 KEK 進行包裝（Wrap/Encrypt），隨後與資料密文一同存於本機檔案。

### 2.2 AEAD 與防篡改驗證
1. **Nonce 唯一性**：每次寫入強制使用 CSPRNG 生成全新 96-bit 隨機 Nonce，嚴禁重用。
2. **AAD (關聯驗證資料) 綁定**：
   - AAD 強制綁定：`Schema Version (u32)` + `App Bundle ID (String)` + `Master Key Fingerprint (4 bytes)`。
   - 解密時若驗證 Tag 不符（哪怕 1 bit 被變造），立即返回解密失敗，**絕不靜默重置或自動建立新金鑰**。

### 2.3 使用者本機 PIN 防護
若使用者啟用本機解鎖 PIN，使用 Argon2id (RFC 9106) 進行金鑰派生（參數：`m=64MB, t=3, p=4`），生成額外保護層。短 PIN 僅作為 KDF 因子，不作為唯一高熵依賴。

### 2.4 記憶體衛生與主動零化 (Memory Hygiene)
1. **Rust 核心清零**：
   - 所有承載助記詞（Mnemonic）、種子（Seed）、衍生私鑰（SecretKey）的資料結構，必須實現 `zeroize::ZeroizeOnDrop`。
   - 敏感結構體禁止實作 `Clone`，禁止以 `Debug` 格式化輸出。
2. **Dart 受管記憶體防護**：
   - Dart ↔ Rust FFI 邊界絕不傳遞私鑰與種子。
   - 助記詞展示與輸入優先採用原生記憶體緩衝區或小型原生元件（Platform View）渲染，避免在 Dart 字串池中殘留明文字串。
   - **誠實揭露**：受管語言記憶體在 GC 觸發前可能存在短暫暫存副本。威脅模型中明確承認此一架構限制，不宣稱「全鏈路絕對零記憶體痕跡」。

### 2.5 原子化持久儲存 (Atomic Persistence)
寫入金庫檔案時遵循原子寫入流程：
1. 寫入臨時檔案 `vault_data.tmp`；
2. 呼叫 `fsync` 確保資料落盤；
3. 執行作業系統層級之原子重命名 `rename` 覆蓋目標檔案，防止斷電或強制殺進程導致金庫損毀。

---

## 3. 後果評估 (Consequences)

### 正面影響 (Positive)
- 靜態資料獲得硬體安全晶片與密碼學 AEAD 雙重保護，阻斷脫機提取與備份洩漏。
- Rust 敏感記憶體即時清零，顯著縮小側信道與記憶體殘留攻擊面。

### 負面影響與代價 (Trade-offs)
- 需撰寫 Kotlin 與 Swift 原生平台通道代碼，增加了跨平台整合與維護成本。
- 若使用者更換硬體設備，由於金鑰綁定實體晶片，必須依靠實體助記詞重新還原，無法自動雲端無縫漫遊（此為安全冷錢包之預期行為）。
