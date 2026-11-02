use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum CborError {
    #[error("CBOR payload size {0} exceeds maximum limit of 131,072 bytes")]
    PayloadTooLarge(usize),

    #[error("CBOR nesting depth {0} exceeds maximum limit of 16")]
    DepthExceeded(usize),

    #[error("Duplicate key detected in CBOR map: {0}")]
    DuplicateKey(String),

    #[error("Trailing bytes detected: {0} extra bytes found after CBOR payload")]
    TrailingBytes(usize),

    #[error("Indefinite length items rejected in strict cold wallet profile")]
    IndefiniteLengthRejected,

    #[error("Unexpected end of CBOR buffer")]
    UnexpectedEof,

    #[error("Invalid CBOR format: {0}")]
    Malformed(String),

    #[error("Type mismatch: expected {expected}, found {found}")]
    TypeMismatch {
        expected: &'static str,
        found: &'static str,
    },
}

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum UrError {
    #[error("CBOR parser error: {0}")]
    Cbor(#[from] CborError),

    #[error("UR encoding/decoding error: {0}")]
    UrCodec(String),

    #[error("UR type mismatch: expected {expected}, got {got}")]
    TypeMismatch { expected: String, got: String },

    #[error("Missing required field: {0}")]
    MissingRequiredField(&'static str),

    #[error("Invalid derivation path: {0}")]
    InvalidDerivationPath(String),

    #[error("Invalid signature length: expected 65 bytes, got {0}")]
    InvalidSignatureLength(usize),

    #[error("Stream splicing detected: mismatched checksum, sequence, or type in fountain frame")]
    StreamSplicingDetected,

    #[error("Session expired or aborted")]
    SessionExpired,
}
