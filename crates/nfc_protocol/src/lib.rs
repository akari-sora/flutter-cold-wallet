use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

pub const MAX_NFC_PAYLOAD_SIZE: usize = 128 * 1024; // 128 KiB
pub const MAX_CHUNKS: u32 = 1024;
pub const PROTOCOL_WIRE_VERSION: u16 = 1;
pub const MAX_CBOR_DEPTH: usize = 8;
pub const MAX_ID_STRING_LEN: usize = 128;
pub const MAX_ENVELOPE_CBOR_LEN: usize = 512;
pub const MAX_HCE_APDU_DATA_LEN: usize = 128;
pub const MAX_HCE_CAPDU_WIRE_LEN: usize = 4 + 1 + MAX_HCE_APDU_DATA_LEN + 1; // 134 bytes
pub const MIN_ISODEP_MAX_TRANSCEIVE_LEN: usize = 261;
pub const INS_NFC_ENVELOPE_FRAME: u8 = 0x40;

pub const MAX_CONCURRENT_SESSIONS: usize = 32;
pub const MAX_GLOBAL_SESSION_BYTES: usize = 512 * 1024; // 512 KiB total across active sessions
pub const DEFAULT_SESSION_TTL_MS: u64 = 30_000; // 30 seconds bounded TTL
pub const MAX_APDU_FRAMES_PER_ENVELOPE: u8 = 8; // 8 * 128B = 1024B > MAX_ENVELOPE_CBOR_LEN (512B)
pub const MAX_COMPLETED_HISTORY_ENTRIES: usize = 256;
pub const MAX_COMPLETED_HISTORY_BYTES: usize = 64 * 1024; // 64 KiB
pub const DEFAULT_COMPLETED_HISTORY_TTL_MS: u64 = 300_000; // 5 minutes
pub const MAX_EVICTED_FINGERPRINT_RING: usize = 2048; // 32 KiB fixed ring
pub const MAX_CACHED_RESPONSES: usize = 16;
pub const MAX_CACHED_RESPONSE_BYTES: usize = 64 * 1024;
pub const DEFAULT_RESPONSE_CACHE_TTL_MS: u64 = 120_000;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum NfcError {
    #[error("Payload exceeds maximum bounded capacity of {0} bytes")]
    PayloadTooLarge(usize),

    #[error("Invalid chunk sequence: index {index}, total {total}")]
    InvalidChunkSequence { index: u32, total: u32 },

    #[error("Session ID mismatch: expected {expected}, got {got}")]
    SessionMismatch { expected: String, got: String },

    #[error("Request ID mismatch: expected {expected}, got {got}")]
    RequestIdMismatch { expected: String, got: String },

    #[error("Message kind mismatch: expected {expected:?}, got {got:?}")]
    MessageKindMismatch { expected: MessageKind, got: MessageKind },

    #[error("Wire version mismatch: expected {expected}, got {got}")]
    WireVersionMismatch { expected: u16, got: u16 },

    #[error("Payload digest commitment mismatch: expected {expected}, got {got}")]
    DigestCommitmentMismatch { expected: String, got: String },

    #[error("Conflicting duplicate chunk at index {index}")]
    ConflictingDuplicateChunk { index: u32 },

    #[error("Payload digest mismatch: calculated {calculated}, declared {declared}")]
    DigestMismatch { calculated: String, declared: String },

    #[error("Serialization / CBOR error: {0}")]
    SerializationError(String),

    #[error("Assembly incomplete: have {received}/{total} chunks")]
    IncompleteAssembly { received: u32, total: u32 },

    #[error("APDU framing error: {0}")]
    ApduFramingError(String),

    #[error("Session lifecycle error: {0}")]
    SessionLifecycleError(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum MessageKind {
    Capabilities = 1,
    Pairing = 2,
    AccountDescriptor = 3,
    SignRequest = 4,
    Status = 5,
    SignResponse = 6,
    Cancel = 7,
    Ack = 8,
    Error = 9,
}

/// Wire Profile v1 (`PROTOCOL_WIRE_VERSION = 1`):
/// - Uses NIST FIPS 180-4 SHA-256 (`sha2::Sha256`) for `payload_digest` (64-char hex).
/// - Legacy/pre-fix Keccak-256 digests or any `wire_version != 1` are strictly rejected
///   at ingress with zero silent compatibility fallback.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NfcEnvelope {
    pub wire_version: u16,
    pub message_kind: MessageKind,
    pub session_id: String,
    pub request_id: String,
    pub chunk_index: u32,
    pub total_chunks: u32,
    pub payload_digest: String,
    pub payload: Vec<u8>,
}

/// Strict structural CBOR validator executed before deserializing `NfcEnvelope`.
/// Enforces:
/// 1. Non-empty input and total input length `<= MAX_NFC_PAYLOAD_SIZE`
/// 2. Complete input consumption (zero trailing bytes after root item)
/// 3. Rejection of indefinite-length encodings (`additional_info == 31`) and reserved info (`28..=30`)
/// 4. Rejection of duplicate map keys at every map level
/// 5. Bounded nesting depth (`<= MAX_CBOR_DEPTH`) and string/integer bounds
pub fn validate_strict_cbor(raw_bytes: &[u8]) -> Result<(), NfcError> {
    if raw_bytes.is_empty() {
        return Err(NfcError::SerializationError("Empty CBOR input".into()));
    }
    if raw_bytes.len() > MAX_NFC_PAYLOAD_SIZE {
        return Err(NfcError::PayloadTooLarge(raw_bytes.len()));
    }

    fn read_arg(buf: &[u8], offset: &mut usize, info: u8) -> Result<u64, NfcError> {
        if info < 24 {
            Ok(info as u64)
        } else if info == 24 {
            if *offset >= buf.len() {
                return Err(NfcError::SerializationError("Unexpected EOF reading 1-byte CBOR arg".into()));
            }
            let b = buf[*offset];
            *offset += 1;
            if b < 24 {
                return Err(NfcError::SerializationError("Non-canonical 1-byte CBOR integer encoding".into()));
            }
            Ok(b as u64)
        } else if info == 25 {
            if *offset + 2 > buf.len() {
                return Err(NfcError::SerializationError("Unexpected EOF reading 2-byte CBOR arg".into()));
            }
            let mut arr = [0u8; 2];
            arr.copy_from_slice(&buf[*offset..*offset + 2]);
            *offset += 2;
            let v = u16::from_be_bytes(arr);
            if v <= u8::MAX as u16 {
                return Err(NfcError::SerializationError("Non-canonical 2-byte CBOR integer encoding".into()));
            }
            Ok(v as u64)
        } else if info == 26 {
            if *offset + 4 > buf.len() {
                return Err(NfcError::SerializationError("Unexpected EOF reading 4-byte CBOR arg".into()));
            }
            let mut arr = [0u8; 4];
            arr.copy_from_slice(&buf[*offset..*offset + 4]);
            *offset += 4;
            let v = u32::from_be_bytes(arr);
            if v <= u16::MAX as u32 {
                return Err(NfcError::SerializationError("Non-canonical 4-byte CBOR integer encoding".into()));
            }
            Ok(v as u64)
        } else if info == 27 {
            if *offset + 8 > buf.len() {
                return Err(NfcError::SerializationError("Unexpected EOF reading 8-byte CBOR arg".into()));
            }
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&buf[*offset..*offset + 8]);
            *offset += 8;
            let v = u64::from_be_bytes(arr);
            if v <= u32::MAX as u64 {
                return Err(NfcError::SerializationError("Non-canonical 8-byte CBOR integer encoding".into()));
            }
            Ok(v)
        } else if info == 31 {
            Err(NfcError::SerializationError("Indefinite-length CBOR encoding is forbidden".into()))
        } else {
            Err(NfcError::SerializationError(format!("Reserved CBOR additional info {}", info)))
        }
    }

    fn walk_item(buf: &[u8], offset: &mut usize, depth: usize) -> Result<(), NfcError> {
        if depth > MAX_CBOR_DEPTH {
            return Err(NfcError::SerializationError(format!(
                "CBOR nesting depth {} exceeds maximum {}",
                depth, MAX_CBOR_DEPTH
            )));
        }
        if *offset >= buf.len() {
            return Err(NfcError::SerializationError("Unexpected EOF in CBOR item".into()));
        }
        let init = buf[*offset];
        *offset += 1;
        let major = init >> 5;
        let info = init & 0x1f;
        let val = read_arg(buf, offset, info)?;

        match major {
            0 => Ok(()), // Unsigned integer
            1 => Err(NfcError::SerializationError("Negative integers are not permitted in NfcEnvelope".into())),
            2 => {
                let len = usize::try_from(val)
                    .map_err(|_| NfcError::PayloadTooLarge(usize::MAX))?;
                if len > MAX_NFC_PAYLOAD_SIZE {
                    return Err(NfcError::PayloadTooLarge(len));
                }
                if *offset + len > buf.len() {
                    return Err(NfcError::SerializationError("Unexpected EOF in CBOR byte string".into()));
                }
                *offset += len;
                Ok(())
            }
            3 => {
                let len = usize::try_from(val)
                    .map_err(|_| NfcError::SerializationError("CBOR text string too large".into()))?;
                if len > 256 {
                    return Err(NfcError::SerializationError(format!(
                        "CBOR text string length {} exceeds 256-byte limit",
                        len
                    )));
                }
                if *offset + len > buf.len() {
                    return Err(NfcError::SerializationError("Unexpected EOF in CBOR text string".into()));
                }
                let slice = &buf[*offset..*offset + len];
                std::str::from_utf8(slice)
                    .map_err(|e| NfcError::SerializationError(format!("Invalid UTF-8 in CBOR text: {}", e)))?;
                *offset += len;
                Ok(())
            }
            4 => {
                let count = usize::try_from(val)
                    .map_err(|_| NfcError::PayloadTooLarge(usize::MAX))?;
                if count > MAX_NFC_PAYLOAD_SIZE {
                    return Err(NfcError::PayloadTooLarge(count));
                }
                for _ in 0..count {
                    walk_item(buf, offset, depth + 1)?;
                }
                Ok(())
            }
            5 => {
                let count = usize::try_from(val)
                    .map_err(|_| NfcError::SerializationError("CBOR map too large".into()))?;
                if count > 32 {
                    return Err(NfcError::SerializationError(format!(
                        "CBOR map entry count {} exceeds limit 32",
                        count
                    )));
                }
                let mut seen_keys = std::collections::HashSet::with_capacity(count);
                for _ in 0..count {
                    let key_start = *offset;
                    walk_item(buf, offset, depth + 1)?;
                    let key_raw = &buf[key_start..*offset];
                    if !seen_keys.insert(key_raw.to_vec()) {
                        return Err(NfcError::SerializationError(format!(
                            "Duplicate CBOR map key: {}",
                            hex::encode(key_raw)
                        )));
                    }
                    walk_item(buf, offset, depth + 1)?;
                }
                Ok(())
            }
            6 => Err(NfcError::SerializationError("CBOR semantic tags are not permitted in NfcEnvelope".into())),
            7 => Err(NfcError::SerializationError("CBOR floats/simple values are not permitted in NfcEnvelope".into())),
            _ => Err(NfcError::SerializationError(format!("Unknown CBOR major type {}", major))),
        }
    }

    let mut offset = 0usize;
    walk_item(raw_bytes, &mut offset, 0)?;
    if offset != raw_bytes.len() {
        return Err(NfcError::SerializationError(format!(
            "Trailing bytes after CBOR root value: {} extra byte(s)",
            raw_bytes.len() - offset
        )));
    }
    Ok(())
}

impl NfcEnvelope {
    pub fn validate_fields(&self) -> Result<(), NfcError> {
        if self.wire_version != PROTOCOL_WIRE_VERSION {
            return Err(NfcError::WireVersionMismatch {
                expected: PROTOCOL_WIRE_VERSION,
                got: self.wire_version,
            });
        }
        if self.session_id.is_empty() || self.session_id.len() > MAX_ID_STRING_LEN {
            return Err(NfcError::SerializationError(
                "session_id must be 1..=128 characters".into(),
            ));
        }
        if self.request_id.is_empty() || self.request_id.len() > MAX_ID_STRING_LEN {
            return Err(NfcError::SerializationError(
                "request_id must be 1..=128 characters".into(),
            ));
        }
        if self.total_chunks == 0 || self.total_chunks > MAX_CHUNKS || self.chunk_index >= self.total_chunks {
            return Err(NfcError::InvalidChunkSequence {
                index: self.chunk_index,
                total: self.total_chunks,
            });
        }
        if self.payload_digest.len() != 64 || !self.payload_digest.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(NfcError::SerializationError(
                "payload_digest must be exactly 64 hex characters (SHA-256)".into(),
            ));
        }
        if self.payload.is_empty() {
            return Err(NfcError::SerializationError(
                "Empty NFC chunk payload is forbidden".into(),
            ));
        }
        if self.payload.len() > MAX_NFC_PAYLOAD_SIZE {
            return Err(NfcError::PayloadTooLarge(self.payload.len()));
        }
        Ok(())
    }

    pub fn to_cbor(&self) -> Result<Vec<u8>, NfcError> {
        self.validate_fields()?;
        let mut buf = Vec::new();
        ciborium::into_writer(self, &mut buf)
            .map_err(|e| NfcError::SerializationError(e.to_string()))?;
        Ok(buf)
    }

    pub fn from_cbor(bytes: &[u8]) -> Result<Self, NfcError> {
        validate_strict_cbor(bytes)?;
        let env: Self = ciborium::from_reader(bytes)
            .map_err(|e| NfcError::SerializationError(e.to_string()))?;
        env.validate_fields()?;
        Ok(env)
    }
}

/// Tier-2 ISO 7816-4 Short APDU Framing for `NfcEnvelope` CBOR bytes.
/// Guarantees that every generated C-APDU has:
/// - `Lc <= max_apdu_data_len <= MAX_HCE_APDU_DATA_LEN` (128 bytes)
/// - Total C-APDU wire length `6 + Lc <= MAX_HCE_CAPDU_WIRE_LEN` (134 bytes) and `<= max_transceive_len`
pub fn encode_cbor_to_apdu_frames(
    cbor_bytes: &[u8],
    ins: u8,
    max_apdu_data_len: usize,
    max_transceive_len: usize,
) -> Result<Vec<Vec<u8>>, NfcError> {
    if cbor_bytes.is_empty() {
        return Err(NfcError::ApduFramingError("Cannot frame empty CBOR payload".into()));
    }
    if cbor_bytes.len() > MAX_ENVELOPE_CBOR_LEN {
        return Err(NfcError::ApduFramingError(format!(
            "Envelope CBOR length {} exceeds maximum {}",
            cbor_bytes.len(),
            MAX_ENVELOPE_CBOR_LEN
        )));
    }
    if max_apdu_data_len == 0 || max_apdu_data_len > MAX_HCE_APDU_DATA_LEN {
        return Err(NfcError::ApduFramingError(format!(
            "max_apdu_data_len {} exceeds HCE APDU data limit {}",
            max_apdu_data_len, MAX_HCE_APDU_DATA_LEN
        )));
    }
    if max_transceive_len < 6 + max_apdu_data_len {
        return Err(NfcError::ApduFramingError(format!(
            "IsoDep maxTransceiveLength {} is too small for APDU frame size {}",
            max_transceive_len,
            6 + max_apdu_data_len
        )));
    }

    let total_frames = (cbor_bytes.len() + max_apdu_data_len - 1) / max_apdu_data_len;
    if total_frames == 0 || total_frames > MAX_APDU_FRAMES_PER_ENVELOPE as usize {
        return Err(NfcError::ApduFramingError(format!(
            "Total APDU frames {} out of 1..={} range",
            total_frames, MAX_APDU_FRAMES_PER_ENVELOPE
        )));
    }

    let mut frames = Vec::with_capacity(total_frames);
    for idx in 0..total_frames {
        let start = idx * max_apdu_data_len;
        let end = std::cmp::min(start + max_apdu_data_len, cbor_bytes.len());
        let slice = &cbor_bytes[start..end];
        let lc = slice.len();
        let mut apdu = Vec::with_capacity(6 + lc);
        apdu.push(0x80); // CLA
        apdu.push(ins);  // INS
        apdu.push(idx as u8); // P1: 0-based frame index
        apdu.push(total_frames as u8); // P2: total frames for this envelope
        apdu.push(lc as u8); // Lc (1..=128)
        apdu.extend_from_slice(slice);
        apdu.push(0x00); // Le

        if lc > MAX_HCE_APDU_DATA_LEN || apdu.len() > MAX_HCE_CAPDU_WIRE_LEN || apdu.len() > max_transceive_len {
            return Err(NfcError::ApduFramingError(format!(
                "APDU frame wire length {} (Lc={}) violates bounds",
                apdu.len(),
                lc
            )));
        }
        frames.push(apdu);
    }
    Ok(frames)
}

/// Reassembles Tier-2 ISO 7816-4 short C-APDU frames back into a single `NfcEnvelope`.
#[derive(Debug, Default, Clone)]
pub struct ApduFrameAssembler {
    expected_ins: Option<u8>,
    total_frames: u8,
    received_frames: Vec<Option<Vec<u8>>>,
    received_count: u8,
    buffered_bytes: usize,
}

impl ApduFrameAssembler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        self.expected_ins = None;
        self.total_frames = 0;
        self.received_frames.clear();
        self.received_count = 0;
        self.buffered_bytes = 0;
    }

    pub fn buffered_wire_bytes(&self) -> usize {
        self.buffered_bytes + self.received_frames.capacity() * 24
    }

    /// Processes a single ISO 7816-4 short C-APDU `[CLA, INS, P1, P2, Lc, ...data, Le]`.
    /// Returns `Ok(Some(NfcEnvelope))` when all frames of the envelope have arrived,
    /// `Ok(None)` when more frames are expected, or `Err(NfcError)` on any violation.
    pub fn accept_apdu(&mut self, capdu: &[u8]) -> Result<Option<NfcEnvelope>, NfcError> {
        if capdu.len() < 7 || capdu.len() > MAX_HCE_CAPDU_WIRE_LEN {
            self.reset();
            return Err(NfcError::ApduFramingError(format!(
                "Invalid C-APDU wire length {} (must be 7..={})",
                capdu.len(),
                MAX_HCE_CAPDU_WIRE_LEN
            )));
        }
        let cla = capdu[0];
        let ins = capdu[1];
        let p1_idx = capdu[2];
        let p2_total = capdu[3];
        let lc = capdu[4] as usize;
        let le = capdu[capdu.len() - 1];

        if cla != 0x80 {
            self.reset();
            return Err(NfcError::ApduFramingError(format!("Invalid CLA 0x{:02x}", cla)));
        }
        if lc == 0 || lc > MAX_HCE_APDU_DATA_LEN || capdu.len() != 6 + lc || le != 0x00 {
            self.reset();
            return Err(NfcError::ApduFramingError(format!(
                "Invalid C-APDU Lc={} / wire_len={} / Le=0x{:02x}",
                lc,
                capdu.len(),
                le
            )));
        }
        if p2_total == 0 || p2_total > MAX_APDU_FRAMES_PER_ENVELOPE || p1_idx >= p2_total {
            self.reset();
            return Err(NfcError::ApduFramingError(format!(
                "Invalid APDU frame sequence P1={} P2={} (max frames={})",
                p1_idx, p2_total, MAX_APDU_FRAMES_PER_ENVELOPE
            )));
        }

        if p1_idx == 0 && self.received_count == 0 {
            self.expected_ins = Some(ins);
            self.total_frames = p2_total;
            self.received_frames = vec![None; p2_total as usize];
            self.buffered_bytes = 0;
        } else if self.expected_ins != Some(ins) || self.total_frames != p2_total {
            self.reset();
            return Err(NfcError::ApduFramingError(
                "APDU frame header mismatch mid-envelope".into(),
            ));
        }

        let data = capdu[5..5 + lc].to_vec();
        let slot = &mut self.received_frames[p1_idx as usize];
        if let Some(existing) = slot {
            if existing != &data {
                self.reset();
                return Err(NfcError::ApduFramingError(format!(
                    "Conflicting duplicate APDU frame at index {}",
                    p1_idx
                )));
            }
        } else {
            if self.buffered_bytes + data.len() > MAX_ENVELOPE_CBOR_LEN {
                self.reset();
                return Err(NfcError::ApduFramingError(format!(
                    "Reassembled APDU CBOR exceeds maximum {} bytes",
                    MAX_ENVELOPE_CBOR_LEN
                )));
            }
            self.buffered_bytes += data.len();
            *slot = Some(data);
            self.received_count += 1;
        }

        if self.received_count < self.total_frames {
            return Ok(None);
        }

        let mut cbor_bytes = Vec::with_capacity(self.buffered_bytes);
        for f in self.received_frames.drain(..) {
            cbor_bytes.extend_from_slice(&f.unwrap());
        }
        self.reset();
        let env = NfcEnvelope::from_cbor(&cbor_bytes)?;
        Ok(Some(env))
    }
}

pub struct FragmentAssembler {
    pub wire_version: u16,
    pub message_kind: MessageKind,
    pub session_id: String,
    pub request_id: String,
    pub total_chunks: u32,
    pub expected_digest: String,
    chunks: Vec<Option<Vec<u8>>>,
    received_count: u32,
    total_bytes: usize,
    pub created_at_ms: u64,
    pub last_updated_ms: u64,
}

impl FragmentAssembler {
    pub fn new(first_envelope: &NfcEnvelope) -> Result<Self, NfcError> {
        Self::new_at(first_envelope, 0)
    }

    pub fn new_at(first_envelope: &NfcEnvelope, now_ms: u64) -> Result<Self, NfcError> {
        if first_envelope.wire_version != PROTOCOL_WIRE_VERSION {
            return Err(NfcError::WireVersionMismatch {
                expected: PROTOCOL_WIRE_VERSION,
                got: first_envelope.wire_version,
            });
        }
        if first_envelope.total_chunks == 0 || first_envelope.total_chunks > MAX_CHUNKS {
            return Err(NfcError::InvalidChunkSequence {
                index: first_envelope.chunk_index,
                total: first_envelope.total_chunks,
            });
        }
        first_envelope.validate_fields()?;
        let total = first_envelope.total_chunks;
        let mut assembler = Self {
            wire_version: first_envelope.wire_version,
            message_kind: first_envelope.message_kind,
            session_id: first_envelope.session_id.clone(),
            request_id: first_envelope.request_id.clone(),
            total_chunks: total,
            expected_digest: first_envelope.payload_digest.clone(),
            chunks: vec![None; total as usize],
            received_count: 0,
            total_bytes: 0,
            created_at_ms: now_ms,
            last_updated_ms: now_ms,
        };
        assembler.add_chunk_at(first_envelope, now_ms)?;
        Ok(assembler)
    }

    pub fn add_chunk(&mut self, env: &NfcEnvelope) -> Result<bool, NfcError> {
        self.add_chunk_at(env, self.last_updated_ms)
    }

    pub fn add_chunk_at(&mut self, env: &NfcEnvelope, now_ms: u64) -> Result<bool, NfcError> {
        if env.wire_version != PROTOCOL_WIRE_VERSION || env.wire_version != self.wire_version {
            return Err(NfcError::WireVersionMismatch {
                expected: PROTOCOL_WIRE_VERSION,
                got: env.wire_version,
            });
        }
        if env.message_kind != self.message_kind {
            return Err(NfcError::MessageKindMismatch {
                expected: self.message_kind,
                got: env.message_kind,
            });
        }
        if env.session_id != self.session_id {
            return Err(NfcError::SessionMismatch {
                expected: self.session_id.clone(),
                got: env.session_id.clone(),
            });
        }
        if env.request_id != self.request_id {
            return Err(NfcError::RequestIdMismatch {
                expected: self.request_id.clone(),
                got: env.request_id.clone(),
            });
        }
        if !env.payload_digest.eq_ignore_ascii_case(&self.expected_digest) {
            return Err(NfcError::DigestCommitmentMismatch {
                expected: self.expected_digest.clone(),
                got: env.payload_digest.clone(),
            });
        }
        if env.total_chunks != self.total_chunks || env.chunk_index >= self.total_chunks {
            return Err(NfcError::InvalidChunkSequence {
                index: env.chunk_index,
                total: env.total_chunks,
            });
        }
        env.validate_fields()?;

        let idx = env.chunk_index as usize;
        if let Some(existing) = &self.chunks[idx] {
            if existing != &env.payload {
                return Err(NfcError::ConflictingDuplicateChunk {
                    index: env.chunk_index,
                });
            }
            // Identical duplicate chunk: DO NOT advance `last_updated_ms` so duplicate chunks
            // can never extend the TTL of an incomplete/expiring session.
        } else {
            let next_total = self.total_bytes + env.payload.len();
            if next_total > MAX_NFC_PAYLOAD_SIZE {
                return Err(NfcError::PayloadTooLarge(next_total));
            }
            self.total_bytes = next_total;
            self.chunks[idx] = Some(env.payload.clone());
            self.received_count += 1;
            self.last_updated_ms = now_ms;
        }

        Ok(self.received_count == self.total_chunks)
    }

    pub fn buffered_bytes(&self) -> usize {
        self.total_bytes
    }

    pub fn metadata_and_slot_bytes(&self) -> usize {
        self.session_id.len()
            + self.request_id.len()
            + self.expected_digest.len()
            + (self.total_chunks as usize).saturating_mul(24)
            + 64
    }

    pub fn footprint_bytes(&self) -> usize {
        self.total_bytes.saturating_add(self.metadata_and_slot_bytes())
    }

    pub fn is_complete(&self) -> bool {
        self.received_count == self.total_chunks
    }

    pub fn finalize(self) -> Result<Vec<u8>, NfcError> {
        if !self.is_complete() {
            return Err(NfcError::IncompleteAssembly {
                received: self.received_count,
                total: self.total_chunks,
            });
        }

        let mut full_payload = Vec::with_capacity(self.total_bytes);
        for chunk_opt in self.chunks {
            if let Some(c) = chunk_opt {
                full_payload.extend_from_slice(&c);
            } else {
                return Err(NfcError::IncompleteAssembly {
                    received: self.received_count,
                    total: self.total_chunks,
                });
            }
        }

        // Verify SHA-256 digest
        let calculated_digest = sha256_hex(&full_payload);
        if !calculated_digest.eq_ignore_ascii_case(&self.expected_digest) {
            return Err(NfcError::DigestMismatch {
                calculated: calculated_digest,
                declared: self.expected_digest,
            });
        }

        Ok(full_payload)
    }
}

#[derive(Debug, Clone)]
pub struct CompletedHistoryEntry {
    pub key: (String, String, u8),
    pub completed_at_ms: u64,
    pub entry_bytes: usize,
}

#[derive(Debug, Clone)]
pub struct CachedResponseEntry {
    pub session_id: String,
    pub request_id: String,
    pub payload_sha256: String,
    pub response_frames: Vec<Vec<u8>>,
    pub cached_at_ms: u64,
    pub total_bytes: usize,
}

fn replay_fingerprint_128(session_id: &str, request_id: &str, kind: u8) -> [u8; 16] {
    let mut hasher = Sha256::new();
    hasher.update(b"FCW_REPLAY_V1:");
    hasher.update((session_id.len() as u32).to_be_bytes());
    hasher.update(session_id.as_bytes());
    hasher.update((request_id.len() as u32).to_be_bytes());
    hasher.update(request_id.as_bytes());
    hasher.update([kind]);
    let digest = hasher.finalize();
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest[0..16]);
    out
}

fn bloom_insert(bloom: &mut [u64; 64], fp: &[u8; 16]) {
    for i in 0..4 {
        let off = i * 4;
        let word = u32::from_be_bytes([fp[off], fp[off + 1], fp[off + 2], fp[off + 3]]);
        let bit_idx = (word as usize) & 4095; // 64 * 64 = 4096 bits
        bloom[bit_idx >> 6] |= 1u64 << (bit_idx & 63);
    }
}

fn bloom_contains(bloom: &[u64; 64], fp: &[u8; 16]) -> bool {
    for i in 0..4 {
        let off = i * 4;
        let word = u32::from_be_bytes([fp[off], fp[off + 1], fp[off + 2], fp[off + 3]]);
        let bit_idx = (word as usize) & 4095;
        if (bloom[bit_idx >> 6] & (1u64 << (bit_idx & 63))) == 0 {
            return false;
        }
    }
    true
}

/// Session lifecycle manager with bounded concurrency (`MAX_CONCURRENT_SESSIONS`),
/// bounded total buffered memory (`MAX_GLOBAL_SESSION_BYTES`), bounded TTL expiration,
/// fatal-error session eviction, bounded `completed_messages` history (capacity + byte budget + TTL),
/// bounded `response_cache`, and fixed-memory cryptographic replay/retired-session rejection across eviction.
pub struct SessionManager {
    pub assemblers: std::collections::HashMap<String, FragmentAssembler>,
    pub completed_messages: std::collections::HashSet<(String, String, u8)>,
    pub completed_order: std::collections::VecDeque<CompletedHistoryEntry>,
    pub completed_history_bytes: usize,
    pub max_completed_history: usize,
    pub max_completed_history_bytes: usize,
    pub completed_ttl_ms: u64,
    pub evicted_replay_bloom: [u64; 64],
    pub evicted_exact_ring: std::collections::VecDeque<[u8; 16]>,
    pub evicted_completed_count: u64,
    pub evicted_high_water_ms: u64,
    pub response_cache: std::collections::VecDeque<CachedResponseEntry>,
    pub response_cache_bytes: usize,
    pub max_cached_responses: usize,
    pub max_cached_response_bytes: usize,
    pub response_cache_ttl_ms: u64,
    pub ttl_ms: u64,
    pub max_sessions: usize,
    pub max_global_bytes: usize,
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new(MAX_CONCURRENT_SESSIONS, MAX_GLOBAL_SESSION_BYTES, DEFAULT_SESSION_TTL_MS)
    }
}

impl SessionManager {
    pub fn new(max_sessions: usize, max_global_bytes: usize, ttl_ms: u64) -> Self {
        Self {
            assemblers: std::collections::HashMap::new(),
            completed_messages: std::collections::HashSet::new(),
            completed_order: std::collections::VecDeque::new(),
            completed_history_bytes: 0,
            max_completed_history: MAX_COMPLETED_HISTORY_ENTRIES,
            max_completed_history_bytes: MAX_COMPLETED_HISTORY_BYTES,
            completed_ttl_ms: DEFAULT_COMPLETED_HISTORY_TTL_MS,
            evicted_replay_bloom: [0u64; 64],
            evicted_exact_ring: std::collections::VecDeque::new(),
            evicted_completed_count: 0,
            evicted_high_water_ms: 0,
            response_cache: std::collections::VecDeque::new(),
            response_cache_bytes: 0,
            max_cached_responses: MAX_CACHED_RESPONSES,
            max_cached_response_bytes: MAX_CACHED_RESPONSE_BYTES,
            response_cache_ttl_ms: DEFAULT_RESPONSE_CACHE_TTL_MS,
            ttl_ms,
            max_sessions,
            max_global_bytes,
        }
    }

    pub fn with_history_bounds(
        mut self,
        max_completed_history: usize,
        max_completed_history_bytes: usize,
        completed_ttl_ms: u64,
    ) -> Self {
        self.max_completed_history = max_completed_history.max(1);
        self.max_completed_history_bytes = max_completed_history_bytes.max(128);
        self.completed_ttl_ms = completed_ttl_ms.max(1);
        self
    }

    pub fn total_buffered_bytes(&self) -> usize {
        self.assemblers.values().map(|a| a. buffered_bytes()).sum()
    }

    pub fn total_footprint_bytes(&self) -> usize {
        self.assemblers.values().map(|a| a.footprint_bytes()).sum()
    }

    fn record_evicted_or_retired_fingerprint(
        bloom: &mut [u64; 64],
        ring: &mut std::collections::VecDeque<[u8; 16]>,
        evicted_count: &mut u64,
        high_water_ms: &mut u64,
        session_id: &str,
        request_id: &str,
        kind: u8,
        now_ms: u64,
    ) {
        let fp = replay_fingerprint_128(session_id, request_id, kind);
        bloom_insert(bloom, &fp);
        if ring.len() >= MAX_EVICTED_FINGERPRINT_RING {
            ring.pop_front();
        }
        ring.push_back(fp);
        *evicted_count = evicted_count.saturating_add(1);
        if now_ms > *high_water_ms {
            *high_water_ms = now_ms;
        }
    }

    fn is_evicted_or_retired(&self, session_id: &str, request_id: &str, kind: u8) -> bool {
        if self.evicted_completed_count == 0 {
            return false;
        }
        let fp = replay_fingerprint_128(session_id, request_id, kind);
        if self.evicted_exact_ring.contains(&fp) {
            return true;
        }
        bloom_contains(&self.evicted_replay_bloom, &fp)
    }

    fn record_completed_message(&mut self, key: (String, String, u8), now_ms: u64) {
        self.evict_expired_completed_history(now_ms);
        let entry_bytes = key.0.len() + key.1.len() + 32;

        while (self.completed_order.len() >= self.max_completed_history
            || self.completed_history_bytes + entry_bytes > self.max_completed_history_bytes)
            && !self.completed_order.is_empty()
        {
            if let Some(old) = self.completed_order.pop_front() {
                self.completed_messages.remove(&old.key);
                self.completed_history_bytes =
                    self.completed_history_bytes.saturating_sub(old.entry_bytes);
                Self::record_evicted_or_retired_fingerprint(
                    &mut self.evicted_replay_bloom,
                    &mut self.evicted_exact_ring,
                    &mut self.evicted_completed_count,
                    &mut self.evicted_high_water_ms,
                    &old.key.0,
                    &old.key.1,
                    old.key.2,
                    now_ms,
                );
            }
        }

        if self.completed_messages.insert(key.clone()) {
            self.completed_history_bytes += entry_bytes;
            self.completed_order.push_back(CompletedHistoryEntry {
                key,
                completed_at_ms: now_ms,
                entry_bytes,
            });
        }
    }

    pub fn evict_expired_completed_history(&mut self, now_ms: u64) -> usize {
        let ttl = self.completed_ttl_ms;
        let mut evicted = 0usize;
        while let Some(front) = self.completed_order.front() {
            if now_ms.saturating_sub(front.completed_at_ms) > ttl {
                let old = self.completed_order.pop_front().unwrap();
                self.completed_messages.remove(&old.key);
                self.completed_history_bytes =
                    self.completed_history_bytes.saturating_sub(old.entry_bytes);
                Self::record_evicted_or_retired_fingerprint(
                    &mut self.evicted_replay_bloom,
                    &mut self.evicted_exact_ring,
                    &mut self.evicted_completed_count,
                    &mut self.evicted_high_water_ms,
                    &old.key.0,
                    &old.key.1,
                    old.key.2,
                    now_ms,
                );
                evicted += 1;
            } else {
                break;
            }
        }
        evicted
    }

    pub fn cache_response(
        &mut self,
        session_id: String,
        request_id: String,
        payload_sha256: String,
        response_frames: Vec<Vec<u8>>,
        now_ms: u64,
    ) -> Result<(), NfcError> {
        self.evict_expired_responses(now_ms);
        let frame_bytes: usize = response_frames.iter().map(|f| f.len() + 16).sum();
        let total_bytes = session_id.len() + request_id.len() + payload_sha256.len() + frame_bytes + 48;
        if total_bytes > self.max_cached_response_bytes {
            return Err(NfcError::SessionLifecycleError(format!(
                "Response cache entry {} bytes exceeds budget {} bytes",
                total_bytes, self.max_cached_response_bytes
            )));
        }
        while (self.response_cache.len() >= self.max_cached_responses
            || self.response_cache_bytes + total_bytes > self.max_cached_response_bytes)
            && !self.response_cache.is_empty()
        {
            if let Some(old) = self.response_cache.pop_front() {
                self.response_cache_bytes = self.response_cache_bytes.saturating_sub(old.total_bytes);
            }
        }
        self.response_cache_bytes += total_bytes;
        self.response_cache.push_back(CachedResponseEntry {
            session_id,
            request_id,
            payload_sha256,
            response_frames,
            cached_at_ms: now_ms,
            total_bytes,
        });
        Ok(())
    }

    pub fn evict_expired_responses(&mut self, now_ms: u64) -> usize {
        let ttl = self.response_cache_ttl_ms;
        let mut evicted = 0usize;
        while let Some(front) = self.response_cache.front() {
            if now_ms.saturating_sub(front.cached_at_ms) > ttl {
                let old = self.response_cache.pop_front().unwrap();
                self.response_cache_bytes = self.response_cache_bytes.saturating_sub(old.total_bytes);
                evicted += 1;
            } else {
                break;
            }
        }
        evicted
    }

    pub fn evict_expired(&mut self, now_ms: u64) -> usize {
        let ttl = self.ttl_ms;
        let max_lifetime = ttl.saturating_mul(2);
        let mut expired_keys = Vec::new();
        for (sess_id, asm) in &self.assemblers {
            if now_ms.saturating_sub(asm.last_updated_ms) > ttl
                || now_ms.saturating_sub(asm.created_at_ms) > max_lifetime
            {
                expired_keys.push((
                    sess_id.clone(),
                    asm.request_id.clone(),
                    asm.message_kind as u8,
                ));
            }
        }
        let count = expired_keys.len();
        for (sess_id, req_id, kind) in expired_keys {
            self.assemblers.remove(&sess_id);
            Self::record_evicted_or_retired_fingerprint(
                &mut self.evicted_replay_bloom,
                &mut self.evicted_exact_ring,
                &mut self.evicted_completed_count,
                &mut self.evicted_high_water_ms,
                &sess_id,
                &req_id,
                kind,
                now_ms,
            );
        }
        self.evict_expired_completed_history(now_ms);
        self.evict_expired_responses(now_ms);
        count
    }

    pub fn cancel_session(&mut self, session_id: &str) -> bool {
        if let Some(asm) = self.assemblers.remove(session_id) {
            Self::record_evicted_or_retired_fingerprint(
                &mut self.evicted_replay_bloom,
                &mut self.evicted_exact_ring,
                &mut self.evicted_completed_count,
                &mut self.evicted_high_water_ms,
                &asm.session_id,
                &asm.request_id,
                asm.message_kind as u8,
                asm.last_updated_ms,
            );
            true
        } else {
            false
        }
    }

    pub fn clear_all(&mut self) {
        self.assemblers.clear();
        self.completed_messages.clear();
        self.completed_order.clear();
        self.completed_history_bytes = 0;
        self.evicted_replay_bloom = [0u64; 64];
        self.evicted_exact_ring.clear();
        self.evicted_completed_count = 0;
        self.evicted_high_water_ms = 0;
        self.response_cache.clear();
        self.response_cache_bytes = 0;
    }

    pub fn process_envelope(
        &mut self,
        env: &NfcEnvelope,
        now_ms: u64,
    ) -> Result<Option<(String, String, MessageKind, Vec<u8>)>, NfcError> {
        self.evict_expired(now_ms);

        let replay_key = (env.session_id.clone(), env.request_id.clone(), env.message_kind as u8);
        if self.completed_messages.contains(&replay_key)
            || self.is_evicted_or_retired(&env.session_id, &env.request_id, env.message_kind as u8)
        {
            return Err(NfcError::SessionLifecycleError(format!(
                "Replayed NFC message rejected for session={} request={}",
                env.session_id, env.request_id
            )));
        }

        let current_global_bytes = self.total_buffered_bytes();
        let existing_session_bytes = self
            .assemblers
            .get(&env.session_id)
            .map(|a| a.buffered_bytes())
            .unwrap_or(0);

        if !self.assemblers.contains_key(&env.session_id) && self.assemblers.len() >= self.max_sessions {
            return Err(NfcError::SessionLifecycleError(format!(
                "Global NFC session capacity exceeded (max {})",
                self.max_sessions
            )));
        }

        let is_complete = if let Some(assembler) = self.assemblers.get_mut(&env.session_id) {
            match assembler.add_chunk_at(env, now_ms) {
                Ok(comp) => {
                    let added_bytes = assembler.buffered_bytes().saturating_sub(existing_session_bytes);
                    if current_global_bytes + added_bytes > self.max_global_bytes {
                        let failed = self.assemblers.remove(&env.session_id).unwrap();
                        Self::record_evicted_or_retired_fingerprint(
                            &mut self.evicted_replay_bloom,
                            &mut self.evicted_exact_ring,
                            &mut self.evicted_completed_count,
                            &mut self.evicted_high_water_ms,
                            &failed.session_id,
                            &failed.request_id,
                            failed.message_kind as u8,
                            now_ms,
                        );
                        return Err(NfcError::SessionLifecycleError(format!(
                            "Global NFC session memory budget exceeded (max {} bytes)",
                            self.max_global_bytes
                        )));
                    }
                    comp
                }
                Err(e) => {
                    // Evict corrupted/failed session on fatal chunk error so it cannot block capacity
                    if let Some(failed) = self.assemblers.remove(&env.session_id) {
                        Self::record_evicted_or_retired_fingerprint(
                            &mut self.evicted_replay_bloom,
                            &mut self.evicted_exact_ring,
                            &mut self.evicted_completed_count,
                            &mut self.evicted_high_water_ms,
                            &failed.session_id,
                            &failed.request_id,
                            failed.message_kind as u8,
                            now_ms,
                        );
                    }
                    return Err(e);
                }
            }
        } else {
            if current_global_bytes + env.payload.len() > self.max_global_bytes {
                return Err(NfcError::SessionLifecycleError(format!(
                    "Global NFC session memory budget exceeded (max {} bytes)",
                    self.max_global_bytes
                )));
            }
            let assembler = FragmentAssembler::new_at(env, now_ms)?;
            let comp = assembler.is_complete();
            self.assemblers.insert(env.session_id.clone(), assembler);
            comp
        };

        if !is_complete {
            return Ok(None);
        }

        let assembler = self.assemblers.remove(&env.session_id).unwrap();
        let verified_sess_id = assembler.session_id.clone();
        let verified_req_id = assembler.request_id.clone();
        let verified_kind = assembler.message_kind;
        let payload = assembler.finalize()?;
        self.record_completed_message(
            (verified_sess_id.clone(), verified_req_id.clone(), verified_kind as u8),
            now_ms,
        );
        Ok(Some((verified_sess_id, verified_req_id, verified_kind, payload)))
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_nfc_chunking_and_reassembly() {
        let payload = vec![0xAB; 1000];
        let digest = sha256_hex(&payload);

        let chunk1 = NfcEnvelope {
            wire_version: PROTOCOL_WIRE_VERSION,
            message_kind: MessageKind::SignRequest,
            session_id: "sess-01".into(),
            request_id: "req-01".into(),
            chunk_index: 0,
            total_chunks: 2,
            payload_digest: digest.clone(),
            payload: payload[0..500].to_vec(),
        };

        let chunk2 = NfcEnvelope {
            wire_version: PROTOCOL_WIRE_VERSION,
            message_kind: MessageKind::SignRequest,
            session_id: "sess-01".into(),
            request_id: "req-01".into(),
            chunk_index: 1,
            total_chunks: 2,
            payload_digest: digest.clone(),
            payload: payload[500..1000].to_vec(),
        };

        let mut assembler = FragmentAssembler::new(&chunk1).unwrap();
        assert!(!assembler.is_complete());

        let complete = assembler.add_chunk(&chunk2).unwrap();
        assert!(complete);
        assert!(assembler.is_complete());

        let assembled = assembler.finalize().unwrap();
        assert_eq!(assembled, payload);
    }

    #[test]
    fn test_nfc_session_mismatch_rejected() {
        let payload = vec![0xAB; 200];
        let digest = sha256_hex(&payload);

        let chunk1 = NfcEnvelope {
            wire_version: PROTOCOL_WIRE_VERSION,
            message_kind: MessageKind::SignRequest,
            session_id: "sess-A".into(),
            request_id: "req-01".into(),
            chunk_index: 0,
            total_chunks: 2,
            payload_digest: digest.clone(),
            payload: payload[0..100].to_vec(),
        };

        let chunk2_bad_session = NfcEnvelope {
            wire_version: PROTOCOL_WIRE_VERSION,
            message_kind: MessageKind::SignRequest,
            session_id: "sess-B".into(), // Wrong session!
            request_id: "req-01".into(),
            chunk_index: 1,
            total_chunks: 2,
            payload_digest: digest.clone(),
            payload: payload[100..200].to_vec(),
        };

        let mut assembler = FragmentAssembler::new(&chunk1).unwrap();
        let err = assembler.add_chunk(&chunk2_bad_session).unwrap_err();
        assert!(matches!(err, NfcError::SessionMismatch { .. }));
    }
}
