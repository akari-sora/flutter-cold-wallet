# Mobile Cold Wallet: Threat Model & Security Boundaries

- **Document Version**: 1.0.0
- **Verification Date**: 2026-10-12
- **Work Package**: FCW-OKX-20261012
- **Scope**: Dedicated Mobile Air-Gapped Signer (`apps/vault`) + Watch-Only Companion (`apps/wallet`) & OKX Interoperability
- **Integrity Mode**: Benchmark Mode (Truthful Security Claims, No False Hardware SE Analogies)

---

## 1. System Goals and Core Security Invariants

### 1.1 System Definition
The system consists of two independently deployable applications designed to run on separate physical mobile devices:
1. **Offline Vault (`apps/vault`)**: A dedicated signing appliance with all network access physically and logically stripped. It securely holds mnemonic seeds, performs deterministic key derivation, executes transaction decoding and policy verification, and produces signatures across an optical air-gap (QR code).
2. **Watch-Only Companion (`apps/wallet` or third-party `OKX Wallet`)**: An untrusted, network-enabled client that manages public accounts, tracks blockchain state, composes unsigned requests, presents them as QR codes, and broadcasts signed raw transactions.

### 1.2 Core Security Invariants
- **Invariant 1 (Secret Confinement)**: Formal secret material (BIP-39 mnemonic, master seed, HD private keys) shall NEVER leave the physical boundary of the dedicated Vault device and shall NEVER be exported via QR codes, logs, IPC, clipboard, or backups.
- **Invariant 2 (Physical Isolation of Watch-Only Wallet)**: The companion wallet binary shall physically contain zero seed intake, zero private key storage, and zero cryptographic signing libraries.
- **Invariant 3 (Zero Blind-Signing)**: The Vault shall independently decode raw transaction bytes and enforce human-in-the-loop review. General-purpose `signHash` or arbitrary digest signing is strictly prohibited.
- **Invariant 4 (Fail-Closed Default)**: Encountering any unapproved chain ID, unknown contract, unexpected transaction type, malformed payload, or expired session shall result in an absolute signature call count of **0**.
- **Invariant 5 (Atomic State Invalidation)**: Any interruption (user cancellation, screen lock, background transition, timeout, or incoming QR scan) shall immediately destroy active review handles, resetting the signature counter to 0.

---

## 2. Trust Boundaries and Domains

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│ 【UNTRUSTED DOMAIN】                                                         │
│                                                                             │
│   ┌───────────────────────────┐         ┌───────────────────────────────┐   │
│   │ External Blockchain / RPC │         │ Third-Party Wallet (OKX App)  │   │
│   │ (May supply forged nonces)│         │ (May project hostile requests)│   │
│   └─────────────┬─────────────┘         └───────────────┬───────────────┘   │
│                 │                                       │                   │
│                 ▼                                       ▼                   │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │ Watch-Only Companion Wallet (`apps/wallet`)                         │   │
│   │ (Binary has no keys; execution environment may be compromised)      │   │
│   └──────────────────────────────────┬──────────────────────────────────┘   │
│                                      │                                      │
│                                      ▼ [Untrusted Optical Air-Gap Channel]  │
│                         (Malformed CBOR, DoS Payloads, Projection Hijacking) │
└──────────────────────────────────────┼──────────────────────────────────────┘
                                       │
=======================================│=======================================
【AIR-GAP PHYSICAL BOUNDARY】           │ (Zero Wi-Fi, Zero Cellular, Zero BT, No USB)
=======================================│=======================================
                                       │
┌──────────────────────────────────────┼──────────────────────────────────────┐
│ 【SEMI-TRUSTED EXECUTION DOMAIN (Dedicated Mobile Device)】                 │
│                                      │                                      │
│   ┌──────────────────────────────────▼──────────────────────────────────┐   │
│   │ Mobile Operating System (Android / iOS)                             │   │
│   │ - Provides process isolation (Sandbox) and camera HAL               │   │
│   │ - NOT assumed to withstand hostile Root/Jailbreak or kernel taps    │   │
│   └──────────────────────────────────┬──────────────────────────────────┘   │
│                                      │                                      │
│   ┌──────────────────────────────────▼──────────────────────────────────┐   │
│   │ Managed Runtime (Dart VM / Flutter / ART)                           │   │
│   │ - Renders UI (large fonts, high contrast, unclipped numbers)        │   │
│   │ - GC-managed memory cannot guarantee instant wiping; no raw secrets │   │
│   └──────────────────────────────────┬──────────────────────────────────┘   │
└──────────────────────────────────────┼──────────────────────────────────────┘
                                       │
┌──────────────────────────────────────┼──────────────────────────────────────┐
│ 【TRUSTED CORE DOMAIN】                                                      │
│                                      │                                      │
│   ┌──────────────────────────────────▼──────────────────────────────────┐   │
│   │ Platform Hardware Keystore (StrongBox/TEE / Secure Enclave)         │   │
│   │ - Non-exportable Key Encryption Key (KEK) wrapping local storage DEK │   │
│   └──────────────────────────────────┬──────────────────────────────────┘   │
│                                      │ (Wrapped ciphertext only)            │
│   ┌──────────────────────────────────▼──────────────────────────────────┐   │
│   │ Rust Security Core (`crates/vault_core` + `vault_ffi`)              │   │
│   │ - Memory Hygiene: `zeroize::ZeroizeOnDrop` clears secret buffers    │   │
│   │ - Strict Bounded Parser (<= 128 KiB payload, depth <= 16)           │   │
│   │ - Fail-Closed Policy Whitelist Engine                               │   │
│   │ - Immutable `PreparedRequest` Opaque Handle State Machine           │   │
│   │ - Software secp256k1 Signing + Self-Verification (`ecrecover`)      │   │
│   └──────────────────────────────────┬──────────────────────────────────┘   │
│                                      │                                      │
│   ┌──────────────────────────────────▼──────────────────────────────────┐   │
│   │ Human in the Loop (Physical User Verification)                      │   │
│   │ - Offline screen displays recipient address, amount, fee limits     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Cryptographic Software Signing vs. Platform Hardware Wrapping Key

### 3.1 Platform Hardware Security Limitations
- Mobile hardware security modules (Android StrongBox / TEE and Apple Secure Enclave) standardly support NIST curves (P-256 / `secp256r1`).
- Native hardware support for Bitcoin / Ethereum `secp256k1` is non-standard, vendor-fragmented, and cannot be relied upon across devices.

### 3.2 Dual-Layer Defense Architecture
1. **Curve Operations & Signing**:
   - Executed entirely in user-space using the battle-tested `secp256k1` library (binding to Bitcoin Core's C implementation).
   - Enforces RFC 6979 deterministic nonce generation and Low-S signature normalization.
2. **Encrypted Storage (Key Wrapping)**:
   - Persistent storage uses an envelope encryption model.
   - **KEK (Key Encryption Key)**: A non-exportable hardware-backed key generated in Android Keystore (StrongBox/TEE preferred) or iOS Keychain (Secure Enclave).
   - **DEK (Data Encryption Key)**: A 256-bit symmetric key generated via CSPRNG per encryption session, used to encrypt mnemonic plaintext via AES-256-GCM.
   - The encrypted DEK and ciphertext are stored locally.

### 3.3 Truthful Security Claim
- **Protected Against**: Device loss, offline filesystem extraction, inter-app sandbox escapes, ADB backup extraction, unauthorized cloud syncing.
- **NOT Protected Against**: Hostile Root / Jailbreak kernel dumps, runtime hooking (e.g. Frida on compromised OS), direct memory bus tapping, physical chip decapping.
- **Explicit Statement**: This software cold wallet does NOT provide the physical tamper-resistance of dedicated hardware secure element devices (e.g. smartcards, dedicated secure chips).

---

## 4. Memory Hygiene and Managed Runtime Bounds

1. **Rust Core Zeroization**:
   - All structures containing mnemonics, seeds, private keys, or derivation paths implement `zeroize::ZeroizeOnDrop`.
   - Explicit memory zeroization executes immediately when secret scopes exit.
   - Formatting secret structures in `Debug` or writing them to logs is strictly prohibited.

2. **FFI Boundary Minimization**:
   - Zero private keys or seeds cross the FFI boundary between Rust and Dart.
   - Secret material resides in Rust memory only during initial generation, import, and active signing.

3. **Dart VM Managed Memory Bounds**:
   - Immutable Dart `String` instances cannot be deterministically zeroed due to garbage collection and string intern pooling.
   - During mnemonic onboarding, words are managed via byte arrays or native platform views to minimize string allocations.
   - **Truthful Disclosure**: Temporary copies may exist in GC memory prior to compaction. The system does NOT claim absolute zero-footprint memory erasure in managed runtimes.

---

## 5. Air-Gap Network Boundary and Permission Revocation

1. **Android Manifest Stripping**:
   - `android.permission.INTERNET` is explicitly stripped via `<uses-permission android:name="android.permission.INTERNET" tools:node="remove" />`.
   - Merged manifest validation confirms that zero network permissions exist in the final Release APK.
   - Zero exported Activities, Services, BroadcastReceivers, or external URL schemes.

2. **iOS Offline Architecture**:
   - Zero network frameworks (`dart:io` HttpClient, NSURLSession wrappers).
   - No iCloud containers, no shared App Groups, no push notification entitlements.

3. **Dynamic Network Guard**:
   - Before key initialization, unlock, mnemonic display, and transaction signing, the Vault queries system radio state (Wi-Fi, Cellular, Bluetooth).
   - If active connectivity is detected, the Vault immediately locks with an alert: "Please enable Airplane Mode and disable all wireless radios."
   - When modern OS restrictions prevent querying radio state without location permissions, the state is recorded as `NETWORK_STATUS: UNKNOWN` and manual user confirmation is required. It is NEVER falsely marked as safe.

---

## 6. Backup, Snapshot, and Migration Exclusion

1. **Android Backup Exclusion**:
   - `android:allowBackup="false"`.
   - `data_extraction_rules.xml` (API 31+) excludes all directories from `<cloud-backup>` and `<device-to-device>`.
   - `backup_rules.xml` (API 23–30) excludes `sharedpref`, `database`, and `file` domains.

2. **iOS Keychain & File Protection**:
   - Keychain items enforce `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (disallows iCloud sync and device migration).
   - Private storage files set `NSURLIsExcludedFromBackupKey = true`.

3. **Screen Capture and Snapshot Shield**:
   - Android windows enforce `FLAG_SECURE`, preventing screenshots, screen recordings, and Recent Apps previews.
   - iOS observers trigger an obfuscated privacy overlay on `applicationWillResignActive` to prevent task-switcher snapshot leaks.

---

## 7. Bounded QR Channel & DoS Protections

1. **Bounded Payload**: Reassembled binary payload cannot exceed 131,072 bytes (128 KiB). Exceeding bytes trigger immediate session reset.
2. **CBOR Nesting Limit**: CBOR recursive parsing depth cannot exceed 16 levels.
3. **Strict CBOR Validation**: Rejects duplicate map keys and trailing unconsumed bytes.
4. **Fountain Code Frame Isolation**: Fountain reassembly enforces a 30-second sliding session timeout. Interleaving frames from distinct transactions triggers a checksum mismatch and safe session reset.

---

## 8. STRIDE Threat Analysis & Mitigation Matrix

| Threat (STRIDE) | Attack Scenario | Impacted Asset | Mitigation Mechanism | Acceptance Case |
|---|---|---|---|---|
| **Spoofing** | Hostile QR injects false chainId or forged requestId | User Funds | Validate internal transaction chainId; return unmodified requestId; ignore external tags | `EVM-06`, `UR-04` |
| **Tampering** | Compromised Dart UI attempts to display forged recipient | User Consent | Rust signs only immutable digest of `PreparedRequest`; display DTO derived directly from raw RLP | `EVM-08`, `LIFE-02` |
| **Repudiation** | User claims cold signer signed transaction autonomously | Transaction Legitimacy | Mandatory physical confirmation; monotonically increasing signature counter | `LIFE-01` |
| **Information Disclosure** | Cloud backup or device transfer exports private vault keys | Master Seed | Explicit backup exclusions in Android Manifest and iOS Keychain `ThisDeviceOnly` | `STORE-01`, `OFF-04` |
| **Information Disclosure** | Hostile background screen capture reads mnemonic | Mnemonic | `FLAG_SECURE` on Android, background privacy blur mask on iOS | `OFF-06`, `STORE-04` |
| **Denial of Service** | Malformed CBOR recursive bomb or huge fountain frame crashes Vault | Signer Availability | Bounded payload (<=128 KiB), depth limit (<=16), 30s session timeout | `UR-01`, `UR-02` |
| **Elevation of Privilege** | DApp requests signing unverified EIP-712 permit or infinite approve | Account Control | Fail-closed policy: reject unapproved contracts, reject permits, reject EIP-7702 | `EVM-07`, `MSG-03` |
