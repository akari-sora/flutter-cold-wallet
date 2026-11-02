# Upstream Sources & Pinned Dependencies Specification

- **Document Version**: 1.1.0
- **Verification Date**: 2026-10-12
- **Work Package**: FCW-OKX-20261012
- **Integrity Baseline**: Benchmark Mode (Frozen SHA, Zero Dynamic HEAD)
- **License Status**: Internal review by the project, not a legal opinion or a third-party audit. Dependencies are under permissive licenses (MIT, Apache, BSD, CC0, Zlib and similar) with two exceptions: the Linux-desktop-only transitive Dart dependency `dbus` (MPL-2.0, file-level copyleft) and S17 ML Kit (proprietary, bundled by `mobile_scanner`). The project's own license is in `LICENSE` at the repository root.

---

## 1. Upstream Specifications and Protocols (S01–S04, S18–S22, S26–S30)

| ID | Name | Category | Authoritative URL | Version / Revision | SPDX License | Purpose & Boundary Notes |
|---|---|---|---|---|---|---|
| **S01** | OKX Keystone Connect Spec | External Spec | `https://web3.okx.com/help/how-do-i-connect-my-keystone-hardware-wallet-to-okx-wallet` | 2026-08-11 official revision | Public Documentation | Entry point reference for hardware/air-gap pairing; external contract, not internal trust root. |
| **S02** | Keystone OKX Mobile Guide | External Guide | `https://www.keystone3.com/en/docs/okx-mobile/` | 2026-08-15 documentation snapshot | Public Documentation | Multi-chain account pairing guide; reference for user interaction flow. |
| **S03** | Keystone Multichain Spec | Protocol Spec | `https://dev.keyst.one/docs/integration-tutorial-advanced/multichain` | 2026-08-01 specification snapshot | Open Specification | Specification for `crypto-multi-accounts` UR encoding and structure. |
| **S04** | Keystone Ethereum QR Spec | Protocol Spec | `https://dev.keyst.one/docs/integration-tutorial-advanced/ethereum` | 2026-08-01 specification snapshot | Open Specification | Specification for `eth-sign-request` and `eth-signature` wire formats. |
| **S18** | BIP-174 (PSBT v0) | Bitcoin BIP | `https://github.com/bitcoin/bips/blob/927b6de9915c9262615a6399de51b200f81e5aa4/bip-0174.mediawiki` | BIP standard | CC0-1.0 | Standard for Partially Signed Bitcoin Transactions v0. Pinned to immutable commit `927b6de9915c9262615a6399de51b200f81e5aa4`. |
| **S19** | EIP-155 (Replay Protection) | Ethereum EIP | `https://eips.ethereum.org/EIPS/eip-155` | Final standard | CC0-1.0 | Legacy Type 0 replay protection and chainId encoding rules. |
| **S20** | EIP-1559 (Fee Market Tx) | Ethereum EIP | `https://eips.ethereum.org/EIPS/eip-1559` | Final standard | CC0-1.0 | Type 2 transaction format, maxFeePerGas, maxPriorityFeePerGas parsing. |
| **S21** | EIP-712 (Typed Data) | Ethereum EIP | `https://eips.ethereum.org/EIPS/eip-712` | Final standard | CC0-1.0 | Structured typed data hashing; strict template whitelist signing only. |
| **S22** | EIP-7702 (Set Code Tx) | Ethereum EIP | `https://eips.ethereum.org/EIPS/eip-7702` | Draft standard | CC0-1.0 | **Fail-closed**: explicitly rejected in initial release. |
| **S26** | ERC-191 (Signed Data) | Ethereum ERC | `https://eips.ethereum.org/EIPS/eip-191` | Final standard | CC0-1.0 | personal_sign format (`\x19Ethereum Signed Message:\n`) prefix validation. |
| **S27** | ERC-2612 (Permit) | Ethereum ERC | `https://eips.ethereum.org/EIPS/eip-2612` | Final standard | CC0-1.0 | **Fail-closed**: explicitly rejected in initial release to prevent gasless allowance exploitation. |
| **S28** | Keystone Bitcoin PSBT Guide | External Guide | `https://dev.keyst.one/docs/integration-tutorial-advanced/bitcoin` | 2026-08-01 specification snapshot | Open Specification | Specification for `crypto-psbt` exchange workflow. |
| **S29** | BIP-32 (HD Wallets) | Bitcoin BIP | `https://github.com/bitcoin/bips/blob/927b6de9915c9262615a6399de51b200f81e5aa4/bip-0032.mediawiki` | BIP standard | CC0-1.0 | Hierarchical Deterministic wallet derivation algorithm standard. Pinned to immutable commit `927b6de9915c9262615a6399de51b200f81e5aa4`. |
| **S30** | BIP-39 (Mnemonic Code) | Bitcoin BIP | `https://github.com/bitcoin/bips/blob/927b6de9915c9262615a6399de51b200f81e5aa4/bip-0039.mediawiki` | BIP standard | CC0-1.0 | Mnemonic sentence generation, checksum, and seed derivation standard. Pinned to immutable commit `927b6de9915c9262615a6399de51b200f81e5aa4`. |

---

## 2. Upstream Code Repositories & Pinned Commit SHAs (S05–S11, S23–S25, AUX-01–04)

All Git dependencies and referenced code repos are frozen at immutable 40-character commit hashes. No dynamic branch tracking (`HEAD`, `main`, `master`) is permitted.

| ID | Module / Crate | Type | Authoritative Repository | Pinned Version / Tag | Pinned Commit SHA (40-hex) | SPDX License | Purpose & Boundary Constraints |
|---|---|---|---|---|---|---|---|
| **S05** | Keystone ur-registry (TS) | Reference Repo | `https://github.com/KeystoneHQ/ur-registry` | `v0.8.0-multi-accounts` | `7d64aa9012a04b54b7d5a40bb5999d869f92fb6f` | Apache-2.0 | Reference implementation & cross-verification test fixtures for `CryptoMultiAccounts`. |
| **S06** | Keystone `eth_sign_request.rs` | Source File | `https://github.com/KeystoneHQ/keystone-sdk-rust` | libs/ur-registry/src/ethereum/eth_sign_request.rs | `9de4a760b0e6d8693204c3fdf9dc148d82b9e831` | MIT | Verification of `dataType` (1..4) semantics and defensive handling of optional fields. |
| **S07** | Keystone `eth_signature.rs` | Source File | `https://github.com/KeystoneHQ/keystone-sdk-rust` | libs/ur-registry/src/ethereum/eth_signature.rs | `9de4a760b0e6d8693204c3fdf9dc148d82b9e831` | MIT | Verification of 65-byte `r \|\| s \|\| v` wire format and recovery ID conventions. |
| **S08** | Keystone Rust SDK (`ur-registry`) | Rust Crate | `https://github.com/KeystoneHQ/keystone-sdk-rust` | `ur-registry = "=1.0.8"` | `9de4a760b0e6d8693204c3fdf9dc148d82b9e831` | MIT | BC-UR / CBOR serialization adapter. **Transport only; NOT a trust root.** |
| **S09** | Coconut Vault | Reference Project | `https://github.com/noncelab/coconut_vault` | `Commit-pinned (0b1ea16)` | `0b1ea167a487b67d2d54e7c1e627dc3f6a3d557d` | MIT | Architectural reference for offline Vault app. **All trademarks and brand assets stripped.** |
| **S10** | Coconut Wallet | Reference Project | `https://github.com/noncelab/coconut_wallet` | `Commit-pinned (e595a6f)` | `e595a6f2d2339e59e0580cc4bb93695ed2763af0` | MIT | Architectural reference for watch-only companion app. **All trademarks stripped.** |
| **S11** | flutter_rust_bridge | FFI Toolchain | `https://github.com/fzyzcjy/flutter_rust_bridge` | `flutter_rust_bridge = "=2.13.0"` | `8631db91a90c699439c9ce2a1fb4164ae8661da9` | MIT | High-performance, type-safe Dart-Rust FFI bridge generator. |
| **S23** | rust-bitcoin | Rust Crate | `https://github.com/rust-bitcoin/rust-bitcoin` | `bitcoin = "=0.32.0"` | `a3f766715eabf008e0d7f2bfdf2ce7a86e9d2f9b` | CC0-1.0 | Bitcoin data structures, script parsing, and PSBT v0 handling. |
| **S24** | libsecp256k1 / rust-secp256k1 | Rust Crate | `https://git.rust-bitcoin.org/rust-bitcoin/rust-secp256k1` | `secp256k1 = "=0.33.1"` | `8820a6e310be639d27ded9e3cc9bf3895fde545a` | CC0-1.0 | Pure cryptographic curve operations, ECDSA signing, recovery, low-s normalization. Rust wrapper around libsecp256k1. (Underlying C library `bitcoin-core/secp256k1` v0.6.0 commit is `0cdc758a56360bf58a851fe91085a327ec97685a`). |
| **S25** | Alloy | Rust Crates | `https://github.com/alloy-rs/alloy` | `alloy-primitives = "=1.7.3"`<br>`alloy-rlp = "=0.3.16"`<br>`alloy-consensus = "=2.5.0"` | `d1636c14762823b672556433783afae8a0c374c6` | MIT OR Apache-2.0 | EVM primitives and RLP codecs. Strictly exclude `alloy-provider` and network features. |
| **AUX-01** | `zeroize` | Rust Crate | `https://github.com/RustCrypto/utils` | `zeroize = "=1.9.1"` | `34a6ebcb9b920ec7ae5809e470fce94fe7c0cb55` | Apache-2.0 OR MIT | Secure memory erasing via `ZeroizeOnDrop` on sensitive buffers. |
| **AUX-02** | `ur-rs` | Rust Crate | `https://github.com/dspicher/ur-rs` | `ur = "=0.5.2"` | `9b3064d879c9f84cbc2a5ce9a57334b98fc16e85` | MIT | BC-UR Luby Transform fountain code encoder/decoder. |
| **AUX-03** | `ciborium` | Rust Crate | `https://github.com/enarx/ciborium` | `ciborium = "=0.2.2"` | `fdf3ec5c53256000f8e12f06c361ca18026a8d99` | Apache-2.0 | Bounded CBOR deserializer (<=128 KiB, <=16 depth). |
| **AUX-04** | `tiny-keccak` | Rust Crate | `https://github.com/debris/tiny-keccak` | `tiny-keccak = "=2.0.2"` | `f034411460d0012925052017c1658b3ce9cda532` | CC0-1.0 | Keccak-256 software hash implementation. |

---

## 3. Platform Security APIs & Toolchain Baselines (S12–S17)

| ID | Platform Component | Target Layer | Specification / API Reference | Target Level | Security Role & Baseline Constraint |
|---|---|---|---|---|---|
| **S12** | Android Keystore | Android API 28–36 | `https://developer.android.com/privacy-and-security/keystore` | TEE / StrongBox preferred | Non-exportable AES-GCM wrapping key (KEK) protecting DEK. |
| **S13** | Apple ATS Spec | iOS 16–18 | `https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html` | Platform Security | Defense-in-depth network rejection; ATS is not a total offline switch. |
| **S14** | Android INTERNET Permission | Android Manifest | `https://developer.android.com/reference/android/Manifest.permission#INTERNET` | Manifest level | **Strictly removed** via `tools:node="remove"`. Zero network permission in Release APK. |
| **S15** | Apple Keychain Data Protection | iOS Security | `https://support.apple.com/guide/security/keychain-data-protection-secb0694978a/web` | Secure Enclave | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` prevents iCloud migration. |
| **S16** | Android Backup Rules | Android 12+ (API 31+) | `https://developer.android.com/identity/data/autobackup` | System Backup | Explicitly excluded via `data_extraction_rules.xml` (Cloud & D2D) and `backup_rules.xml`. |
| **S17** | ML Kit Barcode Scanning | Native Library | `https://developers.google.com/ml-kit/vision/barcode-scanning/android` | `17.3.0` (Bundled Mode) | Google ML Kit Terms of Service (Proprietary with telemetry). **Mandatory Bundled Mode**. Fully functional offline on first launch without dynamic model download. Air-gap defense-in-depth: Manifest completely strips `INTERNET` permission, preventing automated telemetry communication. |

---

## 4. Architectural Boundaries and Trust Constraints

1. **Transport vs. Trust Root Separation**:
   - BC-UR and Keystone Rust SDK (`ur-registry`) serve exclusively as air-gap wire protocol adapters.
   - They are NOT trust roots for transaction validity, policy decisions, or user consent.
   - Internal validation is independently enforced by `public_core` and `vault_core`.

2. **Fail-Closed EVM Policy Engine**:
   - Only whitelisted networks (local development chain, verified testnets) are permitted.
   - Unknown chain IDs, unknown contract addresses, unapproved typed transactions (EIP-7702), and unsafe DeFi allowances (`approve`, `permit`) are firmly rejected.
   - Rejecting an invalid or unapproved transaction results in an absolute signature counter of **0**.

3. **Offline Vault Zero-Network Boundary**:
   - `apps/vault` and `crates/vault_core` strictly prohibit HTTP clients, socket networking, analytics SDKs, and remote font loaders.
   - Android Release APK merged manifest must be verified to contain zero `INTERNET` permission.
   - S17 ML Kit runs strictly in offline Bundled Mode (`com.google.mlkit:barcode-scanning:17.3.0`), with OS-level internet blockage neutralizing vendor telemetry.

4. **Watch-Only Companion Physical Isolation**:
   - `apps/wallet` and `crates/wallet_ffi` are physically isolated from `crates/vault_core`.
   - The watch-only binary contains zero seed intake, zero private key storage, and zero signing algorithms.

---

## 5. Dependency License Notes (internal review)

- **Method**: manual review of the pinned sources above and of the `Cargo.lock` / `pubspec.lock` files. This is the project's own review, not a legal opinion or a third-party audit; re-check it when dependencies change.
- **Findings**:
  - MIT: `ur-registry`, `ur-rs`, `flutter_rust_bridge`, `coconut_vault`, `coconut_wallet`.
  - Apache-2.0: `ciborium`, `alloy-primitives` (dual), `ur-registry (TS)`.
  - Dual Apache-2.0 / MIT: `zeroize`, `alloy`.
  - CC0-1.0 / Public Domain: `bitcoin`, `secp256k1`, `tiny-keccak`, BIP/EIP standards.
  - MPL-2.0 (file-level copyleft): `dbus`, a transitive dependency of `wakelock_plus` that is only used on Linux desktop and is not built into the Android or iOS apps.
  - Proprietary platform library: `ML Kit` (Google ML Kit Terms of Service / Google APIs Terms of Service), bundled by `mobile_scanner`; offline bundled scanning only, with network access removed from the Vault manifest.
  - Strong copyleft (GPL family) in dependencies: none found at the time of review.
- **Binary distribution**: APKs and iOS builds must ship the third-party license texts, for Dart packages through Flutter's license registry and for the Rust crates compiled into the native libraries through a generated list.
- **Coconut Trademark & Brand Stripping**:
  - Coconut Wallet / Vault (S09, S10) code is referenced strictly for dual-app air-gap state machine concepts under MIT license.
  - All brand names, logos, package identifiers, and trademarks are completely excluded.
  - The project uses unique identifiers (`com.coldwallet.vault`, `com.coldwallet.watch`).
