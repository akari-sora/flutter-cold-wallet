pub mod bounded_cbor;
pub mod crypto_keypath;
pub mod crypto_multi_accounts;
pub mod crypto_psbt;
pub mod error;
pub mod eth_sign_request;
pub mod eth_signature;
pub mod fountain;
pub mod ffi_decode;

pub use bounded_cbor::{BoundedCborParser, BoundedCborValue, MAX_ALLOWED_DEPTH, MAX_ALLOWED_PAYLOAD};
pub use crypto_keypath::{CryptoKeyPath, PathComponent};
pub use crypto_multi_accounts::{CryptoHDKey, CryptoMultiAccounts};
pub use crypto_psbt::CryptoPsbt;
pub use error::{CborError, UrError};
pub use eth_sign_request::{DataType, EthSignRequest};
pub use eth_signature::EthSignature;
pub use fountain::{default_fragment_len, decode_ur_frames, displayable_single_ur, encode_ur_fountain_frames, UrSession};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodedUrPayload {
    EthSignRequest(EthSignRequest),
    EthSignature(EthSignature),
    MultiAccounts(CryptoMultiAccounts),
    CryptoPsbt(CryptoPsbt),
}

impl DecodedUrPayload {
    pub fn decode(ur_string: &str) -> Result<Self, UrError> {
        let clean = ur_string.trim();
        if clean.starts_with('[') {
            let frames: Vec<String> = serde_json::from_str(clean)
                .map_err(|e| UrError::UrCodec(format!("Invalid UR frame array JSON: {e}")))?;
            return Self::decode_frames(&frames);
        }
        Self::decode_frames(&[clean.to_string()])
    }

    pub fn decode_frames(frames: &[String]) -> Result<Self, UrError> {
        if frames.is_empty() {
            return Err(UrError::UrCodec("Empty UR frame list".into()));
        }
        let first = frames[0].trim();
        if !first.to_lowercase().starts_with("ur:") {
            return Err(UrError::UrCodec("Invalid UR prefix".into()));
        }

        let parts: Vec<&str> = first[3..].split('/').collect();
        if parts.is_empty() {
            return Err(UrError::UrCodec("Invalid UR format".into()));
        }

        let ur_type = parts[0].to_lowercase();
        let raw_cbor = decode_ur_frames(&ur_type, frames)?;

        match ur_type.as_str() {
            EthSignRequest::UR_TYPE => {
                let req = EthSignRequest::from_cbor_bytes(&raw_cbor)?;
                Ok(Self::EthSignRequest(req))
            }
            EthSignature::UR_TYPE => {
                let sig = EthSignature::from_cbor_bytes(&raw_cbor)?;
                Ok(Self::EthSignature(sig))
            }
            CryptoMultiAccounts::UR_TYPE => {
                let acc = CryptoMultiAccounts::from_cbor_bytes(&raw_cbor)?;
                Ok(Self::MultiAccounts(acc))
            }
            CryptoPsbt::UR_TYPE => {
                let psbt = CryptoPsbt::from_cbor_bytes(&raw_cbor)?;
                Ok(Self::CryptoPsbt(psbt))
            }
            other => Err(UrError::TypeMismatch {
                expected: "eth-sign-request, eth-signature, crypto-multi-accounts, or crypto-psbt".into(),
                got: other.to_string(),
            }),
        }
    }
}
