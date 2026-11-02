// The full privacy policy, embedded because the Vault cannot open a web page.
// It must say what docs/privacy/privacy-policy.*.md say; the maintainer
// comment there is the only difference test/privacy_policy_test.dart allows.

/// Traditional Chinese, the primary text.
const fcwPrivacyPolicyZhTw = r'''
# FCW 隱私權政策

生效日期：2026 年 10 月 23 日

本隱私權政策說明 FCW 專案維護者（以下稱「開發者」）在 Google Play 發布的兩個 App 如何處理你的資料：

- **FCW Watch**（觀察錢包，套件名稱 `com.coldwallet.watch`）
- **FCW Vault**（離線金庫，套件名稱 `com.coldwallet.vault`）

兩個 App 搭配使用：Vault 裝在一支不連網的手機上保存助記詞並簽署交易；Watch 裝在連網的手機上，只保存公開資料，負責查詢與廣播。兩支手機之間只透過螢幕上的 QR 碼交換資料。

## 1. 摘要

- 開發者**不經營 App 伺服器**，App 沒有帳號或登入功能。App 不會向開發者傳送任何資料；如果你自行寄信聯絡支援，開發者會收到你寄送的內容（見第 11 節）。開發者不會出售你的資料。
- **FCW Vault 不能連網**：App 沒有網路權限，資料只存在那支手機上。
- **FCW Watch 只連到你自己填入的節點**（RPC 網址），並把查詢與廣播需要的地址、公開描述（descriptor）和已簽交易送過去。該節點的營運者看得到這些資料，以及你的 IP 位址。
- 兩個 App 都使用 Google ML Kit 在手機上辨識 QR 碼，並移除了 ML Kit 傳送診斷資料的元件（見第 4 節）。兩個 App 都沒有任何分析或遙測。
- 兩個 App 都**沒有廣告**。

## 2. FCW Vault（離線金庫）

### 2.1 網路

Vault 沒有 Android 的網路權限，App 內的任何程式（包含第三方元件）都無法把資料傳出手機。Vault 只會在螢幕上顯示 QR 碼，由你用另一支手機掃描。

### 2.2 存在手機上的資料

- **加密金庫**：你的助記詞以你設定的「App 解鎖密碼」加密後保存（AES-256-GCM；加密金鑰由 PBKDF2-HMAC-SHA256、600,000 次迭代推導），存在 App 的私有儲存空間，並已排除在 Google 雲端備份與裝置間資料轉移之外。
- **簽章結果紀錄**：已簽交易的公開內容（不含私鑰或助記詞），讓你在需要時重新顯示簽章 QR 碼。
- **加密備份檔**：只有在你按下「匯出加密備份」並自己選擇存檔位置時才會產生，以你另外設定的「備份密碼」加密。檔案存在你選的位置，App 不會傳送它。

### 2.3 權限

- **相機**：只用來掃描 QR 碼。影像在手機上辨識，不會儲存或傳送。
- **生物識別與裝置鎖**：解鎖金庫時，App 請 Android 系統確認你的指紋、臉部或螢幕鎖定密碼。App 只收到「驗證成功或失敗」，拿不到你的生物特徵資料或鎖定密碼。

### 2.4 其他

- Vault 禁止截圖與螢幕錄影，離開畫面時會自動上鎖。
- 你按「複製公開簽章 UR」或「複製配對 UR」時，簽章結果或配對資料會放進手機的剪貼簿，同一支手機上的其他 App 可能讀得到。配對資料含擴充公鑰，讀到的人可以推算出這些帳戶的所有地址。

## 3. FCW Watch（觀察錢包）

### 3.1 存在手機上的資料

- 從 Vault 匯入的公開帳戶資料：地址、公鑰、擴充公鑰與 descriptor、主指紋、派生路徑、你取的帳戶名稱。
- 你選的網路與 RPC 網址。
- 交易紀錄：包含已簽交易的完整內容，讓 App 在廣播結果不明時只查詢同一筆交易，不會要求重新簽署。
- Bitcoin 交易草稿與紀錄。

Watch 不保存私鑰或助記詞。Bitcoin Core 節點的 RPC 使用者名稱與密碼只放在記憶體中，離開 Bitcoin 畫面就清除，不會寫入檔案。以上資料都排除在 Google 雲端備份與裝置間資料轉移之外。

### 3.2 傳送到你的節點的資料

Watch 沒有內建任何遠端伺服器，預設網址都指向手機本身（`127.0.0.1`）。只有在你填入節點網址、並執行查詢或廣播時，Watch 才會把下列資料送到**該節點**：

- **EVM 網路**（目前為 Ethereum Sepolia 測試網與本機開發鏈）：你的地址（查詢餘額、代幣餘額與 nonce）；建立交易時的付款地址、收款地址、金額與交易資料（估算手續費）；Vault 簽好的交易（廣播）；交易雜湊（查詢狀態）。
- **Bitcoin**（目前只支援 regtest，連到你自己架設的 Bitcoin Core 節點）：含擴充公鑰的接收與找零 descriptor（節點可以由此推算出這個帳戶的所有地址）、地址、前一筆交易的 txid、簽好的交易，以及你填的 RPC 使用者名稱與密碼（只送給該節點，用於節點驗證）。

此外，每一次連線都會讓節點（以及中間的網路業者）看到你手機的 IP 位址。Watch 本身不讀取、不使用你的 IP 位址，也不取得你的位置。

### 3.3 誰會收到這些資料

收到資料的是你選的節點營運者：可能是你自己的節點，也可能是你選用的第三方 RPC 服務。對方如何保存與使用這些資料，依對方自己的條款與隱私權政策，開發者無法控制，也不會收到這些資料。請只使用你信任的節點。節點也可能回報錯誤的餘額或交易狀態。

### 3.4 加密

使用 `https://` 網址時，連線以 TLS 加密。Watch 只對下列主機接受 `http://` 網址，其他主機一律要用 `https://`：

- 同一支手機：`localhost`、`127.0.0.0/8`、`::1`。
- 私有網路位址：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`169.254.0.0/16`、`fc00::/7`、`fe80::/10`。
- 不含點的主機名稱，以及結尾為 `.local` 的名稱。

使用 `http://` 時，資料以**明文**傳送。連到同一支手機時，資料不會離開手機；連到私有網路或本地名稱時，同一個網路上的其他裝置可以看到你的地址與交易，連到 Bitcoin Core 節點時還包括含擴充公鑰的帳戶描述（descriptor）與節點帳號密碼。App 會在網址欄位下方說明是哪一種情況。只在你信任的家用網路使用 `http://`。

### 3.5 其他

- **相機**：只用來掃描 QR 碼。影像在手機上辨識，不會儲存或上傳。
- **公開帳戶備份**：只有在你按下匯出並自己選擇存檔位置時才會產生。備份包含地址、公鑰與交易紀錄，不含私鑰、助記詞或 RPC 網址。這些公開資料仍屬隱私，請妥善保管。
- **剪貼簿**：你按「複製地址」或「複製待簽資料」時，地址或完整的待簽交易請求（包含收款地址、金額、派生路徑與主指紋等）會放進手機的剪貼簿，同一支手機上的其他 App 可能讀得到。

## 4. Google ML Kit

兩個 App 都使用 Google ML Kit 條碼掃描功能（內建在 App 中的版本），在手機上辨識 QR 碼。相機影像不會上傳。

依 Google 的公開說明，ML Kit 會收集裝置資訊、App 資訊、每次安裝產生的識別碼與效能指標等診斷與用量資料，並傳給 Google。**FCW Watch** 與 **FCW Vault** 的正式版都移除了 ML Kit 傳送這些資料的元件，因此不會傳送；FCW Vault 另外沒有網路權限。

## 5. 我們不做的事

- 沒有帳號、登入、廣告、推播通知。
- 沒有任何分析、追蹤或當機回報元件。
- 不讀取位置、聯絡人、相簿、簡訊、通話紀錄或其他 App 的資料。
- 不出售、不出租、不交換任何資料。

## 6. 透過 Google Play 下載

你從 Google Play 下載與更新 App 時，Google 會依自己的政策處理相關資料，這不在開發者的控制範圍內。

## 7. 資料保存與刪除

- 開發者沒有保存 App 收集的資料，因此沒有可由開發者刪除的 App 資料。你自行寄給支援信箱的郵件，依第 11 節處理。
- **FCW Watch**：在 App 內按「移除觀察帳戶」會把帳戶從帳戶清單刪除；交易紀錄等其他本機檔案仍會保留。要刪除全部資料，請到 Android「設定 → 應用程式 → FCW Watch → 儲存空間」清除資料，或解除安裝 App。已經送到節點的資料，需向該節點的營運者要求刪除。
- **FCW Vault**：解除安裝或清除儲存空間會永久刪除手機上的加密金庫。刪除前請確認你有助記詞紙本備份或加密備份檔；否則資產無法找回，開發者也無法協助還原。
- 你匯出的備份檔存在你自己選的位置，請自行管理與刪除。

## 8. 安全

**本專案未經第三方安全稽核，請先小額使用。** 私鑰與助記詞只存在 Vault 手機上，開發者拿不到，也無法替你找回。專案 repository 為 <https://gitlab.com/aa22396584/mobile_cold_wallet>；匿名訪客目前會被導向 GitLab 登入，存取需要驗證，也可能需要 repository 權限。兩個 App 授權為 AGPL-3.0-or-later，並附加允許使用 Google ML Kit 與 Google Play 服務的額外許可。任何發行 App 的人仍必須依 AGPL 要求提供對應原始碼（Corresponding Source）。

## 9. 兒童

這兩個 App 的目標使用者是 18 歲以上的成人，不以兒童為對象。App 不會替開發者收集個人資料，也包括兒童的資料。

## 10. 政策變更

本政策更新時，會修改本頁並更新上方的生效日期；重大變更也會寫在 App 的更新說明中。日後版本若新增連線對象（例如預設的區塊鏈查詢服務），會先更新本政策再發布該版本。

## 11. 聯絡方式

隱私問題或使用支援請寄信至 <mailto:aa22396584@gmail.com>，這是開發者已公開列出的支援信箱。App 不會自動寄信。你自行聯絡此信箱時，開發者會收到寄件地址與你選擇提供的內容；你的郵件服務商與 Gmail 也會依各自的政策處理郵件。開發者僅使用這些往來郵件處理你的請求，並只在處理請求或適用法律義務所需期間保存。你可向同一信箱要求刪除支援往來郵件。請勿寄送助記詞、私鑰、App 解鎖密碼或備份密碼；除非問題確實需要，請避免附上地址、交易或擴充公鑰。

專案議題頁面 <https://gitlab.com/aa22396584/mobile_cold_wallet/-/issues> 需要 GitLab 驗證，也可能需要 repository 權限。請勿在該處張貼私密錢包資料。
''';

/// English.
const fcwPrivacyPolicyEn = r'''
# FCW Privacy Policy

Effective date: October 23, 2026

This privacy policy explains how the two apps that the FCW maintainers ("the developer") publish on Google Play handle your data:

- **FCW Watch** (watch-only wallet, package name `com.coldwallet.watch`)
- **FCW Vault** (offline vault, package name `com.coldwallet.vault`)

The two apps work together. The Vault runs on a phone that stays offline; it holds the recovery phrase and signs transactions. The Watch runs on a phone with internet access; it holds public data only and checks balances and broadcasts transactions. The two phones exchange data only through QR codes shown on screen.

## 1. Summary

- The developer **runs no app servers**, and the apps have no accounts or sign-in. The apps do not send any data to the developer. If you choose to email support, the developer receives the information you send (see section 11). The developer does not sell your data.
- **FCW Vault cannot go online.** It has no network permission, and its data stays on that phone.
- **FCW Watch only connects to the node you enter yourself** (an RPC URL). It sends that node the addresses, public descriptors and signed transactions needed to check balances and broadcast. Whoever runs that node can see this data and your IP address.
- Both apps use Google ML Kit to read QR codes on the phone, with ML Kit's components for sending diagnostic data removed (see section 4). Neither app contains any analytics or telemetry.
- Neither app shows **ads**.

## 2. FCW Vault (offline vault)

### 2.1 Network

The Vault does not have Android's network permission, so no code in the app, including third-party components, can send data off the phone. The Vault only shows QR codes on its screen for you to scan with the other phone.

### 2.2 Data stored on the phone

- **Encrypted vault**: your recovery phrase is stored encrypted with the app unlock password you set (AES-256-GCM; the key is derived with PBKDF2-HMAC-SHA256, 600,000 iterations). It is kept in the app's private storage and excluded from Google cloud backup and device-to-device transfer.
- **Signed results**: the public content of transactions you signed (no private keys or recovery phrase), so the app can show the signature QR code again when needed.
- **Encrypted backup file**: created only when you tap "export encrypted backup" and pick where to save it. It is encrypted with a separate backup password you set. The file is saved where you choose; the app never sends it anywhere.

### 2.3 Permissions

- **Camera**: used only to scan QR codes. Images are processed on the phone and are not stored or sent.
- **Biometrics and screen lock**: to unlock the vault, the app asks Android to confirm your fingerprint, face or screen-lock PIN/password. The app only receives "succeeded" or "failed"; it never gets your biometric data or your screen-lock secret.

### 2.4 Other

- The Vault blocks screenshots and screen recording, and locks itself when you leave the app.
- When you tap "copy public signature UR" or "copy pairing UR", the signed result or the pairing data goes to the phone's clipboard, where other apps on the same phone may be able to read it. The pairing data contains extended public keys, from which anyone who reads it can derive every address of those accounts.

## 3. FCW Watch (watch-only wallet)

### 3.1 Data stored on the phone

- Public account data imported from the Vault: addresses, public keys, extended public keys and descriptors, master fingerprint, derivation path and the account name you choose.
- The network you picked and your RPC URL.
- Transaction history, including the full signed transaction, so that if a broadcast result is unclear the app only looks up that same transaction and never asks you to sign again.
- Bitcoin transaction drafts and history.

The Watch never stores private keys or the recovery phrase. The RPC user name and password for a Bitcoin Core node are kept in memory only, cleared when you leave the Bitcoin screen, and never written to a file. All of this data is excluded from Google cloud backup and device-to-device transfer.

### 3.2 Data sent to your node

The Watch has no built-in remote server; its default addresses point to the phone itself (`127.0.0.1`). Only after you enter a node URL and run a query or a broadcast does the Watch send the following to **that node**:

- **EVM networks** (currently the Ethereum Sepolia test network and local development chains): your address (to check balances, token balances and the nonce); when you build a transaction, the sender, recipient, amount and transaction data (to estimate the fee); the transaction signed by the Vault (to broadcast it); and transaction hashes (to check status).
- **Bitcoin** (currently regtest only, through a Bitcoin Core node you run yourself): the receive and change descriptors, which contain your extended public key (the node can derive every address of the account from them); addresses; the txids of previous transactions; the signed transaction; and the RPC user name and password you enter (sent only to that node so it can authenticate you).

Every connection also lets the node, and the networks in between, see your phone's IP address. The Watch itself does not read or use your IP address and does not access your location.

### 3.3 Who receives this data

The data goes to the operator of the node you chose: your own node or a third-party RPC service you picked. How they store and use it is governed by their own terms and privacy policy. The developer has no control over it and never receives it. Use only nodes you trust. A node can also report wrong balances or transaction status.

### 3.4 Encryption

With an `https://` URL the connection is encrypted with TLS. The Watch accepts `http://` URLs only for the following hosts; every other host must use `https://`:

- This phone: `localhost`, `127.0.0.0/8` and `::1`.
- Private network addresses: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `fc00::/7` and `fe80::/10`.
- Host names without a dot, and names ending in `.local`.

With `http://` the data is sent **unencrypted**. To this phone it never leaves the phone; to a private network or a local name, other devices on the same network can see your addresses and transactions, and for a Bitcoin Core node also the descriptors that contain your extended public key, and the node's user name and password. The app says which case applies under the URL field. Use `http://` only on a home network you trust.

### 3.5 Other

- **Camera**: used only to scan QR codes. Images are processed on the phone and are not stored or uploaded.
- **Public account backup**: created only when you export it and pick where to save it. It contains addresses, public keys and transaction history, but no private keys, recovery phrase or RPC URL. This public data is still private; keep the file safe.
- **Clipboard**: when you tap "copy address" or "copy unsigned request", the address or the full unsigned transaction request (including the recipient, amount, derivation path and master fingerprint) goes to the phone's clipboard, where other apps on the same phone may be able to read it.

## 4. Google ML Kit

Both apps use Google ML Kit barcode scanning (the version bundled inside the app) to read QR codes on the phone. Camera images are not uploaded.

According to Google's published documentation, ML Kit collects diagnostic and usage data, such as device information, app information, a per-installation identifier and performance metrics, and sends it to Google. The release versions of **FCW Watch** and **FCW Vault** both have the ML Kit components that send this data removed, so they do not send it. FCW Vault also has no network permission.

## 5. What we do not do

- No accounts, sign-in, ads or push notifications.
- No analytics, tracking or crash-reporting components.
- No access to location, contacts, photos, SMS, call logs or other apps' data.
- No selling, renting or trading of any data.

## 6. Downloading from Google Play

When you download or update the apps from Google Play, Google processes the related data under its own policies, which the developer does not control.

## 7. Data retention and deletion

- The developer stores no data collected by the apps, so there is no app data for the developer to delete. Email you choose to send to support is handled as described in section 11.
- **FCW Watch**: "remove watch-only account" deletes the account from the account list; other local files, such as transaction history, remain. To delete everything, clear the app's storage in Android Settings (Apps → FCW Watch → Storage) or uninstall the app. Data already sent to a node can only be deleted by that node's operator.
- **FCW Vault**: uninstalling the app or clearing its storage permanently deletes the encrypted vault on the phone. Before you do, make sure you have your written recovery phrase or an encrypted backup file. Otherwise your assets cannot be recovered, and the developer cannot help restore them.
- Backup files you export are saved where you choose; manage and delete them yourself.

## 8. Security

**This project has not been audited by a third party. Start with small amounts.** Private keys and the recovery phrase exist only on the Vault phone; the developer cannot access or recover them. The project repository is <https://gitlab.com/aa22396584/mobile_cold_wallet>. Anonymous visitors are currently redirected to GitLab sign-in; access requires authentication and may also require repository permission. The apps are licensed under AGPL-3.0-or-later with an additional permission for Google ML Kit and Google Play services. Anyone distributing the apps remains responsible for providing Corresponding Source as required by the AGPL.

## 9. Children

Both apps are intended for adults aged 18 and over and are not directed at children. The apps do not collect personal data for the developer, including from children.

## 10. Changes to this policy

When this policy changes, this page and the effective date above are updated, and significant changes are also noted in the app's release notes. If a future version adds a new party the app connects to (for example a default blockchain data service), this policy will be updated before that version is released.

## 11. Contact

For privacy questions or support, email <mailto:aa22396584@gmail.com>. This is the developer's publicly listed support address. The apps never send email automatically. If you contact this address, the developer receives your sender address and the message you choose to send; your email provider and Gmail also process the message under their own policies. The developer uses this correspondence only to handle your request and retains it only as long as needed for that purpose or applicable legal obligations. You can request deletion of your support correspondence at the same address. Never send a recovery phrase, private key, unlock password or backup password; avoid including addresses, transactions or extended public keys unless needed for your question.

The project issue page at <https://gitlab.com/aa22396584/mobile_cold_wallet/-/issues> requires GitLab authentication and may also require repository access. Do not post private wallet details there.
''';
