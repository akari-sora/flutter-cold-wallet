#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod bitcoin_api;

use public_core::evm::{Eip1559Transaction, LegacyTransaction};
use public_core::verify::verify_ethereum_signature;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Mutex;

#[derive(Debug, Clone)]
pub struct PendingWalletRequest {
    pub session_id: String,
    pub request_id: String,
    pub chain_id: u64,
    pub expected_address: String,
    pub raw_rlp_hex: String,
    pub expected_digest_hex: String,
    pub tx_type: String,
    pub consumed: bool,
}

pub struct WalletContext {
    pub nfc_sessions: nfc_protocol::SessionManager,
    pub apdu_frame_assembler: nfc_protocol::ApduFrameAssembler,
    pub pending_requests: HashMap<String, PendingWalletRequest>,
    pub clock_ms: u64,
}

impl Default for WalletContext {
    fn default() -> Self {
        Self {
            nfc_sessions: nfc_protocol::SessionManager::default(),
            apdu_frame_assembler: nfc_protocol::ApduFrameAssembler::new(),
            pending_requests: HashMap::new(),
            clock_ms: 1000,
        }
    }
}

static WALLET_CONTEXT: Mutex<Option<WalletContext>> = Mutex::new(None);

fn with_wallet_ctx<F, R>(f: F) -> R
where
    F: FnOnce(&mut WalletContext) -> R,
{
    let mut guard = WALLET_CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        *guard = Some(WalletContext::default());
    }
    let ctx = guard.as_mut().unwrap();
    ctx.clock_ms = ctx.clock_ms.saturating_add(10);
    f(ctx)
}

#[no_mangle]
pub extern "C" fn wallet_init() -> i32 {
    let mut guard = WALLET_CONTEXT.lock().unwrap_or_else(|e| e.into_inner());
    *guard = Some(WalletContext::default());
    0
}

/// Revokes all pending QR requests owned by this UI session.
#[no_mangle]
pub extern "C" fn wallet_cancel_pending_session(session_id: *const c_char) -> i32 {
    if session_id.is_null() { return -1; }
    let session = match unsafe { CStr::from_ptr(session_id) }.to_str() {
        Ok(value) if !value.is_empty() => value,
        _ => return -1,
    };
    with_wallet_ctx(|ctx| cancel_pending_session(ctx, session))
}

fn cancel_pending_session(ctx: &mut WalletContext, session: &str) -> i32 {
    ctx.pending_requests.retain(|_, pending| pending.session_id != session);
    0
}

#[no_mangle]
pub extern "C" fn wallet_nfc_reset_sessions() -> i32 {
    with_wallet_ctx(|ctx| {
        ctx.nfc_sessions.clear_all();
        ctx.apdu_frame_assembler.reset();
        0
    })
}

/// Verifies that an Ethereum signature recovered address matches the watch-only account address.
/// Returns 1 on match, 0 on mismatch, -1 on error.
#[no_mangle]
pub extern "C" fn wallet_verify_signature(
    digest_hex: *const c_char,
    sig_r_hex: *const c_char,
    sig_s_hex: *const c_char,
    sig_v: u8,
    expected_address: *const c_char,
) -> i32 {
    if digest_hex.is_null()
        || sig_r_hex.is_null()
        || sig_s_hex.is_null()
        || expected_address.is_null()
    {
        return -1;
    }

    let digest_str = unsafe { CStr::from_ptr(digest_hex) }.to_string_lossy();
    let r_str = unsafe { CStr::from_ptr(sig_r_hex) }.to_string_lossy();
    let s_str = unsafe { CStr::from_ptr(sig_s_hex) }.to_string_lossy();
    let exp_addr = unsafe { CStr::from_ptr(expected_address) }.to_string_lossy();

    let digest_bytes = match hex::decode(digest_str.trim_start_matches("0x")) {
        Ok(b) if b.len() == 32 => {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&b);
            arr
        }
        _ => return -1,
    };

    let r_bytes = match hex::decode(r_str.trim_start_matches("0x")) {
        Ok(b) if b.len() == 32 => {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&b);
            arr
        }
        _ => return -1,
    };

    let s_bytes = match hex::decode(s_str.trim_start_matches("0x")) {
        Ok(b) if b.len() == 32 => {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&b);
            arr
        }
        _ => return -1,
    };

    match verify_ethereum_signature(&digest_bytes, &r_bytes, &s_bytes, sig_v, &exp_addr) {
        Ok(_) => 1,
        Err(_) => 0,
    }
}

/// Decodes and evaluates raw RLP transaction intent (watch-only verification).
/// Returns JSON-formatted intent string or null on decode error.
#[no_mangle]
pub extern "C" fn wallet_decode_intent_json(
    raw_rlp_hex: *const c_char,
    declared_chain_id: u64,
) -> *mut c_char {
    if raw_rlp_hex.is_null() {
        return std::ptr::null_mut();
    }
    let rlp_str = unsafe { CStr::from_ptr(raw_rlp_hex) }.to_string_lossy();
    let raw_bytes = match hex::decode(rlp_str.trim_start_matches("0x")) {
        Ok(b) => b,
        Err(_) => return std::ptr::null_mut(),
    };

    let (intent, transaction) = if raw_bytes.first() == Some(&0x02) {
        match Eip1559Transaction::decode(&raw_bytes, declared_chain_id) {
            Ok(t) => (t.to_intent(), serde_json::json!({
                "type": "EIP-1559", "chain_id": t.chain_id.to_string(),
                "nonce": t.nonce.to_string(), "gas_limit": t.gas_limit.to_string(),
                "max_fee_per_gas_wei": t.max_fee_per_gas.to_string(),
                "max_priority_fee_per_gas_wei": t.max_priority_fee_per_gas.to_string(),
                "to": t.to, "value_wei": t.value_wei, "data_hex": format!("0x{}", hex::encode(t.data)),
            })),
            Err(_) => return std::ptr::null_mut(),
        }
    } else {
        match LegacyTransaction::decode(&raw_bytes, declared_chain_id) {
            Ok(t) => (t.to_intent(), serde_json::json!({
                "type": "Legacy EIP-155", "chain_id": t.chain_id.to_string(),
                "nonce": t.nonce.to_string(), "gas_limit": t.gas_limit.to_string(),
                "gas_price_wei": t.gas_price.to_string(),
                "to": t.to, "value_wei": t.value_wei, "data_hex": format!("0x{}", hex::encode(t.data)),
            })),
            Err(_) => return std::ptr::null_mut(),
        }
    };
    let json_str = serde_json::json!({"intent": intent, "transaction": transaction}).to_string();

    CString::new(json_str).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// Computes the exact 32-byte signing preimage hash (digest) for a legacy or EIP-1559 transaction.
/// Returns hex string of 32 bytes (64 chars) or null on error.
#[no_mangle]
pub extern "C" fn wallet_compute_legacy_signing_digest(
    raw_rlp_hex: *const c_char,
    declared_chain_id: u64,
) -> *mut c_char {
    if raw_rlp_hex.is_null() {
        return std::ptr::null_mut();
    }
    let rlp_str = unsafe { CStr::from_ptr(raw_rlp_hex) }.to_string_lossy();
    let raw_bytes = match hex::decode(rlp_str.trim_start_matches("0x")) {
        Ok(b) => b,
        Err(_) => return std::ptr::null_mut(),
    };

    let digest = if raw_bytes.first() == Some(&0x02) {
        match Eip1559Transaction::decode_unsigned(&raw_bytes, declared_chain_id) {
            Ok(t) => t.signing_preimage_hash(),
            Err(_) => return std::ptr::null_mut(),
        }
    } else {
        match LegacyTransaction::decode_unsigned(&raw_bytes, declared_chain_id) {
            Ok(t) => t.signing_preimage_hash(),
            Err(_) => return std::ptr::null_mut(),
        }
    };

    CString::new(hex::encode(digest)).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// Registers a pending watch-only transaction in the Wallet context, binding
/// `(session_id, request_id, chain_id, expected_address, raw_rlp_hex, expected_digest_hex)`.
pub fn wallet_register_pending_tx_internal(
    session_id: &str,
    request_id: &str,
    raw_rlp_hex: &str,
    declared_chain_id: u64,
    expected_address: &str,
) -> String {
    if session_id.is_empty() || request_id.is_empty() || expected_address.is_empty() {
        return "{\"error\":\"session_id, request_id, and expected_address must be non-empty\"}".into();
    }
    let raw_bytes = match hex::decode(raw_rlp_hex.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => return format!("{{\"error\":\"Invalid RLP hex: {}\"}}", e),
    };
    let (digest_hex, intent, tx_type) = if raw_bytes.first() == Some(&0x02) {
        let tx = match Eip1559Transaction::decode_unsigned(&raw_bytes, declared_chain_id) {
            Ok(t) => t,
            Err(e) => return format!("{{\"error\":\"EIP-1559 decode failed: {}\"}}", e),
        };
        if let Err(e) = tx.validate_gas_for_signer(expected_address) {
            return serde_json::json!({"error": e.to_string()}).to_string();
        }
        (
            hex::encode(tx.signing_preimage_hash()),
            tx.to_intent(),
            "EIP1559".to_string(),
        )
    } else {
        let tx = match LegacyTransaction::decode_unsigned(&raw_bytes, declared_chain_id) {
            Ok(t) => t,
            Err(e) => return format!("{{\"error\":\"Transaction decode failed: {}\"}}", e),
        };
        (
            hex::encode(tx.signing_preimage_hash()),
            tx.to_intent(),
            "LEGACY_EIP155".to_string(),
        )
    };

    with_wallet_ctx(|ctx| {
        ctx.pending_requests.insert(
            request_id.to_string(),
            PendingWalletRequest {
                session_id: session_id.to_string(),
                request_id: request_id.to_string(),
                chain_id: declared_chain_id,
                expected_address: expected_address.to_string(),
                raw_rlp_hex: hex::encode(&raw_bytes),
                expected_digest_hex: digest_hex.clone(),
                tx_type: tx_type.clone(),
                consumed: false,
            },
        );
    });

    serde_json::json!({
        "status": "PENDING_REGISTERED",
        "session_id": session_id,
        "request_id": request_id,
        "chain_id": declared_chain_id,
        "expected_address": expected_address,
        "expected_digest": digest_hex,
        "tx_type": tx_type,
        "intent": intent,
    })
    .to_string()
}

#[no_mangle]
pub extern "C" fn wallet_register_pending_tx(
    session_id: *const c_char,
    request_id: *const c_char,
    raw_rlp_hex: *const c_char,
    declared_chain_id: u64,
    expected_address: *const c_char,
) -> *mut c_char {
    if session_id.is_null()
        || request_id.is_null()
        || raw_rlp_hex.is_null()
        || expected_address.is_null()
    {
        return std::ptr::null_mut();
    }
    let sess = unsafe { CStr::from_ptr(session_id) }.to_string_lossy();
    let req = unsafe { CStr::from_ptr(request_id) }.to_string_lossy();
    let rlp = unsafe { CStr::from_ptr(raw_rlp_hex) }.to_string_lossy();
    let addr = unsafe { CStr::from_ptr(expected_address) }.to_string_lossy();
    let out = wallet_register_pending_tx_internal(&sess, &req, &rlp, declared_chain_id, &addr);
    CString::new(out).unwrap().into_raw()
}

/// Watch-only Wallet verification of a reassembled NFC SignResponse payload against the
/// locally registered `PendingWalletRequest` (checking session_id, request_id, chain_id,
/// expected_address, independently computed expected_digest, and secp256k1 ecrecover).
pub fn wallet_verify_nfc_response_internal(
    session_id: &str,
    request_id: &str,
    response_payload_hex: &str,
) -> String {
    let resp_bytes = match hex::decode(response_payload_hex.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => return format!("{{\"verified\":false,\"error\":\"Invalid response hex: {}\"}}", e),
    };
    let resp_json: serde_json::Value = match serde_json::from_slice(&resp_bytes) {
        Ok(v) => v,
        Err(e) => return format!("{{\"verified\":false,\"error\":\"Invalid response JSON: {}\"}}", e),
    };

    with_wallet_ctx(|ctx| {
        let pending = match ctx.pending_requests.get_mut(request_id) {
            Some(p) => p,
            None => {
                return format!(
                    "{{\"verified\":false,\"error\":\"Unknown request_id: {}\"}}",
                    request_id
                )
            }
        };
        if pending.consumed {
            return format!(
                "{{\"verified\":false,\"error\":\"Pending request {} already consumed\"}}",
                request_id
            );
        }
        if pending.session_id != session_id {
            return format!(
                "{{\"verified\":false,\"error\":\"Session ID mismatch: expected {}, got {}\"}}",
                pending.session_id, session_id
            );
        }

        let resp_req_id = resp_json.get("request_id").and_then(|v| v.as_str()).unwrap_or("");
        if resp_req_id != pending.request_id {
            return format!(
                "{{\"verified\":false,\"error\":\"Response request_id mismatch: expected {}, got {}\"}}",
                pending.request_id, resp_req_id
            );
        }

        if let Some(resp_cid) = resp_json.get("chain_id").and_then(|v| v.as_u64()) {
            if resp_cid != pending.chain_id {
                return format!(
                    "{{\"verified\":false,\"error\":\"Response chain_id mismatch: expected {}, got {}\"}}",
                    pending.chain_id, resp_cid
                );
            }
        }

        let resp_digest = resp_json.get("digest").and_then(|v| v.as_str()).unwrap_or("");
        if !resp_digest.eq_ignore_ascii_case(&pending.expected_digest_hex) {
            return format!(
                "{{\"verified\":false,\"error\":\"Digest mismatch against local pending tx: expected {}, got {}\"}}",
                pending.expected_digest_hex, resp_digest
            );
        }

        let resp_signer = resp_json.get("signer_address").and_then(|v| v.as_str()).unwrap_or("");
        if !resp_signer.is_empty() && !resp_signer.eq_ignore_ascii_case(&pending.expected_address) {
            return format!(
                "{{\"verified\":false,\"error\":\"Signer address mismatch: expected {}, got {}\"}}",
                pending.expected_address, resp_signer
            );
        }

        let r_str = resp_json.get("r").and_then(|v| v.as_str()).unwrap_or("");
        let s_str = resp_json.get("s").and_then(|v| v.as_str()).unwrap_or("");
        let v_u8 = resp_json.get("v").and_then(|v| v.as_u64()).unwrap_or(0) as u8;

        let digest_bytes = match hex::decode(&pending.expected_digest_hex) {
            Ok(b) if b.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&b);
                arr
            }
            _ => return "{\"verified\":false,\"error\":\"Invalid local expected digest\"}".into(),
        };
        let r_bytes = match hex::decode(r_str.trim_start_matches("0x")) {
            Ok(b) if b.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&b);
                arr
            }
            _ => return "{\"verified\":false,\"error\":\"Invalid signature r component\"}".into(),
        };
        let s_bytes = match hex::decode(s_str.trim_start_matches("0x")) {
            Ok(b) if b.len() == 32 => {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(&b);
                arr
            }
            _ => return "{\"verified\":false,\"error\":\"Invalid signature s component\"}".into(),
        };

        match verify_ethereum_signature(&digest_bytes, &r_bytes, &s_bytes, v_u8, &pending.expected_address) {
            Ok(recovered) => {
                pending.consumed = true;
                serde_json::json!({
                    "verified": true,
                    "status": "VERIFIED",
                    "session_id": pending.session_id,
                    "request_id": pending.request_id,
                    "chain_id": pending.chain_id,
                    "expected_digest": pending.expected_digest_hex,
                    "recovered_address": recovered,
                })
                .to_string()
            }
            Err(e) => format!(
                "{{\"verified\":false,\"error\":\"Cryptographic signature verification failed: {}\"}}",
                e
            ),
        }
    })
}

#[no_mangle]
pub extern "C" fn wallet_verify_nfc_response_json(
    session_id: *const c_char,
    request_id: *const c_char,
    response_payload_hex: *const c_char,
) -> *mut c_char {
    if session_id.is_null() || request_id.is_null() || response_payload_hex.is_null() {
        return std::ptr::null_mut();
    }
    let sess = unsafe { CStr::from_ptr(session_id) }.to_string_lossy();
    let req = unsafe { CStr::from_ptr(request_id) }.to_string_lossy();
    let resp = unsafe { CStr::from_ptr(response_payload_hex) }.to_string_lossy();
    let out = wallet_verify_nfc_response_internal(&sess, &req, &resp);
    CString::new(out).unwrap().into_raw()
}

pub fn wallet_reset_transport_assembler_internal(session_id: &str) -> i32 {
    with_wallet_ctx(|ctx| {
        ctx.apdu_frame_assembler.reset();
        if !session_id.is_empty() {
            ctx.nfc_sessions.assemblers.remove(session_id);
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn wallet_reset_transport_assembler(session_id: *const c_char) -> i32 {
    let sess = if session_id.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(session_id) }.to_string_lossy().into_owned()
    };
    wallet_reset_transport_assembler_internal(&sess)
}

pub fn wallet_chunk_payload_internal(
    sess_str: &str,
    req_str: &str,
    message_kind_u8: u8,
    payload_str: &str,
    chunk_size: usize,
) -> String {
    let raw_bytes = match hex::decode(payload_str.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => return format!("{{\"error\":\"Invalid hex payload: {}\"}}", e),
    };
    if raw_bytes.is_empty() {
        return "{\"error\":\"Empty NFC payload is forbidden\"}".into();
    }
    if raw_bytes.len() > nfc_protocol::MAX_NFC_PAYLOAD_SIZE {
        return "{\"error\":\"Payload exceeds 128 KiB NFC boundary limit\"}".into();
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
        let slice = raw_bytes[start..end].to_vec();
        let env = nfc_protocol::NfcEnvelope {
            wire_version: nfc_protocol::PROTOCOL_WIRE_VERSION,
            message_kind: msg_kind,
            session_id: sess_str.to_string(),
            request_id: req_str.to_string(),
            chunk_index: i,
            total_chunks,
            payload_digest: digest.clone(),
            payload: slice.clone(),
        };
        let cbor_bytes = match env.to_cbor() {
            Ok(b) => b,
            Err(e) => return format!("{{\"error\":\"Envelope serialization error: {}\"}}", e),
        };
        if cbor_bytes.len() > nfc_protocol::MAX_ENVELOPE_CBOR_LEN {
            return format!(
                "{{\"error\":\"Serialized CBOR envelope length {} exceeds limit {}\"}}",
                cbor_bytes.len(),
                nfc_protocol::MAX_ENVELOPE_CBOR_LEN
            );
        }
        let apdu_frames = match nfc_protocol::encode_cbor_to_apdu_frames(
            &cbor_bytes,
            nfc_protocol::INS_NFC_ENVELOPE_FRAME,
            nfc_protocol::MAX_HCE_APDU_DATA_LEN,
            nfc_protocol::MIN_ISODEP_MAX_TRANSCEIVE_LEN,
        ) {
            Ok(f) => f,
            Err(e) => return format!("{{\"error\":\"APDU framing error: {}\"}}", e),
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
    serde_json::to_string(&chunk_records).unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn wallet_nfc_chunk_payload(
    session_id: *const c_char,
    request_id: *const c_char,
    message_kind_u8: u8,
    raw_payload_hex: *const c_char,
    chunk_size: usize,
) -> *mut c_char {
    if session_id.is_null() || request_id.is_null() || raw_payload_hex.is_null() {
        return std::ptr::null_mut();
    }
    let sess = unsafe { CStr::from_ptr(session_id) }.to_string_lossy();
    let req = unsafe { CStr::from_ptr(request_id) }.to_string_lossy();
    let payload = unsafe { CStr::from_ptr(raw_payload_hex) }.to_string_lossy();
    let out = wallet_chunk_payload_internal(&sess, &req, message_kind_u8, &payload, chunk_size);
    CString::new(out).unwrap().into_raw()
}

pub fn wallet_process_chunk_internal(cbor_hex: &str) -> String {
    let bytes = match hex::decode(cbor_hex.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => return format!("{{\"error\":\"Invalid hex: {}\"}}", e),
    };
    let env = match nfc_protocol::NfcEnvelope::from_cbor(&bytes) {
        Ok(e) => e,
        Err(err) => return format!("{{\"error\":\"Envelope decode error: {}\"}}", err),
    };
    with_wallet_ctx(|ctx| {
        let now_ms = ctx.clock_ms;
        match ctx.nfc_sessions.process_envelope(&env, now_ms) {
            Ok(None) => {
                let asm = ctx.nfc_sessions.assemblers.get(&env.session_id).unwrap();
                serde_json::json!({
                    "status": "IN_PROGRESS",
                    "session_id": asm.session_id,
                    "request_id": asm.request_id,
                    "total_chunks": asm.total_chunks,
                })
                .to_string()
            }
            Ok(Some((verified_sess_id, verified_req_id, verified_kind, full_payload))) => {
                let digest = nfc_protocol::sha256_hex(&full_payload);
                serde_json::json!({
                    "status": "COMPLETE",
                    "session_id": verified_sess_id,
                    "request_id": verified_req_id,
                    "message_kind": verified_kind as u8,
                    "payload_hex": hex::encode(&full_payload),
                    "payload_len": full_payload.len(),
                    "payload_digest": digest,
                })
                .to_string()
            }
            Err(e) => format!("{{\"error\":\"NFC fragment error: {}\"}}", e),
        }
    })
}

#[no_mangle]
pub extern "C" fn wallet_nfc_process_chunk(apdu_cbor_hex: *const c_char) -> *mut c_char {
    if apdu_cbor_hex.is_null() {
        return std::ptr::null_mut();
    }
    let hex_str = unsafe { CStr::from_ptr(apdu_cbor_hex) }.to_string_lossy();
    let out = wallet_process_chunk_internal(&hex_str);
    CString::new(out).unwrap().into_raw()
}

pub fn wallet_process_apdu_frame_internal(apdu_hex: &str) -> String {
    let capdu = match hex::decode(apdu_hex.trim().trim_start_matches("0x")) {
        Ok(b) => b,
        Err(e) => return format!("{{\"error\":\"Invalid APDU hex: {}\",\"sw\":\"6f00\"}}", e),
    };
    let maybe_env = with_wallet_ctx(|ctx| ctx.apdu_frame_assembler.accept_apdu(&capdu));
    match maybe_env {
        Ok(None) => "{\"status\":\"FRAME_ACK\",\"sw\":\"9000\"}".into(),
        Ok(Some(env)) => {
            let cbor_hex = hex::encode(env.to_cbor().unwrap_or_default());
            wallet_process_chunk_internal(&cbor_hex)
        }
        Err(e) => format!("{{\"error\":\"{}\",\"sw\":\"6700\"}}", e),
    }
}

#[no_mangle]
pub extern "C" fn wallet_nfc_process_apdu_frame(apdu_hex: *const c_char) -> *mut c_char {
    if apdu_hex.is_null() {
        return std::ptr::null_mut();
    }
    let hex_str = unsafe { CStr::from_ptr(apdu_hex) }.to_string_lossy();
    let out = wallet_process_apdu_frame_internal(&hex_str);
    CString::new(out).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn wallet_finalize_and_extract_psbt(
    psbt_raw_or_ur: *const c_char,
) -> *mut c_char {
    if psbt_raw_or_ur.is_null() {
        return std::ptr::null_mut();
    }
    let input_str = unsafe { CStr::from_ptr(psbt_raw_or_ur) }.to_string_lossy();
    let clean = input_str.trim();

    let psbt_bytes = if clean.to_lowercase().starts_with("ur:crypto-psbt/")
        || clean.starts_with('[')
    {
        match ur_adapter::DecodedUrPayload::decode(clean) {
            Ok(ur_adapter::DecodedUrPayload::CryptoPsbt(cp)) => cp.psbt_data,
            _ => {
                return CString::new("{\"error\":\"Failed to decode crypto-psbt UR\"}")
                    .unwrap()
                    .into_raw();
            }
        }
    } else if let Ok(b) = hex::decode(clean.trim_start_matches("0x")) {
        b
    } else {
        return CString::new("{\"error\":\"Invalid PSBT encoding (neither UR nor hex)\"}")
            .unwrap()
            .into_raw();
    };

    let psbt = match public_core::bitcoin::Psbt::deserialize(&psbt_bytes) {
        Ok(p) => p,
        Err(e) => {
            return CString::new(format!("{{\"error\":\"PSBT deserialization error: {}\"}}", e))
                .unwrap()
                .into_raw();
        }
    };

    match public_core::bitcoin::finalize_and_extract_p2wpkh_psbt(&psbt) {
        Ok(tx_bytes) => {
            let tx_hex = hex::encode(&tx_bytes);
            let txid_bytes =
                public_core::bitcoin::double_sha256(&psbt.unsigned_tx.serialize_legacy());
            let mut rev = txid_bytes;
            rev.reverse();
            let txid_hex = hex::encode(rev);

            let out_json = format!(
                "{{\"status\":\"SUCCESS\",\"tx_hex\":\"{}\",\"txid\":\"{}\",\"size_bytes\":{}}}",
                tx_hex,
                txid_hex,
                tx_bytes.len()
            );
            CString::new(out_json).unwrap().into_raw()
        }
        Err(e) => CString::new(format!("{{\"error\":\"Finalization failed: {}\"}}", e))
            .unwrap()
            .into_raw(),
    }
}

fn pubkey_bytes_to_evm_address(compressed_33: &[u8]) -> Result<String, String> {
    let pk = secp256k1::PublicKey::from_slice(compressed_33)
        .map_err(|e| format!("Invalid secp256k1 compressed pubkey: {e}"))?;
    let uncompressed = pk.serialize_uncompressed();
    let hash = public_core::evm::keccak256(&uncompressed[1..65]);
    Ok(public_core::verify::to_checksum_address(&hash[12..32]))
}

fn derive_child_pubkey_0_0(compressed_33: &[u8], chain_code_32: &[u8]) -> Result<[u8; 33], String> {
    if compressed_33.len() != 33 || chain_code_32.len() != 32 {
        return Err("Invalid pubkey or chain_code length for BIP-32 child derivation".into());
    }
    let verifying_key = bip32::secp256k1::ecdsa::VerifyingKey::from_sec1_bytes(compressed_33)
        .map_err(|e| format!("Invalid SEC1 public key: {e}"))?;
    let mut cc = [0u8; 32];
    cc.copy_from_slice(chain_code_32);
    let attrs = bip32::ExtendedKeyAttrs {
        depth: 3,
        parent_fingerprint: [0u8; 4],
        child_number: bip32::ChildNumber::new(0, true).unwrap(),
        chain_code: cc,
    };
    let xpub = bip32::XPub::new(verifying_key, attrs);
    let c0 = xpub
        .derive_child(bip32::ChildNumber::new(0, false).unwrap())
        .map_err(|e| format!("Child /0 derivation failed: {e}"))?;
    let c00 = c0
        .derive_child(bip32::ChildNumber::new(0, false).unwrap())
        .map_err(|e| format!("Child /0/0 derivation failed: {e}"))?;
    Ok(c00.to_bytes())
}

#[no_mangle]
pub extern "C" fn wallet_verify_pubkey_address(
    compressed_pubkey_hex: *const c_char,
    expected_address: *const c_char,
) -> i32 {
    if compressed_pubkey_hex.is_null() || expected_address.is_null() {
        return -1;
    }
    let pk_str = unsafe { CStr::from_ptr(compressed_pubkey_hex) }.to_string_lossy();
    let addr_str = unsafe { CStr::from_ptr(expected_address) }.to_string_lossy();
    let pk_bytes = match hex::decode(pk_str.trim().trim_start_matches("0x")) {
        Ok(b) if b.len() == 33 => b,
        _ => return -1,
    };
    match pubkey_bytes_to_evm_address(&pk_bytes) {
        Ok(derived) => {
            if derived.eq_ignore_ascii_case(addr_str.trim()) {
                1
            } else {
                0
            }
        }
        Err(_) => -1,
    }
}

#[no_mangle]
pub extern "C" fn wallet_decode_and_verify_multi_accounts_ur(
    ur_or_frames: *const c_char,
    default_chain_id: u64,
) -> *mut c_char {
    if ur_or_frames.is_null() {
        return std::ptr::null_mut();
    }
    let input_str = unsafe { CStr::from_ptr(ur_or_frames) }.to_string_lossy();
    let clean = input_str.trim();

    let multi = if clean.to_lowercase().starts_with("ur:") || clean.starts_with('[') {
        match ur_adapter::DecodedUrPayload::decode(clean) {
            Ok(ur_adapter::DecodedUrPayload::MultiAccounts(m)) => m,
            Ok(_) => {
                return CString::new("{\"status\":\"ERROR\",\"error_code\":\"ERR_TYPE_MISMATCH\",\"error\":\"UR payload is not crypto-multi-accounts\"}")
                    .unwrap()
                    .into_raw();
            }
            Err(e) => {
                let out = serde_json::json!({
                    "status": "ERROR",
                    "error_code": "ERR_UR_DECODE",
                    "error": e.to_string(),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        }
    } else if let Ok(cbor_bytes) = hex::decode(clean.trim_start_matches("0x")) {
        match ur_adapter::CryptoMultiAccounts::from_cbor_bytes(&cbor_bytes) {
            Ok(m) => m,
            Err(e) => {
                let out = serde_json::json!({
                    "status": "ERROR",
                    "error_code": "ERR_CBOR_DECODE",
                    "error": e.to_string(),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        }
    } else {
        return CString::new("{\"status\":\"ERROR\",\"error_code\":\"ERR_INVALID_INPUT\",\"error\":\"Input is neither UR string, frame array JSON, nor CBOR hex\"}")
            .unwrap()
            .into_raw();
    };

    if multi.master_fingerprint == 0 {
        return CString::new("{\"status\":\"ERROR\",\"error_code\":\"ERR_ZERO_FINGERPRINT\",\"error\":\"Master fingerprint cannot be zero\"}")
            .unwrap()
            .into_raw();
    }
    if multi.keys.is_empty() {
        return CString::new("{\"status\":\"ERROR\",\"error_code\":\"ERR_EMPTY_KEYS\",\"error\":\"crypto-multi-accounts contains no keys\"}")
            .unwrap()
            .into_raw();
    }

    let fp_hex = hex::encode(multi.master_fingerprint.to_be_bytes());
    let active_chain = if default_chain_id == 0 {
        11155111
    } else {
        default_chain_id
    };

    let mut evm_accounts = Vec::new();
    let mut btc_accounts = Vec::new();
    let mut unsupported_accounts = Vec::new();

    for (idx, k) in multi.keys.iter().enumerate() {
        if k.origin.to_string_path().starts_with("m/84'/") {
            match bitcoin_api::btc_account_from_hdkey(k, multi.master_fingerprint.to_be_bytes()) {
                Ok(mut account) => {
                    account["label"] = serde_json::json!("Vault Bitcoin Regtest");
                    if !btc_accounts.iter().any(|existing: &serde_json::Value| existing["account_xpub"] == account["account_xpub"]) { btc_accounts.push(account); }
                }
                Err(error) => unsupported_accounts.push(serde_json::json!({"chain_family":"BTC", "derivation_path":k.origin.to_string_path(), "error":error})),
            }
            continue;
        }
        if k.key_data.len() != 33 {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_INVALID_PUBKEY",
                "error": format!("Key {} has invalid length {} (expected 33 bytes)", idx, k.key_data.len()),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        if let Some(src_fp) = k.origin.source_fingerprint {
            if src_fp != [0, 0, 0, 0] && u32::from_be_bytes(src_fp) != multi.master_fingerprint {
                let out = serde_json::json!({
                    "status": "ERROR",
                    "error_code": "ERR_FINGERPRINT_MISMATCH",
                    "error": format!(
                        "Key {} origin fingerprint {} does not match master_fingerprint {}",
                        idx,
                        hex::encode(src_fp),
                        fp_hex
                    ),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        }

        let path_str = k.origin.to_string_path();
        if path_str.starts_with("m/44'/60'/") {
            let is_account_profile = k.origin.components.len() == 3
                && (k.note.as_deref() == Some("account.xpub")
                    || (k.note.as_deref() == Some("account.standard")
                        && path_str == "m/44'/60'/0'"));
            let (leaf_pubkey, leaf_path) = if is_account_profile {
                let chain_code = match k.chain_code.as_deref() {
                    Some(chain_code) if chain_code.len() == 32 => chain_code,
                    _ => {
                        return CString::new(serde_json::json!({
                            "status": "ERROR",
                            "error_code": "ERR_ACCOUNT_CHAIN_CODE",
                            "error": "Account public profile requires a 32-byte chain code",
                        }).to_string()).unwrap().into_raw();
                    }
                };
                let child_pk = match derive_child_pubkey_0_0(&k.key_data, chain_code) {
                    Ok(pk) => pk.to_vec(),
                    Err(e) => {
                        let out = serde_json::json!({
                            "status": "ERROR",
                            "error_code": "ERR_CHILD_DERIVATION",
                            "error": e,
                        });
                        return CString::new(out.to_string()).unwrap().into_raw();
                    }
                };
                (child_pk, format!("{path_str}/0/0"))
            } else {
                (k.key_data.clone(), path_str.clone())
            };

            let address = match pubkey_bytes_to_evm_address(&leaf_pubkey) {
                Ok(a) => a,
                Err(e) => {
                    let out = serde_json::json!({
                        "status": "ERROR",
                        "error_code": "ERR_INVALID_PUBKEY",
                        "error": e,
                    });
                    return CString::new(out.to_string()).unwrap().into_raw();
                }
            };

            let already_present = evm_accounts.iter().any(|existing: &serde_json::Value| {
                existing.get("address").and_then(|v| v.as_str()) == Some(address.as_str())
                    && existing.get("derivation_path").and_then(|v| v.as_str()) == Some(leaf_path.as_str())
            });
            if !already_present {
                let acc_idx = evm_accounts.len();
                evm_accounts.push(serde_json::json!({
                    "account_index": acc_idx,
                    "master_fingerprint": fp_hex,
                    "derivation_path": leaf_path,
                    "address": address,
                    "chain_id": active_chain,
                    "label": format!("Vault EVM #{}", acc_idx),
                    "compressed_pubkey_hex": hex::encode(&leaf_pubkey),
                    "chain_code_hex": k.chain_code.as_ref().map(hex::encode),
                    "note": k.note,
                }));
            }
        }
    }

    if evm_accounts.is_empty() && btc_accounts.is_empty() {
        return CString::new("{\"status\":\"ERROR\",\"error_code\":\"ERR_NO_SUPPORTED_ACCOUNTS\",\"error\":\"No supported EVM (m/44'/60'/...) or BTC (m/84'/...) keys found\"}")
            .unwrap()
            .into_raw();
    }

    let out = serde_json::json!({
        "status": "SUCCESS",
        "master_fingerprint": fp_hex,
        "master_fingerprint_u32": multi.master_fingerprint,
        "device": multi.device.unwrap_or_else(|| "AirGap Vault".to_string()),
        "device_id": multi.device_id,
        "version": multi.version,
        "evm_accounts": evm_accounts,
        "btc_accounts": btc_accounts,
        "unsupported_accounts": unsupported_accounts,
    });
    CString::new(out.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn wallet_build_eth_sign_request_ur(
    session_id: *const c_char,
    request_id_hex: *const c_char,
    raw_tx_hex: *const c_char,
    chain_id: u64,
    derivation_path: *const c_char,
    master_fingerprint_hex: *const c_char,
    expected_address: *const c_char,
    max_fragment_len: u32,
) -> *mut c_char {
    if session_id.is_null()
        || raw_tx_hex.is_null()
        || derivation_path.is_null()
        || expected_address.is_null()
    {
        return std::ptr::null_mut();
    }
    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy().to_string();
    let req_in = if request_id_hex.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(request_id_hex) }.to_string_lossy().to_string()
    };
    let tx_str = unsafe { CStr::from_ptr(raw_tx_hex) }.to_string_lossy();
    let path_str = unsafe { CStr::from_ptr(derivation_path) }.to_string_lossy();
    let fp_str = if master_fingerprint_hex.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(master_fingerprint_hex) }.to_string_lossy().to_string()
    };
    let addr_str = unsafe { CStr::from_ptr(expected_address) }.to_string_lossy();

    let raw_bytes = match hex::decode(tx_str.trim().trim_start_matches("0x")) {
        Ok(b) if !b.is_empty() => b,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_INVALID_TX_HEX",
                "error": format!("Invalid transaction hex: {e}"),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        _ => {
            return CString::new("{\"status\":\"ERROR\",\"error_code\":\"ERR_EMPTY_TX\",\"error\":\"Empty transaction bytes\"}")
                .unwrap()
                .into_raw();
        }
    };

    let (digest_bytes, intent, tx_type, data_type) = if raw_bytes.first() == Some(&0x02) {
        let tx = match Eip1559Transaction::decode_unsigned(&raw_bytes, chain_id) {
            Ok(t) => t,
            Err(e) => {
                let out = serde_json::json!({
                    "status": "ERROR",
                    "error_code": "ERR_EIP1559_DECODE",
                    "error": e.to_string(),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        };
        if let Err(e) = tx.validate_gas_for_signer(addr_str.trim()) {
            return CString::new(serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_GAS_PARAMETERS",
                "error": e.to_string(),
            }).to_string()).unwrap().into_raw();
        }
        (
            tx.signing_preimage_hash(),
            tx.to_intent(),
            "EIP1559".to_string(),
            ur_adapter::DataType::TypedTransaction,
        )
    } else {
        let tx = match LegacyTransaction::decode_unsigned(&raw_bytes, chain_id) {
            Ok(t) => t,
            Err(e) => {
                let out = serde_json::json!({
                    "status": "ERROR",
                    "error_code": "ERR_LEGACY_DECODE",
                    "error": e.to_string(),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        };
        (
            tx.signing_preimage_hash(),
            tx.to_intent(),
            "LEGACY_EIP155".to_string(),
            ur_adapter::DataType::Transaction,
        )
    };

    let policy = public_core::policy::PolicyEngine::default();
    let verdict = policy.evaluate_intent(&intent);
    if let public_core::policy::PolicyVerdict::Rejected { reason } = &verdict {
        let out = serde_json::json!({
            "status": "ERROR",
            "error_code": "ERR_POLICY_REJECTED",
            "error": reason,
        });
        return CString::new(out.to_string()).unwrap().into_raw();
    }

    let fp_opt: Option<[u8; 4]> = hex::decode(fp_str.trim().trim_start_matches("0x"))
        .ok()
        .and_then(|b| {
            if b.len() == 4 {
                let mut arr = [0u8; 4];
                arr.copy_from_slice(&b);
                Some(arr)
            } else {
                None
            }
        });

    let keypath = match ur_adapter::CryptoKeyPath::from_string_path(path_str.trim(), fp_opt) {
        Ok(kp) => kp,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_INVALID_KEYPATH",
                "error": e.to_string(),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
    };

    let addr_bytes_opt: Option<[u8; 20]> = hex::decode(addr_str.trim().trim_start_matches("0x"))
        .ok()
        .and_then(|b| {
            if b.len() == 20 {
                let mut arr = [0u8; 20];
                arr.copy_from_slice(&b);
                Some(arr)
            } else {
                None
            }
        });

    let req_uuid: [u8; 16] = if let Ok(b) = hex::decode(req_in.trim().trim_start_matches("0x")) {
        if b.len() == 16 {
            let mut arr = [0u8; 16];
            arr.copy_from_slice(&b);
            arr
        } else {
            let h = public_core::evm::keccak256(format!("{}:{}:{}", sess_str, req_in, hex::encode(digest_bytes)).as_bytes());
            let mut arr = [0u8; 16];
            arr.copy_from_slice(&h[0..16]);
            arr
        }
    } else {
        let h = public_core::evm::keccak256(format!("{}:{}:{}", sess_str, req_in, hex::encode(digest_bytes)).as_bytes());
        let mut arr = [0u8; 16];
        arr.copy_from_slice(&h[0..16]);
        arr
    };
    let req_id_hex_final = hex::encode(req_uuid);

    let eth_req = ur_adapter::EthSignRequest {
        request_id: Some(req_uuid),
        sign_data: raw_bytes.clone(),
        data_type,
        chain_id: Some(chain_id),
        derivation_path: keypath,
        address: addr_bytes_opt,
        origin: Some("MobileColdWallet Watch".to_string()),
    };

    let cbor_bytes = eth_req.to_cbor_bytes();
    let ur_single = ur_adapter::displayable_single_ur(ur_adapter::EthSignRequest::UR_TYPE, &cbor_bytes).unwrap_or_default();
    let frag_len = match if max_fragment_len == 0 {
        ur_adapter::default_fragment_len(&cbor_bytes)
    } else {
        Ok(max_fragment_len as usize)
    } {
        Ok(length) => length,
        Err(error) => return CString::new(serde_json::json!({
            "status":"ERROR", "error_code":"ERR_UR_ENCODE", "error":error.to_string(),
        }).to_string()).unwrap().into_raw(),
    };
    let fountain_frames = match ur_adapter::encode_ur_fountain_frames(
        ur_adapter::EthSignRequest::UR_TYPE,
        &cbor_bytes,
        frag_len,
    ) {
        Ok(frames) => frames,
        Err(error) => return CString::new(serde_json::json!({
            "status":"ERROR", "error_code":"ERR_UR_ENCODE", "error":error.to_string(),
        }).to_string()).unwrap().into_raw(),
    };

    let digest_hex = hex::encode(digest_bytes);
    with_wallet_ctx(|ctx| {
        ctx.pending_requests.insert(
            req_id_hex_final.clone(),
            PendingWalletRequest {
                session_id: sess_str.clone(),
                request_id: req_id_hex_final.clone(),
                chain_id,
                expected_address: addr_str.trim().to_string(),
                raw_rlp_hex: hex::encode(&raw_bytes),
                expected_digest_hex: digest_hex.clone(),
                tx_type: tx_type.clone(),
                consumed: false,
            },
        );
    });

    let out = serde_json::json!({
        "status": "PENDING_REGISTERED",
        "session_id": sess_str,
        "request_id": req_id_hex_final,
        "chain_id": chain_id,
        "expected_address": addr_str.trim(),
        "expected_digest": digest_hex,
        "tx_type": tx_type,
        "intent": intent,
        "policy_verdict": verdict,
        "cbor_hex": hex::encode(&cbor_bytes),
        "ur_single": ur_single,
        "fountain_frames": fountain_frames,
    });
    CString::new(out.to_string()).unwrap().into_raw()
}

fn assemble_signed_evm_transaction(
    raw_unsigned: &[u8],
    chain_id: u64,
    verified_signer: &str,
    r: &[u8; 32],
    s: &[u8; 32],
    v: u8,
) -> Result<(Vec<u8>, [u8; 32]), String> {
    use public_core::evm::dec_string_to_be_bytes;
    use public_core::rlp::{encode_bytes, encode_list, encode_u64};

    let recid: u64 = match v {
        0 | 1 => v as u64,
        27 | 28 => (v - 27) as u64,
        other => return Err(format!("Invalid recovery id v={other}")),
    };

    let trim_leading_zeros = |bytes: &[u8]| -> Vec<u8> {
        let first_nz = bytes.iter().position(|&b| b != 0).unwrap_or(bytes.len());
        bytes[first_nz..].to_vec()
    };
    let r_trimmed = trim_leading_zeros(r);
    let s_trimmed = trim_leading_zeros(s);

    if raw_unsigned.first() == Some(&0x02) {
        let tx = Eip1559Transaction::decode_unsigned(raw_unsigned, chain_id)
            .map_err(|e| format!("EIP-1559 decode failed during assembly: {e}"))?;
        tx.validate_gas_for_signer(verified_signer).map_err(|e| e.to_string())?;
        let value_bytes = dec_string_to_be_bytes(&tx.value_wei);
        let to_encoded = match &tx.to {
            Some(addr_str) => {
                let to_bytes = hex::decode(addr_str.trim_start_matches("0x")).unwrap_or_default();
                encode_bytes(&to_bytes)
            }
            None => encode_bytes(&[]),
        };
        let mut access_list_encoded = Vec::new();
        for item in &tx.access_list {
            let addr_bytes = hex::decode(item.address.trim_start_matches("0x")).unwrap_or_default();
            let mut keys_encoded = Vec::new();
            for k in &item.storage_keys {
                let raw_k = hex::decode(k.trim_start_matches("0x")).unwrap_or_default();
                keys_encoded.push(encode_bytes(&raw_k));
            }
            access_list_encoded.push(encode_list(&[
                encode_bytes(&addr_bytes),
                encode_list(&keys_encoded),
            ]));
        }

        let fields = vec![
            encode_u64(tx.chain_id),
            encode_u64(tx.nonce),
            encode_u64(tx.max_priority_fee_per_gas),
            encode_u64(tx.max_fee_per_gas),
            encode_u64(tx.gas_limit),
            to_encoded,
            encode_bytes(&value_bytes),
            encode_bytes(&tx.data),
            encode_list(&access_list_encoded),
            encode_u64(recid),
            encode_bytes(&r_trimmed),
            encode_bytes(&s_trimmed),
        ];
        let rlp_body = encode_list(&fields);
        let mut signed_bytes = Vec::with_capacity(1 + rlp_body.len());
        signed_bytes.push(0x02);
        signed_bytes.extend_from_slice(&rlp_body);
        let tx_hash = public_core::evm::keccak256(&signed_bytes);
        Ok((signed_bytes, tx_hash))
    } else {
        let tx = LegacyTransaction::decode_unsigned(raw_unsigned, chain_id)
            .map_err(|e| format!("Legacy decode failed during assembly: {e}"))?;
        let value_bytes = dec_string_to_be_bytes(&tx.value_wei);
        let to_encoded = match &tx.to {
            Some(addr_str) => {
                let to_bytes = hex::decode(addr_str.trim_start_matches("0x")).unwrap_or_default();
                encode_bytes(&to_bytes)
            }
            None => encode_bytes(&[]),
        };
        let eip155_v = tx.chain_id * 2 + 35 + recid;
        let fields = vec![
            encode_u64(tx.nonce),
            encode_u64(tx.gas_price),
            encode_u64(tx.gas_limit),
            to_encoded,
            encode_bytes(&value_bytes),
            encode_bytes(&tx.data),
            encode_u64(eip155_v),
            encode_bytes(&r_trimmed),
            encode_bytes(&s_trimmed),
        ];
        let signed_bytes = encode_list(&fields);
        let tx_hash = public_core::evm::keccak256(&signed_bytes);
        Ok((signed_bytes, tx_hash))
    }
}

#[no_mangle]
pub extern "C" fn wallet_verify_and_assemble_eth_signature_ur(
    session_id: *const c_char,
    request_id_hex: *const c_char,
    sig_ur_or_frames: *const c_char,
) -> *mut c_char {
    if session_id.is_null() || request_id_hex.is_null() || sig_ur_or_frames.is_null() {
        return std::ptr::null_mut();
    }
    let sess_str = unsafe { CStr::from_ptr(session_id) }.to_string_lossy();
    let req_str = unsafe { CStr::from_ptr(request_id_hex) }
        .to_string_lossy()
        .trim()
        .trim_start_matches("0x")
        .to_lowercase();
    let sig_input = unsafe { CStr::from_ptr(sig_ur_or_frames) }.to_string_lossy();
    let clean = sig_input.trim();

    let eth_sig = if clean.to_lowercase().starts_with("ur:") || clean.starts_with('[') {
        match ur_adapter::DecodedUrPayload::decode(clean) {
            Ok(ur_adapter::DecodedUrPayload::EthSignature(s)) => s,
            Ok(_) => {
                return CString::new("{\"verified\":false,\"error_code\":\"ERR_TYPE_MISMATCH\",\"error\":\"UR payload is not eth-signature\"}")
                    .unwrap()
                    .into_raw();
            }
            Err(e) => {
                let out = serde_json::json!({
                    "verified": false,
                    "error_code": "ERR_UR_DECODE",
                    "error": e.to_string(),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        }
    } else if let Ok(cbor_bytes) = hex::decode(clean.trim_start_matches("0x")) {
        match ur_adapter::EthSignature::from_cbor_bytes(&cbor_bytes) {
            Ok(s) => s,
            Err(e) => {
                let out = serde_json::json!({
                    "verified": false,
                    "error_code": "ERR_CBOR_DECODE",
                    "error": e.to_string(),
                });
                return CString::new(out.to_string()).unwrap().into_raw();
            }
        }
    } else {
        return CString::new("{\"verified\":false,\"error_code\":\"ERR_INVALID_INPUT\",\"error\":\"Invalid eth-signature input\"}")
            .unwrap()
            .into_raw();
    };

    let out = with_wallet_ctx(|ctx| {
        let pending = match ctx.pending_requests.get_mut(&req_str) {
            Some(p) => p,
            None => {
                return serde_json::json!({
                    "verified": false,
                    "error_code": "ERR_UNKNOWN_REQUEST_ID",
                    "error": format!("No pending transaction registered for request_id '{}'", req_str),
                })
                .to_string();
            }
        };

        if pending.consumed {
            return serde_json::json!({
                "verified": false,
                "error_code": "ERR_ALREADY_CONSUMED",
                "error": format!("Pending request '{}' has already been consumed", req_str),
            })
            .to_string();
        }

        if pending.session_id != sess_str {
            return serde_json::json!({
                "verified": false,
                "error_code": "ERR_SESSION_MISMATCH",
                "error": format!("Session ID mismatch: expected '{}', got '{}'", pending.session_id, sess_str),
            })
            .to_string();
        }

        match eth_sig.request_id {
            Some(sig_uuid) => {
                let sig_req_hex = hex::encode(sig_uuid);
                if !sig_req_hex.eq_ignore_ascii_case(&pending.request_id) {
                    return serde_json::json!({
                        "verified": false,
                        "error_code": "ERR_REQUEST_ID_MISMATCH",
                        "error": format!(
                            "Signature request_id '{}' does not match pending request_id '{}'",
                            sig_req_hex, pending.request_id
                        ),
                    })
                    .to_string();
                }
            }
            None => {
                return serde_json::json!({
                    "verified": false,
                    "error_code": "ERR_MISSING_REQUEST_ID",
                    "error": "eth-signature is missing mandatory request_id binding",
                })
                .to_string();
            }
        }

        let mut digest_bytes = [0u8; 32];
        if let Ok(b) = hex::decode(&pending.expected_digest_hex) {
            if b.len() == 32 {
                digest_bytes.copy_from_slice(&b);
            } else {
                return "{\"verified\":false,\"error_code\":\"ERR_INTERNAL_DIGEST\",\"error\":\"Invalid stored digest length\"}".to_string();
            }
        } else {
            return "{\"verified\":false,\"error_code\":\"ERR_INTERNAL_DIGEST\",\"error\":\"Invalid stored digest hex\"}".to_string();
        }

        let mut r = [0u8; 32];
        let mut s = [0u8; 32];
        r.copy_from_slice(&eth_sig.signature[0..32]);
        s.copy_from_slice(&eth_sig.signature[32..64]);
        let v = eth_sig.signature[64];

        let recovered_address = match verify_ethereum_signature(
            &digest_bytes,
            &r,
            &s,
            v,
            &pending.expected_address,
        ) {
            Ok(addr) => addr,
            Err(e) => {
                return serde_json::json!({
                    "verified": false,
                    "error_code": "ERR_SIGNATURE_VERIFICATION_FAILED",
                    "error": format!("Signature verification failed: {e}"),
                })
                .to_string();
            }
        };

        let raw_unsigned = match hex::decode(&pending.raw_rlp_hex) {
            Ok(b) => b,
            Err(e) => {
                return serde_json::json!({
                    "verified": false,
                    "error_code": "ERR_RAW_TX_DECODE",
                    "error": e.to_string(),
                })
                .to_string();
            }
        };

        let (signed_bytes, tx_hash) = match assemble_signed_evm_transaction(
            &raw_unsigned,
            pending.chain_id,
            &recovered_address,
            &r,
            &s,
            v,
        ) {
            Ok(res) => res,
            Err(e) => {
                return serde_json::json!({
                    "verified": false,
                    "error_code": "ERR_TX_ASSEMBLY_FAILED",
                    "error": e,
                })
                .to_string();
            }
        };

        pending.consumed = true;
        serde_json::json!({
            "verified": true,
            "status": "SIGNED_TX_READY",
            "session_id": pending.session_id,
            "request_id": pending.request_id,
            "chain_id": pending.chain_id,
            "tx_type": pending.tx_type,
            "expected_digest": pending.expected_digest_hex,
            "recovered_address": recovered_address,
            "r_hex": format!("0x{}", hex::encode(r)),
            "s_hex": format!("0x{}", hex::encode(s)),
            "v": v,
            "signed_raw_tx_hex": format!("0x{}", hex::encode(&signed_bytes)),
            "local_tx_hash": format!("0x{}", hex::encode(tx_hash)),
        })
        .to_string()
    });

    CString::new(out).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn wallet_encode_psbt_ur(
    psbt_hex: *const c_char,
    max_fragment_len: u32,
) -> *mut c_char {
    if psbt_hex.is_null() {
        return std::ptr::null_mut();
    }
    let hex_str = unsafe { CStr::from_ptr(psbt_hex) }.to_string_lossy();
    let psbt_bytes = match hex::decode(hex_str.trim().trim_start_matches("0x")) {
        Ok(b) if !b.is_empty() => b,
        Err(e) => {
            let out = serde_json::json!({
                "status": "ERROR",
                "error_code": "ERR_INVALID_PSBT_HEX",
                "error": format!("Invalid PSBT hex: {e}"),
            });
            return CString::new(out.to_string()).unwrap().into_raw();
        }
        _ => {
            return CString::new("{\"status\":\"ERROR\",\"error_code\":\"ERR_EMPTY_PSBT\",\"error\":\"Empty PSBT bytes\"}")
                .unwrap()
                .into_raw();
        }
    };

    if let Err(e) = public_core::bitcoin::Psbt::deserialize(&psbt_bytes) {
        let out = serde_json::json!({
            "status": "ERROR",
            "error_code": "ERR_PSBT_DESERIALIZE",
            "error": format!("PSBT deserialization failed: {e}"),
        });
        return CString::new(out.to_string()).unwrap().into_raw();
    }

    let cp = ur_adapter::CryptoPsbt::new(psbt_bytes);
    let cbor_bytes = cp.to_cbor_bytes();
    let ur_single = ur_adapter::displayable_single_ur(ur_adapter::CryptoPsbt::UR_TYPE, &cbor_bytes).unwrap_or_default();
    let frag_len = match if max_fragment_len == 0 {
        ur_adapter::default_fragment_len(&cbor_bytes)
    } else {
        Ok(max_fragment_len as usize)
    } {
        Ok(length) => length,
        Err(error) => return CString::new(serde_json::json!({
            "status":"ERROR", "error_code":"ERR_UR_ENCODE", "error":error.to_string(),
        }).to_string()).unwrap().into_raw(),
    };
    let fountain_frames = match ur_adapter::encode_ur_fountain_frames(
        ur_adapter::CryptoPsbt::UR_TYPE,
        &cbor_bytes,
        frag_len,
    ) {
        Ok(frames) => frames,
        Err(error) => return CString::new(serde_json::json!({
            "status":"ERROR", "error_code":"ERR_UR_ENCODE", "error":error.to_string(),
        }).to_string()).unwrap().into_raw(),
    };

    let out = serde_json::json!({
        "status": "SUCCESS",
        "cbor_hex": hex::encode(&cbor_bytes),
        "ur_single": ur_single,
        "fountain_frames": fountain_frames,
    });
    CString::new(out.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn wallet_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

// ============================================================================
// Standard JNI Exports for Android / JVM (`com.mobilecoldwallet.nfc_probe.WalletCoreBridge`)
// ============================================================================
#[cfg(any(test, feature = "test-fixtures"))]
mod nfc_probe_jni {
use super::*;
use std::os::raw::c_void;
type JniEnv = *const *const *const std::os::raw::c_void;
type JObject = *mut c_void;
type JString = *mut c_void;

unsafe fn jstring_to_rust(env: JniEnv, jstr: JString) -> String {
    if env.is_null() || jstr.is_null() {
        return String::new();
    }
    let table = *env;
    // JNINativeInterface_ index 169 = GetStringUTFChars, 170 = ReleaseStringUTFChars
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

unsafe fn rust_to_jstring(env: JniEnv, s: &str) -> JString {
    if env.is_null() {
        return std::ptr::null_mut();
    }
    let table = *env;
    // JNINativeInterface_ index 167 = NewStringUTF
    let new_utf: extern "system" fn(JniEnv, *const c_char) -> JString =
        std::mem::transmute(*table.add(167));
    let cstr = CString::new(s).unwrap_or_else(|_| CString::new("{}").unwrap());
    new_utf(env, cstr.as_ptr())
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_WalletCoreBridge_nativeInit(
    _env: JniEnv,
    _class: JObject,
) -> i32 {
    wallet_init()
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_WalletCoreBridge_nativeRegisterPendingTx(
    env: JniEnv,
    _class: JObject,
    session_id: JString,
    request_id: JString,
    raw_rlp_hex: JString,
    declared_chain_id: i64,
    expected_address: JString,
) -> JString {
    let sess = jstring_to_rust(env, session_id);
    let req = jstring_to_rust(env, request_id);
    let rlp = jstring_to_rust(env, raw_rlp_hex);
    let addr = jstring_to_rust(env, expected_address);
    let out = wallet_register_pending_tx_internal(&sess, &req, &rlp, declared_chain_id as u64, &addr);
    rust_to_jstring(env, &out)
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_WalletCoreBridge_nativeChunkPayload(
    env: JniEnv,
    _class: JObject,
    session_id: JString,
    request_id: JString,
    message_kind: i32,
    raw_payload_hex: JString,
    chunk_size: i32,
) -> JString {
    let sess = jstring_to_rust(env, session_id);
    let req = jstring_to_rust(env, request_id);
    let payload = jstring_to_rust(env, raw_payload_hex);
    let out = wallet_chunk_payload_internal(&sess, &req, message_kind as u8, &payload, chunk_size.max(1) as usize);
    rust_to_jstring(env, &out)
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_WalletCoreBridge_nativeProcessApduFrame(
    env: JniEnv,
    _class: JObject,
    apdu_hex: JString,
) -> JString {
    let apdu = jstring_to_rust(env, apdu_hex);
    let out = wallet_process_apdu_frame_internal(&apdu);
    rust_to_jstring(env, &out)
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_WalletCoreBridge_nativeVerifyNfcResponse(
    env: JniEnv,
    _class: JObject,
    session_id: JString,
    request_id: JString,
    response_payload_hex: JString,
) -> JString {
    let sess = jstring_to_rust(env, session_id);
    let req = jstring_to_rust(env, request_id);
    let resp = jstring_to_rust(env, response_payload_hex);
    let out = wallet_verify_nfc_response_internal(&sess, &req, &resp);
    rust_to_jstring(env, &out)
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_mobilecoldwallet_nfc_1probe_WalletCoreBridge_nativeResetTransportAssembler(
    env: JniEnv,
    _class: JObject,
    session_id: JString,
) -> i32 {
    let sess = jstring_to_rust(env, session_id);
    wallet_reset_transport_assembler_internal(&sess)
}

} // NFC Probe bridge is retained only in explicitly selected fixture builds.

#[cfg(test)]
mod tests {
    use super::*;
    use public_core::rlp::{encode_bytes, encode_list, encode_u64};

    fn official_account_standard_fixture() -> ur_adapter::CryptoMultiAccounts {
        ur_adapter::CryptoMultiAccounts {
            master_fingerprint: 0x73c5da0a,
            keys: vec![ur_adapter::CryptoHDKey {
                name: Some("Keystone".into()),
                key_data: hex::decode("02eae4b876a8696134b868f88cc2f51f715f2dbedb7446b8e6edf3d4541c4eb67b").unwrap(),
                chain_code: Some(hex::decode("d882718b7a42806803eeb17f7483f20620611adb88fc943c898dc5aba94c2819").unwrap()),
                parent_fingerprint: Some([0xd3, 0x2e, 0x45, 0x08]),
                origin: ur_adapter::CryptoKeyPath::from_string_path(
                    "m/44'/60'/0'",
                    Some([0x73, 0xc5, 0xda, 0x0a]),
                ).unwrap(),
                note: Some("account.standard".into()),
            }],
            device: Some("FCW Vault".into()),
            device_id: None,
            version: None,
        }
    }

    fn decode_public_pairing_fixture(account: &ur_adapter::CryptoMultiAccounts) -> serde_json::Value {
        let encoded = CString::new(account.to_ur_single()).unwrap();
        let result = wallet_decode_and_verify_multi_accounts_ur(encoded.as_ptr(), 11155111);
        let decoded = serde_json::from_str(unsafe { CStr::from_ptr(result) }.to_str().unwrap()).unwrap();
        wallet_free_string(result);
        decoded
    }

    #[test]
    fn official_account_standard_profile_derives_real_leaf_address() {
        let decoded = decode_public_pairing_fixture(&official_account_standard_fixture());
        assert_eq!(decoded["status"], "SUCCESS");
        assert_eq!(
            decoded["evm_accounts"][0]["address"].as_str().unwrap().to_lowercase(),
            "0x9858effd232b4033e47d90003d41ec34ecaeda94"
        );
        assert_eq!(decoded["evm_accounts"][0]["derivation_path"], "m/44'/60'/0'/0/0");
    }

    #[test]
    fn malformed_account_chain_code_never_imports_account_node_as_receive_address() {
        for chain_code in [None, Some(vec![0; 31]), Some(vec![0; 33])] {
            let mut account = official_account_standard_fixture();
            account.keys[0].chain_code = chain_code;
            let decoded = decode_public_pairing_fixture(&account);
            assert_eq!(decoded["status"], "ERROR");
            assert_eq!(decoded["error_code"], "ERR_ACCOUNT_CHAIN_CODE");
            assert!(decoded.get("evm_accounts").is_none());
        }
    }

    #[test]
    fn sepolia_low_gas_pending_requests_require_the_expected_self_sender() {
        let raw = "02f183aa36a782016a843b9aca00843b9aca15822ee094f39fd6e51aad88f6f4ce6ab8827279cfffb9226685e8d4a5100080c0";
        let rejected: serde_json::Value = serde_json::from_str(&wallet_register_pending_tx_internal(
            "sepolia-gas-session",
            "sepolia-gas-wrong-sender",
            raw,
            11155111,
            "0x9858effd232b4033e47d90003d41ec34ecaeda94",
        )).unwrap();
        assert!(rejected.get("error").is_some(), "{rejected}");
        let accepted: serde_json::Value = serde_json::from_str(&wallet_register_pending_tx_internal(
            "sepolia-gas-session",
            "sepolia-gas-self-sender",
            raw,
            11155111,
            "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
        )).unwrap();
        assert_eq!(accepted["status"], "PENDING_REGISTERED");

        let session = CString::new("sepolia-gas-ur-session").unwrap();
        let request_id = CString::new(hex::encode([9; 16])).unwrap();
        let raw_c = CString::new(raw).unwrap();
        let path = CString::new("m/44'/60'/0'/0/0").unwrap();
        for (signer, expected_status) in [
            ("0x9858effd232b4033e47d90003d41ec34ecaeda94", "ERROR"),
            ("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266", "PENDING_REGISTERED"),
        ] {
            let signer = CString::new(signer).unwrap();
            let result = wallet_build_eth_sign_request_ur(session.as_ptr(), request_id.as_ptr(), raw_c.as_ptr(), 11155111, path.as_ptr(), std::ptr::null(), signer.as_ptr(), 200);
            let decoded: serde_json::Value = serde_json::from_str(unsafe { CStr::from_ptr(result) }.to_str().unwrap()).unwrap();
            wallet_free_string(result);
            assert_eq!(decoded["status"], expected_status, "{decoded}");
        }
    }

    #[test]
    fn test_wallet_ffi_watch_only_decode_and_verify() {
        wallet_init();
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
        let rlp_c = CString::new(rlp_hex.clone()).unwrap();

        let intent_ptr = wallet_decode_intent_json(rlp_c.as_ptr(), 11155111);
        assert!(!intent_ptr.is_null());
        let intent_str = unsafe { CStr::from_ptr(intent_ptr) }.to_str().unwrap();
        assert!(intent_str.contains("NativeTransfer"));
        wallet_free_string(intent_ptr);

        // Verification test with dummy signature
        let digest_c = CString::new("0000000000000000000000000000000000000000000000000000000000000001").unwrap();
        let r_c = CString::new("0000000000000000000000000000000000000000000000000000000000000001").unwrap();
        let s_c = CString::new("0000000000000000000000000000000000000000000000000000000000000001").unwrap();
        let exp_c = CString::new("0x9858EfFD232B4033E47d90003D41EC34EcaEda94").unwrap();

        // Mismatched / invalid signature returns 0, does not crash
        let res = wallet_verify_signature(digest_c.as_ptr(), r_c.as_ptr(), s_c.as_ptr(), 27, exp_c.as_ptr());
        assert_eq!(res, 0);

        // Null pointer returns -1
        let null_res = wallet_verify_signature(std::ptr::null(), r_c.as_ptr(), s_c.as_ptr(), 27, exp_c.as_ptr());
        assert_eq!(null_res, -1);

        // Digest computation test
        let digest_ptr = wallet_compute_legacy_signing_digest(rlp_c.as_ptr(), 11155111);
        assert!(!digest_ptr.is_null());
        let digest_str = unsafe { CStr::from_ptr(digest_ptr) }.to_str().unwrap();
        assert_eq!(digest_str.len(), 64);
        wallet_free_string(digest_ptr);

        // Pending tx registration and mismatched response rejection
        let reg = wallet_register_pending_tx_internal(
            "sess-w-1",
            "req-w-1",
            &rlp_hex,
            11155111,
            "0x9858EfFD232B4033E47d90003D41EC34EcaEda94",
        );
        assert!(reg.contains("PENDING_REGISTERED"));

        let bad_resp = hex::encode(
            serde_json::json!({
                "request_id": "req-w-1",
                "digest": "00".repeat(32),
                "r": "11".repeat(32),
                "s": "22".repeat(32),
                "v": 27,
                "signer_address": "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
            })
            .to_string()
            .as_bytes(),
        );
        let ver_bad = wallet_verify_nfc_response_internal("sess-w-1", "req-w-1", &bad_resp);
        assert!(ver_bad.contains("\"verified\":false"));
        assert!(ver_bad.contains("Digest mismatch against local pending tx"));
    }

    #[test]
    fn test_wallet_ffi_ur_pairing_and_sign_request_assembly() {
        wallet_init();
        let xpub_pk = hex::decode("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798").unwrap();
        let xpub_cc = [0x11u8; 32].to_vec();
        let expected_addr = pubkey_bytes_to_evm_address(&xpub_pk).unwrap();

        // Verify leaf pubkey -> address consistency
        let pubkey_c = CString::new(hex::encode(&xpub_pk)).unwrap();
        let addr_c = CString::new(expected_addr.clone()).unwrap();
        let v_res = wallet_verify_pubkey_address(pubkey_c.as_ptr(), addr_c.as_ptr());
        assert_eq!(v_res, 1);

        // Mismatched address must return 0
        let wrong_addr_c = CString::new("0x0000000000000000000000000000000000000001").unwrap();
        assert_eq!(wallet_verify_pubkey_address(pubkey_c.as_ptr(), wrong_addr_c.as_ptr()), 0);

        // Also test wallet_decode_and_verify_multi_accounts_ur on a real CryptoMultiAccounts UR
        let multi = ur_adapter::CryptoMultiAccounts {
            master_fingerprint: 0x73c5da0a,
            keys: vec![ur_adapter::CryptoHDKey {
                name: None,
                parent_fingerprint: None,
                key_data: xpub_pk.clone(),
                chain_code: Some(xpub_cc),
                origin: ur_adapter::CryptoKeyPath::from_string_path("m/44'/60'/0'/0/0", Some([0x73, 0xc5, 0xda, 0x0a])).unwrap(),
                note: Some("account.standard".into()),
            }],
            device: Some("TestVault".into()),
            device_id: None,
            version: Some("1.0.0".into()),
        };
        let multi_ur = ur_adapter::encode_ur_fountain_frames("crypto-multi-accounts", &multi.to_cbor_bytes(), 0).unwrap()[0].clone();
        let multi_ur_c = CString::new(multi_ur).unwrap();
        let decoded_ptr = wallet_decode_and_verify_multi_accounts_ur(multi_ur_c.as_ptr(), 11155111);
        let decoded_str = unsafe { CStr::from_ptr(decoded_ptr) }.to_str().unwrap();
        let decoded_val: serde_json::Value = serde_json::from_str(decoded_str).unwrap();
        assert_eq!(decoded_val["status"], "SUCCESS", "Got: {decoded_str}");
        assert_eq!(decoded_val["evm_accounts"][0]["address"], expected_addr);
        wallet_free_string(decoded_ptr);

        // Build EthSignRequest UR for EIP-1559 transaction
        let to_addr = hex::decode("70997970c51812dc3a010c7d01b50e0d17dc79c8").unwrap();
        let fields = vec![
            encode_u64(11155111),
            encode_u64(0),
            encode_u64(1_500_000_000),
            encode_u64(20_000_000_000),
            encode_u64(21000),
            encode_bytes(&to_addr),
            encode_u64(100_000_000_000_000_000),
            encode_bytes(&[]),
            encode_list(&[]),
        ];
        let mut raw_1559 = vec![0x02u8];
        raw_1559.extend_from_slice(&encode_list(&fields));
        let raw_1559_hex = hex::encode(&raw_1559);

        let sess_c = CString::new("sess-ur-1").unwrap();
        let req_id_c = CString::new("11111111222233334444555566667777").unwrap();
        let raw_c = CString::new(raw_1559_hex.clone()).unwrap();
        let path_c = CString::new("m/44'/60'/0'/0/0").unwrap();
        let fp_c = CString::new("73c5da0a").unwrap();

        let ur_ptr = wallet_build_eth_sign_request_ur(
            sess_c.as_ptr(),
            req_id_c.as_ptr(),
            raw_c.as_ptr(),
            11155111,
            path_c.as_ptr(),
            fp_c.as_ptr(),
            addr_c.as_ptr(),
            80,
        );
        let ur_str = unsafe { CStr::from_ptr(ur_ptr) }.to_str().unwrap();
        let ur_val: serde_json::Value = serde_json::from_str(ur_str).unwrap();
        assert_eq!(ur_val["status"], "PENDING_REGISTERED", "Got: {ur_str}");
        assert_eq!(ur_val["request_id"], "11111111222233334444555566667777");
        assert!(ur_val["ur_single"].as_str().unwrap().starts_with("ur:eth-sign-request/"));
        wallet_free_string(ur_ptr);
    }
}


#[no_mangle]
pub extern "C" fn fcw_decode_ur_frames(input: *const c_char) -> *mut c_char {
    unsafe { ur_adapter::ffi_decode::decode_frames_json(input) }
}

#[no_mangle]
pub extern "C" fn fcw_free_ur_result(ptr: *mut c_char) {
    unsafe { ur_adapter::ffi_decode::free_json(ptr) }
}

#[cfg(test)]
mod qr_cancellation_tests {
    use super::*;
    #[test]
    fn cancelling_qr_session_removes_only_its_requests() {
        let session = "cancel-test-owned-session";
        let other = "cancel-test-other-session";
        let mut ctx = WalletContext::default();
        for (id, owner) in [("cancel-owned-id", session), ("cancel-other-id", other)] {
            ctx.pending_requests.insert(id.into(), PendingWalletRequest {
                session_id: owner.into(), request_id: id.into(), chain_id: 11155111,
                expected_address: String::new(), raw_rlp_hex: String::new(),
                expected_digest_hex: String::new(), tx_type: String::new(), consumed: false,
            });
        }
        assert_eq!(cancel_pending_session(&mut ctx, session), 0);
        assert!(!ctx.pending_requests.contains_key("cancel-owned-id"));
        assert!(ctx.pending_requests.contains_key("cancel-other-id"));
        assert_eq!(wallet_cancel_pending_session(std::ptr::null()), -1);

    }
}
