# Mobile Cold Wallet: System Architecture & Monorepo Specification

- **Document Version**: 1.1.0
- **Implementation clarification**: 2026-10-18
- **Work Package**: FCW-OKX-20261012
- **Scope**: Monorepo Code Layout, Physical Boundary Separation, Interface Contracts & State Machines

---

Current Android implementation: asset signing executes in Rust software. Vault
storage is encrypted using a password-derived key; the Keystore-backed device
authentication proof is a separate recent-authentication gate. It does not wrap
the asset-storage key or perform hardware secp256k1 asset signing. Hardware
KEK/DEK envelope encryption in the original ADR-003 remains an unimplemented
design target, not a current product guarantee. The iOS design below is not an
executed iOS build or device acceptance result.

## 1. Monorepo Structure and Physical Module Boundaries

The project adopts a structured monorepo architecture with strict physical separation between public observation logic and private cryptographic signing logic:

```text
fcw/
  apps/
    wallet/                     # Flutter watch-only companion (applicationId: com.coldwallet.watch)
    vault/                      # Flutter offline vault (applicationId: com.coldwallet.vault)
  packages/
    public_models/              # Shared Dart DTOs (strictly zero secret fields)
    qr_ui/                      # Camera barcode scanner and animated fountain QR widgets
    design_system/              # Shared UI components (strictly zero telemetry/analytics)
    vault_platform_security/    # Android Keystore / iOS Keychain platform channel integration
  crates/
    public_core/                # Public key derivation, transaction encoding/decoding, verification
    ur_adapter/                 # BC-UR & CBOR bounded parser (<=128 KiB, <=16 depth)
    vault_core/                 # Key derivation, policy engine, zeroize signing, state machine
    wallet_ffi/                 # FFI for watch-only Wallet (strictly no vault_core dependency)
    vault_ffi/                  # FFI for offline Vault (exposes only opaque PreparedRequest handles)
  tools/
    okx_probe/                  # Standalone OKX crypto-multi-accounts probe CLI
    reference_oracle/           # Independent address and transaction signature cross-verification oracle
    release_checks/             # Artifact checksums, manifest audit, environment verification
  tests/
    vectors/                    # BIP-39, BIP-32, EIP-155, EIP-1559 standard vectors
    protocol/                   # UR roundtrip & boundary checks
    security/                   # Fail-closed policy & negative state machine tests
    integration/                # End-to-end flow tests
  docs/
    sources.md                  # S01~S30 pinned sources & commits
    threat-model.md             # Threat model & trust boundaries
    architecture.md             # Architecture overview & FFI state machine
    ADR/                        # Architecture Decision Records 001~004
```

---

## 2. Physical Dependency & Binary Isolation Rules

1. **Watch-Only Wallet Isolation**:
   - `crates/wallet_ffi` depends strictly on `public_core` and `ur_adapter`.
   - Dependency on `vault_core` in `wallet_ffi/Cargo.toml` is strictly forbidden.
   - The compiled `libwallet_ffi.so` contains zero private key generation, storage, or signing symbols.

2. **Offline Vault Network Isolation**:
   - Vault has no application network workflow. Flutter plugin dependencies may include a transitive HTTP client; its presence alone is not evidence of runtime network access.
   - The Android build strips `android.permission.INTERNET` at the manifest level. Isolation claims must be checked against the specific packaged APK permissions and dependencies.

3. **Transport vs. Trust Root Separation**:
   - `crates/ur_adapter` serves purely as a serialization adapter.
   - It outputs strongly-typed payloads that are independently validated by `vault_core` before any signature handle can be generated.

---

## 3. Interface Contracts and Data Flow

### 3.1 `crates/ur_adapter` ↔ `crates/vault_core` / `crates/public_core`

#### Resource Constraints:
- `max_payload_bytes`: 131,072 (128 KiB)
- `max_cbor_depth`: 16
- `reject_duplicate_cbor_keys`: true
- `reject_trailing_bytes`: true

#### Decoder Outputs:
```rust
pub enum DecodedUrPayload {
    MultiAccounts(CryptoMultiAccounts),
    EthSignRequest(EthSignRequest),
    BtcPsbt(PsbtRequest),
}
```

### 3.2 `crates/vault_core` ↔ `crates/vault_ffi` (PreparedRequest Opaque Handle)

The Vault strictly prohibits general-purpose `sign_hash` or raw digest signing APIs. All signing operations must traverse an immutable handle lifecycle:

```text
       Raw Bytes
           │
           ▼
┌───────────────────────┐
│ parse_prepared_request│ ────► Fails policy / bounds ──► Error (Signature Count = 0)
└──────────┬────────────┘
           │ Passes bounds & policy
           ▼
┌───────────────────────┐
│ PreparedRequest Handle│ (State: ReadyForReview, UUID, Digest, Display DTO)
└──────────┬────────────┘
           │
   ┌───────┴─────────────────────────────────────────┐
   │                                                 │
   ▼ User Confirms                                   ▼ Cancellation / Timeout / Background
┌───────────────────────┐                         ┌───────────────────────┐
│ sign_prepared_request │                         │   discard_prepared    │
└──────────┬────────────┘                         └──────────┬────────────┘
           │                                                 │
           ▼                                                 ▼
┌───────────────────────┐                         ┌───────────────────────┐
│ Consumed (Signature)  │                         │ Cancelled / Expired   │
└───────────────────────┘                         └───────────────────────┘
                                                  (Signature Count = 0)
```

#### API Specifications:
```rust
pub fn parse_prepared_request(raw_bytes: &[u8]) -> Result<Arc<PreparedRequest>, PolicyError>;
pub fn sign_prepared_request(handle_id: HandleId) -> Result<SignatureResult, SigningError>;
pub fn discard_prepared_request(handle_id: HandleId) -> Result<(), PolicyError>;
```

### 3.3 `crates/wallet_ffi` (Watch-Only Companion)

```rust
pub fn generate_pairing_qr(account_data: &PublicAccountData) -> Result<String, FfiError>;
pub fn build_unsigned_eth_tx(params: &UnsignedTxParams) -> Result<PreparedUrRequest, FfiError>;
pub fn verify_and_reconstruct_signed_tx(raw_tx: &[u8], signature_65b: &[u8]) -> Result<Vec<u8>, ReconstructError>;
```

---

## 4. Platform Security Integration

1. **Android**:
   - `apps/vault/android/.../MainActivity.kt` provides a Keystore-backed recent-device-authentication gate through Platform Channels.
   - `crates/vault_core/src/storage.rs` derives the storage encryption key from the user's password and a random salt; no hardware KEK wrapping is currently integrated.
   - Device authentication does not constitute hardware asset signing, hardware wrapping of the Vault encryption key, or proof of secret-memory erasure.
2. **iOS design target, not yet accepted on device**:
   - Security items stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
   - Excluded from iCloud Keychain sync and backup archives.
