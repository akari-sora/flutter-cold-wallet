<!--
Maintainer notes (not rendered):
1. Both apps embed the full text in their About page (packages/design_system/lib/src/privacy_policy.dart);
   packages/design_system/test/privacy_policy_test.dart compares the two. Change both together.
2. GitLab Pages must serve this as an HTML page, not as a raw .md file or a PDF.
3. Written for the 1.2.1+9 candidate. Before the mainnet version ships, update section 3 and the effective date.
-->

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
