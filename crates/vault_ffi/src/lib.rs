#![allow(clippy::not_unsafe_ptr_arg_deref)]

use public_core::evm::{Eip1559Transaction, LegacyTransaction, ParsedIntent};
use public_core::policy::PolicyEngine;
use signer_router::{PreparedRequest, RequestState, SignerBackend, Transport};
use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
#[cfg(any(test, feature = "test-fixtures"))]
use std::os::raw::c_void;
use std::sync::Mutex;
use ur_adapter::{DataType, DecodedUrPayload, EthSignRequest, EthSignature};
use vault_core::KeyVault;

pub struct VaultContext {
    pub key_vault: Option<KeyVault>,
    pub requests: HashMap<String, PreparedRequest>,
    pub request_paths: HashMap<String, String>,
    pub signed_results: HashMap<String, String>,
    pub psbts: HashMap<String, Vec<u8>>,
    pub active_handle_id: Option<String>,
    pub monotonic_counter: u64,
    pub policy_engine: PolicyEngine,
    pub nfc_sessions: nfc_protocol::SessionManager,
    pub apdu_frame_assembler: nfc_protocol::ApduFrameAssembler,
    pub nfc_clock_ms: u64,
    cancelled_receipts: VecDeque<CancelledReceipt>,
}

static CONTEXT: Mutex<Option<VaultContext>> = Mutex::new(None);

const MAX_RETAINED_PREPARED_REQUESTS: usize = 128;
const MAX_CANCELLED_RECEIPTS: usize = 64;

struct CancelledReceipt {
    // Fixed-size identity avoids retaining caller-sized request identifiers.
    handle_hash: [u8; 32],
    backend: SignerBackend,
    transport: Transport,
}

impl VaultContext {
    fn cancelled_receipt(&self, handle: &str) -> Option<&CancelledReceipt> {
        let hash = public_core::bitcoin::sha256(handle.as_bytes());
        self.cancelled_receipts.iter().find(|receipt| receipt.handle_hash == hash)
    }

    fn release_cancelled_request(&mut self, handle: &str) {
        if !self.requests.get(handle).is_some_and(|request|
            request.state == RequestState::Cancelled && request.sign_command_count == 0)
        {
            return;
        }
        let request = self.requests.remove(handle).expect("request checked above");
        self.request_paths.remove(handle);
        self.psbts.remove(handle);
        if self.cancelled_receipt(handle).is_none() {
            self.cancelled_receipts.push_back(CancelledReceipt {
                handle_hash: public_core::bitcoin::sha256(handle.as_bytes()),
                backend: request.backend,
                transport: request.transport,
            });
        }
        while self.cancelled_receipts.len() > MAX_CANCELLED_RECEIPTS {
            self.cancelled_receipts.pop_front();
        }
    }

    fn revoke_active_request(&mut self) {
        if let Some(handle) = self.active_handle_id.clone() {
            if let Some(request) = self.requests.get_mut(&handle) { request.revoke(); }
            self.release_cancelled_request(&handle);
        }
    }

    fn revoke_all_requests(&mut self) {
        let handles: Vec<_> = self.requests.keys().cloned().collect();
        for handle in handles {
            if let Some(request) = self.requests.get_mut(&handle) { request.revoke(); }
            self.release_cancelled_request(&handle);
        }
        self.active_handle_id = None;
    }

    fn retain_prepared_request(
        &mut self, request: PreparedRequest, path: Option<String>, psbt: Option<Vec<u8>>,
    ) -> Result<(), &'static str> {
        // Every preparation path passes this gate. Dispatched, signed, consumed,
        // and unknown outcomes stay retained: capacity fails closed, never evicts
        // signing history or permits an automatic retry.
        self.revoke_active_request();
        if self.requests.len() >= MAX_RETAINED_PREPARED_REQUESTS {
            return Err("Prepared request retention limit reached; existing signing history must be preserved");
        }
        let handle = request.handle_id.clone();
        if self.requests.contains_key(&handle) || self.cancelled_receipt(&handle).is_some() {
            return Err("Prepared request handle already exists");
        }
        if let Some(path) = path { self.request_paths.insert(handle.clone(), path); }
        if let Some(psbt) = psbt { self.psbts.insert(handle.clone(), psbt); }
        self.requests.insert(handle.clone(), request);
        self.active_handle_id = Some(handle);
        Ok(())
    }
}

fn error_json(code: &str, error: impl std::fmt::Display) -> *mut c_char {
    CString::new(serde_json::json!({"status":"ERROR","error_code":code,"error":error.to_string()}).to_string()).unwrap().into_raw()
}

fn validate_eip1559_gas_for_vault(tx: &Eip1559Transaction, ctx: &VaultContext) -> Result<(), String> {
    if tx.gas_limit >= 21_000 {
        return Ok(());
    }
    let vault = ctx.key_vault.as_ref().ok_or("Vault is locked")?;
    let account = vault.derive_evm_public_account(0).map_err(|e| e.to_string())?;
    tx.validate_gas_for_signer(&account.address).map_err(|e| e.to_string())
}

fn legacy_transaction_summary(tx: &LegacyTransaction) -> serde_json::Value {
    serde_json::json!({
        "type": "Legacy EIP-155", "chain_id": tx.chain_id.to_string(),
        "nonce": tx.nonce.to_string(), "gas_limit": tx.gas_limit.to_string(),
        "gas_price_wei": tx.gas_price.to_string(), "to": tx.to,
        "value_wei": tx.value_wei, "data_hex": format!("0x{}", hex::encode(&tx.data)),
        "access_list": [],
    })
}

fn eip1559_transaction_summary(tx: &Eip1559Transaction, raw: &[u8]) -> Result<serde_json::Value, String> {
    // Core historically tolerates malformed access-list entries. Never turn
    // skipped wire fields into an apparently empty authoritative review.
    let payload = raw.strip_prefix(&[0x02]).ok_or("Missing Type-2 prefix")?;
    let root = public_core::rlp::decode_rlp(payload).map_err(|e| e.to_string())?;
    let fields = root.as_list().map_err(|e| e.to_string())?;
    let entries = fields.get(8).ok_or("Missing access list")?.as_list().map_err(|e| e.to_string())?;
    for entry in entries {
        let fields = entry.as_list().map_err(|e| e.to_string())?;
        if fields.len() != 2 || fields[0].as_bytes().map_err(|e| e.to_string())?.len() != 20 {
            return Err("Malformed access-list entry or address".into());
        }
        for key in fields[1].as_list().map_err(|e| e.to_string())? {
            if key.as_bytes().map_err(|e| e.to_string())?.len() != 32 {
                return Err("Access-list storage key must be 32 bytes".into());
            }
        }
    }
    Ok(serde_json::json!({
        "type": "EIP-1559", "chain_id": tx.chain_id.to_string(),
        "nonce": tx.nonce.to_string(), "gas_limit": tx.gas_limit.to_string(),
        "max_fee_per_gas_wei": tx.max_fee_per_gas.to_string(),
        "max_priority_fee_per_gas_wei": tx.max_priority_fee_per_gas.to_string(),
        "to": tx.to, "value_wei": tx.value_wei,
        "data_hex": format!("0x{}", hex::encode(&tx.data)), "access_list": tx.access_list,
    }))
}

fn validate_new_storage_path(path: &str) -> Result<(), &'static str> {
    if path.trim().is_empty() { return Err("A private storage destination is required"); }
    if std::path::Path::new(path.trim()).exists() { return Err("Existing vault must not be overwritten"); }
    Ok(())
}

#[no_mangle]
pub extern "C" fn fcw_decode_ur_frames(input: *const c_char) -> *mut c_char {
    unsafe { ur_adapter::ffi_decode::decode_frames_json(input) }
}
#[no_mangle]
pub extern "C" fn fcw_free_ur_result(pointer: *mut c_char) {
    unsafe { ur_adapter::ffi_decode::free_json(pointer) }
}

#[no_mangle]
pub extern "C" fn vault_init() -> i32 {
    let mut ctx = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    *ctx = Some(VaultContext {
        key_vault: None,
        requests: HashMap::new(),
        request_paths: HashMap::new(),
        signed_results: HashMap::new(),
        psbts: HashMap::new(),
        active_handle_id: None,
        monotonic_counter: 0,
        policy_engine: PolicyEngine::default(),
        nfc_sessions: nfc_protocol::SessionManager::default(),
        apdu_frame_assembler: nfc_protocol::ApduFrameAssembler::new(),
        nfc_clock_ms: 1000,
        cancelled_receipts: VecDeque::new(),
    });
    0
}

#[no_mangle]
pub extern "C" fn vault_lock() -> i32 {
    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return -1,
    };
    ctx.revoke_all_requests();
    ctx.key_vault = None;
    0
}

#[no_mangle]
pub extern "C" fn vault_generate_mnemonic_json(word_count: u32) -> *mut c_char {
    match KeyVault::generate_mnemonic(word_count as usize) {
        Ok(mnemonic) => {
            let out = serde_json::json!({
                "status": "SUCCESS",
                "word_count": word_count,
                "mnemonic": mnemonic,
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_MNEMONIC_GEN",
                "error": e.to_string(),
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
    }
}

#[no_mangle]
pub extern "C" fn vault_preview_mnemonic_json(
    phrase: *const c_char,
    passphrase: *const c_char,
) -> *mut c_char {
    if phrase.is_null() {
        return std::ptr::null_mut();
    }
    let phrase_str = unsafe { CStr::from_ptr(phrase) }.to_string_lossy();
    let pass_str = if passphrase.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(passphrase) }.to_string_lossy().into_owned()
    };

    let word_count = match KeyVault::validate_mnemonic_detailed(&phrase_str) {
        Ok(cnt) => cnt,
        Err(vault_core::VaultError::InvalidChecksum) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_INVALID_CHECKSUM",
                "error": "BIP-39 mnemonic checksum verification failed",
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_INVALID_MNEMONIC",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    match KeyVault::from_mnemonic(&phrase_str, &pass_str) {
        Ok(preview_vault) => {
            let evm0 = preview_vault.derive_evm_public_account(0).ok();
            let evm1 = preview_vault.derive_evm_public_account(1).ok();
            let btc0 = preview_vault.derive_btc_public_account(0, "bcrt").ok();
            let out = serde_json::json!({
                "status": "SUCCESS",
                "word_count": word_count,
                "master_fingerprint": hex::encode(preview_vault.master_fingerprint()),
                "has_passphrase": preview_vault.has_passphrase_hint(),
                "evm_account_0": evm0,
                "evm_account_1": evm1,
                "btc_account_0": btc0,
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_DERIVATION_FAILED",
                "error": e.to_string(),
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
    }
}

#[no_mangle]
pub extern "C" fn vault_activate_and_save_mnemonic_json(
    phrase: *const c_char,
    passphrase: *const c_char,
    storage_path: *const c_char,
    pin_password: *const c_char,
) -> *mut c_char {
    if phrase.is_null() || storage_path.is_null() || pin_password.is_null() {
        return std::ptr::null_mut();
    }
    let phrase_str = unsafe { CStr::from_ptr(phrase) }.to_string_lossy();
    let pass_str = if passphrase.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(passphrase) }.to_string_lossy().into_owned()
    };
    let path_str = unsafe { CStr::from_ptr(storage_path) }.to_string_lossy();
    let pin_str = unsafe { CStr::from_ptr(pin_password) }.to_string_lossy();

    if let Err(e) = validate_new_storage_path(&path_str) { return error_json("ERR_STORAGE_PATH", e); }
    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() { Some(ctx) => ctx, None => return error_json("ERR_NOT_INITIALIZED", "Initialize vault before activation") };
    if ctx.key_vault.is_some() { return error_json("ERR_VAULT_EXISTS", "Lock existing vault before onboarding"); }

    let vault = match KeyVault::from_mnemonic(&phrase_str, &pass_str) {
        Ok(v) => v,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_INVALID_MNEMONIC",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    let multi = match vault.build_multi_accounts_ur(&[0, 1], "bcrt", 120) {
        Ok(m) => m,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_MULTI_ACCOUNTS",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    let protected = match vault_core::storage::encrypt_seed_with_password(
        &pin_str,
        vault.seed_bytes(),
        vault.master_fingerprint(),
        vault_core::storage::EXPECTED_BUNDLE_ID,
        vault.has_passphrase_hint(),
    ) {
        Ok(p) => p,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_ENCRYPTION_FAILED",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    if !path_str.trim().is_empty() {
        if let Err(e) = vault_core::storage::save_new_protected_envelope_atomic(
            std::path::Path::new(path_str.trim()),
            &protected,
        ) {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_STORAGE_IO",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    }

    ctx.key_vault = Some(vault);

    let out = serde_json::json!({
        "status": "SUCCESS",
        "master_fingerprint": multi.master_fingerprint,
        "has_passphrase_hint": protected.has_passphrase_hint,
        "multi_accounts": multi,
    });
    CString::new(out.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_check_storage_status_json(storage_path: *const c_char) -> *mut c_char {
    if storage_path.is_null() {
        return std::ptr::null_mut();
    }
    let path_str = unsafe { CStr::from_ptr(storage_path) }.to_string_lossy();
    let path = std::path::Path::new(path_str.trim());

    let unlocked = {
        let ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
        ctx_guard.as_ref().and_then(|c| c.key_vault.as_ref()).is_some()
    };

    if !path.exists() {
        let out = serde_json::json!({
            "status": "EMPTY",
            "initialized": false,
            "unlocked": unlocked,
        });
        return CString::new(out.to_string()).unwrap().into_raw();
    }

    match vault_core::storage::load_protected_envelope(path) {
        Ok(env) => {
            if env.envelope.bundle_id != vault_core::storage::EXPECTED_BUNDLE_ID {
                let out = serde_json::json!({
                    "status": "STORAGE_CORRUPTED",
                    "initialized": true,
                    "unlocked": false,
                    "error_code": "ERR_BUNDLE_MISMATCH",
                    "error": format!(
                        "Bundle ID mismatch: expected {}, got {}",
                        vault_core::storage::EXPECTED_BUNDLE_ID,
                        env.envelope.bundle_id
                    ),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
            let out = serde_json::json!({
                "status": "ENCRYPTED_ON_DISK",
                "initialized": true,
                "unlocked": unlocked,
                "master_fingerprint": hex::encode(env.envelope.master_fingerprint),
                "has_passphrase_hint": env.has_passphrase_hint,
                "schema_version": env.schema_version,
                "kdf_alg": env.kdf_alg,
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
        Err(vault_core::storage::StorageError::SchemaVersionMismatch { expected, got }) => {
            let out = serde_json::json!({
                "status": "STORAGE_CORRUPTED",
                "initialized": true,
                "unlocked": false,
                "error_code": "ERR_SCHEMA_MISMATCH",
                "error": format!("Unsupported storage schema version {}, expected {}", got, expected),
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "STORAGE_CORRUPTED",
                "initialized": true,
                "unlocked": false,
                "error_code": "ERR_STORAGE_CORRUPTED",
                "error": e.to_string(),
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
    }
}

#[no_mangle]
pub extern "C" fn vault_unlock_from_storage_json(
    storage_path: *const c_char,
    pin_password: *const c_char,
) -> *mut c_char {
    if storage_path.is_null() || pin_password.is_null() {
        return std::ptr::null_mut();
    }
    let path_str = unsafe { CStr::from_ptr(storage_path) }.to_string_lossy();
    let pin_str = unsafe { CStr::from_ptr(pin_password) }.to_string_lossy();
    let path = std::path::Path::new(path_str.trim());

    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() { Some(ctx) => ctx, None => return error_json("ERR_NOT_INITIALIZED", "Initialize vault before unlock") };
    ctx.revoke_all_requests();
    ctx.key_vault = None;
    let protected = match vault_core::storage::load_protected_envelope(path) {
        Ok(p) => p,
        Err(vault_core::storage::StorageError::SchemaVersionMismatch { expected, got }) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_SCHEMA_MISMATCH",
                "error": format!("Unsupported schema version {}, expected {}", got, expected),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_STORAGE_CORRUPTED",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    let seed = match vault_core::storage::decrypt_seed_with_password(
        &pin_str,
        &protected,
        vault_core::storage::EXPECTED_BUNDLE_ID,
        Some(protected.envelope.master_fingerprint),
    ) {
        Ok(s) => s,
        Err(vault_core::storage::StorageError::AuthenticationFailed) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_AUTH_FAILED",
                "error": "Authentication failed: wrong PIN/password or tampered vault storage",
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_STORAGE_CORRUPTED",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    let vault = match KeyVault::from_seed(seed, protected.has_passphrase_hint) {
        Ok(v) => v,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_SEED_RESTORE",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    if vault.master_fingerprint() != protected.envelope.master_fingerprint {
        let out = serde_json::json!({
            "status": "ERROR",
            "error_code": "ERR_FINGERPRINT_MISMATCH",
            "error": "Decrypted seed fingerprint does not match envelope header",
        });
        return CString::new(out.to_string()).unwrap().into_raw();
    }

    let multi = match vault.build_multi_accounts_ur(&[0, 1], "bcrt", 120) {
        Ok(m) => m,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_MULTI_ACCOUNTS",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    ctx.key_vault = Some(vault);

    let out = serde_json::json!({
        "status": "UNLOCKED",
        "master_fingerprint": multi.master_fingerprint,
        "has_passphrase_hint": protected.has_passphrase_hint,
        "multi_accounts": multi,
    });
    CString::new(out.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_export_multi_accounts_json(max_fragment_len: u32) -> *mut c_char {
    let ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_ref() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };
    let vault = match ctx.key_vault.as_ref() {
        Some(v) => v,
        None => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_VAULT_LOCKED",
                "error": "Vault is locked or uninitialized",
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };
    match vault.build_multi_accounts_ur(&[0, 1], "bcrt", max_fragment_len as usize) {
        Ok(multi) => {
            let out = serde_json::json!({
                "status": "SUCCESS",
                "master_fingerprint": multi.master_fingerprint,
                "has_passphrase_hint": vault.has_passphrase_hint(),
                "multi_accounts": multi,
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_MULTI_ACCOUNTS",
                "error": e.to_string(),
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
    }
}

#[no_mangle]
pub extern "C" fn vault_export_okx_accounts_json(max_fragment_len: u32) -> *mut c_char {
    let ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let vault = match ctx_guard.as_ref().and_then(|ctx| ctx.key_vault.as_ref()) {
        Some(vault) => vault,
        None => return error_json("ERR_VAULT_LOCKED", "Vault is locked or uninitialized"),
    };
    match vault.build_okx_multi_accounts_ur(max_fragment_len as usize) {
        Ok(multi) => CString::new(serde_json::json!({
            "status": "SUCCESS",
            "adapter": "okx-evm-account-standard",
            "master_fingerprint": multi.master_fingerprint,
            "has_passphrase_hint": vault.has_passphrase_hint(),
            "multi_accounts": multi,
        }).to_string()).unwrap().into_raw(),
        Err(error) => error_json("ERR_MULTI_ACCOUNTS", error),
    }
}

#[no_mangle]
pub extern "C" fn vault_export_encrypted_backup_json(
    backup_password: *const c_char,
) -> *mut c_char {
    if backup_password.is_null() {
        return std::ptr::null_mut();
    }
    let pw_str = unsafe { CStr::from_ptr(backup_password) }.to_string_lossy();
    let ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_ref() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };
    let vault = match ctx.key_vault.as_ref() {
        Some(v) => v,
        None => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_VAULT_LOCKED",
                "error": "Vault is locked or uninitialized",
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    match vault_core::storage::export_encrypted_backup_json(
        &pw_str,
        vault.seed_bytes(),
        vault.master_fingerprint(),
        vault.has_passphrase_hint(),
    ) {
        Ok(backup_json) => {
            let out = serde_json::json!({
                "status": "SUCCESS",
                "master_fingerprint": hex::encode(vault.master_fingerprint()),
                "backup_json": backup_json,
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_BACKUP_EXPORT",
                "error": e.to_string(),
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
    }
}

#[no_mangle]
pub extern "C" fn vault_preview_encrypted_backup_json(backup_json: *const c_char, backup_password: *const c_char) -> *mut c_char {
    if backup_json.is_null() || backup_password.is_null() { return error_json("ERR_BACKUP_INPUT", "Backup and password are required"); }
    let backup = unsafe { CStr::from_ptr(backup_json) }.to_string_lossy();
    let password = unsafe { CStr::from_ptr(backup_password) }.to_string_lossy();
    let (seed, expected_fp, hint) = match vault_core::storage::import_encrypted_backup_json(&password, &backup) {
        Ok(result) => result, Err(e) => return error_json("ERR_BACKUP_AUTH", e),
    };
    let vault = match KeyVault::from_seed(seed, hint) { Ok(v) => v, Err(e) => return error_json("ERR_SEED_RESTORE", e) };
    if vault.master_fingerprint() != expected_fp { return error_json("ERR_FINGERPRINT_MISMATCH", "Backup fingerprint mismatch"); }
    let multi = match vault.build_multi_accounts_ur(&[0, 1], "bcrt", 120) { Ok(m) => m, Err(e) => return error_json("ERR_DERIVATION", e) };
    CString::new(serde_json::json!({"status":"SUCCESS","master_fingerprint":multi.master_fingerprint,"multi_accounts":multi}).to_string()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_restore_from_encrypted_backup_json(
    backup_json: *const c_char,
    backup_password: *const c_char,
    storage_path: *const c_char,
    new_pin_password: *const c_char,
) -> *mut c_char {
    if backup_json.is_null() || backup_password.is_null() {
        return std::ptr::null_mut();
    }
    let b_json = unsafe { CStr::from_ptr(backup_json) }.to_string_lossy();
    let b_pw = unsafe { CStr::from_ptr(backup_password) }.to_string_lossy();
    let path_str = if storage_path.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(storage_path) }.to_string_lossy().into_owned()
    };
    let pin_str = if new_pin_password.is_null() {
        b_pw.to_string()
    } else {
        let s = unsafe { CStr::from_ptr(new_pin_password) }.to_string_lossy().into_owned();
        if s.trim().is_empty() { b_pw.to_string() } else { s }
    };

    if let Err(e) = validate_new_storage_path(&path_str) { return error_json("ERR_STORAGE_PATH", e); }
    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() { Some(ctx) => ctx, None => return error_json("ERR_NOT_INITIALIZED", "Initialize vault before restore") };
    if ctx.key_vault.is_some() { return error_json("ERR_VAULT_EXISTS", "Lock existing vault before restore"); }
    let (seed, expected_fp, hint) = match vault_core::storage::import_encrypted_backup_json(&b_pw, &b_json) {
        Ok(res) => res,
        Err(vault_core::storage::StorageError::AuthenticationFailed) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_AUTH_FAILED",
                "error": "Backup decryption failed: wrong password or tampered backup",
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        Err(vault_core::storage::StorageError::SchemaVersionMismatch { expected, got }) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_SCHEMA_MISMATCH",
                "error": format!("Unsupported backup version {}, expected {}", got, expected),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_BACKUP_CORRUPTED",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    let vault = match KeyVault::from_seed(seed, hint) {
        Ok(v) => v,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_SEED_RESTORE",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    if vault.master_fingerprint() != expected_fp {
        let out = serde_json::json!({
            "status": "ERROR",
            "error_code": "ERR_FINGERPRINT_MISMATCH",
            "error": "Restored seed fingerprint does not match backup header",
        });
        return CString::new(out.to_string()).unwrap().into_raw();
    }

    let multi = match vault.build_multi_accounts_ur(&[0, 1], "bcrt", 120) {
        Ok(m) => m,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_MULTI_ACCOUNTS",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    if !path_str.trim().is_empty() {
        let protected = match vault_core::storage::encrypt_seed_with_password(
            &pin_str,
            vault.seed_bytes(),
            vault.master_fingerprint(),
            vault_core::storage::EXPECTED_BUNDLE_ID,
            vault.has_passphrase_hint(),
        ) {
            Ok(p) => p,
            Err(e) => {
                let out = serde_json::json!({
                    "status": "ERROR",
                    "error_code": "ERR_ENCRYPTION_FAILED",
                    "error": e.to_string(),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        };
        if let Err(e) = vault_core::storage::save_new_protected_envelope_atomic(
            std::path::Path::new(path_str.trim()),
            &protected,
        ) {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_STORAGE_IO",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    }

    ctx.key_vault = Some(vault);

    let out = serde_json::json!({
        "status": "RESTORED",
        "master_fingerprint": multi.master_fingerprint,
        "has_passphrase_hint": hint,
        "multi_accounts": multi,
    });
    CString::new(out.to_string()).unwrap().into_raw()
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub extern "C" fn vault_load_test_mnemonic(
    phrase: *const c_char,
    passphrase: *const c_char,
) -> i32 {
    if phrase.is_null() {
        return -1;
    }
    let phrase_str = unsafe { CStr::from_ptr(phrase) }.to_string_lossy();
    let pass_str = if passphrase.is_null() {
        "".into()
    } else {
        unsafe { CStr::from_ptr(passphrase) }.to_string_lossy()
    };

    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return -1,
    };

    match KeyVault::from_mnemonic(&phrase_str, &pass_str) {
        Ok(v) => {
            ctx.key_vault = Some(v);
            0
        }
        Err(_) => -2,
    }
}

#[no_mangle]
pub extern "C" fn vault_prepare_legacy_tx_with_transport(
    session_id: *const c_char,
    request_id: *const c_char,
    raw_rlp_hex: *const c_char,
    declared_chain_id: u64,
    transport_code: u32,
) -> *mut c_char {
    if session_id.is_null() || request_id.is_null() || raw_rlp_hex.is_null() {
        return std::ptr::null_mut();
    }

    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let req_str = unsafe { CStr::from_ptr(request_id) }.to_string_lossy().to_string();
    let rlp_str = unsafe { CStr::from_ptr(raw_rlp_hex) }.to_string_lossy();

    let raw_bytes = match hex::decode(rlp_str.trim_start_matches("0x")) {
        Ok(b) => b,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    let tx = match LegacyTransaction::decode_unsigned(&raw_bytes, declared_chain_id) {
        Ok(t) => t,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"{}\"}}", e))
                .unwrap()
                .into_raw()
        }
    };

    let transaction = legacy_transaction_summary(&tx);
    let intent = tx.to_intent();
    let verdict = ctx.policy_engine.evaluate_intent(&intent);
    let digest = tx.signing_preimage_hash();

    ctx.monotonic_counter += 1;
    let handle_id = format!("handle-{}-{}", ctx.monotonic_counter, &req_str);

    // LIFE-01: Invalidate previous active request if any
    ctx.revoke_active_request();

    let transport = match transport_code {
        1 => Transport::NfcIsoDepHce,
        2 => Transport::NfcNdefMedia,
        3 => Transport::NfcCard,
        4 => Transport::Ble,
        5 => Transport::Usb,
        _ => Transport::Qr,
    };

    let prep = match PreparedRequest::new(
        sess_str,
        req_str,
        transport,
        SignerBackend::LocalVaultKey,
        tx.chain_id,
        tx.to.unwrap_or_default(),
        digest,
        intent,
        verdict,
    ) {
        Ok(p) => p.with_handle_id(handle_id.clone()),
        Err(e) => {
            return CString::new(format!("{{\"error\":\"{}\"}}", e))
                .unwrap()
                .into_raw()
        }
    };

    let mut summary = serde_json::to_value(&prep).unwrap();
    summary["transaction"] = transaction;
    if let Some(vault) = ctx.key_vault.as_ref() {
        match vault.derive_evm_public_account(0) {
            Ok(account) => { summary["signer_address"] = serde_json::json!(account.address); summary["derivation_path"] = serde_json::json!(account.derivation_path); },
            Err(e) => return error_json("ERR_DERIVATION", e),
        }
    }
    let json_summary = summary.to_string();
    if let Err(error) = ctx.retain_prepared_request(prep, None, None) {
        return error_json("ERR_REQUEST_RETENTION", error);
    }

    CString::new(json_summary).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_prepare_eip1559_tx_with_transport(
    session_id: *const c_char,
    request_id: *const c_char,
    raw_tx_hex: *const c_char,
    declared_chain_id: u64,
    transport_code: u32,
) -> *mut c_char {
    if session_id.is_null() || request_id.is_null() || raw_tx_hex.is_null() {
        return std::ptr::null_mut();
    }

    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let req_str = unsafe { CStr::from_ptr(request_id) }.to_string_lossy().to_string();
    let tx_str = unsafe { CStr::from_ptr(raw_tx_hex) }.to_string_lossy();

    let raw_bytes = match hex::decode(tx_str.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    let tx = match Eip1559Transaction::decode_unsigned(&raw_bytes, declared_chain_id) {
        Ok(t) => t,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"{}\"}}", e))
                .unwrap()
                .into_raw()
        }
    };
    if let Err(e) = validate_eip1559_gas_for_vault(&tx, ctx) {
        return error_json("ERR_GAS_PARAMETERS", e);
    }

    let transaction = match eip1559_transaction_summary(&tx, &raw_bytes) {
        Ok(value) => value,
        Err(e) => return error_json("ERR_TRANSACTION_REVIEW", e),
    };
    let intent = tx.to_intent();
    let verdict = ctx.policy_engine.evaluate_intent(&intent);
    let digest = tx.signing_preimage_hash();

    ctx.monotonic_counter += 1;
    let handle_id = format!("handle-{}-{}", ctx.monotonic_counter, &req_str);

    ctx.revoke_active_request();

    let transport = match transport_code {
        1 => Transport::NfcIsoDepHce,
        2 => Transport::NfcNdefMedia,
        3 => Transport::NfcCard,
        4 => Transport::Ble,
        5 => Transport::Usb,
        _ => Transport::Qr,
    };

    let prep = match PreparedRequest::new(
        sess_str,
        req_str,
        transport,
        SignerBackend::LocalVaultKey,
        tx.chain_id,
        tx.to.unwrap_or_default(),
        digest,
        intent,
        verdict,
    ) {
        Ok(p) => p.with_handle_id(handle_id.clone()),
        Err(e) => {
            return CString::new(format!("{{\"error\":\"{}\"}}", e))
                .unwrap()
                .into_raw()
        }
    };

    let mut summary = serde_json::to_value(&prep).unwrap();
    summary["transaction"] = transaction;
    if let Some(vault) = ctx.key_vault.as_ref() {
        match vault.derive_evm_public_account(0) {
            Ok(account) => { summary["signer_address"] = serde_json::json!(account.address); summary["derivation_path"] = serde_json::json!(account.derivation_path); },
            Err(e) => return error_json("ERR_DERIVATION", e),
        }
    }
    let json_summary = summary.to_string();
    if let Err(error) = ctx.retain_prepared_request(prep, None, None) {
        return error_json("ERR_REQUEST_RETENTION", error);
    }

    CString::new(json_summary).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_prepare_legacy_tx(
    session_id: *const c_char,
    request_id: *const c_char,
    raw_rlp_hex: *const c_char,
    declared_chain_id: u64,
) -> *mut c_char {
    vault_prepare_legacy_tx_with_transport(session_id, request_id, raw_rlp_hex, declared_chain_id, 0)
}


fn prepare_from_eth_sign_request(
    ctx: &mut VaultContext,
    sess_str: String,
    req_id_str: String,
    eth_req: &EthSignRequest,
    declared_chain_id: u64,
    transport: Transport,
) -> Result<String, String> {

    let active_chain_id = if declared_chain_id != 0 {
        if let Some(req_cid) = eth_req.chain_id {
            if req_cid != declared_chain_id {
                return Err(format!(
                    "ChainIdMismatch: declared {} does not match request {}",
                    declared_chain_id, req_cid
                ));
            }
        }
        declared_chain_id
    } else {
        eth_req.chain_id.ok_or("Missing explicit chain ID")?
    };

    if !ctx.policy_engine.allowed_chain_ids.contains(&active_chain_id) { return Err("Only local/testnet signing is enabled".into()); }
    let (digest, intent, to_addr, tx_chain_id, custom_verdict, type2_tx, transaction) = match eth_req.data_type {
        DataType::Transaction => {
            if eth_req.sign_data.first() == Some(&0x02) {
                let tx = Eip1559Transaction::decode_unsigned(&eth_req.sign_data, active_chain_id)
                    .map_err(|e| format!("{}", e))?;
                let transaction = eip1559_transaction_summary(&tx, &eth_req.sign_data)?;
                (
                    tx.signing_preimage_hash(),
                    tx.to_intent(),
                    tx.to.clone().unwrap_or_default(),
                    tx.chain_id,
                    None,
                    Some(tx),
                    transaction,
                )
            } else {
                let tx = LegacyTransaction::decode_unsigned(&eth_req.sign_data, active_chain_id)
                    .map_err(|e| format!("{}", e))?;
                let transaction = legacy_transaction_summary(&tx);
                (
                    tx.signing_preimage_hash(),
                    tx.to_intent(),
                    tx.to.unwrap_or_default(),
                    tx.chain_id,
                    None,
                    None,
                    transaction,
                )
            }
        }
        DataType::TypedTransaction => {
            let tx = Eip1559Transaction::decode_unsigned(&eth_req.sign_data, active_chain_id)
                .map_err(|e| format!("{}", e))?;
            let transaction = eip1559_transaction_summary(&tx, &eth_req.sign_data)?;
            (
                tx.signing_preimage_hash(),
                tx.to_intent(),
                tx.to.clone().unwrap_or_default(),
                tx.chain_id,
                None,
                Some(tx),
                transaction,
            )
        }
        DataType::TypedData | DataType::PersonalMessage => {
            return Err("Personal Sign and EIP-712 are not enabled in the QR transaction release".into());
        }
    };

    let path_str = eth_req.derivation_path.to_string_path();
    let leaf_index = path_str.strip_prefix("m/44'/60'/0'/0/").and_then(|index| index.parse::<u32>().ok()).filter(|index| *index < (1 << 31)).ok_or("Unsupported EVM derivation path")?;
    let vault = ctx.key_vault.as_ref().ok_or("Vault is locked")?;
    let account = vault.derive_evm_public_account(leaf_index).map_err(|e| e.to_string())?;
    if let Some(address) = eth_req.address {
        if !account.address.eq_ignore_ascii_case(&format!("0x{}", hex::encode(address))) { return Err("RequestAddressMismatch: address does not match derivation path".into()); }
    }
    if let Some(tx) = type2_tx {
        tx.validate_gas_for_signer(&account.address).map_err(|e| e.to_string())?;
    }
    let verdict = custom_verdict.unwrap_or_else(|| ctx.policy_engine.evaluate_intent(&intent));

    if let (Some(req_fp), Some(vault)) = (
        eth_req.derivation_path.source_fingerprint,
        ctx.key_vault.as_ref(),
    ) {
        if req_fp != [0, 0, 0, 0] && req_fp != vault.master_fingerprint() {
            return Err(format!(
                "MasterFingerprintMismatch: sign request targets fingerprint {}, but active vault is {}",
                hex::encode(req_fp),
                hex::encode(vault.master_fingerprint())
            ));
        }
    }

    ctx.monotonic_counter += 1;
    let handle_id = format!("handle-{}-{}", ctx.monotonic_counter, &req_id_str);

    // LIFE-01: Invalidate previous active request if any
    ctx.revoke_active_request();

    let prep = PreparedRequest::new(
        sess_str,
        req_id_str,
        transport,
        SignerBackend::LocalVaultKey,
        tx_chain_id,
        to_addr,
        digest,
        intent,
        verdict,
    )
    .map_err(|e| format!("{}", e))?
    .with_handle_id(handle_id.clone());

    let mut json_val = serde_json::to_value(&prep).map_err(|e| format!("{}", e))?;
    json_val["transaction"] = transaction;
    if let Some(obj) = json_val.as_object_mut() {
        obj.insert("derivation_path".to_string(), serde_json::Value::String(path_str.clone()));
        obj.insert("signer_address".to_string(), serde_json::Value::String(account.address));
    }
    let json_summary = serde_json::to_string(&json_val).map_err(|e| format!("{}", e))?;
    ctx.retain_prepared_request(prep, Some(path_str), None).map_err(String::from)?;
    Ok(json_summary)
}

#[no_mangle]
pub extern "C" fn vault_prepare_eip1559_tx(
    session_id: *const c_char,
    request_id: *const c_char,
    raw_payload_hex: *const c_char,
    declared_chain_id: u64,
) -> *mut c_char {
    if session_id.is_null() || request_id.is_null() || raw_payload_hex.is_null() {
        return std::ptr::null_mut();
    }

    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let req_str = unsafe { CStr::from_ptr(request_id) }.to_string_lossy().to_string();
    let payload_str = unsafe { CStr::from_ptr(raw_payload_hex) }.to_string_lossy();

    let raw_bytes = match hex::decode(payload_str.trim_start_matches("0x")) {
        Ok(b) => b,
        Err(_) => return std::ptr::null_mut(),
    };

    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    let tx = match Eip1559Transaction::decode_unsigned(&raw_bytes, declared_chain_id) {
        Ok(t) => t,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"{}\"}}", e))
                .unwrap()
                .into_raw();
        }
    };
    if let Err(e) = validate_eip1559_gas_for_vault(&tx, ctx) {
        return error_json("ERR_GAS_PARAMETERS", e);
    }

    let transaction = match eip1559_transaction_summary(&tx, &raw_bytes) {
        Ok(value) => value,
        Err(e) => return error_json("ERR_TRANSACTION_REVIEW", e),
    };
    let intent = tx.to_intent();
    let verdict = ctx.policy_engine.evaluate_intent(&intent);
    let digest = tx.signing_preimage_hash();

    ctx.monotonic_counter += 1;
    let handle_id = format!("handle-{}-{}", ctx.monotonic_counter, &req_str);

    // LIFE-01: Invalidate previous active request if any
    ctx.revoke_active_request();

    let prep = match PreparedRequest::new(
        sess_str,
        req_str,
        Transport::Qr,
        SignerBackend::LocalVaultKey,
        tx.chain_id,
        tx.to.unwrap_or_default(),
        digest,
        intent,
        verdict,
    ) {
        Ok(p) => p.with_handle_id(handle_id.clone()),
        Err(e) => {
            return CString::new(format!("{{\"error\":\"{}\"}}", e))
                .unwrap()
                .into_raw();
        }
    };

    let mut summary = serde_json::to_value(&prep).unwrap();
    summary["transaction"] = transaction;
    if let Some(vault) = ctx.key_vault.as_ref() {
        match vault.derive_evm_public_account(0) {
            Ok(account) => { summary["signer_address"] = serde_json::json!(account.address); summary["derivation_path"] = serde_json::json!(account.derivation_path); },
            Err(e) => return error_json("ERR_DERIVATION", e),
        }
    }
    let json_summary = summary.to_string();
    if let Err(error) = ctx.retain_prepared_request(prep, None, None) {
        return error_json("ERR_REQUEST_RETENTION", error);
    }

    CString::new(json_summary).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_prepare_sign_request_with_transport(
    session_id: *const c_char,
    request_id: *const c_char,
    cbor_hex: *const c_char,
    declared_chain_id: u64,
    transport_code: u32,
) -> *mut c_char {
    if session_id.is_null() || cbor_hex.is_null() {
        return std::ptr::null_mut();
    }

    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let req_str = if !request_id.is_null() {
        unsafe { CStr::from_ptr(request_id) }.to_string_lossy().to_string()
    } else {
        "req_cbor".into()
    };
    let cbor_str = unsafe { CStr::from_ptr(cbor_hex) }.to_string_lossy();
    let cbor_bytes = match hex::decode(cbor_str.trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"Invalid hex: {}\"}}", e))
                .unwrap()
                .into_raw();
        }
    };

    let eth_req = match EthSignRequest::from_cbor_bytes(&cbor_bytes) {
        Ok(r) => r,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"CBOR decode error: {}\"}}", e))
                .unwrap()
                .into_raw();
        }
    };

    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    let req_id_final = if let Some(arr) = eth_req.request_id {
        hex::encode(arr)
    } else {
        req_str
    };

    let transport = match transport_code {
        1 => Transport::NfcIsoDepHce,
        2 => Transport::NfcNdefMedia,
        3 => Transport::NfcCard,
        4 => Transport::Ble,
        5 => Transport::Usb,
        _ => Transport::Qr,
    };

    match prepare_from_eth_sign_request(ctx, sess_str, req_id_final, &eth_req, declared_chain_id, transport) {
        Ok(json_res) => CString::new(json_res).unwrap().into_raw(),
        Err(err_msg) => error_json("ERR_REQUEST_REJECTED", err_msg),
    }
}

#[no_mangle]
pub extern "C" fn vault_prepare_sign_request(
    session_id: *const c_char,
    request_id: *const c_char,
    cbor_hex: *const c_char,
    declared_chain_id: u64,
) -> *mut c_char {
    vault_prepare_sign_request_with_transport(session_id, request_id, cbor_hex, declared_chain_id, 0)
}

#[no_mangle]
pub extern "C" fn vault_prepare_ur_request(
    session_id: *const c_char,
    ur_string: *const c_char,
) -> *mut c_char {
    if session_id.is_null() || ur_string.is_null() {
        return std::ptr::null_mut();
    }

    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let ur_str = unsafe { CStr::from_ptr(ur_string) }.to_string_lossy();

    vault_cancel(std::ptr::null());
    let decoded_payload = match DecodedUrPayload::decode(ur_str.trim()) {
        Ok(p) => p,
        Err(e) => {
            return error_json("ERR_UR_DECODE", e);
        }
    };

    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    match decoded_payload {
        DecodedUrPayload::EthSignRequest(eth_req) => {
            let req_id_final = if let Some(arr) = eth_req.request_id {
                hex::encode(arr)
            } else {
                "req_ur".into()
            };
            match prepare_from_eth_sign_request(ctx, sess_str, req_id_final, &eth_req, 0, Transport::Qr) {
                Ok(json_res) => CString::new(json_res).unwrap().into_raw(),
                Err(err_msg) => error_json("ERR_REQUEST_REJECTED", err_msg),
            }
        }
        DecodedUrPayload::CryptoPsbt(cp) => {
            match prepare_from_crypto_psbt(ctx, sess_str, cp.psbt_data, "bcrt") {
                Ok(json_res) => CString::new(json_res).unwrap().into_raw(),
                Err(err_msg) => error_json("ERR_REQUEST_REJECTED", err_msg),
            }
        }

        _ => {
            CString::new("{\"error\":\"Unsupported UR payload (expected eth-sign-request or crypto-psbt)\"}")
                .unwrap()
                .into_raw()
        }
    }
}

fn prepare_from_crypto_psbt(
    ctx: &mut VaultContext,
    session_id: String,
    psbt_bytes: Vec<u8>,
    network_hrp: &str,
) -> Result<String, String> {
    let vault = ctx.key_vault.as_ref().ok_or("Vault key not initialized")?;

    let psbt = public_core::bitcoin::Psbt::deserialize(&psbt_bytes)
        .map_err(|e| format!("PSBT parse error: {e}"))?;

    if network_hrp != "bcrt" { return Err("Only Bitcoin regtest signing is enabled".into()); }
    let verdict = vault.audit_psbt_p2wpkh(&psbt, network_hrp)
        .map_err(|e| format!("PSBT policy rejection: {e}"))?;
    ur_adapter::CryptoPsbt::ensure_p2wpkh_response_capacity(&psbt)
        .map_err(|e| format!("PSBT response capacity: {e}"))?;
    ctx.revoke_active_request();

    ctx.monotonic_counter += 1;
    let handle_id = format!("h_psbt_{}", ctx.monotonic_counter);
    // Bind review and cached responses to the same original-PSBT SHA256 used
    // by Wallet. A new scan handle must not turn identical bytes into a new
    // signing request or invoke the primitive again.
    let digest = public_core::bitcoin::sha256(&psbt_bytes);
    let request_id = format!("psbt-{}", hex::encode(digest));
    let recipient_amount_sat = verdict.destination_outputs.iter().try_fold(0u64, |sum, output| {
        sum.checked_add(output.amount_sat).ok_or("Recipient amount overflow")
    })?;

    let recipient_str = verdict.destination_outputs.first().map(|d| d.address.clone()).unwrap_or_else(|| "InternalChange".into());
    let intent = ParsedIntent::NativeTransfer {
        chain_id: 0,
        recipient: recipient_str.clone(),
        value_wei: recipient_amount_sat.to_string(),
        fee_cap_wei: verdict.fee_sat.to_string(),
    };
    let policy_verdict = public_core::policy::PolicyVerdict::Approved {
        chain_id: 0,
        recipient: recipient_str.clone(),
        amount_display: format!("{} sat", recipient_amount_sat),
        fee_cap_wei: verdict.fee_sat.to_string(),
    };
    let prep_req = PreparedRequest::new(
        session_id.clone(),
        request_id.clone(),
        Transport::Qr,
        SignerBackend::LocalVaultKey,
        0, // Bitcoin chain_id
        recipient_str,
        digest,
        intent,
        policy_verdict,
    )
    .map_err(|e| format!("{}", e))?
    .with_handle_id(handle_id.clone());

    ctx.retain_prepared_request(prep_req, None, Some(psbt_bytes)).map_err(String::from)?;

    Ok(serde_json::json!({
        "status": "SUCCESS",
        "handle_id": handle_id,
        "type": "BITCOIN_PSBT",
        "network": "regtest",
        "session_id": session_id,
        "request_id": request_id,
        "signing_digest": hex::encode(digest),
        "inputs_count": verdict.inputs_verified_count,
        "total_input_sat": verdict.total_input_sat,
        "total_output_sat": verdict.total_output_sat,
        "recipient_amount_sats": recipient_amount_sat,
        "fee_sat": verdict.fee_sat,
        "destinations": verdict.destination_outputs,
        "changes": verdict.change_outputs,
        "master_fingerprint": verdict.master_fingerprint,
    }).to_string())
}

#[no_mangle]
pub extern "C" fn vault_prepare_psbt_request(
    session_id: *const c_char,
    psbt_raw_or_ur: *const c_char,
    network_hrp: *const c_char,
) -> *mut c_char {
    if session_id.is_null() || psbt_raw_or_ur.is_null() {
        return std::ptr::null_mut();
    }

    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let raw_str = unsafe { CStr::from_ptr(psbt_raw_or_ur) }.to_string_lossy();
    let clean = raw_str.trim();

    let hrp_str = if network_hrp.is_null() {
        "bcrt".to_string()
    } else {
        unsafe { CStr::from_ptr(network_hrp) }.to_string_lossy().to_string()
    };

    let psbt_bytes = if clean.to_lowercase().starts_with("ur:crypto-psbt/") {
        match DecodedUrPayload::decode(clean) {
            Ok(DecodedUrPayload::CryptoPsbt(cp)) => cp.psbt_data,
            _ => {
                return CString::new("{\"error\":\"Failed to decode crypto-psbt UR\"}").unwrap().into_raw();
            }
        }
    } else if let Ok(b) = hex::decode(clean.trim_start_matches("0x")) {
        b
    } else {
        return CString::new("{\"error\":\"Invalid PSBT encoding (neither UR nor hex)\"}").unwrap().into_raw();
    };

    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    match prepare_from_crypto_psbt(ctx, sess_str, psbt_bytes, &hrp_str) {
        Ok(s) => CString::new(s).unwrap().into_raw(),
        Err(e) => CString::new(format!("{{\"error\":\"{}\"}}", e)).unwrap().into_raw(),
    }
}

#[no_mangle]
pub extern "C" fn vault_approve_and_generate_signature_ur(handle_id: *const c_char) -> *mut c_char {
    vault_approve_and_sign(handle_id)
}

#[no_mangle]
pub extern "C" fn vault_approve_and_sign(handle_id: *const c_char) -> *mut c_char {
    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    let target_handle = if !handle_id.is_null() {
        unsafe { CStr::from_ptr(handle_id) }.to_string_lossy().to_string()
    } else if let Some(ref h) = ctx.active_handle_id {
        h.clone()
    } else {
        return CString::new("{\"error\":\"No active prepared request\"}")
            .unwrap()
            .into_raw();
    };

    if ctx.cancelled_receipt(&target_handle).is_some() {
        return error_json("ERR_ALREADY_CANCELLED", "Request already cancelled (LIFE-01)");
    }
    let req = match ctx.requests.get_mut(&target_handle) {
        Some(r) => r,
        None => {
            return CString::new(format!("{{\"error\":\"Handle not found: {}\"}}", target_handle))
                .unwrap()
                .into_raw();
        }
    };

    if req.state == RequestState::Consumed {
        return CString::new("{\"error\":\"Request already consumed (LIFE-03)\",\"error_code\":\"ERR_ALREADY_CONSUMED\"}")
            .unwrap()
            .into_raw();
    }
    if req.state == RequestState::Cancelled {
        return CString::new("{\"error\":\"Request already cancelled (LIFE-01)\",\"error_code\":\"ERR_ALREADY_CANCELLED\"}")
            .unwrap()
            .into_raw();
    }
    if req.state == RequestState::SigningOutcomeUnknown {
        return CString::new("{\"error\":\"Request signing outcome unknown; automatic retry forbidden\",\"error_code\":\"ERR_OUTCOME_UNKNOWN\"}")
            .unwrap()
            .into_raw();
    }
    if matches!(
        req.state,
        RequestState::SignCommandSent | RequestState::SignedVerified | RequestState::ResponseReady
    ) || req.sign_command_count > 0
    {
        return CString::new("{\"error\":\"Request already signed (LIFE-03)\",\"error_code\":\"ERR_ALREADY_SIGNED\"}")
            .unwrap()
            .into_raw();
    }

    let vault = match ctx.key_vault.as_ref() {
        Some(v) => v,
        None => {
            return CString::new("{\"error\":\"Vault key not initialized\"}")
                .unwrap()
                .into_raw();
        }
    };

    // Same signed request scanned again: return the existing response without
    // entering the signing state machine or invoking the signing primitive.
    let wallet_identity = match vault.derive_evm_public_account(0) { Ok(account) => account.compressed_pubkey_hex, Err(e) => return error_json("ERR_DERIVATION", e) };
    let response_key = format!("{}:{}:{}:{}:{}:{}", wallet_identity, req.request_id, req.chain_id, hex::encode(req.raw_signing_digest), ctx.request_paths.get(&target_handle).map(String::as_str).unwrap_or("m/44'/60'/0'/0/0"), serde_json::to_string(&req.policy_verdict).unwrap());
    if let Some(cached) = ctx.signed_results.get(&response_key) {
        req.state = RequestState::Consumed;
        return CString::new(cached.as_str()).unwrap().into_raw();
    }
    if req.chain_id == 0 {
        let psbt_bytes = match ctx.psbts.get(&target_handle) {
            Some(bytes) => bytes,
            None => return error_json("ERR_PSBT_PAYLOAD", "PSBT payload not found in vault context"),
        };
        let psbt = match public_core::bitcoin::Psbt::deserialize(psbt_bytes) {
            Ok(psbt) => psbt,
            Err(error) => return error_json("ERR_PSBT_PARSE", error),
        };
        if let Err(error) = ur_adapter::CryptoPsbt::ensure_p2wpkh_response_capacity(&psbt) {
            return error_json("ERR_PSBT_RESPONSE_SIZE", error);
        }
    }
    let _ = req.start_review();
    if let Err(e) = req.approve() {
        return CString::new(format!("{{\"error\":\"{}\"}}", e))
            .unwrap()
            .into_raw();
    }
    if let Err(e) = req.mark_sign_command_sent(SignerBackend::LocalVaultKey) {
        return CString::new(format!("{{\"error\":\"{}\"}}", e))
            .unwrap()
            .into_raw();
    }

    if req.chain_id == 0 {
        let psbt_bytes = match ctx.psbts.get(&target_handle) {
            Some(b) => b,
            None => {
                let _ = req.mark_disconnected_or_interrupted();
                return CString::new("{\"error\":\"PSBT payload not found in vault context\"}")
                    .unwrap()
                    .into_raw();
            }
        };

        let mut psbt = match public_core::bitcoin::Psbt::deserialize(psbt_bytes) {
            Ok(p) => p,
            Err(e) => {
                let _ = req.mark_disconnected_or_interrupted();
                return CString::new(format!("{{\"error\":\"PSBT deserialization error: {}\"}}", e))
                    .unwrap()
                    .into_raw();
            }
        };

        match vault.sign_psbt_p2wpkh(&mut psbt) {
            Ok(inputs_signed) => {
                let signed_bytes = psbt.serialize();
                let _ = req.complete_with_signature(signed_bytes.clone());
                let _ = req.prepare_response();
                let _ = req.consume();

                let crypto_psbt = ur_adapter::CryptoPsbt::new(signed_bytes.clone());
                let psbt_cbor = crypto_psbt.to_cbor_bytes();
                let psbt_ur = ur_adapter::displayable_single_ur(ur_adapter::CryptoPsbt::UR_TYPE, &psbt_cbor).unwrap_or_default();
                let fragment_len = match ur_adapter::default_fragment_len(&psbt_cbor) {
                    Ok(length) => length,
                    Err(error) => return error_json("ERR_UR_ENCODE", error),
                };
                let psbt_frames = match ur_adapter::encode_ur_fountain_frames(
                    ur_adapter::CryptoPsbt::UR_TYPE,
                    &psbt_cbor,
                    fragment_len,
                ) {
                    Ok(frames) => frames,
                    Err(error) => return error_json("ERR_UR_ENCODE", error),
                };
                let psbt_hex = hex::encode(&signed_bytes);

                let out = serde_json::json!({
                    "status": "SUCCESS",
                    "handle_id": target_handle,
                    "type": "BITCOIN_PSBT",
                    "signed_psbt_hex": psbt_hex,
                    "signed_psbt_ur": psbt_ur,
                    "signed_psbt_ur_frames": psbt_frames,
                    "inputs_signed": inputs_signed,
                });
                let result = out.to_string();
                ctx.signed_results.insert(response_key, result.clone());
                return CString::new(result).unwrap().into_raw();
            }
            Err(e) => {
                let _ = req.mark_disconnected_or_interrupted();
                return CString::new(format!("{{\"error\":\"{}\"}}", e))
                    .unwrap()
                    .into_raw();
            }
        }
    }

    let sign_path = ctx
        .request_paths
        .get(&target_handle)
        .cloned()
        .unwrap_or_else(|| "m/44'/60'/0'/0/0".to_string());

    match vault.derive_address_and_sign(&sign_path, &req.raw_signing_digest) {
        Ok((recovered_addr, sig_65)) => {
            let sig_hex = hex::encode(sig_65);
            let _ = req.complete_with_signature(sig_65.to_vec());
            let _ = req.prepare_response();
            // LIFE-03: Transition to Consumed to prevent replay
            let _ = req.consume();

            let req_id_bytes: Option<[u8; 16]> = hex::decode(req.request_id.trim_start_matches("0x"))
                .ok()
                .and_then(|b| if b.len() == 16 {
                    let mut arr = [0u8; 16];
                    arr.copy_from_slice(&b);
                    Some(arr)
                } else {
                    None
                });

            let eth_sig = EthSignature::new(req_id_bytes, sig_65, Some("MobileVault".into()));
            let sig_cbor = eth_sig.to_cbor_bytes();
            let sig_ur = ur_adapter::displayable_single_ur(EthSignature::UR_TYPE, &sig_cbor).unwrap_or_default();
            let sig_frames = match ur_adapter::encode_ur_fountain_frames(
                EthSignature::UR_TYPE,
                &sig_cbor,
                120,
            ) {
                Ok(frames) => frames,
                Err(error) => return error_json("ERR_UR_ENCODE", error),
            };

            let out = serde_json::json!({
                "status": "SUCCESS",
                "handle_id": target_handle,
                "derivation_path": sign_path,
                "address": recovered_addr,
                "signature": format!("0x{}", sig_hex),
                "signature_ur": sig_ur,
                "signature_ur_frames": sig_frames,
            });
            let result = out.to_string();
            ctx.signed_results.insert(response_key, result.clone());
            CString::new(result).unwrap().into_raw()
        }
        Err(e) => {
            let _ = req.mark_disconnected_or_interrupted();
            CString::new(format!("{{\"error\":\"{:?}\"}}", e))
                .unwrap()
                .into_raw()
        }
    }
}

/// Non-destructive, panic-free cancellation:
/// - `0`: cancelled from a pre-sign state (`state == Cancelled`, `sign_command_count == 0`).
/// - `-1`: context uninitialized or handle not found.
/// - `-2`: `ERR_ALREADY_SIGNED` (`SignCommandSent` / `SignedVerified` / `ResponseReady`); state preserved.
/// - `-3`: `ERR_ALREADY_CONSUMED` (`Consumed`); state preserved.
/// - `-4`: `ERR_OUTCOME_UNKNOWN` (`SigningOutcomeUnknown`); state preserved.
/// - `-5`: `ERR_ALREADY_CANCELLED` (`Cancelled`); state preserved.
/// - `-6`: `ERR_INVALID_STATE_TRANSITION`; state preserved.
#[no_mangle]
pub extern "C" fn vault_cancel(handle_id: *const c_char) -> i32 {
    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return -1,
    };
    let target_handle = if !handle_id.is_null() {
        unsafe { CStr::from_ptr(handle_id) }.to_string_lossy().to_string()
    } else if let Some(ref h) = ctx.active_handle_id {
        h.clone()
    } else {
        return -1;
    };

    if ctx.cancelled_receipt(&target_handle).is_some() { return -5; }
    let req = match ctx.requests.get_mut(&target_handle) {
        Some(r) => r,
        None => return -1,
    };

    match req.cancel() {
        Ok(()) => { ctx.release_cancelled_request(&target_handle); 0 },
        Err(signer_router::RouterError::AlreadySigned { .. }) => -2,
        Err(signer_router::RouterError::AlreadyConsumed) => -3,
        Err(signer_router::RouterError::OutcomeUnknownCannotCancel) => -4,
        Err(signer_router::RouterError::AlreadyCancelled) => -5,
        Err(_) => -6,
    }
}

#[no_mangle]
pub extern "C" fn vault_cancel_json(handle_id: *const c_char) -> *mut c_char {
    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => {
            return CString::new("{\"status\":\"ERROR\",\"code\":-1,\"error_code\":\"ERR_NOT_INITIALIZED\",\"error\":\"Vault context not initialized\"}")
                .unwrap()
                .into_raw()
        }
    };
    let target_handle = if !handle_id.is_null() {
        unsafe { CStr::from_ptr(handle_id) }.to_string_lossy().to_string()
    } else if let Some(ref h) = ctx.active_handle_id {
        h.clone()
    } else {
        return CString::new("{\"status\":\"ERROR\",\"code\":-1,\"error_code\":\"ERR_NO_HANDLE\",\"error\":\"No active handle\"}")
            .unwrap()
            .into_raw();
    };

    let primitive_count = ctx
        .key_vault
        .as_ref()
        .map(|v| v.primitive_sign_invocations())
        .unwrap_or(0);

    if ctx.cancelled_receipt(&target_handle).is_some() {
        let out = serde_json::json!({
            "status":"ERROR", "code":-5, "error_code":"ERR_ALREADY_CANCELLED",
            "error":"Request is already cancelled", "handle_id":target_handle,
            "state":"Cancelled", "sign_command_count":0,
            "primitive_sign_invocations":primitive_count,
        });
        return CString::new(out.to_string()).unwrap().into_raw();
    }
    let req = match ctx.requests.get_mut(&target_handle) {
        Some(r) => r,
        None => {
            let out = serde_json::json!({
                "status": "ERROR",
                "code": -1,
                "error_code": "ERR_HANDLE_NOT_FOUND",
                "error": format!("Handle not found: {}", target_handle),
                "primitive_sign_invocations": primitive_count,
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    match req.cancel() {
        Ok(()) => {
            let out = serde_json::json!({
                "status": "CANCELLED",
                "code": 0,
                "error_code": serde_json::Value::Null,
                "handle_id": target_handle,
                "state": format!("{:?}", req.state),
                "sign_command_count": req.sign_command_count,
                "primitive_sign_invocations": primitive_count,
            });
            ctx.release_cancelled_request(&target_handle);
            CString::new(out.to_string()).unwrap().into_raw()
        }
        Err(err) => {
            let (code, err_code) = match &err {
                signer_router::RouterError::AlreadySigned { .. } => (-2, "ERR_ALREADY_SIGNED"),
                signer_router::RouterError::AlreadyConsumed => (-3, "ERR_ALREADY_CONSUMED"),
                signer_router::RouterError::OutcomeUnknownCannotCancel => (-4, "ERR_OUTCOME_UNKNOWN"),
                signer_router::RouterError::AlreadyCancelled => (-5, "ERR_ALREADY_CANCELLED"),
                _ => (-6, "ERR_INVALID_STATE_TRANSITION"),
            };
            let out = serde_json::json!({
                "status": "ERROR",
                "code": code,
                "error_code": err_code,
                "error": err.to_string(),
                "handle_id": target_handle,
                "state": format!("{:?}", req.state),
                "sign_command_count": req.sign_command_count,
                "primitive_sign_invocations": primitive_count,
            });
            CString::new(out.to_string()).unwrap().into_raw()
        }
    }
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub extern "C" fn vault_create_test_psbt(variant: u32) -> *mut c_char {
    use public_core::bitcoin::{OutPoint, Psbt, PsbtInput, PsbtOutput, Transaction, TxIn, TxOut};
    use std::collections::BTreeMap;

    let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    let vault = match vault_core::KeyVault::from_mnemonic(mnemonic, "") {
        Ok(v) => v,
        Err(_) => return std::ptr::null_mut(),
    };

    let (_, receive_pubk_arr) = vault.derive_bitcoin_address("m/84'/0'/0'/0/0", "bc").unwrap();
    let (_, change_pubk_arr) = vault.derive_bitcoin_address("m/84'/0'/0'/1/0", "bc").unwrap();
    let receive_pubkey = receive_pubk_arr.to_vec();
    let change_pubkey = change_pubk_arr.to_vec();

    let receive_pkh = public_core::bitcoin::hash160(&receive_pubkey);
    let receive_script = [&[0x00, 0x14], &receive_pkh[..]].concat();
    let change_pkh = public_core::bitcoin::hash160(&change_pubkey);
    let change_script = [&[0x00, 0x14], &change_pkh[..]].concat();

    let input_val = if variant == 6 { 50_000_000 } else { 500_000 };

    let prev_tx = Transaction {
        version: 2,
        lock_time: 0,
        inputs: vec![TxIn {
            previous_output: OutPoint {
                txid: [0xaa; 32],
                vout: 0,
            },
            script_sig: vec![],
            sequence: 0xffffffff,
        }],
        outputs: vec![TxOut {
            value: input_val,
            script_pubkey: receive_script.clone(),
        }],
    };
    let prev_txid = prev_tx.txid();

    let (out0_val, out1_val) = match variant {
        4 => (600_000, 0), // Negative fee
        6 => (40_000_000, 0), // Fee = 10,000,000 sat (0.1 BTC > 0.05 BTC)
        _ => (400_000, 98_000), // Standard: fee = 2,000 sat
    };

    let mut unsigned_outputs = vec![TxOut {
        value: out0_val,
        script_pubkey: vec![
            0x00, 0x14, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
            0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
        ],
    }];
    if out1_val > 0 {
        unsigned_outputs.push(TxOut {
            value: out1_val,
            script_pubkey: change_script,
        });
    }

    let unsigned_tx = Transaction {
        version: 2,
        lock_time: 0,
        inputs: vec![TxIn {
            previous_output: OutPoint {
                txid: prev_txid,
                vout: 0,
            },
            script_sig: vec![],
            sequence: 0xfffffffd,
        }],
        outputs: unsigned_outputs,
    };

    let in_fp = if variant == 2 {
        [0xde, 0xad, 0xbe, 0xef] // Foreign input
    } else {
        [0x73, 0xc5, 0xda, 0x0a]
    };

    let mut in_derivations = BTreeMap::new();
    in_derivations.insert(
        receive_pubkey,
        (in_fp, vec![84 | 0x80000000, 0x80000000, 0x80000000, 0, 0]),
    );

    let sighash_opt = if variant == 5 {
        Some(0x02) // SIGHASH_NONE
    } else {
        Some(0x01) // SIGHASH_ALL
    };

    let psbt_in = PsbtInput {
        non_witness_utxo: if variant == 3 { None } else { Some(prev_tx) },
        witness_utxo: Some(TxOut {
            value: input_val,
            script_pubkey: receive_script,
        }),
        sighash_type: sighash_opt,
        bip32_derivation: in_derivations,
        ..Default::default()
    };

    let mut psbt_outputs = vec![PsbtOutput::default()];
    if out1_val > 0 {
        let change_fp = if variant == 1 {
            [0xde, 0xad, 0xbe, 0xef] // Fake change
        } else {
            [0x73, 0xc5, 0xda, 0x0a]
        };
        let mut out_derivations = BTreeMap::new();
        out_derivations.insert(
            change_pubkey,
            (change_fp, vec![84 | 0x80000000, 0x80000000, 0x80000000, 1, 0]),
        );
        psbt_outputs.push(PsbtOutput {
            bip32_derivation: out_derivations,
            ..Default::default()
        });
    }

    let psbt = Psbt {
        unsigned_tx,
        inputs: vec![psbt_in],
        outputs: psbt_outputs,
        unknown_global: BTreeMap::new(),
    };

    let hex_str = hex::encode(psbt.serialize());
    CString::new(hex_str).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_get_primitive_sign_count() -> i64 {
    let ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_ref() {
        Some(c) => c,
        None => return -1,
    };
    ctx.key_vault
        .as_ref()
        .map(|v| v.primitive_sign_invocations() as i64)
        .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn vault_nfc_reset_sessions() -> i32 {
    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return -1,
    };
    ctx.nfc_sessions.clear_all();
    ctx.apdu_frame_assembler.reset();
    0
}

#[no_mangle]
pub extern "C" fn vault_get_request_state(handle_id: *const c_char) -> *mut c_char {
    let ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_ref() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    let target_handle = if !handle_id.is_null() {
        unsafe { CStr::from_ptr(handle_id) }.to_string_lossy().to_string()
    } else if let Some(ref h) = ctx.active_handle_id {
        h.clone()
    } else {
        return CString::new("{\"error\":\"No active handle\"}").unwrap().into_raw();
    };

    if let Some(receipt) = ctx.cancelled_receipt(&target_handle) {
        let primitive_count = ctx.key_vault.as_ref().map(|vault| vault.primitive_sign_invocations()).unwrap_or(0);
        let out = serde_json::json!({
            "status":"SUCCESS", "handle_id":target_handle, "state":"Cancelled",
            "sign_command_count":0, "primitive_sign_invocations":primitive_count,
            "backend":receipt.backend, "transport":receipt.transport,
        });
        return CString::new(out.to_string()).unwrap().into_raw();
    }
    let req = match ctx.requests.get(&target_handle) {
        Some(r) => r,
        None => {
            return CString::new(format!("{{\"error\":\"Handle not found: {}\"}}", target_handle))
                .unwrap()
                .into_raw();
        }
    };

    let primitive_count = ctx
        .key_vault
        .as_ref()
        .map(|v| v.primitive_sign_invocations())
        .unwrap_or(0);

    let out = format!(
        "{{\"status\":\"SUCCESS\",\"handle_id\":\"{}\",\"state\":\"{:?}\",\"sign_command_count\":{},\"primitive_sign_invocations\":{},\"backend\":\"{:?}\",\"transport\":\"{:?}\"}}",
        target_handle, req.state, req.sign_command_count, primitive_count, req.backend, req.transport
    );
    CString::new(out).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_mark_disconnected(handle_id: *const c_char) -> i32 {
    let mut ctx_guard = CONTEXT.lock().unwrap();
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return -1,
    };

    let target_handle = if !handle_id.is_null() {
        unsafe { CStr::from_ptr(handle_id) }.to_string_lossy().to_string()
    } else if let Some(ref h) = ctx.active_handle_id {
        h.clone()
    } else {
        return -1;
    };

    if let Some(req) = ctx.requests.get_mut(&target_handle) {
        let _ = req.mark_disconnected_or_interrupted();
        ctx.release_cancelled_request(&target_handle);
        0
    } else if ctx.cancelled_receipt(&target_handle).is_some() {
        0
    } else {
        -1
    }
}

#[no_mangle]
pub extern "C" fn vault_nfc_chunk_payload(
    session_id: *const c_char,
    request_id: *const c_char,
    message_kind_u8: u8,
    raw_payload_hex: *const c_char,
    chunk_size: usize,
) -> *mut c_char {
    if session_id.is_null() || request_id.is_null() || raw_payload_hex.is_null() {
        return std::ptr::null_mut();
    }

    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let req_str = unsafe { CStr::from_ptr(request_id) }.to_string_lossy().to_string();
    let payload_str = unsafe { CStr::from_ptr(raw_payload_hex) }.to_string_lossy();

    let raw_bytes = match hex::decode(payload_str.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"Invalid hex payload: {}\"}}", e))
                .unwrap()
                .into_raw();
        }
    };

    if raw_bytes.is_empty() {
        return CString::new("{\"error\":\"Payload must not be empty\"}")
            .unwrap()
            .into_raw();
    }

    if raw_bytes.len() > nfc_protocol::MAX_NFC_PAYLOAD_SIZE {
        return CString::new("{\"error\":\"Payload exceeds 128 KiB NFC boundary limit\"}")
            .unwrap()
            .into_raw();
    }

    let chunk_limit = if chunk_size == 0 || chunk_size > 180 {
        120
    } else {
        chunk_size
    };

    let msg_kind = match message_kind_u8 {
        1 => nfc_protocol::MessageKind::Capabilities,
        2 => nfc_protocol::MessageKind::Pairing,
        3 => nfc_protocol::MessageKind::AccountDescriptor,
        4 => nfc_protocol::MessageKind::SignRequest,
        5 => nfc_protocol::MessageKind::Status,
        6 => nfc_protocol::MessageKind::SignResponse,
        7 => nfc_protocol::MessageKind::Cancel,
        8 => nfc_protocol::MessageKind::Ack,
        _ => nfc_protocol::MessageKind::Error,
    };

    let total_chunks = ((raw_bytes.len() + chunk_limit - 1) / chunk_limit) as u32;

    let digest = nfc_protocol::sha256_hex(&raw_bytes);
    let mut chunk_records = Vec::new();

    for i in 0..total_chunks {
        let start = (i as usize) * chunk_limit;
        let end = std::cmp::min(start + chunk_limit, raw_bytes.len());
        let slice = if start < raw_bytes.len() {
            raw_bytes[start..end].to_vec()
        } else {
            Vec::new()
        };

        let env = nfc_protocol::NfcEnvelope {
            wire_version: nfc_protocol::PROTOCOL_WIRE_VERSION,
            message_kind: msg_kind,
            session_id: sess_str.clone(),
            request_id: req_str.clone(),
            chunk_index: i,
            total_chunks,
            payload_digest: digest.clone(),
            payload: slice.clone(),
        };

        let cbor_bytes = match env.to_cbor() {
            Ok(b) => b,
            Err(e) => {
                return CString::new(format!("{{\"error\":\"Envelope serialization error: {}\"}}", e))
                    .unwrap()
                    .into_raw();
            }
        };

        if cbor_bytes.len() > nfc_protocol::MAX_ENVELOPE_CBOR_LEN {
            return CString::new(format!(
                "{{\"error\":\"Serialized CBOR envelope length {} exceeds limit {}\"}}",
                cbor_bytes.len(),
                nfc_protocol::MAX_ENVELOPE_CBOR_LEN
            ))
            .unwrap()
            .into_raw();
        }

        let apdu_frames = match nfc_protocol::encode_cbor_to_apdu_frames(
            &cbor_bytes,
            nfc_protocol::INS_NFC_ENVELOPE_FRAME,
            nfc_protocol::MAX_HCE_APDU_DATA_LEN,
            nfc_protocol::MIN_ISODEP_MAX_TRANSCEIVE_LEN,
        ) {
            Ok(f) => f,
            Err(e) => {
                return CString::new(format!("{{\"error\":\"APDU framing error: {}\"}}", e))
                    .unwrap()
                    .into_raw();
            }
        };
        let apdu_hex_list: Vec<String> = apdu_frames.iter().map(hex::encode).collect();
        let apdu_len_list: Vec<usize> = apdu_frames.iter().map(|f| f.len()).collect();
        let apdu_lc_list: Vec<usize> = apdu_frames.iter().map(|f| f[4] as usize).collect();

        chunk_records.push(serde_json::json!({
            "chunk_index": i,
            "total_chunks": total_chunks,
            "raw_payload_len": slice.len(),
            "cbor_hex": hex::encode(&cbor_bytes),
            "byte_len": cbor_bytes.len(),
            "cbor_byte_len": cbor_bytes.len(),
            "max_apdu_data_len": nfc_protocol::MAX_HCE_APDU_DATA_LEN,
            "max_capdu_wire_len": nfc_protocol::MAX_HCE_CAPDU_WIRE_LEN,
            "apdu_frames_hex": apdu_hex_list,
            "apdu_frame_lengths": apdu_len_list,
            "apdu_data_lengths": apdu_lc_list,
        }));
    }

    let out_json = serde_json::to_string(&chunk_records).unwrap_or_default();
    CString::new(out_json).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn vault_nfc_process_chunk(apdu_cbor_hex: *const c_char) -> *mut c_char {
    if apdu_cbor_hex.is_null() {
        return std::ptr::null_mut();
    }

    let hex_str = unsafe { CStr::from_ptr(apdu_cbor_hex) }.to_string_lossy();
    let bytes = match hex::decode(hex_str.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"Invalid hex: {}\"}}", e))
                .unwrap()
                .into_raw();
        }
    };

    let env = match nfc_protocol::NfcEnvelope::from_cbor(&bytes) {
        Ok(e) => e,
        Err(err) => {
            return CString::new(format!("{{\"error\":\"Envelope decode error: {}\"}}", err))
                .unwrap()
                .into_raw();
        }
    };

    let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    let ctx = match ctx_guard.as_mut() {
        Some(c) => c,
        None => return std::ptr::null_mut(),
    };

    ctx.nfc_clock_ms = ctx.nfc_clock_ms.saturating_add(10);
    let now_ms = ctx.nfc_clock_ms;

    match ctx.nfc_sessions.process_envelope(&env, now_ms) {
        Ok(None) => {
            let assembler = ctx.nfc_sessions.assemblers.get(&env.session_id).unwrap();
            let res = serde_json::json!({
                "status": "IN_PROGRESS",
                "session_id": assembler.session_id,
                "request_id": assembler.request_id,
                "total_chunks": assembler.total_chunks,
            });
            CString::new(res.to_string()).unwrap().into_raw()
        }
        Ok(Some((verified_sess_id, verified_req_id, verified_kind, full_payload))) => {
            let digest = nfc_protocol::sha256_hex(&full_payload);
            let res = serde_json::json!({
                "status": "COMPLETE",
                "session_id": verified_sess_id,
                "request_id": verified_req_id,
                "message_kind": verified_kind as u8,
                "payload_hex": hex::encode(&full_payload),
                "payload_len": full_payload.len(),
                "payload_digest": digest
            });
            CString::new(res.to_string()).unwrap().into_raw()
        }
        Err(e) => CString::new(format!("{{\"error\":\"NFC fragment error: {}\"}}", e))
            .unwrap()
            .into_raw(),
    }
}

#[no_mangle]
pub extern "C" fn vault_nfc_process_apdu_frame(apdu_hex: *const c_char) -> *mut c_char {
    if apdu_hex.is_null() {
        return std::ptr::null_mut();
    }
    let hex_str = unsafe { CStr::from_ptr(apdu_hex) }.to_string_lossy();
    let capdu = match hex::decode(hex_str.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"Invalid APDU hex: {}\",\"sw\":\"6f00\"}}", e))
                .unwrap()
                .into_raw()
        }
    };

    let maybe_env = {
        let mut ctx_guard = CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
        let ctx = match ctx_guard.as_mut() {
            Some(c) => c,
            None => return std::ptr::null_mut(),
        };
        ctx.apdu_frame_assembler.accept_apdu(&capdu)
    };

    match maybe_env {
        Ok(None) => CString::new("{\"status\":\"FRAME_ACK\",\"sw\":\"9000\"}")
            .unwrap()
            .into_raw(),
        Ok(Some(env)) => {
            let cbor_hex = hex::encode(env.to_cbor().unwrap_or_default());
            let cstr = CString::new(cbor_hex).unwrap();
            vault_nfc_process_chunk(cstr.as_ptr())
        }
        Err(e) => CString::new(format!("{{\"error\":\"{}\",\"sw\":\"6700\"}}", e))
            .unwrap()
            .into_raw(),
    }
}

#[no_mangle]
pub extern "C" fn vault_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

// ============================================================================
// Standard JNI Exports for Android / JVM (`com.mobilecoldwallet.nfc_probe.VaultCoreBridge`)
// ============================================================================
#[cfg(any(test, feature = "test-fixtures"))]
type JniEnv = *const *const *const c_void;
#[cfg(any(test, feature = "test-fixtures"))]
type JObject = *mut c_void;
#[cfg(any(test, feature = "test-fixtures"))]
type JString = *mut c_void;

#[cfg(any(test, feature = "test-fixtures"))]
unsafe fn jstring_to_rust(env: JniEnv, jstr: JString) -> String {
    if env.is_null() || jstr.is_null() {
        return String::new();
    }
    let table = *env;
    let get_utf: extern "system" fn(JniEnv, JString, *mut u8) -> *const c_char =
        std::mem::transmute(*table.add(169));
    let rel_utf: extern "system" fn(JniEnv, JString, *const c_char) =
        std::mem::transmute(*table.add(170));
    let c_ptr = get_utf(env, jstr, std::ptr::null_mut());
    if c_ptr.is_null() {
        return String::new();
    }
    let s = CStr::from_ptr(c_ptr).to_string_lossy().into_owned();
    rel_utf(env, jstr, c_ptr);
    s
}

#[cfg(any(test, feature = "test-fixtures"))]
unsafe fn ptr_to_jstring_and_free(env: JniEnv, ptr: *mut c_char) -> JString {
    if env.is_null() || ptr.is_null() {
        return std::ptr::null_mut();
    }
    let s = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    vault_free_string(ptr);
    let table = *env;
    let new_utf: extern "system" fn(JniEnv, *const c_char) -> JString =
        std::mem::transmute(*table.add(167));
    let cstr = CString::new(s).unwrap_or_else(|_| CString::new("{}").unwrap());
    new_utf(env, cstr.as_ptr())
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeInit(
    _env: JniEnv,
    _class: JObject,
) -> i32 {
    vault_init()
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeLoadTestMnemonic(
    env: JniEnv,
    _class: JObject,
    phrase: JString,
    passphrase: JString,
) -> i32 {
    let p_str = CString::new(jstring_to_rust(env, phrase)).unwrap_or_default();
    let pass_str = CString::new(jstring_to_rust(env, passphrase)).unwrap_or_default();
    vault_load_test_mnemonic(p_str.as_ptr(), pass_str.as_ptr())
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeProcessApduFrame(
    env: JniEnv,
    _class: JObject,
    apdu_hex: JString,
) -> JString {
    let hex_c = CString::new(jstring_to_rust(env, apdu_hex)).unwrap_or_default();
    let ptr = vault_nfc_process_apdu_frame(hex_c.as_ptr());
    ptr_to_jstring_and_free(env, ptr)
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativePrepareLegacyTxWithTransport(
    env: JniEnv,
    _class: JObject,
    session_id: JString,
    request_id: JString,
    raw_rlp_hex: JString,
    declared_chain_id: i64,
    transport_code: i32,
) -> JString {
    let sess_c = CString::new(jstring_to_rust(env, session_id)).unwrap_or_default();
    let req_c = CString::new(jstring_to_rust(env, request_id)).unwrap_or_default();
    let rlp_c = CString::new(jstring_to_rust(env, raw_rlp_hex)).unwrap_or_default();
    let ptr = vault_prepare_legacy_tx_with_transport(
        sess_c.as_ptr(),
        req_c.as_ptr(),
        rlp_c.as_ptr(),
        declared_chain_id as u64,
        transport_code as u32,
    );
    ptr_to_jstring_and_free(env, ptr)
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativePrepareEip1559TxWithTransport(
    env: JniEnv,
    _class: JObject,
    session_id: JString,
    request_id: JString,
    raw_tx_hex: JString,
    declared_chain_id: i64,
    transport_code: i32,
) -> JString {
    let sess_c = CString::new(jstring_to_rust(env, session_id)).unwrap_or_default();
    let req_c = CString::new(jstring_to_rust(env, request_id)).unwrap_or_default();
    let tx_c = CString::new(jstring_to_rust(env, raw_tx_hex)).unwrap_or_default();
    let ptr = vault_prepare_eip1559_tx_with_transport(
        sess_c.as_ptr(),
        req_c.as_ptr(),
        tx_c.as_ptr(),
        declared_chain_id as u64,
        transport_code as u32,
    );
    ptr_to_jstring_and_free(env, ptr)
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeApproveAndSign(
    env: JniEnv,
    _class: JObject,
    handle_id: JString,
) -> JString {
    let h_str = jstring_to_rust(env, handle_id);
    let ptr = if h_str.is_null_or_empty() {
        vault_approve_and_sign(std::ptr::null())
    } else {
        let h_c = CString::new(h_str).unwrap_or_default();
        vault_approve_and_sign(h_c.as_ptr())
    };
    ptr_to_jstring_and_free(env, ptr)
}

#[cfg(any(test, feature = "test-fixtures"))]
trait StrExt {
    fn is_null_or_empty(&self) -> bool;
}
#[cfg(any(test, feature = "test-fixtures"))]
impl StrExt for String {
    fn is_null_or_empty(&self) -> bool {
        self.is_empty()
    }
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeCancel(
    env: JniEnv,
    _class: JObject,
    handle_id: JString,
) -> i32 {
    let h_str = jstring_to_rust(env, handle_id);
    if h_str.is_empty() {
        vault_cancel(std::ptr::null())
    } else {
        let h_c = CString::new(h_str).unwrap_or_default();
        vault_cancel(h_c.as_ptr())
    }
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeCancelJson(
    env: JniEnv,
    _class: JObject,
    handle_id: JString,
) -> JString {
    let h_str = jstring_to_rust(env, handle_id);
    let ptr = if h_str.is_empty() {
        vault_cancel_json(std::ptr::null())
    } else {
        let h_c = CString::new(h_str).unwrap_or_default();
        vault_cancel_json(h_c.as_ptr())
    };
    ptr_to_jstring_and_free(env, ptr)
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeGetRequestState(
    env: JniEnv,
    _class: JObject,
    handle_id: JString,
) -> JString {
    let h_str = jstring_to_rust(env, handle_id);
    let ptr = if h_str.is_empty() {
        vault_get_request_state(std::ptr::null())
    } else {
        let h_c = CString::new(h_str).unwrap_or_default();
        vault_get_request_state(h_c.as_ptr())
    };
    ptr_to_jstring_and_free(env, ptr)
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeChunkPayload(
    env: JniEnv,
    _class: JObject,
    session_id: JString,
    request_id: JString,
    message_kind: i32,
    raw_payload_hex: JString,
    chunk_size: i32,
) -> JString {
    let sess_c = CString::new(jstring_to_rust(env, session_id)).unwrap_or_default();
    let req_c = CString::new(jstring_to_rust(env, request_id)).unwrap_or_default();
    let payload_c = CString::new(jstring_to_rust(env, raw_payload_hex)).unwrap_or_default();
    let ptr = vault_nfc_chunk_payload(
        sess_c.as_ptr(),
        req_c.as_ptr(),
        message_kind as u8,
        payload_c.as_ptr(),
        chunk_size.max(1) as usize,
    );
    ptr_to_jstring_and_free(env, ptr)
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeGetPrimitiveSignCount(
    _env: JniEnv,
    _class: JObject,
) -> i64 {
    vault_get_primitive_sign_count()
}

#[cfg(any(test, feature = "test-fixtures"))]
#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_VaultCoreBridge_nativeResetNfcSessions(
    _env: JniEnv,
    _class: JObject,
) -> i32 {
    vault_nfc_reset_sessions()
}


#[cfg(test)]
mod tests {
    // This test constructs public request metadata only. It never creates,
    // imports, unlocks, derives, or signs with a key.
    #[test]
    fn public_retention_no_keys_releases_cancelled_request_content() {
        let _guard = TEST_LOCK.lock().unwrap();
        vault_init();
        for index in 0..192 {
            let handle = format!("public-retention-{index}");
            let request = public_retention_request(&handle);
            {
                let mut guard = CONTEXT.lock().unwrap();
                let ctx = guard.as_mut().unwrap();
                assert!(ctx.key_vault.is_none());
                ctx.retain_prepared_request(request, Some("public-path".into()), Some(vec![0x55; 1024])).unwrap();
            }
            let handle_c = CString::new(handle.clone()).unwrap();
            if index % 2 == 0 {
                assert_eq!(vault_cancel(handle_c.as_ptr()), 0);
            } else {
                assert_eq!(json_result(vault_cancel_json(handle_c.as_ptr()))["status"], "CANCELLED");
            }
            assert_eq!(vault_cancel(handle_c.as_ptr()), -5);
            assert_eq!(json_result(vault_cancel_json(handle_c.as_ptr()))["error_code"], "ERR_ALREADY_CANCELLED");
            let guard = CONTEXT.lock().unwrap();
            let ctx = guard.as_ref().unwrap();
            assert!(!ctx.requests.contains_key(&handle), "cancel must release public request content");
            assert!(!ctx.request_paths.contains_key(&handle));
            assert!(!ctx.psbts.contains_key(&handle));
            assert!(ctx.requests.len() <= MAX_RETAINED_PREPARED_REQUESTS);
            assert!(ctx.cancelled_receipts.len() <= MAX_CANCELLED_RECEIPTS);
        }
        assert_eq!(CONTEXT.lock().unwrap().as_ref().unwrap().cancelled_receipts.len(), MAX_CANCELLED_RECEIPTS);
        let expired = CString::new("public-retention-0").unwrap();
        assert_eq!(vault_cancel(expired.as_ptr()), -1);
        assert_eq!(json_result(vault_cancel_json(expired.as_ptr()))["error_code"], "ERR_HANDLE_NOT_FOUND");
        let recent = CString::new("public-retention-191").unwrap();
        assert_eq!(json_result(vault_get_request_state(recent.as_ptr()))["state"], "Cancelled");
    }

    fn public_retention_request(handle: &str) -> PreparedRequest {
        PreparedRequest::new(
            "public-session".into(), handle.into(), Transport::Qr,
            SignerBackend::LocalVaultKey, 11_155_111, "public-account".into(),
            [0x42; 32],
            ParsedIntent::NativeTransfer { chain_id: 11_155_111,
                recipient: "public-recipient".into(), value_wei: "0".into(),
                fee_cap_wei: "21000".into() },
            public_core::policy::PolicyVerdict::Approved { chain_id: 11_155_111,
                recipient: "public-recipient".into(), amount_display: "0".into(),
                fee_cap_wei: "21000".into() },
        ).unwrap().with_handle_id(handle.into())
    }

    #[test]
    fn public_retention_no_keys_preserves_protected_outcomes_at_capacity_and_lock() {
        let _guard = TEST_LOCK.lock().unwrap();
        vault_init();
        let before;
        {
            let mut guard = CONTEXT.lock().unwrap();
            let ctx = guard.as_mut().unwrap();
            for index in 0..MAX_RETAINED_PREPARED_REQUESTS {
                let handle = format!("public-protected-{index}");
                let mut request = public_retention_request(&handle);
                // Synthetic state records only; no signing transition or primitive.
                request.state = [RequestState::SignCommandSent, RequestState::SignedVerified,
                    RequestState::SigningOutcomeUnknown, RequestState::ResponseReady,
                    RequestState::Consumed][index % 5];
                request.sign_command_count = 1;
                ctx.retain_prepared_request(request, Some("public-path".into()), Some(vec![0x44; 32])).unwrap();
            }
            ctx.signed_results.insert("public-result-id".into(), "public-result".into());
            before = serde_json::to_value(&ctx.requests).unwrap();
            assert!(ctx.retain_prepared_request(public_retention_request("public-over-capacity"),
                Some("unused-path".into()), Some(vec![0x55; 32])).is_err());
            assert_eq!(ctx.requests.len(), MAX_RETAINED_PREPARED_REQUESTS);
            assert_eq!(ctx.request_paths.len(), MAX_RETAINED_PREPARED_REQUESTS);
            assert_eq!(ctx.psbts.len(), MAX_RETAINED_PREPARED_REQUESTS);
            assert!(!ctx.request_paths.contains_key("public-over-capacity"));
            assert!(!ctx.psbts.contains_key("public-over-capacity"));
            assert_eq!(serde_json::to_value(&ctx.requests).unwrap(), before);
        }
        let signed = CString::new("public-protected-1").unwrap();
        let unknown = CString::new("public-protected-2").unwrap();
        assert_eq!(vault_cancel(signed.as_ptr()), -2);
        assert_eq!(vault_cancel(unknown.as_ptr()), -4);
        assert_eq!(vault_lock(), 0);
        let guard = CONTEXT.lock().unwrap();
        let ctx = guard.as_ref().unwrap();
        assert!(ctx.key_vault.is_none());
        assert_eq!(serde_json::to_value(&ctx.requests).unwrap(), before);
        assert_eq!(ctx.signed_results["public-result-id"], "public-result");
        assert_eq!(ctx.request_paths.len(), MAX_RETAINED_PREPARED_REQUESTS);
        assert_eq!(ctx.psbts.len(), MAX_RETAINED_PREPARED_REQUESTS);
    }

    #[test]
    fn public_retention_no_keys_releases_revoked_disconnected_and_locked_content() {
        let _guard = TEST_LOCK.lock().unwrap();
        vault_init();
        {
            let mut guard = CONTEXT.lock().unwrap();
            let ctx = guard.as_mut().unwrap();
            for handle in ["public-revoked", "public-disconnected"] {
                ctx.retain_prepared_request(public_retention_request(handle), Some("public-path".into()),
                    Some(vec![0x55; 1024])).unwrap();
            }
            assert!(ctx.cancelled_receipt("public-revoked").is_some());
            assert!(!ctx.requests.contains_key("public-revoked"));
            assert!(!ctx.request_paths.contains_key("public-revoked"));
            assert!(!ctx.psbts.contains_key("public-revoked"));
        }
        let disconnected = CString::new("public-disconnected").unwrap();
        assert_eq!(vault_mark_disconnected(disconnected.as_ptr()), 0);
        assert_eq!(vault_cancel(disconnected.as_ptr()), -5);
        {
            let mut guard = CONTEXT.lock().unwrap();
            let ctx = guard.as_mut().unwrap();
            assert!(ctx.requests.is_empty());
            assert!(ctx.request_paths.is_empty());
            assert!(ctx.psbts.is_empty());
            ctx.retain_prepared_request(public_retention_request("public-locked"), Some("public-path".into()),
                Some(vec![0x55; 1024])).unwrap();
        }
        assert_eq!(vault_lock(), 0);
        let guard = CONTEXT.lock().unwrap();
        let ctx = guard.as_ref().unwrap();
        assert!(ctx.requests.is_empty());
        assert!(ctx.request_paths.is_empty());
        assert!(ctx.psbts.is_empty());
        assert!(ctx.cancelled_receipt("public-locked").is_some());
        assert!(ctx.key_vault.is_none());
    }
    use super::*;
    use public_core::rlp::{encode_bytes, encode_list, encode_u64};

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn json_result(ptr: *mut c_char) -> serde_json::Value {
        assert!(!ptr.is_null());
        let value = serde_json::from_str(unsafe { CStr::from_ptr(ptr) }.to_str().unwrap()).unwrap();
        vault_free_string(ptr);
        value
    }

    #[test]
    fn captured_okx_transaction_review_is_complete_and_preserves_exact_fee_cap() {
        let raw = hex::decode("02f183aa36a782016a843b9aca00843b9aca15822ee094f39fd6e51aad88f6f4ce6ab8827279cfffb9226685e8d4a5100080c0").unwrap();
        let tx = Eip1559Transaction::decode(&raw, 11155111).unwrap();
        let transaction = eip1559_transaction_summary(&tx, &raw).unwrap();
        assert_eq!(transaction, serde_json::json!({
            "type": "EIP-1559", "chain_id": "11155111", "nonce": "362",
            "gas_limit": "12000", "max_fee_per_gas_wei": "1000000021",
            "max_priority_fee_per_gas_wei": "1000000000",
            "to": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            "value_wei": "1000000000000", "data_hex": "0x", "access_list": [],
        }));
        let fee_cap = transaction["gas_limit"].as_str().unwrap().parse::<u128>().unwrap()
            * transaction["max_fee_per_gas_wei"].as_str().unwrap().parse::<u128>().unwrap();
        assert_eq!(fee_cap, 12_000_000_252_000);
        assert!(matches!(tx.to_intent(), ParsedIntent::NativeTransfer { fee_cap_wei, .. } if fee_cap_wei == fee_cap.to_string()));
        assert_eq!(tx.signing_preimage_hash(), public_core::evm::keccak256(&raw));
    }

    #[test]
    fn transaction_review_preserves_all_calldata_and_typed_access_list_keys() {
        let recipient = hex::decode("f39fd6e51aad88f6f4ce6ab8827279cfffb92266").unwrap();
        let data = [0x00, 0x01, 0xab, 0xff, 0x00];
        let fields = [
            encode_u64(11155111), encode_u64(362), encode_u64(1_000_000_000),
            encode_u64(1_000_000_021), encode_u64(50_000), encode_bytes(&recipient),
            encode_u64(1_000_000_000_000), encode_bytes(&data),
            encode_list(&[encode_list(&[encode_bytes(&recipient), encode_list(&[encode_bytes(&[0xab; 32])])])]),
        ];
        let mut raw = vec![0x02];
        raw.extend_from_slice(&encode_list(&fields));
        let tx = Eip1559Transaction::decode(&raw, 11155111).unwrap();
        let transaction = eip1559_transaction_summary(&tx, &raw).unwrap();
        assert_eq!(transaction["data_hex"], "0x0001abff00");
        assert_eq!(transaction["access_list"], serde_json::json!([{
            "address": tx.to.as_ref().unwrap(), "storage_keys": [format!("0x{}", "ab".repeat(32))],
        }]));
    }

    #[test]
    fn activation_rejects_blank_and_existing_destinations_without_mutation() {
        let _guard = TEST_LOCK.lock().unwrap();
        vault_init();
        let phrase = CString::new("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap();
        let password = CString::new("Strong-Vault-Password-2026").unwrap();
        let blank = CString::new(" ").unwrap();
        let result = json_result(vault_activate_and_save_mnemonic_json(phrase.as_ptr(), std::ptr::null(), blank.as_ptr(), password.as_ptr()));
        assert_eq!(result["status"], "ERROR");
        assert_eq!(result["error_code"], "ERR_STORAGE_PATH");
        assert!(CONTEXT.lock().unwrap().as_ref().unwrap().key_vault.is_none());
        let path = std::env::temp_dir().join(format!("fcw-preserve-{}.json", std::process::id()));
        std::fs::write(&path, b"existing vault must survive").unwrap();
        let path_c = CString::new(path.to_str().unwrap()).unwrap();
        let result = json_result(vault_activate_and_save_mnemonic_json(phrase.as_ptr(), std::ptr::null(), path_c.as_ptr(), password.as_ptr()));
        assert_eq!(result["status"], "ERROR");
        assert_eq!(std::fs::read(&path).unwrap(), b"existing vault must survive");
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn qr_rejects_unsafe_message_types_networks_and_claimed_sender_before_signing() {
        let _guard = TEST_LOCK.lock().unwrap();
        vault_init();
        let phrase = CString::new("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap();
        vault_load_test_mnemonic(phrase.as_ptr(), std::ptr::null());
        let mut guard = CONTEXT.lock().unwrap();
        let ctx = guard.as_mut().unwrap();
        let path = ur_adapter::crypto_keypath::CryptoKeyPath::from_string_path("m/44'/60'/0'/0/0", None).unwrap();
        let mut request = EthSignRequest { request_id:Some([7;16]), sign_data:vec![1], data_type:DataType::PersonalMessage, chain_id:Some(11155111), derivation_path:path, address:None, origin:None };
        assert!(prepare_from_eth_sign_request(ctx,"session".into(),"request".into(),&request,0,Transport::Qr).unwrap_err().contains("not enabled"));
        request.data_type = DataType::TypedData;
        assert!(prepare_from_eth_sign_request(ctx,"session".into(),"request".into(),&request,0,Transport::Qr).is_err());
        request.chain_id = Some(1);
        assert!(prepare_from_eth_sign_request(ctx,"session".into(),"request".into(),&request,0,Transport::Qr).unwrap_err().contains("local/testnet"));
        request.chain_id = None;
        assert!(prepare_from_eth_sign_request(ctx,"session".into(),"request".into(),&request,0,Transport::Qr).unwrap_err().contains("explicit chain"));
        request.chain_id = Some(11155111);
        request.data_type = DataType::Transaction;
        request.sign_data = hex::decode("ef808504a817c800825208949858effd232b4033e47d90003d41ec34ecaeda9488016345785d8a00008083aa36a78080").unwrap();
        request.address = Some([0x33;20]);
        assert!(prepare_from_eth_sign_request(ctx,"session".into(),"request".into(),&request,0,Transport::Qr).unwrap_err().contains("RequestAddressMismatch"));
        assert_eq!(ctx.key_vault.as_ref().unwrap().primitive_sign_invocations(),0);
        assert!(ctx.active_handle_id.is_none());

        // The OKX-shaped low-gas request does not target this test vault.
        request.address = None;
        request.data_type = DataType::TypedTransaction;
        request.sign_data = hex::decode("02f183aa36a782016a843b9aca00843b9aca15822ee094f39fd6e51aad88f6f4ce6ab8827279cfffb9226685e8d4a5100080c0").unwrap();
        assert!(prepare_from_eth_sign_request(ctx,"session".into(),"low-gas-wrong-sender".into(),&request,0,Transport::Qr).is_err());
        assert_eq!(ctx.key_vault.as_ref().unwrap().primitive_sign_invocations(),0);
        assert!(ctx.active_handle_id.is_none());

        let account = ctx.key_vault.as_ref().unwrap().derive_evm_public_account(0).unwrap();
        let recipient = hex::decode(account.address.trim_start_matches("0x")).unwrap();
        let fields = vec![
            encode_u64(11155111), encode_u64(362), encode_u64(1_000_000_000),
            encode_u64(1_000_000_021), encode_u64(12_000), encode_bytes(&recipient),
            encode_u64(1_000_000_000_000), encode_bytes(&[]), encode_list(&[]),
        ];
        let mut cases = Vec::new();
        for (name, index, replacement, chain_id) in [
            ("wrong-sender", 5, encode_bytes(&[0x33; 20]), 11155111),
            ("data", 7, encode_bytes(&[0x01]), 11155111),
            ("access-list", 8, encode_list(&[encode_list(&[encode_bytes(&recipient), encode_list(&[])])]), 11155111),
            ("malformed-access", 8, encode_list(&[encode_bytes(&[])]), 11155111),
            ("local-chain", 0, encode_u64(31337), 31337),
            ("below-floor", 4, encode_u64(11_999), 11155111),
        ] {
            let mut invalid = fields.clone();
            invalid[index] = replacement;
            let mut raw = vec![0x02];
            raw.extend_from_slice(&encode_list(&invalid));
            cases.push((name, chain_id, raw));
        }
        for (name, access_list) in [
            ("access-list-is-bytes", encode_bytes(&[])),
            ("access-entry-is-bytes", encode_list(&[encode_bytes(&[])])),
            ("access-entry-missing-keys", encode_list(&[encode_list(&[encode_bytes(&recipient)])])),
            ("access-keys-are-bytes", encode_list(&[encode_list(&[encode_bytes(&recipient), encode_bytes(&[])])])),
            ("access-key-is-short", encode_list(&[encode_list(&[encode_bytes(&recipient), encode_list(&[encode_bytes(&[0xab; 31])])])])),
        ] {
            let mut invalid = fields.clone();
            invalid[4] = encode_u64(21_000);
            invalid[8] = access_list;
            let mut raw = vec![0x02];
            raw.extend_from_slice(&encode_list(&invalid));
            cases.push((name, 11155111, raw));
        }
        let mut missing_access_list = vec![0x02];
        missing_access_list.extend_from_slice(&encode_list(&fields[..8]));
        cases.push(("missing-access-list", 11155111, missing_access_list));
        cases.push(("truncated-payload", 11155111, vec![0x02]));
        for data_type in [DataType::Transaction, DataType::TypedTransaction] {
            request.data_type = data_type;
            for (name, chain_id, raw) in &cases {
                request.chain_id = Some(*chain_id);
                request.sign_data = raw.clone();
                assert!(prepare_from_eth_sign_request(ctx,"session".into(),(*name).into(),&request,0,Transport::Qr).is_err(), "{name}");
                assert!(ctx.active_handle_id.is_none(), "{name}");
                assert_eq!(ctx.key_vault.as_ref().unwrap().primitive_sign_invocations(), 0);
            }
        }
        let mut self_raw = vec![0x02];
        self_raw.extend_from_slice(&encode_list(&fields));
        request.chain_id = Some(11155111);
        request.sign_data = self_raw.clone();
        for data_type in [DataType::Transaction, DataType::TypedTransaction] {
            request.data_type = data_type;
            let result: serde_json::Value = serde_json::from_str(&prepare_from_eth_sign_request(ctx,"session".into(),"low-gas-self".into(),&request,0,Transport::Qr).unwrap()).unwrap();
            assert_eq!(result["transaction"], serde_json::json!({
                "type": "EIP-1559", "chain_id": "11155111", "nonce": "362",
                "gas_limit": "12000", "max_fee_per_gas_wei": "1000000021",
                "max_priority_fee_per_gas_wei": "1000000000", "to": account.address,
                "value_wei": "1000000000000", "data_hex": "0x", "access_list": [],
            }));
        }
        drop(guard);

        let session = CString::new("low-gas-direct-session").unwrap();
        let request_id = CString::new("low-gas-direct-request").unwrap();
        for with_transport in [false, true] {
            for (name, chain_id, raw) in &cases {
                let raw_hex = CString::new(hex::encode(raw)).unwrap();
                let result = if with_transport {
                    json_result(vault_prepare_eip1559_tx_with_transport(session.as_ptr(), request_id.as_ptr(), raw_hex.as_ptr(), *chain_id, 1))
                } else {
                    json_result(vault_prepare_eip1559_tx(session.as_ptr(), request_id.as_ptr(), raw_hex.as_ptr(), *chain_id))
                };
                assert!(result.get("error").is_some(), "{name}: {result}");
                assert!(result.get("transaction").is_none(), "{name}: {result}");
                assert_eq!(CONTEXT.lock().unwrap().as_ref().unwrap().key_vault.as_ref().unwrap().primitive_sign_invocations(), 0);
            }
            let raw_hex = CString::new(hex::encode(&self_raw)).unwrap();
            let result = if with_transport {
                json_result(vault_prepare_eip1559_tx_with_transport(session.as_ptr(), request_id.as_ptr(), raw_hex.as_ptr(), 11155111, 1))
            } else {
                json_result(vault_prepare_eip1559_tx(session.as_ptr(), request_id.as_ptr(), raw_hex.as_ptr(), 11155111))
            };
            assert!(result.get("error").is_none(), "{result}");
            assert_eq!(result["signer_address"], account.address);
            assert_eq!(result["transaction"], serde_json::json!({
                "type": "EIP-1559", "chain_id": "11155111", "nonce": "362",
                "gas_limit": "12000", "max_fee_per_gas_wei": "1000000021",
                "max_priority_fee_per_gas_wei": "1000000000", "to": account.address,
                "value_wei": "1000000000000", "data_hex": "0x", "access_list": [],
            }));
        }

        let legacy_fields = [
            encode_u64(362), encode_u64(1_000_000_021), encode_u64(21_000),
            encode_bytes(&recipient), encode_u64(1_000_000_000_000), encode_bytes(&[]),
            encode_u64(11155111), encode_u64(0), encode_u64(0),
        ];
        let legacy_raw = encode_list(&legacy_fields);
        let legacy_expected = serde_json::json!({
            "type": "Legacy EIP-155", "chain_id": "11155111", "nonce": "362",
            "gas_limit": "21000", "gas_price_wei": "1000000021", "to": account.address,
            "value_wei": "1000000000000", "data_hex": "0x", "access_list": [],
        });
        request.data_type = DataType::Transaction;
        request.sign_data = legacy_raw.clone();
        {
            let mut guard = CONTEXT.lock().unwrap();
            let result: serde_json::Value = serde_json::from_str(&prepare_from_eth_sign_request(guard.as_mut().unwrap(),"session".into(),"legacy-full-review".into(),&request,0,Transport::Qr).unwrap()).unwrap();
            assert_eq!(result["transaction"], legacy_expected);
        }
        let legacy_hex = CString::new(hex::encode(legacy_raw)).unwrap();
        for with_transport in [false, true] {
            let result = if with_transport {
                json_result(vault_prepare_legacy_tx_with_transport(session.as_ptr(), request_id.as_ptr(), legacy_hex.as_ptr(), 11155111, 1))
            } else {
                json_result(vault_prepare_legacy_tx(session.as_ptr(), request_id.as_ptr(), legacy_hex.as_ptr(), 11155111))
            };
            assert_eq!(result["transaction"], legacy_expected);
        }
    }

    #[test]
    fn test_vault_ffi_lifecycle_and_cancellation() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert_eq!(vault_init(), 0);

        let phrase = CString::new("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap();
        assert_eq!(vault_load_test_mnemonic(phrase.as_ptr(), std::ptr::null()), 0);

        let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
        let fields = vec![
            encode_u64(0),
            encode_u64(20_000_000_000),
            encode_u64(21000),
            encode_bytes(&to_addr),
            encode_u64(1_000_000_000_000_000),
            encode_bytes(&[]),
            encode_u64(11155111 * 2 + 35),
            encode_u64(0),
            encode_u64(0),
        ];
        let rlp_hex = hex::encode(encode_list(&fields));
        let rlp_c = CString::new(rlp_hex).unwrap();
        let sess_c = CString::new("sess_test_1").unwrap();
        let req_c = CString::new("req_test_1").unwrap();

        let prep_json_ptr = vault_prepare_legacy_tx(sess_c.as_ptr(), req_c.as_ptr(), rlp_c.as_ptr(), 11155111);
        assert!(!prep_json_ptr.is_null());
        let prep_json = unsafe { CStr::from_ptr(prep_json_ptr) }.to_str().unwrap();
        assert!(prep_json.contains("Approved"));
        assert!(prep_json.contains("handle-1-req_test_1"));
        vault_free_string(prep_json_ptr);

        // LIFE-02: Cancel test - cancel before sign, sign_command_count MUST be 0
        assert_eq!(vault_cancel(std::ptr::null()), 0);
        // Repeated cancel returns typed -5 (ERR_ALREADY_CANCELLED) without panic
        assert_eq!(vault_cancel(std::ptr::null()), -5);

        // Prepare second request
        let req_c2 = CString::new("req_test_2").unwrap();
        let prep_json_ptr2 = vault_prepare_legacy_tx(sess_c.as_ptr(), req_c2.as_ptr(), rlp_c.as_ptr(), 11155111);
        assert!(!prep_json_ptr2.is_null());
        vault_free_string(prep_json_ptr2);

        // Sign active handle
        let sign_res_ptr = vault_approve_and_sign(std::ptr::null());
        assert!(!sign_res_ptr.is_null());
        let sign_res = unsafe { CStr::from_ptr(sign_res_ptr) }.to_str().unwrap();
        assert!(sign_res.contains("SUCCESS"));
        assert!(sign_res.contains("0x9858EfFD232B4033E47d90003D41EC34EcaEda94"));
        vault_free_string(sign_res_ptr);

        // Cancel AFTER sign must NOT panic or overwrite Consumed state; returns -3 (ERR_ALREADY_CONSUMED)
        assert_eq!(vault_cancel(std::ptr::null()), -3);
        let cancel_json_ptr = vault_cancel_json(std::ptr::null());
        let cancel_json_str = unsafe { CStr::from_ptr(cancel_json_ptr) }.to_str().unwrap();
        assert!(cancel_json_str.contains("ERR_ALREADY_CONSUMED"), "Got: {cancel_json_str}");
        assert!(cancel_json_str.contains("\"state\":\"Consumed\""), "Got: {cancel_json_str}");
        assert!(cancel_json_str.contains("\"sign_command_count\":1"), "Got: {cancel_json_str}");
        vault_free_string(cancel_json_ptr);

        // LIFE-03: Replay signing on consumed handle must fail
        let replay_res_ptr = vault_approve_and_sign(std::ptr::null());
        assert!(!replay_res_ptr.is_null());
        let replay_res = unsafe { CStr::from_ptr(replay_res_ptr) }.to_str().unwrap();
        assert!(replay_res.contains("already consumed"), "Must reject replay signing: {replay_res}");
        vault_free_string(replay_res_ptr);
        let count_before = CONTEXT.lock().unwrap().as_ref().unwrap().key_vault.as_ref().unwrap().primitive_sign_invocations();
        vault_free_string(vault_prepare_legacy_tx(sess_c.as_ptr(), req_c2.as_ptr(), rlp_c.as_ptr(), 11155111));
        let redisplayed = json_result(vault_approve_and_sign(std::ptr::null()));
        assert_eq!(redisplayed["status"], "SUCCESS");
        assert_eq!(CONTEXT.lock().unwrap().as_ref().unwrap().key_vault.as_ref().unwrap().primitive_sign_invocations(), count_before);
    }

    #[test]
    fn test_vault_cancel_unknown_outcome_and_signed_verified_and_eip1559() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert_eq!(vault_init(), 0);
        let phrase = CString::new("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap();
        assert_eq!(vault_load_test_mnemonic(phrase.as_ptr(), std::ptr::null()), 0);

        // EIP-1559 Type-2 transaction: 0x02 || RLP([chain_id, nonce, max_priority_fee, max_fee, gas_limit, to, value, data, access_list])
        let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
        let eip1559_fields = vec![
            encode_u64(11155111),
            encode_u64(0),
            encode_u64(1_500_000_000),
            encode_u64(30_000_000_000),
            encode_u64(21000),
            encode_bytes(&to_addr),
            encode_u64(1_000_000_000_000_000),
            encode_bytes(&[]),
            encode_list(&[]),
        ];
        let mut raw_1559 = vec![0x02u8];
        raw_1559.extend_from_slice(&encode_list(&eip1559_fields));
        let tx_hex = hex::encode(&raw_1559);
        let tx_c = CString::new(tx_hex).unwrap();
        let sess_c = CString::new("sess_1559").unwrap();
        let req_c = CString::new("req_1559").unwrap();

        let prep_ptr = vault_prepare_eip1559_tx_with_transport(
            sess_c.as_ptr(),
            req_c.as_ptr(),
            tx_c.as_ptr(),
            11155111,
            1, // Transport::NfcIsoDepHce
        );
        assert!(!prep_ptr.is_null());
        let prep_str = unsafe { CStr::from_ptr(prep_ptr) }.to_str().unwrap();
        assert!(prep_str.contains("NfcIsoDepHce"), "Got: {prep_str}");
        vault_free_string(prep_ptr);

        // Force SignCommandSent -> mark_disconnected -> SigningOutcomeUnknown
        {
            let mut g = CONTEXT.lock().unwrap();
            let ctx = g.as_mut().unwrap();
            let h = ctx.active_handle_id.clone().unwrap();
            let req = ctx.requests.get_mut(&h).unwrap();
            req.start_review().unwrap();
            req.approve().unwrap();
            req.mark_sign_command_sent(SignerBackend::LocalVaultKey).unwrap();
            // Cancel while SignCommandSent must return AlreadySigned (-2) and preserve SignCommandSent!
        }
        assert_eq!(vault_cancel(std::ptr::null()), -2);
        // Disconnect while SignCommandSent transitions to SigningOutcomeUnknown
        assert_eq!(vault_mark_disconnected(std::ptr::null()), 0);
        // Cancel while SigningOutcomeUnknown must return -4 (ERR_OUTCOME_UNKNOWN) and preserve state
        assert_eq!(vault_cancel(std::ptr::null()), -4);
        let state_ptr = vault_get_request_state(std::ptr::null());
        let state_str = unsafe { CStr::from_ptr(state_ptr) }.to_str().unwrap();
        assert!(state_str.contains("SigningOutcomeUnknown"), "Got: {state_str}");
        vault_free_string(state_ptr);
    }

    #[test]
    fn test_vault_ffi_nfc_chunking_and_reassembly() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert_eq!(vault_init(), 0);

        let sess_c = CString::new("sess_nfc_1").unwrap();
        let req_c = CString::new("req_nfc_1").unwrap();
        let payload_hex = "deadbeef".repeat(100); // 800 hex chars = 400 bytes
        let payload_c = CString::new(payload_hex.clone()).unwrap();

        // Chunk into 120-byte chunks
        let chunks_json_ptr = vault_nfc_chunk_payload(sess_c.as_ptr(), req_c.as_ptr(), 4, payload_c.as_ptr(), 120);
        assert!(!chunks_json_ptr.is_null());
        let chunks_json = unsafe { CStr::from_ptr(chunks_json_ptr) }.to_str().unwrap();
        let parsed_chunks: serde_json::Value = serde_json::from_str(chunks_json).unwrap();
        let chunk_arr = parsed_chunks.as_array().unwrap();
        assert_eq!(chunk_arr.len(), 4); // 400 bytes / 120 = 4 chunks
        vault_free_string(chunks_json_ptr);

        // Process chunk 0 -> IN_PROGRESS
        let cbor0 = chunk_arr[0]["cbor_hex"].as_str().unwrap();
        let cbor0_c = CString::new(cbor0).unwrap();
        let res0_ptr = vault_nfc_process_chunk(cbor0_c.as_ptr());
        let res0 = unsafe { CStr::from_ptr(res0_ptr) }.to_str().unwrap();
        assert!(res0.contains("IN_PROGRESS"));
        vault_free_string(res0_ptr);

        // Process chunk 1 -> IN_PROGRESS
        let cbor1 = chunk_arr[1]["cbor_hex"].as_str().unwrap();
        let cbor1_c = CString::new(cbor1).unwrap();
        let res1_ptr = vault_nfc_process_chunk(cbor1_c.as_ptr());
        let res1 = unsafe { CStr::from_ptr(res1_ptr) }.to_str().unwrap();
        assert!(res1.contains("IN_PROGRESS"));
        vault_free_string(res1_ptr);

        // Process chunk 2 -> IN_PROGRESS
        let cbor2 = chunk_arr[2]["cbor_hex"].as_str().unwrap();
        let cbor2_c = CString::new(cbor2).unwrap();
        let res2_ptr = vault_nfc_process_chunk(cbor2_c.as_ptr());
        let res2 = unsafe { CStr::from_ptr(res2_ptr) }.to_str().unwrap();
        assert!(res2.contains("IN_PROGRESS"));
        vault_free_string(res2_ptr);

        // Process chunk 3 -> COMPLETE
        let cbor3 = chunk_arr[3]["cbor_hex"].as_str().unwrap();
        let cbor3_c = CString::new(cbor3).unwrap();
        let res3_ptr = vault_nfc_process_chunk(cbor3_c.as_ptr());
        let res3 = unsafe { CStr::from_ptr(res3_ptr) }.to_str().unwrap();
        assert!(res3.contains("COMPLETE"));
        assert!(res3.contains(&payload_hex));
        vault_free_string(res3_ptr);
    }

    #[test]
    fn test_vault_ffi_state_queries_and_disconnection() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert_eq!(vault_init(), 0);

        let phrase = CString::new("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about").unwrap();
        assert_eq!(vault_load_test_mnemonic(phrase.as_ptr(), std::ptr::null()), 0);

        let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
        let fields = vec![
            encode_u64(0),
            encode_u64(20_000_000_000),
            encode_u64(21000),
            encode_bytes(&to_addr),
            encode_u64(1_000_000_000_000_000),
            encode_bytes(&[]),
            encode_u64(11155111 * 2 + 35),
            encode_u64(0),
            encode_u64(0),
        ];
        let rlp_hex = hex::encode(encode_list(&fields));
        let rlp_c = CString::new(rlp_hex).unwrap();
        let sess_c = CString::new("sess_state_1").unwrap();
        let req_c = CString::new("req_state_1").unwrap();

        let prep_json_ptr = vault_prepare_legacy_tx(sess_c.as_ptr(), req_c.as_ptr(), rlp_c.as_ptr(), 11155111);
        vault_free_string(prep_json_ptr);

        // Query state
        let state_ptr = vault_get_request_state(std::ptr::null());
        assert!(!state_ptr.is_null());
        let state_str = unsafe { CStr::from_ptr(state_ptr) }.to_str().unwrap();
        assert!(state_str.contains("Prepared"));
        assert!(state_str.contains("\"sign_command_count\":0"));
        vault_free_string(state_ptr);

        // Disconnect
        assert_eq!(vault_mark_disconnected(std::ptr::null()), 0);
        let state_ptr2 = vault_get_request_state(std::ptr::null());
        let state_str2 = unsafe { CStr::from_ptr(state_ptr2) }.to_str().unwrap();
        assert!(state_str2.contains("Cancelled"));
        vault_free_string(state_ptr2);
    }

    #[test]
    fn test_vault_ffi_onboarding_storage_backup_and_multi_accounts() {
        let _guard = TEST_LOCK.lock().unwrap();
        assert_eq!(vault_init(), 0);

        // 1. Generate 12-word mnemonic
        let gen_ptr = vault_generate_mnemonic_json(12);
        let gen_str = unsafe { CStr::from_ptr(gen_ptr) }.to_str().unwrap();
        let gen_val: serde_json::Value = serde_json::from_str(gen_str).unwrap();
        assert!(gen_val["mnemonic"].as_str().is_some());
        vault_free_string(gen_ptr);

        // 2. Preview standard test mnemonic
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let phrase_c = CString::new(phrase).unwrap();
        let prev_ptr = vault_preview_mnemonic_json(phrase_c.as_ptr(), std::ptr::null());
        let prev_str = unsafe { CStr::from_ptr(prev_ptr) }.to_str().unwrap();
        let prev_val: serde_json::Value = serde_json::from_str(prev_str).unwrap();
        assert_eq!(prev_val["status"], "SUCCESS", "Got: {prev_str}");
        assert_eq!(prev_val["master_fingerprint"], "73c5da0a");
        vault_free_string(prev_ptr);

        // 3. Activate and save to temp file
        let tmp_dir = std::env::temp_dir().join(format!("fcw_vault_ffi_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp_dir);
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let storage_path = tmp_dir.join("vault_envelope.json");
        let storage_c = CString::new(storage_path.to_str().unwrap()).unwrap();
        let pin_c = CString::new("Strong-Local-Password-246810").unwrap();
        let wrong_pin_c = CString::new("Wrong-Strong-Password-000000").unwrap();

        let act_ptr = vault_activate_and_save_mnemonic_json(
            phrase_c.as_ptr(),
            std::ptr::null(),
            storage_c.as_ptr(),
            pin_c.as_ptr(),
        );
        let act_str = unsafe { CStr::from_ptr(act_ptr) }.to_str().unwrap();
        assert!(act_str.contains("\"status\":\"SUCCESS\""), "Got: {act_str}");
        vault_free_string(act_ptr);

        // 4. Lock vault -> export must fail while locked
        assert_eq!(vault_lock(), 0);
        let exp_locked_ptr = vault_export_multi_accounts_json(80);
        let exp_locked_str = unsafe { CStr::from_ptr(exp_locked_ptr) }.to_str().unwrap();
        assert!(exp_locked_str.contains("ERR_VAULT_LOCKED"), "Got: {exp_locked_str}");
        vault_free_string(exp_locked_ptr);

        // 5. Wrong PIN unlock must fail
        let bad_unlock_ptr = vault_unlock_from_storage_json(storage_c.as_ptr(), wrong_pin_c.as_ptr());
        let bad_unlock_str = unsafe { CStr::from_ptr(bad_unlock_ptr) }.to_str().unwrap();
        assert!(bad_unlock_str.contains("ERR_AUTH_FAILED"), "Got: {bad_unlock_str}");
        vault_free_string(bad_unlock_ptr);

        // 6. Correct PIN unlock must succeed
        let ok_unlock_ptr = vault_unlock_from_storage_json(storage_c.as_ptr(), pin_c.as_ptr());
        let ok_unlock_str = unsafe { CStr::from_ptr(ok_unlock_ptr) }.to_str().unwrap();
        assert!(ok_unlock_str.contains("\"status\":\"UNLOCKED\""), "Got: {ok_unlock_str}");
        assert!(ok_unlock_str.contains("73c5da0a"));
        vault_free_string(ok_unlock_ptr);

        // 7. Export multi-accounts UR
        let exp_ptr = vault_export_multi_accounts_json(80);
        let exp_str = unsafe { CStr::from_ptr(exp_ptr) }.to_str().unwrap();
        let exp_val: serde_json::Value = serde_json::from_str(exp_str).unwrap();
        assert_eq!(exp_val["status"], "SUCCESS", "Got: {exp_str}");
        assert_eq!(exp_val["master_fingerprint"], "73c5da0a");
        assert!(exp_val["multi_accounts"]["ur_single"].as_str().unwrap().starts_with("ur:crypto-multi-accounts/"));
        vault_free_string(exp_ptr);

        // 8. Export encrypted backup and restore into second storage path
        let backup_pass_c = CString::new("BackupStrongPass#99").unwrap();
        let bkp_ptr = vault_export_encrypted_backup_json(backup_pass_c.as_ptr());
        let bkp_str = unsafe { CStr::from_ptr(bkp_ptr) }.to_str().unwrap().to_string();
        vault_free_string(bkp_ptr);
        let bkp_val: serde_json::Value = serde_json::from_str(&bkp_str).unwrap();
        let bkp_envelope_str = bkp_val["backup_json"].as_str().unwrap();
        let bkp_envelope_c = CString::new(bkp_envelope_str).unwrap();

        let storage2_path = tmp_dir.join("vault_envelope_restored.json");
        let storage2_c = CString::new(storage2_path.to_str().unwrap()).unwrap();
        vault_lock();
        let preview = json_result(vault_preview_encrypted_backup_json(bkp_envelope_c.as_ptr(), backup_pass_c.as_ptr()));
        assert_eq!(preview["status"], "SUCCESS");
        assert_eq!(preview["master_fingerprint"], "73c5da0a");
        assert!(!storage2_path.exists());
        assert!(CONTEXT.lock().unwrap().as_ref().unwrap().key_vault.is_none());
        let rest_ptr = vault_restore_from_encrypted_backup_json(
            bkp_envelope_c.as_ptr(),
            backup_pass_c.as_ptr(),
            storage2_c.as_ptr(),
            pin_c.as_ptr(),
        );
        let rest_str = unsafe { CStr::from_ptr(rest_ptr) }.to_str().unwrap();
        assert!(rest_str.contains("\"status\":\"RESTORED\""), "Got: {rest_str}");
        assert!(rest_str.contains("73c5da0a"));
        vault_free_string(rest_ptr);

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }
}

