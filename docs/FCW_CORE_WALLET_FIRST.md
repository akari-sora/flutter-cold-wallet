# FCW QR 核心版本：可操作的 local/testnet 子集

> 本文由私有開發存檔整理而來。文中的 commit SHA（例如 `003c49de`、`7fd2a75`、`0e20162`）與 APK SHA-256 指向私有存檔 repo 與當時的本機建置；公開 repo 從單一起始 commit 開始，查不到這些 SHA。原始執行紀錄與證據檔留在私有存檔，不隨公開 repo 發布。
>
> 下文的「通過」「PASS」只表示當時那一顆 APK 在本機節點、regtest 或測試網上的操作結果，不是安全性保證，也不是第三方稽核。

## 範圍

2026-10-18：審查後的修正已進入實作與測試，最新產物另外凍結來源、建置及核對；見 [修正範圍](FCW_REMEDIATION_2026-10-18.md)。實際 APK 身份與各版驗收以對應的 source manifest、artifact audit 及執行收據為準。下列裝置狀態及 PASS 是原驗收當時的歷史紀錄，不代表任何手機目前的狀態，也不替新候選背書。

- 最後一組 QR 核心安裝包（私有存檔 `release-btc-request`）：Wallet SHA-256 `2a839800950ebeaddb488f0fcfeb20bc0295e37e04c4e1052284edc7f8efde7f`，Vault SHA-256 `ac7038f30836f3c574981ccb03d996e68d20cfde05b8fc0bf93e3010b8d23227`。
- 這組在 API 35 模擬器、手動貼上 UR、本機 Anvil 或 Bitcoin regtest 上做過 Legacy、EIP-1559、ERC-20、Bitcoin PSBT，以及公開備份還原。
- stock OKX 6.192.0 畫面上的待簽 QR 已能讀出並解碼；新建的空金庫依政策拒絕這張請求，沒有核准、回傳或廣播。
- 尚未完成：OKX 收回簽名並廣播、相機對相機、S8 裝置驗證、iOS 真機與模擬器執行（2026-10-18 第三輪已完成 `--no-codesign` 編譯）、Ledger。NFC 已延後，原始碼與測試保留。

基準為 `003c49de`。主交付是 `apps/wallet`、`apps/vault` 及共用核心；完整原始目標尚未結案。NFC 延後的原因是先完成雙 App QR 核心流程，不阻塞此子集；Ledger USB／BLE 排在核心流程之後。

## 主 App 已接線的功能

- Vault 不自動載入測試助記詞。系統 CSPRNG＋BIP39 新建、隱藏單字備份抽考、助記詞／passphrase 還原預覽、獨立 App 密碼、真實裝置驗證及解密、背景／逾時／取消撤銷與清除秘密。
- AES-256-GCM schema 2、PBKDF2-HMAC-SHA256 600,000 次、至少 12 字元且非全數字密碼；KDF／版本／指紋／其他 metadata 受驗證且有界。新金庫原子發布並禁止覆寫。Android 用 renameat2(RENAME_NOREPLACE)，已修正實機 SELinux 拒絕 hard link 的問題。
- 公開 UR／CBOR 配對由實際金庫派生；Wallet 驗證、公鑰對地址、摘要確認、保存、去重、命名／切換／移除及重啟恢復。BTC tpub 重新派生收款／找零與 descriptor。
- Vault 的「自有 Wallet」與「OKX EVM」配對分開。後者依 Keystone 官方 OKX adapter 匯出真正 `m/44'/60'/0'` 帳戶公鑰、chain code、parent fingerprint，另附完整 `/0/0` 的 `account.ledger_live` leaf 公鑰（不附 chain code）；普通／passphrase 金庫都驗證與自有配對地址一致，不沿用歷史 Probe 的 key／path 混合寫法。公開匯入拒絕 `is-private=true`。
- Wallet 原生幣／白名單 Token 真實餘額、完整十進位顯示、載入／更新時間／離線／錯誤；未取得資料不顯示 0。完整鏈上歷史沒有索引來源，介面明確只列本機紀錄。
- 轉帳地址／金額空白起始，整數精確計算並拒絕非法格式、過多小數、負值與溢位；nonce／fee／gas 由 RPC 取得或明確手動輸入。Legacy、Type-2、Sepolia USDC／DAI transfer；Token 合約與網路顯示，未知合約／approve／隱藏 ETH 價值拒絕。
- 有界且真正重組的多幀 UR；原始交易獨立解析、本機可見批准、request／digest／chain／帳戶／policy 綁定、簽章自驗與 Wallet 驗章、真正 raw transaction、明確廣播確認。節點接受、待確認、執行失敗、結果待查分開；不確定結果查同一 hash 並保留原 bytes。
- EVM 確認頁顯示 native 同一解析物件的類型、nonce、Gas、精確費率、原生幣數量、完整 calldata／access list。欄位缺失、損壞或與交易意圖及費用不一致時禁止批准。Sepolia Amsterdam 的 12,000 Gas 僅開放已核對簽署者的 Type-2 空資料／空 access list 自轉帳；其他網路與交易形狀保留原限制，不套用為主網規則。
- Wallet 待簽畫面被撤銷後，可在本機歷史重新核對原始交易，明確確認後接收原 request ID／原 bytes 的既有簽章。恢復入口不顯示原未簽 QR、不要求 Vault 重簽、不自動廣播；背景仍撤銷接收授權。取消待簽請求不等於撤銷已產生的簽章。
- Vault 批准前先原子記錄不可變識別，成功後保存公開回傳；鎖定／背景／重啟可唯讀重顯示，私鑰維持鎖定。回傳 QR 預設暫停，可播放多幀。重掃相同已簽請求撤銷新 handle 並使用既有回傳，不再呼叫簽章；簽署已開始但結果未保存時顯示待查，不能當成新請求重簽。Native EVM 的 32-byte digest 亦已真正接入審查模型。
- Vault 加密檔案備份／還原及紙本重新驗證；Wallet 公開帳戶／本機交易備份分離，排除 RPC 帳密，匯入有界、重新驗證、分步確認與中斷續做。
- Wallet 的 xpub／descriptor／交易紀錄排除 Android 自動雲端備份與裝置轉移，iOS 儲存目錄亦設定備份排除；公開備份由使用者明確匯出。iOS 設定尚待實機驗證。
- BTC 主畫面接入 regtest UTXO、前筆交易驗證、收款／找零、明確 sat 費用、PSBT v0／P2WPKH／SIGHASH_ALL、回傳綁定、finalize／broadcast／確認查詢。
- 正式 QR native 匯出不含測試助記詞、測試 PSBT 或 Probe JNI。Wallet 不依賴 vault_core；Vault release 無 INTERNET／NFC 權限，條碼模型與圖示字型隨 APK 打包。

原版四類 demo 路徑已移除：Vault 測試助記詞與占位 UR、Wallet 預設測試帳戶與只顯示提示的配對、浮點／預設金額與固定交易參數、未驗章／固定 hash／catch 假廣播成功。

## 已取得的結果及邊界

| 層級 | 實際結果 |
|---|---|
| Rust workspace | 當時 108 tests 及 doc tests 通過，包含原有 NFC 純單元回歸；這不代表射頻驗收 |
| Wallet / Vault widget＋production host FFI | Wallet 79、Vault 72 tests 通過；完整新建／重開／真正解密、請求綁定、錯誤與還原、兩種配對、不完整 BTC／EVM 禁止批准及已簽回傳的保存／鎖定／重啟／重掃；原待簽紀錄明確確認恢復、背景晚到 RPC 撤銷、production 原生庫既有簽章驗證及改金額／ID／帳戶拒絕；320dp／200% 字級、明暗主題及真實 native 錯誤可讀性 |
| 共用 Dart／Flutter packages | public_models 267、qr_ui 12、design_system 12 tests 通過，包含完整 EVM 參數及深層不可變 access list、公開交易值的完整讀屏標籤及長按選取、明暗版面回歸、真 native EVM digest 與 BTC 金額／找零／輸入數映射回歸 |
| Python host / 真實節點 | 8 tests 通過；其中真實 Anvil 一般／passphrase 各完成 Legacy、Type-2、ERC-20，Bitcoin Core 31.1 regtest 真正 mempool 接受且已確認；另有兩種配對一致性及獨立 CBOR 核對 |
| S8 Vault 正常 UI | 真實隨機新建、備份抽考、加密保存、公開配對、重開鎖定及身份一致；一般助記詞的真實 SAF 加密備份在乾淨 App 資料還原、錯備份口令拒絕、完整地址／指紋一致；裝置驗證不可用時拒絕。非空 BIP39 passphrase 的還原／新交易簽章只有 core／host 與模擬器結果，未算此實機 PASS |
| 專用 Android API 35 x86_64 模擬器 | 正常還原同一測試金庫、核對完整 EVM 0／1 地址、正式自有／OKX 公開配對；真正 SystemUI 裝置驗證取消後維持鎖定，正確的測試用系統密碼＋App 密碼可解密回到相同指紋。不是 S8 身分驗證或相機光學證據 |
| 新版 Vault 的 Android 公開交易檢視 | 一張 stock OKX 請求的 17 個實際可見欄位、政策與可用批准按鈕通過，每個值都對得上原始 UI 節點。此請求正常取消，批准／簽章均為 0；不是 OKX 回傳或節點接受證據 |
| 兩個獨立 Android 模擬器＋正式主 App＋本機節點 | Wallet 實際配對／保存／重啟，輸入有效地址與精確金額，取得 RPC nonce／Gas／費用，生成真正 UR；Vault 正常還原及裝置驗證後逐欄審查，三筆各批准一次；Wallet 接收簽章、native 驗章、組裝 raw、明確單次廣播及查 receipt。Type-2／Legacy／ERC-20 分別在 Local Anvil 區塊 1／2／3 成功；不是公開 Sepolia、光學或真機證據 |
| `7fd2a75` APK 更新與錯誤狀態 | 兩 App 保留資料更新成功；Vault 鎖定重開仍可唯讀重顯示三個原簽章。Anvil 停止後 Wallet 顯示真實 RPC 錯誤及「無法查詢」，歷史保留；沒有假零值、假成功或新增簽章 |
| S24 Wallet 正常 UI（先前版本） | 公開配對確認／保存／重開、真實 RPC 精確餘額、Token 錯誤；本機公開檔案匯出／匯入、取消／損毀拒絕與去重；乾淨 Wallet 還原帳戶與已簽交易，先結果待查、重新驗章後查同一 hash 確認 |
| 兩個 Android 主 App＋真實節點 | 正式手動 UR 交換、Vault 核對與批准、Wallet 真 native 驗章／明確廣播／receipt 成功；不是相機對相機的光學證據 |
| Bitcoin 兩個 Android 主 App | Wallet 建 PSBT／畫面多幀 QR，Vault 從加密備份還原後獨立核對、批准一次，Wallet 驗章／廣播，Core 31.1 regtest 已確認；Wallet 重開仍保留原 PSBT 與簽章，可重新驗證 |
| stock OKX Android 6.192.0（736208） | 正式 Vault 雙 key adapter 配對 QR 經相簿掃入、帳戶選擇、保存及完整 EVM 地址核對通過；stock App 建立的 Sepolia Type-2 自轉帳請求已能擷取並解碼。簽章回傳／廣播及節點結果仍未通過，不能以配對或 request 解碼代替 |

本機節點上的交易都在隔離的 Anvil loopback（chain ID 31337，或刻意設成 11155111 的本機鏈）或 Bitcoin Core regtest 上執行，不是公開 Sepolia。ERC-20 測試用的是在政策 USDC 地址部署的本機 TestToken，不是公開的 USDC。

測試後，S8 與 S24 上本輪新建的 QA 金庫、測試 App 資料與測試匯出檔已依指紋與檔案 hash 核對後清除；沒有刪除既有資料。這不代表撤銷既有簽章，也不代表安全抹除所有備份或記憶體。

## 模擬器補充紀錄（`0e20162` 之後）

以下都在 API 35 模擬器上、以手動貼上 UR 進行，EVM 交易送往本機 Anvil（chain 11155111，非公開 Sepolia），BTC 送往 Bitcoin Core 31.1 regtest；全部是新建的測試金庫，沒有真實資產。

| 項目 | 結果 |
|---|---|
| EIP-1559、Legacy、ERC-20（政策 USDC 地址上的本機測試代幣） | Vault 審查後簽署，Wallet 驗章、廣播，receipt status `0x1` |
| 待簽畫面撤銷後恢復 | Wallet 離開前景後撤銷待簽畫面，從交易紀錄「核對並接收原請求既有簽章」收回同一份簽章並廣播；回到前景後按鈕可再按 |
| 非空 BIP-39 passphrase | 錯誤 passphrase 的預覽指紋不同且沒有啟用；正確 passphrase 還原後指紋一致並可簽署 |
| Vault 加密備份 | 錯誤備份密碼被拒且不顯示指紋；正確密碼還原後指紋與 EVM #0 一致；備份內容沒有寫進紀錄 |
| Wallet 公開備份 | 匯出檔只有允許的欄位，沒有助記詞、私鑰或 RPC 帳密；清掉資料後分步匯入，紀錄先顯示結果待查，重新查詢同一 hash 後才顯示已確認 |
| BTC PSBT | PSBT v0、BIP-84 P2WPKH 審查與簽署，Wallet 驗章、廣播，regtest 確認；已確認紀錄可放進公開備份並在乾淨 Wallet 還原 |
| 裝置驗證逾時與背景 | 逾時顯示「裝置驗證逾時，請重試，金庫維持鎖定」；提示顯示時離開前景顯示「應用程式已離開前景，請重新驗證，金庫維持鎖定」；之後正確裝置密碼仍可解鎖 |

權限審計通過：Vault 沒有 INTERNET、NFC、ACCESS_NETWORK_STATE。兩 App analyzer 無問題，workspace Clippy 正常模式通過；嚴格 `-D warnings` 仍被既有 NFC 程式的 manual_div_ceil／too_many_arguments／type_complexity 等警告阻擋，workspace `cargo fmt --check` 也有既有格式差異。

## 直接操作

1. 在專用 Vault 裝置先設定可用的裝置鎖定／生物識別，使用離線環境。開啟 Vault，選新建或還原；分清 BIP39 passphrase、App 密碼及獨立備份密碼。完成備份抽考，或先核對還原地址再啟用。
2. 在 Vault 顯示公開帳戶配對 QR。Wallet 掃描後核對摘要並按「確認並儲存」，可命名、切換、移除觀察帳戶。收款時逐字核對 Wallet 與 Vault 本機地址。
   stock OKX 則在 Vault 選「OKX EVM」，OKX 選新增錢包 → 連接硬體錢包 → Keystone → 掃碼連接；匯入後比對完整 EVM 地址。目前只驗證過從相簿匯入配對 QR，未驗證相機對相機。
3. Wallet 選 local/testnet，設定 RPC 並核對 chain ID。輸入有效收款地址、精確金額；同步 nonce／fee／gas，再生成未簽 QR。
4. Vault 掃描、檢查完整 chain／簽署帳戶／收款／金額／合約／費用，明確批准。Wallet 掃回簽章並驗證，再確認廣播；按查詢核對 receipt，不能把 hash 當成確認成功。
   若 Wallet 待簽畫面已撤銷，從本機交易紀錄選原請求，核對完整交易後按「核對並接收原請求既有簽章」，掃同一份回傳。不要為了取回簽章重新建立交易或讓 Vault 重簽。
5. 秘密備份在 Vault 的加密備份功能完成，先重新驗證紙本助記詞及原 passphrase，再用獨立強密碼儲存本機檔案。乾淨 Vault 先預覽地址再還原。公開備份在 Wallet 工具列操作，帳戶與交易各自確認；恢復的交易先驗章、查原 hash。
6. BTC 選 regtest 帳戶，連到 Bitcoin Core 的 disable_private_keys 觀察錢包（txindex=1），在 Wallet 輸入 RPC 帳密、匯入公開 descriptor、讀 UTXO、輸入收款／金額／sat 費用。再依相同 QR 批准／驗證／廣播／查確認流程操作。RPC 帳密只留 Wallet 記憶體。

本機 ETH 節點例子：`anvil --silent --host 127.0.0.1 --port 18545 --chain-id 31337`。USB 實機可用 `adb -s <Wallet 裝置序號> reverse tcp:18545 tcp:18545`，Wallet 選 Local Anvil 31337 及 `http://127.0.0.1:18545`。只用測試金庫；測試資金可由此本機節點的 anvil_setBalance 設定。

## 建置與重跑

前置需求與各平台的完整指令見 [README](../README.md#build-and-test)。在 repo root（`cargo` 與 `python3` 在 PATH 上）：

```sh
cargo test --workspace
cargo build --release -p vault_ffi -p wallet_ffi
forge build --root tests/fixtures/local_token
python3 -m pytest tests/integration/test_fcw_core_wallet_first_qr_e2e.py tests/integration/test_qr_real_node.py tests/integration/test_qr_bitcoin_regtest.py tests/integration/test_okx_pairing_profile.py -q
```

Windows 可用 `./tools/build_android_qr.ps1` 建兩個 APK，輸出 `target/qr-core/wallet-qr-local-test.apk`、`vault-qr-local-test.apk`，再用 `python tools/release_checks/verify_qr_apks.py` 檢查實際權限、離線相機模型及原生匯出。只有在沒有設定 `FCW_KEY_PROPERTIES`、且該 App 的 `android/key.properties` 不存在時，才是 debug certificate 簽署的 release 組態本機測試 APK，不是商店發佈。`FCW_KEY_PROPERTIES` 指定的檔案不存在，或必要欄位缺少／空白時，建置失敗；`storeFile` 為相對路徑時以該設定檔所在目錄為準。`verify_qr_apks.py` 會記錄實際簽章憑證，可用 `--expect-cert-sha256` 要求特定憑證。App 的 `flutter analyze`／`flutter test` 各自在 `apps/wallet`、`apps/vault` 執行；host 測試可用 `WALLET_FFI_PATH`／`VAULT_FFI_PATH` 指向 host 平台建出的原生庫。

私有存檔另保留 `ef678d9`、`7fd2a75`、`427c87f`、`0e20162` 等版本的測試 APK 與各自的 SHA-256 收據；這些 APK 沒有公開發布。

## 尚未完成，不能計為 PASS

- 相機對相機光學 QR、真正裝置身分驗證成功及裝置鎖屏／生物識別取消的完整實機矩陣；S8 尚未成功使用系統驗證，沒有繞過。Android 解鎖門禁支援安全裝置在沒有 class-3 生物識別時僅以裝置密碼驗證；API 35 模擬器在 PIN、零枚已登錄指紋下可解鎖，取消後停在鎖定畫面。手機全系統的飛航／射頻隔離也未驗證，Android App 權限限制另有 APK 檢查。
- Android 兩個主 App 的 Legacy、Type-2、ERC-20 已通過隔離節點實機手動 UR 流程；不外推為公開測試網資產或光學相機互掃，Token 測試亦不是實際公開 USDC。
- BTC 實際雙 App 手動標準 UR 流程已通過；相機對相機光學交換仍未驗，不外推為其他 PSBT／script／SIGHASH 或主網能力。
- iOS 已完成兩個 target、FFI 靜態庫接線、Keychain／LocalAuthentication、儲存／備份排除、檔案挑選器與隱私遮罩；當時在 Windows 上無法進行 Xcode 編譯、簽名、模擬器或真機測試，第三方相機 SDK 的 iOS 網路行為仍待驗。見 `QR_NATIVE_PLATFORMS.md`。
- stock OKX Android 6.192.0（736208）：早期 leaf-only／account-root-only 配對失敗及無資產入口的 BLOCKED 結果保留在私有存檔。後續的雙 key 配對已讓 stock App 產生真正的 Sepolia Type-2 低 gas 自轉帳請求；原始 UR 由 stock QR 擷取，native 獨立解析與 host 互通測試都不能代替 stock 完整成功。目前沒有 Vault 簽章、OKX 接收或廣播結果，也沒有假報成功或重簽。iOS、extension 各自 NOT_RUN；沒有改簽主網。
- Personal Sign／EIP712 正式 QR 入口採拒絕，需完成對應本機完整訊息／domain 審查後才能擴充。這不是所有 DeFi 的批准。
- schema 1 自製加密資料不自動遷移或覆寫，原檔保留；既有資料需以已驗證備份在乾淨環境還原。沒有宣稱手機能硬體內簽章，也沒有將清除測試 App 資料當成所有備份／記憶體的安全抹除。
- Vault 公開回傳日誌目前最多保留 128 筆請求識別、20 筆完整回傳、2 MiB；識別標記不自動刪除。容量滿／日誌損毀時拒絕新批准，已知結果缺失時拒絕重簽。這份公開日誌與秘密備份分開，清除 App 資料不會從助記詞自動重建既有回傳。
- Ledger USB／BLE 及延後的 NFC 原需求保留，完整全功能目標未結案。

下一個可執行增量：用 stock OKX 配對時的同一座測試金庫核對 OKX 畫面上的即時請求，再做一次批准、回傳、廣播與 receipt；新建的空金庫已經依政策拒絕這張請求，不能拿別的鑰匙代替。相機對相機及 S8 裝置驗證仍待實機。iOS 要在有 Xcode 的 Mac 上編譯、簽名並上模擬器或真機。Bitcoin 維持已通過的 regtest、P2WPKH、SIGHASH_ALL 子集。NFC 不作為主線，程式保留。
