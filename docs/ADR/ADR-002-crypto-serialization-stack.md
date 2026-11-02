# ADR-002: 密碼學、區塊鏈原語與序列化程式庫選型 (Crypto & Serialization Stack)

- **狀態**：ACCEPTED
- **日期**：2026-10-12
- **決策者**：FCW Architecture Team
- **工作包**：FCW-OKX-20261012

---

## 1. 背景與問題脈絡 (Context)

行動冷錢包需處理多種密碼學標準、交易格式與二進位序列化協定：
- 標準密碼學：BIP-39 助記詞、BIP-32 HD 派生、secp256k1 橢圓曲線標量運算、ECDSA 簽章與公鑰恢復；
- 以太坊生態：RLP 編解碼、EIP-155 防重放簽章、EIP-1559 費用市場交易結構、EIP-712 結構化資料雜湊；
- 比特幣生態：BIP-174 PSBT v0、Native SegWit P2WPKH 腳本與輸入校驗；
- 氣隙傳輸格式：BC-UR (Luby Transform 噴泉碼) 與 CBOR 二進位序列化；
- 跨語言通信：Dart (Flutter) 與 Rust 之間的型別安全 FFI 橋接。

若自研密碼學曲線運算或引入未經廣泛審計的第三方輪子，可能因側信道攻擊、nonce 重用或 low-s 規範錯誤導致私鑰失竊；若引入包含全量 RPC/網路功能的現成 SDK（如完整的 Web3 套件或 Alloy 全量套件），可能導致連網代碼滲透至離線端。

---

## 2. 決策內容 (Decision)

### 2.1 密碼學與曲線計算
1. **橢圓曲線與 ECDSA 簽署**：
   - 選用 `secp256k1`（版本 `=0.33.1`，綁定 Bitcoin Core C 實作，啟用 `recovery`, `rand-std`, `alloc`）。
   - 強制執行 RFC 6979 確定性 nonce 生成，徹底避免 PRNG 瑕疵導致私鑰洩漏。
   - 簽名輸出強制實施 Low-S 規範化（若 $s > n/2$ 則轉換為 $n - s$）。
2. **助記詞與 HD 派生**：
   - 選用 `bip39`（版本 `=3.0.0`，純 Rust 實作，啟用 `zeroize` feature）。
   - 支援 12 與 24 單詞生成及選填 passphrase。
3. **哈希計算**：
   - 選用 `tiny-keccak`（版本 `=2.0.2`，啟用 `keccak` feature），作為純軟體 Keccak-256 實作。

### 2.2 以太坊原語 (EVM Stack)
1. **資料結構與 RLP 編解碼**：
   - 選用 `alloy-primitives`（`=1.7.3`，`default-features = false`，僅啟用 `rlp`）與 `alloy-rlp`（`=0.3.16`）。
   - 選用 `alloy-consensus`（`=2.5.0`，`default-features = false`）用於交易結構體解析。
2. **剛性禁令**：
   - **嚴格禁止引入** `alloy-provider`、`alloy-transport`、`alloy-rpc-client` 等任何帶有網路連線功能的 Alloy 子模組。
   - 僅引入無 std-io 的純粹記憶體資料運算原語。

### 2.3 比特幣原語 (Bitcoin Stack)
1. **資料結構與 PSBT 處理**：
   - 選用 `rust-bitcoin`（`=0.32.0`，`default-features = false`，僅啟用 `std`, `secp-recovery`）。
   - 範圍限定於 BIP-174 PSBT v0、Native SegWit P2WPKH 簽署與前序交易（`nonWitnessUtxo`）費用校驗。

### 2.4 氣隙傳輸與序列化 (Wire Protocol)
1. **BC-UR 與 CBOR 編解碼**：
   - 選用 `ur`（`=0.5.2`）處理 Luby Transform 噴泉碼切片與重組。
   - 選用 `ciborium`（`=0.2.2`）實現有界 CBOR 解析器（<=128 KiB payload，<=16 嵌套深度，拒絕重複 key）。
   - 選用 Keystone 開源之 `ur-registry`（commit `9de4a760b0e6d8693204c3fdf9dc148d82b9e831`）。
2. **信任邊界澄清**：
   - Keystone SDK 僅作為跨裝置傳輸協定之編解碼轉換器，**絕非交易合法性或簽章授權的信任來源**。

### 2.5 跨語言 FFI 橋接技術
- 選用 `flutter_rust_bridge`（`=2.13.0`），提供記憶體安全、型別安全之跨語言 C-ABI 自動綁定。

---

## 3. 後果評估 (Consequences)

### 正面影響 (Positive)
- 核心運算依賴經過比特幣與以太坊社群數年戰場檢驗的底層庫，杜絕手寫曲線的災難性風險。
- 精確裁減依賴 feature，產物完全不含網路傳輸代碼。

### 負面影響與代價 (Trade-offs)
- Rust Crate 鎖定版本必須定期審查安全性諮詢（Advisory），升級時需手動審查 feature graph。
- FRB v2 代碼生成需保持 Dart 與 Rust 定義嚴格同步。
