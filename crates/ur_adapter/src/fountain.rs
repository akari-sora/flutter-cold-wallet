use crate::error::UrError;
use crate::{BoundedCborParser, MAX_ALLOWED_PAYLOAD};
use std::collections::HashMap;
use ur::Decoder;

pub const MAX_UR_FRAME_CHARS: usize = 8192;
pub const MAX_UR_FRAMES: usize = 512;
pub const MAX_UR_SESSION_CHARS: usize = 2_097_152;
// Lowercase ASCII UR uses byte mode in qr_flutter at ECC M. Version 40
// supports 2,331 bytes; scanner wire bounds intentionally remain separate.
pub const MAX_UR_DISPLAY_CHARS: usize = 2331;

pub fn displayable_single_ur(ur_type: &str, cbor_bytes: &[u8]) -> Option<String> {
    if validate_payload_size(cbor_bytes).is_err() {
        return None;
    }
    let clean_type = ur_type.trim().to_lowercase();
    if clean_type.is_empty() || clean_type.len() > 80
        || !clean_type.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return None;
    }
    let frame_chars = cbor_bytes.len().checked_add(4)?.checked_mul(2)?
        .checked_add(clean_type.len())?.checked_add(4)?;
    if frame_chars > MAX_UR_DISPLAY_CHARS {
        return None;
    }
    Some(format!("ur:{}/{}", clean_type,
        ur::bytewords::encode(cbor_bytes, ur::bytewords::Style::Minimal)))
}

/// Default QR density grows only when needed to fit the bounded session.
pub fn default_fragment_len(cbor_bytes: &[u8]) -> Result<usize, UrError> {
    validate_payload_size(cbor_bytes)?;
    Ok(120.max(cbor_bytes.len().div_ceil(MAX_UR_FRAMES)))
}

fn validate_payload_size(cbor_bytes: &[u8]) -> Result<(), UrError> {
    if cbor_bytes.is_empty() || cbor_bytes.len() > MAX_ALLOWED_PAYLOAD {
        return Err(UrError::UrCodec("UR payload must contain 1 through 131,072 bytes".into()));
    }
    Ok(())
}

pub struct UrSession {
    expected_type: String,
    decoder: Decoder,
    complete: bool,
    metadata: Option<(u64, u64, u64, usize)>,
    frames: HashMap<u64, String>,
    session_chars: usize,
}

impl UrSession {
    pub fn new(expected_type: &str) -> Self {
        Self {
            expected_type: expected_type.to_lowercase(),
            decoder: Decoder::default(),
            complete: false,
            metadata: None,
            frames: HashMap::new(),
            session_chars: 0,
        }
    }

    pub fn receive(&mut self, frame: &str) -> Result<Option<Vec<u8>>, UrError> {
        if frame.len() > MAX_UR_FRAME_CHARS {
            return Err(UrError::UrCodec("UR frame exceeds limit".into()));
        }
        let normalized = frame.trim().to_ascii_lowercase();
        let clean = normalized.as_str();
        if self.complete {
            return Err(UrError::UrCodec(
                "UR session already complete; reset before scanning".into(),
            ));
        }
        if !clean.to_lowercase().starts_with("ur:") {
            return Err(UrError::UrCodec("Invalid UR schema prefix".into()));
        }

        let parts: Vec<&str> = clean[3..].split('/').collect();
        if parts.is_empty() {
            return Err(UrError::UrCodec("Empty UR path segments".into()));
        }

        let frame_type = parts[0].to_lowercase();
        if frame_type != self.expected_type {
            return Err(UrError::TypeMismatch {
                expected: self.expected_type.clone(),
                got: frame_type,
            });
        }

        // Single-part check: ur:<type>/<bytewords>
        if parts.len() == 2 {
            let (ur_type, message) =
                ur::decode(clean).map_err(|e| UrError::UrCodec(e.to_string()))?;
            if self.metadata.is_some() {
                return Err(UrError::UrCodec(
                    "Cannot splice single and multipart UR sessions".into(),
                ));
            }
            if ur_type == ur::ur::Kind::SinglePart
                && !message.is_empty()
                && message.len() <= MAX_ALLOWED_PAYLOAD
            {
                self.complete = true;
                return Ok(Some(message));
            }
        }

        // Multi-part fountain check: ur:<type>/<seq_num>-<seq_len>/<bytewords>
        if parts.len() == 3 {
            // Validate bounded metadata BEFORE the fountain library allocates state.
            let (_, decoded) = ur::decode(clean).map_err(|e| UrError::UrCodec(e.to_string()))?;
            let value = BoundedCborParser::parse(&decoded)?;
            let fields = value.as_array()?;
            if fields.len() != 5 {
                return Err(UrError::UrCodec("Invalid fountain metadata".into()));
            }
            let seq = fields[0].as_u64()?;
            let count = fields[1].as_u64()?;
            let length = fields[2].as_u64()?;
            let checksum = fields[3].as_u64()?;
            let fragment_len = fields[4].as_bytes()?.len();
            if seq == 0
                || seq > u32::MAX as u64
                || count == 0
                || count > MAX_UR_FRAMES as u64
                || length == 0
                || length > MAX_ALLOWED_PAYLOAD as u64
                || checksum > u32::MAX as u64
                || fragment_len == 0
                || fragment_len > MAX_UR_FRAME_CHARS / 2
                || length > count * fragment_len as u64
                || length <= (count - 1) * fragment_len as u64
            {
                return Err(UrError::UrCodec(
                    "Fountain metadata exceeds limits or is inconsistent".into(),
                ));
            }
            let metadata = (count, length, checksum, fragment_len);
            if self.metadata.is_some_and(|m| m != metadata) {
                return Err(UrError::UrCodec("Mixed fountain sessions".into()));
            }
            if let Some(previous) = self.frames.get(&seq) {
                if previous != clean {
                    return Err(UrError::UrCodec("Conflicting fountain sequence".into()));
                }
                return Ok(None);
            }
            if self.frames.len() >= MAX_UR_FRAMES
                || self.session_chars + clean.len() > MAX_UR_SESSION_CHARS
            {
                return Err(UrError::UrCodec(
                    "UR session exceeds frame or byte limit".into(),
                ));
            }
            self.decoder
                .receive(clean)
                .map_err(|e| UrError::UrCodec(e.to_string()))?;
            self.metadata = Some(metadata);
            self.session_chars += clean.len();
            self.frames.insert(seq, clean.to_string());

            if self.decoder.complete() {
                self.complete = true;
                let message = self
                    .decoder
                    .message()
                    .map_err(|e| UrError::UrCodec(e.to_string()))?
                    .ok_or_else(|| UrError::UrCodec("Decoded message empty".into()))?;
                return Ok(Some(message));
            }
            return Ok(None);
        }

        Err(UrError::UrCodec(format!(
            "Invalid UR segment count: {}",
            parts.len()
        )))
    }

    pub fn is_complete(&self) -> bool {
        self.complete
    }

    pub fn total_fragments(&self) -> usize {
        if self.complete && self.metadata.is_none() {
            1
        } else {
            self.decoder.fragment_count()
        }
    }

    pub fn resolved_fragments(&self) -> usize {
        if self.complete && self.metadata.is_none() {
            1
        } else {
            self.decoder.resolved_fragment_count().unwrap_or(0)
        }
    }

    pub fn reset(&mut self) {
        self.decoder = Decoder::default();
        self.complete = false;
        self.metadata = None;
        self.frames.clear();
        self.session_chars = 0;
    }
}

pub fn encode_ur_fountain_frames(
    ur_type: &str,
    cbor_bytes: &[u8],
    max_fragment_len: usize,
) -> Result<Vec<String>, UrError> {
    validate_payload_size(cbor_bytes)?;
    let clean_type = ur_type.trim().to_lowercase();
    if clean_type.is_empty() || clean_type.len() > 80
        || !clean_type.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(UrError::UrCodec("Invalid UR type".into()));
    }
    if max_fragment_len == 0 || cbor_bytes.len() <= max_fragment_len {
        let single = displayable_single_ur(&clean_type, cbor_bytes)
            .ok_or_else(|| UrError::UrCodec("Single UR exceeds QR display capacity; use fountain fragments".into()))?;
        return Ok(vec![single]);
    }

    if cbor_bytes.len().div_ceil(max_fragment_len) > MAX_UR_FRAMES {
        return Err(UrError::UrCodec("Requested fragment size exceeds the 512-frame session limit".into()));
    }
    let mut encoder = ur::Encoder::new(cbor_bytes, max_fragment_len, &clean_type)
        .map_err(|e| UrError::UrCodec(e.to_string()))?;
    let frag_count = encoder.fragment_count();
    if frag_count > MAX_UR_FRAMES {
        return Err(UrError::UrCodec("Requested fragment size exceeds the 512-frame session limit".into()));
    }
    if frag_count <= 1 {
        let single = displayable_single_ur(&clean_type, cbor_bytes)
            .ok_or_else(|| UrError::UrCodec("Single UR exceeds QR display capacity; use fountain fragments".into()))?;
        return Ok(vec![single]);
    }

    let total_frames = (frag_count * 2).max(frag_count + 2).min(MAX_UR_FRAMES);
    let mut frames = Vec::with_capacity(total_frames);
    let mut session_chars = 0;
    for _ in 0..total_frames {
        let part = encoder
            .next_part()
            .map_err(|e| UrError::UrCodec(e.to_string()))?;
        session_chars += part.len();
        if part.len() > MAX_UR_DISPLAY_CHARS || session_chars > MAX_UR_SESSION_CHARS {
            return Err(UrError::UrCodec("Encoded UR frames exceed session limits".into()));
        }
        frames.push(part);
    }
    Ok(frames)
}

pub fn decode_ur_frames(expected_type: &str, frames: &[String]) -> Result<Vec<u8>, UrError> {
    if frames.is_empty() {
        return Err(UrError::UrCodec("No UR frames provided".into()));
    }
    if frames.len() > MAX_UR_FRAMES
        || frames.iter().map(String::len).sum::<usize>() > MAX_UR_SESSION_CHARS
    {
        return Err(UrError::UrCodec("UR session exceeds limit".into()));
    }
    let mut session = UrSession::new(expected_type);
    for frame in frames {
        if let Some(bytes) = session.receive(frame)? {
            return Ok(bytes);
        }
    }
    Err(UrError::UrCodec(
        "Incomplete multipart UR: insufficient frames to reconstruct payload".into(),
    ))
}
