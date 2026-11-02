# ADR-005: 主網網路支援：網路模型、政策分割與上線閘門 (Mainnet Networks)

- **狀態**：ACCEPTED（2026-10-20；持有人決定第 14.1 節全部事項）
- **日期**：2026-10-20
- **決策者**：FCW Architecture Team；主網開放、各項數值上限與第 14 節的開放問題由持有人簽核
- **工作包**：FCW-OKX-20261012 的主網延伸。本文件就是 `AGENT_WORK_PACKAGE.md:350` 要求的「上線風險與金鑰遷移審查」紀錄，也是 `REQUIREMENTS.md:45` 要求的需求變更決策紀錄。
- **程式基準**：`77758a8`（branch `adr-005`）。所有 `檔案:行` 皆相對於 repo 根目錄，並已在此 commit 重新核對。
- **輸入**：主網盤點（mainnet survey，基準 `97eafba`；與本基準的差異見附錄 B）與外部事實查核（mainnet facts，查核日 2026-10-20；來源見附錄 A）。外部數值只從 facts 複製，保留其 **UNVERIFIED** 標記；facts 沒有的協定數值一律寫成「實作時依原文核對」，不在本文給值。
- **修訂**：第二版（2026-10-20）回應第一輪三方審查（Codex、Opus、Argon）；第三版（同日）回應第二輪審查，重寫第 2.5 節並新增第 2.6、2.7、10.6 節與附錄 E、F；第四版（同日）回應第三輪四方審查（另加 GPT 6 Pro）：資源狀態改為由證據推導並可多重引用、新增資源救援與調解、主網單一來源規則、族外交易的驗證規格、EIP-7702（第 4.6 節）與逐期匯出清單（附錄 E）；第五版（同日）回應第四輪審查：角色與意圖類型相容、救援與清除集合不能被外部付款沿用、單一來源規則擴及所有意圖、可更正的 nonce 消耗證據、存疑紀錄、收款內容嚴格子集與 Vault 單獨收款範圍；第六版（同日）回應第五輪審查：不受高度限制的質疑證據入口、以交易歷史重建的清除覆蓋、Vault 主網收款的公開種子檢查、Vault 端的委派回呼揭露與收款內容的完整語法；第七版（同日）回應第六輪審查並以簡化收斂：刪除自動或半自動解除「歷史可能不完整」的窄確認，旗標只能由使用者全面確認解除；第八版（同日）依第七輪審查只做文字修正，不改設計；之後持有人於 2026-10-20 決定第 14.1 節全部事項，狀態改為 ACCEPTED。逐項處理見附錄 D，審查中確認的現行程式缺陷見第 15 節，決定的變動見附錄 C。

本文件中的編號：
- `KEEP-nn`：必須保留的既有防護（第 1.3 節）。
- `MN-nn`：本 ADR 新增的不變量，每一條在第 11 節指定釘住它的測試檔。
- `D-nn`：本 ADR 作者自行作出、持有人尚未指定的決定（彙整於附錄 C），供審查者集中挑戰。
- `Q-nn`：留給持有人的開放問題（第 14.1 節）。

---

## 0. 與既有 ADR 及治理文件的關係

| 既有規則 | 本 ADR 的處理 | 類型 |
|---|---|---|
| ADR-001 §2.1 五個 crate 的依賴隔離；`wallet_ffi` 不得依賴 `vault_core` | 不變。新增的網路表放在 `public_core`（純資料與純函式，不含私鑰 API） | 保留 |
| ADR-001 §1（背景）列出「以 Cargo feature 區分功能」的風險；具拘束力的是 §2.1、§2.2 | 該風險針對 Wallet／Vault 能力的隔離。本 ADR 新增一個只增加本機開發網路資料的 `dev-networks` feature，並說明為何不屬於該風險（第 3.3 節） | 擴充（新增 feature 規則） |
| ADR-001 §2.2 建置期稽核 | 現行只落實一部分（C-15），且「二進位不含 sign／private_key／mnemonic 符號」在現行依賴下無法成立。改寫為可執行的規則：對上傳的 AAB 稽核全部原生庫、FFI 匯出集合完全等於附錄 E 並記錄輸入契約、dev 哨兵、表指紋、依賴樹不得含 `vault_core` 與 `bip39`、`public_core` 不含秘密型別（第 3.4 節） | 修訂（第 2 點）與擴充 |
| ADR-002 §2.3 比特幣原語 | 地址「顯示」擴充到 P2WSH、P2TR（bech32m）、P2SH、P2PKH（base58check），不新增執行期 crate（第 8 節）。ADR-002 與實際依賴多處不符：`rust-bitcoin =0.32.0`、`alloy-*`、Keystone `ur-registry`、`flutter_rust_bridge` 都不在 `Cargo.lock`／`pubspec.yaml`；bip39 的需求為 `"2.1.0"`（`crates/vault_core/Cargo.toml`），lock 解析為 `2.2.2`。本 ADR 以實際依賴為準，並建議持有人核准 ADR-002 的正式修訂（`Q-17`） | 擴充；ADR-002 需另行修訂 |
| ADR-003 金鑰儲存 | 不變。`crates/vault_core/src/storage.rs:13` 的 `CURRENT_STORAGE_SCHEMA_VERSION = 2` 與 AAD 不動 | 保留 |
| ADR-004 §2.1 禁止盲簽 | 擴充到 BTC 輸出：無法顯示為地址的輸出一律拒簽，刪除 `script:<hex>` 顯示路徑（第 8 節） | 擴充 |
| ADR-004 §2.2 金額禁用浮點 | 擴充到 BTC 費率：一律以整數 sat/kvB 表示與比較（第 6.6 節） | 擴充 |
| ADR-004 §2.3.1 ChainId 白名單「僅本地測試鏈與 Sepolia」 | 修訂為編譯期的逐鏈政策表，含五條主網與其官方測試網；本機鏈只在 dev 建置（第 3、4 節） | 修訂 |
| ADR-004 §2.3.2 內外層 chain_id 一致 | 不變（`KEEP-03`） | 保留 |
| ADR-004 §2.3.3 交易型態白名單 | 改為逐鏈白名單，並把分派點改成明確列舉（第 4.2 節） | 修訂 |
| ADR-004 §2.3.4 ERC-20 只允許白名單 Mock 合約 | 改為以 `(chain_id, address)` 為 key 的實際合約表；未知代幣仍 fail-closed（第 5 節） | 修訂 |
| `AGENT_WORK_PACKAGE.md:336`「release 須無 … mainnet switch」 | release 不提供任何「開／關主網」的執行期開關；主網可用與否只由編譯期網路表決定，使用者只在已允許的網路之間選擇。持有人核准本 ADR 即視為以此解讀取代該條原文 | 修訂（需持有人核准） |
| `AGENT_WORK_PACKAGE.md:340`「未經獨立審查前產物標示 `EXPERIMENTAL / TESTNET ONLY`」 | 持有人已決定上線前不做外部稽核，改為在 App 與商店文案標示「未經第三方安全稽核，請先小額使用」；本 ADR 記錄此取代（第 14.1 節） | 修訂（持有人已決定） |
| `docs/threat-model.md` §1.2 Invariant 4「unapproved chain ID」 | 「approved」改指本 ADR 的編譯期網路表；§8 STRIDE 需新增「Esplora／RPC 後端不可信與隱私」與「第三方（OKX）主網請求」兩列（第 11 節 Phase 0 文件項） | 修訂 |

---

## 1. 背景與威脅變化 (Context & Threat Delta)

### 1.1 現況

目前只允許測試網路。實際的拒絕點只有少數幾處：

| 資產 | 拒絕點 | 內容 |
|---|---|---|
| EVM | `crates/public_core/src/policy.rs:55-59` | `allowed_chain_ids = [11155111, 1337, 31337]`；`:54` 註解「Mainnet (1) is strictly excluded」 |
| EVM | `crates/vault_ffi/src/lib.rs:1062` | 不在 allowlist 即回「Only local/testnet signing is enabled」 |
| EVM | `crates/vault_ffi/src/lib.rs:184`、`crates/wallet_ffi/src/lib.rs:1060` | 兩端都用 `PolicyEngine::default()`，同一份表 |
| BTC | `crates/vault_ffi/src/lib.rs:1368`、`:1393`、`:1473-1477` | UR 入口寫死 `"bcrt"`；`network_hrp != "bcrt"` 即拒絕；預設 `"bcrt"` |
| BTC | `crates/wallet_ffi/src/bitcoin_api.rs:16`、`:31-45`、`:181-182`、`:343-354` | `ACCOUNT_PATH = "m/84'/1'/0'"`、只接受 `tpub`、收款地址只解 `bcrt`、回應驗證只認 `84'/1'/0'` |

BTC 的 prepare 路徑完全不經 `PolicyEngine`：`crates/vault_ffi/src/lib.rs:1418-1423` 直接建構 `PolicyVerdict::Approved`，`chain_id` 固定為 0（`:1429`），DTO 的 `"network": "regtest"` 寫死（`:1444`）。

### 1.2 資金為真之後改變的威脅

| # | 威脅 | 測試網時的後果 | 主網時的後果 | 本 ADR 對策 |
|---|---|---|---|---|
| T1 | 代幣小數位數或名稱誤讀（代幣表只以地址為 key，散在 `policy.rs:35-51`、`review_model.dart:203-214`、`scan_signature_screen.dart:447-452`、`node_rpc_client.dart:35-38`）；原生幣名稱寫死為 ETH（第 15 節 C-10） | 顯示錯誤 | 使用者確認的金額與實際簽署相差 10^12 倍；橋接 USDC 的鏈上 `symbol()` 也是 `USDC`（facts §2.1）；Polygon 的 POL 被顯示為 ETH | 第 5 節，`MN-06` |
| T2 | BTC 非 P2WPKH 輸出只顯示 `script:<hex>`（`crates/public_core/src/bitcoin.rs:1123-1133`）；多收款輸出時審查頁頂端只列第一個地址（C-06） | 無價值 | 被入侵的 Wallet 可加入使用者看不懂的輸出，等同盲簽 | 第 8 節，`MN-08` |
| T3 | BTC 簽署時由 PSBT 反推網路（`crates/vault_core/src/lib.rs:618-629`） | 無 | 網路不是在 prepare 時綁定 | 第 2.3 節，`MN-07` |
| T4 | 手續費只有絕對上限：BTC 5,000,000 sat（`bitcoin.rs:1169-1172`），EVM 0.05 ETH（`policy.rs:60`）；BTC 無費率概念；OP／Base 的 L1 data fee 與 operator fee 不在簽章內，沒有任何簽章欄位能限制它們 | 測試幣損失 | 上限內的手續費可被灌高；OP／Base 的額外費用沒有硬上限（真正的上限只有帳戶餘額） | 第 4.3、6.6 節，`MN-05`、`MN-10` |
| T5 | 第三方（OKX）發起的主網請求只經過 Vault（`crates/vault_core/src/lib.rs:393-458` 的匯出不帶 chain 資訊） | 被拒 | Vault 是唯一閘門 | 第 3、4 節，`MN-02`、`MN-03`、`MN-18` |
| T6 | 測試與公開助記詞被用於主網：EVM 金鑰與鏈無關；`abandon … about`（指紋 `73C5DA0A`）出現在 `crates/vault_ffi/src/lib.rs:1863`、`crates/vault_core/src/lib.rs:738` 等處 | 無 | 任何人都能動用 | 第 10.4 節，`MN-14` |
| T7 | 已簽但未廣播的交易仍有效；Vault 簽完而 Wallet 尚未掃回時，Wallet 不知道已簽 | 無 | 使用者以為已取消，持有已簽 bytes 的人之後仍可廣播 | 第 2.5 節，`MN-12` |
| T8 | 後端（Esplora／RPC）不誠實或記錄資料：隱藏 UTXO、偽造入帳、謊報費率、狀態或「已被花掉」、記錄地址與 IP | 無 | 餘額顯示錯誤、費用被灌、隱私外洩，並可**誘使使用者重複付款**；後端無法讓 Wallet 建出「金額被謊報卻仍有效」的交易（`KEEP-13`） | 第 2.5、6、10.5 節，`MN-12`、`MN-16` |
| T9 | 狀態不明或「可能已簽」時建立不衝突的新交易，造成重複付款（現行 BTC `newDraft` 會把已匯出的請求標為 `cancelled`，第 15 節 C-01） | 測試幣重複付款 | 真實重複付款 | 第 2.5 節，`MN-12`、`MN-13` |
| T10 | 網路選擇器是全域的，切換時改寫所有 EVM 帳戶（`apps/wallet/lib/screens/account_screen.dart:300-312`） | 困惑 | 以為在 Sepolia，其實在主網 | 第 4.5、10 節，`MN-15` |
| T11 | RPC 錯誤訊息帶出完整 URL（`apps/wallet/lib/services/node_rpc_client.dart:225`）與回應本文（`:232`） | 無 | 帶 API key 的 RPC URL 外洩 | 第 4.4 節，`MN-16` |
| T12 | release 產物帶入本機開發網路、test fixture 或舊的 dev 原生庫 | 無 | 稽核面擴大；本機鏈不能動到主網資金（見第 3.3 節失效分析），但違反「release 不含開發功能」 | 第 3 節，`MN-01` |
| T13 | 找零被放在很高的合法 index（Vault 重新派生仍視為自有找零），一般 gap-limit 掃描找不到（現行無上界，C-03） | 無 | 資金在密碼學上仍屬使用者，但實務上失聯 | 第 6.4 節，`MN-17` |
| T14 | 被入侵的 Wallet 把攻擊者的地址顯示成使用者的收款地址；收款不經 Vault | 收到測試幣的是攻擊者 | 付款人直接付給攻擊者 | 第 10.6 節，`MN-19` |
| T15 | 帳戶已有 EIP-7702 委派（同一組種子曾在其他工具設定委派） | 無 | 任何呼叫該帳戶的交易都會執行委派程式，包括 `to = 自己` 的零金額取消；收款合約也可以回呼它；Vault 只看到顯示的金額 | 第 4.6 節，`MN-21` |

### 1.3 必須保留的既有防護

主網化不得削弱下列任何一項；每一項都已有測試，Phase 0 起列入回歸集。

| ID | 防護 | 位置 |
|---|---|---|
| KEEP-01 | `PreparedRequest::new` 拒絕 `Rejected` verdict；所有 prepare 路徑都經過它 | `crates/signer_router/src/lib.rs:112-114` |
| KEEP-02 | 單一 active handle、取消／逾時失效、`SigningOutcomeUnknown` 不自動重試、同一已簽請求再掃描回傳快取結果而不再簽 | `crates/vault_ffi/src/lib.rs:69-104`、`:1527-1562`、`:1573-1580` |
| KEEP-03 | 外層宣告 chain 與請求 chain、RLP 內層 chain 必須一致 | `crates/vault_ffi/src/lib.rs:1048-1060`；`crates/public_core/src/evm.rs:145-150`、`:304-309` |
| KEEP-04 | EIP-155 強制：`v ∈ {0, 27, 28}` 拒絕 | `crates/public_core/src/evm.rs:112-114` |
| KEEP-05 | 拒絕 `approve`、`increaseAllowance`、`setApprovalForAll`、Permit2；ERC-20 不得夾帶原生幣；dirty padding；合約部署 | `crates/public_core/src/evm.rs:207-243`、`:482-517` |
| KEEP-06 | fee cap 解析失敗視為 `u128::MAX` 而拒絕 | `crates/public_core/src/policy.rs:91`、`:128` |
| KEEP-07 | QR 版停用 personal_sign 與 EIP-712 | `crates/vault_ffi/src/lib.rs:1107-1109` |
| KEEP-08 | 請求的 path 與 address 綁定、master fingerprint 綁定 | `crates/vault_ffi/src/lib.rs:1112-1135` |
| KEEP-09 | 審查 DTO 完整驗證，含 `fee_cap == gas_limit × price` | `packages/public_models/lib/src/review_model.dart:228-265`、`:406-439` |
| KEEP-10 | PSBT：強制 `non_witness_utxo` 並核對 txid；`witness_utxo` 交叉比對；只接受 P2WPKH 輸入與 `SIGHASH_ALL`；拒絕未知欄位（取捨理由見第 8.2 節第 7 點）；≤128 KiB | `crates/public_core/src/bitcoin.rs:1039-1055`、`:1069-1088`、`:1001-1009`、`:593-597` |
| KEEP-11 | 每個輸入與每個宣稱 derivation 的輸出都用 Vault 種子重新派生 pubkey 與 script 比對（擋假找零與外部輸入） | `crates/vault_core/src/lib.rs:564-610` |
| KEEP-12 | 簽後 ECDSA 自我驗證；最終簽章驗證與 low-S | `crates/vault_core/src/lib.rs:710-715`；`crates/public_core/src/bitcoin.rs:1185-1249` |
| KEEP-13 | Wallet 建 PSBT 時核對前置交易 txid 與 script 屬於帳戶：不可信後端無法讓 Wallet 建出「金額被謊報卻仍有效」的交易（但仍可偽造入帳的顯示，第 10.5 節） | `crates/wallet_ffi/src/bitcoin_api.rs:191`、`:203` |
| KEEP-14 | Wallet 驗回應：回傳 PSBT 去掉 `partial_sigs` 後必須與原 PSBT 完全相同 | `crates/wallet_ffi/src/bitcoin_api.rs:327-336` |
| KEEP-15 | 廣播前先核對網路與 `canDispatch`；結果不確定時只能查詢同一筆交易 | `apps/wallet/lib/services/bitcoin_rpc_client.dart:282-299`；`apps/wallet/lib/services/node_rpc_client.dart:159-181`；`apps/wallet/lib/screens/bitcoin_send_screen.dart:382-467` |
| KEEP-16 | BTC 恢復時以公開請求重建 PSBT，逐一比對 `psbt_hex`、digest、txid | `apps/wallet/lib/screens/bitcoin_send_screen.dart:211-239` |
| KEEP-17 | 公開備份不含秘密，匯出時移除 RPC 端點 | `apps/wallet/lib/services/public_backup.dart:89-93`、`:349`、`:356` |
| KEEP-18 | Vault APK 無 `INTERNET`／`ACCESS_NETWORK_STATE`；release 原生庫無 test fixture 匯出；Wallet 原生庫無 `vault_` 符號 | `tools/release_checks/verify_qr_apks.py:44-46`、`:63-67` |
| KEEP-19 | **（第三版更正：不是既有防護，而是必須新增的規則）** Wallet 以共用的 App 內 URL 規則強制 HTTPS：release 與 dev 建置相同：`http` 只允許 loopback（`localhost`、`127.0.0.0/8`、`::1`）、區域網路私有位址字面值（`10/8`、`172.16/12`、`192.168/16`、`169.254/16`、`fc00::/7`、`fe80::/10`），以及單一標籤主機名與以 `.local` 結尾的名稱；使用 `http` 時，URL 欄位下方常駐警告「此連線未加密：同一網路上的其他裝置可以看到你的地址、交易與節點帳號密碼。只在你信任的家用網路使用。」；其他主機一律必須 `https`，儲存時拒絕，每次請求時再檢查一次（`Q-21`，已決定）。理由：主要的 BTC 用法是使用者家中區域網路上、沒有 TLS 的自有 Bitcoin Core。第一版把 `network_security_config.xml:3-9` 當成依據是錯的：依 play-writer 對 Flutter engine 3.47.2 與 3.41.3 原始碼的核對，`dart:io` 不受該設定約束（`settings.h:167` 預設允許不安全連線，Android 從未傳入 `--disallow-insecure-connections`；engine 原始碼未經本 ADR 作者獨立核對）。現行 Wallet 對任何主機都接受 `http`（C-22） | 現行檢查：`apps/wallet/lib/screens/account_screen.dart:336-342`、`apps/wallet/lib/services/bitcoin_rpc_client.dart:53-58`；平台設定 `apps/wallet/android/app/src/main/res/xml/network_security_config.xml:3-9` 保留，但不作為依據 |
| KEEP-20 | `wallet_ffi` 不依賴 `vault_core`（ADR-001 §2.1） | `crates/wallet_ffi/Cargo.toml` |
| KEEP-21 | Vault 公開簽署結果綁定 `chain_id` 與 `network` | `apps/vault/lib/services/public_signed_result_store.dart:287-345` |
| KEEP-22 | 政策不得動態下載 | `AGENT_WORK_PACKAGE.md:336` |

---

## 2. 網路模型

### 2.1 EVM：`chain_id` 是端到端的明確參數

EVM 地址與網路無關（Vault 一律 `m/44'/60'/0'/0/n`，`crates/vault_core/src/lib.rs:194-241`），所以帳戶不依網路複製；網路是**每筆請求**的參數，簽章本身就綁定它（EIP-155 的 `v` 或 type-2 的 `chain_id` 欄位）。

| 階段 | 網路從哪裡來 | 檢查 |
|---|---|---|
| Wallet 建立 | 使用者在轉帳頁明確選擇的網路（不是全域選擇器） | 該網路必須在 `wallet_ffi` 匯出的網路表中；`eth_chainId` 必須等於 `chain_id`（`MN-16`） |
| Wallet 預檢 | 同上 | `wallet_ffi` 以同一份表評估（取代 `crates/wallet_ffi/src/lib.rs:1060` 的 `PolicyEngine::default()`）；預檢只是提早失敗，不能取代 Vault |
| 傳輸 | `eth-sign-request` key 4 的 `chain_id`（`crates/ur_adapter/src/eth_sign_request.rs:109-112`）與 RLP 內層 | — |
| Vault prepare | 外層與內層 | `KEEP-03`；`NetworkPolicy::evm(chain_id)` 查表，查無即拒絕（`MN-02`）；逐鏈交易型態（`MN-03`）、費用（`MN-05`）、代幣（`MN-06`） |
| Vault sign | `PreparedRequest` 已綁定的 `chain_id`；preimage 本身含 `chain_id` | `KEEP-02` |
| Wallet 驗簽與廣播 | 紀錄中的 `chain_id` | 回應的 `v`／`y_parity` 與 chain 相符；廣播前再次 `eth_chainId`（`KEEP-15`） |

### 2.2 Bitcoin：網路是帳戶屬性

BTC 的網路寫在派生路徑裡：主網是另一個帳戶 `m/84'/0'/0'`，不是同一帳戶換旗標。

| `BtcNetwork`（Wallet 帳戶屬性） | 建置層級 | HRP | coin type | 擴充公鑰前綴 | Vault 可分辨的簽署域 `BtcSigningDomain` | 預設後端 |
|---|---|---|---|---|---|---|
| `Bitcoin` | release | `bc` | `0'` | `xpub` | `Mainnet` | Esplora `https://mempool.space/api` |
| `Signet` | release | `tb` | `1'` | `tpub` | `TestTb` | Esplora `https://mempool.space/signet/api` |
| `Testnet4` | release | `tb` | `1'` | `tpub` | `TestTb` | Esplora `https://mempool.space/testnet4/api` |
| `Regtest` | dev | `bcrt` | `1'` | `tpub` | `Regtest` | Bitcoin Core RPC `http://127.0.0.1:18443/wallet/fcw_watch`（`apps/wallet/lib/screens/bitcoin_send_screen.dart:29-30`） |

- 三個 Esplora base URL 來自 facts §5.1（實測與 mempool.space 文件一致，已驗證）。blockstream.info 沒有 testnet4（`/testnet4/api/*` 回 HTTP 200 的 HTML，facts §5.1），只能當自訂端點用於 mainnet／signet。
- testnet3 不列入。
- **可分辨性（誠實說明）**：Signet、Testnet4、Regtest 共用 coin type `1'` 與同一把金鑰。Vault 能用密碼學確認的只有「`0'` 或 `1'`」（`KEEP-11` 的重新派生會把 coin type 釘死在 Vault 自己的種子上），無法分辨三個測試網路。Signet 與 Testnet4 的 HRP 都是 `tb`，地址顯示相同，所以 release 的 Vault 只需要 `TestTb` 一個測試域。Regtest 的 HRP 不同，只存在 dev 建置。
- **殘餘風險**：segwit v0 簽章不承諾網路。若有主網資金落在 `m/84'/1'/0'/*` 派生的 script 上（例如使用者在其他軟體把測試路徑誤用於主網），Vault 會在 `TestTb` 域把它當測試網交易簽署，畫面標示「測試網」、地址顯示為 `tb1…`。為了不讓這種情況多一層損失，`TestTb` 的手續費上限與 `Mainnet` 相同（第 6.6 節）【D-25】；顯示錯誤本身無法消除，列入第 12.6 節。
- `public_core` 新增 `BtcNetwork` 與 `BtcSigningDomain` 列舉及對照表（HRP、coin type、前綴、層級），取代目前散在 `crates/vault_core/src/lib.rs:250-258`、`:555-563` 的字串比對。所有 BTC FFI 改為接收明確的 network 參數（Phase 0）。

### 2.3 Vault 在 prepare 時綁定網路（不在 sign 時重推）

現況：`sign_psbt_p2wpkh` 由第一個輸入的 coin type 推出 HRP（`0'` → `"bc"`，否則 `"bcrt"`），再用推出的 HRP 審核一次（`crates/vault_core/src/lib.rs:618-629`）。網路沒有存進 `PreparedRequest`，BTC 只靠 `chain_id = 0` 識別（`crates/vault_ffi/src/lib.rs:1429`），sign 路徑也以 `req.chain_id == 0` 分派（`:1581`、`:1606`）。

決定（`MN-07`）：

1. `crates/signer_router` 的 `PreparedRequest` 新增欄位 `network: NetworkBinding`，`enum NetworkBinding { Evm { chain_id: u64 }, Btc { domain: BtcSigningDomain } }`。不使用假 chain_id；sign 路徑改以 `NetworkBinding` 分派，刪除 BTC 的 `chain_id = 0`。
2. `prepare_from_crypto_psbt`（`crates/vault_ffi/src/lib.rs:1382`）決定域的規則：
   - 所有輸入的 derivation 與所有宣稱 derivation 的輸出，其 coin type 必須相同；混用 `0'` 與 `1'` 即拒絕。
   - coin type `0'` → `Mainnet`；`1'` → release 建置為 `TestTb`，dev 建置為 `Regtest`（dev Vault 另有僅限 dev 的設定可改成 `TestTb`，供在 dev 建置上跑 signet）【D-01】。
   - 該域必須在本建置的網路表內，否則拒絕。
   - 之後的 `audit_psbt_p2wpkh(psbt, domain)` 沿用 `KEEP-11` 的重新派生，coin type 因此被 Vault 種子釘死。
   - Dart 目前可傳入網路：`vault_prepare_psbt_request` 的 `network_hrp` 參數（`crates/vault_ffi/src/lib.rs:1473-1477`，Dart 預設 `'bcrt'`，`apps/vault/lib/ffi/vault_ffi_service.dart:449`）。Phase 0 刪除此參數；release 建置中簽署域**永遠不從 Dart 接收**。唯一受 Dart 影響的輸入是 dev 建置的測試 HRP 設定，且該設定只在 `dev-networks` 下編譯。
3. `sign_psbt_p2wpkh(psbt, domain)` 以參數接收已綁定的域，簽署前斷言 PSBT 的 coin type 與域一致；刪除 `crates/vault_core/src/lib.rs:618-629` 的推斷。
4. 回應快取 key（`crates/vault_ffi/src/lib.rs:1576`）改以 `NetworkBinding` 取代 `chain_id`。注意：signet 與 testnet4 的同一份 PSBT bytes 相同、綁定同一個 `TestTb`，快取 key 對兩者沒有區分作用（無害；盤點「不同網路的 PSBT bytes 必然不同」對這兩者不成立）。
5. 審查 DTO 由原生端提供 `network_id`（例如 `evm:1`、`btc:mainnet`、`btc:test-tb`、`btc:regtest`）、`network_class`（`main`／`test`／`dev`）與 `network_display`；Dart 以 `vault_network_policy_json` 取得的表驗證這三個欄位彼此一致，取代 `packages/public_models/lib/src/review_model.dart:532-534`（只接受 `regtest`）、`:587`（寫死 `m/84'/1'/0'`）、`:596`。BTC 的帳戶派生路徑也由原生端回傳。

### 2.4 帳戶身分、schema 版本與遷移

**帳戶身分**：master fingerprint 只有 32 bits，可能碰撞，匯入檔也可以自行宣稱任意 fingerprint，所以不能當帳戶身分。
- EVM 帳戶身分 = EIP-55 地址。
- BTC 帳戶身分 `account_id` = SHA-256（帳戶層擴充公鑰序列化 ‖ `BtcNetwork` 名稱）的前 16 hex。匯入、備份合併與歷史檔比對時，比對完整擴充公鑰（含 chain code）、origin path 與 network；fingerprint 相同而公鑰不同時，視為不同帳戶並警示，**絕不覆寫**。fingerprint 只作顯示與 Vault 請求的 `source_fingerprint`。

**版本規則**：讀舊寫新、絕不降版；舊版 App 讀到新版檔案時拒絕（單向門，發版說明須寫明）。下表列出每個檔案為何符合此規則。

| 資料 | 現行 | 新版（Phase 1a 起寫入） | 舊讀取器遇到新檔 |
|---|---|---|---|
| Wallet 帳戶檔（`apps/wallet/lib/services/account_store.dart:5-35`；`supportedChains`（`:21`）） | `schema_version: 1`；單一 `selected_chain_id` 與 `rpc_url` | v2：`accounts[]`（每筆帶 `network` 與 `account_id`）、`evm_profiles{chain_id → {rpc_url, verified_chain_id, privacy_ack}}`、`btc_backends{network → {kind, base_url, second_host}}`、`last_network_by_account`、BTC 位址高水位（第 6.4 節） | 拒絕（`:27-33` 只接受 v1） |
| EVM 歷史 `public_transactions.json`（`apps/wallet/lib/services/transaction_history.dart:12-32`） | `version: 1`，每筆有 `chainId`、`rpcUrl` | v2：新增 `network_id`，並改存第 2.5 節的意圖、成員與證據；查詢改用該 chain 的 profile，不再要求 `rpcUrl` 字串相同（`apps/wallet/lib/screens/scan_signature_screen.dart:82-88`、`:98-99`） | 拒絕（`:25` 只接受 v1） |
| BTC 紀錄 `bitcoin_<fp>.json`（`apps/wallet/lib/screens/bitcoin_send_screen.dart:134-147`，`schema_version ∈ {1,2}`） | 檔名只有 fingerprint | `bitcoin_<account_id>.json`，`schema_version: 3`：`network`、完整擴充公鑰、`backend{kind, base_url}`、意圖、成員與證據、高水位與已發出清單 | 舊檔名不同，舊讀取器看不到新檔；不會誤讀 |
| 公開備份（`apps/wallet/lib/services/public_backup.dart:264-381`；`version ∈ {1,2}`；每個 fp 一份 BTC 紀錄 `:507-510`） | v1／v2 | v3：每個帳戶帶 `network` 與 `account_id`；BTC 紀錄以 `account_id` 為 key；EVM 紀錄**保留所有網路**（修正 C-09）；含付款意圖、成員、證據、存疑紀錄、調解確認與觀察期內的已結算紀錄（第 2.6 節）；仍移除端點（`KEEP-17`） | 拒絕（`:280` 只接受 1、2） |
| Vault 加密庫（`crates/vault_core/src/storage.rs:13`、`:79-87`） | v2 | **不變**，不動 AAD | — |
| Vault 公開簽署結果（`apps/vault/lib/services/public_signed_result_store.dart`） | `schema_version: 1` | **不升版**；`network` 允許表中的值，metadata 加入 `network`（修正 C-13）。另新增獨立的公開索引檔，供「最近已簽」提示（第 2.6 節第 8 點），不改既有結果檔 | 舊 Vault 建置會把未知網路顯示為「Unknown」。這些紀錄只是以 `signing_digest` 綁定的顯示快取，簽署仍由該建置的原生政策決定，所以不升版是安全的 |

**遷移程序（Phase 1a，不在 Phase 0）**【D-24】：
1. 先把 Wallet 的全部公開檔案複製到 `pre-v2-backup/<UTC 時間>/` 並 `fsync`。
2. 所有新檔寫到 `migration-v2.tmp/`；付款紀錄最先遷移，舊狀態依第 2.6 節第 5 點對照。
3. 最後寫入標記 `migration-v2.done`，再逐一 `rename` 到正式位置。啟動時若標記不存在，丟棄暫存目錄重跑（冪等）；若標記存在但未完成搬移，繼續搬移。
4. 遷移前的副本保留到使用者確認或連續 3 次正常啟動之後。Play 不能降版安裝，解除安裝又會刪除 App 私有目錄（審查意見 Opus m-5），所以回復方式改為：使用者先把副本匯出到自己選擇的位置；必要時發佈以舊程式碼建置、versionCode 較高的「還原建置」讀入該副本。遷移之後只要建立過任何新成員，回復就停用（否則會遺失之後的資源保留，審查意見 Codex R2-I1）。還原演練依此流程進行。
5. 舊 BTC 帳戶一律標為 `regtest`；release 建置中保留但列在「僅開發版支援的網路」下且不可操作，提示重新配對，**不**自動改標為 signet【D-03】。
6. v1 的 `rpc_url` 只在 `selected_chain_id` 屬於本建置網路表且 URL 通過第 4.4 節驗證時，搬到對應 profile；否則捨棄並提示。`last_network_by_account` 只在原 chain 仍在表中時設定；**遷移絕不預設成任何主網**【D-02】。

### 2.5 付款意圖、成員與資源：防重複付款的單一模型（`MN-12`、`MN-13`）【D-19，第五版修訂】

本節取代第二版的 PA-1–PA-8，EVM 與 BTC 共用；驗收案例在附錄 F。保護範圍：這些規則只存在連網的 Wallet，Vault 離線且無狀態。它們防的是「誠實的 Wallet 遇到使用者失誤或說謊的後端」；對被入侵的 Wallet（T2）無效，對 T2 的防線仍是 Vault 審查頁與第 10.6 節的收款地址核對。第四版把資源狀態改為**由證據推導、可被多個成員引用**，並新增 `rescue`（審查意見 Codex R3-B1、R3-I4，GPT 第三輪 B1、B2）【D-39】。第五版的改變：成員角色必須與意圖類型相容，救援與清除集合不能被外部付款沿用【D-46】；救援可以明確選擇較低費用【D-45】；單一來源規則適用於所有意圖類型；可以更正來源回報錯誤的消耗證據【D-47】；存疑改為只增不減的紀錄【D-48】（審查意見 Codex R4-B1、R4-I1、R4-I2，GPT R4-B1–B3、R4-I1、R4-I2、R4-I4，Opus I4-1–I4-5）。

#### 2.5.1 紀錄

| 紀錄 | 內容 | 可變性 |
|---|---|---|
| 付款意圖 | 類型（`payment`、`rescue`、`clearing`）、帳戶、網路、資產、原始收款輸出（BTC 的 script 與金額；EVM 的 `to` 或 ERC-20 calldata 內的收款人與金額；`rescue`／`clearing` 沒有外部收款）、建立時間、使用者標籤 | 建立後不可變 |
| 成員 | 所屬意圖、角色、實際輸出、手續費、BTC 實際輸入集合或 EVM nonce、找零 index、已簽 bytes（取得後）、傳送觀察（`exported` → `signed` → `broadcasting` → `accepted` → `pending`／`unknown`）、是否曾由本 Wallet 送出 | 角色、輸出、輸入、nonce、找零 index 不可變；傳送觀察與已簽 bytes 只增不減 |
| 證據 | 種類（自有成員上鏈、經驗證的族外交易 T、nonce 被用掉、receipt 狀態、重組撤銷、來源錯誤撤銷、使用者覆寫）、txid／雜湊、區塊雜湊與高度、量測時來源自己的結算層級高度、來源主機與其營運者、是否有第二來源一致、是否已被撤銷 | 只能新增；撤銷以新增「撤銷證據」表示，撤銷的對象是事實，涵蓋同一事實的所有證據（2.5.4.3） |
| 存疑紀錄 | outpoint、來源（使用者標記、取代時以存疑理由捨棄、第二主機核對其存在失敗）、時間、理由；以及「解除存疑」紀錄，**引用它解除的存疑紀錄 id**（第二主機之後回報存在，或使用者確認） | 只能新增；隨備份保存，合併時取聯集【D-48】；解除只讓被引用的紀錄失效，並行或之後新增的存疑紀錄繼續有效，與時鐘和順序無關（審查意見 GPT R5-I3、Opus m5-4） |
| 調解確認 | 確認當時受影響的資源與成員集合、時間 | 只能新增；隨備份保存 |
| 衝突集合 | 依 PM-2 建立、彼此兩兩衝突、至多一筆能上鏈的成員。`payment` 集合可以包含不同 `payment` 意圖的成員；每個 `rescue`、`clearing` 意圖各自成一個集合，只含同一意圖的成員 | 只能新增成員 |

**資源**只有兩種：BTC 的 outpoint 與 EVM 的 `(帳戶, 網路, nonce)`。找零與收款 index 不是資源：依第 6.4 節單調配置，一經匯出或顯示就不再配置給別的請求（審查意見 Opus m4-3）。「族外交易」指不屬於某衝突集合任何成員的交易。

**由證據推導的狀態**：推導結果是（成員、未撤銷的證據、存疑紀錄、調解確認）的純函數，與事件到達的順序無關。每次這些紀錄改變時，在 PM-1 的同一把 `(帳戶, 網路)` 鎖內全量重算，並與觸發它的紀錄一起以單一提交寫入（整份檔案寫到暫存檔再改名）；選幣讀取推導狀態與寫入新成員也在同一把鎖內完成（審查意見 Opus m4-2、Codex R4）。
- **成員有效性**：成員的任一輸入（或 nonce）被「不是它自己」的交易消耗、且該證據未被撤銷，成員即失效；否則仍「可能上鏈」。
- **資源狀態**：有未撤銷的消耗證據 → `consumed(證據)`；否則，若 `refs(r)`（引用它、且仍可能上鏈的成員）非空 → `reserved(refs)`；否則 → `free`。同一資源可以被不同衝突集合的成員同時引用。
- **存疑**：某個 outpoint 至少有一筆未被任何解除紀錄引用的存疑紀錄時為存疑。存疑輸入不會被自動選用；存疑不改變上述狀態，也不代表它已被證明不存在。
- **意圖結果**：`payment` 意圖為 `open`、`paid(成員)`、`cancelled(成員)`、`failed(成員)`、`unresolved(證據)`、`abandoned`（2.5.6）；`rescue`、`clearing` 意圖為 `open`、`done(成員)`、`unresolved(證據)`。主網上它們都受 2.5.4 的單一來源規則限制。`rescue`、`clearing` 意圖沒有外部收款人，不觸發 2.5.5 的全頁確認；`clearing` 的結果不影響第 2.6 節的旗標。

**成員角色**（建立時決定，不可變；角色必須與意圖類型相容【D-46】）：

| 意圖類型 | 允許的角色 |
|---|---|
| `payment` | `pay`：付給該意圖的收款人。同一意圖可有多個 `pay` 成員：第一個是原始付款，之後的是「變更收款資訊」，只能經明確流程建立，並同時顯示新舊收款資訊。<br>`bump`：外部收款輸出（script 與金額）與某個 `pay` 成員相同，只提高手續費；已驗證的自有找零可以減少，低於 dust 時依第 6.7 節移除（審查意見 GPT 第三輪 I2、Codex R3 Minor 1）。<br>`cancel`：只付給本帳戶自有地址，且加入要取消的衝突集合；EVM 的 `cancel` 是 0 金額、付給同一個 Vault 種子在配對時匯出的另一個 EVM 帳戶，見第 4.6 節 |
| `rescue` | `rescue`：所有輸出都付給本帳戶新的自有地址。第一個成員花用使用者選定的輸入；之後的成員是同一救援的取代，依 PM-2 花用該集合所有成員共同擁有的至少一個輸入，輸出仍全部自有（2.5.6，審查意見 Opus m5-7） |
| `clearing` | `clearing`：所有輸出都付給本帳戶新的自有地址，只花用建立時未被任何成員引用的 UTXO（EVM 為 0 金額、付給另一個 EVM 帳戶）；之後的成員是同一清除的取代，規則同 `rescue`（第 2.6 節第 4 點） |

Vault 只能核對結構：`cancel`、`rescue`、`clearing` 的所有輸出都通過自有派生驗證（BTC 以 `KEEP-11` 重新派生；EVM 由 Vault 派生配對匯出的帳戶並標示「收款人是本 Vault 的帳戶 #n」，第 4.6 節）。`draft`（請求尚未顯示為 QR）不是成員，可以直接刪除。「封存」只是 UI 旗標，不改變任何紀錄。

#### 2.5.2 不變量

| # | 規則 |
|---|---|
| PM-1 | **建立**：成員與其資源引用在請求 QR 第一次顯示前原子寫入（沿用「先寫入、成功後才顯示」）；寫入失敗則不顯示 QR。同一 `(帳戶, 網路)` 在 Wallet 程序內以單一鎖序列化，兩個畫面不能同時建立；2.5.1 的重算也在這把鎖內。 |
| PM-2 | **衝突**：新成員加入衝突集合 S 時，角色必須與 S 的意圖類型相容（2.5.1），且必須與 S 的**每個**成員衝突。BTC：可以捨棄任何原輸入，只要仍花用至少一個「S 所有成員共同擁有」的輸入（預設花用原始成員的全部輸入）；可以另加未被引用、已確認的輸入。EVM：使用 S 的 nonce。依歸納，S 內任兩個成員都衝突，所以至多一筆能上鏈。每個成員的**實際**輸入都記錄下來。S 的共同輸入全部存疑時，不得再加入新的輸入（加入的真實輸入會被綁住），只能以 `rescue` 取回（審查意見 Opus m3-2）。 |
| PM-3 | **取代的費用**：只與「會被新成員取代、曾由本 Wallet 送出、且仍可能上鏈」的成員比較，已失效的歷史成員不計（審查意見 GPT 第三輪 I1、Codex R3 Minor 2）。**BTC**：新成員的費率必須高於每一個這種成員；手續費必須高於「這些成員所在的每個集合各取最高手續費、再相加」，另加節點要求的增量轉發費（審查意見 GPT R4-I4）。這是 FCW 的保守預檢；節點實際的取代規則（Core 31 起為 cluster mempool，facts §6.4）依 Core 原文核對（UNVERIFIED），節點仍可能拒收。被取代的成員彼此已經衝突（共用輸入、不可能同時在 mempool）時，只取其中最高者，不重複相加；部分重疊時維持各集合相加的保守算法（審查意見 Argon M5-01、Opus m6-10）。**EVM**：新成員的每 gas 價格欄位（type-2 的 `maxFeePerGas` 與 `maxPriorityFeePerGas`，legacy 的 `gasPrice`）都必須依客戶端的最低提高比例高於這些成員（比例依各客戶端原文核對，facts 沒有此值）；總費用另依目標鏈估價，並受 Vault 的 `max_signed_fee_wei` 限制。若沒有這種成員（全部從未送出），新成員不需要提高費用，Wallet 提示「若原交易已由其他裝置送出，這筆可能被節點拒收」。**`rescue` 的例外**【D-45】：使用者可以明確選擇低於上述要求的費用（2.5.6）。 |
| PM-4 | **新支出只有四種**（S 為同一帳戶、同一網路上任一未結算的衝突集合）：(a) 加入一個未結算的集合 S：S 是 `payment` 集合時，允許 `bump`、變更收款資訊、`cancel`，或「用 A 的資源付這筆新款」（新 `payment` 意圖的 `pay` 成員加入 A 的集合）；S 是 `rescue`／`clearing` 集合時，只接受同一意圖、全自有輸出的取代，**任何外部付款都不得加入**（審查意見 Codex R4-B1、Opus I4-2、GPT R4-I2）；(b) 另一筆獨立付款：只能經 2.5.5 的確認（依觸發條件為全頁或一行），BTC 不得使用任何 `reserved` 或存疑輸入，EVM 的 nonce 依 2.5.3；用已結算救援的輸出再付款也屬於此類；(c) 新的 `rescue`（2.5.6）或 `clearing`（第 2.6 節第 4 點）；(d) 沒有未結算的集合時，正常建立。 |
| PM-5 | **否定或模糊的回應不會新增消耗證據，也不會釋放任何保留**（它們只觸發查詢；在重組觀察期內，已結算成員的交易消失可以新增撤銷證據，這只會讓成員復活、增加保留）：404／`notFoundHere`、`/tx/:txid/status` 的 `{"confirmed":false}`、`POST` 送出後收到的任何錯誤（含 `-22`、`-25`、`-27`；它們只觸發查詢）、mempool 中的衝突交易、欄位缺失、tip 不一致、只有單一來源的「執行失敗」。`POST` 已送出後的任何錯誤一律進入 `unknown`；只有送出之前的失敗（網路核對失敗、`canDispatch` 被撤銷、Core 回 401／403）才回到原狀態。現行程式：Core 的 RPC 錯誤物件**未設** `uncertain`，只保存 code 與 `rpcMessage`（`apps/wallet/lib/services/bitcoin_rpc_client.dart:82-87`），401／403 標為 `notSent`（`:75-79`），連線或解析失敗才標為 `uncertain`（`:95-97`）；「送出後的錯誤進入 `unknown`」實際由畫面完成（`apps/wallet/lib/screens/bitcoin_send_screen.dart:436-457`）。 |
| PM-6 | **需要調解**（審查意見 Codex R3-I4、R4-I2，GPT 第三輪 B2、R4-B3，Opus m3-10、I4-5）。兩種觸發：(i) 重算後有成員從失效變回可能上鏈（例如結算它的證據被撤銷），或有資源被**不同衝突集合**中、都仍可能上鏈的成員同時引用（`rescue`、`clearing` 集合的成員沒有外部輸出，它們與其他集合共用輸入不算，審查意見 Opus m5-7）；(ii) EVM nonce 證據有爭議（2.5.3）。**期間停止的動作**：PM-4(b)、(d)、(c) 的 `clearing`，以及會用到受影響資源的「用 A 的資源付這筆新款」。**期間仍允許**：`cancel`、`bump`、變更收款資訊、`rescue`、查詢與重送同一份 bytes。**結束**：(i) 使用者看過列出受影響資源與成員的畫面並確認；確認綁定當時受影響的（資源、成員）集合並存為調解確認，之後只有這個集合改變時才重新進入；確認後，被多重引用的資源仍是 `reserved`，不參與選幣。(ii) 依 2.5.4.3 的核對結束，或該來源之後回報的 nonce 達到 `L_local`。畫面如實寫出「B 已顯示 QR，可能已簽（若 Wallet 已取回並驗證其簽章，則寫已簽），簽章無法收回；A′ 與 B 至多一筆能上鏈，A 仍可能另外上鏈」這類事實；不合併兩個集合，因為它們的其他成員並不互相衝突。 |

#### 2.5.3 EVM nonce（`MN-13`）【D-29，第六版修訂】

- 令 `L_rpc = eth_getTransactionCount(地址, "latest")`，`L_local` = 本機未撤銷的消耗證據（含 Q-24 的使用者覆寫與 2.7 的手動結算）的最高 nonce + 1（沒有時為 0）。起點 `n = max(L_rpc, L_local)`。**絕不自動採用較低的 RPC 值**（審查意見 Opus m3-7、Argon M3-03）。
- **較低的觀察**【D-47，第六版修訂】（審查意見 Codex R4-I2、R5-B1，GPT R4-B3、R5-I1）：若 `L_rpc < L_local`，**絕不自動降低**。Wallet 以同一來源的結算層級（主網 `finalized`，測試網 `latest`）量測 nonce 與高度：先取該區塊的高度與雜湊，再以區塊雜湊查詢 nonce（EIP-1898 的 block-hash 參數，facts 未涵蓋，UNVERIFIED），最後重核雜湊，避免負載平衡的 RPC 把不同節點的高度與 nonce 混在一起（審查意見 Opus m6-5）。結果**只作診斷**：
  - 該來源的高度 < 證據記錄的高度 H：畫面寫「此 RPC 回報的 nonce 較低；可能只是落後，也可能原證據（包括它的高度）是偽造的」，以 `L_local` 為起點繼續，並在建立前的確認頁顯示 nonce 差異與「質疑這筆證據」的入口（2.5.4.3）。
  - 該來源的高度 ≥ H：兩個來源的回報互相矛盾，帳戶自動進入 PM-6(ii)「nonce 證據有爭議」，停止新付款與新 nonce，畫面列出有爭議的消耗證據與較低的觀察，並提供同一入口。
  - H 是來源自報的值，FCW 不驗證；高度只決定「是否自動停止」，**不決定使用者能否質疑**。任何消耗證據都可以隨時經 2.5.4.3 質疑，核對不需要任何來源追上 H。
  - 已簽出的較高 nonce 成員一律保留，標為「等待 nonce n」，不刪除；未被質疑、或核對後仍成立的真實消耗證據一律保留。
- **`latest` 異常跳升**（審查意見 GPT 第三輪 I3、Opus I4-1；`Q-24`）：若 `L_rpc > L_local`，而 `[L_local, L_rpc)` 之間的 nonce 不全是本機已送出的成員，Wallet 停止建立，要求使用者在與 RPC 不同營運者的 explorer 核對帳戶目前的 nonce。畫面只有兩個出口，不提供任意輸入：
  - (a)「explorer 顯示的 nonce 等於 `L_rpc`（例如我曾用其他工具送出交易）」：只對 `[L_local, L_rpc)` 中**沒有本機已送出成員**的 nonce 新增使用者覆寫證據「被本機已送出成員以外的交易用掉」；範圍內本機已送出的成員不受影響，依自己的 receipt 結算。只有 `exported`／`signed` 成員的 nonce 也記這筆覆寫，但之後查到本機 `signed` 成員雜湊的 receipt、且達到第 2.7 節的結算層級時（`exported` 成員還沒有雜湊），以 receipt 為準並自動撤銷該 nonce 的覆寫（審查意見 Opus I5-3、m6-3）。核對所用的 explorer 必須與 RPC 是已知且不同的營運者。覆寫保存 `L_rpc`、該 RPC 當時的 `latest` 高度（作為 H）、查詢主機、explorer 營運者與時間；它的事實鍵是（帳戶、nonce、覆寫 id），撤銷它不會壓掉之後獨立量測到的同一 nonce；它計入 `L_local`，之後的跳升從這個值起算，同一段跳升不再提示。此事件依第 2.6 節第 1 點設定「歷史可能不完整」：同一個畫面另附 `Q-20` 的完整確認文字與獨立的勾選和長按，使用者可以不勾；不勾時覆寫照樣記錄、旗標保留，之後每一筆新付款仍顯示第 2.6 節的說明（審查意見 Opus m7-2、Codex R7 Minor 2）。這筆覆寫之後若被證明有誤，依 2.5.4.3 質疑與更正。
  - (b)「兩者不一致」：不建立，引導使用者更換 RPC 或加入第二個 RPC。
- 從 `n` 開始：只要 nonce `n` 上有衝突集合，且其中至少一個成員已取得已簽 bytes 並由本 Wallet 送出過，就 `n = n + 1`；第一個不符合的 `n` 稱為「下一個可用 nonce」。
- 若 nonce `n` 上有衝突集合，但其成員都沒有已簽 bytes 或都從未送出，**不得**在 `n + 1` 建立獨立付款（會排在從未簽署的 nonce 後面）。選項為：以 PM-4(a) 加入 nonce `n` 的集合（畫面說明「原請求將被取代」）；或若 Wallet 持有已簽 bytes，「先送出 A」（審查意見 Opus m3-12）。nonce `n` 是 `clearing` 集合時，付款不能加入它，選項為「送出清除」或「以新的清除取代」（審查意見 Opus m5-3）。
- nonce 大於 `n` 的集合標為「等待 nonce n」，不參與計算；當下一個可用 nonce 進入其前 10 個以內時，提示「已簽的 nonce N 交易即將可以上鏈；若不想讓它生效，請在可用時以相同 nonce 的 `cancel` 取代」。
- RPC 的 `pending` nonce 只作提示；大於 `n` 時顯示「RPC 回報有 FCW 不知道的待處理交易」，使用者可以等待，或在明確選擇後改用 `pending`；**絕不自動採用**。小於 `n` 時忽略。
- **轉帳頁的 nonce 欄位**（Phase 1a 起）：現行以 `pending` 取值（`apps/wallet/lib/services/node_rpc_client.dart:93-94`；`apps/wallet/lib/screens/send_tx_screen.dart:243`、`:256`），並允許自由輸入（`:329-333`、`:674-675`），可以繞過本節（C-20）。改為唯讀顯示上述「下一個可用 nonce」；進階選項只能選「下一個可用 nonce」或「加入 nonce m 的集合」（等於 PM-4(a)）（審查意見 Opus R3-4）。
- **餘額預留**（審查意見 GPT 第三輪 I4、Opus m4-8）：建立新付款前，可用原生幣餘額 = `eth_getBalance(地址, "latest")` − Σ（每個尚未在 `latest` 上鏈的未結算衝突集合中，各成員 `value + gas_limit × maxFee`（OP／Base 另加估計的額外費用）的最大值）；已在 `latest` 上鏈的成員，其支出已反映在餘額中，不再扣除。代幣同理扣除各集合的最大代幣金額。不足時警告「加上未結算的付款後餘額不足；這筆付款可能卡在 nonce 佇列」並要求確認。這只是警告，不是餘額充足的保證。
- `bump` 與 `cancel` 使用該集合的 nonce。

#### 2.5.4 證據與推導結果

證據都必須達到第 2.7 節的結算層級。**單一來源規則**（主網）【D-41，第五版擴及所有意圖類型】：若結算證據只來自一個主機（沒有第二主機，或第二主機已被使用者關閉），`payment` 意圖的結果只能是 `paid` 或 `unresolved`；`rescue`、`clearing` 意圖只能是 `unresolved`，不會成為 `done`。會導致 `cancelled`、`failed` 或 `done` 的結果都改記為 `unresolved`，並標示「伺服器回報……，未經第二來源核對」；單一來源的 `paid` 也標示「伺服器回報已付款，未經第二來源核對」並附 explorer 連結（審查意見 Opus R3-1、m4-11，GPT R4-B2）。消耗證據照樣記錄（並標明是單一來源），所以資源仍是 `consumed`；有誤時以撤銷證據更正（BTC：第 2.7 節的區塊雜湊改變或交易消失；EVM：另有 2.5.3 的更正流程）。測試網不受此限。

| 事件 | 資源與成員 | 意圖結果 |
|---|---|---|
| `payment` 意圖的成員 M 結算為已上鏈（BTC：M 的 txid；EVM：M 的雜湊之 receipt，且同一層級量測的 nonce 大於 M 的 nonce——一致性檢查，否則不採信） | M 的輸入或 nonce 為 `consumed`；引用這些資源的其他成員失效；其餘資源依推導規則變為 `free` 或仍 `reserved` | M 為 `pay`／`bump`（EVM 另需 receipt `status = 1`）→ `paid(M)`。M 為 `cancel` → `cancelled(M)`（EVM 的 `cancel` 即使 receipt `status = 0` 也是如此：nonce 已用掉，取消已生效，審查意見 Opus m4-4）。其成員因 M 而全部失效的其他 `payment` 意圖 → `cancelled`。後兩者在主網受單一來源規則限制 |
| EVM：`pay`／`bump` 成員 M 的 receipt `status = 0` | 同上（nonce 已用掉） | 第二來源的 `status` 一致或使用者核對後才記為 `failed(M)`；否則 `unresolved`，標示「伺服器回報執行失敗，未經第二來源核對」。一致性檢查同上 |
| BTC：保留輸入 u 被族外交易 T 花掉，且 T 通過 2.5.4.1 的本地驗證 | u 為 `consumed`；花用 u 的成員失效 | 衝突集合的成員全部失效時，各意圖 → `unresolved`，畫面列出 T 的輸出：T 付給某意圖的收款 script 且金額不少於該意圖時，提示「可能是此付款在其他裝置或較舊備份之外建立的版本，付款可能已完成」；否則提示「付款看起來未經此衝突集合完成」。**不自動判定為未付款** |
| EVM：以結算層級量測的 nonce（主網 `eth_getTransactionCount(地址, "finalized")`；測試網 `"latest"` 且再前進 1 個區塊）大於 S 的 nonce，且仍查不到任何成員的 receipt | nonce 為 `consumed`（證據記錄量測時的高度與區塊雜湊；量測方式同 2.5.3：先取 `finalized` 區塊，再以它的雜湊查詢 nonce，審查意見 Opus m7-6）；S 的成員全部失效 | 各意圖 → `unresolved`（族外交易可能是使用者從其他工具送出的同一筆付款） |
| `rescue` 或 `clearing` 意圖的成員 R 結算 | R 的輸入或 nonce 為 `consumed`；引用這些資源的成員失效 | R 的意圖 → `done(R)`（主網單一來源時為 `unresolved`）。其他 `payment` 意圖不直接改變；只有某意圖的成員因此全部失效時，該意圖 → `unresolved`（提示「資源救援使所有成員失效；付款看起來未發生」），**不記為 `cancelled`** |
| 重組或來源錯誤撤銷：先前用於結算的區塊雜湊改變、交易消失，或 2.5.3 的更正 | 新增撤銷證據；依撤銷後的證據重新推導；可能觸發 PM-6 | 依重新推導的結果；先前的 `paid`／`cancelled`／`done` 改回 `open` 或 `unresolved`，並通知 |
| 結果覆寫（2.5.4.2） | 不新增也不改變任何資源證據 | 依使用者的選擇，標示「使用者覆寫」 |
| 新增證據的覆寫（2.5.3 的出口 (a)、2.7 的手動結算） | 新增消耗證據並計入 `L_local`；核對所用的 explorer 必須與證據來源是已知且不同的營運者（審查意見 Opus m6-2） | 依推導規則 |
| T 的簽章無效、bytes 缺漏、txid 不符、T 並未花用 u、sighash 不是 `SIGHASH_ALL` | 不變 | 不變（記錄為可疑回應） |

T 的簽章驗證使 T 必須由本帳戶的金鑰簽出（本 Vault，或使用者以同一組種子在其他工具簽出），伺服器無法偽造。**仍依賴後端信任的部分**：T 與 M 是否真的在主鏈上、深度多少、是否發生重組；FCW 不驗證區塊標頭（第 2.7 節）。

##### 2.5.4.1 族外交易 T 的驗證規格【D-42】

1. 只接受被花用的保留輸入 u 是 segwit v0 P2WPKH；否則記為可疑（未來的 BIP-86 帳戶另依 BIP-341 定義）。T 的其他輸入與輸出是什麼類型不影響本驗證。
2. u 的金額與 scriptPubKey 一律取自本機保存、已依 `KEEP-13` 核對過 txid 的前置交易的 `(txid, vout)`；不採信後端另報的金額。
3. 在 T 中找出實際引用 u 的輸入索引；以該索引計算 sighash。
4. scriptCode 依 BIP-143 的 P2WPKH 規則由 u 的 20-byte program 建立（P2PKH 形式；實作時以 BIP-143 原文核對，facts 未涵蓋），不能直接用 witness program 當 scriptCode。
5. **只接受 `SIGHASH_ALL`**：其他 sighash 類型一律記為可疑、不改變任何紀錄（審查意見 Codex R3-I2、Opus R3-3 的建議）。代價：使用者在其他工具以非 ALL 簽出、且已上鏈的 T，FCW 不承認；同一集合其他成員引用的輸入會保持 `reserved`，可用 `rescue` 取回（2.5.6）。現有 `compute_bip143_sighash` 只支援 ALL（`crates/public_core/src/bitcoin.rs:906-914`），與此一致；Vault 簽署端仍只允許 ALL（`KEEP-10`）。
6. witness 必須恰好兩個元素；pubkey 為 33 bytes 壓縮格式，`hash160(pubkey)` 等於 u 的 program；簽章為嚴格 DER（BIP-66），驗證前先做 low-S 正規化（segwit v0 共識允許 high-S，`libsecp256k1` 的驗證會拒絕它）；ECDSA 驗證必須成功。
7. 需要新的有界解析器：現有 `Transaction::deserialize` 讀過 witness 後直接丟棄（`crates/public_core/src/bitcoin.rs:431-448`）。新解析器保留每個輸入的 witness，拒絕尾端多餘 bytes、重複 outpoint、錯誤的 stack／DER／公鑰編碼；txid 仍以不含 witness 的序列化計算並核對。
8. 本地驗簽只證明 T 對 u 的簽章有效，不證明 T 的其他輸入有效或 T 已上主鏈。

##### 2.5.4.2 使用者覆寫與 explorer 的獨立性

`unresolved` 的處理：使用者先核對**具體的鏈上事實**，再由事實決定可選的結果（審查意見 Opus R3-1、I6-1）。`payment` 意圖的結果是「標為已付款」或「標為未付款」，`rescue`／`clearing` 為「標為已完成」或「標為未完成」：
- EVM（nonce N）：(i) nonce N 被本機某個成員的雜湊用掉（explorer 顯示已上鏈）→ 以第 2.7 節的手動結算記錄該成員的上鏈與執行結果；(ii) nonce N 被另一筆**已上鏈**的交易用掉（explorer 顯示已確認，不是 pending）→ 使用者貼上該交易的雜湊，FCW 核對 `from` 等於本帳戶、nonce 等於 N、且不是本機任何成員的雜湊（是的話改走 (i)），核對不到時標示「未經驗證」，之後才能選結果；(iii) nonce N 尚未被用掉，或 explorer 只顯示 pending 的交易 → **不提供結果覆寫**，只提供 2.5.4.3 的「質疑這筆證據」，畫面寫明「原交易仍可能上鏈」（審查意見 Opus m7-4）。
- BTC：explorer 顯示 T（或成員）已確認，且確認數不少於第 2.7 節所需的深度 → 可以選結果；只在 mempool 中或不在鏈上 → 只提供 2.5.4.3 的質疑。
- 只有 2.5.4 第 3 列「T 付給原收款人」的提示，才另外詢問「收款人是否已收到」。

**explorer 與第二來源必須是不同營運者**【D-51，第六版修訂】（審查意見 Opus I4-4、I5-4，Codex R5 Minor 4，GPT R5 Minor）：網路表的每個 explorer 與內建端點都帶營運者標籤；使用者新增自訂端點時須填營運者，未填即為「未知」。只有 explorer（或第二來源）與產生證據的主機、以及提出較低觀察的主機都屬於**已知且不同**的營運者時，才算獨立核對，也才算第 2.7 節的「第二來源一致」。同一或未知營運者的連結仍可供瀏覽，畫面寫明「這不是獨立核對」：它可以用於本節的結果覆寫（使用者自負），但不能完成 2.5.4.3 的撤銷或確認。畫面區分「兩個端點一致」與「不同營運者核對」。EVM 的 explorer 見第 4.1 節；BTC 的 explorer 見第 6.2 節。本節的規則同樣適用於 2.5.3 的核對與 2.7 的手動結算。

結果記錄（審查意見 Opus m4-10、Codex R5 Minor 3）：`payment` 意圖的「標為已付款」→ `paid(使用者覆寫)`；「標為未付款」→ 證據是 receipt `status = 0` 時為 `failed(M, 使用者覆寫)`，其餘為 `cancelled(使用者覆寫)`。`rescue`／`clearing` 意圖的「標為已完成」→ `done(使用者覆寫)`；「標為未完成」→ `open(使用者覆寫)`。結果覆寫不改變任何資源證據；要更正資源證據，使用 2.5.4.3。所有覆寫都保存當時的證據快照（查詢過的主機、explorer 營運者、nonce、receipt、T 的 bytes）。

##### 2.5.4.3 質疑證據與更正【D-47，第六版修訂】

適用於任何消耗證據（BTC 的自有成員上鏈與族外交易 T；EVM 的 receipt 與「nonce 被用掉」），也適用於 2.5.3 出口 (a) 的使用者覆寫與 2.7 的手動結算（審查意見 Codex R4-I2、R5-B1，GPT R4-B3、R5-I1，Opus I5-4）。
1. **入口**：使用者隨時可以在證據畫面選「質疑這筆證據」；2.5.3 的較低觀察會在畫面上提示同一入口。入口**不檢查任何高度條件**：來源自報的高度 H 可以偽造，只用於 2.5.3 的自動診斷。
2. **核對**（`Q-26`）：(a) 第二來源以它自己目前的結算層級，對同一事實（txid 或雜湊與其區塊；或帳戶在某高度的 nonce）給出結果；或 (b) 使用者在 explorer 核對具體事實（BTC：該 txid 是否在鏈上、確認數；EVM：nonce N 是否被用掉、被哪一筆交易用掉）。第二來源與 explorer 都必須與**原證據的來源**以及**提出較低觀察的來源**屬於已知且不同的營運者（2.5.4.2）。核對使用這些來源目前可查的高度，**不需要任何來源追上 H**。第二來源的結果依它自己的高度解讀（審查意見 Codex I7-1、GPT R7-I1、Opus m7-5）：(1) 它的結算層級高度 ≥ H → 它對同一事實的結果可以作為撤銷（矛盾時）或確認（一致時）的依據；(2) 它的結算層級高度 < H ≤ 它的 `latest` → 還沒結算到，不算核對結果；(3) H > 它的 `latest` → 不證明 H 是偽造的（它可能只是落後），也不算核對結果。(2)、(3) 仍可以改用 (b) 的 explorer 核對具體事實；這種核對不受 H 限制，是 `Q-26` 的信任選擇。
3. **紀錄**：核對結果記為綁定具體證據的事件，隨備份保存：
   - 「撤銷」：撤銷的是**事實**——BTC 為（txid、區塊雜湊、高度）；EVM 的 receipt 分成兩個事實：上鏈（雜湊、區塊雜湊、高度）與執行結果（雜湊、區塊雜湊、`status`），撤銷錯誤的 `status` 只撤銷後者，撤銷上鏈事實時同一（雜湊、區塊雜湊）的執行結果一併失效（審查意見 GPT R6-I1、Opus m7-9）；EVM 的「nonce 被用掉」為（帳戶、nonce、來源回報的高度與區塊雜湊），2.5.3 出口 (a) 的覆寫為（帳戶、nonce、覆寫 id）——涵蓋所有記錄同一事實的證據。所以重啟，或匯入一份帶有同一事實、但 id 不同的舊證據，都不會讓它復活（審查意見 Opus m5-5）。產生被撤銷證據的來源標為「回報與核對結果不符」。
   - 「確認」：原證據成立。適用於任何質疑；爭議來自較低的觀察時，綁定（提出較低觀察的來源、有爭議的證據、較低的觀察值）並持久化，該來源標為「回報與核對結果不符」（審查意見 Opus I6-4）。
   - 標記針對主機（端點的 scheme、host 與 port）：被標記的主機不再自動觸發爭議，它的回報不再單獨構成任何新的消耗證據，也不算第 2.7 節的「第二來源一致」；同一營運者的其他端點不繼承標記，但畫面顯示「此營運者的另一個端點曾被標記」。使用者可以明確解除標記：解除紀錄引用造成標記的事件 id，之後新增的標記不受舊的解除影響（比照 D-48）。畫面建議更換被標記的主機（審查意見 Opus m6-4、m7-7）。
   - **撤銷也可以更正**（審查意見 GPT R6-I1、R7-I2，Opus I6-4、m7-8）：撤銷事件同樣可以被質疑，核對要求與撤銷時相同：第二來源或 explorer 都必須與撤銷所依據的來源、以及原證據來源屬於已知且不同的營運者。核對後新增綁定該撤銷事件 id 的「恢復」事件。**恢復只解除它引用的那一次撤銷**：同一事實若還有其他有效的撤銷（例如之後真的發生重組），事實仍不生效。因這次撤銷而加的來源標記一併移除；撤銷所依據的第二來源標為「回報與核對結果不符」。恢復事件本身也可以再被質疑，規則相同。所有事件只增不減，推導結果與匯入順序無關。
4. **重算**：事件寫入後，在 PM-1 的鎖內原子重算 `L_local`、引用與成員有效性；因撤銷而復活的成員依 PM-6(i) 處理；PM-6(ii) 的爭議結束。
5. 未核對前，既有證據保持有效，`L_local` 不下降；已簽出的較高 nonce 成員與核對後仍成立的真實消耗證據一律保留。
6. 同一事實之外的新證據（例如重組之後交易真的在另一個區塊上鏈）照常記錄並重算。
7. **誤撤銷的後果**：2.5.3 的「下一個可用 nonce」迴圈只依本機已簽、曾送出的成員計算，與證據無關，所以誤撤銷不會讓 FCW 重用自己送出過的 nonce；最壞是在已用掉的 nonce 上白簽一筆（鏈會拒絕）、或把 `paid` 翻回 `open`，使全頁確認重新出現（審查意見 Opus 第五輪 2.2）。

#### 2.5.5 確認頁與警告

- **全頁確認的觸發條件**：該帳戶、該網路上有 `payment` 意圖的成員處於 `exported`、`signed`、`broadcasting`、`accepted`、0 確認的 `pending` 或 `unknown`；或有 `payment` 意圖為 `unresolved`；或有 `payment` 意圖的成員有 `status = 0` 的 receipt、或已上鏈但尚未結算的 `cancel` 成員；或有 `pay`／`bump` 成員只有上鏈事實、沒有未撤銷的執行結果事實（結果未知，取得新的執行結果之前不記為 `paid`，審查意見 Opus m7-9）；或帳戶處於「需要調解」（PM-6）或「歷史可能不完整」（2.6）（審查意見 Opus m4-9）。
- **一行說明**只用於兩種尚未結算的成員：有成功 receipt（EVM `status = 1`）的 `pay`／`bump`，以及已確認的 BTC `pay`／`bump`（審查意見 Opus R3-1）。
- 全頁列出所有觸發的意圖（金額、收款人、時間、狀態）。預設按鈕是「取代」或「變更收款資訊」；選「另一筆新的付款」必須勾選「這不是重試」並長按確認。帳戶處於「需要調解」時，調解確認之前不提供「另一筆新的付款」（審查意見 Opus m5-2）。
- 只因「歷史可能不完整」而觸發時，顯示第 2.6 節第 3 點的說明頁：頁內直接提供 `Q-20` 的確認，以及「只繼續這一筆」的按鈕。「這不是重試」的勾選只用於列出觸發意圖的頁面，避免使用者養成反射性勾選（審查意見 Opus m7-3）。
- **醒目警告**：新付款與任何 `open`、`unresolved`、`abandoned` 的 `payment` 意圖，或最近 30 天內單一來源的 `paid` 意圖、或以使用者覆寫記為 `cancelled` 的意圖（審查意見 Opus I6-1），同一資產且金額相同（容許兩者手續費的差額），**或**收款人相同，任一成立即警告（審查意見 Opus m4-11）。
- EVM 適用時另寫：「這筆付款要等 nonce n 之前的交易上鏈後才會執行」。
- 實作不得把一般的「重試」按鈕預設對應到「另一筆新的付款」。

#### 2.5.6 卡死、取消空間、資源救援與放棄

- QR 顯示後在 Vault 拒簽、或已簽但從未送出的集合，可依 PM-3 以不提高費用的新成員取代，不會因費用上限卡死。
- 已送出、且費用已接近 Vault 上限的集合：見第 6.6 節「取消空間」與 `Q-18`；**不提供逾時自動解鎖，也不靜默提高上限**。
- **資源救援**（`rescue`，BTC）【D-38，第五版修訂】：原本的用途是取回只因為與存疑或無法上鏈的輸入綁在同一集合而無法取回的真實輸入 Y（審查意見 Codex R3-B1、GPT 第三輪 B1 的反例：A={X_f} → A′={X_f, Y}，所有合法取代都必須含 X_f）；Wallet 不強制這個前提，`rescue` 也可以當成只花部分輸入的自轉帳使用，結果相同（`Q-23`，審查意見 Opus m4-15）。使用者可以建立 `rescue` 成員 R：
  - R 只花用使用者選定的輸入（例如只有 Y），所有輸出都付到本帳戶新的自有地址；Vault 能核對「所有輸出都是自有」，並如實顯示「這是自轉帳」。
  - R 的意圖另成一個集合，不加入它救援的集合；它只與實際引用其輸入的成員衝突（例子中只有 A′）。這個集合之後只接受同一救援的取代（PM-4(a)），任何外部付款都不能加入（審查意見 Codex R4-B1、Opus I4-2）。
  - **費用**：預設依 PM-3 計算（R 同時取代多個集合的成員時，手續費取各集合最高者的總和）。若做不到（例如 A′ 已以 30,000 sat 送出、而 Y 只有 10,000 sat，審查意見 GPT R4-B1），使用者可以明確選擇較低的費用【D-45】。畫面寫明：「這筆救援與已送出的 A′ 競爭：若 A′ 實際在節點的 mempool 中，這筆會被拒收；若 A′ 之後上鏈，這筆失效，原付款照常完成。」兩種結局都不構成第二筆付款，因為 R 沒有外部輸出。§6.6 的取消空間預檢對 `rescue` 同樣計算（審查意見 Opus m4-1）。
  - 建立前，畫面列出會因 R 而失效的成員，以及**仍可能上鏈**的成員（例子中 A={X_f}），並寫明「A 仍可能上鏈；此付款意圖維持未結算」。
  - R 結算後：Y 為 `consumed`，A′ 失效；A 仍可能上鏈，X_f 仍被 A 引用並維持存疑；原付款意圖維持 `open`，**絕不**記為 `cancelled`；R 的意圖為 `done(R)`（主網單一來源時為 `unresolved`）。R 的輸出是新的、未被引用的 UTXO；若 R 的結算其實是捏造的，花用這些輸出的交易只會無效，不構成損失。
  - **它為什麼不是重試**：R 沒有外部收款人，不能構成第二筆付款；它不改變任何意圖的結果（2.5.4 第 5 列）；所有仍可能上鏈的成員繼續保留其資源，並繼續觸發 2.5.5 的全頁確認。用 R 的輸出再付給原收款人，只能經 PM-4(b) 的明確宣告。
- **標為已放棄**（`Q-19`）：使用者可以把 `payment` 意圖標為 `abandoned`，畫面明寫「此付款仍可能上鏈；FCW 會繼續監看，並保留它的輸入或 nonce」。效果只有一個：它不再觸發全頁確認（醒目警告仍會比對它）。資源引用與監看都不變。
- 公開備份（第 2.6 節）匯出時列出已放棄但未取消的意圖，建議先以 `cancel` 處理。

### 2.6 歷史完整性：備份、遷移、還原與多台 Wallet（`MN-20`）

**保證範圍**：第 2.5 節的保留只對**這台 Wallet 確實擁有的歷史**成立。Vault 不保存付款歷史，無法保證跨安裝的付款唯一性。

1. **歷史可能不完整的事件**：從任何備份還原或匯入；只靠 Vault 重新配對或只有種子的恢復；**任何有既有付款歷史的帳戶從 v1 遷移到 v2**（現行 C-01、C-20 會把可能已簽的請求標成 `cancelled`）；遷移後回復（第 2.4 節）；重新安裝；鏈上出現本機紀錄解釋不了的花費（自有 UTXO 被一筆通過 2.5.4.1 驗證、但本機沒有對應成員的交易花掉，或 EVM nonce 被未知交易用掉，包括 2.5.3 出口 (a) 的確認）。發生時，帳戶標為「歷史可能不完整」。
2. **本機沒有成員的自有花費**：記為「偵測到本機沒有紀錄的已簽交易」，設定上述旗標，並列入旗標全頁說明中的清單：已確認的花費一次列出、不逐筆通知；還在 mempool 中的花費每筆通知一次，因為只有這段時間能以清除與它競爭（審查意見 Opus I6-2、m7-10）。它只能在使用者覆寫後記為某意圖的付款，不會自動變成 `paid`：只有它已確認時（確認數同 2.5.4.2）才能在旗標頁把它歸入意圖 I，I 記為 `paid(使用者覆寫, T)`；I 原有的成員仍可能上鏈，保留不變並繼續觸發全頁確認，使用者應另以 `cancel` 處理，或依 `Q-19` 標為已放棄（審查意見 Opus m7-11）。只有已匯入並經 `KEEP-14` 驗證的 `pay` 成員上鏈，才能自動推導為 `paid`（審查意見 Codex R3-I1）。BTC 的標準同步看不到還在 mempool 中的這類花費（`/utxo` 只會讓被花用的輸出消失）；已知的自有 UTXO 從 `/utxo` 消失、又沒有本機成員花用它時，Wallet 查一次該 outpoint 的 `outspend`；完整的發現要靠第 4 點、深度掃描時的交易歷史查詢。旗標頁寫明本次是否已查詢交易歷史（審查意見 Opus m7-10）。
3. **旗標只能由使用者明確解除**【D-34，第七版修訂】（審查意見 GPT R5-B1、R6-B1、R6-B2、R6-I2）：FCW 無法證明「沒有未見過的已簽支出」。曾廣播後被 mempool 淘汰、被取代或被重組掉的入金，以及 chain 與 mempool 分開讀取的時間差，都可能讓兩個誠實主機同樣看不到某筆入金與花用它的已簽交易。所以旗標存在時，該帳戶的每一筆新付款前都顯示全頁說明：「這台 Wallet 可能沒有你最近建立或簽署的付款紀錄；若你曾在其他裝置、其他工具或這份備份之後簽過付款，那些交易仍可能上鏈。」可以做的事：
   - 匯入其他裝置的最新公開備份並合併——降低風險，**不清除旗標**；
   - 以清除交易移動資金（下方第 4 點）——降低風險，**不清除旗標**；
   - **解除旗標的唯一方式**（`Q-20`）：勾選並長按確認「我了解：如果我曾在其他裝置、其他工具或這份備份之後簽過付款，那些交易仍可能上鏈，現在的付款可能造成重複付款；FCW 無法檢查這件事」。確認連同時間記錄並隨備份保存。
4. **清除交易**【D-43，第七版修訂】：屬於類型 `clearing` 的獨立意圖，角色為 `clearing`，自成一個集合、不加入任何既有集合（之後只接受同一清除的取代），只付給本帳戶新的自有地址，只花用建立時未被任何成員引用的輸出（已被引用的輸入由各自的集合處理）；受 64 個輸入、QR 預算與 `max_fee_sat` 限制時分成多筆。它是**資源與結算工具**：清除結算後，花用同一輸出的遺留交易失效；它**從不解除旗標**。清除與遺留交易是競爭：遺留交易若先上鏈，原付款仍會完成，並依第 2 點記錄。
   - **被未知交易花用的 BTC 輸出**【D-52，第七版簡化】：`/address/:addr/utxo` 會排除已在 mempool 中被花掉的鏈上輸出（facts §5.3，只見於原始碼，UNVERIFIED），所以深度掃描對有紀錄的地址另取交易歷史（`/address/:addr/txs/chain/:last_seen_txid` 分頁與 `/address/:addr/txs/mempool`，facts §5.4），再以 `outspend` 查自有輸出被誰花（格式 UNVERIFIED，第 6.1 節）。被本機沒有成員的交易花用、而那筆交易還在 mempool 的自有輸出，清除可以與它競爭，前提是那筆交易先通過 2.5.4.1 的驗證（由本帳戶的金鑰簽出）。清除只花它實際花用的自有輸入，必要時再加一個已確認的輸入補足費用；費用依 PM-3 高於它（它的前置交易依 `KEEP-13` 取得並核對；非自有輸入的前置交易可以被後端編造，所以它的手續費可能被灌高）；畫面並列兩者的費用，經使用者確認，並受 `max_fee_sat` 限制（審查意見 Opus m6-8、m7-12）。這些查詢只用於發現與競爭，不構成任何「已完整」的判定。
   - **EVM 清除**：每個 nonce 各自一個集合（0 金額、付給另一個 EVM 帳戶，第 4.6 節），只能清除使用者估計曾在其他裝置匯出的那幾個 nonce。
5. **v1 → v2 遷移的狀態對照**（審查意見 Codex R3-I1、R4-I3，Opus m4-7）。v1 的 EVM 狀態見 `apps/wallet/lib/services/transaction_history.dart:137-148` 的標籤表，BTC 狀態見 `apps/wallet/lib/screens/bitcoin_send_screen.dart:718-727`。已保存的已簽 bytes（EVM 的 `signedRaw`，由 `apps/wallet/lib/screens/scan_signature_screen.dart:287` 寫入，還原合併時以 `transaction_history.dart:57-65`、`:78-80` 的綁定欄位比對；BTC 紀錄中的已簽資料）一律帶入成員。

| 舊紀錄 | 新紀錄 | 曾由本 Wallet 送出 |
|---|---|---|
| BTC `draft`（`request` 為 null；`apps/wallet/lib/screens/bitcoin_send_screen.dart:39`、`:194`） | 不建立成員（審查意見 Opus m5-6） | — |
| BTC、EVM `awaitingSignature` | 成員 `exported`（可能已簽）；以保存的請求重建輸入或 nonce 的引用 | 否 |
| `verified` | 成員 `signed` | 否 |
| `broadcasting`、`accepted` | 成員 `unknown` | 是 |
| `pending` | 成員 `pending` | 是 |
| `confirmed` | 成員「已上鏈，待依第 2.7 節結算」 | 是 |
| EVM `executionFailed`（receipt `status = 0`，`transaction_history.dart:133`，由 `apps/wallet/lib/screens/scan_signature_screen.dart:356-370` 保存） | 成員 `unknown`，附「舊 receipt 回報執行失敗」觀察，待依第 2.7 節的結算層級與第二來源重新查詢；保留 nonce、請求與已簽資料；**不直接記為 `failed`** | 是 |
| EVM `unknown` | 成員 `unknown` | 是 |
| BTC `failed`（Core 路徑，實際接不到，C-02） | 成員 `unknown` | 是 |
| `cancelled`（含 C-01、C-20 產生者）與封存的 recovery 紀錄 | 成員 `exported`（可能已簽），重建引用；**絕不**視為已取消的付款結果 | 有送出紀錄時為是，否則否 |
| 其他任何無法識別的舊狀態 | 成員 `exported`（可能已簽），重建引用 | 有已簽 bytes 時為是，否則否 |
| 保存的資料不足以重建輸入或 nonce | 照樣建立意圖與成員紀錄 | 同上 |

   有任何既有付款歷史的帳戶遷移後一律設旗標，只能依第 3 點清除。
6. **匯入合併的規則**（審查意見 Codex R3-I1、R4-I1，GPT R4-I1，Opus m3-3、I4-3）：
   - 不可變欄位（意圖內容；成員的角色、輸出、輸入、nonce、找零 index）在同一 id 下不一致 → 拒絕整個檔案並說明。
   - 已簽 bytes：一方有、一方沒有時，經 `KEEP-14` 對原請求驗證後才採用；兩方不同 → 拒絕。
   - 成員、傳送觀察、證據（含撤銷證據與使用者覆寫）、存疑紀錄（含解除紀錄）與調解確認取聯集，之後依第 2.5.1 節**以同一公式全量重算**。不以狀態名稱比大小。未撤銷的消耗證據仍使匯入的成員失效；撤銷事件以事實涵蓋匯入的同一事實證據（2.5.4.3）；沒有消耗證據的資源會接受匯入成員的有效引用——例如補回仍未結算的 B={U2} 時，U2 從 `free` 變為 `reserved({B})`；構成多重引用時依 PM-6 處理。
   - 匯入較舊的備份絕不刪除本機已有的紀錄；**成功匯入不證明歷史完整**，也不清除旗標。
7. **備份內容**：所有意圖、成員（含已簽 bytes，`Q-16`）、證據（含撤銷證據與使用者覆寫）、存疑紀錄、調解確認，以及仍在重組觀察期內的已結算紀錄。
8. **Vault 的「最近已簽」提示**【D-36，第四版修訂】：現行公開簽署結果沒有時間欄位，且只保留 20 份完整結果（`apps/vault/lib/services/public_signed_result_store.dart:82`），無法支援提示。新增獨立的公開索引檔，每筆記錄 `signed_at`（Vault 時鐘，不可信，只供顯示）、網路、收款人、金額，以及 BTC 的輸入 outpoint 清單；依數量保留最近 500 筆（不依時間）。prepare 時，若索引中有同收款人或同金額的請求，或 BTC 輸入與先前結果重疊，顯示「此 Vault 曾在 <時間> 簽過……；若這不是取代，可能是重複付款」。索引建立之前的簽署結果沒有這些資料，提示寫明「較舊的簽署紀錄無法比對」。只提示、不阻擋（審查意見 Codex R3-I1、Opus m3-5）。這個檔案不加密，Vault 遺失時會洩漏最近 500 筆的收款人、金額與輸入；第 10.5 節揭露，Vault 提供「清除最近簽署索引」的動作（審查意見 Opus m4-12）。
9. **兩台 Wallet 使用同一帳戶**：不支援，在配對頁與說明中揭露；第 1、2 點的鏈上異常偵測（BTC 的標準同步看不到 mempool 中的未知花費，見第 2 點）與第 8 點的 Vault 提示是僅有的補強。

### 2.7 結算層級（逐鏈）與第二主機核對（`MN-12`）

第二版「EVM 一律 12 個區塊」已刪除。三個層級：

- **已上鏈**：BTC 為後端回報 `status.confirmed`；EVM 為成員雜湊有 receipt，且同一 RPC 的 `eth_getBlockByNumber(receipt.blockNumber)` 雜湊等於 `receipt.blockHash`。
- **安全**：EVM 為區塊號 ≤ `safe` 標籤的區塊（依審查者引用的 OP 文件，L2 上表示批次已提交到 L1，sequencer 確認不算；各鏈語意 UNVERIFIED，見下）。
- **最終**：EVM 為區塊號 ≤ `finalized` 標籤的區塊，且該高度的區塊雜湊仍等於 `receipt.blockHash`；BTC 為深度 ≥ K。

| 網路 | 結算所需層級（建議，`Q-13`） | 深度與標籤從哪裡算 | 區塊雜湊重核 | 重組觀察結束 |
|---|---|---|---|---|
| Bitcoin 主網 | 深度 ≥ 6 | 同一主機的 `GET /blocks/tip/height`；深度 = tip − 高度 + 1 | 每次輪詢比對 `status.block_hash`；改變或交易消失即新增撤銷證據（2.5.4） | 深度 ≥ 12 |
| Signet、Testnet4、Regtest | 深度 ≥ 1 | 同上 | 同上 | 深度 ≥ 2 |
| Ethereum 主網、Arbitrum One、OP Mainnet、Base、Polygon PoS | **最終**（`finalized`）；「nonce 被用掉」也以 `eth_getTransactionCount(地址, "finalized")` 量測（以該 `finalized` 區塊的雜湊查詢，2.5.3） | 同一 RPC 的 `eth_getBlockByNumber("finalized")` | 結算前與每次輪詢都以 `eth_getBlockByNumber(n)` 重核 | 達到最終即結束 |
| 各 EVM 測試網 | 已上鏈，且 `latest` 至少再前進 1 個區塊 | `latest` | 同上 | 達到最終或 1 小時後結束 |

- 各鏈 RPC 是否支援 `safe`／`finalized` 標籤（含 `eth_getTransactionCount` 的 `finalized` 參數）、以及 L2 上的確切語意，**不在 facts 內（UNVERIFIED）**；Phase 1a／1b 依各鏈官方文件核對。RPC 不支援所選標籤時**不自動結算**：成員顯示「已上鏈，尚未最終」，資源保持 `reserved`。使用者可以「手動結算」：它就是 2.5.4.2 的核對（在不同營運者的 explorer 核對該雜湊與區塊），依使用者的選擇記錄一次結果，不需要再覆寫一次；手動結算的消耗證據計入 `L_local`，其高度 H 為 receipt 的區塊高度；之後可以依 2.5.4.3 質疑（審查意見 Opus m3-6、m4-6、I4-1、I5-4）。不以固定區塊數代替最終性。
- **sequencer 信任是明確選擇**：持有人可以為某條 L2 選擇以「已上鏈」或「安全」結算（`Q-13`）；預設不採用。
- EVM 在結算之前，獨立付款仍可依 2.5.3 使用下一個 nonce，所以等待最終只會延後「同一 nonce 的重付」。
- **第二主機核對**（`Q-14`，主網）：
  1. 主要主機達到所需層級後，向第二主機查詢同一物件。BTC：同一 txid 的狀態、區塊雜湊與第二主機自己的 tip（T 的 bytes 與簽章已在本地驗證）。EVM：同一雜湊的 receipt（**含 `status`**）、該高度的區塊、第二主機自己的 `finalized`；沒有 receipt 時，第二主機以 `finalized` 量測的 nonce。
  2. 只有第二主機回報**相同的區塊雜湊、高度與 `status`**，且第二主機自己的 head 也滿足所需層級，才算「第二來源一致」；第二主機必須與主要主機屬於已知且不同的營運者（2.5.4.2）。
  3. 第二主機 404、逾時、落後、內容不同、欄位缺失，都**不算一致**：維持原狀並以退避重試，畫面顯示「第二主機尚未一致」。絕不以「任一主機成功」結算。
  4. 使用者可以更換第二主機，或在警告後關閉核對（明確確認並記錄）；關閉後主網結算依 2.5.4 的單一來源規則。不自動關閉。
  5. 若持有人選擇擴大用途：主網 BTC 選幣前，候選 outpoint 也須由兩個主機都回報為已確認且未花，才可選用；核對失敗的輸入新增存疑紀錄，之後兩個主機都回報存在時新增解除紀錄。第二主機因此會看到 outpoint，須在第 10.5 節揭露。
  6. 兩個主機一致仍不是密碼學上的鏈證明。
- **使用者覆寫的紀錄**：時間、選擇的結果、查詢過的主機、explorer 的營運者、當時的證據快照，永久標示為「使用者覆寫」，並隨備份保存。
- §12.2 的說謊後端測試分成兩類：可以擋下的（bytes 缺漏、txid 不符、簽章無效、非 ALL、區塊雜湊改變、單一來源的取消、失敗或清除、與已核對事實矛盾的 nonce 回報），與無法獨立辨別的（有效的 T 加上偽造的深度、兩個主機同時說謊）。

---

## 3. 政策分割（不破壞 ADR-001）

### 3.1 現況

`PolicyEngine::default()`（`crates/public_core/src/policy.rs:33-68`）同時被 Vault（`crates/vault_ffi/src/lib.rs:184`）與 Wallet（`crates/wallet_ffi/src/lib.rs:1060`）使用。直接在 `Default` 加入 1，會讓兩端同時開放主網，也無法保留「release 不含本機鏈」。另外 `evaluate_eip712_template` 的 verdict 把 `chain_id: 11155111` 寫死（`policy.rs:179-184`）；QR 版已停用該路徑（`KEEP-07`），Phase 0 改為必須傳入 chain 並查表，維持停用。

### 3.2 選項與 feature unification 分析

建置事實：
- workspace `resolver = "2"`（`Cargo.toml:2`），成員含兩個 FFI crate、`tools/okx_probe`、`tools/reference_oracle`。
- `tools/build_ios_core.sh:17` 以**同一次** `cargo build --locked --release -p wallet_ffi -p vault_ffi` 建置兩個 App 的原生庫；同次建置中，任一 crate 對共用依賴（例如 `public_core`）啟用的 feature 會統一套用到兩者。
- `tools/build_android_qr.ps1:11` 逐 App 建置，並帶 `--no-default-features`。
- 既有先例：`vault_ffi`、`wallet_ffi` 都有非預設的 `test-fixtures` feature（`crates/vault_ffi/Cargo.toml`、`crates/wallet_ffi/Cargo.toml`），以 `#[cfg(any(test, feature = "test-fixtures"))]` 隔離 `vault_load_test_mnemonic`（`crates/vault_ffi/src/lib.rs:810-812`），並由 `tools/release_checks/verify_qr_apks.py:63-64` 掃描符號確認 release 不含。

| 選項 | 做法 | 結論 |
|---|---|---|
| (a) 改 `PolicyEngine::default()` 加入主網 | — | 拒絕：兩端同時開放，且沒有 dev／release 之分 |
| (b) 只在執行期由 Dart 選擇建構子（`vault_init(tier)`） | release 二進位仍含 1337／31337／regtest；選擇權在不可信的 Dart 層 | 拒絕 |
| (c) 只用 Flutter flavor | Dart 無法從 Rust 表移除項目；Vault 閘門在 Rust | 拒絕 |
| (d) `RUSTFLAGS=--cfg …` 或環境變數 | `cargo tree` 看不到；全 crate 生效；快取語意難稽核 | 拒絕 |
| (e) 另立 `vault_ffi_dev` 等 crate | FFI 介面重複維護 | 拒絕 |
| (f) 策略 B：主網與測試網拆成兩個 App | 見第 14.2 節 | 拒絕 |
| **(g) 明確建構子 + 非預設 `dev-networks` feature，兩端同開同關** | 見 3.3 | **採用**【D-04】 |

### 3.3 決定

1. **刪除 `impl Default for PolicyEngine`**（`crates/public_core/src/policy.rs:33`）。任何建構都必須明確選表，編譯器會找出所有呼叫點（含 `crates/public_core/tests/evm_tests.rs:43`、`:121`、`:148`、`:336` 與 `crates/public_core/tests/sepolia_gas_floor.rs:59`、`:116`、`:134`）。
2. `public_core` 新增 `network.rs`：
   - `pub const RELEASE_EVM_CHAINS: &[EvmChainPolicy]`、`pub const RELEASE_BTC_NETWORKS: &[BtcNetworkPolicy]`、`pub const TOKENS: &[TokenEntry]`（第 4、5 節的表）。
   - `NetworkPolicy::release()` 永遠存在。
   - `DEV_LOCAL_EVM_CHAINS`（1337、31337）、`DEV_LOCAL_BTC_NETWORKS`（Regtest）與 dev 用代幣列（見第 11.2 節）只在 `#[cfg(feature = "dev-networks")]` 下編譯。
   - 選表只在 `public_core` 的一個函式 `NetworkPolicy::for_build()`：依 `public_core` 自己的 `cfg(feature = "dev-networks")` 回傳 release 表或 release ∪ dev 表。
   - 兩個哨兵，都定義在 `public_core`、都只在此 feature 下編譯：(a) 字串常數 `FCW_DEV_NETWORKS_ENABLED`，由 `NetworkPolicy::for_build()` 產生的 JSON 參照，因此留在原生庫的唯讀資料段；(b) `#[no_mangle] pub extern "C" fn fcw_dev_networks_enabled() -> i32`。第三輪審查（Opus）以 `llvm-nm -D --defined-only` 檢查已提交的 `tools/nfc_probe/android/app/src/main/jniLibs/arm64-v8a/libwallet_ffi.so`，確認 cdylib 會匯出上游 crate 的 `#[no_mangle]` 符號（例如 `rustsecp256k1_v0_14_context_create`），所以 dev 層級的檢查同時要求 (a)(b)。Phase 0 以新產物再確認一次；若結果不同，刪除 (b) 並同步修改檢查與附錄 E，**不得**讓檢查默默略過。
3. `public_core/Cargo.toml` 定義 `dev-networks = []`（非預設；所有 crate 的 `default` 都不得包含它）。`vault_ffi` 與 `wallet_ffi` 各自定義 `dev-networks = ["public_core/dev-networks"]`（非預設），只做轉發，本身不含任何 `cfg(feature = "dev-networks")` 分支。`vault_init`（`crates/vault_ffi/src/lib.rs:184`）與 Wallet 預檢（`crates/wallet_ffi/src/lib.rs:1060`）都改用 `NetworkPolicy::for_build()`。
4. **兩端同開同關**：建置腳本只接受一個開關 `FCW_NETWORK_TIER=release|dev`，dev 時對兩個 FFI crate 都加 `--features dev-networks`，release 時兩者都帶 `--no-default-features` 且不得帶此 feature（`tools/build_ios_core.sh:17` 目前沒有 `--no-default-features`，Phase 0 一併補上）。因為選表與哨兵都在 `public_core`：
   - 在 `tools/build_ios_core.sh:17` 這種同次建置兩個 crate 的情況下，即使設定錯誤只對一端開啟，feature 也會統一到兩端（`--no-default-features` 不會清除由其他依賴啟用的 feature），兩個原生庫都變成 dev 表、也都帶哨兵。失效方向是「多了本機網路」，不是「少了檢查」。
   - 在 `tools/build_android_qr.ps1:11` 這種逐 App 建置中，兩個 App 可能分屬不同層級；由第 3.4 節的產物檢查逐一抓到。若 Wallet 為 dev、Vault 為 release，Wallet 提供的本機網路會被 Vault 拒絕（fail-closed）。
   - 本期 iOS 不在發版與驗收範圍內（第 12.6 節）；iOS 腳本只做上述 `--no-default-features` 修正，不宣稱已有 iOS 產物檢查。
5. **只增不改**：`dev-networks` 只能**新增** `class = DevLocal` 的項目，不得修改任何 release 項目。測試在開與不開 feature 時各跑一次，斷言 release 項目完全相同（`MN-01`）。
6. 每個 FFI 匯出 `{app}_network_policy_json()`：表的正規化 JSON、`tier`（`release`／`dev`）與 SHA-256 指紋。兩個 App 的「關於」頁顯示 tier 與指紋前 16 hex；從 Phase 1a 起，`tier == dev` 時常駐顯示「開發版：含本機測試網路」橫幅。Dart 端所有網路清單、名稱、代幣、上限與原生幣單位都從這個 JSON 取得，不再有 Dart 常數。

**為何不違反 ADR-001**：ADR-001 具拘束力的規則在 §2.1（crate 依賴隔離）與 §2.2（建置期稽核）；§1 列出「以 Cargo feature 區分功能」是背景中的風險。`dev-networks` 不開關任何 Wallet／Vault 能力，不含簽署或秘密程式碼，只新增網路資料列，所以不屬於該風險。ADR-001 §2.2 的稽核在現行程式中並未完整落實（C-15），第 3.4 節把它改寫成可以執行的規則。

**`dev-networks` 誤入 release 的失效分析**：本機鏈（1337、31337）的簽章因 EIP-155 chain_id 綁定，無法在主網重放；Regtest 使用 coin type `1'`，`KEEP-11` 會拒絕任何 `0'` 的輸入（最壞情況是被入侵的 Wallet 把 signet／testnet4 交易標成 regtest，仍只涉及測試幣）。所以誤入 release 不會動到主網資金，但違反 `AGENT_WORK_PACKAGE.md:336` 的「release 無開發功能」，必須由建置閘門擋下（`MN-01`）。

### 3.4 建置期與發版檢查（修訂 ADR-001 §2.2）

repo 沒有 CI；以下檢查都放在 `tools/release_checks`，列為發版清單的硬性步驟，並在 Mac 與 Windows 都能執行。

**對 ADR-001 §2.2 的修訂（明示）**：ADR-001 §2.2 第 2 點要求「二進位產物完全無 `sign`、`private_key`、`mnemonic` 等符號」，這在現行依賴下無法成立：`wallet_ffi` 依賴 `secp256k1 0.33.1`（驗簽與還原），其 C 程式庫含簽署函式；`bip32 0.5.3` 預設 feature 帶入 `k256`、`pbkdf2` 與助記詞程式碼（C-15）。本 ADR 把該點改為三項可執行的規則：(1) 每個 FFI 原生庫的匯出集合**完全等於**附錄 E 的允許清單；(2) 附錄 E 逐一記錄每個匯出的輸入契約，Wallet 的匯出不得接受種子、助記詞、私鑰或任何秘密；(3) 依賴樹規則。連結進來的通用密碼學程式庫內部符號不在保證範圍內。ADR-001 §2.1 的 crate 隔離不變；§2.2 第 1 點的依賴樹稽核保留「不得出現 `vault_core`、`bip39`」，`secp256k1` 因驗簽需要而允許（`secp256k1/sign` 這個 feature 並不存在，該條原文無法執行）。

| 檢查 | 位置 | 內容 |
|---|---|---|
| 檢查對象 | `tools/release_checks/verify_qr_apks.py`（改寫） | 對**實際上傳的 AAB** 以 bundletool 產生的全部 APK 執行；逐一檢查其中**每個**原生庫（所有 ABI，含 Flutter engine 與第三方 `.so`），不只兩個 FFI。現行只檢查 `*-qr-local-test.apk`（`:31`），且工具路徑寫死 Windows（`:25-28` 的 `LOCALAPPDATA`、`aapt.exe`、`windows-x86_64` 的 `llvm-nm.exe`），改為從 `ANDROID_SDK_ROOT`／`ANDROID_NDK_HOME` 依主機作業系統解析 |
| 哨兵 | 同上，新增 `--tier release` 與 `--tier dev` | `--tier release`：每個原生庫都不得含字串 `FCW_DEV_NETWORKS_ENABLED`，也不得匯出 `fcw_dev_networks_enabled`；`--tier dev`：依第 3.3 節第 2 點 Phase 0 的結論要求存在。既有的 `vault_load_test_mnemonic`、`vault_create_test_psbt` 不得存在的檢查保留 |
| 匯出集合 | 同上 | `libwallet_ffi.so` 與 `libvault_ffi.so` 的已定義動態匯出符號，必須**完全等於**附錄 E 中該 App、該層級的清單：多出任何一個、或少了任何一個（例如 `{app}_network_policy_json`、Phase 2a 前的三個 `regtest` 名稱）都失敗（恢復第一版的「必須存在」檢查，審查意見 Opus m-12）。新增匯出必須同時更新附錄 E 與其輸入契約，並經審查確認：Wallet 的匯出不接受秘密；Vault 的簽署只能經 handle 狀態機（ADR-004）。前綴本身不授予任何權限（審查意見 Codex R2-I5）；比對使用附錄 E 的逐字名稱，不使用萬用字元（審查意見 Codex R3-I3、Opus R3-2） |
| `public_core` 不含秘密型別 | `tests/integration/test_public_core_secret_free.py`（新增） | `crates/public_core/src` 中非 `#[cfg(test)]` 的程式碼不得出現 `SecretKey`、`XPrv`、`Mnemonic`、`sign_ecdsa`，也不得有以種子或私鑰為參數的公開函式。`public_core` 只做解析與政策；需要以種子重新派生的所有權檢查（`KEEP-11`）留在 `vault_core`（第 3.5 節） |
| 依賴樹 | 同上 | `cargo tree -p wallet_ffi -e normal` 不得出現 `vault_core` 與 `bip39`；評估 `bip32` 關閉預設 feature 以移除不需要的助記詞程式碼（Phase 0 確認） |
| 表快照 | `crates/public_core/tests/network_table.rs`（新增） | release 表的正規化 JSON 與 `crates/public_core/tests/snapshots/release_network_table.json` 逐位相同；改表必須同時改快照 |
| 治理測試 | `tests/integration/test_g7_release_governance.py:185-212`（BUILD-02，改寫） | 比對 release 表快照、確認無 `DevLocal` 項、確認 APK 原生庫中的指紋字串與快照相同 |
| 舊原生庫 | `tools/build_android_qr.ps1:11` | 建置前先刪除 `apps/*/android/app/src/main/jniLibs`，避免 dev 與 release 共用的輸出目錄殘留舊的 dev `.so` |
| 16 KB | 同上（第 13 節） | 每個打包 `.so` 的 ELF `PT_LOAD` 對齊 ≥ 16 KiB（`llvm-readelf -l`），APK 的 `zipalign -v -c -P 16 4`；並在 16 KB 分頁的 AVD 上實際載入 |
| 建置紀錄 | release manifest | 每次建置記錄：實際指令、target、`cargo tree -e features` 的解析結果（逐次 cargo 呼叫各一份，不混用）、網路表指紋、每個產物的 SHA-256 |
| 檢查本身的負向測試 | `tests/integration/test_release_audit_negative.py`（新增） | 只對一端開 feature、兩端 tier 不同、帶入 `test-fixtures`（含 JNI probe 匯出）、多一個 ABI、殘留舊 `.so`、多一個或少一個匯出，都必須讓 release 檢查失敗 |

`MN-01`：上傳的 release 產物中，任何原生庫都不含 `DevLocal` 網路或 test fixture 匯出，FFI 原生庫的匯出集合等於附錄 E.3 中該期、該 App、該層級的清單。

iOS 不在本期範圍；`tools/build_ios_core.sh:17` 在 Phase 0 補上 `--no-default-features`（第 3.3 節第 4 點），其 `:27-28` 目前只檢查 `_${app}_init` 是否存在，iOS 上架前比照本節改寫（C-21）。

### 3.5 Vault 的逐鏈政策如何表示

```rust
pub enum NetworkClass { Main, Test, DevLocal }
pub enum EvmTxType { LegacyEip155, Eip1559 }
pub enum EvmFeeModel { L1, ArbitrumInclusive, OpStackL1DataFee }

pub struct EvmChainPolicy {
    pub chain_id: u64,
    pub display_name: &'static str,             // 例：「Ethereum 主網」
    pub class: NetworkClass,
    pub native_symbol: &'static str,            // ETH | POL
    pub native_decimals: u8,                    // 18
    pub allowed_tx_types: &'static [EvmTxType],
    pub fee_model: EvmFeeModel,
    pub max_signed_fee_wei: u128,               // gas_limit × max_fee（或 gas_price）的硬上限，簽章可保證
    pub extra_fee_estimate_ceiling_wei: u128,   // 只有 OpStackL1DataFee 非 0；估價門檻，任何東西都無法強制
    pub min_gas_limit: u64,                     // 21_000
    pub wallet_max_gas_limit: u64,              // Wallet 端合理性上限，非 Vault 閘門
    pub max_unsigned_tx_bytes: Option<usize>,   // Main 與 Test：Some(256)；DevLocal：None
    pub require_empty_access_list: bool,        // Main 與 Test：true；DevLocal：false
    pub settlement_level: SettlementLevel,      // 第 2.7 節：Finalized | Safe | Included
}

pub struct BtcNetworkPolicy {
    pub network: BtcNetwork,
    pub domain: BtcSigningDomain,
    pub class: NetworkClass,
    pub hrp: &'static str,
    pub coin_type: u32,
    pub max_fee_sat: u64,
    pub max_fee_rate_sat_per_kvb: u64,
    pub max_address_index: u32,                 // 第 6.4 節；宣稱自有 derivation 的輸出不得超過
    pub allowed_tx_versions: &'static [i32],    // [1, 2]
    pub allowed_sequences: &'static [u32],      // [0xfffffffd, 0xfffffffe, 0xffffffff]
    pub allow_op_return: bool,                  // false
    pub settlement_depth: u32,                  // 第 2.7 節
    pub watch_until_depth: u32,                 // 第 2.7 節
}

pub struct TokenEntry {
    pub chain_id: u64,
    pub address: &'static str,                  // EIP-55 checksum，比對時轉小寫
    pub display_symbol: &'static str,
    pub decimals: u8,
    pub issuer_note: &'static str,              // 例：「Circle 原生」「Sky DAI 橋」
}
```

**單一原生驗證入口（`MN-18`）**：目前 `ParsedIntent`（`crates/public_core/src/evm.rs:46-58`）只有 chain、收款人、金額與費用，沒有交易型態、原始長度、access list、gas limit，所以「`evaluate_intent` 依鏈檢查型態」無法用現有介面完成。改為：
- `public_core::validate_evm_request(raw: &[u8], declared_chain_id: u64, signer: &SignerBinding, policy: &NetworkPolicy) -> Result<ValidatedEvmRequest, PolicyRejection>`：輸入有界的原始 bytes，內部完成型態分派、解析、逐鏈檢查（型態、長度、access list、gas 下限、簽章可限制的費用、代幣），回傳不可變的 intent、`NetworkBinding`、審查顯示資料（含 Rust 產生的金額與費用字串）與 verdict。呼叫端不得另外傳入 chain、verdict 或 digest。
- `public_core::validate_btc_psbt(bytes: &[u8], domain: BtcSigningDomain, account: &AccountPublicDescriptor, policy: &NetworkPolicy)`：`AccountPublicDescriptor` 只含 master fingerprint 與帳戶擴充公鑰。它完成解析、形狀、輸出顯示、費用與 index 上界等純公開檢查；之後由 `vault_core` 以種子重新派生所有輸入與宣稱自有的輸出（`KEEP-11`）。兩段都通過才產生可核准的 handle（ADR-004 §2.2），`public_core` 不接觸任何秘密（第 3.4 節）。這取代 `crates/vault_ffi/src/lib.rs:1418-1423` 直接建構的 `Approved`。
- 所有公開入口都必須只經過這兩個函式：`vault_prepare_legacy_tx*`（`crates/vault_ffi/src/lib.rs:842`、`:1029`）、`vault_prepare_eip1559_tx*`（`:933`、`:1169`）、`vault_prepare_sign_request*`（`:1256`、`:1320`）與 `vault_prepare_ur_request`（`:1330`）進入的 `eth-sign-request` `Transaction`／`TypedTransaction` 分支（`:1063-1106`）、BTC 的 `crypto-psbt` 分支與 `vault_prepare_psbt_request`（`:1382`、`:1460`），以及 Wallet 預檢（`crates/wallet_ffi/src/lib.rs:1060`）。Phase 1a 到 2a 之間 release 建置沒有 BTC 網路時，BTC 入口在 Rust 層回「此建置未啟用 Bitcoin」，不是只在 UI 隱藏。
- 刪除 `custom_verdict`（`crates/vault_ffi/src/lib.rs:1122`；目前三個分支都設為 `None`，見 `:1074`、`:1087`、`:1102`，沒有繞過，但這個欄位讓日後的分支可以略過檢查）。
- 不經 UR 的直接入口目前固定為帳戶 `#0`（顯示 `:919-921` 與簽署 `:1674-1677` 一致，C-07）；改為必須傳入明確的派生路徑並經 `SignerBinding` 綁定，`PreparedRequest` 新增 `signer_address` 與 `derivation_path`，現有的 `account_address`（實際存的是收款人 `tx.to`，`:903`、`:999`、`:1149`、`:1226`）改名為 `recipient`。

其他：
- BTC prepare 以 `NetworkPolicy::btc(domain)` 的欄位檢查，不再自行建構 verdict。
- 所有欄位都是編譯期常數，不能動態下載（`KEEP-22`）。

---

## 4. EVM

### 4.1 逐鏈表

chain id、原生幣、RPC 與手續費特性取自 facts §1.1–§1.2、§3、§4；費用上限與預估門檻是本 ADR 的建議值（結算層級見第 2.7 節），持有人已於 2026-10-20 決定採用（第 14.1 節）。

| 網路 | chain id | class | 原生幣 / decimals | 允許型態 | 費用模型 | Wallet 估價規則（最低值） | `max_signed_fee_wei`（建議） | `extra_fee_estimate_ceiling_wei`（建議） | `wallet_max_gas_limit` |
|---|---|---|---|---|---|---|---|---|---|
| Ethereum 主網 | `1` | Main | ETH / 18 | Legacy-155、`0x02` | `L1` | priority 用 `eth_feeHistory` 第 50 百分位（facts §1.2：只看 `eth_maxPriorityFeePerGas` 會低估，**單一來源**） | 0.02 ETH | 0 | 500,000 |
| Arbitrum One | `42161` | Main | ETH / 18 | Legacy-155、`0x02` | `ArbitrumInclusive`：`eth_estimateGas` 已含 L1 成本（facts §1.2，空轉帳實測 21442），所以簽章上限即總費用上限 | `maxFee ≥` 最低 gas price 0.02 gwei；tip 會被收走不退（ArbOS 61，`getCollectTips() = true`） | 0.002 ETH | 0 | 2,000,000【D-05】 |
| OP Mainnet | `10` | Main | ETH / 18 | Legacy-155、`0x02` | `OpStackL1DataFee`：`eth_estimateGas` 不含 L1 data fee（實測 21000）；另有 operator fee（實測 0，可調） | 見第 4.3 節 | 0.002 ETH | 0.0001 ETH | 500,000 |
| Base | `8453` | Main | ETH / 18 | Legacy-155、`0x02` | `OpStackL1DataFee`（實測 21000）；Base 已於 2026-04-27 離開 OP superchain-registry，設定獨立 | `maxFee ≥` 最低 base fee 5,000,000 wei（0.005 gwei），低於此值永遠不會上鏈；其餘同 OP | 0.002 ETH | 0.0001 ETH | 500,000 |
| Polygon PoS | `137` | Main | POL / 18 | Legacy-155、`0x02` | `L1`（無另計費用） | tip 用 `eth_feeHistory` 第 50 百分位，下限 25 gwei（Bor 節點 txpool 預設，不是共識規則；`eth_maxPriorityFeePerGas` 實測永遠回 25 gwei，而 gas station 的 standard 為 94 gwei）；base fee 數秒內可由 128 跳到 253 gwei，`maxFee = 2 × baseFee + tip` | 1 POL | 0 | 500,000 |
| Sepolia | `11155111` | Test | ETH / 18 | Legacy-155、`0x02` | `L1`（Glamsterdam 已於 2026-10-06 上線） | 同 Ethereum | 0.05 ETH（現值，`policy.rs:60`） | 0 | 500,000 |
| Arbitrum Sepolia | `421614` | Test | ETH / 18 | Legacy-155、`0x02` | `ArbitrumInclusive` | 同 Arbitrum One | 0.05 ETH | 0 | 2,000,000 |
| OP Sepolia | `11155420` | Test | ETH / 18 | Legacy-155、`0x02` | `OpStackL1DataFee` | 同 OP | 0.05 ETH | 0.0001 ETH | 500,000 |
| Base Sepolia | `84532` | Test | ETH / 18 | Legacy-155、`0x02` | `OpStackL1DataFee` | 同 Base（最低 base fee 同值） | 0.05 ETH | 0.0001 ETH | 500,000 |
| Polygon Amoy | `80002` | Test | POL / 18 | Legacy-155、`0x02` | `L1` | 同 Polygon（Amoy gas station 實測 tip 25） | 0.05 POL | 0 | 500,000 |
| Hardhat 本機 | `1337` | DevLocal | ETH / 18 | Legacy-155、`0x02` | `L1` | — | 0.05 ETH（現值） | 0 | 500,000 |
| Anvil 本機 | `31337` | DevLocal | ETH / 18 | Legacy-155、`0x02` | `L1` | — | 0.05 ETH（現值） | 0 | 500,000 |

- 共同欄位：
  - `min_gas_limit = 21_000`，**legacy 與 type-2 都檢查**（現行只有 type-2 檢查，C-08）；Sepolia 保留現有 type-2 12,000 的自我轉帳例外（`crates/public_core/src/evm.rs:321-334`、`:398-419`）。
  - `max_unsigned_tx_bytes`：Main 與 Test 為 256，DevLocal 不限【D-06】。依允許的交易形狀（`data` 為空或 68 bytes、access list 為空、整數欄位皆為 `u64`、value 最多 32 bytes），合法未簽交易最長為 173 bytes（type-2；legacy 為 164 bytes），256 是縱深防禦，不是 L1 data fee 的上界。
  - `require_empty_access_list`：Main 與 Test 為 `true`，DevLocal 為 `false`【D-07】。測試網因此演練與主網相同的結構規則；`crates/public_core/tests/type2_access_list.rs` 的 access list 案例在 Phase 1a 改用 DevLocal chain。OKX 主網請求是否帶 access list 未經實機驗證（第 12.6 節），帶了就會被拒。
  - 結算層級見第 2.7 節（`Q-13`）；第二版的「EVM 一律 12 個區塊」已刪除。
- Phase 0 的表中，既有網路的 `display_name` 與現在 `packages/design_system/lib/src/review_card.dart:231-240` 的字串完全相同；新的標示文字（第 10.1 節）在 Phase 1a 才套用。
- Explorer 交易網址（只供 Wallet 顯示連結，Vault 不使用；facts §1.4，皆已確認）：`https://etherscan.io/tx/<hash>`、`https://arbiscan.io/tx/<hash>`、`https://optimistic.etherscan.io/tx/<hash>`、`https://basescan.org/tx/<hash>`、`https://polygonscan.com/tx/<hash>`、`https://sepolia.etherscan.io/tx/<hash>`、`https://sepolia.arbiscan.io/tx/<hash>`、`https://sepolia-optimism.etherscan.io/tx/<hash>`、`https://sepolia.basescan.org/tx/<hash>`、`https://amoy.polygonscan.com/tx/<hash>`。
- 每個 explorer 與每個內建 RPC 端點在網路表中帶營運者標籤，供第 2.5.4.2 節判斷核對是否獨立；標籤依各服務的網站資訊於 Phase 1a 填寫（facts 未涵蓋，UNVERIFIED）。

### 4.2 交易型態：逐鏈白名單與明確分派（`MN-03`、`MN-04`）

現況：兩個 FFI 的 `Transaction` 分支只看第一個 byte，`0x02` 走 1559，其餘一律走 legacy（`crates/wallet_ffi/src/lib.rs:1015`、`crates/vault_ffi/src/lib.rs:1065`）；`0x01`、`0x03`、`0x04` 是在 legacy RLP 解析時失敗，而不是被型態檢查拒絕。`eth-sign-request` 的 `TypedTransaction` 分支直接走 type-2（`crates/vault_ffi/src/lib.rs:1093`），直接 FFI 入口（`:842`、`:933`、`:1029`、`:1169`）各自解析。全部改走第 3.5 節的單一入口。

決定：

1. 分派改為明確列舉（依 EIP-2718：`[0, 0x7f]` 是型態化交易，`[0xc0, 0xfe]` 是 legacy，`0xff` 保留；facts §1.3）：
   - 第一個 byte 為 `0x02` 且該鏈允許 `Eip1559` → type-2 解析器；
   - 第一個 byte 在 `0xc0..=0xfe` 且該鏈允許 `LegacyEip155` → legacy 解析器；
   - 其他一律回 `UnsupportedTransactionType(b)`，不進任何解析器。
2. 明確拒絕的型態（皆不在任何鏈的白名單中）：`0x01`（2930）、`0x03`（4844）、`0x04`（7702）、`0x06`（EIP-8141 Frame，Hegotá 排定、仍為 Draft；型態值 **UNVERIFIED**）、`0x79`／`0x7A`（Base Everest，日期 TBD）、`0x7E`（OP／Base deposit）、`0x64`、`0x65`、`0x66`、`0x68`、`0x69`、`0x6A`（Arbitrum 系統型態 100、101、102、104、105、106）、`0x7F`（Polygon StateSync）、`0xFF`。日後要支援新型態，只能修改該鏈的白名單並更新快照，不能改分派預設。
3. Legacy 未簽格式（Phase 1a）【D-08，第二版修改】：
   - `declared_chain_id` 必須非 0；刪除 `crates/public_core/src/evm.rs:115-126` 中只在 `declared == 0` 時才生效的推斷，包括 `:120` 含 `1` 的寫死清單與 `(v-35)/2` 的退路。
   - 9 欄位、`r`、`s` 皆為空時，接受 `v ∈ {d, 2d+35, 2d+36}`（`d` = declared）。這等於現行在 declared 非 0 時實際接受的集合（`:145-150` 會把推斷結果固定在 declared）。`2d+35` 佔位格式是刻意保留的相容格式，有測試與整合案例：`crates/public_core/tests/canonical_roundtrip.rs:39-45`、`tests/integration/test_g4_okx_closed_loop.py:61-75`。
   - 6 欄位格式（`:133-137`）在 declared 非 0 時保留：簽署 preimage 會以 declared 重新編碼成 EIP-155（`crates/public_core/tests/canonical_roundtrip.rs:30-36`），簽章已綁定鏈，拒絕它沒有安全收益。
   - 已簽 legacy 交易的廣播與驗證解碼不受此條影響。
4. Legacy 與 type-2 都套用 `min_gas_limit`（現行 legacy 沒有下限，C-08）。低於 intrinsic gas 的交易無效、不會上鏈；通過 intrinsic 檢查但執行中 gas 不足的交易會上鏈、照扣手續費但轉帳不生效（facts §4.2）。Vault 無法得知節點估算值，21,000 下限只擋前者；實際 gas 是否足夠由 Wallet 的估算負責（審查意見 Codex R3）。
5. 其餘既有規則不變：`max_priority_fee_per_gas ≤ max_fee_per_gas`；`to` 為空（合約部署）拒絕；`data` 只能為空或 68 bytes 的 `transfer(address,uint256)`（`KEEP-05`）。
6. ERC-20 收款人一律以 EIP-55 顯示（現行為小寫，`crates/public_core/src/evm.rs:245`、`:519`，C-11），與原生轉帳一致（`crates/public_core/src/rlp.rs:81`）。

### 4.3 費用：簽章可保證的上限與無法保證的額外費用（`MN-05`）【D-20】

**Vault 能保證與不能保證的（誠實說明）**：簽章承諾的是 `gas_limit` 與每單位 gas 的上限價格，所以 Ethereum、Arbitrum One（L1 成本已計入 gas）與 Polygon 的總手續費都受簽章限制。OP Mainnet 與 Base 的總費用由三部分組成：execution fee、L1 data fee、operator fee（facts §1.2）；後兩者依交易大小、當時 L1 價格與鏈營運方可調的參數另外收取，**不在任何簽章欄位內**，現有交易格式也無法設定它們的最高支付額。OP 文件並強烈建議不要自行實作 L1 data fee 公式。離線的 Vault 無法算出或限制這兩項；它們真正的上限只有帳戶餘額。

Vault 的檢查（取代 `crates/public_core/src/policy.rs:91-99`、`:128-136` 的單一常數）：

```text
signed_fee = gas_limit × max_fee_per_gas           (type-2)
           = gas_limit × gas_price                 (legacy)
signed_fee ≤ max_signed_fee_wei(chain)             所有鏈；簽章可保證
gas_limit  ≥ min_gas_limit(chain)                  legacy 與 type-2
len(unsigned_tx_bytes) ≤ 256                       Main 與 Test
access_list == []                                  Main 與 Test
```

Vault 不檢查各鏈的協定 gas 上限：L1／OP／Base 為 16,777,216，Arbitrum One 為 32,000,000，Polygon PoS 為 33,554,432，而 Glamsterdam 上線後 `tx.gas` 的上限改為 2^32 − 1、16,777,216 只套用在 execution gas（facts §4.1、§4.2、§4.4、§4.7）。超過協定上限的交易本來就無效、不收費；成本由 `max_signed_fee_wei` 約束。

`extra_fee_estimate_ceiling_wei`（OP／Base）**不進入 Vault 的檢查公式**：把它加進「總額上限」只會讓文件看起來有一個並不存在的保證（第一版的寫法已刪除）。它只用於 Wallet 的估價門檻與 Vault 的顯示。

審查 DTO 與畫面：
- `fee_cap_wei` 維持等於 `gas_limit × price`，`packages/public_models/lib/src/review_model.dart:432-434` 的一致性檢查（`KEEP-09`）不變。額外費用放在新欄位 `extra_fee_model` 與 `extra_fee_estimate_ceiling_wei`；所有金額與費用字串由 Rust 依該鏈的 `native_symbol`、`native_decimals` 產生（修正 C-10）。
- `L1`、`ArbitrumInclusive`：一行「最高網路費（簽章保證）：X <原生幣>」；Arbitrum 註明「已含 L1 成本」。
- `OpStackL1DataFee`：三行：
  1. 「執行費上限（簽章保證）：X ETH」
  2. 「L1 data fee：不在簽章內，Vault 無法核對」；另列「Wallet 額外費用警告門檻：R（不是本筆估價，也不是上限）」（審查意見 GPT R4 Minor）
  3. 「Operator fee：不在簽章內，Vault 無法核對；可由鏈營運方調整」（離線 Vault 不聲稱它目前的值）
  並另起一行：「Vault 無法得知請求的來源，也無法驗證任何估價；FCW Wallet 會在建立與廣播前估價，超過 R 時另行要求確認（下表）」。Vault 不聲稱估計值不超過 R（審查意見 GPT 第三輪 I5、Codex R3 Minor 4）。Main 類請求在核准前必須先勾選「我了解 L1 data fee 與 operator fee 不受此簽章限制」。
- 原生幣轉帳且 `signed_fee`（OP／Base 再加 R）大於轉帳金額 10% 時，多一個確認畫面（不阻擋），該確認綁定同一個 handle 與 digest；ERC-20 不適用（費用與代幣單位不同），但一律顯示原生幣費用【D-09】。

Wallet 的估價（Wallet 端規則，非 Vault 閘門）：

| 項目 | 規則 |
|---|---|
| gas limit | 一律取當下的 `eth_estimateGas`，再乘 1.2 向上取整；**任何網路都不寫死 21000**。理由：Glamsterdam 在 Sepolia 上線後，轉 ETH 到新地址實測 `eth_estimateGas` = 207391（主網尚未排程）；通過 intrinsic 檢查但執行中 gas 不足時，交易照樣上鏈、照扣手續費但轉帳不生效（facts §4.2，EIP-2780 原文）。Glamsterdam 的各項 gas 常數仍在 Last Call，**UNVERIFIED**，所以只依賴節點估算，不在程式中放這些常數。RPC 因餘額不足等原因拒絕估算時，不得改用預設值，直接顯示原因 |
| gas limit 合理範圍 | `21_000 ≤ gas_limit ≤ wallet_max_gas_limit(chain)`（Sepolia type-2 自我轉帳沿用現行 12,000 的例外，`apps/wallet/lib/screens/send_tx_screen.dart:343-348`），取代全域寫死的 21,000–500,000（`apps/wallet/lib/services/node_rpc_client.dart:151`、`apps/wallet/lib/screens/send_tx_screen.dart:347-348`）。輸入欄位目前最多 6 位數（`send_tx_screen.dart:340`，C-12），改為依該鏈上限驗證。Arbitrum 設 2,000,000，因為其估算值以 L2 gas 單位計入 L1 成本，L1 壅塞時會變大 |
| maxFee | `2 × baseFee(latest) + tip`；Base／Base Sepolia 下限 5,000,000 wei；Arbitrum 下限 0.02 gwei |
| tip | Ethereum／Sepolia／Polygon／Amoy／Arbitrum：`eth_feeHistory` 第 50 百分位（Polygon／Amoy 再取下限 25 gwei；Arbitrum 的 `eth_maxPriorityFeePerGas` 實測回 0，但 ArbOS 61 起會收取 tip，壅塞時排序會落後）；OP、Base：`eth_maxPriorityFeePerGas`。不呼叫額外的第三方 gas station【D-10】 |
| OP／Base 建立時 | 呼叫 `GasPriceOracle`（預部署位址 `0x420000000000000000000000000000000000000F`，facts §1.2）的 `getL1Fee(未簽交易 bytes)`（OP 文件：此方法預設輸入是**未簽**交易，facts §1.2）與 `getOperatorFee(gas_limit)`；兩者之和超過 R 時顯示醒目警告與估計金額，使用者明確勾選確認後才可建立（與廣播前一致；審查意見 Argon NI-03）；R 仍不進 Vault 的檢查公式。實測參考：OP `getL1FeeUpperBound(150)` = 3341427922 wei，Base = 2006110411 wei，皆遠低於 R |
| OP／Base 廣播前 | 以同一份未簽交易重新呼叫兩者；超過 R 時顯示對話框並要求明確確認（已簽 bytes 不能修改）；另核對帳戶餘額 ≥ 轉帳金額 + `signed_fee` + 估計值，不足時提示節點會拒收 |
| 超出 Vault 上限 | Wallet 以同一份表預先計算 `signed_fee`，超過即在建立前提示並說明是哪一道限制，不產生必定被 Vault 拒絕的 QR，也不自動降低金額或 gas 來繞過 |
| 硬分叉提醒 | 若 RPC 支援 EIP-7910 `eth_config` 且 `next` 不為 `null`，建立頁提示「即將硬分叉；跨越分叉的已簽交易可能因 gas 規則改變而失敗並照扣手續費」。不支援時不提示（best effort） |

### 4.4 RPC 端點（`MN-16`）

**每條鏈一個 profile**，取代單一全域的 `chainId` 與 `rpcUrl`（`apps/wallet/lib/services/account_store.dart:5-15`）。

| 網路 | 預設（使用者必須點選確認才生效，生效前顯示隱私說明） | 依據 |
|---|---|---|
| Ethereum 主網 | **無預設**，使用者自行輸入 | 官方不提供公開 RPC（facts §3） |
| Sepolia | **無預設** | 同上；`https://rpc.sepolia.org` 實測 HTTP 522 |
| Arbitrum One | 選項 `https://arb1.arbitrum.io/rpc`，標示「官方公開端點：有限流、無可用性保證」 | facts §3 |
| Arbitrum Sepolia | 選項 `https://sepolia-rollup.arbitrum.io/rpc`，同上標示 | facts §3 |
| OP Mainnet | 選項 `https://mainnet.optimism.io`，標示「官方公開端點：嚴格限流」 | facts §3 |
| OP Sepolia | 選項 `https://sepolia.optimism.io`，同上 | facts §3 |
| Base | 選項 `https://mainnet.base.org`，標示「官方公開端點：有限流、不適合正式流量」 | facts §3 |
| Base Sepolia | 選項 `https://sepolia.base.org`，同上 | facts §3 |
| Polygon PoS | 選項 `https://polygon.drpc.org`，標示「第三方（dRPC），列於 Polygon 官方文件，無可用性保證」 | facts §3；Polygon 自營的 `polygon-rpc.com` 回 401，不得出現在程式中 |
| Polygon Amoy | 選項 `https://polygon-amoy.drpc.org`，同上標示 | facts §3；`rpc-amoy.polygon.technology` DNS 失敗，不得出現在程式中 |

【D-11】不靜默套用任何預設：所有 profile 初始為未設定，官方文件列出的端點以「一鍵選用」呈現並標明性質；Ethereum／Sepolia 只有手動輸入，首次設定時提示「這個伺服器會看到你的地址，並能謊報狀態；請使用你信任的服務」。sequencer／交易提交端點只能送交易、不能讀資料（facts §3），不提供為選項。

規則：
- **HTTPS 與 `http` 的例外**：`KEEP-19` 的規則（release 與 dev 建置相同：`http` 只允許 loopback（`localhost`、`127.0.0.0/8`、`::1`）、區域網路私有位址字面值（`10/8`、`172.16/12`、`192.168/16`、`169.254/16`、`fc00::/7`、`fe80::/10`），以及單一標籤主機名與以 `.local` 結尾的名稱；使用 `http` 時，URL 欄位下方常駐警告「此連線未加密：同一網路上的其他裝置可以看到你的地址、交易與節點帳號密碼。只在你信任的家用網路使用。」；其他主機一律必須 `https`，儲存時拒絕，每次請求時再檢查一次）由 Wallet 內共用的 URL 規則函式負責，所有端點（EVM RPC、Bitcoin Core RPC、自訂 Esplora）的儲存與每次請求都經過它；Android 的 `network_security_config.xml` 對 `dart:io` 無效，不能依賴（C-22）【D-37】。本 ADR 列出的預設與一鍵選用端點全部是 `https`。
- **不跟隨轉址**：RPC 與 Esplora 的 HTTP client 關閉自動轉址；任何 3xx 都當錯誤（「端點要求轉址，已拒絕」），避免被導到 HTTP、其他主機或未經隱私同意的服務【D-26】。
- **不顯示遠端本文**：錯誤訊息、日誌與 UI 只顯示本地錯誤分類、HTTP 狀態碼或 JSON-RPC 錯誤碼，以及遮蔽後的 `scheme://host[:port]`（沿用 `apps/wallet/lib/screens/send_tx_screen.dart:153` 的 `_rpcDisplay` 作法）。`node_rpc_client.dart:225` 的完整 URL、`:232` 的 `response.body`、遠端 `error.message` 與底層例外字串都不原樣呈現，因為伺服器可能回顯帶 token 的完整 URL【D-26】。公開備份照舊不含端點（`KEEP-17`）。
- **限流**：同一主機的所有請求（查詢、掃描、歷史、廣播）共用一個限流器（併發與請求間隔）；先判斷 HTTP 429 再判斷 Content-Type（mempool.space 的 429 是 HTML）；GET 依指數退避重試（2、4、8、16 秒，上限 60 秒，最多 5 次，加隨機抖動）；仍失敗則明確顯示「端點限流」，不得當成餘額 0。`eth_sendRawTransaction` 與 `POST /tx` **不由 HTTP 層自動重試**，只能由使用者對同一份 bytes 執行重送（第 2.5 節）。
- **逾時**：預設 10 秒（現行 EVM 為 5 秒，`node_rpc_client.dart:221`），可在 profile 調整。
- **chain_id 核對時點**：(1) 儲存 profile 時：`eth_chainId` 必須等於該 profile 的 chain id，否則不儲存（新增）；(2) 查詢 nonce／估價前（現有 `apps/wallet/lib/screens/send_tx_screen.dart:242`）；(3) 廣播前（現有 `node_rpc_client.dart:164-166`）；(4) Wallet 預檢查表；(5) Vault：`KEEP-03` 加查表（`MN-02`）。

### 4.5 網路選擇與 EVM 的付款嘗試（`MN-13`、`MN-15`）

- 刪除會改寫所有 EVM 帳戶的全域 `selectChainId`（`apps/wallet/lib/screens/account_screen.dart:300-312`），以及匯入時把 EVM 帳戶 `chainId` 覆寫成目前網路的作法（`:488-490`，C-09）。EVM 帳戶只列一次；網路在轉帳頁逐筆選擇，選擇器只列本建置網路表中、且 profile 已設定的網路，以第 10 節的標示呈現。
- 付款意圖、成員、資源與結算一律依第 2.5–2.7 節。EVM 專屬部分：
  - nonce 依第 2.5.3 節計算：以 `max(L_rpc, L_local)` 與本機已送出的衝突集合推出下一個可用 nonce；無法解釋的 `latest` 跳升要使用者核對；`pending` 只作提示；從未簽署的 nonce 之後不建立獨立付款；轉帳頁的 nonce 欄位改為唯讀；新付款前預留未結算付款的最大支出【D-29】。
  - 現行狀態 `accepted`（`apps/wallet/lib/screens/scan_signature_screen.dart:402-418` 先存 `broadcasting`，RPC 回應後存 `accepted`）屬於未結算。
  - 現行表單一變動就把已匯出的請求標成 `cancelled`（`apps/wallet/lib/screens/send_tx_screen.dart:77-95` 的 `_invalidate()` 呼叫 `apps/wallet/lib/services/transaction_history.dart:94-101` 的 `cancelPending`），nonce 因此沒有保留（C-20）。改為：QR 一顯示就是成員，表單變動只能建立新成員（PM-4）；nonce 欄位不再接受自由輸入（第 2.5.3 節）。
  - 取代時依 PM-3 只比較每 gas 價格欄位：tip 與 maxFee 都必須提高（從未送出者除外），總費用不需要更高；主流客戶端 txpool 的最低提高比例在實作時依原文核對（facts 沒有此值），低於比例的取代會被節點拒收，Wallet 在建立前檢查並說明。
  - receipt `status = 0` 與「nonce 被未知交易用掉」都依第 2.5.4 節處理，不直接導向重付。
  - `cancel` 與清除一律是 0 金額，付給配對匯出的另一個 EVM 帳戶（所選來源須回報它沒有 code），不建立 `to` 等於發送方的交易；發送方被回報有委派時，對合約收款與 ERC-20 轉帳逐筆確認（第 4.6 節，`MN-21`）。

### 4.6 EIP-7702 委派帳戶（`MN-21`）【D-40，第五版修訂】

**風險**（審查意見 GPT 第三輪 B4、R4-B4，Codex R4）：facts §4 只記錄各鏈的啟用狀態；本節其餘的 EIP-7702 協定行為（委派如何執行、標記格式、對 nonce 的影響）不在 facts 內，依審查者引用的 EIP-7702 原文寫成，實作時依原文核對。facts §4 顯示 EIP-7702（type `0x04`）已在 Ethereum（Pectra）、Arbitrum One（ArbOS 40 起）、OP Mainnet（Isthmus 起）、Base（實測區塊含 `0x4`）與 Polygon PoS（Bhilai 起）啟用。FCW 拒簽 `0x04`（第 4.2 節），所以 FCW 不會建立新的委派；但同一組種子若曾在其他工具設定委派，該 EOA 就帶有委派程式，任何對該地址的呼叫都會在該帳戶的情境下執行它。
- **FCW 能避免的**：FCW 自己不建立呼叫委派發送方的交易（外層 `to` 等於發送方），例如 `to = 自己、value = 0` 的取消——委派程式可以藉此轉走帳戶的 ETH 與代幣，而 Vault 只看到一筆零金額自轉帳。這條規則不依賴任何遠端查詢。
- **FCW 不能避免的**：交易送到另一個**有程式的地址**時（原生幣送到合約，或任何 ERC-20 轉帳——外層 `to` 是代幣合約），被呼叫的合約可以回呼發送方，委派程式因此在發送方的情境下執行，可能轉走顯示金額以外的資產（審查意見 GPT R4-B4 的構造反例：委派程式以 `tx.origin` 授權、收款合約在收款時回呼）。第三版「發往其他地址不會執行發送方的委派程式」的說法已撤回。這也不只是「任何人本來就能呼叫委派程式」的既有風險：使用者簽出的交易可以提供攻擊者原本沒有的條件，例如 `tx.origin` 等於發送方（審查意見 GPT R5-I2）。Vault 顯示的金額不是可能流出的全部。
- 委派程式執行 `CREATE` 時也會增加 EOA 的 nonce，這由第 2.5.4 節「nonce 被未知交易用掉」吸收。

**偵測**：Wallet 在建立任何 EVM 請求前、顯示 QR 前與廣播前，各以 `eth_getCode(地址, "latest")` 查詢發送方與外層 `to`（審查意見 Opus m4-4）。委派帳戶的 code 是一個固定的委派標記前綴加上 20-byte 的委派地址；前綴的值不在 facts 內，本文不給值，實作時依 EIP-7702 原文複製並以測試釘住。有第二個 RPC 時兩者都查，任一回報有 code 即視為有 code。查詢失敗或回應無法解析 → **不建立請求、不廣播**（fail-closed）。廣播前再查的結果改變時：取消的目的帳戶改被回報有 code → 不廣播這筆取消；發送方改被回報有委派 → 先補做政策 2 的確認（審查意見 Opus m5-10）。RPC 可以謊報：畫面與文件一律寫成「所選來源回報無 code／有 code」，不寫成「確認沒有委派」；只有一個 RPC 時另寫「只依單一 RPC 判斷」（審查意見 Codex R4、Opus m4-4）。自呼叫的判斷比較的是外層 raw `to` 與簽署帳戶，不是 ERC-20 calldata 內的收款人（審查意見 Codex R4）。

**政策**（建議，`Q-22`）：
1. **FCW 從不建立 `to` 等於發送方的交易。** EVM 的 `cancel` 與清除一律是 **0 金額**（配對帳戶之間的一般轉帳是 `pay`，可以帶金額，審查意見 Opus m5-9），付給同一個 Vault 種子在配對時匯出的**另一個 EVM 帳戶**（目前為 `m/44'/60'/0'/0/0` 與 `/0/1`，第 9.2 節），而且所選來源必須回報該帳戶沒有 code（審查意見 Opus m4-4、Argon M4-02）。Wallet 沒有另一個已配對的 EVM 帳戶，或所選來源回報它有 code 時，不提供產品內取消。ERC-20 收款人等於發送方的轉帳沒有用途，Wallet 不建立（審查意見 Argon M4-02）。
2. **發送方被回報有委派時**：Wallet 常駐顯示「此帳戶已設定 EIP-7702 委派（委派地址 0x…）；任何送到此帳戶的呼叫都會執行該程式」，建議使用者以其他工具移除委派（FCW 不簽 `0x04`）。轉出時：
   - 原生幣送到被回報**沒有 code** 的地址：一般確認，另顯示「只依所選來源判斷」。
   - 原生幣送到被回報**有 code** 的地址，以及**所有 ERC-20 轉帳**：每一筆都要勾選「收款合約可以回呼你的帳戶並執行委派程式，可能轉走顯示金額以外的資產；Vault 顯示的金額不是可能流出的全部」並長按確認（審查意見 GPT R4-B4）。
3. **收款地址被回報有 code**（發送方沒有委派時）：顯示「收款地址是合約或帶委派程式的帳戶；轉帳會執行其程式，gas 可能較高」。
4. **Vault 端**：Vault 看不到鏈上狀態，無法得知任何地址是否有委派，也無法得知代幣合約會不會回呼。它能做的是：比對外層 `to` 與 `PreparedRequest` 綁定的簽署帳戶（Phase 0 新增的 `signer_address`，第 3.5 節）；以種子派生配對匯出的 EVM 帳戶，`to` 符合時標示「收款人是本 Vault 的帳戶 #n」，讓 EVM 的取消也能在 Vault 核對結構（審查意見 Opus m4-4）。`to` 等於簽署帳戶時顯示「收款人是簽署帳戶本身：若此帳戶有 EIP-7702 委派，這筆交易會執行委派程式；Vault 無法得知帳戶是否有委派」，並要求勾選確認。不直接拒簽，因為 OKX 等第三方可能以自轉帳取消交易。**EVM `Main` 審查頁另外一律顯示一行與來源無關的揭露**：「若此帳戶曾在其他工具設定 EIP-7702 委派，收款合約可能回呼它並執行委派程式，轉走顯示金額以外的資產；Vault 無法得知是否有委派。」每次解鎖後的首次主網確認頁顯示完整說明（第 10.2 節）。這涵蓋第三方（例如 OKX）與被入侵 Wallet 送來的請求，它們不會經過 Wallet 的政策 2（審查意見 GPT R5-I2）。
- **代幣註冊表的收錄條件**（審查意見 Opus m4-5）：第 5 節不收錄轉帳時會呼叫收款人或發送方的代幣（例如帶收款回呼的 ERC-777、ERC-1363 類代幣）；每個代幣在實作時依其合約原始碼核對（facts 沒有涵蓋）。這只縮小風險，政策 2 對 ERC-20 的逐筆確認不因此取消。
- **替代方案**（不建議為預設）：發送方被回報有委派時拒絕所有交易。缺點：拒絕所有交易不能消除既有委派的風險（委派程式仍可能被他人呼叫），只能避免部分由本次簽署觸發的條件，卻讓使用者無法把資產移出；所以改為揭露與逐筆確認（審查意見 Codex R6 Minor 2）。
- **與 `Q-05` 的關係**：在本 Vault 新產生、從未匯入其他工具的種子不會有委派；公開助記詞（`PUBLIC_TEST_SEEDS`）的主網地址常被設定成自動轉走資產的委派，第 10.4 節的清單已擋下它們。首次主網說明提醒「不要把這組種子匯入其他錢包」。

---

## 5. 代幣註冊表（`MN-06`）

### 5.1 單一來源

- 註冊表只存在 Rust：`public_core::network::TOKENS`，以 `(chain_id, address 小寫)` 為 key，欄位見第 3.5 節。`PolicyEngine` 的 ERC-20 查表（`crates/public_core/src/policy.rs:138`，目前只用地址，所以 Sepolia 的代幣地址在 1337／31337 上也會被接受，C-16）改為以 `(chain_id, address)` 查詢。
- 顯示名稱一律來自註冊表的 `display_symbol`，**不讀鏈上 `symbol()`**：Arbitrum、OP、Polygon 的橋接 USDC 鏈上 `symbol()` 都回 `USDC`（facts §2.1）。
- 刪除 Dart 端的所有副本：`apps/wallet/lib/services/node_rpc_client.dart:35-38`、`packages/public_models/lib/src/review_model.dart:203-214`、`apps/wallet/lib/screens/scan_signature_screen.dart:447-452`。Vault 審查頁顯示原生端提供的 `amount_display`、`token_symbol`、`token_decimals`、`token_issuer_note`；Wallet 的可選代幣清單與查詢餘額的合約地址只取自 `wallet_network_policy_json`。
- **原生幣也由 Rust 產生顯示字串**：現行 Dart 把原生幣金額與最高手續費一律寫成 ETH（`packages/public_models/lib/src/review_model.dart:90`、`:173`、`:188-193`；`packages/design_system/lib/src/review_card.dart:206`），Rust 只產生 `"{} wei"`（`crates/public_core/src/policy.rs:104`）。改為 Rust 依 `native_symbol`、`native_decimals` 產生 `native_amount_display` 與 `fee_display`，涵蓋審查頁、簽署結果、歷史紀錄與重新顯示的公開結果；Polygon 與 Amoy 一律顯示 POL（C-10）。
- **收錄條件**（審查意見 Opus m4-5）：不收錄轉帳時會呼叫收款人或發送方的代幣（例如帶收款回呼的 ERC-777、ERC-1363 類）；每個代幣在實作時依其合約原始碼核對（facts 未涵蓋）。理由見第 4.6 節。
- 文件用語：第 5.3 節列的是「本版未收錄或來源不足」的代幣，不代表該鏈沒有這種代幣。

### 5.2 v1 收錄內容（只收 facts 標「已確認」者）

| 網路 | 顯示名稱 | 合約地址 | decimals | 發行說明 |
|---|---|---|---|---|
| Ethereum `1` | USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | 6 | Circle 原生 |
| Ethereum `1` | USDT | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 | Tether 官方頁列出 |
| Ethereum `1` | DAI | `0x6B175474E89094C44Da98b954EedeAC495271d0F` | 18 | Sky chainlog `MCD_DAI` |
| Ethereum `1` | USDS | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` | 18 | Sky chainlog `USDS` |
| Arbitrum One `42161` | USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 6 | Circle 原生 |
| Arbitrum One `42161` | DAI | `0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1` | 18 | Sky 自己的 DAI 橋 |
| Arbitrum One `42161` | USDS | `0x6491c05A82219b8D1479057361ff1654749b876b` | 18 | Sky 橋（鏈上 `l1ToL2Token` 核對） |
| OP Mainnet `10` | USDC | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | 6 | Circle 原生 |
| OP Mainnet `10` | DAI | `0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1` | 18 | Sky 自己的 DAI 橋 |
| Base `8453` | USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 | Circle 原生 |
| Base `8453` | USDS | `0x820C137fa70C8691f0e44Dc420a5e53c168921Dc` | 18 | Sky Base 指南 |
| Polygon PoS `137` | USDC | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | 6 | Circle 原生 |
| Sepolia `11155111` | USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | 6 | Circle 測試網 |
| Sepolia `11155111` | DAI（Sepolia 模擬） | `0xFF34B3d4Aee8ddCd6F9AFFFB6Fe49bD371b8a357` | 18 | 現有 repo 值（`policy.rs:46-51`），**不在 facts 內、未經外部核對**；只在測試網，Phase 1 起顯示名稱改為「DAI（Sepolia 模擬）」【D-12】 |
| Arbitrum Sepolia `421614` | USDC | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` | 6 | Circle 測試網 |
| OP Sepolia `11155420` | USDC | `0x5fd84259d66Cd46123540766Be93DFE6D43130D7` | 6 | Circle 測試網 |
| Base Sepolia `84532` | USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | 6 | Circle 測試網 |
| Polygon Amoy `80002` | USDC | `0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582` | 6 | Circle 測試網 |

同一地址在不同鏈上是不同條目：`0xDA10…0da1` 只在 42161 與 10 有效，送到 chain 1 必須被拒（測試案例）。

### 5.3 v1 不收錄（持有人可依 `Q-02`、`Q-03` 決定加入）

| 網路 | 代幣 | 地址 | 不收錄理由 | 若日後收錄的顯示名稱 |
|---|---|---|---|---|
| Arbitrum One | 橋接 USDC | `0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8` | 橋接版；鏈上 `symbol()` 為 `USDC` | 「USDC.e（橋接）」 |
| OP Mainnet | 橋接 USDC | `0x7F5c764cBc14f9669B88837ca1490cCa17c31607` | 橋接版，官方文件稱正在淘汰 | 「USDC.e（橋接，淘汰中）」 |
| Polygon PoS | 橋接 USDC | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` | PoS 橋接版；鏈上 `symbol()` 為 `USDC` | 「USDC.e（PoS 橋）」 |
| Base | USDbC | `0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA` | **UNVERIFIED**（無發行方或 Base 官方來源） | — |
| Arbitrum One | USDT0 | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 非 Tether 官方頁所列；USDT0 是否視為官方 **UNVERIFIED**；鏈上 symbol 為 `USD₮0` | 「USDT0（非 Tether 發行頁所列）」 |
| Polygon PoS | USDT0 | `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` | 同上；鏈上 symbol 為 `USDT0` | 同上 |
| OP Mainnet | USDT0 | `0x01bFF41798a0BcF287b996046Ca68b395DbC1071` | 同上 | 同上 |
| OP Mainnet | 舊橋接 USDT | `0x94b008aA00579c1307B0EF2c499aD98a8ce58e58` | 第三方橋接，且與 USDT0 並存 | 「USDT（舊橋接）」 |
| Base | USDT | `0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2` | 第三方橋接（Tether 與 USDT0 皆未列） | 「USDT（第三方橋接）」 |
| Base | DAI | `0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb` | 不是 Sky 發行 | 「DAI（非 Sky 橋）」 |
| Polygon PoS | DAI | `0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063` | Polygon PoS 橋版本，不是 Sky 發行 | 「DAI（PoS 橋）」 |
| OP Mainnet | USDS | `0x4F13a96EC5C4Cf34e442b46Bbd98a0791F20edC3` | **UNVERIFIED**（只有鏈上一個來源） | 「USDS」 |

DAI 沒有任何鏈上版本被宣告停用（facts §2.3，只能證明「沒找到」）。Polygon 沒有 USDS。測試網上只有 Circle 的 USDC 有官方地址。

### 5.4 未知代幣：fail-closed

依 ADR-004 §2.3.4 與現行 EVM-09 行為（`crates/public_core/src/policy.rs:138-147`），`(chain_id, address)` 不在註冊表的 ERC-20 `transfer` 一律拒簽，**不提供「原始數值顯示」模式**【D-13】。理由：沒有 decimals 與名稱時，使用者無法正確判讀金額，正是 T1 要防的情況；ADR-004 的 WYSIWYS 要求 Vault 能完整呈現所簽內容。Wallet 也不提供任意代幣的餘額或轉帳。

---

## 6. Bitcoin 後端介面

### 6.1 介面與實作

把 `apps/wallet/lib/services/bitcoin_rpc_client.dart` 抽成 Dart 介面 `BitcoinBackend`。狀態機（`apps/wallet/lib/screens/bitcoin_send_screen.dart` 的世代隔離、前景檢查、`canDispatch`、封存與恢復）只依賴介面，付款意圖、成員與資源依第 2.5 節。

| 方法 | 回傳 | Core RPC 實作（dev） | Esplora 實作（signet／testnet4／mainnet） |
|---|---|---|---|
| `verifyNetwork()` | 端點屬於帳戶網路，否則丟出 `notSent` 類錯誤 | `getblockchaininfo.chain == 'regtest'`（現有 `:111-116`） | 見 6.2 |
| `addressStats(addrs)` | 每個地址是否曾使用 | descriptor 匯入與 `getreceivedbyaddress`（現有 `:171-226`） | `GET /address/:addr`，見 6.3、6.4 |
| `loadUtxos(addrs)` | `[{txid, vout, value, previous_tx_hex, branch, address_index, confirmed}]` | `listunspent 1 9999999` + `getrawtransaction`（需 txindex，現有 `:228-280`） | `GET /address/:addr/utxo` + `GET /tx/:txid/hex` |
| `feeRates()` | 各確認目標的整數 sat/kvB | 不提供（dev 手動輸入） | 見 6.6 |
| `broadcast(hex, canDispatch)` | txid 或分類後的錯誤 | `sendrawtransaction`（現有 `:282-299`） | `POST /tx`，body 為不含換行的純 hex |
| `lookup(txid)` | `confirmed(height, block_hash)`／`inMempool`／`notFoundHere`／`inconclusive` | `getrawtransaction txid true`，`-5` 分類（現有 `:20-33`） | `GET /tx/:txid`（不使用 `/tx/:txid/status` 判斷存在，見 6.3） |
| `outspend(txid, vout)` | 未花／被某 txid 花掉（含確認狀態） | **不提供**：現行 `transactionStatus` 用的是 `getrawtransaction`（`:301-307`），不會回負確認數，畫面中 `confirmations < 0 → failed` 的分支（`apps/wallet/lib/screens/bitcoin_send_screen.dart:520-524`）實際接不到（C-02）。dev 路徑不自動判定 `conflicted` | `GET /tx/:txid/outspend/:vout`；回應格式不在 facts 內，**UNVERIFIED**，Phase 2a 依 Esplora `API.md` 核對並以錄製回應測試；判定結果仍需第 2.5.4.1 節的本地驗證 |
| `tipHeight()`／`tipHash()` | 鏈頂高度與雜湊 | `getblockchaininfo` | `GET /blocks/tip/height`（facts §5.1 實測）與 `GET /blocks/tip/hash`（facts 未實測，**UNVERIFIED**） |

- Bitcoin Core RPC 實作只在 `tier == dev` 時可選，保留給 regtest 與測試 harness（持有人決定）。release 建置只有 Esplora；自架節點的使用者可設定自己的 Esplora／electrs URL。
- 兩個實作都必須保留 `KEEP-13`：前置交易 bytes 由 FFI 核對 txid 與 script，後端無法讓 Wallet 建出「金額被謊報卻仍有效」的交易。

### 6.2 端點與網路綁定（`MN-16`）

- 預設端點見第 2.2 節表格，主網與測試網的預設一律是 `https`。使用者可為每個 BTC 網路設定自訂 Esplora URL，與其他端點走同一個 URL 規則函式（`KEEP-19`：區域網路與 loopback 可用 `http` 並顯示警告，其他主機必須 `https`），不跟隨轉址（第 4.4 節）。
- 儲存自訂端點時與每次掃描前驗證網路：取端點回報的 genesis block hash，與編譯期常數比對。**genesis 值與所用端點路徑都不在 facts 檔內**，實作時從 Bitcoin Core `chainparams.cpp` 與 Esplora `API.md` 原文複製並加測試，本 ADR 不給值（UNVERIFIED，Phase 2a 驗證項）。另以「把另一網路的地址送到 `/address/:addr` 應回 400 `Address on invalid network`」（facts §5.2，兩家實測一致）作第二道檢查。
- 審查意見指出所有 signet 可能共用同一個 genesis、以 challenge 區分（BIP-325）；若屬實，genesis 檢查無法分辨預設 signet 與自訂 signet（**UNVERIFIED**，Phase 2a 依 Core 原文核對並在此註明）。只影響測試網。
- **BTC explorer**（審查意見 Opus I4-4）：覆寫與手動結算畫面所用的 BTC explorer 不在 facts 內。候選是 facts §5.1 已列出其 API 的兩個營運者（mempool.space、blockstream.info）的網頁版；交易頁的網址格式、以及 signet／testnet4 是否有對應頁面，Phase 2a 依其文件核對後寫入網路表（UNVERIFIED，第 11.2 節第 4 點）。依第 2.5.4.2 節，後端是 mempool.space 時連到 blockstream.info，反之亦然；testnet4 沒有第二個營運者，畫面寫明「這不是獨立核對」。
- 此檢查同時擋下「blockstream.info 的 `/testnet4/api/*` 對 GET 回 HTTP 200 HTML」的陷阱（facts §5.1）。

### 6.3 回應處理規則（facts §5，全部已驗證，除非另註）

所有資源與付款結果的改變只依第 2.5.4 節與第 2.7 節；本表只定義如何分類回應。標「設計」者是本 ADR 的保守處理，不在 facts 內。

| 情況 | 規則 |
|---|---|
| HTTP 429 | 先於 Content-Type 判斷；mempool.space 回 HTML、沒有 `Retry-After`；GET 視為可重試，依 6.4 的退避規則 |
| `Content-Type` 不符預期（例如 HTML） | 一律當錯誤；JSON 解析失敗也是錯誤，不得當成空結果 |
| `/address/:addr` 判斷「已使用」 | `chain_stats.tx_count + mempool_stats.tx_count > 0`；只看 `chain_stats` 會漏掉未確認入帳 |
| `/address/:addr/utxo` 與 mempool | 結果包含未確認交易產生的輸出；已在 mempool 中被花掉的鏈上輸出會被排除（facts §5.3；排除的部分只見於原始碼，UNVERIFIED）。可用於餘額與選幣候選；被未知交易在 mempool 中花用的自有輸出，要從交易歷史與 `outspend` 才看得到（D-52） |
| `/address/:addr/utxo` 超過 500 筆 | 整個請求回 400；顯示「此地址 UTXO 超過後端上限」，**不得**當成餘額 0 |
| 分頁 | 只用 `/address/:addr/txs/chain/:last_seen_txid`，回傳少於 25 筆即最後一頁；不用 `?after_txid=`（blockstream.info 會忽略而造成無限迴圈）；不假設 `/txs` 長度固定（mempool.space 回 50 筆） |
| 交易是否存在 | `/tx/:txid/status` 對 mempool 中的交易與根本不存在的 txid 都回 200 `{"confirmed":false}`，**不得**用來判斷存在；用 `GET /tx/:txid`：200 依 `status.confirmed` 分為已確認／mempool，404 為 `notFoundHere` |
| 剛廣播後查詢回 404（設計） | 索引器可能延遲；`accepted` 之後一段時間內的 404 顯示「伺服器索引中」，狀態不變 |
| 確認數 | `tip_height − block_height + 1`；同時記錄 `block_hash` 供第 2.7 節偵測重組 |
| `POST /tx` 成功 | HTTP 200，本文為 txid；必須等於本地 txid，否則 `unknown` |
| `POST /tx` 錯誤格式 | 兩家不同：`sendrawtransaction RPC error: {JSON}` 與 `sendrawtransaction RPC error <code>: <message>`；以 regex 取出數字 code，不比對訊息文字 |
| `-27`（outputs already in utxo set） | 狀態 `unknown`，立即 `GET /tx/:txid`；依第 2.5.4、2.7 節結算 |
| `-25`（bad-txns-inputs-missingorspent） | 與「輸入已被雙花」同碼，無法區分；狀態 `unknown`，查詢 `GET /tx/:txid` 與各保留輸入的 `outspend`，只有符合第 2.5.4 節（含 T 的簽章驗證）才改變紀錄 |
| `-26`（設計） | 審查意見指出費用不足以取代等情況會回此碼（facts 未涵蓋，UNVERIFIED）；依 PM-5 進入 `unknown`。救援被拒時，畫面另外提示「費用可能不足以取代已送出的交易；可以提高費用重建救援」（審查意見 Opus m5-8） |
| `-22`（decode failed） | 狀態 `unknown`（送出後的任何回應都不能證明 bytes 沒被轉發，PM-5）；另標示「應視為缺陷調查」 |
| 其他錯誤、逾時、連線中斷 | `unknown` |
| 重送同一筆 | 冪等（200 + 同一 txid，兩家實測一致） |

### 6.4 地址範圍、掃描與恢復（`MN-17`）

現況：Wallet 帳戶只保存 `/0/0` 與 `/1/0` 兩個地址（`crates/wallet_ffi/src/bitcoin_api.rs:108-122` 的 `account_json`），其他 index 依賴 Bitcoin Core 匯入 descriptor 後由節點追蹤；Vault 接受任何未硬化 index 的自有輸出（`crates/vault_core/src/lib.rs:574-575` 只要求 `path[4] < 0x80000000`；`crates/public_core/src/bitcoin.rs:1136-1146` 的找零判定不看 index），Wallet 建 PSBT 時的 `change_index` 也沒有上界（`bitcoin_api.rs:162`、`:237`；Dart 端從後端取得後原樣傳入，`apps/wallet/lib/screens/bitcoin_send_screen.dart:309-310`；C-03）。被入侵的 Wallet 或謊報「已使用」的後端，可以把找零放在很高的合法 index：Vault 重新派生成功、標示「已驗證找零」，但一般 gap-limit 20 的掃描找不到它。

決定：

1. **index 上界**【D-21】：每個 BTC 網路有編譯期常數 `max_address_index`（建議 1,000，`Q-15`；index 範圍為 `0..=1000`）。Vault 對**宣稱自有 derivation 的輸出**（找零，以及任何標成自有的收款輸出）檢查 index ≤ 上界，超過即拒簽。輸入不受此限：花用高 index 的 UTXO 只會把資金移回範圍內。上界用完時本期只能停止配置；之後以提高上界或開放第二個 BIP-84 帳戶（`m/84'/0'/1'`）處理，需另立 ADR。
2. **一律顯示找零路徑**：Vault 審查頁的找零列顯示完整路徑（例如 `m/84'/0'/0'/1/37`），不只顯示「已驗證找零」。
3. **依序配置**：Wallet 配置收款與找零 index 時，取「鏈上未使用、未被任何資源保留（第 2.5 節）、也未曾發出」的最低 index；已匯出、已簽、pending、曾使用與**曾顯示給使用者**的 index 都視為已用。配置到上界即停止並提示「此帳戶的地址已用盡」。
4. **高水位與已發出集合**：Wallet 在帳戶檔與公開備份中保存每個 branch 已配置的最高 index，以及「已發出但尚未收款」的 index 清單（收款地址顯示給使用者時記錄）。
5. **同步的四項工作**（彼此不能互相替代；審查意見 Codex R2-I4、Argon NB-01）：
   - **刷新已用地址**：查詢所有有鏈上紀錄、有 UTXO 或被未結算集合引用的地址；舊地址可能再次收款，也可能剛被花掉。
   - **刷新已發出地址**：依第 9 點的頻率，查詢已發出但尚未收款的收款地址，以及高水位以下所有尚未確認為已用的 index 與第 9 點的 Vault 單獨範圍（包括付款人晚到的款項）。
   - **探索**：`/0/*` 與 `/1/*` 各自從 max（高水位，鏈上最後已用 index）之後（兩者都沒有時從 index 0 起，審查意見 Opus m5-1），掃到**連續 20 個未使用**為止，且不超過上界（上界以上的地址 FCW 從不配置）。地址由 Rust 派生（新增 `wallet_derive_btc_addresses_json({account_xpub, network, branch, start, count})`，回傳 `(branch, index, address, script_pubkey)`；Dart 目前沒有派生能力，`child()`、`script()`、`address()` 是 `bitcoin_api.rs:18-33` 的私有函式）。
   - **調解**：依第 2.5、2.7 節追蹤所有未結算與觀察中的集合。
   「掃描完整」= 本次同步完成探索與第 9 點「每次同步都查」的那一層刷新，且「每 24 小時」那一層最近一次完整結果未超過 24 小時（審查意見 Opus m3-8）。掃描進度（每個 branch、每個主機的游標）、鏈頂高度與雜湊持久化，中斷後從游標續掃；未完成時餘額與 UTXO 清單標示「掃描未完成」，不顯示為完整結果。
6. **建立交易的閘門**：掃描未完成時不允許建立**需要選幣**的交易。只花用已被引用、前置交易已儲存之輸入的成員不受此限：`bump`、`cancel`、變更收款資訊的 `pay`、「用 A 的資源付這筆新款」與 `rescue`；若要加入其他輸入，仍需掃描完整（審查意見 Opus m-1、m3-9）。
7. **沒有備份時的恢復**（深度掃描另對有紀錄的地址取交易歷史與 `outspend`，用來發現本機沒有紀錄的花費，D-52）：標準 gap-20 掃描，加上「深度掃描至上界」選項（兩個 branch 共 2,002 個地址，另加有紀錄地址的 UTXO 與歷史查詢）。深度掃描前警告：mempool.space 文件寫明反覆超出限流可能被封鎖（facts §5.10），建議改用自己的 Esplora。可隨時取消並回到上一次完整的標準掃描結果，或更換端點後從游標續掃（審查意見 Argon NM-01）。以其他軟體復原時，須把 gap limit 設為至少 `max_address_index + 1`（上界為 1,000 時為 1,001；否則 index 0–999 都未使用時，會在查到 index 1,000 之前停止，審查意見 GPT 第三輪 m1），否則可能找不到高 index 的資金；此說明寫入備份與復原說明（審查意見 Opus m-10）。
8. **限流預算**【D-14】：同一主機的所有請求共用一個限流器與預算。初始值：併發 ≤ 2、同一連線請求間隔 ≥ 250 ms、每分鐘 ≤ 60 個請求；429、逾時與連線錯誤以 2、4、8、16、32 秒（上限 60 秒，±20% 抖動）退避，最多 6 次，首次 429 後把每分鐘預算減半，連續 10 分鐘沒有 429 後恢復初始值（審查意見 Opus m3-8）；參數可調。依此預算，深度掃描的理想下限約 34 分鐘（D-52 的交易歷史查詢時間另計，並動態顯示），實際時間依 429 與重試動態估算並顯示。mempool.space 不公布限流數字，同一連線連續約 21 個請求後開始回 429，重連可能要 12–69 秒（facts §5.10，數字 **UNVERIFIED**）；上述初始值是本產品的保守設定，不是服務承諾。
9. **刷新頻率**：有 UTXO、被未結算集合引用、以及 30 天內發出的收款地址，每次同步都查；高水位以下其餘 index，以及 **BTC branch 0 的 index `0..=min(19, max_address_index)`**（Vault 可以不經 Wallet 顯示它們，第 10.6 節；即使 Wallet 從未發出、目前沒有使用紀錄也一律包含，不依賴高水位或探索的起點，審查意見 Codex R6-B1），每 24 小時（App 在前景時）或使用者要求時完整刷新一次。
10. 第三方 PSBT 中的自有輸出同樣受上界限制並顯示路徑。

### 6.5 選幣（Rust，取代「全部 UTXO 當輸入」）

現況：Wallet 把節點回傳的全部已確認 UTXO 都當成輸入（`apps/wallet/lib/services/bitcoin_rpc_client.dart:228-280` 回傳全部，`apps/wallet/lib/screens/bitcoin_send_screen.dart:318-319` 原樣傳入）。

新增 `wallet_ffi` 的 `select_coins`。輸入：候選 UTXO（含前置交易 bytes）、收款輸出、費率（整數 sat/kvB）、保留集合；輸出：選中的輸入、找零金額、費用、vsize 與實際序列化後的 PSBT 長度。規則【D-15，第二版修改】：

1. 候選只含**已確認**的 UTXO（現行行為；自有未確認找零見 `Q-06`），排除第 2.5 節的保留輸入；候選數量、請求 JSON 大小與前置交易取得量都有上限（候選 ≤ 500 筆，與 Esplora 每地址 UTXO 上限同量級；請求 JSON 沿用 512 KiB，`bitcoin_api.rs:167-169`）。
2. **費用隨選擇計算**：每個候選組合的費用 = vsize（輸入數、輸出數、是否有找零）× 費率，向上取整；BnB 以「有效金額」（UTXO 金額減去花用它的費用）求解，目標含收款金額與無找零時的費用，容忍範圍為找零成本。
3. 先試 Branch-and-Bound 尋找不需找零的組合（迭代上限 100,000 次）；失敗則依有效金額由大到小累加。同金額以 `(txid, vout)` 排序，保證可重現。
4. **QR 可行性是硬條件**：每個組合在接受前都以實際序列化計算 PSBT 長度（每個輸入各自內嵌完整前置交易；同一前置交易被多個輸入引用時，每個輸入各算一次）、回應預留（`crates/ur_adapter/src/crypto_psbt.rs:14-28`，每輸入 +109、另 +8）與 UR 實際幀數（由 `crates/ur_adapter/src/fountain.rs` 的編碼器計算；噴泉碼會產生約 2 倍於分片數的幀，`:246`）。某個組合超出預算時，繼續搜尋其他組合，不因 largest-first 先選到一個巨大前置交易就宣告失敗。
5. 前置交易放入 `non_witness_utxo` 之前先**去掉 witness**：txid 不包含 witness，去掉後 Vault 的 txid 核對（`crates/public_core/src/bitcoin.rs:1039-1055`）結果不變，而 segwit 批次出金交易可大幅縮小；Vault 的交易解析同時支援兩種序列化（`bitcoin.rs:358-359`）。
6. 限制：輸入 1–64 筆（`bitcoin_api.rs:14` 的 `MAX_INPUTS`，檢查在 `:178-180`）。
7. 找零低於該 script 類型的 dust 門檻（第 6.7 節）時併入手續費；併入後的費率仍須在第 6.6 節上限內，否則報錯。最終結果（含 dust 併入）才計入「預算內最多可付金額」。
8. 測試必須包含：金額足夠但 QR 不可行、改選較小前置交易的組合其實可行、重複前置交易、64 輸入邊界、恰好等於與超過上限 1 byte、dust 併入。

### 6.6 費率：整數 sat/kvB（擴充 ADR-004 §2.2，`MN-10`）

- 費率可能低於 1 sat/vB（實測 0.1–1.7；mempool.space `/api/v1/fees/precise` 最多 3 位小數、最低 0.1；Core 29.1／30 的最低轉發費率為 0.1 sat/vB；facts §5.7、§6.5）。為符合 ADR-004「金額禁用浮點」，費率一律以**整數 sat/kvB**（1 sat/vB = 1,000 sat/kvB）儲存、傳遞與比較。
- 解析：在 Rust 端把回應中的 JSON 數字當十進位字串解析（不經 `f64`），向上取整到 sat/kvB 整數。**不得**為此啟用 `serde_json/arbitrary_precision`：它是全域 feature，在 `tools/build_ios_core.sh:17` 的同次建置中會統一到 `vault_ffi`，改變 Vault 的 JSON 解析行為。
- 來源順序：mempool.space 用 `/api/v1/fees/precise`；其他 Esplora 用 `/fee-estimates`（可能缺 key、順序不固定、數值帶浮點誤差）。mempool.space 的 `/api/fee-estimates` 已棄用並回 HTTP 203，不使用。
- 下限：100 sat/kvB。低於 1,000 sat/kvB 時 Wallet 提示「低於 1 sat/vB 的交易未必能傳播或確認」（Core 30 release notes 原文，facts §6.5）。
- vsize：Rust 依 BIP-141 weight 規則計算。P2WPKH 輸入的 witness 長度依 DER 簽章長度而異；Vault 以「接受的 DER 編碼範圍內最短的簽章」計算 `vsize_min`（不是常見長度），Wallet 以最長的計算估費。
- Vault 檢查（取代 `crates/public_core/src/bitcoin.rs:1169-1172` 的單一常數）：
  - `fee_sat ≤ max_fee_sat(network)`
  - `fee_sat × 1000 ≤ max_fee_rate_sat_per_kvb(network) × vsize_min`（交叉相乘比較，不做會向下截斷的整數除法；以 `u128` 計算並檢查溢位；Regtest 的 `u64::MAX` 上限也在測試邊界內）
  - 審查畫面顯示手續費（sat 與 BTC 字串）、估計 vsize、有效費率（sat/vB，3 位小數，由 Rust 產生字串），並在被拒時說明是哪一道限制。
- 建議上限（`Q-01`）：

| 網路 | `max_fee_sat` | `max_fee_rate_sat_per_kvb` |
|---|---|---|
| Bitcoin 主網 | 100,000 | 200,000（200 sat/vB） |
| Signet／Testnet4（`TestTb`） | 與主網相同：100,000【D-25】 | 與主網相同：200,000 |
| Regtest | 5,000,000（現值） | 不限（`u64::MAX`，維持現行行為） |

  `TestTb` 與主網共用金鑰與程式路徑，主網資金若落在 `1'` 的 script 上會以測試網名義簽署（第 2.2 節），所以測試網上限不高於主網；測試網手續費沒有價值，收緊沒有實際代價。
- 手續費大於外部輸出總額 10% 時，Vault 多一個確認畫面（不阻擋），綁定同一個 handle 與 digest；沒有外部輸出（自轉帳、整併）時改為顯示費率確認【D-09】。「外部輸出」= 沒有通過自有派生驗證的輸出；付給自己 `/0/*` 的輸出也算自有（現行 `crates/public_core/src/bitcoin.rs:1136-1146` 只把 branch 1 認作找零，第 2a 期一併改正）。

#### 取消空間（`Q-18`）

BTC 的取代與取消依 PM-3 必須在手續費與費率上都高於仍可能上鏈、曾送出的成員；Vault 的上限可能讓這件事做不到（審查意見 Codex R2-I2、Opus N-5、Argon NB-02）：
- 原交易的手續費接近 `max_fee_sat` 時，任何取代都必須超過上限。
- 取消通常只有一個輸出、vsize 比原交易小，所需費率更高；以 1 進 2 出付約 24,000 sat 為例（約 141 vB；取消約 110 vB；皆為審查意見的約值，實作以 Rust 依 BIP-141 計算），取消的費率要超過約 218 sat/vB，超過 200 sat/vB 的上限。
- EVM 依 PM-3 只比較每 gas 價格欄位；取消的 gas 依目標鏈估價（第 4.3 節，不寫死 21,000），總費用仍受 `max_signed_fee_wei` 限制，所以只能說取消比加速容易，不能保證可行（審查意見 Codex R3 Minor 2、R4 Minor 1，GPT 第三輪 I1）。

可行選項（不採用逾時解鎖，也不靜默提高上限）：
1. **匯出前檢查取消空間**：Wallet 在顯示 QR 前，以 vsize 與增量轉發費算出最低限度的 `cancel`（全部輸入付到一個自有輸出）所需費用與費率；建立 `rescue` 時，對它實際花用的輸入同樣計算，且同時取代多個集合的成員時，依 PM-3 以各集合最高手續費之和計算（審查意見 GPT R4-I4、Opus m4-1）；若超出 Vault 上限，顯示「此交易一旦送出，可能無法在本產品內取消或加速」並要求明確確認，或建議降低費率。
2. **取代與取消可以加入未保留的已確認輸入**（PM-2 已允許）：加大 vsize、降低所需費率；無法解決絕對費用上限。
3. **上限擋住時的使用者途徑**：送出原交易（Wallet 持有已簽 bytes 時；這會完成原付款）；或等待；或使用者自行以其他工具簽署取代（產品外，自負風險）。
4. **Vault 對「純自轉帳」放寬上限**：所有輸出都通過自有派生驗證時，允許手續費最高到一般上限的 2 倍，需長按確認並顯示「這是為了取消先前交易而提高的手續費」。這是明示、只適用於自轉帳的放寬，不是靜默提高。

建議：1 + 2 + 3，不採用 4（被入侵的 Wallet 可以把「取消」包裝成自轉帳來多燒一倍手續費）。持有人已於 2026-10-20 決定採用此建議（`Q-18`）。

### 6.7 交易形狀：version、sequence、locktime 與 dust（`MN-09`）

| 欄位 | Wallet 建立 | Vault 接受 | 依據 |
|---|---|---|---|
| `nVersion` | `2`（現行 `bitcoin_api.rs:260`） | `{1, 2}`；`3`（TRUC）與其他值拒絕 | TRUC 自 Core 28.0 起為標準交易，限 10,000 vB（facts §6.5）；本產品不需要，fail-closed |
| `nSequence` | 一律 `0xfffffffd`（現行 `bitcoin_api.rs:216`） | `{0xfffffffd, 0xfffffffe, 0xffffffff}`；三者 bit 31 皆為 1，不啟用 BIP-68 相對時間鎖；其他值拒絕 | Core 錢包預設 `0xfffffffd`（facts §6.4） |
| `nLockTime` | `0`（現行 `bitcoin_api.rs:261`） | `0`；或區塊高度（< 500,000,000）**且至少一個輸入的 `nSequence ≠ 0xffffffff`**；時間戳型（≥ 500,000,000）拒絕；非 0 但所有輸入皆為 `0xffffffff` 時拒絕【D-22】 | 所有輸入皆為 final sequence 時共識層忽略 nLockTime，顯示「鎖定」會誤導（BIP-65）。Wallet 只產生 0；接受高度型是為第三方 PSBT 保留（防 fee sniping 見 `Q-11`） |
| 輸出金額 | 每個輸出 ≥ 該 script 類型的 dust 門檻 | 每個非 OP_RETURN 輸出（含找零）必須 ≥ 該 script 類型的 dust 門檻；0 金額拒絕【D-22】 | 現行 Vault 對輸出金額沒有下限（C-04）。門檻是依 Bitcoin Core `GetDustThreshold` 規則與 `-dustrelayfee` 預設值計算的函式，在 `public_core::bitcoin` 實作並由 Wallet 與 Vault 共用；各類型的數值在實作時依 Core 原文核對並以測試釘住，本文不寫（facts 未涵蓋；現行 P2WPKH 的 294 是 repo 既有值，`bitcoin_api.rs:15`） |

- 審查畫面：
  - `nLockTime ≠ 0` 時顯示「nLockTime：區塊高度 N（區塊 N 之後才能上鏈）」。
  - RBF 顯示為「BIP-125 取代訊號：有／無」，並註明「Core 29 起任何未確認交易都可能被取代」；不暗示沒有訊號就無法取代（facts §6.4）。
- 現況：Vault 的 `verify_and_audit_psbt`（`crates/public_core/src/bitcoin.rs:996` 起）不檢查也不顯示 `version`、`lock_time`、`sequence`（C-05）。上表在 **Phase 2a** 生效（測試網就開始執行，不等到主網）。
- full RBF 自 Core 29.0 起是唯一行為（選項已移除，facts §6.4）。Core 31 改為 cluster mempool；單筆交易的取代需要更高的手續費與費率（facts §6.4），但節點仍有轉發與增量費用等條件，取代可能被拒；被拒時原付款維持 `unknown`／`pending`，保留不變。
- 「加速／取代／取消」流程（Phase 2a）依第 2.5.2 節：新成員須與集合內每個成員共有至少一個輸入（可以捨棄其他原輸入），可以加入未保留的已確認輸入；`bump` 不改外部收款 script 與金額，可以減少已驗證的自有找零，低於 dust 時移除找零；`pay` 可變更收款資訊；與仍可能上鏈、曾送出的成員相比，手續費與費率都必須提高，從未送出時不必；共同輸入被綁住時改用 `rescue`（第 2.5.6 節）；使用者在 Vault 重新簽署。匯出前的取消空間檢查見第 6.6 節【D-33】。

### 6.8 找零配置

- 找零 index 依第 6.4 節第 3 點配置：鏈上未使用且未被保留的最低 index，不超過上界。Core RPC 路徑已在 `de8a77e` 實作「最低未使用」（`apps/wallet/lib/services/bitcoin_rpc_client.dart:203` 的 `unusedChangeIndex`，`apps/wallet/lib/screens/bitcoin_send_screen.dart:309-318`），但沒有考慮保留中的 index；Esplora 路徑由第 6.4 節的掃描結果提供。
- 選定的 index 是儲存請求與保留的一部分，恢復時重建出同一份 PSBT（`KEEP-16`）。
- 同一衝突集合的成員沿用同一個找零 index（輸出結構相同時），避免留下空洞；若新成員需要另一個找零輸出，配置新的 index 並一併保留（審查意見 Opus m-3）。
- Vault 照舊重新派生找零（`KEEP-11`）；找零只能是本帳戶的 P2WPKH，最多一個（第 8.2 節），並顯示完整路徑。

### 6.9 恢復狀態與「查無」的語意（`MN-12`）

BTC 的意圖、成員、資源、取代與結算全部依第 2.5–2.7 節。BTC 專屬補充：
- 重啟時 `broadcasting`、`accepted` 降為 `unknown`（現行 `apps/wallet/lib/screens/bitcoin_send_screen.dart:162-166`，保留）。
- `newDraft`（`:552` 起）改為：只有 `draft` 可以丟棄；其他狀態的「封存」只是 UI 旗標，不改變任何紀錄，也不再把 `awaitingSignature`／`verified` 寫成 `cancelled`（`:566-570`，C-01）。
- Core 路徑的 `transactionNotFound`（`apps/wallet/lib/services/bitcoin_rpc_client.dart:24-30`）目前會設定 `_canResend` 並讓 `unknown` 可封存（`apps/wallet/lib/screens/bitcoin_send_screen.dart:63-68`、`:538-541`）。Phase 2a 起兩種後端套用同一規則：查無只允許查詢與重送同一份 bytes。
- Esplora 的 404（`notFoundHere`）只顯示「此伺服器查無；可重送同一筆，或改用其他伺服器查詢」，狀態維持 `unknown`。
- 族外交易 T 只有通過第 2.5.4.1 節的驗證才算數；`outspend` 回報但取不到 T、T 的簽章無效、或 T 的 sighash 不是 ALL 時，記錄為可疑回應，不改變任何紀錄。
- 偽造的 UTXO（例如另一網路上付給同一 script 的交易，第 10.5 節）只會讓含它的成員永遠無法上鏈。PM-2 允許取代時捨棄這類輸入，只要集合仍有真實的共同輸入；若共同輸入只剩偽造輸入（A={X_f} 之後又加入真實的 Y），以第 2.5.6 節的 `rescue` 取回 Y，原付款意圖維持未結算（審查意見 Opus N-2、Codex R3-B1、GPT 第三輪 B1）。第三版「不會凍結同一集合中的真實輸入」的無條件說法已撤回。

EVM 的對應規則見第 4.5 節（`MN-13`）。

---

## 7. PSBT 輸入政策（`MN-11`）

### 7.1 `non_witness_utxo`

- Vault 目前只能簽 P2WPKH 輸入（`crates/public_core/src/bitcoin.rs:1075-1081`），簽章是 ECDSA（ADR-002 §2.1；`secp256k1` 未啟用 Schnorr 簽署），所以**每個可簽輸入都是 segwit v0**。
- 規則：segwit v0 輸入**必須**附 `non_witness_utxo` 並核對 txid（`KEEP-10`，現行 `bitcoin.rs:1039-1055`）。理由：BIP-143 只承諾本輸入的金額，被入侵的主機可讓使用者對兩份 PSBT 各簽一次、各自謊報另一輸入的金額，多出的錢成為礦工費（CVE-2020-14199；facts §6.1）。Trezor 與 BitBox02 強制要求前一筆交易，Ledger 只警告、Jade 不檢查（facts §6.2；Jade 部分 **UNVERIFIED**）。
- 「只有全部輸入都是 taproot 時才可只帶 `witness_utxo`」（BIP-341／BIP-371；facts §6.2）在本產品**不存在對應路徑**：Vault 沒有 taproot 簽署能力。此條件規則保留給未來的 BIP-86 帳戶 ADR；混合 segwit v0 與 taproot 輸入時，v0 輸入仍須 `non_witness_utxo`。
- 不支援 legacy（P2PKH）輸入。

### 7.2 QR 預算與「無法以 QR 簽署」

現有上限：

| 項目 | 值 | 位置 |
|---|---|---|
| PSBT 位元組 | ≤ 131,072（128 KiB） | `crates/public_core/src/bitcoin.rs:593-597`；`crates/ur_adapter/src/bounded_cbor.rs:4` 的 `MAX_ALLOWED_PAYLOAD` |
| 回應容量預留 | 每個輸入 +109 bytes，另 +8 | `crates/ur_adapter/src/crypto_psbt.rs:14-28` 的 `ensure_p2wpkh_response_capacity` |
| 每次傳輸的 QR 幀數 | ≤ 512；噴泉碼產生 `max(2 × 分片數, 分片數 + 2)` 幀（再以 512 為上限） | `crates/ur_adapter/src/fountain.rs:7` 的 `MAX_UR_FRAMES`、`:246` |
| 每幀字元 | ≤ 2,331 | `crates/ur_adapter/src/fountain.rs:11` 的 `MAX_UR_DISPLAY_CHARS` |
| 分片長度 | `max(120, ⌈len ÷ 512⌉)` | `crates/ur_adapter/src/fountain.rs:33-36` |
| 建立請求 JSON | ≤ 512 KiB | `crates/wallet_ffi/src/bitcoin_api.rs:167-169` |

主網上常見交易所批次出金的前置交易有數百個輸出、數十 KB；少數幾個這類 UTXO 就會超過上限。

規則：
1. 第 6.5 節的選幣把「實際序列化的 PSBT bytes + 回應預留 ≤ 131,072，且請求與回應的實際幀數 ≤ 512」當成硬條件；接受前以實際序列化驗證，估算不算數。前置交易先去掉 witness（第 6.5 節第 5 點）。
2. 無法在預算內湊足金額時，Wallet 顯示「無法以 QR 簽署」頁，列出：需要的金額、預算內最多可湊的金額（含 dust 併入後的結果）、需要的輸入數、實際 PSBT bytes 與上限 131,072、實際幀數、前置交易最大的幾個 UTXO（txid 前 8 碼與 KB）。建議作法：把前置交易大的 UTXO 逐一自轉帳整理。
3. **已知限制**：如果單一 UTXO 的前置交易（去掉 witness 後）本身加上必要開銷就超過預算，它連單一輸入的自轉帳也無法以 QR 簽署，本產品無法花用它；需要其他傳輸方式或未來的 taproot 帳戶。Wallet 在收款頁說明此風險，偵測到這類 UTXO 時明確標示「無法以 QR 花費」，不得承諾整理一定可解。
4. **絕不靜默降級**：不移除 `non_witness_utxo`、不改用只帶 `witness_utxo`、不自動拆成多筆交易、不提高上限。
5. 超過上限的 PSBT 若仍送到 Vault，UR 解碼即被有界解析器拒絕；Vault 顯示「此請求超過 QR 上限」。

---

## 8. 輸出顯示：主網拒簽無法顯示為地址的輸出（`MN-08`）

### 8.1 現況

`verify_and_audit_psbt` 只把 P2WPKH 轉成地址，其他 script 一律顯示 `script:<hex>`（`crates/public_core/src/bitcoin.rs:1123-1133`）。解碼器只支援 v0 P2WPKH（`bitcoin.rs:184-221`）；Wallet 只能付款給 `bcrt` 的 P2WPKH（`crates/wallet_ffi/src/bitcoin_api.rs:181-182`）。

### 8.2 決定

1. 刪除 `script:<hex>` 分支：無法顯示為下表地址的輸出，`verify_and_audit_psbt` 回 `BitcoinError::UnrenderableOutput(index)`，請求被拒、簽章次數為 0。**所有網路都適用**（不只主網），在 Phase 2a 生效；Phase 2a 時尚未支援的地址類型同樣拒絕（fail-closed），Phase 2b 再加入。
2. 可顯示的類型（地址前綴由 prepare 時綁定的 `BtcSigningDomain` 決定）：

| 類型 | scriptPubKey 形式 | 編碼 | 階段 |
|---|---|---|---|
| P2WPKH | witness v0，20 bytes | bech32（BIP-173） | 現有 |
| P2WSH | witness v0，32 bytes | bech32（BIP-173） | 2b【D-16：owner 清單外另加】 |
| P2TR | witness v1，32 bytes | bech32m（BIP-350） | 2b |
| P2SH | `OP_HASH160 <20> OP_EQUAL` | base58check | 2b |
| P2PKH | `OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG` | base58check | 2b |

3. 一律拒絕：witness v1 但長度不是 32 bytes（含 Pay-To-Anchor）；witness v2–v16（目前共識未定義，送入等同任何人可花）；P2PK；裸多簽；非標準 script；**所有 OP_RETURN 輸出**（不論金額；零金額 OP_RETURN 是否開放見 `Q-04`）；低於 dust 門檻或 0 金額的輸出（第 6.7 節）。
4. **找零**：被標示為找零的輸出必須是本帳戶 P2WPKH、通過重新派生（`KEEP-11`）、index 不超過上界（第 6.4 節），**每筆交易最多一個**；超過一個即拒絕【D-22】。找零列顯示完整派生路徑。
5. **多個收款輸出**：FCW Wallet 只建立一個收款輸出；第三方 PSBT 可以有多個。審查頁頂端：只有一個外部輸出時顯示該地址與金額；有多個時改為「N 個收款輸出，合計 X；請逐一核對」，不再只顯示第一個地址（現行 `crates/vault_ffi/src/lib.rs:1407-1411` 與 `packages/public_models/lib/src/review_model.dart:578-579` 取第一個，C-06）；所有輸出逐列完整顯示（現行 `packages/design_system/lib/src/review_card.dart:108-112` 已列出），且在使用者捲動看過全部輸出之前，核准按鈕不可用。公開簽署結果的綁定以 `signing_digest`（整份 PSBT 的 SHA-256，`crates/vault_ffi/src/lib.rs:1405`）為準，已涵蓋所有輸出。
6. 外部收款輸出若帶有不屬於本 Vault 的 `bip32_derivation`，現行會被 `verify_key` 拒絕（`crates/vault_core/src/lib.rs:606-610`）。保留此 fail-closed 行為，代價是部分協調器產生的 PSBT 無法簽署。
7. 未知的 PSBT 欄位（含 `PSBT_GLOBAL_XPUB` 與 proprietary 欄位）維持拒絕（`KEEP-10`，`crates/public_core/src/bitcoin.rs:1001-1009`）。facts §6.3 指 BIP-174 建議簽章端原樣保留未知欄位；本產品選擇嚴格子集，理由是 Vault 只能審查它理解的內容，代價是 Sparrow、Core 等產生、帶有這類欄位的 PSBT 會被拒。現行解析時其實已保留未知欄位（`bitcoin.rs:642`），只在審核層拒絕，日後放寬只需改審核層。
8. base58check 的版本位元組與 bech32m 常數**不在 facts 檔內**：實作時依 Bitcoin Core `chainparams.cpp`、BIP-173、BIP-350 原文複製，並以 BIP 附帶的正向與負向測試向量釘住（錯誤 checksum、大小寫混用、非零 padding、v0 用 bech32m、v1 用 bech32、長度與版本錯誤、跨網路前綴）。另以參考實作 crate 作為 **dev-dependency** 做差分測試（resolver 2 下不進 release 建置），避免自寫的 encode 與 decode 共享同一個錯誤（Phase 2b 驗證項）。
9. Wallet 收款地址解析使用 `public_core` 的同一套編解碼器：只接受上表五種、網路必須符合帳戶網路（例如主網帳戶拒絕 `tb1…`）、witness v0 必須是 bech32、v1 以上必須是 bech32m（BIP-350）、拒絕大小寫混用。
10. 不新增執行期 crate：在 `public_core::bitcoin`（現有 `bitcoin.rs:153-221` 的 bech32 編碼）上加入 bech32m 常數與 base58check（使用既有的 double-SHA256）【D-17】。這是對 ADR-002 原則（「依賴經過戰場驗證的程式庫」）的偏離，需持有人一併核准 ADR-002 的正式修訂（`Q-17`）。理由：引入完整的 `bitcoin` crate 會把另一個 `secp256k1` 主版本與大量 API 帶進兩個 App（版本需實作時核對）；而 ADR-002 宣稱的 `rust-bitcoin =0.32.0` 實際從未加入依賴。
11. 顯示格式：完整地址，每 4 字元一組；旁邊加網路標記（第 10 節）；金額同時以 sat 與 8 位小數 BTC 字串顯示，皆由 Rust 產生。

---

## 9. 配對與帳戶匯出

### 9.1 現況

- 自有 Wallet 的配對 UR（`crates/vault_core/src/lib.rs:298-387`）：EVM 兩筆 leaf（`m/44'/60'/0'/0/0`、`/0/1`，note `account.standard`）；BTC 一筆帳戶層 key，`derive_btc_public_account(idx, "bcrt")` 寫死（`:334`），note 為 `account.btc_bip84.regtest`（`:351`），只匯出一次（`:337`）。
- `build_multi_accounts_ur(&[0, 1], "bcrt", …)` 的**第二個參數是 `device`，不是網路**（`crates/vault_core/src/lib.rs:298-303`；呼叫點 `crates/vault_ffi/src/lib.rs:325`、`:534`、`:575`、`:675`、`:756`）。匯出的 device 名稱因此是 `"bcrt"`。
- `CryptoHDKey` 沒有 `use_info` 欄位，解析時忽略未知 key（`crates/ur_adapter/src/crypto_multi_accounts.rs:7-14`、`:86-124` 的 `_ => {}`），編碼時也不輸出。
- Wallet 解碼把所有 `m/84'/` 開頭的 key 交給 `btc_account_from_hdkey`（`crates/wallet_ffi/src/lib.rs:845-853`），後者只接受 `m/84'/1'/0'`（`crates/wallet_ffi/src/bitcoin_api.rs:72-81`）且只接受 `tpub`（`:34-45`）；label 寫死「Vault Bitcoin Regtest」（`crates/wallet_ffi/src/lib.rs:848`）；`default_chain_id == 0` 時退回 11155111（`:834-838`）。
- OKX 匯出（`crates/vault_core/src/lib.rs:393-458`）只含 EVM，不帶 chain 資訊；OKX 在每個 `eth-sign-request` 帶 `chain_id`。

### 9.2 決定

1. Phase 0：`build_multi_accounts_ur(indices, device, btc_domains: &[BtcSigningDomain], max_fragment_len)`，網路改為明確參數，**輸出 bytes 不變**（device 名稱仍為現值）。Vault 預覽中另一處寫死的 `derive_btc_public_account(0, "bcrt")`（`crates/vault_ffi/src/lib.rs:266`）與還原預覽只顯示 `btc_account_0`（`apps/vault/lib/screens/vault_home_screen.dart:1748`）一併改為依網路表（C-14）。device 名稱改為實際裝置名放在 Phase 2a，與 `use_info` 輸出一起改。
2. EVM 部分不變：EVM 金鑰與鏈無關，同一份配對 UR 適用所有 EVM 網路。兩個帳戶（`/0/0`、`/0/1`）都要保留：第 4.6 節的取消付給另一個帳戶。
3. BTC 匯出【D-27，第二版修改】：

| key | origin | 前綴 | note | 建置 | 階段 |
|---|---|---|---|---|---|
| 測試網 key | `m/84'/1'/0'` | `tpub` | `account.btc_bip84.test` | release、dev | 2a |
| 主網 key | `m/84'/0'/0'` | `xpub` | `account.btc_bip84.mainnet` | release、dev | 2b |

   - `m/84'/1'/0'` 只匯出**一筆**。BCR-2020-007 的 `use_info` 網路欄位只區分主網與測試網，無法區分 signet、testnet4 與 regtest；dev 建置若匯出兩筆同 origin 的 key，CBOR 內容會完全相同。由 Wallet 在匯入時讓使用者選擇 signet／testnet4（release）或 regtest（dev），同一把 `tpub` 可以建立多個測試網路帳戶。
4. 每筆 BTC key 加上 BCR-2020-007 的 `use_info`（crypto-coininfo：幣別與網路），**從 Phase 2a 起輸出**（第一版排在 2b，與 2a 需要可匯入的測試網 key 矛盾）。其 CBOR key 編號、網路值與預設值不在 facts 檔內，Phase 0 從 BCR-2020-007 原文複製並以向量測試釘住（**UNVERIFIED**）。盤點指出缺少 `use_info` 時第三方會預設為 BTC 主網，因此現在匯出的 `84'/1'` 帳戶可能被第三方誤認為主網。
5. **缺少 `use_info` 的相容規則**：FCW Vault 產生的 key 以 origin 的 coin type 為準；Phase 2a 之前的舊匯出（沒有 `use_info`、origin 為 `m/84'/1'/0'`）只能匯入為 `regtest` 帳戶（D-03），release 建置提示重新配對；帶有 `use_info` 但與 coin type 或前綴不一致者拒絕。
6. 主網 key 只在 Vault 通過第 10.4 節的公開種子檢查、且本次解鎖後使用者已確認首次主網警告後才匯出。
7. Wallet 解碼：接受 `m/84'/0'/0'`（`xpub`、depth 3、child `0'`）與 `m/84'/1'/0'`（`tpub`）；交叉核對 coin type、`use_info` 的網路與前綴，任一不一致即放入 `unsupported_accounts` 並附原因；label 依網路產生；帳戶身分依第 2.4 節的 `account_id`。
8. OKX 匯出不變（只含 EVM）；OKX 送來的 EVM 請求由同一份表把關（`MN-02`）。OKX BTC 不在本 ADR 範圍：先前因 OKX 只支援 BTC 主網而記為 BLOCKED（`tools/release_checks/generate_g6_evidence.py:53-58`）；開放 BTC 主網後，由於 OKX 匯出不含 BTC key，OKX 無法為 Vault 的 BTC 金鑰建立 PSBT。任何來源的 `crypto-psbt` 都套用同一套 Vault 規則。若日後要把 BTC key 匯出給 OKX，需另立 ADR。
9. Phase 1a 到 2a 之間（release 建置沒有 BTC 網路）：Vault 匯出不含 BTC key；Wallet 隱藏 BTC 入口並顯示「此版本暫不支援 Bitcoin」，不顯示「請由更新後 Vault 重新產生配對碼」這類誤導訊息（現行 `apps/wallet/lib/screens/account_screen.dart:246`）；舊 BTC 帳戶與紀錄保留、可檢視；BTC FFI 符號保留，但在 Rust 層回「此建置未啟用 Bitcoin」（第 3.5 節）。

### 9.3 既有已配對測試帳戶的遷移

- EVM 帳戶：地址不變，不需重新配對；舊的 `chainId` 只用來設定 `last_network_by_account`（第 2.4 節，不會設成主網）。
- BTC 帳戶：既有帳戶一律標為 `regtest`。release 建置中不可操作，提示「請在 Vault 重新匯出帳戶並在此掃描」以取得 signet／testnet4／主網帳戶。BTC 紀錄檔改名為 `bitcoin_<account_id>.json` 並標為 `regtest`（第 2.4 節）。
- 金鑰衛生：開發期間用過的種子（含 `73C5DA0A` 與 Vault QA 種子）**不得**用於主網，見第 10.4 節。Vault 無法得知任意種子的使用歷史；是否強制「主網只能用新產生的種子」見 `Q-05`。

---

## 10. UX 安全

### 10.1 網路標示（兩個 App，`MN-15`）

所有網路名稱、類別與配色來源都是原生端的網路表（`network_display`、`network_class`），Dart 不保留鏈名對照表（取代 `packages/design_system/lib/src/review_card.dart:231-240` 的 switch，以及 `:65-66` 只認得 regtest 的寫法）。

| class | 文字（一律搭配圖示，不只靠顏色） | 使用位置 |
|---|---|---|
| `Main` | 「主網・真實資產」＋鏈名（例如「Ethereum 主網」「Bitcoin 主網」） | Vault 審查頁頁首整條換色；Vault 簽署結果頁；Wallet 首頁帳戶列、轉帳頁頁首、掃描簽章頁、歷史紀錄每列 |
| `Test` | 「測試網・無價值」＋鏈名（例如「Sepolia 測試網」「Bitcoin 測試網（signet／testnet4）」） | 同上 |
| `DevLocal` | 「本機開發網路」＋鏈名；另有全域「開發版」橫幅 | 只出現在 dev 建置 |

- 主網與測試網使用不同的頁首底色，並通過現有的對比度測試（`packages/design_system/test/theme_contrast_test.dart`）。
- Vault 首頁與匯出頁中寫死的「Bitcoin regtest」文字（`apps/vault/lib/screens/vault_home_screen.dart:797-799`、`:1147`、`:1993`、`:2010`、`:2102`）改為依網路表產生。

### 10.2 首次使用主網的警告

- **Wallet**：第一次為主網建立 profile 或匯入主網 BTC 帳戶時，顯示全頁說明，內容依序為：未經第三方安全稽核、請先小額使用、地址會送到所選伺服器且伺服器可以謊報狀態（10.5）、已簽交易不會因取消而失效（第 2.5 節）。OP Mainnet 與 Base 另加一項：「L1 data fee 與 operator fee 不受簽章限制，實際上限只有你的帳戶餘額」（第 4.3 節）；以及「收大額款項前，讓付款人掃描 Vault 的收款 QR，或先在 Vault 核對」（第 10.6 節）。EVM 另加：「不要把這組種子匯入其他錢包：其他錢包可能替帳戶設定 EIP-7702 委派」（第 4.6 節）。使用者需逐項勾選後才能繼續；確認狀態存在 Wallet 設定，可在「關於」頁重看。
- **Vault**：每次解鎖後第一筆 `Main` 類請求、第一次主網帳戶匯出與第一次顯示 `Main` 收款地址（審查意見 Opus I5-1），在審查頁或收款頁前多一個確認頁（EVM 另含第 4.6 節的委派回呼完整說明），並改為長按確認。此狀態只存在記憶體（每次解鎖重置），**不寫入加密庫**，因此不需要變更 `storage.rs` 的 schema 或 AAD（ADR-003 不變）【D-18】。重新顯示的已簽結果同樣標示網路。是否改為持久化的 Vault 主網模式見 `Q-05`。

### 10.3 未稽核聲明與「取消不等於作廢」

- 固定字串「**未經第三方安全稽核，請先小額使用**」出現在：Wallet 首頁頁尾與「關於」頁、Vault「關於」頁與首次主網確認頁、兩個 App 的商店簡短說明或完整說明第一行、`README.md`。
- Vault 簽署結果頁與 Wallet 待廣播頁加上：「取消或關閉 App 不會撤銷已簽交易。EVM 需以相同 nonce 的交易取代，BTC 需花掉相同輸入，舊交易才會失效。」（盤點 R10；`docs/FCW_REMEDIATION_2026-10-18.md` 已有同義說明。）

### 10.4 公開與開發用種子不得用於主網（`MN-14`，擴充）

- `public_core` 編譯期清單 `PUBLIC_TEST_SEEDS`。能取得助記詞者，每筆含 master fingerprint、`m/44'/60'/0'/0/0` 與 `/0/1` 地址、`m/84'/0'/0'` 與 `m/84'/1'/0'` 帳戶擴充公鑰的 SHA-256：
  - BIP-39 零熵 12 詞 `abandon … about`（fingerprint `73C5DA0A`；`crates/vault_core/src/lib.rs:738`、`:1031`）。
  - BIP-39 零熵 24 詞 `abandon … art`（`crates/vault_core/src/lib.rs:743`；各值由測試從助記詞算出並寫入常數，本文不寫值）。
  - 只有 fingerprint 的開發用金庫：`a82351a4`（`docs/REMAINING_WORK.md:32`），以及已刪除的開發 QA 金庫 `467F1EFD`（`Q-12`，持有人 2026-10-20 決定）。只比對 4 bytes 時，一般使用者誤中的機率為每筆 2^-32；誤中時只會被擋主網，不影響測試網。
- **Vault**：以解鎖後實際金鑰推導的值比對（不採信任何外部宣稱）；命中時停用主網帳戶匯出；拒絕所有 `Main` 類 prepare 與 sign；不顯示任何 `Main` 網路的收款地址或收款 QR，`vault_verify_receive_address_json` 對 `Main` 一律回同一訊息，重新顯示先前的收款頁也拒絕；還原預覽（`vault_preview_mnemonic_json`，在解鎖之前直接由助記詞計算）也比對同一清單，命中時不回傳主網 BTC 地址【D-53】（審查意見 GPT R5-B2、Opus I5-1、I6-3）；EVM 地址在所有網路上相同，所以公開種子的任何 EVM 地址顯示（還原預覽、測試網收款頁）都加上「此地址在所有 EVM 網路上相同，私鑰公開；在任何主網上收到的資產都會被取走」，並且不顯示可掃描的收款 QR；並在重新顯示已簽結果時標示；訊息為「此助記詞是公開或開發用的測試助記詞，不可用於主網」。
- **Wallet**：以 EVM 地址與 BTC 擴充公鑰雜湊比對，**不只看匯入檔宣稱的 fingerprint**（匯入檔可以改寫或省略 fingerprint）。命中時拒絕建立主網 BTC 帳戶、停用該 EVM 帳戶的主網網路，並且不顯示任何主網收款地址（入金不經簽署，所以兩端各擋自己顯示的地址：Wallet 擋 Wallet 顯示的，Vault 擋 Vault 顯示的）。EVM 地址不分網路，所以該 EVM 帳戶的測試網收款頁也加上同一警告、不顯示收款 QR（審查意見 Opus I6-3）。只有 fingerprint 的清單項目在 Wallet 端只作警告。
- 此清單只能防已知的測試金庫，無法辨識所有曾在開發中用過的種子；它是防呆，不能取代第 12.5 節的操作規則。

### 10.5 隱私與可信邊界揭露

- 每個 `(網路, 伺服器主機)` 第一次連線前顯示，主機名取自 profile：「此錢包會把你的地址（包含 gap-limit 掃描時的一整串地址）與你的 IP 位址傳送到 <host>。該伺服器可以看到你的餘額與交易紀錄，也可以看到廣播交易的來源 IP。」主網結算啟用第二主機核對時（`Q-14`），對第二主機另外揭露：BTC 的第二主機在結算核對時只收到 txid 與 outpoint，啟用選幣核對時另收到候選 outpoint；EVM 的第二個 RPC 會收到交易雜湊與帳戶地址（nonce 與 `eth_getCode` 查詢，第 4.6 節）。
- 可信邊界：伺服器可以隱藏 UTXO、偽造入帳顯示（例如拿另一條鏈上付給同一 script 的交易當成本鏈 UTXO）、謊報費率與確認狀態、謊報「已被花掉」、拒絕轉發廣播。它無法讓 Wallet 建出金額被謊報卻仍有效的交易（`KEEP-13`），也無法讓 Vault 簽下超過上限的簽章內手續費（EVM 的 `gas_limit × price` 與 BTC 手續費，`MN-05`、`MN-10`；OP／Base 的 L1 data fee 與 operator fee 不受此限，第 4.3 節）。由於 FCW 不驗證區塊標頭，**防重複付款的保留不依賴伺服器的否定回應**（第 2.5.2 節 PM-5），族外花費必須通過簽章驗證（第 2.5.4 節），但結算仍依賴所選伺服器的確認回報（第 2.7 節）。啟用選幣前核對時，第二主機會看到候選 outpoint。
- 收到的款項在 UI 標示「由伺服器回報，未獨立驗證」；未確認的入帳另外標示。用於商家或 OTC 收款時，建議以第二個伺服器或自己的節點核對。
- 使用者核對所用的 explorer 只依營運者標籤判斷是否獨立；自訂端點的營運者未知（第 2.5.4.2 節）。EIP-7702 的 code 查詢只代表所選來源的回報（第 4.6 節）。
- Vault 的「最近已簽」索引檔不加密，Vault 遺失時會洩漏最近 500 筆的收款人、金額與輸入；Vault 提供清除動作（第 2.6 節第 8 點）。
- 提供「使用自己的 Esplora／RPC 伺服器」入口。Tor／SOCKS 代理見 `Q-07`。
- 同一內容寫入隱私權政策（第 13 節）。

### 10.6 在 Vault 顯示與核對收款地址（`MN-19`）【D-32，第六版修訂】

Vault 只在簽署時審查輸出；Wallet 顯示給付款人的**收款地址**從不經過 Vault。被入侵的 Wallet 可以把攻擊者的地址顯示成「你的收款地址」，付款人直接付給攻擊者（審查意見 Opus N-8）。現行 Vault 預覽只顯示 index 0 的地址（`crates/vault_ffi/src/lib.rs:266`、`apps/vault/lib/screens/vault_home_screen.dart:1748`）。本節的所有 `Main` 網路功能都受第 10.4 節公開種子檢查的限制（D-53）。

- **收款內容的嚴格子集**【D-49，第六版修訂】（審查意見 GPT R4-B5、Opus I5-2、Codex R5 Minor 1、Argon M5-02）：FCW 產生、顯示與核對的收款內容只有兩種，偏離即為「不一致」（Vault 核對）或拒絕（Wallet 輸入）：
  - **EVM**：只有裸地址 `0x` 加 40 個十六進位字元。混合大小寫時必須通過 EIP-55 checksum；全小寫或（`0x` 之後）全大寫視為不帶 checksum，可以接受，顯示時一律轉成 EIP-55；`0X` 前綴拒絕（審查意見 Opus m6-6）。現行收款欄位只以 `^0x[0-9a-fA-F]{40}$` 比對、不驗 checksum（`apps/wallet/lib/services/transaction_builder.dart:7-10`），Phase 1a 補上。**任何 `ethereum:` URI 一律拒絕**（包括帶 `@chain_id`、`value` 或 `/transfer` 的 EIP-681 形式：`/transfer` 形式的第一個地址是代幣合約，不是收款人；`@chain_id` 也不能被忽略），提示「請向收款方取得純地址」。
  - **BTC**：`bitcoin:<地址>`，至多再帶一個 `?amount=<值>`。scheme 不分大小寫；bech32／bech32m 地址必須全小寫或全大寫（全大寫是 QR 英數模式的常見寫法），HRP 必須等於帳戶網路；base58 地址依第 8.2 節。key 必須是字面的小寫 `amount`（BIP-21／BIP-321 對 key 大小寫的規定列入 UNVERIFIED）；值只由 ASCII 數字 `0-9` 與至多一個 `.` 組成（排除全形與其他 Unicode 數字，審查意見 Opus m7-15），是十進位 BTC，至多 8 位小數，大於 0 且不超過 21,000,000，不接受正負號、指數、千分位、空白、前置或尾端的 `.`、多餘的前置 0，以整數運算換算成 sat（ADR-004 禁用浮點）。拒絕：重複的 key、percent-encoding（下一點的例外除外）、`#` fragment、`//` authority、空的 query、空的 key 或值。
  - **Wallet 的付款輸入**只去除前後的 ASCII 空白，內部任何空白都拒絕（審查意見 Opus m7-15）；另外接受：裸地址（BTC 與 EVM，套用同一套地址檢查）；以及 `label`、`message` 兩個參數名（必須是字面的小寫 ASCII；值不使用、不顯示為可信資訊，值裡可以有 percent-encoding，審查意見 Argon M6-01、Opus m6-6）；`r`、`pj`、任何 `req-*`，以及任何其他參數名都拒絕。審查意見指出 BIP-72 的 `r` 會讓付款端改讀遠端的付款請求、忽略連結中的地址，BIP-321 更新了 BIP-21 並新增 `lightning`、`lno`、`sp`、`pop` 等參數；這些名稱與語意不在 facts 內，Phase 2a 依 BIP-21、BIP-72、BIP-321 原文核對（UNVERIFIED），白名單的作法不受影響。Vault 的收款核對連 `label`、`message` 也不接受，只接受地址加 `amount`。
- **最可靠的作法**：讓付款人直接掃描 **Vault 畫面**上的收款 QR，或抄寫 Vault 顯示的地址。Vault 新增「收款地址」頁，以自己的種子派生並顯示地址文字（每 4 字元一組）與收款 QR。
- **核對 Wallet 顯示的地址**：Wallet 收款頁只有**一份**收款內容，交給付款人的 QR 與在 Vault 核對的是同一份 bytes；Wallet 另以文字顯示網路、branch 與 index（不放進 QR）。收款內容不帶 branch 與 index，所以 Vault 掃描後在有界範圍內自行派生並比對地址（審查意見 GPT R5-I4）：BTC 為帳戶網路的 branch 0、index `0..=max_address_index`（預設最多 1,001 次派生）；EVM 為配對匯出的帳戶。找到時顯示「一致」、找到的 index、完整內容與金額（若有）。「一致」只證明地址屬於本 Vault，不證明 Wallet 已登記這個地址（審查意見 GPT R6-I3、Opus m6-7）：找到的 index 在第 6.4 節第 9 點的固定刷新範圍（`0..=min(19, max_address_index)`）之外時，Vault 另外顯示「只有本 Wallet 已發出的 index 才會被自動追蹤；若這份內容不是來自本 Wallet 的收款頁，請在 Wallet 執行深度掃描」，使用者確認後才顯示收款 QR，而且只在本次核對的畫面中顯示；找不到時顯示「不是本 Vault 在此範圍內的收款地址」。內容不屬於上述子集時一律顯示「不一致：收款內容含有 FCW 不支援的格式或參數」。畫面寫明「『一致』只證明你掃描的這份內容；交給付款人的必須是同一份，或改讓付款人掃描 Vault 畫面」（審查意見 GPT 第三輪 I6、Opus m3-11）。EVM 另寫「EVM 地址不帶網路資訊：付款人在哪條鏈付款，款項就在那條鏈上的同一個地址」。
- **Vault 單獨顯示的地址**【D-50，第六版修訂】（審查意見 GPT R4-I3，`Q-25`）：Wallet 不知道 Vault 單獨顯示過哪些地址，所以 Vault 收款頁只提供兩種地址：
  1. 以上方的核對找到的地址（只在本次核對的畫面中顯示，前提與提示見上一點）；
  2. 不經 Wallet 時，只限 BTC branch 0 的 index `0..=min(19, max_address_index)`，以及 EVM 配對匯出的帳戶。

  第 2 種地址一定會被 Wallet 查詢（審查意見 Codex R6-B1）：第 6.4 節第 9 點把 BTC branch 0 的 index `0..=min(19, max_address_index)` 固定納入完整刷新，不論 Wallet 是否發出、是否有使用紀錄，也不依賴高水位或探索的起點。完整刷新在 App 位於前景且距上次已滿 24 小時時執行，也可以手動要求；它是「掃描完整」的一部分，最近一次完整刷新超過 24 小時就不能選幣（第 6.4 節第 5、6 點）。入帳在下一次完整刷新或手動刷新之後可見；在那之前，選幣可能還沒看到它，但不會花錯（審查意見 GPT R6 Minor）。刷新失敗時繼續顯示「掃描未完成」。代價：Wallet 可能把 Vault 單獨顯示過的 index 再配給別的付款人，影響隱私，也影響收款歸屬（商家無法分辨是誰付的）；畫面揭露。
- **index 範圍**：BTC 不得超過 `max_address_index`；EVM 只允許配對匯出中包含的 index（目前為 0 與 1，第 9.2 節），否則重新配對的 Wallet 找不到該帳戶（審查意見 GPT 第三輪 I7）。
- Wallet 的首次主網說明（第 10.2 節）加入「收大額款項前，讓付款人掃 Vault 的收款 QR，或先在 Vault 核對」。
- 排程：EVM 在 Phase 1a；BTC 在 Phase 2a 先於測試網落實，**Phase 2b 開放主網前必須完成**。

---

## 11. 分期

### 11.1 不變量與測試對照

repo 沒有 CI；下表的測試由 `tools/release_checks` 與各 crate／package 的測試指令執行，並列為每期出貨標準。

| 不變量 | 內容 | 新增或擴充的測試檔 |
|---|---|---|
| `MN-01` | 上傳的 release 產物中，任何原生庫都不含 `DevLocal` 網路或 test fixture 匯出；FFI 匯出集合完全等於附錄 E.3 中該期、該 App、該層級的逐字清單（多一個或少一個都失敗；清單定稿為 Phase 0 完成條件）；`public_core` 不含秘密型別；`dev-networks` 只增不改 | 新增 `crates/public_core/tests/network_table.rs`（快照 + 開與不開 feature 各跑一次）；改寫 `tools/release_checks/verify_qr_apks.py`（AAB、全部 `.so`、`--tier`、匯出集合、16 KB）；新增 `tests/integration/test_release_audit_negative.py`（多一個符號、少一個符號、JNI probe 匯出）、`tests/integration/test_public_core_secret_free.py`；改寫 `tests/integration/test_g7_release_governance.py:185-212`（BUILD-02） |
| `MN-02` | EVM 政策一律查表；查無即拒絕 | 新增 `crates/public_core/tests/policy_for_chain.rs`；反轉 `crates/public_core/tests/evm_tests.rs:147-149`；改寫 `crates/vault_ffi/src/lib.rs:2790-2803` 的測試（chain 1 在 release 表中通過、chain 56 被拒） |
| `MN-03` | 只有該鏈白名單內的型態進入解析器 | 新增 `crates/public_core/tests/tx_type_dispatch.rs`（逐一測試 256 個首位元組，含 `0x04`、`0x06`、`0x79`、`0x7E`、`0x64`–`0x6A`、`0x7F`） |
| `MN-04` | Legacy 未簽：declared 非 0；9 欄位 `v ∈ {d, 2d+35, 2d+36}` 且 `r`、`s` 為空；6 欄位保留；legacy 與 type-2 都有 gas 下限 | 新增 `crates/public_core/tests/legacy_chain_strict.rs`；保留 `crates/public_core/tests/canonical_roundtrip.rs:30-45` |
| `MN-05` | `signed_fee ≤ max_signed_fee_wei`；Main／Test 的長度與 access list 限制；OP／Base 額外費用以獨立欄位顯示、需確認，Wallet 在建立與廣播前核對 | 新增 `crates/public_core/tests/fee_cap.rs`；新增 `apps/wallet/test/l2_fee_estimation_test.dart`（建立時超過門檻、估價後漲價、operator fee 非 0、RPC 失敗、餘額不足）；擴充 `packages/public_models/test/evm_review_details_test.dart`（`fee_cap_wei` 一致性不變、額外費用欄位） |
| `MN-06` | 代幣以 `(chain_id, address)` 查表；未知即拒；Dart 無代幣常數；原生幣與費用字串由 Rust 產生 | 新增 `crates/public_core/tests/token_registry.rs`（`0xDA10…0da1` 在 chain 1 被拒）；擴充 `packages/public_models/test/review_safety_test.dart`（chain 137 必須顯示 POL）；新增 `tests/integration/test_single_source_registry.py`（Dart 原始碼不得出現任何註冊表地址或 `'ETH'` 原生幣常數） |
| `MN-07` | BTC 網路在 prepare 綁定；全部輸入與找零 coin type 一致；sign 只用綁定值；Dart 不能傳入網路 | 擴充 `crates/vault_ffi/src/lib.rs` 測試模組（`btc_network_binding_*`：混合 coin type、審查後改 dev 設定、跨域快取）、`crates/vault_core/src/lib.rs` 測試；擴充 `apps/vault/test/bitcoin_review_contract_test.dart` |
| `MN-08` | 每個 BTC 輸出都顯示為綁定網路的地址，否則拒簽；找零最多一個；多收款輸出完整顯示 | 新增 `crates/public_core/tests/btc_output_render.rs`（BIP-173／BIP-350 與 base58check 正反向量、差分測試；witness v2–v16、P2A、OP_RETURN、P2PK、裸多簽皆拒）；擴充 `apps/vault/test/review_layout_test.dart`（多收款輸出、看完全部才可核准） |
| `MN-09` | `nVersion ∈ {1,2}`、三種 `nSequence`、locktime 規則、每個輸出 ≥ dust | 新增 `crates/public_core/tests/btc_tx_shape.rs`（全 final sequence 加非 0 locktime 被拒、高度邊界、各 script 類型 dust 邊界、0 金額） |
| `MN-10` | BTC 費用與費率上限；整數 sat/kvB；交叉相乘比較 | 新增 `crates/public_core/tests/btc_fee_rate.rs`（`"0.09999999999999999"`、缺 key、3 位小數、上限前後一單位、`u64::MAX`） |
| `MN-11` | segwit v0 必附 `non_witness_utxo`；超出 QR 預算時明確報錯，不降級 | 新增 `crates/wallet_ffi/tests/coin_selection.rs`（第 6.5 節第 8 點的案例、去 witness 後 txid 不變）；新增 `apps/wallet/test/bitcoin_qr_budget_test.dart` |
| `MN-12` | 第 2.5、2.7 節的意圖、成員、證據、推導狀態、衝突集合、`rescue`、調解與逐鏈結算（兩種資產）；主網單一來源只到 `paid`／`unresolved` | 新增 `apps/wallet/test/payment_model_test.dart`（附錄 F 的 F-1–F-8、F-12–F-15、F-18、F-19、F-22–F-28、F-34–F-40、F-46–F-48、F-53、F-69、F-72，每案分別斷言資源、成員有效性與結果；F-26 另以備份匯入與重啟兩種交錯各跑一次）；新增 `crates/wallet_ffi/tests/spend_signature.rs`（第 2.5.4.1 節：有效、簽章無效、pubkey 不符、金額取自前置交易、非 ALL 記為可疑、high-S 正規化後通過、非嚴格 DER、witness 不是兩個元素、非壓縮 pubkey、u 不是 v0 P2WPKH、尾端多餘 bytes、重複 outpoint、txid 以不含 witness 的序列化核對）；新增 `apps/wallet/test/settlement_level_test.dart`（`finalized` 標籤、區塊雜湊改變、RPC 不支援標籤與手動結算、第二主機 404／落後／區塊雜湊不同／`status` 不同、單一來源的取消與清除為 `unresolved`、單一來源的 `paid` 加標示）；新增 `apps/wallet/test/esplora_client_test.dart`、`apps/wallet/test/bitcoin_backend_contract_test.dart`；擴充 `apps/wallet/test/bitcoin_recovery_lifecycle_test.dart` |
| `MN-13` | EVM 下一個可用 nonce 依第 2.5.3 節（`max(L_rpc, L_local)`、nonce 證據爭議與更正、`latest` 異常跳升的兩個出口、`pending` 只作提示、唯讀 nonce 欄位、餘額預留）；不在未簽 nonce 之後建立獨立付款；單一來源的 `status = 0` 不判定失敗 | 新增 `apps/wallet/test/evm_nonce_test.dart`（附錄 F 的 F-7–F-11、F-29、F-31、F-33、F-42–F-45、F-54、F-59–F-61、F-66、F-68、F-70、F-71，`accepted` 後重開轉帳頁、表單變動不取消已匯出成員且 nonce 欄位不可自由輸入（C-20）、RPC 落後）；擴充 `apps/wallet/test/transaction_flow_test.dart`、`apps/wallet/test/rpc_lifecycle_test.dart` |
| `MN-14` | 公開與開發用種子不得用於主網 | 新增 `crates/public_core/tests/public_test_seeds.rs`（從助記詞重算並比對常數）；擴充 `crates/vault_ffi/src/lib.rs` 測試（`mainnet_denylist_*`：匯出、prepare、sign、`Main` 收款頁、`vault_verify_receive_address_json` 與 `vault_preview_mnemonic_json`；公開種子的 EVM 地址警告；附錄 F 的 F-57）；新增 `apps/wallet/test/public_seed_denylist_test.dart`（改寫或缺少 fingerprint 的匯入檔仍被攔下；EVM 測試網收款頁的警告與不顯示 QR，審查意見 Opus m7-13） |
| `MN-15` | 網路顯示只來自原生表；主網與測試網有文字與顏色差異 | 擴充 `packages/design_system/test/design_system_test.dart`、`apps/vault/test/review_layout_test.dart`、`apps/wallet/test/ui_layout_test.dart` |
| `MN-16` | 每網路一個端點；`http` 只依 `KEEP-19` 的規則（loopback、區域網路私有位址、單一標籤與 `.local` 名稱，並顯示警告），其他主機必須 HTTPS；不跟隨轉址；儲存與使用前核對 chain id／genesis；錯誤不顯示遠端本文與完整網址 | 新增 `apps/wallet/test/endpoint_url_policy_test.dart`（接受：`http://127.0.0.1`、`http://127.8.9.1`、`http://[::1]`、`http://10.0.2.2`、`http://172.16.0.5`、`http://192.168.1.2`、`http://169.254.1.1`、`http://[fd00::1]`、`http://[fe80::1]`、`http://umbrel`、`http://node.local`，且畫面顯示未加密警告；拒絕：`http://example.com`、`http://172.32.0.1`、`http://8.8.8.8`、`http://node.example.local.com`；release 與 dev 結果相同；儲存時與每次請求時都檢查）、`apps/wallet/test/network_profile_test.dart`、`apps/wallet/test/rpc_redaction_test.dart`（遠端回顯帶 token 的 URL、3xx）；改寫 `apps/wallet/test/account_flow_test.dart` |
| `MN-17` | 宣稱自有的 BTC 輸出 index ≤ 上界；依序配置（含已發出地址）；同步四項工作；只用已引用輸入的成員豁免掃描閘門；深度掃描可到上界 | 新增 `crates/public_core/tests/btc_index_bound.rs`（上界通過、上界 +1 被拒）；擴充 `crates/vault_core/src/lib.rs` 測試；新增 `apps/wallet/test/btc_address_allocation_test.dart`（附錄 F 的 F-20、F-21、F-50：Vault 單獨範圍固定在完整刷新的查詢集合中，H=0、先用 19 再用 15、重啟與還原、上界小於 19、刷新失敗時不顯示掃描完整；掃描中斷後續掃、取消深度掃描、「掃描完整」的三層定義、限流減半與恢復） |
| `MN-18` | 所有 prepare 入口只經單一驗證函式 | 新增 `crates/vault_ffi/tests/prepare_entry_parity.rs`：對每個公開入口送入相同的惡意內容（不允許的 chain、型態、access list、超長 bytes、未知代幣），結果相同、不留下可核准的 handle、簽署次數為 0 |
| `MN-19` | Vault 能派生並顯示收款地址與收款 QR（BTC ≤ 上界；EVM 只限配對匯出的 index）；Wallet 收款頁只有一份收款內容，同時用於交付與核對；收款內容與付款連結只接受嚴格子集；「一致」只證明地址所有權；Vault 單獨顯示只限 `0..=min(19, max_address_index)` | 新增 `crates/vault_ffi` 測試（`verify_receive_address_*`：上界、上界 +1、網路不符、EVM index 2 被拒、EVM 與 BTC）；新增 `apps/vault/test/receive_address_check_test.dart`；新增 `apps/wallet/test/receive_payload_test.dart`（交付與核對使用同一份內容；附錄 F 的 F-49、F-50、F-62、F-63：完整語法、EIP-681 拒絕、EIP-55、有界比對、嚴格子集、兩端都拒絕 `r`／`pj`／`req-*` 與其他參數，`label`／`message` 只在 Wallet 付款輸入接受（值可含 percent-encoding）、Vault 核對拒絕、Vault 單獨顯示的範圍） |
| `MN-20` | 歷史可能不完整時，每一筆新付款前出現第 2.6 節的全頁說明；旗標只能以 `Q-20` 的全面確認解除，合併與清除都不解除；v1→v2 狀態對照；逐欄合併、只增不減；Vault 公開索引的提示 | 新增 `apps/wallet/test/history_completeness_test.dart`（附錄 F 的 F-16、F-17、F-30、F-40、F-46、F-47、F-52、F-55、F-64、F-65，遷移後回復停用、舊 `cancelled` 對照為 `exported`、同 id 不可變欄位不一致即拒絕、撤銷事實涵蓋匯入的同一事實證據、BTC 與 EVM 的清除都不解除旗標）；新增 `apps/vault/test/recent_signed_index_test.dart`（同收款人、同金額、輸入重疊、索引建立前的舊紀錄、超過 500 筆）；擴充 `apps/wallet/test/public_backup_merge_lifecycle_test.dart` |
| `MN-21` | 不建立 `to` 等於發送方的 EVM 交易；取消為 0 金額、付給另一個配對帳戶；建立請求、顯示 QR 與廣播前以 `eth_getCode` 查詢，查詢失敗不建立；結果寫成「所選來源回報」；發送方有委派時，對合約收款與所有 ERC-20 轉帳逐筆確認；自呼叫比較外層 `to`；Vault 在 `to` 等於簽署帳戶時警告，並標示本 Vault 的配對帳戶 | 新增 `apps/wallet/test/eip7702_delegation_test.dart`（附錄 F 的 F-32、F-51、F-58、F-67、委派標記解析、兩個 RPC 結果不同、收款地址有 code、廣播前再查一次）；擴充 `apps/vault/test/review_layout_test.dart`（`to` 等於簽署帳戶的警告與勾選、「本 Vault 的帳戶 #n」標示） |
| 遷移 | 讀舊寫新、不降版、不預設主網、遷移前副本與還原 | 新增 `apps/wallet/test/account_store_migration_test.dart`（中斷後重跑、舊新檔並存、同名目標存在、未結算保留不遺失、同 fingerprint 不同公鑰、第 2.6 節第 5 點的舊狀態對照）；擴充 `apps/wallet/test/public_backup_test.dart`（保留所有網路的 EVM 紀錄） |

盤點 §3.3(b) 列出的「斷言主網必須被拒」測試：第 1–3、8 項在 Phase 1a 反轉；第 6 項（`packages/public_models/test/review_safety_test.dart:202-206`）在 Phase 0 隨 DTO 改用 `network_id` 改寫；第 7 項（`apps/wallet/test/bitcoin_flow_test.dart` 的「refuses non-regtest」）在 Phase 2a 改寫為「網路不符即拒」；第 4、5 項在 Phase 2b 反轉；第 10 項在 Phase 0 改寫；第 9 項（`tests/integration/test_g4_okx_closed_loop.py:668-690`，外層 11155111、內層 1 的偽造）與第 11 項（`crates/public_core/tests/sepolia_gas_floor.rs:77`、`:161` 的低 gas 例外必須失敗）**保留不變**。

### 11.2 對外發佈的最低閘門

任何交給持有人以外的人使用的建置（包括 Play 封閉測試），不論屬於哪一期，都必須先滿足：
1. 未稽核聲明出現在第 10.3 節所列位置；隱私權政策已就該期啟用的功能更新（第 13 節）。
2. 使用正式簽章金鑰；`verify_qr_apks.py --tier release` 對上傳的 AAB 通過。
3. Data safety 與 Financial features declaration 和該期啟用的功能一致。
4. 該期啟用的能力所依賴的每個 **UNVERIFIED** 項目都已在出貨前查證並記錄（例如 Phase 1a 的 explorer 營運者標籤、Phase 2a 的 genesis 與 `outspend` 格式、BTC explorer 網址、BIP-21／BIP-72／BIP-321 參數、EIP-1898 的 block-hash 參數、`/utxo` 排除 mempool 花用者的行為、Phase 2b 的 base58check 版本位元組與 bech32m 常數、`use_info` 編碼），不能只留在總表。

各期的「可否單獨出貨」指通過此閘門後可進入封閉測試；正式上架需要 Phase 3。

### 11.3 Phase 0：網路參數化，行為不變

| 項目 | 內容 |
|---|---|
| 範圍 | `network.rs` 網路表：release 表 = Sepolia；BTC release 表為空；dev 表 = 1337、31337、Regtest，**另含 Sepolia USDC 與 DAI 地址在 1337、31337 上的代幣列**，以保留現行「只以地址查表」在本機鏈上的接受行為；刪除 `impl Default for PolicyEngine`；`NetworkBinding` 加入 `PreparedRequest`，sign 改以綁定分派；第 3.5 節的單一驗證函式（接受／拒絕集合不變）；刪除 `custom_verdict`；BTC prepare 改經網路表並綁定 `BtcSigningDomain`；`sign_psbt_p2wpkh` 改收綁定值並刪除推斷；刪除 Dart 傳入的 `network_hrp`；回應快取 key 改用綁定；明確的交易型態分派（拒絕集合不變，只改錯誤碼）；`build_multi_accounts_ur` 加入明確的網路參數（輸出 bytes 不變）；`crates/vault_ffi/src/lib.rs:266` 的寫死 `"bcrt"`；`ur_adapter` 解析 `use_info`（只解析不強制）；`wallet_ffi` BTC 函式原地加入 network 參數（名稱不變，Dart 與 Rust 同版出貨，附錄 E.1）；`dev-networks` feature 與兩個哨兵（第三輪審查已以既有產物確認 cdylib 會匯出上游的 `#[no_mangle]` 符號，Phase 0 以新產物再確認）；`tools/build_ios_core.sh:17` 補上 `--no-default-features`（C-21）；**現有所有建置腳本都帶 `dev-networks`**，所以產物行為與現在相同；`{app}_network_policy_json`；Dart 改從原生表取得網路、代幣與顯示字串（字串與現在相同，**不顯示 dev 橫幅**），刪除 Dart 代幣副本；`verify_qr_apks.py` 改寫（工具路徑、AAB、附錄 E 的逐字清單），以 `--tier dev` 執行，並以實際產物定稿附錄 E；評估 `bip32` 關閉預設 feature；`docs/threat-model.md` §1.2 Invariant 4 與 §8 新增兩列（後端不可信與隱私、第三方主網請求）。**不含任何資料遷移** |
| 主要檔案 | `crates/public_core/src/{network.rs,policy.rs,evm.rs,bitcoin.rs}`、`crates/signer_router/src/lib.rs`、`crates/vault_core/src/lib.rs`、`crates/vault_ffi/src/lib.rs`、`crates/wallet_ffi/src/{lib.rs,bitcoin_api.rs}`、`crates/ur_adapter/src/crypto_multi_accounts.rs`、四個 `Cargo.toml`、`tools/build_android_qr.ps1`、`tools/build_ios_core.sh`、`tools/release_checks/verify_qr_apks.py`、`packages/public_models/lib/src/review_model.dart`、`packages/design_system/lib/src/review_card.dart`、`apps/wallet/lib/services/node_rpc_client.dart`、`apps/wallet/lib/screens/scan_signature_screen.dart`、`apps/vault/lib/ffi/vault_ffi_service.dart` |
| 出貨標準 | (1) 現有測試全部通過，修改只限機械性的建構子與欄位改名；(2) 新增的「行為快照」測試以現有 fixture 語料列出每個請求在**每個公開入口**（UR 的 `Transaction`／`TypedTransaction`、直接 legacy／1559 FFI、PSBT）的接受／拒絕結果，包括 1337／31337 上的 Sepolia 代幣地址，Phase 0 前後逐筆相同；(3) `verify_qr_apks.py --tier dev` 通過，匯出集合完全等於附錄 E.3 的 Phase 0 dev 清單，且「多一個符號」「少一個符號」兩種負向測試都讓檢查失敗（附錄 E 的定稿條件）；(4) 模擬器上兩個 App 的畫面文字與現在相同 |
| 釘住的不變量 | `MN-01`（dev 模式）、`MN-02`、`MN-03`、`MN-06`（單一來源部分）、`MN-07`、`MN-18` |
| 可否單獨出貨 | **只供內部驗收**：Phase 0 的產物是 dev 層級，不適用第 11.2 節的對外發佈閘門，不進封閉測試；網路集合與資料格式與現在相同，可直接回到前一版 |

### 11.4 Phase 1a：EVM 主網（Ethereum、Arbitrum One、Polygon PoS）

| 項目 | 內容 |
|---|---|
| 範圍 | 網路表加入 `1`、`42161`、`137` 與 `421614`、`80002`；第 4.1 節上限（持有人 2026-10-20 決定）；第 5.2 節這五條鏈的代幣；Legacy 規則（`MN-04`）與 legacy gas 下限；Main 與 Test 的 256 bytes 與空 access list；原生幣與費用字串由 Rust 產生；ERC-20 收款人 EIP-55；`dec_string_to_be_bytes` 遇非數字報錯（`crates/public_core/src/evm.rs:600-609`）、preimage 中 `to` 的 hex 解碼失敗改為報錯（`:167`、`:425`）；**資料遷移**（第 2.4 節的 v2／v3 與遷移程序，含遷移前副本與還原）；EVM 的付款意圖、成員與資源（第 2.5 節、`MN-13`），含公開備份保留所有網路的 EVM 紀錄（C-09）與未結算的衝突集合；Wallet 每鏈 profile、HTTPS、不跟隨轉址、不顯示遠端本文、共用限流、儲存時核對 chain id；估價規則與 gas 欄位；刪除全域網路選擇器與匯入時覆寫 `chainId`；第 10 節的標示、dev 橫幅、首次主網警告、未稽核聲明；`PUBLIC_TEST_SEEDS`（EVM 部分）；**release 建置腳本改為不帶 `dev-networks`**，`verify_qr_apks.py --tier release`；BTC 在 release 中停用的行為（第 9.2 節第 9 點）；第 2.5 節模型的 EVM 部分（意圖、成員、證據與推導狀態、nonce 計算含 `L_local` 與 `latest` 異常跳升、唯讀 nonce 欄位、餘額預留、`status = 0`、單一來源規則、`unresolved` 與覆寫畫面），並修正表單變動取消已匯出成員與可自由輸入的 nonce（C-20）；第 4.6 節的 EIP-7702 偵測與政策（`MN-21`）；nonce 證據的質疑與更正（D-47）；收款內容與付款輸入的 EVM 語法（D-49）；D-53 全部（Vault `Main` 收款頁、還原預覽，以及兩個 App 上公開種子的 EVM 地址警告、不顯示 QR）；Vault EVM `Main` 審查頁的委派回呼揭露；explorer 營運者標籤與獨立性規則（D-51）；第 2.6 節的歷史完整性旗標、v1→v2 狀態對照、逐欄合併與 Vault 公開索引的提示（EVM）；第 2.7 節 EVM 結算層級，並逐鏈核對 `safe`／`finalized` 標籤的支援與語意；第 10.6 節 Vault 核對 EVM 收款地址；`KEEP-19` 的 App 內 URL 檢查（修正 C-22，若持有人要求可提前為 1.x 的獨立修正） |
| 主要檔案 | `crates/public_core/src/{network.rs,evm.rs,policy.rs}`、`crates/vault_ffi/src/lib.rs`、`crates/wallet_ffi/src/lib.rs`、`apps/wallet/lib/services/{node_rpc_client.dart,account_store.dart,transaction_history.dart,public_backup.dart}`、`apps/wallet/lib/screens/{account_screen.dart,send_tx_screen.dart,scan_signature_screen.dart}`、`packages/public_models/lib/src/review_model.dart`、`packages/design_system/lib/src/review_card.dart`、`apps/vault/lib/screens/{review_screen.dart,signed_result_screen.dart,vault_home_screen.dart}`、`apps/vault/lib/services/public_signed_result_store.dart`、`README.md`、`docs/threat-model.md` |
| 出貨標準 | 第 11.1 節所列 Phase 1a 測試全綠；遷移的回復演練一次（遷移、確認資料、匯出副本、以還原建置讀入；遷移後已有新成員時確認回復被停用）；第 11.2 節閘門；模擬器上 Sepolia、Arbitrum Sepolia 與 Amoy 的原生幣與 USDC 端到端成功，含故障代理的 EVM 情境（12.2）；三條主網的建立與驗證乾跑（12.3）；持有人在三條主網各完成一筆小額真實廣播（12.4） |
| 釘住的不變量 | `MN-01`（release 模式）、`MN-02`–`MN-06`、`MN-12`（EVM）、`MN-13`–`MN-16`、`MN-19`（EVM）、`MN-20`（EVM）、`MN-21`、遷移 |
| 可否單獨出貨 | **可以**。注意：release 建置從此不含 Regtest，BTC 在 release 建置中暫時不可用，直到 Phase 2a；dev 建置照舊 |

### 11.5 Phase 1b：OP Mainnet 與 Base

| 項目 | 內容 |
|---|---|
| 範圍 | 網路表加入 `10`、`8453`、`11155420`、`84532`；`OpStackL1DataFee` 模型、三行費用顯示與核准前確認；Wallet 在建立與廣播前呼叫 `GasPriceOracle.getL1Fee` 與 `getOperatorFee` 並核對餘額；Base 最低 base fee；這兩條鏈的代幣；Base 與 OP 設定分開、各自測試 |
| 主要檔案 | `crates/public_core/src/network.rs`、`apps/wallet/lib/services/node_rpc_client.dart`、`apps/wallet/lib/screens/{send_tx_screen.dart,scan_signature_screen.dart}`、`packages/public_models/lib/src/review_model.dart`、`packages/design_system/lib/src/review_card.dart` |
| 出貨標準 | `MN-05` 的 OP／Base 情境全綠；模擬器上 OP Sepolia、Base Sepolia 端到端成功；兩條主網乾跑；持有人小額真實廣播；第 11.2 節閘門 |
| 可否單獨出貨 | **可以**（在 1a 之後） |

### 11.6 Phase 2a：Esplora 後端，先在 signet／testnet4 驗證

| 項目 | 內容 |
|---|---|
| 範圍 | `BitcoinBackend` 介面；`EsploraBackend`；`BitcoinRpcClient` 成為 dev-only 實作；端點、genesis 與錯置地址檢查；BTC 的付款意圖、成員與資源（第 2.5 節），含修正 `newDraft` 把已匯出請求標成 `cancelled`（C-01，兩種後端）；`wallet_derive_btc_addresses_json`、index 上界、依序配置、高水位、探索／刷新／調解三種掃描、深度掃描（`MN-17`）；Rust 選幣（有效金額、QR 可行性、去 witness）；整數 sat/kvB 與 vsize；`TestTb` 費用上限；交易形狀規則（`MN-09`，含 dust 與 locktime）；刪除 `script:<hex>`（所有網路）、找零最多一個、多收款輸出顯示；測試網 key 匯出與 `use_info` 輸出、device 名稱；取代流程；QR 預算頁與單一大前置交易的限制說明；隱私與可信邊界揭露；網路表加入 Signet、Testnet4（release）；第 2.5 節模型的 BTC 部分，含族外交易 T 的驗證（第 2.5.4.1 節，含新的保留 witness 的有界解析器）、`rescue`（含較低費用的選項與後續成員規則，D-45、D-46）、多重引用與調解（PM-6）、存疑紀錄（D-48）與第 6.6 節的取消空間檢查（含跨集合總和）；收款內容嚴格子集與 Vault 單獨收款範圍（D-49、D-50）；第 2.7 節 BTC 結算層級與第二主機核對；第 2.6 節的 BTC 部分（含以交易歷史與 `outspend` 發現未知花費並以清除與它競爭，D-52；第 6.4 節第 9 點的 Vault 單獨範圍）；第 10.6 節 Vault 核對 BTC 收款地址（測試網） |
| 主要檔案 | `apps/wallet/lib/services/{bitcoin_backend.dart,esplora_backend.dart,bitcoin_rpc_client.dart}`、`apps/wallet/lib/screens/bitcoin_send_screen.dart`、`crates/wallet_ffi/src/bitcoin_api.rs`（選幣、派生、費率）、`crates/public_core/src/bitcoin.rs`（vsize、費率、形狀、dust、不可顯示輸出即拒）、`crates/vault_core/src/lib.rs`（index 上界）、`crates/ur_adapter/src/crypto_multi_accounts.rs` |
| 出貨標準 | `MN-08`（拒絕部分）、`MN-09`–`MN-12`、`MN-17`、`MN-19`、`MN-20` 測試全綠（含附錄 F 的 F-25、F-26、F-30）；模擬器上 signet 經 mempool.space 端到端，並以故障代理覆蓋每個恢復分支與說謊的後端（12.2）；testnet4 冒煙測試；第 11.2 節閘門 |
| 可否單獨出貨 | **可以**：BTC 只有測試網，但不再需要自架節點 |

### 11.7 Phase 2b：Bitcoin 主網

| 項目 | 內容 |
|---|---|
| 範圍 | 網路表加入 `Bitcoin`／`Mainnet` 域；Vault 匯出 `m/84'/0'/0'` 並帶 `use_info`；Wallet 解碼與驗證 `xpub` 帳戶；回應驗證的 path 依網路（取代 `crates/wallet_ffi/src/bitcoin_api.rs:343-354` 寫死的 `84'/1'/0'`）；P2WSH、P2TR、P2SH、P2PKH 的顯示與收款解析（向量與差分測試）；OP_RETURN 拒絕；主網費用上限；`PUBLIC_TEST_SEEDS`（BTC 部分）；主網結算的第二主機核對（若 `Q-14` 採用） |
| 主要檔案 | `crates/vault_core/src/lib.rs`、`crates/vault_ffi/src/lib.rs`、`crates/ur_adapter/src/crypto_multi_accounts.rs`、`crates/wallet_ffi/src/{lib.rs,bitcoin_api.rs}`、`crates/public_core/src/bitcoin.rs`、`packages/public_models/lib/src/review_model.dart`、`apps/wallet/lib/screens/bitcoin_send_screen.dart` |
| 出貨標準 | `MN-07`–`MN-12`、`MN-14`、`MN-17`、`MN-19` 測試全綠；Vault 核對主網收款地址已可用（第 10.6 節）；盤點 §3.3(b) 第 4、5 項已反轉；主網乾跑（12.3）；持有人小額真實廣播；第 11.2 節閘門。testnet 上端到端成功**不能**當作上述安全條件的證明 |
| 可否單獨出貨 | **可以**（在 2a 之後） |

### 11.8 Phase 3：上架

| 項目 | 內容 |
|---|---|
| 範圍 | 第 13 節全部項目；正式簽章金鑰（`docs/REMAINING_WORK.md` 的「發版與簽章 1」）；兩個 App 各自的封閉測試（若 Play Console 對持有人的帳號仍要求，`Q-09`）；Production 申請 |
| 與盤點的差異 | 盤點 Phase 3 的「外部安全稽核」依持有人決定移除，改為未稽核聲明；「實機驗收」依持有人決定改為模擬器覆蓋加 Play 封閉測試，其缺口列於第 12.6 節 |
| 出貨標準 | 第 13 節清單逐項完成；第 12 節的驗證紀錄齊全 |

---

## 12. 驗證計畫

### 12.1 單元與性質測試

- 第 11.1 節每個不變量都有對應測試，Phase 0 起列入發版檢查腳本（repo 沒有 CI）。
- 性質測試（`proptest` 作為 dev-dependency，版本實作時固定；resolver 2 下 dev-dependency 不會統一進 release 建置）：
  - 任意首位元組：只有該鏈允許的型態能進入解析器（`MN-03`）。
  - 任意輸出 script：結果只能是「可顯示的地址，且 `decode(encode(script)) == script`」或拒絕（`MN-08`）；另與參考實作做差分。
  - 簽章費用檢查對 `gas_limit`、`max_fee` 單調（`MN-05`）。
  - sat/kvB 解析與精確有理數運算結果一致；費率比較與精確比較一致（`MN-10`）。
  - 選幣：總額正確、實際序列化不超過 QR 預算、相同輸入得到相同結果（`MN-11`）。
  - 付款模型（`MN-12`）：推導狀態是（成員、未撤銷的證據、存疑紀錄、調解確認）的純函數，同一組紀錄以任意順序重算，結果相同；合法的本機事件只有建立成員（PM-1，寫入成功後才顯示 QR）、新增或撤銷證據、使用者覆寫、存疑或解除紀錄、調解確認與匯入；404 與其他模糊回應（PM-5）不改變任何推導結果；撤銷不會讓仍被可能上鏈的成員引用的資源變成 `free`（審查意見 Codex R4 Minor 2、Opus m4-13）。
- Rust 測試在開與不開 `dev-networks` 兩種設定下各跑一次。

### 12.2 Android 模擬器端到端

使用現有 Mac harness：arm64、16 KB 分頁的 AVD；以模擬器 gRPC `setEnvironment` 播放 QR 影片模擬相機；以 host 端擷取通過 `FLAG_SECURE` 的 Vault 畫面。Main 專屬的結構規則（256 bytes、空 access list）也套用在 Test，所以測試網端到端同時演練這些規則。

| 流程 | 建置 | 網路與後端 |
|---|---|---|
| EVM 配對、原生幣、USDC、廣播中途強制結束後恢復、取代 | release 層級 | Sepolia、Arbitrum Sepolia、OP Sepolia、Base Sepolia、Polygon Amoy；使用第 4.4 節的公開端點與測試幣 |
| EVM 說謊的 RPC | release 層級 | 故障代理模式：`pending` nonce 回到舊值、`latest` nonce 前進但 receipt 為 `null`、`latest` 被灌高（F-31）、以真實區塊捏造 nonce 消耗後換成誠實或真正落後的 RPC（F-42–F-44）、扣住交易並捏造取消的 receipt 與 `finalized`（F-27）、`eth_getCode` 回委派標記或查詢失敗（F-32）、廣播後逾時、HTTP 3xx、回應本文回顯帶 token 的 URL |
| BTC 配對、掃描、選幣、簽署、廣播、取代 | release 層級 | signet，經 mempool.space signet；在 Esplora 前面放故障代理（模式：正常、丟棄送出、送出後斷線、注入 404 與 HTML 429） |
| BTC 說謊的後端 | release 層級 | 故障代理模式分兩類。**可擋下**：轉發後回 `-22`、偽造 `outspend` 但取不到 T、T 的 witness 簽章無效、T 的 sighash 不是 ALL、偽造 UTXO（另一網路上付給同一 script 的交易）、缺少 `status` 欄位、區塊雜湊改變（模擬重組）、重組後同一輸入被兩個集合引用（F-26）、只有單一主機回報清除交易的深度（F-40）。期望：資源與結果不變、偽造的 UTXO 無法產生有效交易且可被捨棄或以 `rescue` 取回其他輸入、重組後依撤銷證據重新推導並進入調解。**無法獨立辨別**：有效的 T 加上偽造的深度——只驗證「第二主機不一致時不結算」 |
| BTC 冒煙 | release 層級 | testnet4，經 mempool.space testnet4 |
| BTC regtest 回歸 | dev 層級 | Bitcoin Core regtest（`txindex=1`）與既有故障代理 |

### 12.3 主網「建立與驗證」乾跑（不廣播）

- 使用專門的乾跑種子，**不是** `73C5DA0A`，也不是任何開發用金庫。乾跑種子**永久作廢**：絕不入金、絕不匯入任何正式 Vault、用完即從 Vault 抹除。理由：乾跑簽出的交易在該 nonce 或輸入被用掉之前永遠有效。
- EVM：以乾跑種子的**無餘額**地址，在每條主網用真實 RPC 取得 chain id、nonce、費率與 gas 估算（OP／Base 另呼叫 `GasPriceOracle`），Vault 簽署，Wallet 驗證簽章還原出的地址與 chain id。RPC 前面放代理拒絕 `eth_sendRawTransaction`。RPC 若因餘額不足拒絕 `eth_estimateGas`，記錄為驗證缺口，不改用預設值。
- BTC：需要真實 UTXO，使用持有人小額資金的帳戶；交易一律是**自我轉帳**到同帳戶下一個未使用的收款地址，萬一誤廣播只損失手續費。若持有人有自架 Bitcoin Core 節點，以 `testmempoolaccept` 驗證（Esplora 沒有對應的不廣播端點；`POST /txs/package` 為 **UNVERIFIED** 且會廣播，不使用）；否則只做本地 finalize 與簽章驗證。乾跑結束後，這筆已簽的自轉帳依第 2.5 節列為未結算的衝突集合，直到持有人廣播它或以另一筆交易花掉其輸入。
- 乾跑的已簽 hex 不寫入證據檔，只記錄 txid 與 SHA-256。

### 12.4 第一筆真實主網廣播

由持有人決定時機，以持有人自己的資金、極小金額，由持有人親自執行，不由 agent 執行。每個 Phase 各鏈一筆：1a 為 Ethereum、Arbitrum One、Polygon PoS；1b 為 OP Mainnet、Base；2b 為 Bitcoin。至少一條鏈另做一筆 USDC。記錄 txid 與 explorer 連結。

### 12.5 硬性規則

**任何主網資金都不得轉入公開的零熵測試金庫 `73C5DA0A`，也不得轉入開發期間使用過的任何測試錢包。**（No mainnet funds may ever be sent to the public zero-entropy vault `73C5DA0A` or any test wallet used during development.）第 10.4 節的清單只是防呆，這條規則不依賴它。

### 12.6 本驗證計畫**沒有**覆蓋的部分

持有人決定以模擬器加 Play 封閉測試取代實機驗收。下列項目因此沒有驗證：

1. 實體相機對相機的光學掃描（反光、對焦、低光、螢幕亮度、多幀 QR 在真實鏡頭下的讀取率）。模擬器播放的是乾淨影像。
2. 實體 ARM64 手機上的簽署、Android Keystore 實際行為、StrongBox／TEE、生物辨識（`docs/REMAINING_WORK.md` 的 P1 第 2 項）。ADR-003 的現況不能被當作已證實的硬體金鑰保護。
3. 各 OEM 的差異：Samsung 的 `FLAG_SECURE`、背景與省電策略、舊機型（Galaxy S8）效能（P1 第 3 項）。
4. 實機上 stock OKX 的簽章回傳與廣播（P1 第 4 項），以及 OKX 主網請求是否帶 access list 或 6 欄位 legacy。
5. 離線裝置的實際隔離：飛航模式、Wi-Fi／藍牙／NFC 關閉狀態下的操作，以及使用者是否真的把 Vault 放在不連網的手機上。Play 封閉測試者的 Vault 裝置是否離線，開發者無法觀察。
6. iOS 全部（`docs/REMAINING_WORK.md` 的 P2 第 6 項）；本期不發佈 iOS。
7. 真實網路環境：行動網路、DNS 汙染、TLS 攔截代理、地區封鎖、長時間的伺服器限流。
8. 長期金鑰保存：OS 更新、App 更新、加密庫跨版本、裝置更換後的恢復。
9. 實體攻擊、側通道、惡意 App 與 Vault 共存於同一實體裝置的情境。
10. 封閉測試者不是安全審查者；12 人、14 天的封閉測試只能發現使用與相容性問題，不能代替第三方稽核（因此需要第 10.3 節的聲明）。
11. 大額、多輸入、極端費率下的主網行為：真實廣播只做極小金額。
12. 真正惡意的後端：12.2 的故障代理只模擬已知的說謊方式；FCW 不驗證區塊標頭，結算仍信任所選伺服器（第 2.7 節）。
13. 主網資金落在 `1'` script 上時以測試網名義顯示的情況（第 2.2 節殘餘風險）。
14. 跨安裝的付款唯一性：資源保留只對這台 Wallet 擁有的歷史成立；舊備份、只靠種子恢復或兩台 Wallet 並用時，只能依第 2.6 節的旗標、清除交易與 Vault 提示降低風險。
15. L2 的 `safe`／`finalized` 標籤語意與各鏈 RPC 的支援情形（第 2.7 節，UNVERIFIED，Phase 1a／1b 逐鏈核對）。
16. EIP-7702 委派的偵測依賴 RPC 的 `eth_getCode`；單一 RPC 可以隱瞞委派（第 4.6 節）。
17. 在其他工具以非 `SIGHASH_ALL` 簽出、已上鏈的族外交易，FCW 不承認（第 2.5.4.1 節）。
18. 覆寫所用 explorer 的獨立性只依營運者標籤判斷；自訂端點無法判定（第 2.5.4.2 節）。
19. 發送方帶 EIP-7702 委派時，收款合約回呼造成的資產流出，FCW 只能揭露、不能阻止（第 4.6 節）。
20. FCW 無法證明沒有未見過的已簽支出（被淘汰、被取代或被重組的入金，非原子的 chain／mempool 讀取，或主機隱藏的輸出）；「歷史可能不完整」只能由使用者全面確認解除，殘餘的重複付款風險由使用者承擔（第 2.6 節第 3 點）。

---

## 13. 發版與 Google Play

除另註外，下列要求取自 facts §7（存取日 2026-10-20）。Data safety 的分類是 facts 依 Google 定義所做的**推論**，Google 沒有直接談錢包地址、xpub 或自訂 RPC 的官方文字（**UNVERIFIED**）。

| 項目 | 要求 | 本專案現況與動作 |
|---|---|---|
| Target API | 2026-08-31 起新 App 與更新都必須 target API 36；可申請延到 2026-11-01（兩個來源） | `targetSdk = flutter.targetSdkVersion`（`apps/wallet/android/app/build.gradle.kts:40`、`apps/vault/android/app/build.gradle.kts:40`）。Phase 3 前以固定版本的 Flutter 確認實際值 ≥ 36；新 App 不依賴展延 |
| 16 KB 分頁 | targetSdk ≥ 35 且含 native code 的 App 必須支援；Help Center 列為現行要求，dev 文件寫 2027-02-01 起封鎖更新（日期 **UNVERIFIED**，兩頁說法不一） | Flutter engine 與 Rust `.so` 都是 native code，必定適用，視為現在就必須符合。`tools/build_android_qr.ps1:7` 預設 NDK `27.0.12077973`；facts 指 NDK r28 起預設 16 KB 對齊（單一來源 **UNVERIFIED**）。動作：升到 r28 以上，或對 Rust 目標明確加上 `-Wl,-z,max-page-size=16384`；發版閘門對上傳的 AAB 以 bundletool 產生的每個 APK 執行 `zipalign -v -c -P 16 4`，並以 `llvm-readelf -l` 檢查每個打包 `.so`（含 Flutter engine 與第三方程式庫）的 `PT_LOAD` 對齊 ≥ 16 KiB，再於 16 KB 分頁的 AVD 實際載入（第 3.4 節）。`zipalign` 只檢查 zip 對齊，不能證明 ELF 對齊 |
| AAB 與 Play App Signing | 新 App 必須用 AAB；最終 APK 由 Google 持有的金鑰簽名 | 在說明頁公布 Google app signing key 指紋，讓使用者可核對；`verify_qr_apks.py` 的 `signing` 欄位（`:77`）改為記錄實際簽章身分；稽核對象改為上傳的 AAB（第 3.4 節） |
| Data safety（Wallet） | 所有上架 App（含封閉測試軌道）都要填；「資料傳出裝置」即算「收集」，不論送到開發者或第三方伺服器 | 申報收集：地址與交易紀錄（送往 Esplora／RPC）。推論的分類：Financial info → Purchase history 及／或 Other financial info；用途 App functionality；必要；**不主張 ephemeral**（第三方是否記錄無法保證）。是否構成 Sharing：預設伺服器可主張 user-initiated 或 service provider，但 App 內須明確揭露（第 10.5 節）。「傳輸中加密」只有在所有傳出資料都加密時才能勾；`KEEP-19` 允許區域網路上的 `http` 節點，所以申報為**否**（`Q-21` 已決定）。若啟用主網結算的第二主機核對（`Q-14`），第二主機同樣列為接收方。無帳號、無 analytics，不填 Account management、Analytics |
| Data safety（Vault） | 同上，即使不收集也要填 | Vault 無網路權限（`KEEP-18`），申報不收集任何資料 |
| Privacy policy | 所有 App 都必須在 Play Console 填連結，且 App 內要有連結或全文；公開、非 PDF、不可編輯；須含開發者資訊與聯絡方式、資料保存與刪除政策、標明為隱私權政策、列出商店頁上的開發者或 App 名稱 | 內容要點：哪些資料會送出（地址、gap-limit 掃描的整串地址、廣播時的已簽交易、IP）；送到哪裡（預設 mempool.space、使用者選擇的 RPC 主機、使用者自訂伺服器）；開發者不經營任何伺服器、不收集 analytics；開發者不保存資料，第三方依其政策保存；本機資料（帳戶、歷史、公開備份）與刪除方式（App 內刪除、解除安裝）；Vault 完全離線。Vault 無法開啟網頁，**App 內嵌全文** |
| Financial features declaration | 所有上架 App（含封閉／公開測試）都必須填 | 勾選「Cryptocurrency wallet」；所有說明一致標示 non-custodial（私鑰只存在離線 Vault）。Help Center 16329703 寫明 non-custodial 錢包不在 Cryptocurrency Exchanges and Software Wallets 政策範圍內（Google 一手來源只有這一頁）；申報表是否詢問託管型態需登入 Play Console 確認（**UNVERIFIED**） |
| Blockchain-based Content 政策 | 不得在裝置上挖礦 | 不適用 |
| 封閉測試 | 2023-11-13 後建立的**個人**開發者帳號：至少 12 名測試者連續加入 14 天，才能申請 Production | `com.coldwallet.watch` 與 `com.coldwallet.vault`（`apps/*/android/app/build.gradle.kts:36`）是兩個 package，**各自**都要跑滿。持有人表示帳號是可直接發佈的個人帳號（「個人直通帳號」，`Q-09`，2026-10-20）；建立 App 時在 Play Console 核對正式發佈是否仍需這項封閉測試，需要時照本列執行 |
| 商店文案 | — | 第一行即「未經第三方安全稽核，請先小額使用」；標示 non-custodial；不使用「安全」「已稽核」等宣稱；測試網路明確標示為測試用途 |
| Android developer verification | 2026-09-30 起在巴西、印尼、新加坡、泰國生效；2027 年全球擴大（時程 **UNVERIFIED**） | 若 Vault 另以 Play 以外管道發佈，須在 Play Console 或 Android Developer Console 註冊 package 與簽章金鑰 |
| 發版簽章 | — | `docs/REMAINING_WORK.md` 的「發版與簽章 1」是 Phase 3 前提 |

---

## 14. 開放問題與已否決方案

### 14.1 持有人的決定（2026-10-20 全部決定）

**持有人已於 2026-10-20 決定下列全部事項**：每一項都採用本節的建議值；`Q-09`、`Q-12` 另有補充（見表）。各項原本的答覆期限保留，供排程參考（「1a 前」指 Phase 1a 開工前，依此類推。審查意見 Opus m3-13）。

1. **費用上限（`Q-01`，1a 前：EVM 三條主網；1b 前：OP、Base；2a 前：`TestTb`；2b 前：BTC 主網）**，建議值與理由：**決定（2026-10-20）：採用建議。**
   - Ethereum `max_signed_fee_wei`：建議 **0.02 ETH**（第一版為 0.01）。理由：Glamsterdam 上主網後，轉 ETH 到新地址的估算約 207,391 gas（Sepolia 實測，facts §4.2），依第 4.3 節乘 1.2 並向上取整得 248,870 gas（推算值）；0.01 ETH 只容許約 40 gwei 的 maxFee，因為 `maxFee = 2 × baseFee + tip`，baseFee 超過約 20 gwei 就會在壅塞時擋下所有轉給新地址的交易。0.02 ETH 約容許 80 gwei；在 500,000 gas 時為 40 gwei。目前實測 baseFee 0.106 gwei。這是費用防線，不是便宜費用的保證。
   - Arbitrum One：**0.002 ETH**（2,000,000 gas 時單價上限 1 gwei；最低 gas price 目前為 0.02 gwei，ArbOS 61 起營運方可在 0.01–0.10 gwei 間調整）。
   - OP Mainnet、Base：`max_signed_fee_wei` **0.002 ETH**；`extra_fee_estimate_ceiling_wei` **0.0001 ETH**（對 facts 的樣本，R 約為 OP `getL1FeeUpperBound(150)` 的 29,900 倍、Base 的 49,800 倍；這只是 Wallet 的估價門檻，不是任何保證，第 4.3 節）。
   - Polygon PoS：**1 POL**（500,000 gas 時單價上限 2,000 gwei；實測 base fee 128–253 gwei）。
   - Bitcoin 主網與 `TestTb`：**100,000 sat** 與 **200 sat/vB**。代價：1 進 2 出交易在 200 sat/vB 約 28,200 sat，可用；64 個輸入的整併交易約 4,400 vB，只能用到約 22.7 sat/vB。改成 200,000 sat 是不同的取捨，不能消除第 7 點的取消問題。
   - 測試網 EVM：0.05 原生幣。
2. **結算層級（`Q-13`，1a 前：EVM；2a 前：BTC 測試網；2b 前：BTC 主網）**：建議 BTC 主網深度 6（觀察到 12）、BTC 測試網深度 1；EVM 主網一律以 `finalized` 標籤結算，「nonce 被用掉」也以 `finalized` 量測；EVM 測試網以「已上鏈且再 1 個區塊」結算。**sequencer 信任**：建議不採用；若持有人希望 L2 的保留更快釋放，可為個別 L2 改用「安全」或「已上鏈」，代價是 L2 重組時付款結果可能顯示錯誤。RPC 不支援 `finalized` 的鏈不自動結算，使用者可在 explorer 核對後手動結算（第 2.7 節），不以固定區塊數代替。**決定（2026-10-20）：採用建議。**
3. **第二主機核對（`Q-14`，1a 前：EVM；2b 前：BTC 主網）**：建議 BTC 主網預設開啟，以 `https://blockstream.info/api/` 作第二主機；testnet4 沒有第二個官方主機；EVM 由使用者自行加第二個 RPC。依第 2.7 節的演算法，第二主機 404、逾時、落後或不一致都不結算。**沒有第二來源時**（EVM 只設一個 RPC，或使用者關閉 BTC 的核對），主網的結算結果只會是 `paid` 或 `unresolved`，取消與失敗都要使用者在 explorer 核對後覆寫（第 2.5.4 節的單一來源規則，審查意見 Opus R3-1）；這是本 ADR 的決定（D-41），持有人只決定是否在首次主網說明中建議加第二個 RPC（建議：是）。另一項決定：是否擴大到**主網 BTC 選幣前核對 outpoint 存在**（防偽造 UTXO；代價是第二主機也會看到 outpoint）——建議開啟。**決定（2026-10-20）：採用建議。**
4. **EIP-7702 委派帳戶（`Q-22`，1a 前）**：建議採第 4.6 節的政策：FCW 從不建立 `to` 等於發送方的交易，EVM 的 `cancel` 與清除是 0 金額、付給配對匯出的另一個 EVM 帳戶（所選來源須回報它沒有 code）；建立請求、顯示 QR 與廣播前都查 `eth_getCode`，查詢失敗不建立（fail-closed）；發送方被回報有委派時常駐警告，**原生幣送到被回報有 code 的地址，以及所有 ERC-20 轉帳，都要逐筆勾選回呼風險並長按確認**，送到被回報無 code 的地址為一般確認；Vault 在 `to` 等於簽署帳戶時警告並要求勾選，`to` 是本 Vault 的配對帳戶時加以標示，所有 EVM `Main` 審查頁另有一行與來源無關的委派回呼揭露（涵蓋第三方送來的請求）。替代方案：(a) 對合約收款只警告、不要求逐筆確認——代價是使用者可能略過警告；(b) 發送方有委派時拒絕所有交易——不建議：它不能消除既有委派的風險，只能避免部分由本次簽署觸發的條件，卻讓使用者無法移出資產。**決定（2026-10-20）：採用建議。**
5. **`latest` nonce 異常跳升（`Q-24`，1a 前）**：建議任何無法由本機已送出成員解釋的跳升都停止建立，要求使用者在與 RPC 不同營運者的 explorer 核對（第 2.5.3 節）。確認畫面只有兩個出口：「explorer 顯示的 nonce 等於 RPC」——只對沒有本機已送出成員的 nonce 存為使用者覆寫證據並計入 `L_local`，之後不再為同一段跳升提示，同時設「歷史可能不完整」（與 `Q-20` 的確認合併成同一個畫面）；「兩者不一致」——不建立，引導更換或加入 RPC。替代方案：只在跳升超過某個門檻（例如 10）時才要求確認——代價是在門檻內被灌高時，Wallet 會簽出一筆要等前面 nonce 才能上鏈的交易。**決定（2026-10-20）：採用建議。**
6. **質疑與更正消耗證據（`Q-26`，1a 前）**：使用者隨時可以質疑任何消耗證據，入口不受高度限制（第 2.5.4.3 節）；核對方式是第二來源，或使用者在 explorer 核對具體事實，兩者都必須與原證據來源及提出較低觀察的來源屬於已知且不同的營運者；撤銷本身也可以用同樣的核對更正（「恢復」事件）。持有人決定：是否允許只靠使用者的 explorer 核對完成撤銷或確認。建議：允許，記錄為使用者覆寫並隨備份保存。誤撤銷最壞是在已用掉的 nonce 上白簽一筆，或把 `paid` 翻回 `open`；不會讓 FCW 重用自己送出過的 nonce。不允許時，只設一個 RPC 的使用者遇到被捏造的消耗證據，只能加入第二個 RPC 才能恢復。**決定（2026-10-20）：採用建議。**
7. **費用上限與取消（`Q-18`，2a 前）**：建議採第 6.6 節「取消空間」的選項 1（匯出前檢查並要求確認）＋2（取代與取消可加入未保留的輸入）＋3（上限擋住時，使用者可送出原交易、等待或自行以其他工具處理），**不採用**選項 4（Vault 對純自轉帳放寬到 2 倍上限）。取捨：選項 4 可以讓更多取消成功，但被入侵的 Wallet 可以把它當成多燒一倍手續費的管道。**決定（2026-10-20）：採用建議。**
8. **資源救援（`Q-23`，2a 前）**：建議允許第 2.5.6 節的 `rescue`，且不強制「輸入確實被綁住」的前提（它也可以當成只花部分輸入的自轉帳，結果相同）：建立前全頁列出「會因此失效的成員」與「仍可能上鏈的成員」，寫明「原付款意圖維持未結算」，勾選並長按確認；Vault 顯示為「自轉帳」。費用預設依 PM-3；做不到時允許使用者明確選擇較低的費用，畫面寫明它與已送出的成員競爭、可能被拒收。救援集合只接受同一救援的取代，外部付款不能加入。若不允許 `rescue`，共同輸入只剩偽造輸入的集合會把後加入的真實輸入永久綁住，只能在產品外處理。**決定（2026-10-20）：採用建議。**
9. **Vault 單獨顯示收款地址（`Q-25`，2a 前）**：Wallet 不知道 Vault 單獨顯示過哪些地址（第 10.6 節）。建議：Vault 不經 Wallet 時只提供 BTC branch 0 的 index `0..=min(19, max_address_index)` 與 EVM 的配對帳戶，第 6.4 節第 9 點把它們固定納入完整刷新；更高的 index 只能經核對 Wallet 的收款內容找到。公開種子一律不顯示 `Main` 收款地址（D-53）。代價：Wallet 可能把 Vault 單獨顯示過的 index 再配給別的付款人，影響隱私與收款歸屬。替代方案：(a) 完全禁止 Vault 單獨顯示收款地址——最簡單，但付款人無法在 Wallet 不在場時直接掃 Vault；(b) 允許任意 index，並以 QR 把 Vault 的發出紀錄帶回 Wallet——需要新的 Vault → Wallet 傳輸格式，使用者忘了帶回時收款會看不見。**決定（2026-10-20）：採用建議。**
10. **BTC 位址 index 上界（`Q-15`，2a 前）**：建議 **1,000**（`0..=1000`）。深度掃描兩個 branch 共 2,002 個地址，依第 6.4 節的預算理想下限約 34 分鐘；1,000 個找零地址約等於 1,000 筆交易。用完後需另立 ADR 提高上界或開放第二個帳戶。**決定（2026-10-20）：採用建議。**
11. **公開備份是否包含未結算的已簽交易與證據（`Q-16`，1a 前）**：建議包含並在匯出時揭露（第 2.6 節）。**決定（2026-10-20）：採用建議。**
12. **「標為已放棄」（`Q-19`，1a 前）**：建議允許；效果只是不再觸發全頁確認，資源保留與監看不變（第 2.5.6 節）。BTC 不提供任何會釋放保留的手動「放棄」。**決定（2026-10-20）：採用建議。**
13. **解除「歷史可能不完整」（`Q-20`，1a 前）**：旗標只能以這項全面確認解除（第 2.6 節第 3 點）；合併備份與清除交易都只降低風險，不解除旗標。確認文字直接寫出殘餘風險：「如果我曾在其他裝置、其他工具或這份備份之後簽過付款，那些交易仍可能上鏈，現在的付款可能造成重複付款；FCW 無法檢查這件事」。建議允許：不允許時，換機或還原後的每一筆付款都要經過全頁說明。**決定（2026-10-20）：採用建議。**
14. **ADR-002 正式修訂（`Q-17`，2b 前）**：ADR-002 列出的 `rust-bitcoin =0.32.0`、`bip39 =3.0.0`、`alloy-primitives`／`alloy-rlp`／`alloy-consensus`、Keystone `ur-registry` 與 `flutter_rust_bridge` 都不在 `Cargo.lock` 或 `pubspec.yaml` 中（bip39 的需求為 `"2.1.0"`，lock 解析為 `2.2.2`；RLP 與 FFI 都是自寫）；D-17 又再自寫 bech32m 與 base58check。建議核准 ADR-002 的正式修訂，記錄「自寫元件＋獨立向量與差分測試」的原則。**決定（2026-10-20）：採用建議。**
15. 其餘事項見下表（`Q-02`–`Q-09`、`Q-11`、`Q-12`），同日決定。

**更早已決定的事項**：五條 EVM 主網與其官方測試網；Sepolia 系與 Amoy 在 release 中保留並標示為測試網；本機鏈與 regtest 只在 dev 建置；BTC 主網加 signet，testnet4 因 mempool.space 支援而納入（facts §5.1）；預設後端 mempool.space Esplora 並可自訂；Core RPC 只供 regtest、dev 與 harness；上線前不做外部稽核，改以「未經第三方安全稽核，請先小額使用」標示，這取代 `AGENT_WORK_PACKAGE.md:340` 的 `EXPERIMENTAL / TESTNET ONLY` 要求（原 `Q-10`，持有人已決定）；實機驗收改為模擬器加封閉測試。`http` 端點允許的主機（原 `Q-21`）：持有人授權 lead 決定，依 `KEEP-19`（loopback、區域網路私有位址、單一標籤與 `.local` 名稱，顯示未加密警告；release 與 dev 相同），代價是 Data safety 的「傳輸中加密」申報為「否」。`AGENT_WORK_PACKAGE.md:336` 的重新解讀（第 0 節）在持有人核准本 ADR 時生效。

| ID | 問題 | 決定（2026-10-20，持有人） | 原答覆期限 |
|---|---|---|---|
| Q-01 | 各鏈手續費上限（見上方第 1 點） | 採用建議值（每條鏈都用較緊的建議上限） | 1a／1b／2a／2b 前（逐鏈） |
| Q-02 | 是否收錄橋接或第三方代幣（USDC.e、USDT0、OP 舊橋接 USDT、Base USDT、非 Sky 的 DAI） | 不收錄；若收錄，使用第 5.3 節的區別名稱 | 1a 前 |
| Q-03 | OP Mainnet 的 USDS（`0x4F13…edC3`，**UNVERIFIED**）是否在取得第二來源後收錄 | 不收錄 | 1b 前 |
| Q-04 | 是否允許零金額 OP_RETURN 輸出（以 hex 與 ASCII 顯示內容） | 全部拒絕 | 2a 前 |
| Q-05 | 主網是否強制使用在主網版 Vault 上新產生的種子，或加入持久化的「Vault 主網模式」；兩者都需要 `crates/vault_core/src/storage.rs` 升版並修改 AAD（目前 `check_version` 只接受完全相同版本，`:79-87`） | 不強制；只做第 10.4 節的清單與每次解鎖的首次主網確認；首次主網說明提醒不要把種子匯入其他錢包（第 4.6 節） | 1a 前 |
| Q-06 | 是否允許花用自有的未確認找零 | 只用已確認 UTXO（現行） | 2a 前 |
| Q-07 | 是否支援 Tor 或 SOCKS 代理 | 不支援；提供自訂伺服器 | 1a 前 |
| Q-08 | dev 建置是否使用不同的 applicationId（例如 `.dev` 後綴）以便並存安裝；修改 applicationId 需持有人同意 | 不改；dev 與 release 共用現有 applicationId | 1a 前 |
| Q-09 | Play 開發者帳號是個人還是組織；兩個 App 是否都上 Play | 個人帳號，持有人表示可直接發佈（「個人直通帳號」）；建立 App 時在 Play Console 核對正式發佈是否仍需每個 App 12 人、14 天的封閉測試；需要時照原計畫執行封閉測試 | Phase 3 前 |
| Q-10 | （已決定，見上方） | — | — |
| Q-11 | BTC 是否採用防 fee sniping 的高度 locktime（Core 錢包作法；facts 標為單一來源） | Wallet 建立 `nLockTime = 0`；Vault 接受 0 或有效的高度 | 2a 前 |
| Q-12 | 開發期間用過、需列入 `PUBLIC_TEST_SEEDS` 的金庫 fingerprint 完整清單 | `73C5DA0A`、零熵 24 詞、`a82351a4`，以及已刪除的開發 QA 金庫 `467F1EFD` | 1a 前 |
| Q-13 | 逐鏈結算層級與 sequencer 信任 | 見上方第 2 點 | 1a／2a／2b 前 |
| Q-14 | 第二主機核對及是否擴大到選幣 | BTC 主網開啟（blockstream.info），含選幣核對；EVM 建議使用者加第二個 RPC | 1a 前（EVM）、2b 前（BTC） |
| Q-15 | BTC `max_address_index` | 1,000 | 2a 前 |
| Q-16 | 公開備份是否包含未結算的已簽交易與證據 | 包含並揭露 | 1a 前 |
| Q-17 | 核准 ADR-002 的正式修訂 | 建議核准 | 2b 前 |
| Q-18 | 費用上限與取消、加速的取捨 | 選項 1＋2＋3，不採用 4 | 2a 前 |
| Q-19 | 是否允許「標為已放棄」（不釋放保留） | 允許 | 1a 前 |
| Q-20 | 是否允許使用者以全面確認解除「歷史可能不完整」（唯一的解除方式） | 允許，確認文字寫明殘餘的重複付款風險 | 1a 前 |
| Q-21 | （已決定，見上方） | — | — |
| Q-22 | EIP-7702 委派帳戶的政策（第 4.6 節） | 不建立 `to` 等於發送方的交易；`eth_getCode` 偵測並 fail-closed；有委派時警告，對合約收款與所有 ERC-20 轉帳逐筆確認；Vault 在 `to` 等於簽署帳戶時警告；Vault 的 EVM `Main` 審查頁一律顯示與來源無關的委派回呼揭露 | 1a 前 |
| Q-23 | 是否允許 BTC 的資源救援（`rescue`）、是否強制前提、可否選較低費用 | 允許；不強制前提；可明確選較低費用；全頁列出失效與仍有效的成員、勾選並長按 | 2a 前 |
| Q-24 | `latest` nonce 異常跳升時是否一律要求確認，以及確認後的處理 | 任何無法解釋的跳升都停止；兩個出口；確認存為覆寫證據並計入 `L_local` | 1a 前 |
| Q-25 | Vault 不經 Wallet 時可顯示哪些收款地址 | BTC branch 0 的 index `0..=min(19, max_address_index)` 與 EVM 配對帳戶；公開種子不顯示 `Main` 地址 | 2a 前 |
| Q-26 | 使用者質疑消耗證據時，是否允許只靠不同營運者的 explorer 核對完成撤銷或確認 | 允許，記錄為使用者覆寫；撤銷可以用同樣的核對恢復 | 1a 前 |

### 14.2 已否決的方案

| 方案 | 否決理由 |
|---|---|
| 盤點策略 A：網路對所有資產都是一級參數，EVM 帳戶依網路各存一份 | 違反「EVM 地址與鏈無關」的實際模型；同一地址重複出現多次，UI 雜亂；遷移量最大（盤點估 80–100 檔、10,000 行以上）；與 OKX 的使用方式不一致 |
| 盤點策略 B：主網與測試網分成不同 App 或 flavor | 持有人要求 release 內保留測試網；需改 applicationId（需持有人同意）；Play 封閉測試從 2 個 package 變成 4 個，各需 12 人 14 天；仍需先完成網路參數化（等於 Phase 0），BTC 的儲存與備份仍需網路欄位 |
| 直接在 `PolicyEngine::default()` 加入 chain 1 | 兩端同時開放；無法讓 release 不含本機鏈 |
| 只用 Cargo feature 而保留執行期選擇，或只由 Dart 在執行期選表 | release 二進位仍含本機網路；選擇權落在不可信的 Dart 層 |
| `RUSTFLAGS` cfg 或環境變數切換 | `cargo tree` 不可見，難以稽核 |
| 把 L1 預留加進 Vault 的「總費用上限」（第一版作法） | 不限制鏈上實際收取的 L1 data fee 與 operator fee，只會製造一個不存在的保證（三位審查者一致指出） |
| Vault 自行計算 L1 data fee | Vault 離線，無法取得 L1 價格；OP 文件明確建議不要自行實作公式 |
| 動態下載代幣表或政策 | `AGENT_WORK_PACKAGE.md:336` 禁止（`KEEP-22`） |
| 未知代幣以原始數值顯示後允許簽署 | 違反 ADR-004 §2.3.4 與 WYSIWYS；正是 T1 要防的金額誤讀 |
| 以鏈上 `symbol()` 決定代幣名稱 | 橋接 USDC 的 `symbol()` 也是 `USDC`（facts §2.1） |
| segwit v0 輸入只帶 `witness_utxo` 以縮小 QR | CVE-2020-14199 手續費超付攻擊 |
| 以單一伺服器的 404、`transactionNotFound`、`outspend` 或 `-22` 釋放防重複付款的保留 | 單一伺服器不能證明不存在，也可能說謊；會造成重複付款（第 2.5.2 節 PM-5） |
| 以「收款地址相同」作為判定重試與否的閘門 | 交易所每次給新地址；ERC-20 收款人在 calldata；只能當輔助警告 |
| 把已匯出或已簽的請求封存為 `cancelled` 並釋放輸入 | Vault 可能已簽；已簽 bytes 仍有效（C-01） |
| 拒絕 6 欄位 legacy 與 `2d+35` 佔位格式（第一版 D-08） | 簽章已綁定 declared chain，沒有安全收益；現有測試與整合案例依賴此相容格式 |
| 寫死 21000 gas limit | Glamsterdam 後轉到新地址需要更多 gas，不足時交易照樣上鏈並扣費（facts §4.2） |
| 以 blockstream.info 為預設 BTC 後端 | 沒有 testnet4；官方已宣布免費層限流且未公布數字（facts §5.10）；只作為自訂端點與第二主機 |
| 引入完整 `bitcoin` crate 處理地址 | 為了顯示功能把另一版 `secp256k1` 與大量 API 帶進兩個 App；改以自寫元件加獨立向量與差分測試（`Q-17`） |
| 維持 sign 時由 PSBT 推斷網路 | 網路不在 prepare 時綁定；Signet／Testnet4／Regtest 共用 `1'`，推斷結果只能是猜測 |
| 保留全域網路選擇器 | T10：使用者無法確定自己在哪個網路 |
| 允許 `nVersion = 3`（TRUC） | 本產品不需要；多一套 mempool 規則的審查面 |
| 在 Phase 0 做資料遷移 | Phase 0 號稱可直接回到前一版，單向遷移會破壞這一點（審查意見 Opus I-11） |
| 以「任一保留 outpoint 被族外交易花掉」判定整個集合衝突並釋放（第二版） | 族外交易只花掉後加的輸入時，原成員仍有效（審查意見 Codex R2-B1） |
| 把取消交易的確認記為「已付款」，或把族外消耗記為「未付款」（第二版） | 資源被消耗與付款是否完成是兩件事（審查意見 Codex R2-B2） |
| 只以 txid 核對族外交易 T（第二版） | 沒有私鑰也能捏造 txid 相符的 T；必須驗證 witness 簽章（審查意見 Opus N-1、Argon NB-03） |
| EVM 一律以 12 個區塊結算（第二版） | 對 L2 沒有意義；改用 `finalized` 標籤（審查意見 Codex R2-I3、Argon NI-02） |
| 以區塊數代替不支援 `finalized` 的鏈（例如 Polygon 64／128 個區塊） | facts 沒有各鏈最終性資料；不支援時不自動結算 |
| 以 RPC 的 `pending` nonce 計算新 nonce（第二版） | 被灌高時帳戶永久卡死，過低時取代前一筆付款（審查意見 Opus N-3、Argon B-03） |
| 本地廢棄已匯出的請求並釋放其資源 | Wallet 無法得知 Vault 是否已簽；改為可不提高費用的取代（第 2.5.2 節 PM-3） |
| 會釋放保留的「放棄」、逾時自動解鎖、靜默提高上限 | 都可能讓仍有效的已簽交易與新付款同時上鏈 |
| 族外交易 T 的驗證支援 BIP-143 全部六種 sighash 類型（審查意見 Argon M3-02；Opus R3-3 的選項 (a)） | 需另寫 NONE、SINGLE、ANYONECANPAY 的 hashPrevouts、hashSequence、hashOutputs 規則與獨立向量，擴大攻擊面；FCW 只簽 ALL。代價（其他工具以非 ALL 簽出、已上鏈的 T 不被承認）寫在第 2.5.4.1 節，相關輸入可用 `rescue` 取回 |
| 重組後把引用同一資源的兩個衝突集合合併（審查意見 Opus m3-10） | 兩個集合的其他成員並不互相衝突，合併會破壞 PM-2「集合內兩兩衝突」的歸納，之後的取代也會被誤認為能同時作廢兩邊；改為資源多重引用加調解（PM-6） |
| 把以存疑理由捨棄、已沒有有效成員引用的輸入維持 `reserved`（審查意見 Argon M3-01） | 沒有有效成員的保留無法被任何證據釋放；改為 `free` 加存疑旗標，不會被自動選用 |
| 共同輸入只剩偽造輸入時，放寬 PM-2，讓只花真實輸入的成員加入原集合 | 新成員與原成員不衝突，會重新引入重複付款；改為不加入原集合、也不改變付款結果的 `rescue` |
| 以單一來源的取消結算，把意圖記為 `cancelled`（第三版） | 惡意 RPC 可以扣住原交易、捏造取消的 receipt 與 `finalized`，使用者會以為可以重付（審查意見 Opus R3-1） |
| 成功匯入備份即清除「歷史可能不完整」（第三版） | 再次匯入同一份舊快照也會「成功」；合併只能降低風險，不能證明完整（審查意見 Codex R3-I1） |
| 轉帳頁以 `pending` 取得、可自由輸入的 nonce（現行） | 可以在未簽的 nonce 之後填入下一個 nonce，繞過第 2.5.3 節（審查意見 Opus R3-4） |
| 發送方有 EIP-7702 委派時拒絕所有交易（`Q-22` 的替代方案） | 它不能消除既有委派的風險，只能避免部分由本次簽署觸發的條件，卻讓使用者無法移出資產 |
| 在救援結算前，讓外部付款沿用救援集合的輸入（「用 R 的資源付這筆新款」） | 新付款只與救援集合衝突，不與被救援集合中仍可能上鏈的成員衝突，兩筆付款可能同時上鏈（審查意見 Codex R4-B1、Opus I4-2）；救援結算後改經 PM-4(b) 另付 |
| 自動採用較低的 RPC nonce，或把所有較低回報都當成節點落後 | 前者在真正落後的節點上會重用 nonce；後者讓捏造的消耗證據永久墊高 `L_local`（審查意見 Codex R4-I2、GPT R4-B3）；高度只作自動診斷；使用者隨時可以質疑並更正（2.5.4.3） |
| 匯入時保證本機的 `free` 不會變回 `reserved`（第四版） | `free` 是推導結果，匯入補回的有效成員本來就要重建保留（審查意見 Codex R4-I1、GPT R4-I1、Opus I4-3） |
| 只比對付款連結中的字面地址就顯示「一致」 | 支援 BIP-72 的付款端會改讀遠端的付款請求（審查意見 GPT R4-B5）；改為只接受嚴格子集 |
| 允許 Vault 單獨顯示任意 index，並以 QR 把發出紀錄帶回 Wallet | 需要新的 Vault → Wallet 傳輸格式，使用者忘了帶回時收款看不見；改為限制在 Wallet 一定會刷新的 index 0–19（`Q-25`） |
| 以證據自報的高度決定使用者能否質疑消耗證據（第五版） | 高度可以和 nonce 一起偽造，誠實來源永遠追不上（審查意見 Codex R5-B1、GPT R5-I1）；高度只用於診斷，質疑入口隨時可用 |
| 以清除交易與覆蓋檢查自動或半自動解除「歷史可能不完整」（第三至六版的「窄確認」） | 任何主機查詢都無法證明沒有未見過的已簽支出：單一來源可以捏造清除的深度（GPT R4-B2）；`/utxo` 排除被 mempool 花用的輸出（GPT R5-B1）；入金被淘汰後重新廣播、chain 與 mempool 分開讀取都會讓兩個誠實主機一致漏掉（GPT R6-B1、R6-B2）；有歷史的帳戶條件又永遠不成立（GPT R6-I2、Opus I6-2）。改為只能由使用者全面確認解除（`Q-20`），清除只作資源與結算工具 |
| 「任何人本來就能呼叫委派程式，所以不是新增攻擊面」（第五版的說法） | 使用者簽出的交易可以提供攻擊者原本沒有的條件，例如 `tx.origin`（審查意見 GPT R5-I2） |
| 在嚴格的收款 QR 中加入 branch、index 參數 | 違反 D-49 的嚴格子集，付款人的錢包也看不懂；改由 Vault 在有界範圍內派生比對（審查意見 GPT R5-I4） |
| 以 `to = 自己、value = 0` 的交易取消 EVM 付款（第三版的隱含作法） | 帳戶有 EIP-7702 委派時會執行委派程式（審查意見 GPT 第三輪 B4）；改付另一個已配對、被回報沒有 code 的 EVM 帳戶（第五版） |

---

## 15. 現行程式已確認缺陷

以下是審查中提出、經本 ADR 作者在 `77758a8` 上逐一核對的現行程式問題，供排程修正；本 ADR 不修改程式。「1.x」指目前只支援測試網路的版本。

| ID | 問題 | 位置 | 對 1.x 的影響 | 對主網的影響 | 來源 | 修正於 |
|---|---|---|---|---|---|---|
| C-01 | BTC `newDraft` 把 `awaitingSignature`／`verified` 封存為 `cancelled`，其輸入不再被保留；`unknown` 在 Core 查無後也可封存 | `apps/wallet/lib/screens/bitcoin_send_screen.dart:552`、`:566-570`、`:63-68`、`:538-541` | regtest 上可能重複付款（測試幣） | 已簽交易仍有效時以不同輸入再付一次，重複付款 | Codex B1、Opus B-2、Argon B-03 | Phase 2a（第 2.5 節） |
| C-02 | Core 路徑的 `transactionStatus` 用 `getrawtransaction`，不會回負確認數；`confirmations < 0 → failed` 的分支接不到 | `apps/wallet/lib/services/bitcoin_rpc_client.dart:301-307`；`apps/wallet/lib/screens/bitcoin_send_screen.dart:520-524` | 衝突交易永遠不會顯示為失敗 | Core 只在 dev；此語意不得移植到 Esplora | Codex B3 | Phase 2a（dev 路徑不自動判定衝突） |
| C-03 | 宣稱自有的輸出 index 沒有上界；Wallet 的 `change_index` 也沒有上界 | `crates/vault_core/src/lib.rs:574-575`；`crates/public_core/src/bitcoin.rs:1136-1146`；`crates/wallet_ffi/src/bitcoin_api.rs:162`、`:237`；Dart 端從後端取得後原樣傳入，`apps/wallet/lib/screens/bitcoin_send_screen.dart:309-310` | 低（Core 依 descriptor range 追蹤） | 找零可被放到一般掃描找不到的位置 | Opus B-1、Codex I3 | Phase 2a（`MN-17`） |
| C-04 | Vault 對輸出金額沒有 dust 或 0 的下限；Wallet 只檢查收款 ≥ 294 與找零 | `crates/public_core/src/bitcoin.rs:1117-1159`；`crates/wallet_ffi/src/bitcoin_api.rs:175`、`:234-236` | 第三方 PSBT 的 0 sat 輸出可被簽署，交易被節點拒收 | 同左，並可能卡住付款 | Argon B-04 | Phase 2a（第 6.7 節） |
| C-05 | `version`、`lock_time`、`sequence` 既不檢查也不顯示 | `crates/public_core/src/bitcoin.rs:996` 起 | FCW 自建交易為固定值，無影響；第三方 PSBT 的這些欄位使用者看不到 | 同左 | Argon B-05、Codex I6 | Phase 2a（`MN-09`） |
| C-06 | BTC 審查頁頂端只顯示第一個收款地址（金額卻是全部外部輸出的總和）；找零欄位只取第一個 | `crates/vault_ffi/src/lib.rs:1407-1411`；`packages/public_models/lib/src/review_model.dart:578-579`、`:590-591`；`packages/design_system/lib/src/review_card.dart:44-60` | FCW 只建一個收款輸出，無影響 | 第三方多輸出 PSBT 的摘要具誤導性。**只是顯示問題**：完整輸出已逐列顯示（`review_card.dart:108-112`），公開結果以整份 PSBT 的 digest 綁定 | Argon B-06 | Phase 2a（第 8.2 節） |
| C-07 | 不經 UR 的 EVM 直接入口固定為帳戶 `#0`；`PreparedRequest.account_address` 實際存的是收款人 `tx.to` | `crates/vault_ffi/src/lib.rs:116`、`:919-921`、`:1015`、`:1242`、`:1674-1677`；`:903`、`:999`、`:1149`、`:1226`；`crates/signer_router/src/lib.rs:90` | **限制而非不一致**：顯示與簽署都是 `#0`，帳戶 `#1` 的請求經直接入口會得到 `#0` 的簽章，Wallet 驗證時失敗，不會造成損失；欄位名稱誤導 | 同左 | Argon B-07（部分） | Phase 0（第 3.5 節） |
| C-08 | Legacy 交易沒有 `gas_limit` 下限（type-2 有） | `crates/public_core/src/evm.rs:76-160`；對照 `:325-334` | 低於 intrinsic gas 的交易無效、不會上鏈（只浪費一次簽署）；通過 intrinsic 檢查但執行 gas 不足的交易會執行失敗並收費（測試幣）。Vault 的 21,000 下限只擋前者 | 同左（後者為真實手續費） | Argon I-01 | Phase 1a（第 4.2 節） |
| C-09 | 公開備份只匯出目前選擇網路的 EVM 紀錄；匯入時把 EVM 帳戶的 `chainId` 覆寫成目前網路 | `apps/wallet/lib/services/public_backup.dart:592-593`；`apps/wallet/lib/screens/account_screen.dart:488-490` | 切換 Sepolia／本機鏈後，其他網路的紀錄不在備份內 | 多鏈時遺失待查紀錄與防重複付款的保留 | Argon I-08 | Phase 1a（第 2.4 節） |
| C-10 | 原生幣金額與最高手續費寫死為 ETH；Rust 只產生 `"{} wei"` | `packages/public_models/lib/src/review_model.dart:90`、`:173`、`:188-193`；`packages/design_system/lib/src/review_card.dart:206`；`crates/public_core/src/policy.rs:104` | 只有 ETH 鏈，無影響 | Polygon／Amoy 的 POL 會被顯示為 ETH | Opus I-2、Codex I6 | Phase 1a（第 5.1 節） |
| C-11 | ERC-20 收款人以小寫顯示，原生轉帳以 EIP-55 顯示 | `crates/public_core/src/evm.rs:245`、`:519`；`crates/public_core/src/rlp.rs:81` | 輕微 | 不利於與 Wallet 逐字比對，增加 address poisoning 風險 | Opus M-11、Argon M-01 | Phase 1a |
| C-12 | gas limit 欄位最多 6 位數 | `apps/wallet/lib/screens/send_tx_screen.dart:340` | 無影響 | Arbitrum 的 2,000,000 無法輸入 | Codex（D-05 判定） | Phase 1a |
| C-13 | Vault 公開結果的 metadata 沒有網路；舊結果標籤把 `chainId == 0` 寫死為「Bitcoin regtest」 | `apps/vault/lib/services/public_signed_result_store.dart:59-65`、`:171-179`；`apps/vault/lib/screens/vault_home_screen.dart:797-799` | 目前只有 regtest，碰巧正確 | 主網結果顯示錯誤網路 | Argon I-09 | Phase 1a／2a |
| C-14 | Vault 預覽寫死 `"bcrt"`；還原預覽只顯示 `btc_account_0` | `crates/vault_ffi/src/lib.rs:266`；`apps/vault/lib/screens/vault_home_screen.dart:1748` | 無影響 | 主網使用者無法以預覽核對主網地址 | Opus M-4、Argon M-02 | Phase 0／2b |
| C-15 | 發版檢查只能在 Windows 執行、只檢查本機測試 APK，不檢查 AAB；dev 與 release 共用 `jniLibs` 輸出目錄；ADR-001 §2.2 的依賴與符號稽核未完整落實（`wallet_ffi` 解析到 `secp256k1 0.33.1`、`bip32 0.5.3`（含 `k256`、`pbkdf2`），檢查只看 `vault_` 前綴） | `tools/release_checks/verify_qr_apks.py:25-28`、`:31`、`:66-67`；`tools/build_android_qr.ps1:11` | Mac harness 無法執行檢查；可能打包舊的 `.so` | release 閘門不可靠 | Opus I-5、Codex I2 | Phase 0（第 3.4 節） |
| C-16 | 代幣表只以地址為 key，Sepolia 代幣地址在 1337／31337 上也被接受 | `crates/public_core/src/policy.rs:138` | 只在本機鏈，無實際影響 | 擴展到多鏈時會把一條鏈的代幣當成另一條鏈的 | Codex I9 | Phase 0／1a（第 5.1 節） |
| C-17 | RPC 錯誤訊息帶出完整 URL 與回應本文 | `apps/wallet/lib/services/node_rpc_client.dart:225`、`:232` | 本機 RPC 無敏感資訊 | 帶 API key 的 URL 外洩 | 盤點 R13、Codex I7 | Phase 1a（第 4.4 節） |
| C-18 | `dec_string_to_be_bytes` 靜默略過非數字；preimage 對 `to` 的 hex 解碼失敗會變成空值（等同合約部署） | `crates/public_core/src/evm.rs:600-609`、`:167`、`:425` | 目前輸入都是內部產生，無影響 | 日後若從外部字串呼叫會出錯 | 盤點 §1.2、Opus M-3 | Phase 1a |
| C-19 | ADR-002 與實際依賴不符（見 `Q-17`） | `docs/ADR/ADR-002-crypto-serialization-stack.md`；`Cargo.lock` | 文件誤導審查 | 同左 | Opus I-13、Codex Minor 6 | 持有人核准後修訂 |
| C-20 | EVM 表單一變動就把已匯出的請求標成 `cancelled`，其 nonce 不再保留；nonce 取自 RPC 的 `pending`，且欄位可自由輸入；現行沒有涵蓋 `accepted` 的 nonce 保留與衝突集合閘門 | `apps/wallet/lib/screens/send_tx_screen.dart:77-95`（`_invalidate()`）；`apps/wallet/lib/services/transaction_history.dart:94-101`（`cancelPending`）；`apps/wallet/lib/services/node_rpc_client.dart:93-94`、`send_tx_screen.dart:243`、`:256`（`pending`）；`:329-333`、`:674-675`（可編輯的 nonce 欄位） | Vault 可能已簽，之後以同一或下一個 nonce 再付一次；也可手動填入任意 nonce（測試幣） | 重複付款或意外取代 | Codex（第二輪）、Opus R3-4 | Phase 1a（第 2.5.3、4.5 節） |
| C-21 | iOS 建置腳本沒有 `--no-default-features`，檢查只看 `_${app}_init` 是否存在 | `tools/build_ios_core.sh:17`、`:27-28` | iOS 不在本期範圍 | iOS 上架前需比照第 3.4 節 | Opus（第二輪） | `--no-default-features`：Phase 0（第 3.3 節第 4 點）；`:27-28` 的檢查：iOS 上架前 |
| C-22 | Wallet 對任何主機都接受 `http://` 端點；Android 的 `network_security_config.xml` 不約束 `dart:io`，所以實際上沒有強制 HTTPS（依 play-writer 對 Flutter engine 3.47.2／3.41.3 的核對：`settings.h:167` 預設允許不安全連線，Android 從未傳入 `--disallow-insecure-connections`） | `apps/wallet/lib/screens/account_screen.dart:336-342`；`apps/wallet/lib/services/bitcoin_rpc_client.dart:53-58`；`apps/wallet/android/app/src/main/res/xml/network_security_config.xml:3-9`（無效的依據） | 使用者填入遠端 `http` 的 RPC／Core 節點時，地址、已簽交易與 Basic auth 帳密以明文傳輸，中間人可以竄改回應（謊報餘額、nonce、狀態） | 同左，另有帶 API key 的 URL 明文外洩；Data safety 的「傳輸中加密」不能申報。Vault 閘門仍阻止竊取資金 | lead 轉述 play-writer（第三輪） | 1.2.1（branch `play-121` 的共用 URL 規則函式）；本 ADR 的 `KEEP-19` |

---

## 後果評估 (Consequences)

### 正面影響 (Positive)
- 主網開放集中在一份編譯期網路表，Vault 與 Wallet 共用、release 與 dev 由產物檢查區分，審查者可以從表快照的 diff 看出每一次放寬。
- 修掉主網上最危險的幾類錯誤：代幣與原生幣單位誤讀（T1）、BTC 輸出盲簽（T2）、網路在 sign 時才推斷（T3）、BTC 無費率檢查（T4）、可能已簽或狀態不明時重複付款（T7、T9）、找零失聯（T13）。
- 防重複付款由一個模型（第 2.5 節）涵蓋兩種資產：資源狀態與成員有效性由證據推導、付款結果另記，族外花費必須通過簽章驗證，不依賴伺服器的否定回應；限制明寫為「只對本機擁有的歷史成立」（第 2.6 節）。
- EVM 可以先上線，BTC 獨立推進；每一期都可以單獨進入封閉測試。
- ADR-001 至 ADR-004 的保證全部保留，並有逐條測試（第 1.3、11.1 節）。

### 負面影響與代價 (Trade-offs)
- 執行期仍有網路分支（使用者在 release 內可選測試網），審查負擔高於「主網專用 App」。
- 保留規則會讓使用者在狀態不明時無法立刻「重新付一次」，只能取代或明確宣告另一筆付款；EVM 主網要等 `finalized`、BTC 主網要等 6 個確認才釋放。已送出且費用接近上限的交易可能無法在產品內取消（第 6.6 節）。
- OP Mainnet 與 Base 的 L1 data fee 與 operator fee 沒有任何簽章層的上限，只能揭露與在 Wallet 端估價。
- 結算信任所選伺服器的確認回報（沒有 SPV）。
- 主網只有單一來源時，取消與失敗不會自動結算，要使用者在 explorer 核對後覆寫；在其他工具以非 `SIGHASH_ALL` 簽出的族外交易不被承認，相關輸入只能以 `rescue` 取回。
- Phase 1a 起 release 建置不含 regtest，BTC 在 release 中暫時不可用，直到 Phase 2a。
- 每次新增或調整網路、代幣、上限都要改 Rust 表與快照並重新發版，不能遠端更新。
- 沒有外部稽核、沒有實機驗收；第 12.6 節列出的風險由持有人承擔，並以「未經第三方安全稽核，請先小額使用」對使用者揭露。
- 預設後端（mempool.space）與公開 RPC 會看到使用者的地址與 IP；只能揭露並提供自訂伺服器。
- 前置交易過大的 UTXO 無法以 QR 花用。
- EVM 的產品內取消需要另一個已配對、被回報沒有 code 的 EVM 帳戶；沒有時只能等待或在產品外處理。發送方帶 EIP-7702 委派時，每一筆合約收款與 ERC-20 轉帳都要逐筆確認；RPC 謊報「有 code」只會造成這類阻擋（DoS）。
- 單一 RPC 的 nonce 回報與本機證據矛盾時，帳戶停止新付款，直到第二來源或使用者核對後更正；被標記的來源在使用者解除標記或更換之前，不再單獨產生新的消耗證據。
- Vault 不經 Wallet 時只能顯示少數收款地址（`Q-25`）。
- 換機、還原或遷移後，「歷史可能不完整」只能由使用者以全面確認解除（`Q-20`）；在那之前每一筆付款都要經過全頁說明。FCW 無法證明沒有未見過的已簽支出，這個殘餘的重複付款風險由使用者承擔。
- 兩個 package 各需 14 天以上的封閉測試，拉長上架時程。

---

## 附錄 A：外部來源（存取日 2026-10-20，取自 facts 檔）

EVM 網路與 RPC：
- ethereum-lists chain registry：https://raw.githubusercontent.com/ethereum-lists/chains/master/_data/chains/ （`eip155-<id>.json`）
- EIP-155：https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-155.md
- EIP-2718：https://raw.githubusercontent.com/ethereum/EIPs/master/EIPS/eip-2718.md
- ethereum.org networks：https://ethereum.org/en/developers/docs/networks/
- Arbitrum chain info：https://docs.arbitrum.io/chain-info 、https://docs.arbitrum.io/llms-full.txt
- Arbitrum ArbOS 40／51／61：https://docs.arbitrum.io/run-a-node/arbos-releases/arbos40 、https://docs.arbitrum.io/run-a-node/arbos-releases/arbos51 、https://docs.arbitrum.io/run-a-node/arbos-releases/arbos61 ；https://docs.arbitrum.foundation/network-upgrades ；https://forum.arbitrum.foundation/t/30942
- Nitro ArbSys：https://github.com/OffchainLabs/nitro/blob/master/precompiles/ArbSys.go
- OP networks：https://docs.optimism.io/op-mainnet/network-information/connecting-to-op 、https://docs.optimism.io/llms-full.txt 、https://docs.optimism.io/op-stack/protocol/network-upgrades.md
- OP specs：https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/isthmus/overview.md 、https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/jovian/exec-engine.md 、https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/karst/overview.md
- superchain-registry PR #1212（Base 移出）：https://github.com/ethereum-optimism/superchain-registry/pull/1212
- Base：https://docs.base.org/get-started/connect-to-base 、https://docs.base.org/llms-full.txt 、https://docs.base.org/specifications/transactions/network-fees.md 、https://docs.base.org/upgrades/overview.md 、https://docs.base.org/specifications/base-transactions.md 、https://github.com/base/base/releases
- Polygon：https://docs.polygon.technology/pos/reference/rpc-endpoints 、https://docs.polygon.technology/llms-full.txt 、https://docs.polygon.technology/pos/concepts/tokens/pol 、https://github.com/0xPolygon/bor/blob/master/params/protocol_params.go 、https://github.com/0xPolygon/bor/blob/master/params/config.go 、https://forum.polygon.technology/t/21331 、https://gasstation.polygon.technology/v2
- Explorer 路徑 ERC-3091：https://raw.githubusercontent.com/ethereum/ERCs/master/ERCS/erc-3091.md

L1 升級：
- EIP-7607（Fusaka）：https://github.com/ethereum/EIPs/blob/master/EIPS/eip-7607.md ；EIP-7825：https://github.com/ethereum/EIPs/blob/master/EIPS/eip-7825.md
- EIP-7773（Glamsterdam）：https://github.com/ethereum/EIPs/blob/master/EIPS/eip-7773.md ；EIP-2780：https://github.com/ethereum/EIPs/blob/master/EIPS/eip-2780.md ；EIP-8037：https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8037.md
- EF 部落格：https://blog.ethereum.org/en/2026/10/16/glamsterdam-hoodi-announcement 、https://blog.ethereum.org/en/2026/08/24/glamsterdam-repricing-testing 、https://blog.ethereum.org/en/2026/09/07/protocol-hegota-eips
- EIP-8081（Hegotá）：https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8081.md ；EIP-8141：https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8141.md ；Base AA 交易 EIP PR：https://github.com/ethereum/EIPs/pull/12385

代幣：
- Circle USDC：https://developers.circle.com/stablecoins/usdc-contract-addresses
- Tether：https://tether.to/en/supported-protocols/ 、https://app.tether.to/transparency.json
- USDT0：https://docs.usdt0.to/technical-documentation/deployments
- Sky：https://chainlog.sky.money/api/mainnet/active.json 、https://developers.skyeco.com/guides/skylink/base-eth-native-bridge/ 、https://developers.skyeco.com/protocol/tokens/dai/ 、https://github.com/sky-ecosystem/arbitrum-dai-bridge 、https://github.com/sky-ecosystem/optimism-dai-bridge
- Arbitrum USDC：https://docs.arbitrum.io/arbitrum-bridge/usdc-arbitrum-one ；Polygon mapped tokens：https://docs.polygon.technology/pos/reference/mapped-tokens
- Superchain token list：https://github.com/ethereum-optimism/ethereum-optimism.github.io/tree/master/data/ 、https://static.optimism.io/optimism.tokenlist.json
- Uniswap default token list：https://tokens.uniswap.org

Esplora：
- Esplora API：https://raw.githubusercontent.com/Blockstream/esplora/master/API.md
- mempool.space API 文件：https://raw.githubusercontent.com/mempool/mempool/master/frontend/src/app/docs/api-docs/api-docs-data.ts
- mempool electrs：https://raw.githubusercontent.com/mempool/electrs/mempool/src/rest.rs
- Blockstream electrs：https://raw.githubusercontent.com/Blockstream/electrs/new-index/src/rest.rs
- mempool 後端：https://raw.githubusercontent.com/mempool/mempool/master/backend/src/api/bitcoin/bitcoin.routes.ts
- Bitcoin Core broadcast：https://raw.githubusercontent.com/bitcoin/bitcoin/master/src/node/transaction.cpp
- Blockstream 限流公告：https://blog.blockstream.com/enhanced-analytics-and-infrastructure-improvements-for-the-blockstream-explorer-api/

PSBT 與 Bitcoin Core 政策：
- CVE-2020-14199：https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2020-14199
- BIP-174：https://raw.githubusercontent.com/bitcoin/bips/master/bip-0174.mediawiki ；BIP-370：https://raw.githubusercontent.com/bitcoin/bips/master/bip-0370.mediawiki ；BIP-371：https://raw.githubusercontent.com/bitcoin/bips/master/bip-0371.mediawiki ；BIP-341：https://raw.githubusercontent.com/bitcoin/bips/master/bip-0341.mediawiki ；BIP-125：https://raw.githubusercontent.com/bitcoin/bips/master/bip-0125.mediawiki
- Bitcoin Optech 2020-06-10：https://bitcoinops.org/en/newsletters/2020/06/10/ ；Ledger LSB 010：https://donjon.ledger.com/lsb/010/
- Trezor：https://raw.githubusercontent.com/trezor/trezor-firmware/main/core/CHANGELOG.md ；BitBox02：https://raw.githubusercontent.com/BitBoxSwiss/bitbox02-firmware/master/src/rust/bitbox02-rust/src/hww/api/bitcoin/signtx.rs ；Ledger：https://raw.githubusercontent.com/LedgerHQ/app-bitcoin/develop/src/handler/sign_psbt/preprocess_inputs.c ；Coldcard：https://raw.githubusercontent.com/Coldcard/firmware/master/shared/psbt.py ；Jade：https://raw.githubusercontent.com/Blockstream/Jade/master/main/process/sign_psbt.c
- Bitcoin Core release notes 28.0／29.0／30.0／31.0：https://raw.githubusercontent.com/bitcoin/bitcoin/master/doc/release-notes/release-notes-28.0.md 、https://raw.githubusercontent.com/bitcoin/bitcoin/master/doc/release-notes/release-notes-29.0.md 、https://raw.githubusercontent.com/bitcoin/bitcoin/master/doc/release-notes/release-notes-30.0.md 、https://raw.githubusercontent.com/bitcoin/bitcoin/master/doc/release-notes/release-notes-31.0.md ；Core wallet：https://raw.githubusercontent.com/bitcoin/bitcoin/master/src/wallet/spend.cpp

Google Play：
- Target API：https://support.google.com/googleplay/android-developer/answer/11926878 、https://developer.android.com/google/play/requirements/target-sdk
- 16 KB：https://developer.android.com/guide/practices/page-sizes 、https://support.google.com/googleplay/android-developer/answer/17492799 、https://android-developers.googleblog.com/2025/05/prepare-play-apps-for-devices-with-16kb-page-size.html
- AAB 與 Play App Signing：https://developer.android.com/guide/app-bundle 、https://support.google.com/googleplay/android-developer/answer/9842756
- Data safety：https://support.google.com/googleplay/android-developer/answer/10787469 、https://developer.android.com/guide/topics/data/collect-share
- Financial features 與加密貨幣政策：https://support.google.com/googleplay/android-developer/answer/13849271 、https://support.google.com/googleplay/android-developer/answer/9876821 、https://support.google.com/googleplay/android-developer/answer/16329703 、https://support.google.com/googleplay/android-developer/answer/13607354
- Privacy policy（User Data）：https://support.google.com/googleplay/android-developer/answer/10144311
- 封閉測試：https://support.google.com/googleplay/android-developer/answer/14151465 、https://support.google.com/googleplay/android-developer/answer/9845334 、https://android-developers.googleblog.com/2023/11/ensuring-high-quality-apps-on-google-play.html
- Developer verification：https://developer.android.com/developer-verification

## 附錄 B：對主網盤點（基準 `97eafba`）的更正

盤點的程式碼敘述在本基準 `77758a8` 逐條核對過，Rust 部分全部相符（`97eafba..77758a8` 之間 `crates/` 沒有變更）。以下是已過時或需修正之處：

| 盤點位置 | 盤點內容 | 現況 |
|---|---|---|
| §2.5、§4.1、R5、已知缺陷 4 | 找零固定 `change_index: 0`（`bitcoin_send_screen.dart:314`） | 已由 `de8a77e` 修正：`unusedChangeIndex`（`apps/wallet/lib/services/bitcoin_rpc_client.dart:203`），呼叫點在 `apps/wallet/lib/screens/bitcoin_send_screen.dart:309-318`。R5 只剩「選幣用全部 UTXO」一半 |
| §2.7 第 270 行、已知缺陷 1 | 重新匯入遇到較大的既有 descriptor range 會失敗 | 已由 `953bd1e` 修正（保留節點既有 range） |
| §1.6、已知缺陷 9 | BTC 簽署結果顯示「原始 Chain ID：0」 | 已由 `5a8135a` 修正：PSBT 結果不顯示該列（`apps/vault/lib/screens/signed_result_screen.dart:143-147`） |
| §1.6、§2.6、§3.4 | `review_card.dart:55-58`、`:216-227` | 行號已移到 `packages/design_system/lib/src/review_card.dart:65-66`、`:231-240` |
| §3.4 | `vault_home_screen.dart:788-791`、`:1086`、`:1901` | 行號已移到 `apps/vault/lib/screens/vault_home_screen.dart:797-799`、`:1147`、`:1993` |
| §6 Phase 3 | 「外部安全稽核」為發版前提 | 持有人決定不做；改為未稽核聲明（第 10.3 節） |
| §1.1 | BTC 閘門只列 `vault_ffi:1393` 等 | 補充：BTC prepare 完全不經 `PolicyEngine`，而是直接建構 `Approved`（`crates/vault_ffi/src/lib.rs:1418-1423`），所以 BTC 的上限與網路必須另外接到網路表（第 3.5 節） |
| §3.5 | OKX BTC BLOCKED 的敘述在 `generate_g6_evidence.py:47-58`、`:135-149` | `BLOCKED_CASES` 與理由在 `tools/release_checks/generate_g6_evidence.py:53-58` |

另：ADR-002 列出的 `rust-bitcoin =0.32.0` 與 `bip39 =3.0.0` 與實際 `Cargo.toml` 不符（盤點 §2.1 說「沒有使用 bitcoin crate」是正確的）。這是 ADR-002 的問題，不是盤點的錯誤；本 ADR 以實際依賴為準。

## 附錄 C：本 ADR 自行作出的決定（供審查集中挑戰）

「變動」欄標示第一輪（第二版）、第二輪（第三版）、第三輪（第四版）、第四輪（第五版）與第五輪（第六版）審查後的處理。

| ID | 決定 | 所在章節 | 變動 |
|---|---|---|---|
| D-01 | coin type `1'` 在 release 綁定 `TestTb`、在 dev 綁定 `Regtest`（dev 可改設定）；Vault 不嘗試分辨 signet 與 testnet4 | 2.3 | 第二版補殘餘風險（2.2） |
| D-02 | 帳戶遷移絕不把任何帳戶的預設網路設成主網 | 2.4 | — |
| D-03 | 舊 BTC 帳戶標為 `regtest`，release 中不可操作並提示重新配對，不自動改標為 signet | 2.4、9.2 | — |
| D-04 | 政策分割採「刪除 `Default` + 明確建構子 + 非預設 `dev-networks` feature（`public_core` 定義並在其內選表與放哨兵，兩個 FFI 只轉發）+ 兩端同開同關 + 產物稽核」 | 3.3、3.4 | 第二版改稽核對象；第三版改為完整匯出允許清單（D-35）；第四版依產物確認兩個哨兵都可用 |
| D-05 | Arbitrum 的 Wallet gas limit 合理上限 2,000,000，其他鏈 500,000 | 4.1、4.3 | 第二版一併修正 gas 欄位位數 |
| D-06 | 未簽交易 ≤ 256 bytes，適用 Main 與 Test；DevLocal 不限 | 4.1、4.3 | 第二版由 512 收緊並擴及 Test |
| D-07 | type-2 access list 必須為空，適用 Main 與 Test | 4.1、4.3 | 第二版擴及 Test |
| D-08 | Legacy 未簽：declared 必須非 0；9 欄位接受 `v ∈ {d, 2d+35, 2d+36}` 且 `r`、`s` 為空；6 欄位保留 | 4.2 | 第二版改回保留相容格式 |
| D-09 | 手續費大於轉帳金額 10% 時多一個確認畫面（不阻擋）；BTC 以外部輸出總額為分母，「外部」= 未通過自有派生驗證 | 4.3、6.6 | 第三版定義「外部輸出」 |
| D-10 | 估價不呼叫額外第三方；Ethereum、Polygon 與 Arbitrum 的 tip 用 `eth_feeHistory` 第 50 百分位，Polygon 另取 25 gwei 下限 | 4.1、4.3 | 第三版把 Arbitrum 改用 `eth_feeHistory`（`eth_maxPriorityFeePerGas` 實測回 0，ArbOS 61 起會收 tip） |
| D-11 | 不靜默套用任何 RPC 預設；官方端點以一鍵選用呈現；Polygon 只提供官方文件列出的第三方 dRPC 選項 | 4.4 | — |
| D-12 | 保留現有 Sepolia DAI 模擬合約，Phase 1 起改名為「DAI（Sepolia 模擬）」 | 5.2 | — |
| D-13 | 未知代幣 fail-closed，不提供原始數值顯示 | 5.4 | — |
| D-14 | 同一主機共用限流器與每分鐘預算；初始併發 ≤ 2、間隔 250 ms、每分鐘 ≤ 60、首次 429 後預算減半；退避 2–32 秒最多 6 次；進度持久化、可取消、可換端點續掃 | 6.4 | 第三版加每分鐘預算、減半、取消與續掃；第四版加減半後的恢復條件 |
| D-15 | 選幣在 Rust：有效金額 BnB，再由大到小累加；QR 可行性以實際序列化為硬條件；前置交易去 witness；候選數量有界；可重現排序 | 6.5 | 第二版修改 |
| D-16 | 可顯示輸出類型另加 P2WSH | 8.2 | — |
| D-17 | 不引入 `bitcoin` crate，自寫 bech32m 與 base58check，以 BIP 正反向量與差分測試釘住；需持有人核准 ADR-002 修訂 | 8.2 | 第二版修改 |
| D-18 | Vault 的首次主網確認只存在記憶體、每次解鎖重置，不升級加密庫 schema；涵蓋主網匯出 | 10.2 | — |
| D-19 | 付款意圖、成員、證據與衝突集合分開；資源狀態與成員有效性由證據推導，付款結果另記；新支出只能加入衝突集合、經確認另付，或以 `rescue` 取回資源 | 2.5 | **第三版重寫**（原 PA-1–PA-8）；第四版改為推導狀態（D-39）並新增 `rescue`（D-38） |
| D-20 | OP／Base：Vault 只保證 `gas_limit × price`；L1 data fee 與 operator fee 顯示為無法核對；建立與廣播前超過 R 都是警告加確認 | 4.3 | 第三版把建立時的硬性阻擋改為警告（Argon NI-03）；第四版刪除 Vault 畫面上「建立時已確認不超過 R」的說法（GPT 第三輪 I5、Codex R3 Minor 4） |
| D-21 | BTC `max_address_index`、依序配置（含已發出地址）、高水位與已發出清單、同步四項工作 | 6.4 | 第三版補「刷新已發出地址」與掃描閘門豁免；第四版定義「掃描完整」、豁免擴及所有只用已引用輸入的成員 |
| D-22 | BTC 交易形狀：非 0 locktime 需至少一個非 final sequence；每個輸出 ≥ 該類型 dust；找零最多一個 | 6.7、8.2 | — |
| D-23 | 公開備份包含意圖、成員、已簽 bytes、證據與觀察期內的已結算紀錄；匯入只增不減 | 2.6 | 第三版擴充；第四版加逐欄合併規則，匯入不證明歷史完整；第五版匯入改為聯集後重算，備份含存疑紀錄與調解確認 |
| D-24 | 資料遷移在 Phase 1a，含遷移前副本與標記檔；回復改為匯出副本＋還原建置，且在遷移後已有新成員時停用 | 2.4、11 | 第三版修改回復方式（Play 無法降版） |
| D-25 | `TestTb` 的 BTC 費用上限與主網相同 | 2.2、6.6 | — |
| D-26 | RPC／Esplora 不跟隨轉址、不顯示遠端回應本文 | 4.4 | — |
| D-27 | `m/84'/1'/0'` 只匯出一筆；`use_info` 從 Phase 2a 起輸出；缺欄位時以 coin type 為準 | 9.2 | — |
| D-28 | 結算信任所選伺服器的確認回報；第二主機核對依第 2.7 節的演算法，不一致或無法連線一律不結算 | 2.7 | 第三版補演算法；第四版第二主機也比對 receipt `status` 與以 `finalized` 量測的 nonce |
| D-29 | EVM 下一個可用 nonce 由 `max(L_rpc, L_local)` 與本機已送出的集合推出；`pending` 只作提示；從未簽署的 nonce 之後不建立獨立付款 | 2.5.3、4.5 | 第三版新增；第四版加 `L_local`、`latest` 異常跳升需確認（`Q-24`）、唯讀 nonce 欄位、餘額預留；第五版加 nonce 證據爭議與更正（D-47）、`Q-24` 的兩個出口，餘額以 `latest` 量測 |
| D-30 | 族外交易 T 必須通過本地 witness 簽章驗證才算數；族外消耗只導致 `unresolved`，不判定未付款 | 2.5.4 | 第三版新增；第四版的驗證規格見 D-42 |
| D-31 | 逐鏈結算層級：BTC 深度；EVM 主網 `finalized`；不支援標籤時不自動結算；sequencer 信任需持有人明確選擇 | 2.7 | 第三版新增（取代 EVM 一律 12）；第四版「nonce 被用掉」也以 `finalized` 量測，並定義手動結算 |
| D-32 | Vault 新增收款地址頁與核對 | 10.6 | 第三版新增；第四版改為單一收款內容、可由 Vault 直接顯示收款 QR、EVM index 限配對範圍；第五版加收款內容嚴格子集（D-49）與 Vault 單獨收款範圍（D-50） |
| D-33 | 匯出前檢查取消空間；取代與取消可加入未保留的輸入；從未送出的集合可不提高費用取代 | 2.5.2、6.6 | 第三版新增；第四版 BTC 與 EVM 的取代費用規則分開，只與仍可能上鏈的已送出成員比較 |
| D-34 | 「歷史可能不完整」旗標與每一筆新付款前的全頁說明 | 2.6 | 第三版新增；第四版擴及 v1→v2 遷移，合併與 EVM 清除都不自動清除旗標；第七版旗標只能以 `Q-20` 的全面確認解除，每一筆新付款前都顯示說明 |
| D-35 | FFI 匯出集合必須完全等於附錄 E；`public_core` 不含秘密型別；修訂 ADR-001 §2.2 的符號規則 | 3.4、附錄 E | 第三版新增；第四版改為逐期、逐 App、逐層級的逐字清單，含第三方 `rustsecp256k1_v0_14_*`，定稿為 Phase 0 完成條件 |
| D-36 | Vault 的「最近已簽」提示 | 2.6 | 第三版新增；第四版改用新增的公開索引檔（`signed_at`、輸入 outpoint，保留 500 筆）；第五版揭露索引檔的隱私影響並提供清除動作 |
| D-37 | HTTPS 由 Wallet 內共用的 URL 規則函式強制：`http` 只限 loopback、區域網路私有位址、單一標籤與 `.local` 名稱並顯示警告，其他主機必須 `https`；release 與 dev 相同；不依賴 Android 平台設定 | 1.3 KEEP-19、4.4、6.2 | 第三版新增；規則由持有人授權的 lead 決定（`Q-21`） |
| D-38 | BTC 資源救援 `rescue`：只花使用者選定的輸入、全部付給自有地址、不加入被救援的集合；結算後不把任何意圖記為 `cancelled` | 2.5.6 | 第四版新增（Codex R3-B1、GPT 第三輪 B1）；確認方式待 `Q-23`；第五版可明確選擇較低費用（D-45），救援集合只接受同一救援的取代（D-46），不強制前提 |
| D-39 | 資源狀態由證據推導（`consumed`／`reserved(refs)`／`free`，另有存疑旗標），同一資源可被多個集合引用；成員復活或多重引用時進入「需要調解」，不合併集合 | 2.5.1、2.5.2 PM-6 | 第四版新增（Codex R3-I4、GPT 第三輪 B2；Opus m3-10 修改後採用） |
| D-40 | EIP-7702：不建立 `to` 等於發送方的交易；`eth_getCode` 偵測並 fail-closed；有委派時警告並逐筆確認；Vault 在 `to` 等於簽署帳戶時警告 | 4.6 | 第四版新增（GPT 第三輪 B4）；政策待 `Q-22`；第五版撤回「發往其他地址不會執行委派」，對合約收款與 ERC-20 逐筆確認，取消為 0 金額、廣播前再查；第六版 Vault 的 EVM `Main` 審查頁加與來源無關的揭露，「0 金額」只限取消與清除 |
| D-41 | 主網單一來源規則：只有一個來源時，結算結果只能是 `paid` 或 `unresolved`；覆寫要求核對具體的鏈上事實 | 2.5.4、2.5.4.2 | 第四版新增（Opus R3-1）；第五版擴及 `rescue`／`clearing`，單一來源的 `paid` 加標示 |
| D-42 | 族外交易 T 的驗證：u 必須是 v0 P2WPKH；金額與 script 取自本機前置交易；BIP-143 scriptCode；只接受 `SIGHASH_ALL`；嚴格 DER、low-S 正規化；新的保留 witness 的有界解析器 | 2.5.4.1 | 第四版新增（Codex R3-I2、Opus R3-3；否決 Argon M3-02 的六種類型） |
| D-43 | 清除交易：獨立的 `clearing` 意圖，只花建立時未被引用的輸出；只作資源與結算工具，從不解除「歷史可能不完整」 | 2.6 第 4 點 | 第四版新增（GPT 第三輪 B3、Opus m3-4），當時以掃描與覆蓋條件清除旗標；第五版改用 `clearing` 角色、單一來源的結算不算、加預簽入金的勾選；第七版刪除這些條件，清除只是資源與結算工具；第八版改寫本欄（Codex R7 Minor 1） |
| D-44 | v1→v2 遷移對照：舊 `cancelled` 與封存紀錄一律視為可能已簽的 `exported` 成員；有付款歷史的帳戶遷移後設「歷史可能不完整」 | 2.6 第 5 點 | 第四版新增（Codex R3-I1）；第五版補 `executionFailed`、v1 `unknown`、無法識別的狀態與「曾由本 Wallet 送出」 |
| D-45 | `rescue` 可由使用者明確選擇低於 PM-3 要求的費用（寫明競爭語意）；BTC 跨集合的取代以「各集合最高手續費之和加增量轉發費」為保守預檢 | 2.5.2 PM-3、2.5.6、6.6 | 第五版新增（GPT R4-B1、R4-I4、Opus m4-1） |
| D-46 | 成員角色必須與意圖類型相容：`payment` 只有 `pay`／`bump`／`cancel`，`rescue` 只有 `rescue`，`clearing` 只有 `clearing`；救援與清除集合只接受同一意圖、全自有輸出的取代，外部付款不得加入 | 2.5.1、2.5.2 PM-2／PM-4 | 第五版新增（Codex R4-B1、Opus I4-2、GPT R4-I2） |
| D-47 | EVM nonce 證據爭議：以來源自己的結算層級高度區分落後與矛盾；矛盾時停止新付款，經第二來源或不同營運者的 explorer 核對後以可備份的撤銷或覆寫更正，再重算 `L_local`；`Q-24` 的確認存為覆寫證據 | 2.5.3、2.5.2 PM-6 | 第五版新增（Codex R4-I2、GPT R4-B3、Opus I4-1）；撤銷權限待 `Q-26`；第六版高度只作診斷，質疑入口隨時可用、不受高度限制，撤銷綁定事實，被標記的來源不再單獨構成證據；第七版撤銷可以「恢復」，receipt 的上鏈與執行結果分開，標記可由使用者解除 |
| D-48 | 存疑改為只增不減的存疑紀錄與解除紀錄，隨備份保存、合併取聯集 | 2.5.1、2.6 | 第五版新增（Opus I4-3）；第六版解除紀錄引用被解除的存疑紀錄 id |
| D-49 | 收款內容只用嚴格子集（EVM 裸地址；BTC `bitcoin:<地址>` 加可選 `amount`）；Vault 核對與 Wallet 付款連結解析都拒絕 `r`、`pj`、`req-*` 等參數 | 10.6 | 第五版新增（GPT R4-B5）；第六版寫明完整語法、拒絕所有 `ethereum:` URI、EIP-55 checksum；第七版補裸地址、EVM 全大寫、`amount` 的邊界與 `label`／`message` 值的 percent-encoding |
| D-50 | Vault 不經 Wallet 時只顯示 BTC branch 0 的 index `0..=min(19, max_address_index)` 與 EVM 配對帳戶；這個範圍固定納入 Wallet 的完整刷新 | 6.4、10.6 | 第五版新增（GPT R4-I3）；待 `Q-25`；第六版改以有界派生比對地址；第七版固定納入完整刷新（Codex R6-B1），「一致」只證明地址所有權（GPT R6-I3） |
| D-51 | 覆寫、手動結算與 nonce 核對所用的 explorer 必須與證據來源不同營運者；無法判定時明寫 | 2.5.4.2、4.1、6.2 | 第五版新增（Opus I4-4）；第六版也約束第二來源，並排除提出較低觀察的來源 |
| D-52 | BTC 深度掃描對有紀錄的地址另取交易歷史與 `outspend`，用來發現被未知交易花用的自有輸出，清除可以與它競爭；不作任何「已完整」的判定 | 2.6 第 2、4 點、6.4 | 第六版新增（GPT R5-B1）；第七版刪除覆蓋集合、雙主機一致與窄確認，只保留發現與競爭 |
| D-53 | Vault 的 `Main` 收款地址顯示、核對結果與重新顯示都受公開種子檢查（`MN-14`），依實際種子判定 | 10.4、10.6 | 第六版新增（GPT R5-B2、Opus I5-1）；第七版涵蓋還原預覽，公開種子的 EVM 地址一律加警告、不顯示 QR |

此外，第 4.1、6.6、2.7 節的數值上限、結算層級與 `max_address_index` 的建議值，都是本 ADR 提出的設計值，持有人已於 2026-10-20 決定採用。

## 附錄 D：審查意見處理表

### 第一輪（2026-10-20，對第一版 `d9e037a`）

本表中的 PA-1–PA-8 指第二版的規則；第三版已改為第 2.5 節的 PM-1–PM-5 與證據表（第四版另加 PM-6）。

審查者：Codex（GPT-6.1-Sol）、Opus（Claude Opus 5.5）、Argon（Gemini 4 Argon）。GPT Pro 因額度未執行。「接受」＝照建議修改；「修改後接受」＝採納問題、但以不同或統一的作法處理；「否決」＝經核對程式或原文後不成立。

| ID | 審查者 | 處理 | ADR 位置 | 理由 |
|---|---|---|---|---|
| B1 | Codex | 接受 | 2.5（PA-1–PA-8）、6.9、15 C-01 | 統一的付款嘗試規則：`exported` 起即保留，封存不釋放，`cancelled` 只給從未匯出的草稿，取消只能用付給自己的取代 |
| B2 | Codex | 接受 | 4.3、10.2 | 改為「簽章保證的執行費上限＋無法核對的額外費用」；R 改名為估價門檻且不進 Vault 公式；三行顯示含 operator fee；來源改為條件句；Wallet 廣播前重估 |
| B3 | Codex | 接受 | 2.5（PA-4–PA-7）、6.1、6.3、15 C-02 | `conflicted` 只依本地核對的族外花費且達 K；mempool 衝突不算；Core 的負確認數分支確認接不到；明寫信任邊界與重組處理 |
| I1 | Codex | 接受 | 3.5（`MN-18`）、11.1 | 單一驗證函式涵蓋所有公開入口，含 `TypedTransaction` 與直接 FFI；以入口一致性測試驗證 |
| I2 | Codex | 接受 | 3.3、3.4、15 C-15 | 稽核最終 AAB 與全部 `.so`、建置紀錄、負向測試、iOS 不在範圍、以匯出符號允許清單取代無法執行的「無 sign 符號」 |
| I3 | Codex | 接受 | 6.4（`MN-17`）、6.8 | 探索／刷新／調解分開；保留中的 index 視為已用；高水位進備份；index 上界與深度掃描 |
| I4 | Codex | 接受 | 2.4、10.4 | 帳戶身分改用完整公鑰雜湊；逐檔說明舊讀取器行為（EVM 歷史升 v2、Vault 結果不升版的理由）；多檔遷移程序；Wallet 防呆改比對地址與公鑰雜湊 |
| I5 | Codex | 接受 | 6.5、7.2 | 有效金額、實際序列化驗證、重複前置交易逐一計算、替代搜尋、單一大前置交易列為產品限制 |
| I6 | Codex | 接受 | 5.1、6.6、6.7、8.2、4.3 | POL 顯示由 Rust 產生；locktime 只在有效時顯示且無效組合拒絕；RBF 用語；交叉相乘比較；D-09 分母與綁定；全部輸出看完才可核准 |
| I7 | Codex | 接受 | 4.4 | 不顯示遠端本文；不跟隨轉址；同主機共用限流；429 先於 Content-Type；POST 不自動重試 |
| I8 | Codex | 接受 | 14.1 第 1 點 | 每個上限附算術含義與代價，交持有人決定 |
| I9 | Codex | 接受 | 11.2–11.7、12.3、13 | Phase 0 保留本機鏈的代幣行為與全入口快照；1a 的 BTC 停用在 Rust 層；`use_info` 與交易形狀提前到 2a；對外發佈最低閘門；Mac 可執行的檢查；ELF 對齊；乾跑種子永久作廢 |
| B-1 | Opus | 接受 | 6.4（`MN-17`）、15 C-03 | 宣稱自有的輸出 index 上界、顯示找零路徑、依序配置、深度掃描到上界 |
| B-2 | Opus | 接受 | 2.5、15 C-01 | 與 Codex B1 合併處理；備份含已簽交易改為明確揭露（`Q-16`） |
| B-3 | Opus | 接受 | 2.5（PA-4、PA-5、PA-7）、6.3、10.5 | `-22` 等送出後錯誤一律 `unknown`；`conflicted` 需本地核對 T 的 bytes 與深度 K，第二主機為選項；改寫可信邊界 |
| I-1 | Opus | 接受 | 4.2（D-08） | 核對 `canonical_roundtrip.rs:30-45` 與 `test_g4_okx_closed_loop.py:61-75` 後改回保留 `2d+35`／`2d+36` 與 6 欄位 |
| I-2 | Opus | 接受 | 5.1、15 C-10 | 原生幣與費用字串改由 Rust 產生；確認現行寫死 ETH |
| I-3 | Opus | 接受 | 4.3、10.2 | 與 Codex B2 合併處理 |
| I-4 | Opus | 接受 | 14.1 第 1 點 | 依其算術建議 Ethereum 改為 0.02 ETH；BTC 整併限制寫明 |
| I-5 | Opus | 接受 | 3.3、3.4、12.1、15 C-15 | 沒有 CI 的事實寫明；檢查改為跨平台並針對 AAB；清除 `jniLibs`；刪除 iOS 產物承諾 |
| I-6 | Opus | 接受 | 2.2、6.6（D-25） | 寫出殘餘風險；`TestTb` 上限等於主網 |
| I-7 | Opus | 接受 | 1.2 T8、10.5 | 改寫為「無法建出金額被謊報卻仍有效的交易」，入帳標示「由伺服器回報」 |
| I-8 | Opus | 接受 | 6.5、7.2 | 單一大前置交易列為無法以 QR 花費；前置交易去 witness |
| I-9 | Opus | 接受 | 2.5（PA-2） | 地址相同只作警告；另一筆付款須明確宣告並列出所有未結算的族 |
| I-10 | Opus | 接受 | 2.5、4.5 | `latest` 前進而無 receipt 不釋放；取代須提高費用；OKX 混用限制 |
| I-11 | Opus | 接受 | 2.4、11.3、11.4（D-24） | 遷移移到 Phase 1a，含遷移前副本與還原演練 |
| I-12 | Opus | 接受 | 4.1（D-06、D-07）、11.1、12.2、12.3、12.6 | 主網結構規則擴及測試網；乾跑種子永久作廢；新增說謊後端的故障模式與對應測試 |
| I-13 | Opus | 修改後接受 | 0、8.2、14.1（`Q-17`）、15 C-19 | 列出全部不符項；D-17 明列為偏離 ADR-002 原則，交持有人核准正式修訂（不在本 ADR 直接改 ADR-002） |
| B-01 | Argon | 否決（部分併入） | 6.4 | 第一版 §6.4 已定義 `wallet_derive_btc_addresses_json` 與 `/0/*`、`/1/*` 各 20 的 gap-limit 掃描；所述缺口是現行 Core 路徑的狀態，不是設計遺漏。相關的上界與掃描模型依 Opus B-1、Codex I3 處理 |
| B-02 | Argon | 修改後接受 | 4.3 | 接受：額外費用改為獨立欄位，保持 `review_model.dart:432-434` 的一致性檢查；廣播前重估。否決「對未簽交易呼叫 `getL1Fee` 會低估」：OP 文件明寫此方法預設輸入為未簽交易（facts §1.2）。否決以 `exec + L1 ≤ 總額` 當硬檢查：L1 費用在簽章外，不能成為保證 |
| B-03 | Argon | 接受 | 2.5（PA-2、PA-5）、4.5 | EVM nonce = max（RPC pending，未結算最大 nonce + 1）；`latest` 前進而無 receipt 不釋放；BTC 封存不釋放保留 |
| B-04 | Argon | 修改後接受 | 6.7、8.2、15 C-04 | 確認 Vault 無輸出下限；改為依 Core `GetDustThreshold` 規則的函式。不採用報告中的各類型數值，因為 facts 沒有，須於實作時依 Core 原文核對 |
| B-05 | Argon | 接受 | 6.7（D-22）、15 C-05 | 非 0 locktime 而所有輸入皆 final 時拒絕；顯示有效的 locktime 與 RBF 訊號 |
| B-06 | Argon | 修改後接受 | 8.2、15 C-06 | 接受：頂端摘要誤導、找零只取第一個、多收款需完整顯示；新增找零最多一個。否決「綁定沒有涵蓋全部輸出」：綁定含 `signing_digest`，即整份 PSBT 的 SHA-256（`crates/vault_ffi/src/lib.rs:1405`） |
| B-07 | Argon | 修改後接受 | 3.5、15 C-07 | 接受：直接入口固定 `#0`、`account_address` 實為收款人，改為明確派生路徑與改名。否決「以 `#0` 私鑰簽出錯誤簽章」與「快取 key 碰撞」：直接入口的顯示（`:919-921`）與簽署（`:1674-1677`）都是 `#0`，彼此一致；快取 key 含 request_id、digest 與路徑 |
| I-01 | Argon | 修改後接受 | 4.2、15 C-08 | 確認 legacy 沒有 gas 下限並補上。不採用「ERC-20 下限 45,000」：facts 沒有此值，實際 gas 是否足夠由 Wallet 估算負責 |
| I-02 | Argon | 接受 | 4.1（D-06） | 計算合法最大長度為 173 bytes，上限改為 256 並擴及 Test |
| I-03 | Argon | 否決（部分接受） | 3.3 | ADR 從未提議 `default = ["dev-networks"]`，第一版即寫明非預設；接受其觀察，為 `tools/build_ios_core.sh:17` 補上 `--no-default-features` |
| I-04 | Argon | 接受 | 9.2 第 9 點、3.5 | 定義 Phase 1a–2a 無 BTC 時的行為：Rust 層回「未啟用」、UI 不顯示誤導訊息、舊資料可檢視 |
| I-05 | Argon | 接受 | 9.2（D-27） | `use_info` 無法區分測試網路；`m/84'/1'/0'` 只匯出一筆，由 Wallet 選擇網路 |
| I-06 | Argon | 修改後接受 | 6.3 | 接受：剛廣播後的 404 顯示「索引中」、加入鏈頂雜湊。否決「以 `outspend` 確認未花後即可解鎖」：與 PA-4 衝突，單一伺服器的回應不能釋放保留 |
| I-07 | Argon | 接受 | 6.5 | 費用隨每個候選組合的 vsize 計算 |
| I-08 | Argon | 接受 | 2.4、4.5、15 C-09 | 確認備份過濾其他網路的 EVM 紀錄與匯入覆寫 `chainId`；v3 保留所有網路 |
| I-09 | Argon | 接受 | 2.4、10.1、15 C-13、C-14 | 確認 metadata 缺網路與寫死標籤；`review_model.dart:587` 第一版已列入 |
| I-10 | Argon | 修改後接受 | 6.5、7.2 | 接受：幀數以實際編碼器計算（噴泉碼約 2 倍幀，`fountain.rs:246`）。報告所指「第 6.8 節 27–30 幀」的估算不在 ADR 中；分片長度調整屬 UX 參數，本 ADR 不定 |
| 錯誤引用與 D 表 | Argon | 否決 | — | 報告引用的 `packages/qr_ui/lib/src/qr_code_view.dart`、`crates/vault_core/src/secp256k1.rs`、`evaluate_policy_with_context`、§13.5、`default = ["dev-networks"]` 與其 D-01–D-18 的內容都不在 ADR-005 中（以 grep 核對為 0 筆；`policy.rs:71` 的函式是 `evaluate_intent`），推測審查的是不同文字 |
| Minor（三位） | 全部 | 大多接受 | 2.3、6.2、8.2、11、14.1 | 已處理：Phase 0 dev 橫幅矛盾、§3.3(b) 反轉時點、`dec_string_to_be_bytes`、寫死 `"bcrt"`、sign 以綁定分派、未知 PSBT 欄位的取捨理由、signet genesis（UNVERIFIED）、EIP-55、快取 key 對 signet／testnet4 無區分、ADR-001 引用、掃描進度、UNVERIFIED 須在啟用前查證、代幣用語、`Q-10` 改為已決定、bip39 的需求版本與 lock 版本區分、逾時可調 |

### 第二輪（2026-10-20，對第二版 `b518c01`）

Codex 與 Argon 判定 REQUEST CHANGES，Opus 判定 APPROVE WITH CHANGES。三份報告集中在第 2.5 節，第三版把它重寫成一個模型（意圖、成員、資源、衝突集合分開），而不是逐條修補。

| ID | 審查者 | 處理 | ADR 位置 | 理由 |
|---|---|---|---|---|
| R2-B1 | Codex | 接受 | 2.5.2 PM-2、2.5.4、附錄 F F-1 | 記錄每個成員的實際輸入；新成員須與每個成員衝突（至少一個共同輸入）；只有每個成員都失效時才釋放其餘保留；反例列為驗收案例 |
| R2-B2 | Codex | 接受 | 2.5.1、2.5.4、F-2–F-5 | 資源狀態與付款結果分開；角色不可變；`cancel` 結算為 `cancelled`；族外消耗只導致 `unresolved`，需使用者選擇 |
| R2-I1 | Codex | 接受 | 2.6、F-16、F-17 | 保證限縮為本機擁有的歷史；定義「歷史可能不完整」與第一筆新付款前的選項；備份含觀察期內的已結算集合；匯入只增不減 |
| R2-I2 | Codex | 接受 | 6.6「取消空間」、`Q-18` | 列出四個選項與取捨，建議 1＋2＋3；不採逾時解鎖或靜默提高上限 |
| R2-I3 | Codex | 接受 | 2.7、`Q-13`、`Q-14`、F-18、F-19 | 逐鏈結算層級、深度與標籤的基準、區塊雜湊重核、觀察結束條件、第二主機演算法、手動結算紀錄；sequencer 信任改為明確選擇 |
| R2-I4 | Codex | 接受 | 6.4 第 3–5 點、F-20 | 記錄已發出地址；同步加入「刷新已發出地址」與高水位以下的全範圍刷新 |
| R2-I5 | Codex | 接受 | 3.4、3.5、附錄 E | 匯出集合必須完全等於允許清單並記錄輸入契約；明示修訂 ADR-001 §2.2；`public_core` 不含秘密型別，所有權檢查留在 `vault_core` |
| Minor 1 | Codex | 接受 | 4.3、10.5 | 離線畫面不再聲稱 operator fee 目前為 0；「無法簽下超過上限」限縮為簽章內費用 |
| Minor 2 | Codex | 接受 | 4.3 | 註明 Sepolia type-2 自我轉帳的 12,000 例外沿用現行 |
| Minor 3 | Codex | 接受 | 11.3 | Phase 0 只供內部驗收，不適用對外發佈閘門 |
| Minor 4 | Codex | 接受 | 6.4 第 7–8 點、14.1 | 2,002 個地址；以每分鐘預算估算時間並標為動態估算；探索不超過上界 |
| 程式主張 PA-4 | Codex、Opus | 接受 | 2.5.2 PM-5 | 改為逐一引用：RPC 錯誤物件只帶 code（`bitcoin_rpc_client.dart:82-87`）、401／403 為 `notSent`（`:75-79`）、連線或解析失敗為 `uncertain`（`:95-97`）、送出後轉 `unknown` 由畫面完成（`bitcoin_send_screen.dart:436-457`） |
| 程式主張 C-08 | Codex | 接受 | 15 C-08、4.2 | 區分低於 intrinsic gas（無效、不會上鏈）與通過 intrinsic 後執行 gas 不足（執行失敗並收費） |
| EVM 匯出後取消 | Codex | 接受 | 15 C-20、4.5 | 核對 `transaction_history.dart:94-101` 與 `send_tx_screen.dart:77-95` 屬實，新增 C-20 |
| N-1 | Opus | 接受 | 2.5.4 | T 須通過 witness 簽章驗證；T 付給原收款人時提示「可能已付款」 |
| N-2 | Opus | 修改後接受 | 2.5.2 PM-2、2.7 第 5 點、6.9、F-12 | 接受：只需一個共同輸入、可捨棄存疑輸入、選幣前第二主機核對（`Q-14`）。不採用「會釋放保留的放棄」：Vault 可能已簽，只提供不釋放保留的「標為已放棄」（`Q-19`） |
| N-3 | Opus | 修改後接受 | 2.5.3、F-9 | 不以「pending ≤ latest + 餘量」拒絕，而是由 `latest` 與本機集合自行推出 nonce，`pending` 只作提示；nonce 缺口後的集合「等待 nonce n」並在 `latest` 到達時自動恢復，取代墓碑設計 |
| N-4 | Opus | 接受 | 2.5.4、F-7、F-8 | 單一來源的 `status = 0` 為 `unresolved`；一致性檢查 |
| N-5 | Opus | 接受 | 6.6「取消空間」、`Q-18`、F-13 | 匯出前檢查取消空間；可加入未保留的輸入；手動釋放不提供 |
| N-6 | Opus | 接受 | 2.5.3、2.5.1、F-10、F-15 | 從未簽署的 nonce 之後不建立獨立付款；`pay` 成員可變更收款資訊 |
| N-7 | Opus | 接受 | 2.5.5、F-22、F-23 | 全頁確認只在有未上鏈或 `unresolved` 時出現；警告條件改為金額相同或收款人相同 |
| N-8 | Opus | 接受 | 10.6（`MN-19`） | Vault 核對收款地址；BTC 在 Phase 2b 前必須完成，EVM 在 Phase 1a |
| m-1 | Opus | 接受 | 6.4 第 6 點、F-21 | 只用已保留輸入的 `bump`／`cancel` 豁免掃描閘門 |
| m-2 | Opus | 接受 | 6.4 第 7–9 點 | 封鎖風險警告、預算、刷新優先順序 |
| m-3 | Opus | 接受 | 2.5.1、2.5.2、6.8 | 可變更輸出（`pay` 成員）、可加入未保留輸入、同集合沿用找零 index |
| m-4 | Opus | 接受 | 2.7 | 不一致或無法連線一律不結算；可更換或在警告後關閉 |
| m-5 | Opus | 接受 | 2.4 遷移程序 | Play 無法降版：改為匯出副本到使用者選擇的位置＋必要時發佈還原建置；遷移後已有新成員時停用回復 |
| m-6 | Opus | 接受 | 2.6 第 5 點（第四版為第 8 點） | Vault 依自己的公開簽署結果提示 |
| m-7 | Opus | 接受 | 6.3 | 標註「剛廣播後 404」是設計上的保守處理，不在 facts 內 |
| m-8 | Opus | 接受 | 4.3（D-10） | Arbitrum 的 tip 改用 `eth_feeHistory` |
| m-9 | Opus | 接受 | 6.6（D-09） | 定義「外部輸出」 |
| m-10 | Opus | 接受 | 6.4 第 7 點 | 復原說明寫明 gap limit |
| m-11 | Opus | 接受 | 11.1、附錄 F | 補測試案例 |
| m-12 | Opus | 接受 | 3.4、附錄 E | 恢復「必須存在」的匯出檢查 |
| 錯誤引用 | Opus | 接受 | 3.2、15 C-07、15 C-03 | `vault_ffi/src/lib.rs:810-812`；`:1226`；C-03 加入 Dart 端；新增 C-21（iOS 腳本） |
| NB-01 | Argon | 接受 | 6.4 第 5 點、F-20 | 與 Codex R2-I4 合併處理 |
| NB-02 | Argon | 修改後接受 | 2.5.2 PM-2／PM-3、2.5.3、6.6、F-10、F-14 | 接受：從未送出時不需提高費用、可變更收款資訊、可加入未保留輸入、不在未簽 nonce 後建立獨立付款。不採用「本地廢棄已匯出的請求並釋放資源」：Wallet 無法得知 Vault 是否已簽；改為可以不提高費用的取代 |
| NB-03 | Argon | 接受 | 2.5.4、`Q-14` | 與 Opus N-1 合併處理；第二主機在 BTC 主網預設開啟 |
| NI-01 | Argon | 接受 | 2.5.1、F-15 | 同意圖的 `pay` 成員可變更收款資訊 |
| NI-02 | Argon | 修改後接受 | 2.7、`Q-13` | 接受逐鏈處理；不採用報告建議的區塊數（Polygon 64／128 等）：facts 沒有各鏈最終性資料，改以 `finalized` 標籤為準，不支援時不自動結算 |
| NI-03 | Argon | 接受 | 4.3（D-20） | 建立時超過 R 改為警告加確認 |
| NM-01 | Argon | 接受 | 6.4 第 7 點 | 深度掃描可取消、可換端點續掃 |
| `Q-15` 補充 | Argon | 接受 | 6.4 第 1 點、14.1（`Q-15`） | 上界用完後的處理需另立 ADR |
| KEEP-19 前提錯誤 | lead 轉述 play-writer | 接受 | 1.3 KEEP-19、4.4、6.2、13、15 C-22、`Q-21` | Dart 端核對屬實：`account_screen.dart:336-342` 與 `bitcoin_rpc_client.dart:53-58` 對任何主機接受 `http`；engine 部分依其核對。KEEP-19 改為必須新增的 App 內 URL 規則；之後持有人授權 lead 決定 `Q-21`：loopback、區域網路私有位址、單一標籤與 `.local` 名稱可用 `http` 並顯示警告，其他主機必須 `https` |

### 第三輪（2026-10-20，對第三版 `ec073d3`）

Codex 與 GPT 6 Pro 判定 REQUEST CHANGES，Opus 判定 APPROVE WITH CHANGES，Argon 判定 APPROVE；以最嚴者為準。GPT 6 Pro 的報告沒有編號，本表依出現順序編為 B1–B4、I1–I7、m1。第四版的模型變動：資源狀態改為由證據推導、可被多個集合引用（D-39）；新增 `rescue`（D-38）與調解（PM-6）；主網單一來源規則（D-41）；族外交易 T 的驗證規格（D-42）；EIP-7702（第 4.6 節，D-40）。

| ID | 審查者 | 處理 | ADR 位置 | 理由 |
|---|---|---|---|---|
| R3-B1 | Codex | 接受 | 2.5.6 資源救援、6.9、`Q-23`、F-25 | 新增不加入原集合、只與引用其輸入的成員衝突的 `rescue`；結算後意圖維持 `open`，不記為 `cancelled`；撤回第 6.9 節「不會凍結真實輸入」的無條件說法；共同輸入全部存疑時不得再加入新輸入 |
| R3-I1 | Codex | 接受 | 2.6 第 1、2、5、6、8 點，F-17 | 有付款歷史的帳戶遷移後一律設旗標；舊 `cancelled` 與封存紀錄對照為可能已簽的 `exported`（D-44）；逐欄合併；成功匯入不清除旗標；本機沒有成員的自有花費只能經覆寫歸入付款，不自動記為 `paid`；Vault 提示改用新增的公開索引檔 |
| R3-I2 | Codex | 接受 | 2.5.4.1（D-42） | 金額與 script 取自同一份本機前置交易；以實際引用 u 的輸入索引計算；P2WPKH 的 BIP-143 scriptCode；只接受 `SIGHASH_ALL`，其他類型不改變紀錄；新的保留 witness 的有界解析器，txid 仍以不含 witness 的序列化核對 |
| R3-I3 | Codex | 接受 | 附錄 E、3.4、11.3 | 依期 × App × 層級列出逐字清單（E.3）；八個 Vault prepare 名稱逐一列出；逐函式的參數與是否接受秘密；清單定稿與「多一個／少一個」負向測試列為 Phase 0 完成條件 |
| R3-I4 | Codex | 接受 | 2.5.1 推導狀態、2.5.2 PM-6、2.5.4 重組列、F-18、F-26 | 證據可以被撤銷；每次證據改變時原子地重算；資源保存所有仍可能有效的引用；多重引用時停止選幣直到調解；畫面揭露已簽的 B 無法收回 |
| Minor 1 | Codex | 接受 | 2.5.1 `bump`、6.7 | 只固定外部收款 script 與金額；自有找零可減少，低於 dust 時移除 |
| Minor 2 | Codex | 接受 | 2.5.2 PM-3、4.5、6.6 | BTC 與 EVM 分寫；EVM 只比較每 gas 價格欄位，總費用只受 `max_signed_fee_wei` 限制 |
| Minor 3 | Codex | 接受 | 附錄 F F-7、F-12、F-19、F-24 | F-12 的 X_f 改為 `free` 加存疑旗標；F-24 限定於全頁觸發條件；F-7、F-19 列出 receipt `status` 與以 `finalized` 量測的 nonce |
| Minor 4 | Codex | 接受 | 4.3 | 刪除「建立時已確認不超過 R」（與 GPT I5 合併） |
| Minor 5 | Codex | 接受 | 附錄 F F-34–F-36、11.1 | 補回存檔失敗不顯示 QR、兩個畫面同時建立、`POST` 後 `-22`／404 的回歸案例 |
| PM-5 用語 | Codex | 接受 | 2.5.2 PM-5 | 改為「未設 `uncertain`，只保存 code 與 `rpcMessage`」 |
| C-20 用語 | Codex | 接受 | 15 C-20 | 改寫為缺少保留與閘門；另加 nonce 欄位（Opus R3-4） |
| C-21 排程 | Codex | 接受 | 3.4、11.3、15 C-21 | `--no-default-features` 在 Phase 0 補上；`:27-28` 的檢查在 iOS 上架前改寫 |
| C-22 | Codex | 不需修改 | — | 審查者接受此決定；engine 的核對仍標為未經本 ADR 作者獨立核對 |
| C-08 於 §4.2 | Codex | 接受 | 4.2 第 4 點、4.3 估價表 | 第二輪處理表誤稱 §4.2 已一併修正；本版區分低於 intrinsic gas 與執行中 gas 不足 |
| 階段閘門 | Codex | 接受 | 11.4、11.6 | Phase 1a 釘住的不變量補上 `MN-19`、`MN-20`、`MN-21`；Phase 2a 補上 witness 解析、`rescue`、調解與清除覆蓋條件 |
| B1 | GPT 6 Pro | 接受 | 同 R3-B1 | 同一反例，採同一個 `rescue` |
| B2 | GPT 6 Pro | 接受 | 同 R3-I4；2.6 第 6 點 | 資源對多個集合的引用與原子調解；備份合併後依同一規則重新推導 |
| B3 | GPT 6 Pro | 接受 | 2.6 第 4 點（D-43）、F-30 | BTC 清除只在兩個 branch 的深度掃描完成、且該次掃描找到的每個 UTXO 都已被已結算的自有成員花掉時才清除旗標；實際覆蓋的 outpoint 持久化；EVM 清除不自動清除 |
| B4 | GPT 6 Pro | 接受 | 4.6（`MN-21`、D-40）、`Q-22`、F-32 | 既存委派以 `eth_getCode` 偵測並 fail-closed；取消改付另一個無委派的自有地址，不呼叫委派程式；Vault 無法得知委派，只在 `to` 等於簽署帳戶時警告。委派標記的格式不在 facts 內，依 EIP-7702 原文核對；facts §4 的啟用狀態與 `Q-05` 的關係已寫明 |
| I1 | GPT 6 Pro | 接受 | 2.5.2 PM-3 | 兩鏈分寫；只與仍可能上鏈的已送出成員比較，已失效的歷史成員不計 |
| I2 | GPT 6 Pro | 接受 | 2.5.1、6.7 | 與 Codex Minor 1 合併 |
| I3 | GPT 6 Pro | 接受 | 2.5.3、`Q-24`、F-31 | 無法由本機成員解釋的 `latest` 跳升停止建立並要求核對；已匯出的高 nonce 成員標為「等待 nonce n」並持續提示，接近時可以相同 nonce 的 `cancel` 取代 |
| I4 | GPT 6 Pro | 接受 | 2.5.3、F-33 | 可用餘額扣除每個未結算集合的最大可能支出；代幣與原生幣分開 |
| I5 | GPT 6 Pro | 接受 | 4.3 | Vault 不再聲稱 Wallet 已確認估價；估值只能顯示為未經 Vault 驗證 |
| I6 | GPT 6 Pro | 接受 | 10.6 | 收款頁只有一份收款內容，同時用於交付與核對；建議付款人直接掃描 Vault 的收款 QR |
| I7 | GPT 6 Pro | 接受 | 10.6 | EVM 只允許配對匯出中的 index |
| m1 | GPT 6 Pro | 接受 | 6.4 第 7 點 | 其他軟體的 gap limit 至少為 `max_address_index + 1` |
| R3-1 | Opus | 接受 | 2.5.4 單一來源規則（D-41）、2.5.4.2、2.5.5、F-27–F-29 | 主網單一來源只到 `paid`／`unresolved`；覆寫要求核對 hash、nonce 被哪一筆交易用掉、txid 與確認數，並附 explorer 連結；一行說明排除 `status = 0` 與已上鏈的 `cancel`；一致性檢查擴及自有成員結算列 |
| R3-2 | Opus | 接受 | 附錄 E、3.3 第 2 點、11.3 | 列入四個 `rustsecp256k1_v0_14_*`；展開 `*`；dev 層級清單；不得存在的符號加入 JNI probe 匯出；Phase 0 改為原地修改簽名，Phase 2a 改名時同時移除舊名；依其產物檢查確認兩個哨兵都可用 |
| R3-3 | Opus | 接受（選項 (b)） | 2.5.4.1 | 只接受 ALL 並寫明代價；scriptCode；嚴格 DER 與 low-S 正規化；witness 恰好兩個元素、33 bytes 壓縮公鑰；u 不是 v0 P2WPKH 時記為可疑 |
| R3-4 | Opus | 接受 | 2.5.3、15 C-20、11.1 `MN-13` | Phase 1a 起 nonce 欄位唯讀；進階選項只能選下一個可用 nonce 或加入既有集合 |
| m3-1 | Opus | 接受 | 附錄 F F-12 | X_f 改為 `free`，另加存疑旗標避免再被選用（與 Argon M3-01 調和） |
| m3-2 | Opus | 接受 | 2.5.2 PM-2 | 改為「可以捨棄任何原輸入，只要仍花用至少一個共同輸入」；共同輸入全部存疑時不得再加入新輸入 |
| m3-3 | Opus | 接受 | 2.6 第 6 點 | 不可變欄位不一致即拒絕；證據取聯集後重新推導，沒有撤銷證據時 `consumed`／`free` 不會變回 `reserved`（第五版撤回這一句，見第四輪 R4-I1） |
| m3-4 | Opus | 接受 | 2.6 第 4 點（D-43） | `clearing` 意圖、`cancel` 角色、只花未被引用的 UTXO、可分多筆；EVM 每個 nonce 一個集合 |
| m3-5 | Opus | 接受 | 2.6 第 8 點、2.4 | 新增公開索引檔（`signed_at` 不可信、只供顯示），依數量保留 500 筆；較舊的紀錄寫明無法比對 |
| m3-6 | Opus | 接受 | 2.7 | 定義「手動結算」：在 explorer 核對後存為使用者覆寫；主網仍適用單一來源規則 |
| m3-7 | Opus | 接受 | 2.5.3 | 起點為 `max(L_rpc, L_local)`；RPC 落後時提示 |
| m3-8 | Opus | 接受 | 6.4 第 5、8 點 | 定義「掃描完整」的三層；限流減半後的恢復條件 |
| m3-9 | Opus | 接受 | 6.4 第 6 點、F-21 | 豁免擴及所有只用已引用輸入的成員（變更收款資訊、用 A 的資源付新款、`rescue`） |
| m3-10 | Opus | 修改後接受 | 2.5.2 PM-6、14.2 | 接受：重組後的再配置必須處理並觸發全頁確認。否決「兩個集合合併」：它們的其他成員並不互相衝突；改為多重引用加調解 |
| m3-11 | Opus | 接受 | 10.6 | 與 GPT I6 合併 |
| m3-12 | Opus | 接受 | 2.5.3、F-10 | 有已簽 bytes 時提供「先送出 A」 |
| m3-13 | Opus | 接受 | 14.1 | 每項標示答覆期限 |
| §3.5 `:1227` | Opus | 接受 | 3.5 | 改為 `:1226` |
| M3-01 | Argon | 修改後接受 | 2.5.2 PM-2、附錄 F F-12 | 接受 PM-2 用語修正。否決「X_f 維持保留」：沒有有效成員的保留無法被釋放；改為 `free` 加存疑旗標、不自動選用，同樣避免它再混入選幣 |
| M3-02 | Argon | 部分否決 | 2.5.4.1、14.2 | 接受 low-S 正規化與 Vault 只簽 ALL。否決支援六種 sighash：攻擊面較大，與 Opus R3-3 建議的選項 (b) 一致；代價寫在第 2.5.4.1 節 |
| M3-03 | Argon | 接受 | 附錄 E、2.5.3 | 展開萬用字元；nonce 起點計入已消耗的 nonce（`L_local`） |

### 第四輪（2026-10-20，對第四版 `9c2a3f1`）

Codex 與 GPT 6 Pro 判定 REQUEST CHANGES，Opus 判定 APPROVE WITH CHANGES，Argon 判定 APPROVE；以最嚴者為準。Codex 與 GPT 6 Pro 都用 R4-B／R4-I 編號，本表在 GPT 的編號前加「GPT」區分。第五版的模型變動：角色必須與意圖類型相容，救援與清除集合不能被外部付款沿用（D-46）；救援可明確選擇較低費用、跨集合以總和預檢（D-45）；單一來源規則擴及所有意圖類型；nonce 消耗證據可以更正（D-47）；存疑改為紀錄（D-48）；收款內容嚴格子集（D-49）；Vault 單獨收款範圍（D-50）；explorer 的獨立性（D-51）。

| ID | 審查者 | 處理 | ADR 位置 | 理由 |
|---|---|---|---|---|
| R4-B1 | Codex | 接受 | 2.5.1 角色表、2.5.2 PM-2／PM-4、2.5.6、F-37 | 角色必須與意圖類型相容（D-46）；`rescue`、`clearing` 集合只接受同一意圖、全自有輸出的取代，外部付款在建立前被拒；`bump` 只屬於 `payment`；救援與清除的結果只有 `open`／`done`／`unresolved`；用救援的輸出再付款經 PM-4(b) |
| R4-I1 | Codex | 接受 | 2.6 第 6 點、F-17、F-46 | 刪除「`free` 不會因匯入變回 `reserved`」；全部聯集後以同一公式重算；未撤銷的消耗證據仍使匯入成員失效 |
| R4-I2 | Codex | 接受 | 2.5.3（D-47）、2.5.2 PM-6(ii)、F-42–F-44 | 以來源自己的結算層級高度區分落後與矛盾；矛盾時停止新付款；經第二來源或不同營運者的 explorer 核對後，以可備份的撤銷或覆寫更正並重算 `L_local`；絕不自動採用較低值；已簽的較高 nonce 成員保留 |
| R4-I3 | Codex | 接受 | 2.6 第 5 點、F-52 | 補上 `executionFailed`（`transaction_history.dart:133`、`scan_signature_screen.dart:356-370`）、v1 `unknown` 與任何無法識別的狀態；`executionFailed` 不直接記為 `failed`，待依結算層級與第二來源重查 |
| 原子提交 | Codex | 接受 | 2.5.1、PM-1 | 重算與觸發它的紀錄在同一把鎖內以單一提交寫入 |
| 7702 措辭與比對 | Codex | 接受 | 4.6、F-51 | 「所選來源回報無 code」；比較外層 `to` 與簽署帳戶，不是 calldata 收款人；單一 RPC 謊報空 code 的案例只驗收提示，不宣稱已阻擋 |
| Minor 1 | Codex | 接受 | 2.5.2 PM-3、6.6 | 不再寫「只需 21,000 gas」；依目標鏈估價並受上限限制 |
| Minor 2 | Codex | 接受 | 12.1 | 性質測試改為推導狀態的純函數性質，並列出合法的本機事件 |
| Minor 3 | Codex | 接受 | 附錄 F F-26 | 分成「已顯示 QR、可能已簽」與「已取回並驗證簽章」兩支 |
| Minor 4 | Codex | 不需修改 | 附錄 F | F-12、F-22、F-24、F-34–F-36 保留原樣 |
| E.1 參數 | Codex | 接受 | 附錄 E.1 | `wallet_build_eth_sign_request_ur` 補上 `max_fragment_len` |
| GPT R4-B1 | GPT 6 Pro | 接受 | 2.5.2 PM-3、2.5.6（D-45）、F-38 | 使用者可明確選擇較低費用的救援；畫面寫明它與已送出的 A′ 競爭；兩種結局都不構成第二筆付款 |
| GPT R4-B2 | GPT 6 Pro | 接受 | 2.5.1、2.5.4 單一來源規則、2.6 第 4 點、F-40 | 刪除第四版「`rescue`／`clearing` 不受單一來源規則影響」；主網單一來源時它們只能是 `unresolved`，清除不解除旗標 |
| GPT R4-B3 | GPT 6 Pro | 接受 | 同 R4-I2 | 同一缺口，同一更正流程 |
| GPT R4-B4 | GPT 6 Pro | 接受 | 4.6（D-40）、`Q-22`、F-51 | 撤回「發往其他地址不會執行委派」；寫明 FCW 能避免與不能避免的；發送方有委派時，對合約收款與所有 ERC-20 轉帳逐筆確認並揭露可能流出的資產不只顯示金額 |
| GPT R4-B5 | GPT 6 Pro | 接受 | 10.6（D-49）、F-49 | 收款內容只用嚴格子集；含 `r`、`pj`、`req-*` 或其他參數一律不顯示「一致」；Wallet 付款連結解析同規則。參數名依 BIP-21、BIP-72 原文核對（UNVERIFIED） |
| GPT R4-I1 | GPT 6 Pro | 接受 | 同 R4-I1 | — |
| GPT R4-I2 | GPT 6 Pro | 接受 | 同 R4-B1 | — |
| GPT R4-I3 | GPT 6 Pro | 修改後接受 | 10.6（D-50）、`Q-25`、F-50 | 接受問題。不採用「把 Vault 的發出紀錄帶回 Wallet」：需要新的傳輸格式，忘了帶回時仍看不見；改為 Vault 單獨只顯示 Wallet 一定會刷新的 index 0–19，更高的 index 必須來自 Wallet 的收款內容 |
| GPT R4-I4 | GPT 6 Pro | 接受 | 2.5.2 PM-3、6.6、F-39 | 跨集合以「各集合最高手續費之和加增量轉發費」預檢；寫明這是 FCW 的保守上界，節點規則依 Core 原文核對 |
| GPT R4-I5 | GPT 6 Pro | 接受 | 2.6 第 4 點、F-41 | 清除只保證花用已覆蓋 outpoint 的交易失效；條件成立後仍需勾選「沒有預簽花用尚未廣播之入金的交易」（第七版已刪除窄確認，見第六輪） |
| GPT Minor | GPT 6 Pro | 接受 | 4.3 | R 改寫為「Wallet 額外費用警告門檻；不是本筆估價，也不是上限」 |
| I4-1 | Opus | 接受 | 2.5.3、`Q-24`、F-45、F-54 | 確認畫面只有兩個出口；確認存為覆寫證據並計入 `L_local`；設歷史旗標並與其確認合併；手動結算計入 `L_local` |
| I4-2 | Opus | 接受 | 同 R4-B1 | — |
| I4-3 | Opus | 接受 | 2.5.1 存疑紀錄（D-48）、2.6 第 6、7 點、F-46、F-47 | 存疑改為只增不減的紀錄與解除紀錄，隨備份、合併取聯集；匯入規則同 R4-I1 |
| I4-4 | Opus | 接受 | 2.5.4.2（D-51）、4.1、6.2、10.5 | 營運者標籤；優先連到不同營運者，無法判定時明寫；BTC explorer 的網址格式不在 facts 內，Phase 2a 查證 |
| I4-5 | Opus | 接受 | 2.5.2 PM-6、F-48 | 寫明調解期間停止與允許的動作；確認綁定受影響集合並持久化；確認後多重引用的資源仍是 `reserved` |
| m4-1 | Opus | 修改後接受 | 2.5.2 PM-3、2.5.6 | 不限於「所有比較對象都花存疑輸入」：任何 `rescue` 都可明確選擇較低費用，因為它沒有外部輸出 |
| m4-2 | Opus | 接受 | 2.5.1、PM-1 | 重算與選幣共用建立的鎖 |
| m4-3 | Opus | 接受 | 2.5.1 | 資源只有 outpoint 與 EVM nonce；index 單調配置，不適用 `free` |
| m4-4 | Opus | 接受 | 4.6、2.5.4 第 1 列、後果評估 | 取消與清除為 0 金額、付給另一個配對 EVM 帳戶；廣播前再查；單一 RPC 標示；Vault 標示「本 Vault 的帳戶 #n」；`cancel` 的 `status = 0` 仍為已取消；沒有第二個帳戶時不能在產品內取消，列入代價 |
| m4-5 | Opus | 接受 | 4.6、5.1 | 撤回「發往其他地址不會執行委派」；代幣收錄條件排除會回呼的代幣 |
| m4-6 | Opus | 接受 | 2.7 | 手動結算就是 2.5.4.2 的核對，只記錄一次 |
| m4-7 | Opus | 接受 | 2.6 第 5 點 | 遷移表加「曾由本 Wallet 送出」欄，並帶入已簽 bytes |
| m4-8 | Opus | 接受 | 2.5.3 | 餘額以 `latest` 量測，只扣尚未在 `latest` 上鏈的集合 |
| m4-9 | Opus | 接受 | 2.5.1、2.5.4、2.5.5 | 清除成員改用 `clearing` 角色；結果列與全頁觸發條件只適用 `payment` 意圖 |
| m4-10 | Opus | 接受 | 2.5.4.2 | 「標為未付款」記為 `cancelled` 或 `failed`（依證據），標示使用者覆寫 |
| m4-11 | Opus | 接受 | 2.5.4、2.5.5、F-53 | 單一來源的 `paid` 加標示與 explorer 連結；醒目警告也比對最近 30 天內的這類意圖（觀察期對 EVM 主網太短） |
| m4-12 | Opus | 接受 | 2.6 第 8 點、10.5 | 揭露 Vault 索引檔的隱私影響；提供清除動作 |
| m4-13 | Opus | 接受 | 12.1 | 與 Codex Minor 2 合併 |
| m4-14 | Opus | 接受 | 附錄 F F-21、E.4 | F-21 補上 `cancel` 與 `rescue`；E.4 標題改為「不得存在的符號」 |
| m4-15 | Opus | 接受 | 2.5.6、`Q-23` | 不強制救援的前提；寫入 `Q-23` |
| M4-01 | Argon | 接受 | 附錄 F F-21 | 與 Opus m4-14 合併 |
| M4-02 | Argon | 接受 | 4.6 政策 1 | 取消付給另一個已配對的 EVM 帳戶，帳戶被刪除時不能在產品內取消；ERC-20 收款人等於發送方時不建立 |

### 第五輪（2026-10-20，對第五版 `559c3ab`）

Codex 與 GPT 6 Pro 判定 REQUEST CHANGES，Opus 判定 APPROVE WITH CHANGES，Argon 判定 APPROVE；以最嚴者為準。GPT 6 Pro 本輪編號為 B1–B2、I1–I4 與 Minor，本表與正文都寫成 GPT R5-B1 等。第六版的變動：質疑證據的入口不再受高度限制（D-47）；清除覆蓋改以交易歷史重建、未知自有支出阻止解除旗標（D-52）；Vault 的主網收款受公開種子檢查（D-53）；Vault 的 EVM 主網審查頁加入與來源無關的委派回呼揭露；收款內容的完整語法與 Vault 的有界比對（D-49、D-50）。

| ID | 審查者 | 處理 | ADR 位置 | 理由 |
|---|---|---|---|---|
| R5-B1 | Codex | 接受 | 2.5.3、2.5.4.3（D-47）、F-59、F-60 | 高度比較只作診斷；「質疑這筆證據」隨時可用、不檢查高度；核對使用可信來源目前的高度；撤銷綁定事實，重啟與匯入不會復活；絕不自動降低；真實證據與已簽的高 nonce 成員保留；`Q-24` 的覆寫與手動結算走同一入口 |
| Minor 1 | Codex | 接受 | 10.6（D-49）、F-62 | 寫明 Wallet 付款輸入只多接受 `label`、`message`；兩端都整筆拒絕 `ethereum:`；BTC 的重複 key、percent-encoding、authority、fragment 與無效金額 |
| Minor 2 | Codex | 接受 | 10.6、F-50 | 改寫為「App 在前景且距上次已滿 24 小時、或手動」；建立需要選幣的交易前一定完成；失敗時顯示掃描未完成；範圍取 `min(19, max_address_index)` |
| Minor 3 | Codex | 接受 | 2.5.4.2、F-38 | 補上 `rescue`／`clearing` 的覆寫結果；覆寫結果不改變資源證據；F-38 寫明主網單一來源時為 `unresolved` |
| Minor 4 | Codex | 接受 | 2.5.4.2（D-51）、2.7 | 只有已知且不同的營運者才算獨立核對或第二來源；同一或未知營運者的連結可供瀏覽，但不能完成 2.5.4.3 的撤銷或確認 |
| 程式引用 | Codex | 不需修改 | — | 審查者確認現有程式沒有 BIP-21／EIP-681 解析器；D-49 是新增能力 |
| GPT R5-B1 | GPT 6 Pro | 接受 | 2.6 第 2、4 點（D-52）、6.3、12.6、F-55、F-56 | 覆蓋以 `/txs/chain`、`/txs/mempool` 與 `outspend` 重建（facts §5.3、§5.4；`/utxo` 排除 mempool 花用者為 UNVERIFIED）；未知自有支出持續阻止解除；兩個主機各自重建一致才可用窄確認，否則只能 `Q-20`；主機隱藏輸出列為殘餘風險（第七版已刪除窄確認，見第六輪） |
| GPT R5-B2 | GPT 6 Pro | 接受 | 10.4（D-53）、10.2、10.6、`MN-14`、F-57 | Vault 的 `Main` 收款顯示、核對與重新顯示都依實際種子檢查；兩端各擋自己顯示的地址，刪除「Wallet 是唯一攔得住的地方」 |
| GPT R5-I1 | GPT 6 Pro | 接受 | 同 R5-B1 | — |
| GPT R5-I2 | GPT 6 Pro | 接受 | 4.6 政策 4、10.2、F-58 | Vault 的 EVM `Main` 審查頁一律顯示與來源無關的委派回呼揭露，涵蓋第三方與被入侵 Wallet 的請求；刪除「任何人本來就能呼叫，所以不是新增攻擊面」 |
| GPT R5-I3 | GPT 6 Pro | 接受 | 2.5.1（D-48）、F-64 | 解除紀錄引用它解除的存疑紀錄 id；未被引用的存疑紀錄繼續有效，與時鐘和順序無關 |
| GPT R5-I4 | GPT 6 Pro | 接受 | 10.6（D-50）、F-63 | 收款 QR 不加參數；Vault 在 branch 0、index `0..=max_address_index` 內派生比對 |
| GPT R5 Minor | GPT 6 Pro | 接受 | 同 Codex Minor 4 | — |
| I5-1 | Opus | 接受 | 同 GPT R5-B2 | 另加：每次解鎖後第一次顯示 `Main` 收款地址也經首次主網確認 |
| I5-2 | Opus | 接受 | 同 Codex Minor 1；11.2 第 4 點、11.4 | EIP-55 checksum（現行 `transaction_builder.dart:7-10` 不驗）；BIP-321 列入 UNVERIFIED；Phase 1a 明列 D-49 的 EVM 部分 |
| I5-3 | Opus | 接受 | 2.5.3 出口 (a)、F-61 | 覆寫只涵蓋沒有本機已送出成員的 nonce；只有 `exported`／`signed` 成員的 nonce 之後查到本機成員的 receipt 時，以 receipt 為準並自動撤銷覆寫 |
| I5-4 | Opus | 接受 | 2.5.4.3、2.5.3、2.7 | (a) 確認綁定並持久化，被標記的來源不再重複觸發、不再單獨構成消耗證據；(b) 覆寫的 H 為當時的 `latest` 高度，手動結算的 H 為 receipt 的區塊高度；(c) 核對必須與原證據來源及提出較低觀察的來源都不同營運者 |
| m5-1 | Opus | 接受 | 6.4 第 5 點、10.6 | 沒有高水位時探索從 index 0 起；時效改寫；揭露收款歸屬 |
| m5-2 | Opus | 接受 | 2.5.5、F-26 | 調解確認前不提供「另一筆新的付款」；F-26 改寫停止的動作 |
| m5-3 | Opus | 接受 | 2.5.3、F-66 | nonce n 是清除集合時，選項為送出清除或以新的清除取代 |
| m5-4 | Opus | 接受 | 同 GPT R5-I3 | — |
| m5-5 | Opus | 接受 | 2.5.4.3 第 3 點、2.6 第 6 點 | 撤銷針對事實，涵蓋同一事實的所有證據 |
| m5-6 | Opus | 接受 | 2.6 第 5 點、F-65 | BTC `draft`（沒有 `request`）不建立成員 |
| m5-7 | Opus | 接受 | 2.5.1、PM-6 | 救援與清除的取代改用 PM-2 的寫法；它們的成員與其他集合共用輸入都不算多重引用 |
| m5-8 | Opus | 接受 | 6.3 | 加 `-26` 列（碼的語意 UNVERIFIED）；救援被拒時提示可提高費用重建 |
| m5-9 | Opus | 接受 | 4.6 政策 1 | 「0 金額」只限取消與清除；配對帳戶之間的一般轉帳是 `pay` |
| m5-10 | Opus | 接受 | 4.6、F-67 | 廣播前再查的結果改變時：目的帳戶有 code 就不廣播取消；發送方有委派就先補做確認 |
| m5-11 | Opus | 接受 | 附錄 D 第三輪 m3-3 | 加註「第五版撤回」 |
| `signedRaw` 引用 | Opus | 接受 | 2.6 第 5 點 | 改引寫入處 `scan_signature_screen.dart:287`，並列讀回處 |
| M5-01 | Argon | 接受 | 2.5.2 PM-3 | 被取代的成員彼此已衝突時只取最高者，不重複相加 |
| M5-02 | Argon | 接受 | 同 Codex Minor 1 | — |

### 第六輪（2026-10-20，對第六版 `e575450`）

Codex 與 GPT 6 Pro 判定 REQUEST CHANGES，Opus 判定 APPROVE WITH CHANGES，Argon 判定 APPROVE；以最嚴者為準。GPT 6 Pro 的編號寫成 GPT R6-B1 等。第七版以**簡化**收斂：刪除自動或半自動解除「歷史可能不完整」的窄確認，旗標只能以 `Q-20` 的全面確認解除；清除只是資源與結算工具。其餘為收緊條文：Vault 單獨範圍固定納入完整刷新、撤銷可以更正、receipt 的上鏈與執行結果分成兩個事實、EVM 覆寫先核對事實。

| ID | 審查者 | 處理 | ADR 位置 | 理由 |
|---|---|---|---|---|
| R6-B1 | Codex | 接受 | 6.4 第 9 點、10.6（D-50）、`MN-17`、`MN-19`、F-50 | BTC branch 0 的 `0..=min(19, max_address_index)` 固定納入完整刷新，不論是否發出、是否有紀錄，也不依賴高水位與探索起點；它受「掃描完整」與選幣閘門約束。F-50 改為 H=0、Vault 先用 19 再用 15、重啟與還原、上界小於 19、刷新失敗 |
| Minor 1 | Codex | 接受 | F-44、14.2、後果評估 | 「可能落後，也可能原證據偽造」並保留質疑入口；被標記的來源是「不再單獨構成新證據，直到解除標記或更換」 |
| Minor 2 | Codex | 接受 | 4.5、4.6、14.1 `Q-22`、14.2 | 「0 金額」只限取消與清除；拒絕所有交易的理由改為「不能消除既有委派的風險，只能避免部分由本次簽署觸發的條件」 |
| Minor 3 | Codex | 不需修改（已因簡化而消失） | 2.6 第 4 點 | 覆蓋集合與窄確認已刪除，不再需要快照與分類的定義 |
| Minor 4 | Codex | 接受 | `MN-19`、附錄 C D-50、F-42、F-43 | 範圍一律寫成 `0..=min(19, max_address_index)`；F-42／43 的 explorer 須與兩個來源都不同營運者 |
| 程式引用 | Codex | 接受 | 2.6 第 5 點 | `transaction_history.dart:63` 改述為還原合併時的綁定欄位比對（`:57-65`、`:78-80`） |
| GPT R6-B1 | GPT 6 Pro | 修改後接受 | 2.6 第 3、4 點、14.2 | 接受反例（被淘汰後重新廣播的入金）。不採用「擴大窄確認的勾選範圍」：任何主機查詢都無法排除未見過的已簽支出；改為刪除窄確認，旗標只能以 `Q-20` 的全面確認解除 |
| GPT R6-B2 | GPT 6 Pro | 修改後接受 | 同 GPT R6-B1 | 接受反例（chain／mempool 分開讀取）。不採用「定義一致性快照與增量補查」：它只能縮小、不能消除缺口；隨窄確認一起刪除 |
| GPT R6-I1 | GPT 6 Pro | 接受 | 2.5.4.3 第 3、5 點、F-69、F-70 | 撤銷可以被質疑並以「恢復」事件更正（同樣的獨立性要求）；receipt 的上鏈（雜湊、區塊雜湊、高度）與執行結果（雜湊、區塊雜湊、`status`）分成兩個事實 |
| GPT R6-I2 | GPT 6 Pro | 不需修改（已因簡化而消失） | 2.6 第 4 點 | 「每一個輸出都已被自有成員花掉」的條件已隨窄確認刪除 |
| GPT R6-I3 | GPT 6 Pro | 接受 | 10.6、F-63 | 「一致」只證明地址屬於本 Vault；固定刷新範圍以外的 index 另外提示可能需要深度掃描，使用者確認後才顯示 QR，且只在本次核對畫面顯示 |
| GPT R6 Minor | GPT 6 Pro | 接受 | 10.6、F-50 | 改寫為「下一次完整刷新或手動刷新之後可見」；選幣只要求最近一次完整刷新未超過 24 小時 |
| I6-1 | Opus | 接受 | 2.5.4.2、2.5.5、F-29、F-68 | 先核對事實再決定可選的結果：nonce N 尚未被用掉（BTC：交易不在鏈上）時不提供結果覆寫，只提供質疑；被其他交易用掉時須貼上該雜湊；醒目警告也比對最近 30 天以使用者覆寫記為 `cancelled` 的意圖。不採用另一項建議（把已結束意圖的成員納入全頁觸發條件）：(iii) 已不允許在 nonce 未被用掉時記為 `cancelled`，該路徑已關閉 |
| I6-2 | Opus | 不需修改（已因簡化而消失） | 2.6 第 2、4 點 | 覆蓋與待處理紀錄已刪除；本機沒有紀錄的花費改為在旗標的全頁說明中一次列出，不逐筆通知 |
| I6-3 | Opus | 接受 | 10.4（D-53）、F-57 | 還原預覽也比對公開種子清單；公開種子的任何 EVM 地址顯示（還原預覽、Vault 與 Wallet 的測試網收款頁）都加「在所有 EVM 網路上相同、私鑰公開」的警告，且不顯示收款 QR |
| I6-4 | Opus | 接受 | 同 GPT R6-I1；2.5.4.3 第 3 點 | 「確認」擴及任何質疑；被標記的來源可由使用者明確解除標記 |
| m6-1 | Opus | 接受 | 同 Codex Minor 2；14.1 `Q-22` 表格 | 表格的揭露文字移到「預設」欄 |
| m6-2 | Opus | 接受 | 2.5.4 表 | 結果覆寫與會新增證據的覆寫分成兩列；後者須用已知且不同營運者的 explorer |
| m6-3 | Opus | 接受 | 2.5.3 出口 (a) | 自動撤銷只看 `signed` 成員達到結算層級的 receipt；覆寫的事實鍵為（帳戶、nonce、覆寫 id）；`Q-24` 的說明補「只涵蓋沒有本機已送出成員的 nonce」 |
| m6-4 | Opus | 接受 | 2.5.4.3 第 3 點、後果評估 | 標記是針對整個來源，可由使用者明確解除；兩處文字統一 |
| m6-5 | Opus | 接受 | 2.5.3 | 量測鎖定同一個 `finalized` 區塊（EIP-1898 的 block-hash 參數，UNVERIFIED） |
| m6-6 | Opus | 接受 | 10.6（D-49）、F-62 | Wallet 付款輸入接受裸地址；EVM 全大寫視為不帶 checksum；拒絕 `0X`、尾端 `.`、多餘的前置 0、超過 21,000,000、空的 query；key 為字面小寫 `amount`；`label`／`message` 的值可含 percent-encoding |
| m6-7 | Opus | 接受 | 同 GPT R6-I3 | — |
| m6-8 | Opus | 部分接受 | 2.6 第 4 點 | 與未知交易競爭時，它的前置交易依 `KEEP-13` 取得並核對；「結果相同」與 50 筆上限的活性問題隨窄確認一起消失 |
| m6-9 | Opus | 接受 | `MN-19`、F-42、F-44 | 同 Codex Minor 1、4；F-55、F-67 已分別在 `MN-20`、`MN-21` 的測試檔 |
| m6-10 | Opus | 接受 | 2.5.2 PM-3 | 部分重疊時維持各集合相加的保守算法 |
| `signedRaw` 引用 | Opus | 接受 | 同 Codex 程式引用 | — |
| M6-01 | Argon | 接受 | 同 Opus m6-6 | — |

### 第七輪（2026-10-20，對第七版 `9339bba`）

Argon 判定 APPROVE；Codex、GPT 6 Pro 與 Opus 判定 APPROVE WITH CHANGES。第八版只做文字修正，不改設計；狀態維持 PROPOSED。GPT 6 Pro 的編號寫成 GPT R7-I1 等。

| ID | 審查者 | 處理 | ADR 位置 | 理由 |
|---|---|---|---|---|
| I7-1 | Codex | 接受 | 2.5.4.3 第 2 點、F-71 | 第二來源的結果依它自己的高度分三種：結算層級高度 ≥ H 可作依據；結算層級高度 < H ≤ `latest` 不算結果；H > `latest` 不證明偽造、也不算結果。後兩種仍可走不受 H 限制的 explorer 核對（`Q-26` 的信任選擇） |
| Minor 1 | Codex | 接受 | 附錄 C D-43 | 「決定」欄改為現行規則，舊條件只留在變動欄 |
| Minor 2 | Codex | 接受 | 2.5.3 出口 (a)、F-45 | 「不再提示」只指同一段 nonce 跳升；`Q-20` 是同畫面中獨立的勾選，不勾時旗標保留 |
| Minor 3 | Codex | 接受 | `MN-19` | 寫明兩端都拒絕的參數，以及 `label`／`message` 只在 Wallet 付款輸入接受 |
| Minor 4 | Codex | 接受 | F-50 | 查詢集合寫成 `0..=min(19, max_address_index)`；「先用 19 再用 15」只用於上界至少 19 的分支 |
| GPT R7-I1 | GPT 6 Pro | 接受 | 同 Codex I7-1 | — |
| GPT R7-I2 | GPT 6 Pro | 接受 | 2.5.4.3 第 3 點、F-72 | 恢復只解除它引用的那一次撤銷；同一事實還有其他有效撤銷時，事實仍不生效；推導結果與匯入順序無關 |
| GPT R7-M1 | GPT 6 Pro | 接受 | 同 Codex Minor 1 | — |
| m7-1 | Opus | 接受 | 同 Codex Minor 1 | — |
| m7-2 | Opus | 接受 | 同 Codex Minor 2 | — |
| m7-3 | Opus | 接受 | 2.5.5 | 只因旗標觸發時顯示第 2.6 節的說明頁，頁內提供 `Q-20` 與「只繼續這一筆」；「這不是重試」只用於列出觸發意圖的頁面 |
| m7-4 | Opus | 接受 | 2.5.4.2、F-29 | explorer 必須顯示已上鏈（BTC 確認數達第 2.7 節的深度）；pending 視同未用；(ii) 的雜湊做基本核對；(i) 以手動結算記錄 |
| m7-5 | Opus | 修改後接受 | 同 Codex I7-1 | 不採用「以區塊時間判斷第二來源是否停滯」：區塊時間同樣由來源回報、無法驗證；改為 H > `latest` 一律不算結果，使用者仍可走 explorer 核對 |
| m7-6 | Opus | 接受 | 2.5.4 第 4 列、2.7 | 產生消耗證據的量測也鎖定同一個 `finalized` 區塊雜湊 |
| m7-7 | Opus | 接受 | 2.5.4.3 第 3 點、F-60、F-68 | 標記針對主機；解除紀錄引用標記事件 id；被標記的主機不算第二來源；同營運者的其他端點不繼承但畫面提示 |
| m7-8 | Opus | 接受 | 同 GPT R7-I2 | 恢復時第二來源也須與撤銷所依據的來源不同營運者；撤銷所依據的第二來源被標記 |
| m7-9 | Opus | 接受 | 2.5.4.3 第 3 點、2.5.5、F-70 | 撤銷上鏈事實時執行結果一併失效；只有上鏈事實的 `pay`／`bump` 結果未知，觸發全頁確認、不記 `paid`；F-70 的新 receipt 來自未被標記的來源 |
| m7-10 | Opus | 接受 | 2.6 第 2、9 點 | 寫明標準同步看不到 mempool 中的未知花費；已知 UTXO 從 `/utxo` 消失又沒有本機成員花用時查一次 `outspend`；mempool 中的未知花費逐筆通知；旗標頁寫明是否已查交易歷史。「每個已用地址多查 `/txs/mempool`」屬於請求預算的設計變更，第八版不加，Phase 2a 實作時再評估 |
| m7-11 | Opus | 接受 | 2.6 第 2 點 | 只有已確認的未知花費才能歸入某意圖，記為 `paid(使用者覆寫, T)`；原成員保留並繼續觸發確認 |
| m7-12 | Opus | 接受 | 2.6 第 4 點 | 競爭前先以 2.5.4.1 驗證那筆交易；清除只花它實際花用的自有輸入；費用並列、經確認、受 `max_fee_sat` 限制 |
| m7-13 | Opus | 接受 | 11.4、`MN-14` | Phase 1a 範圍寫成 D-53 全部；Wallet 測試加 EVM 測試網收款頁 |
| m7-14 | Opus | 接受 | 11.1 | 每個 F 案例只指定一個測試檔：F-55 在 `MN-20`；F-68、F-70、F-71 在 `MN-13`；F-69、F-72 在 `MN-12` |
| m7-15 | Opus | 接受 | 10.6（D-49）、F-62 | 只去除前後的 ASCII 空白；`amount` 只接受 ASCII 數字與一個 `.` |
| （無） | Argon | — | — | 沒有新項目 |

## 附錄 E：FFI 匯出允許清單與輸入契約（`MN-01`）

第 3.4 節的發版檢查要求 FFI 原生庫的已定義動態匯出符號**完全等於**本附錄中「該 App × 該期 × 該層級」的清單；比對以下列逐字名稱進行，不使用萬用字元或前綴（審查意見 Codex R3-I3、Opus R3-2）。**定稿條件**：Phase 0 結束前以實際產物的 `llvm-nm -D --defined-only` 結果定稿本表，並通過「多一個符號」「少一個符號」兩種負向測試；這是 Phase 0 的完成條件。之後任何增刪都必須同時修改本表並經審查。

### E.1 Wallet（`libwallet_ffi.so`）——所有匯出都不得接受種子、助記詞、私鑰、密碼或任何秘密

| 符號 | 參數（位置） | 自 |
|---|---|---|
| `wallet_init` | 無（`crates/wallet_ffi/src/lib.rs:58`） | 現有 |
| `wallet_free_string` | 由本庫配置的字串指標（`:1558`） | 現有 |
| `wallet_cancel_pending_session` | `session_id`（`:66`） | 現有 |
| `wallet_reset_transport_assembler` | `session_id`（`:463`） | 現有 |
| `wallet_verify_signature` | `digest_hex`、`sig_r_hex`、`sig_s_hex`、`sig_v`、`expected_address`（`:92`）；只驗證 | 現有 |
| `wallet_verify_pubkey_address` | `compressed_pubkey_hex`、`expected_address`（`:751`） | 現有 |
| `wallet_decode_intent_json` | `raw_rlp_hex`、`declared_chain_id`（`:148`） | 現有 |
| `wallet_compute_legacy_signing_digest` | `raw_rlp_hex`、`declared_chain_id`（`:191`） | 現有 |
| `wallet_register_pending_tx` | `session_id`、`request_id`、`raw_rlp_hex`、`declared_chain_id`、`expected_address`（`:290`） | 現有 |
| `wallet_build_eth_sign_request_ur` | `session_id`、`request_id_hex`、`raw_tx_hex`、`chain_id`、`derivation_path`、`master_fingerprint_hex`、`expected_address`、`max_fragment_len`（`:966`） | 現有 |
| `wallet_verify_and_assemble_eth_signature_ur` | `session_id`、`request_id_hex`、`sig_ur_or_frames`（`:1293`） | 現有 |
| `wallet_decode_and_verify_multi_accounts_ur` | `ur_or_frames`、`default_chain_id`（`:777`） | 現有 |
| `wallet_encode_psbt_ur` | `psbt_hex`、`max_fragment_len`（`:1490`） | 現有 |
| `wallet_finalize_and_extract_psbt` | `psbt_raw_or_ur`（`:658`） | 現有 |
| `wallet_verify_regtest_account_json`、`wallet_build_regtest_psbt_json`、`wallet_verify_regtest_psbt_response_json` | 各一個 JSON 字串（`crates/wallet_ffi/src/bitcoin_api.rs:385`、`:376`、`:380`）；內容為公開帳戶、UTXO 與前置交易、PSBT | 現有；Phase 0 原地加入 network 欄位（名稱不變，Dart 與 Rust 同版出貨）；Phase 2a 改名為 `wallet_verify_btc_account_json`、`wallet_build_btc_psbt_json`、`wallet_verify_btc_psbt_response_json`，舊名同時移除 |
| `wallet_nfc_chunk_payload` | `session_id`、`request_id`、`message_kind_u8`、`raw_payload_hex`、`chunk_size`（`:564`） | 現有 |
| `wallet_nfc_process_chunk`、`wallet_nfc_process_apdu_frame` | APDU hex（`:622`、`:648`） | 現有 |
| `wallet_nfc_reset_sessions` | 無（`:81`） | 現有 |
| `wallet_verify_nfc_response_json` | `session_id`、`request_id`、`response_payload_hex`（`:437`） | 現有 |
| `fcw_decode_ur_frames` | UR 字串（`:1938`） | 現有 |
| `fcw_free_ur_result` | 由本庫配置的指標（`:1943`） | 現有 |
| `wallet_network_policy_json` | 無 | Phase 0 |
| `wallet_derive_btc_addresses_json`、`wallet_select_coins_json`、`wallet_parse_fee_rates_json`、`wallet_verify_btc_spend_json` | 各一個 JSON 字串：公開擴充公鑰與範圍；UTXO 與前置交易、收款輸出、費率、引用集合；費率回應本文；族外交易 T、被花用的 outpoint 與其前置交易 | Phase 2a |
| `rustsecp256k1_v0_14_context_create`、`rustsecp256k1_v0_14_context_destroy`、`rustsecp256k1_v0_14_default_illegal_callback_fn`、`rustsecp256k1_v0_14_default_error_callback_fn` | 第三方（`secp256k1-sys 0.14.1` 的 `#[no_mangle]`）；不接受秘密 | 現有；**版本相依**，升級 `secp256k1-sys` 時名稱改變、檢查失敗，迫使重新審查（Opus 第三輪以 `llvm-nm` 在已提交的 `tools/nfc_probe/android/app/src/main/jniLibs/arm64-v8a/libwallet_ffi.so` 確認） |

NFC 匯出在 Phase 0 保留（行為不變）；若之後決定從 release 移除，同時修改本表。

### E.2 Vault（`libvault_ffi.so`）——簽署只能經 handle 狀態機（ADR-004）

| 符號 | 參數（位置） | 是否接受秘密 | 自 |
|---|---|---|---|
| `vault_init`、`vault_lock`、`vault_free_string`、`vault_get_primitive_sign_count`、`vault_nfc_reset_sessions` | 無或本庫配置的指標（`crates/vault_ffi/src/lib.rs:174`、`:194`、`:2329`、`:1992`、`:2005`） | 否 | 現有 |
| `vault_generate_mnemonic_json` | `word_count`（`:206`）；**輸出**新助記詞 | 否（輸出秘密） | 現有 |
| `vault_preview_mnemonic_json` | `phrase`、`passphrase`（`:228`） | **是** | 現有 |
| `vault_activate_and_save_mnemonic_json` | `phrase`、`passphrase`、`storage_path`、`pin_password`（`:290`） | **是** | 現有 |
| `vault_check_storage_status_json` | `storage_path`（`:381`） | 否 | 現有 |
| `vault_unlock_from_storage_json` | `storage_path`、`pin_password`（`:453`） | **是** | 現有 |
| `vault_export_encrypted_backup_json` | `backup_password`（`:616`） | **是** | 現有 |
| `vault_preview_encrypted_backup_json` | `backup_json`、`backup_password`（`:666`） | **是** | 現有 |
| `vault_restore_from_encrypted_backup_json` | `backup_json`、`backup_password`、`storage_path`、`new_pin_password`（`:680`） | **是** | 現有 |
| `vault_export_multi_accounts_json`、`vault_export_okx_accounts_json` | `max_fragment_len`（`:558`、`:597`）；以已解鎖金庫匯出公開帳戶 | 否 | 現有 |
| `vault_prepare_legacy_tx` | `session_id`、`request_id`、`raw_rlp_hex`、`declared_chain_id`（`:1029`） | 否；只產生 handle | 現有；Phase 0 起加明確派生路徑（第 3.5 節） |
| `vault_prepare_legacy_tx_with_transport` | 同上另加 `transport_code`（`:842`） | 否 | 同上 |
| `vault_prepare_eip1559_tx` | `session_id`、`request_id`、`raw_payload_hex`、`declared_chain_id`（`:1169`） | 否 | 同上 |
| `vault_prepare_eip1559_tx_with_transport` | 同上另加 `transport_code`（`:933`） | 否 | 同上 |
| `vault_prepare_sign_request` | `session_id`、`request_id`、`cbor_hex`、`declared_chain_id`（`:1320`） | 否 | 現有 |
| `vault_prepare_sign_request_with_transport` | 同上另加 `transport_code`（`:1256`） | 否 | 現有 |
| `vault_prepare_ur_request` | `session_id`、`ur_string`（`:1330`） | 否 | 現有 |
| `vault_prepare_psbt_request` | `session_id`、`psbt_raw_or_ur`、`network_hrp`（`:1460`） | 否 | 現有；Phase 0 刪除 `network_hrp` 參數（第 2.3 節） |
| `vault_approve_and_sign`、`vault_approve_and_generate_signature_ur` | `handle_id`（`:1510`、`:1505`） | 否；唯一的簽署入口 | 現有 |
| `vault_cancel`、`vault_cancel_json`、`vault_get_request_state`、`vault_mark_disconnected` | `handle_id`（`:1740`、`:1771`、`:2017`、`:2064`） | 否 | 現有 |
| `vault_nfc_chunk_payload` | `session_id`、`request_id`、`message_kind_u8`、`raw_payload_hex`、`chunk_size`（`:2091`） | 否 | 現有 |
| `vault_nfc_process_chunk`、`vault_nfc_process_apdu_frame` | APDU hex（`:2226`、`:2290`） | 否 | 現有 |
| `fcw_decode_ur_frames` | UR 字串（`:165`） | 否 | 現有 |
| `fcw_free_ur_result` | 本庫配置的指標（`:169`） | 否 | 現有 |
| `vault_network_policy_json` | 無 | 否 | Phase 0 |
| `vault_verify_receive_address_json` | 網路、branch、index；或 Wallet 收款內容 | 否 | Phase 1a（第 10.6 節） |
| `rustsecp256k1_v0_14_context_create`、`rustsecp256k1_v0_14_context_destroy`、`rustsecp256k1_v0_14_default_illegal_callback_fn`、`rustsecp256k1_v0_14_default_error_callback_fn` | 第三方，同 E.1 | 否 | 現有；版本相依 |

### E.3 各期與層級的組合

| 期 | Wallet release | Vault release | dev 層級 |
|---|---|---|---|
| Phase 0 | E.1 中「現有」與「Phase 0」各列 | E.2 中「現有」與「Phase 0」各列 | 各自再加 `fcw_dev_networks_enabled`（Opus 第三輪以產物確認 cdylib 會匯出上游 crate 的 `#[no_mangle]`，第 3.3 節第 2 點的兩個哨兵都可用） |
| Phase 1a、1b | 同 Phase 0 | 再加 `vault_verify_receive_address_json` | 同上 |
| Phase 2a 起 | 再加 E.1 的 Phase 2a 四個，並把三個 `regtest` 名稱換成新名稱 | 同 Phase 1a | 同上 |

### E.4 不得存在的符號

`vault_load_test_mnemonic`、`vault_create_test_psbt`；全部 `Java_com_mobilecoldwallet_nfc_1probe_*` JNI 匯出（禁止清單可以用前綴比對，允許清單不行；只靠 `test-fixtures` 隔離：`crates/wallet_ffi/src/lib.rs:1569-1570` 的 `mod nfc_probe_jni`、`crates/vault_ffi/src/lib.rs:2380-2575`；其中 `…VaultCoreBridge_nativeLoadTestMnemonic`（`:2391`）是第二個載入測試助記詞的入口）；release 層級的 `fcw_dev_networks_enabled`。第 3.4 節的負向測試涵蓋這些符號。

## 附錄 F：付款模型的驗收案例（`MN-12`、`MN-13`、`MN-19`、`MN-20`、`MN-21`）

每個案例都要**分別**斷言資源狀態、成員有效性與付款結果。「主網、單一來源」指沒有第二主機或第二主機已關閉。

| # | 情境 | 期望資源與成員 | 期望結果 | 來源 |
|---|---|---|---|---|
| F-1 | A 花 {U1}；`bump` A′ 花 {U1, U2}；族外 T 花 {U2} 並結算 | A′ 失效、A 有效；U2 `consumed`；U1 `reserved` | `open`；全頁確認仍出現 | Codex R2-B1 |
| F-2 | A（`pay`）與 C（`cancel`）同集合，C 先結算，第二來源一致 | 全部成員結算或失效 | `cancelled(C)` | Codex R2-B2 |
| F-3 | 同上，A 先結算 | 同上 | `paid(A)` | Codex R2-B2 |
| F-4 | 族外 T 花掉所有成員的共同輸入，T 付給原收款人且金額足夠 | 成員全部失效；其餘資源 `free` | `unresolved`，提示「可能已付款」 | Codex R2-B2、Opus N-1 |
| F-5 | 族外 T 為自轉帳 | 同上 | `unresolved`，提示「看起來未付款」；需使用者依 2.5.4.2 核對後選擇 | Codex R2-B2 |
| F-6 | 伺服器回報被 T 花掉，但取不到 T、T 的簽章無效、或 T 的 sighash 不是 ALL | 不變 | 不變；記錄可疑回應 | Opus N-1、R3-3 |
| F-7 | EVM receipt `status = 0`，只有單一來源 | nonce `consumed` | `unresolved`；第二來源回報相同 `status = 0` 與區塊雜湊後才 `failed` | Opus N-4、Codex R3 Minor 3 |
| F-8 | EVM receipt 存在，但同一層級量測的 nonce 不大於該 nonce | 不變 | 不採信；適用 2.5.4 第 1、2 列 | Opus N-4、R3-1 |
| F-9 | RPC 回報 `pending = latest + 1000` | 不變 | 警告；不自動採用 | Opus N-3 |
| F-10 | nonce N 只有 `exported` 成員（Vault 拒簽），使用者要付另一筆 | N 被引用 | 新付款以 nonce N 加入 N 的集合；不產生 N+1；若 Wallet 持有已簽 bytes，另提供「先送出 A」 | Opus N-6、m3-12 |
| F-11 | 一筆已送出、`pending` 的 A，RPC 的 `pending` 回到 N | 不變 | 獨立付款使用 N+1 | Argon B-03（第一輪） |
| F-12 | A 花 {X_f, Y}；以只花 Y 的 `cancel` C 取代並結算 | Y `consumed`；A 失效；X_f `free` 且存疑，不會被自動選用 | `cancelled(C)`（主網單一來源時為 `unresolved`） | Opus N-2、m3-1、Argon M3-01 |
| F-13 | A 費用接近 `max_fee_sat` | — | 匯出前顯示「可能無法取消」並要求確認 | Codex R2-I2、Opus N-5 |
| F-14 | A 已簽但從未送出，以較低費用的新成員取代 | 依 PM-2 | Vault 接受；Wallet 提示可能被拒收 | Argon NB-02 |
| F-15 | 商家換地址：同意圖新增 `pay` 成員 | 共同輸入被引用 | 任一成員結算後為 `paid` | Argon NI-01 |
| F-16 | 匯出備份 S → 建立並簽署 A → 還原 S | — | 帳戶標為「歷史可能不完整」；每一筆新付款前出現第 2.6 節的全頁說明，直到 `Q-20` 的全面確認 | Codex R2-I1 |
| F-17 | 匯入較舊的備份（成員狀態較舊、證據較少，沒有新的有效引用） | 本機紀錄不減少；狀態重新推導，與匯入前相同 | 不變；旗標不因匯入而清除 | Codex R2-I1、R3-I1、R4-I1、Opus m3-3 |
| F-18 | 已結算的成員在觀察期內被回報為不在鏈上 | 撤銷證據；重新推導 | 回到 `open`／`unknown` 並通知 | Codex R2-I3 |
| F-19 | 第二主機 404、落後、區塊雜湊不同、receipt `status` 不同、以 `finalized` 量測的 nonce 不同 | 不變 | 不算一致；不結算 | Codex R2-I3、R3 Minor 3、Opus m-4 |
| F-20 | 收款 index 5 已發出但未收款，高水位 37，之後收到款 | — | 一般同步即可看到（第 6.4 節第 5 點） | Codex R2-I4、Argon NB-01 |
| F-21 | 掃描未完成時，以只用已保留輸入的 `bump`、`cancel`、變更收款資訊的 `pay`、「用 A 的資源付新款」與 `rescue` 建立成員 | — | 允許；若加入新輸入則要求掃描完整 | Opus m-1、m3-9、m4-14，Argon M4-01 |
| F-22 | 只有一個已確認、receipt 成功、尚未結算的 `pay` 成員 | — | 不出現全頁確認，只顯示一行 | Opus N-7 |
| F-23 | 交易所換新地址、金額相同 | — | 全頁確認並醒目警告 | Opus N-7 |
| F-24 | 在 2.5.5 的全頁觸發條件成立時選「另一筆新的付款」 | — | 必須經全頁確認、勾選並長按；預設按鈕是取代。觸發條件不成立時依 F-22 只顯示一行 | Opus m-11、Codex R3 Minor 3 |
| F-25 | A 花 {X_f}；`bump` A′ 花 {X_f, Y}；發現 X_f 存疑後，建立只花 Y 的 `rescue` R 並結算 | Y `consumed`；A′ 失效；A 仍可能上鏈；X_f 被 A 引用且存疑；R 的輸出為 `free` | 原意圖 `open`，**不是** `cancelled`；R 的意圖 `done(R)`（主網單一來源時為 `unresolved`）；全頁確認仍出現；不得以刪除紀錄、重裝或關閉保留通過 | Codex R3-B1、GPT 第三輪 B1 |
| F-26 | S 的 M 花 {U1} 結算，另一成員 A 花 {U1, U2} 失效，U2 變 `free`；新集合的 B 花 {U2} 並已顯示 QR；M 在觀察期內被重組掉 | A 恢復可能上鏈；`refs(U2) = {A, B}`；兩個集合不合併 | 帳戶進入「需要調解」，停止 PM-4(b)、(d) 與 `clearing`，調解確認前不提供「另一筆新的付款」；畫面寫明 B 可能已簽、Wallet 無法撤回請求。另一支：Wallet 已取回並驗證 B 的簽章時，畫面寫明 B 已簽、簽章無法收回。另以「重組前匯出備份、重組後匯入」與「調解中重啟 App」各跑一次 | Codex R3-I4、R4 Minor 3，GPT 第三輪 B2，Opus m3-10 |
| F-27 | 主網、單一 RPC：A（nonce N）被扣留；`cancel` C 的 receipt、`finalized` 與 `latest` 都由同一 RPC 捏造 | nonce `consumed` | `unresolved`，標示未經第二來源核對；全頁確認出現 | Opus R3-1 |
| F-28 | EVM `status = 0` 的 receipt 尚未最終 | — | 觸發全頁確認，不只顯示一行 | Opus R3-1 |
| F-29 | EVM「nonce 被用掉、查不到 receipt」的 `unresolved`；使用者核對 explorer：(i) nonce N 被本機成員的雜湊用掉（已上鏈）；(ii) 被另一筆已上鏈的交易用掉；(ii′) explorer 只顯示 pending 的交易；(iii) 尚未被用掉 | — | (i) 以手動結算記錄該成員；(ii) 貼上雜湊並經基本核對後才能選結果；(ii′)(iii) 不提供結果覆寫，只提供「質疑這筆證據」，畫面寫明原交易仍可能上鏈。不詢問收款人是否收到 | Opus R3-1、I6-1、m7-4 |
| F-30 | 還原後的清除交易只花到標準 gap-20 掃描找到的 UTXO，遺留交易 A 花的是 index 37 的 UTXO | — | 旗標**保留**：清除從不解除旗標，只有 `Q-20` 的全面確認可以 | GPT 第三輪 B3 |
| F-31 | RPC 回報 `latest = 1000`，本機已知最高消耗 nonce 為 9 | 不變 | 停止建立，要求使用者在 explorer 核對並確認 | GPT 第三輪 I3 |
| F-32 | 發送方帳戶被回報有委派標記；使用者要取消 nonce N 的付款 | — | 取消為 0 金額、付給另一個已配對且被回報沒有 code 的 EVM 帳戶；`eth_getCode` 查詢失敗時不建立任何請求 | GPT 第三輪 B4、Opus m4-4 |
| F-33 | 10 ETH 餘額，A 待付 9 ETH；使用下一個 nonce 付 5 ETH | — | 警告「加上未結算的付款後餘額不足」並要求確認 | GPT 第三輪 I4 |
| F-34 | 成員紀錄存檔失敗 | 無新成員 | QR 不顯示 | 第一輪 MN-12 回歸（Codex R3 Minor 5） |
| F-35 | 兩個畫面同時為同一帳戶建立請求 | 只有一個成員建立成功 | 另一個畫面顯示鎖定中 | 同上 |
| F-36 | `POST` 送出後收到 `-22`、之後查詢回 404 | 不變 | 成員 `unknown`；只能查詢或重送同一份 bytes | 同上 |
| F-37 | 主網：A 花 {X}；已送出的 A′ 花 {X, Y}；X 只因第二主機落後而被標為存疑，其實是有效 UTXO。建立只花 Y 的 `rescue` R（未結算），接著 (1) 嘗試以新意圖的 `pay` P={Y} 付給原收款人並加入 R 的集合；(2) 嘗試以 PM-4(b) 用 Y 付款；(3) 加速 R；(4) R 結算；(5) 匯出備份、還原並重啟 | (1)(2) 在建立前被拒（P 不能加入 `rescue` 集合；Y 是 `reserved`）；(3) 只接受全自有輸出的 `rescue` 成員；R 結算後 Y `consumed`、A′ 失效、A 仍可能上鏈 | R 的意圖 `done(R)`（單一來源時為 `unresolved`）；原意圖 `open`，全頁確認仍出現；還原與重啟後相同；之後以 R 的輸出付給原收款人必須經 PM-4(b) 的全頁確認 | Codex R4-B1、Opus I4-2、GPT R4-I2 |
| F-38 | A′ 已以 30,000 sat 送出並花 {X_f, Y}；Y 只有 10,000 sat；使用者明確選擇以 2,000 sat 建立 `rescue` R | — | 允許，畫面寫明與 A′ 競爭；R 被節點拒收時一切不變；R 結算時為 `done(R)`（主網單一來源時為 `unresolved`），原意圖維持 `open` | GPT R4-B1、Opus m4-1、Codex R5 Minor 3 |
| F-39 | `rescue` R 花用分屬兩個集合、各以 10,000 sat 送出的成員所引用的輸入；R 付 11,000 sat 且費率較高 | — | 預檢判定低於「各集合最高手續費之和加增量轉發費」，提示可能被拒收；使用者可依 F-38 明確選擇 | GPT R4-I4 |
| F-40 | 主網、第二主機關閉：還原的備份缺少花 X 的已簽付款 A；以清除 C 花 X；C 的結算深度只由單一主機回報 | X `consumed`（單一來源） | C 的意圖 `unresolved`，不是 `done`；旗標保留；之後的新付款仍出現全頁說明 | GPT R4-B2 |
| F-41 | （第七版刪除：只為已移除的窄確認而存在，見第 14.2 節） | — | — | GPT R4-I5 |
| F-42 | 主網：真實的下一個 nonce 是 10，nonce 10 只有 `exported` 成員；惡意 RPC 在真實的 finalized 區塊 H 回報 nonce 11、所有 receipt 為 null；之後換成誠實 RPC，其 finalized 高度 ≥ H、回報 10 | nonce 10 先被記為 `consumed`、`L_local = 11`；換 RPC 後進入「nonce 證據有爭議」，停止新付款；使用者在與兩個 RPC 都不同營運者的 explorer 核對「沒有交易用掉 nonce 10」後撤銷該事實 | `L_local` 回到 10，nonce 10 的成員復活並依 PM-6(i) 處理；下一筆付款只能加入 nonce 10 的集合，不會排在缺口後面 | Codex R4-I2、R6 Minor 4，GPT R4-B3 |
| F-43 | F-27 之後換成誠實 RPC（finalized 高度 ≥ C 的證據高度，回報 nonce N 未被用掉） | 進入「nonce 證據有爭議」；在與兩個 RPC 都不同營運者的 explorer（或第二來源）核對後，撤銷捏造的消耗證據 | A 與 C 都恢復可能上鏈；意圖從 `unresolved` 回到 `open`；全頁確認出現 | Codex R4-I2 |
| F-44 | 換成真正落後的 RPC：回報的 nonce 小於 `L_local`，其 finalized 高度也小於證據高度 | 不變 | 顯示「可能只是落後，也可能原證據是偽造的」，提供「質疑這筆證據」的入口，以 `L_local` 為起點繼續，不停止、不重用 nonce | Codex R4-I2、R6 Minor 1 |
| F-45 | F-31 的兩個出口：(a) explorer 顯示 nonce 等於 `L_rpc`，並分「同時勾選 `Q-20`」與「不勾」兩支；(b) 兩者不一致 | (a) 新增使用者覆寫證據並計入 `L_local` | (a) 繼續建立，同一段跳升不再提示；勾選 `Q-20` 時旗標解除，不勾時旗標保留、之後每一筆付款仍顯示第 2.6 節的說明。(b) 不建立，引導更換或加入 RPC | Opus I4-1、m7-2，Codex R7 Minor 2 |
| F-46 | 本機 A′={U1, U2} 因 M={U1} 結算而失效，U2 為 `free`；匯入的備份含仍未結算的 B={U2}，沒有任何撤銷證據 | U2 → `reserved({B})`；若同時被其他集合引用則進入 PM-6 | 不變；一般選幣不會選到 U2 | Codex R4-I1、GPT R4-I1、Opus I4-3 |
| F-47 | X_f 有存疑紀錄；匯出備份、還原到新安裝，再與另一份不含該紀錄的備份合併；之後第二主機回報 X_f 存在 | 還原與合併後 X_f 仍為存疑；第二主機回報後新增解除紀錄 | 不變 | Opus I4-3 |
| F-48 | F-26 的調解：(1) 使用者確認後重啟 App；(2) 確認前建立 `cancel`；(3) 確認前以 PM-4(b) 付款；(4) 確認後匯入的備份讓受影響集合多一個成員 | (1) 不再進入調解；(2) 允許；(3) 拒絕；(4) 重新進入調解 | 被多重引用的資源在確認後仍是 `reserved` | Opus I4-5 |
| F-49 | Vault 核對 `bitcoin:<自有地址>?r=https://…`、`?pj=…`、`?label=…`；Wallet 轉帳頁貼上含 `pj` 或 `req-*` 的付款連結 | — | Vault 顯示「不一致：含有 FCW 不支援的參數」；Wallet 拒絕該連結 | GPT R4-B5 |
| F-50 | 高水位 H=0；上界至少 19 的分支：Vault 單獨顯示 branch 0 的 index 19 並收款，同步後探索掃到 20–39；Vault 再單獨顯示 index 15，晚到的款項在 15 確認；之後重啟、從備份還原。上界為 10 的分支：固定範圍是 0–10，單獨顯示 19 被拒。另以完整刷新失敗跑一次；另嘗試單獨顯示 index 37 | 完整刷新實際送出的查詢集合包含 `0..=min(19, max_address_index)` | index 15 在下一次完整刷新或手動刷新後出現，重啟與還原後亦同；刷新失敗時不顯示掃描完整；index 37 只能經核對 Wallet 的收款內容顯示 | GPT R4-I3、R6 Minor，Codex R6-B1、R7 Minor 4 |
| F-51 | 發送方被回報有委派：(1) 轉 USDC；(2) 原生幣轉到被回報有 code 的地址；(3) 原生幣轉到被回報無 code 的地址，只有一個 RPC；(4) ERC-20 收款人等於發送方；(5) 唯一的 RPC 對另一個 EVM 帳戶謊報無 code | — | (1)(2) 逐筆勾選回呼風險並長按；(3) 一般確認並標示「只依單一 RPC 判斷」；(4) Wallet 不建立；(5) 取消仍會建立，畫面寫明只依單一 RPC 判斷。自呼叫判斷比較外層 `to`，不是 calldata 收款人 | GPT R4-B4、Codex R4、Opus m4-4、Argon M4-02 |
| F-52 | v1 歷史含 EVM `executionFailed` 與一個無法識別的狀態 | 前者遷移為 `unknown` 並附舊 receipt 失敗觀察，「曾由本 Wallet 送出」為真；後者為 `exported` | 付款警告不消失；設「歷史可能不完整」；重新查詢後依第 2.7 節結算 | Codex R4-I3、Opus m4-7 |
| F-53 | 主網、單一 RPC 回報 A 的 receipt 成功並達到 finalized；使用者又要付同一個收款人 | — | A 為 `paid`，標示「未經第二來源核對」；新付款出現醒目警告 | Opus m4-11 |
| F-54 | RPC 不支援 `finalized`；使用者在不同營運者的 explorer 核對後手動結算 nonce N 的成員 | nonce N `consumed`（使用者覆寫） | 只記錄一次結果；`L_local` 計入 N | Opus m4-6、I4-1 |
| F-55 | 主網、兩個主機都誠實：還原的備份缺少已簽付款 A={U}（U 早已確認，A 沒有找零、以低費率停在 mempool）；另有自有 UTXO V | 交易歷史與 `outspend` 找到被 A 花用的 U，記為本機沒有紀錄的已簽交易 | 旗標保留；清除可以花用 U 與 A 競爭（費用高於 A，A 的前置交易依 `KEEP-13` 核對）；不論清除結果，旗標只能以 `Q-20` 解除 | GPT R5-B1、Opus m6-8 |
| F-56 | （第七版刪除：只為已移除的窄確認而存在，見第 14.2 節） | — | — | GPT R5-B1 |
| F-57 | Vault 載入 `PUBLIC_TEST_SEEDS` 中的種子：(1) 開啟 BTC 主網與 Ethereum 主網的收款頁；(2) 掃描 Wallet 的主網收款內容核對；(3) 重新顯示先前的收款頁；(4) 測試網收款頁；(5) 還原預覽 | — | (1)(2)(3) 都拒絕並顯示「此助記詞是公開或開發用的測試助記詞，不可用於主網」，`vault_verify_receive_address_json` 對 `Main` 回同一錯誤；(4) BTC 測試網照常，EVM 測試網顯示「在所有 EVM 網路上相同、私鑰公開」的警告且不顯示 QR；(5) 不回傳主網 BTC 地址，EVM 地址加同一警告 | GPT R5-B2、Opus I5-1、I6-3 |
| F-58 | OKX（或被入侵的 Wallet）送來 Ethereum 主網請求，`to` 是合約 C，C ≠ 簽署帳戶 | — | Vault 審查頁顯示與來源無關的委派回呼揭露；每次解鎖後的首次主網確認頁顯示完整說明 | GPT R5-I2 |
| F-59 | F-42 的變形：惡意 RPC 回報 nonce 11，並把 finalized 高度捏造成 H_bad = 1,000,000,000；之後換上兩個不同營運者的誠實 RPC，都回報 10，高度都遠低於 H_bad | 不自動進入爭議（只顯示診斷與入口）；使用者選「質疑這筆證據」，以第二來源或不同營運者的 explorer 核對後撤銷該事實 | `L_local` 回到 10；nonce 10 的集合復活並依 PM-6(i) 處理；原 RPC 被標記；重啟、以及匯入帶有同一假證據的舊備份後，假證據都不復活 | Codex R5-B1、GPT R5-I1 |
| F-60 | nonce 10 真的已被用掉（證據正確）；另一個錯誤的 RPC 回報 nonce 9 | 沒有核對時 `L_local` 不下降，真實消耗證據不刪除；使用者核對後記「確認」 | 錯誤的 RPC 主機被標記；在解除標記或更換之前，它的回報不再進入爭議，不單獨構成任何新的消耗證據，也不算第二來源 | Codex R5-B1、Opus I5-4、m7-7 |
| F-61 | `L_local = 50`；本機以 nonce 50 送出 A；使用者又以 OKX 送出 nonce 51；`L_rpc = 52`；使用者選 F-31 的出口 (a) | 覆寫只涵蓋 nonce 51；A 不受影響 | A 之後達到 finalized 時為 `paid`，不是 `unresolved` | Opus I5-3 |
| F-62 | 付款輸入與收款核對的語法：EVM 的 `ethereum:0x…@1?value=…`、`ethereum:<代幣>/transfer?address=…`、未通過 EIP-55 的混合大小寫地址、全小寫與全大寫地址、`0X` 前綴；BTC 的裸地址、`BITCOIN:BC1Q…`（全大寫）、混合大小寫地址、重複 `amount`、`%61mount=1`、`#x`、`bitcoin://…`、`bitcoin:<地址>?`、`amount=1e-3`、`amount=-1`、`amount=0`、`amount=0.000000001`、`amount=1.`、`amount=01.5`、`amount=21000001`、`label=x`、`label=Coffee%20Shop`、全形數字的 `amount`、前後有空白與中間有空白的輸入 | — | EVM 的 URI 都拒絕；EIP-55 不符與 `0X` 拒絕；全小寫與全大寫接受並以 EIP-55 顯示；BTC 裸地址與全大寫接受；其餘 BTC 案例都拒絕；`label`（含 `%20`）在 Wallet 付款輸入接受、在 Vault 核對為不一致；全形數字拒絕；Wallet 付款輸入去除前後空白後接受，中間有空白則拒絕 | Opus I5-2、m6-6，Codex R5 Minor 1，Argon M5-02、M6-01 |
| F-63 | Vault 掃描 `bitcoin:<index 37 的地址>`（可能來自本 Wallet，也可能來自持有同一 xpub 的其他工具）；另掃描一個不屬於本 Vault 的地址 | — | 前者在有界派生中找到 index 37 並顯示「一致」，另提示「只有本 Wallet 已發出的 index 才會被自動追蹤……請在 Wallet 執行深度掃描」，確認後才在本次畫面顯示 QR；後者顯示「不是本 Vault 在此範圍內的收款地址」 | GPT R5-I4、R6-I3，Opus m6-7 |
| F-64 | 存疑紀錄 S1 被解除紀錄 L1（引用 S1）解除；另一台裝置在 L1 之前的時間、但並行地新增 S2；兩邊合併 | S1 失效；S2 仍有效 | 結果與合併順序、兩邊時鐘無關 | GPT R5-I3、Opus m5-4 |
| F-65 | v1 BTC 紀錄為 `draft`，`request` 為 null | 不建立成員 | 不觸發全頁確認 | Opus m5-6 |
| F-66 | EVM nonce n 只有尚未簽署的清除成員；使用者要付款 | 付款不能加入清除集合 | 選項只有「送出清除」或「以新的清除取代」 | Opus m5-3 |
| F-67 | 廣播前再查一次 `eth_getCode`：(1) 取消的目的帳戶改被回報有 code；(2) 發送方改被回報有委派 | — | (1) 不廣播這筆取消；(2) 先補做第 4.6 節政策 2 的確認 | Opus m5-10 |
| F-68 | 主網、單一 RPC：FCW 以 nonce 10 經它送出付款 A；它扣住 A，並回報 finalized 與 latest 的 nonce 都是 11、A 沒有 receipt；使用者在不同營運者的 explorer 看到 nonce 10 尚未被用掉 | nonce 10 先被記為 `consumed`，意圖 `unresolved` | 不能「標為未付款」；只能質疑這筆證據；撤銷後 A 恢復可能上鏈，全頁確認的預設按鈕是以 nonce 10 的新成員取代；唯一的 RPC 被標記，新成員無法經它結算，畫面建議更換 RPC | Opus I6-1 |
| F-69 | A 已結算（6 層、第二來源一致），使用者誤把它的上鏈證據撤銷；之後以第二來源核對並恢復 | 撤銷時 A 復活、U 回到 `reserved`；恢復後 A 再次結算，因撤銷而加的來源標記移除 | 恢復後 `paid(A)`；重啟與匯入都維持恢復的結果 | GPT R6-I1、Opus I6-4 |
| F-70 | 來源對 M 回報 receipt `status = 0`，但 M 實際在同一區塊執行成功；使用者撤銷錯誤的執行結果 | 只撤銷執行結果的事實；上鏈的事實與 nonce 的消耗保留 | 之後從未被標記的來源取得的 `status = 1` receipt 照常採用，`paid(M)` | GPT R6-I1 |
| F-71 | 消耗證據的高度 H=100；第二來源分三種：(1) finalized 110、latest 120，回報 nonce 未被用掉；(2) finalized 95、latest 105；(3) latest 90 | — | (1) 可作為撤銷依據；(2)(3) 不算核對結果，畫面仍提供不受 H 限制的 explorer 核對；(3) 不把原證據判為偽造 | Codex I7-1、GPT R7-I1、Opus m7-5 |
| F-72 | 同一上鏈事實：誤撤銷 R1 → 恢復 R1 → 之後真的重組，撤銷 R2；以三種不同順序匯入包含這些事件的備份 | 事實不生效；成員復活、資源保留、進入調解 | 三種順序的結果相同；恢復 R1 不會讓 R2 失效 | GPT R7-I2、Opus m7-8 |
