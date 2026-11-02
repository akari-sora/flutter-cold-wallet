# FCW NFC Probe (`tools/nfc_probe`)

Offline dual-device Android NFC transport & transaction signing probe for Mobile Cold Wallet.

> **Test tool only.** The probe's "vault" always loads the public BIP-39 test vector
> (`abandon … about`), which everyone knows. Never put real funds on its addresses, and never
> install it on a device that holds a real wallet. NFC is deferred in the main apps; this probe is
> kept for protocol regression work.

## 0. Build

The probe needs the `vault_ffi` and `wallet_ffi` native libraries built with the `test-fixtures`
feature (which exports the probe's JNI entry points); they are not committed. From the repository root:

```sh
cargo ndk -t arm64-v8a -o tools/nfc_probe/android/app/src/main/jniLibs \
  build --release -p vault_ffi -p wallet_ffi --features vault_ffi/test-fixtures,wallet_ffi/test-fixtures
cd tools/nfc_probe && flutter build apk --debug   # or --release for the manual UI flow
```

## 1. Flavor & Manifest Separation (`A1` / `A3`)

- **Release / Offline APK (`app-release.apk`)**:
  - Contains **no `INTERNET` permission** and **no external control Activity or ContentProvider**.
  - `TestControlProvider` lives exclusively under `src/debug/kotlin/` and `src/debug/AndroidManifest.xml`; it is never compiled into or merged into the Release APK.
  - `MainActivity` (`MAIN`/`LAUNCHER`) strictly ignores and rejects all external `role`, `run_id`, `phase`, and `internal_sync` intent extras (`PROBE_SECURITY_REJECT` logged on any attempt).
  - `FcwHostApduService` is protected by `android:permission="android.permission.BIND_NFC_SERVICE"`.
- **Debug / Automation APK (`app-debug.apk`)**:
  - Includes debug-only `com.mobilecoldwallet.nfc_probe.TestControlProvider` (`content://com.mobilecoldwallet.nfc_probe.testcontrol`) protected by `android:permission="android.permission.DUMP"`.
  - In `ContentProvider.call()`, Android's Binder IPC preserves the true caller UID (`Binder.getCallingUid()`) and caller permission (`checkCallingPermission(Manifest.permission.DUMP)`). `TestControlGate.authorize()` enforces `isDebuggableBuild == true`, `callerHoldsDump == true`, and `callingUid in {0, 2000}` with zero fallback, returning `ack_json` synchronously in the result `Bundle` and emitting `PROBE_CONTROL_ACK` to logcat and persistent JSONL storage.

## 2. Manual UI Operation (Release / Offline APK)

### A. Transport Probe Mode (`TEST_32B`..`TEST_NEGATIVE_SERVICE_OVERSIZED_CHUNK`)
1. Install `app-release.apk` onto two NFC-capable Android devices (**Device A** and **Device B**).
2. On **Device B (Vault / HCE)**:
   - Select **HCE (Card Emulation)** in the segmented role selector.
   - Tap **Start New Run** to allocate a fresh local `run_id`, positive `generation`, and active cancellation token.
3. On **Device A (Wallet / Reader)**:
   - Select **READER (IsoDep Polling)** in the segmented role selector.
   - Tap **Start New Run** to enable `NfcAdapter.enableReaderMode` with a fresh `run_id`, `generation`, and active token.
4. Hold the NFC antennas of both phones together until all 8 transport & negative probe vectors complete.

### B. Genuine Two-Tap & Three-Tap Rust Transaction Signing Flow (`A4` / `A6`)
1. On **Device B (Vault / HCE)**:
   - Select **HCE (Card Emulation)** and tap **Start New Run** (or switch to HCE) to arm `VaultApprovalGate`.
2. On **Device A (Wallet / Reader)**:
   - Select **READER (IsoDep Polling)** and tap **Start NFC Tx**.
3. **Touch 1 (Request Delivery -> Separate Phones)**:
   - Bring Device A and Device B together for **Touch 1**.
   - Device A registers the local `PendingWalletRequest` in `WalletCoreBridge`, transmits the `INS=0x40` request frames, confirms `STATE_PENDING` (`0x00`) via `INS=0x41 P1=0x00`, and cleanly closes RF connection #1 (`status = "AWAITING_VAULT_APPROVAL_TOUCH_2"`, `touch_count = 1`, `request_delivered = true`).
   - Separate the two phones. `FcwHostApduService.onDeactivated` preserves the pending request and prepared handle in `VaultApprovalGate` without cancelling or resetting it.
4. **Offline Local Review & Signing on Vault (Device B)**:
   - Remote approval over NFC (`INS=0x41 P1=0x01`) is **unconditionally rejected** with `SW_SECURITY_STATUS_NOT_SATISFIED` (`0x6982`).
   - On **Device B's local screen**, inspect the decoded transaction summary and immutable review identity (`handle_id`, `request_id`, `payload_sha256`, `signing_digest_hex`, `chain_id`, `expected_signer`, `run_id`, `generation`, `review_seq`) in the **Vault Local Review** card and tap **Approve & Sign** (or **Reject**).
   - Once signed, `VaultApprovalGate` transitions to `SIGNED_AWAITING_DELIVERY` (`SIGNED_KNOWN_SUCCESS`) and caches the signed `INS=0x50` response frames. Subsequent `onPause`, role/cancel actions, or RF deactivations never overwrite a signed fact into unsigned `CANCELLED` (`SIGNED_DISCARDED_BY_USER` if explicitly discarded).
5. **Touch 2 (Response Collection & Self-Verification)**:
   - Bring Device A and Device B together again for **Touch 2**.
   - Device A reuses its retained `PendingWalletTxState` (without calling `WalletCoreBridge.nativeInit`, creating a new `requestId`, or re-sending `INS=0x40` frames), sends `INS=0x41 P1=0x00` with peer-context binding (`session_id`, `request_id`, `payload_sha256`, `signing_digest`, `expected_signer`, `chain_id`), fetches all `INS=0x50` signed response frames, and verifies the signature and independently recomputed digest against the retained `PendingWalletRequest`.
6. **Touch 3 (Recovery After Interrupted Touch 2)**:
   - If RF contact is lost mid-fetch during Touch 2, `WalletCoreBridge.nativeResetTransportAssembler(sessionId)` clears only the partial transport assembler while preserving `PendingWalletRequest` on Device A and `SIGNED_AWAITING_DELIVERY` on Device B.
   - Touching a third time (**Touch 3**) completes fetching the cached signed response with zero additional signing invocations (`primitive_sign_invocations` unchanged).

### C. Cancellation, Hardened Evidence & Historical Run Export (`A2` / `A7`)
- Tap **Cancel / Reset** before signing to transition `PRE_SIGN_PENDING` -> `PRE_SIGN_CANCELLED`, invoke panic-free non-destructive `VaultCoreBridge.nativeCancel(handleId)` (`0` cancelled, `-1` already cancelled, `-2` not found, `-3` already signed), close any active `IsoDep` socket, and record a terminal `CANCELLED` report.
- Persistent evidence is written atomically (`Files.move` with `REPLACE_EXISTING` fallback, never pre-deleting existing reports) and `event_seq` allocation + JSONL append execute inside `synchronized(stateLock)`.
- Any write failure sets `evidence_status = "EVIDENCE_WRITE_FAILED"` (`all_passed = false`); any corrupted JSON line or missing `event_seq` / `run_event_seq` gap sets `evidence_status = "EVIDENCE_CORRUPTED_OR_MISSING_EVENT"` (`all_passed = false`).
- Across app restarts, use the **Persisted Run History (`A7`)** selector in the UI (`listPersistedRuns` / `loadPersistedRunBundle`) and tap **Export Selected** or **Export JSON** to export current or historical run bundles from `<filesDir>/nfc_probe_evidence/`.

## 3. Automated Dual-Device Runner (Debug APK)

```bash
python tools/nfc_probe/run_nfc_probe.py \
  --device-a <SERIAL_A> \
  --device-b <SERIAL_B> \
  --apk tools/nfc_probe/build/app/outputs/flutter-apk/app-debug.apk \
  --deadline 45 \
  --verify \
  --output results/nfc_probe_report.json
```

Both adb serials are required, either as `--device-a` / `--device-b` or through the
`FCW_NFC_DEVICE_A` / `FCW_NFC_DEVICE_B` environment variables. Without `--output` the report is
written to `target/nfc_probe/run-01/nfc_probe_report.json`.

## 4. Merged AndroidManifest Newline Normalization Rule

On Windows hosts, Android Gradle Plugin (AGP) writes `build/app/intermediates/merged_manifest/<variant>/process<Variant>MainManifest/AndroidManifest.xml` with CRLF (`\r\n`) line endings, whereas Git normalizes committed XML files in the repository tree/index to LF (`\n`).
To avoid ambiguity across Windows build outputs and Git tree verification:
1. When a merged manifest is archived as a run record, normalize it to LF (`\n`) before hashing so the on-disk file and the Git blob have the exact same byte length and SHA-256 (`sha256` / `git_lf_sha256`).
2. Record both `git_lf_sha256` (`git_lf_bytes`) and `raw_build_crlf_sha256` (`raw_build_crlf_bytes`) next to it.
