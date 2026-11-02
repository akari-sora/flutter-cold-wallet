use crate::bounded_cbor::{BoundedCborParser, BoundedCborValue};
use crate::error::UrError;
use ciborium::value::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CryptoPsbt {
    pub psbt_data: Vec<u8>,
}

impl CryptoPsbt {
    pub const CBOR_TAG: u64 = 310;
    pub const UR_TYPE: &'static str = "crypto-psbt";

    /// Call after policy validation and before approving a P2WPKH request.
    /// Each input adds at most one partial-signature entry: CompactSize key
    /// length (1), key type plus compressed pubkey (34), value length (1),
    /// DER signature (at most 72) plus sighash byte (1), or 109 bytes.
    /// Tag 310 and the byte-string header need at most another eight bytes.
    pub fn ensure_p2wpkh_response_capacity(psbt: &public_core::bitcoin::Psbt) -> Result<(), UrError> {
        let upper_bound = psbt.inputs.len().checked_mul(109)
            .and_then(|overhead| psbt.serialize().len().checked_add(overhead))
            .and_then(|length| length.checked_add(8))
            .ok_or_else(|| UrError::UrCodec("PSBT response size overflow".into()))?;
        if upper_bound > crate::MAX_ALLOWED_PAYLOAD {
            return Err(UrError::UrCodec("PSBT leaves insufficient space for the bounded signature response".into()));
        }
        Ok(())
    }

    pub fn new(psbt_data: Vec<u8>) -> Self {
        Self { psbt_data }
    }

    pub fn from_cbor_bytes(bytes: &[u8]) -> Result<Self, UrError> {
        let ast = BoundedCborParser::parse(bytes)?;
        Self::from_cbor_value(&ast)
    }

    pub fn from_cbor_value(ast: &BoundedCborValue) -> Result<Self, UrError> {
        let inner = match ast {
            BoundedCborValue::Tag(tag, inner) => {
                if *tag != Self::CBOR_TAG {
                    return Err(UrError::TypeMismatch {
                        expected: "Tag 310 (crypto-psbt)".into(),
                        got: format!("Tag {}", tag),
                    });
                }
                inner.as_ref()
            }
            other => other,
        };

        match inner {
            BoundedCborValue::Bytes(b) => Ok(Self {
                psbt_data: b.clone(),
            }),
            BoundedCborValue::Map(_) => {
                // Check key 1
                if let Some(val) = inner.get_map_value(1) {
                    let b = val.as_bytes()?;
                    Ok(Self {
                        psbt_data: b.to_vec(),
                    })
                } else {
                    Err(UrError::MissingRequiredField("key 1 (psbt bytes) in crypto-psbt map"))
                }
            }
            _ => Err(UrError::TypeMismatch {
                expected: "Bytes or Map with key 1 for crypto-psbt".into(),
                got: "Other CBOR value".into(),
            }),
        }
    }

    pub fn to_cbor_bytes(&self) -> Vec<u8> {
        // Tag 310 wrapping raw PSBT bytes
        let root = Value::Tag(Self::CBOR_TAG, Box::new(Value::Bytes(self.psbt_data.clone())));
        let mut buf = Vec::new();
        ciborium::into_writer(&root, &mut buf).expect("CBOR write crypto-psbt");
        buf
    }

    pub fn to_ur_single(&self) -> String {
        let bytes = self.to_cbor_bytes();
        format!(
            "ur:{}/{}",
            Self::UR_TYPE,
            ur::bytewords::encode(&bytes, ur::bytewords::Style::Minimal)
        )
    }

    pub fn to_ur_fountain(&self, max_fragment_len: usize) -> Result<Vec<String>, UrError> {
        let bytes = self.to_cbor_bytes();
        crate::encode_ur_fountain_frames(Self::UR_TYPE, &bytes, max_fragment_len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DecodedUrPayload;

    #[test]
    fn test_crypto_psbt_roundtrip() {
        let dummy_psbt = b"psbt\xff\x01\x00\x00\x00\x00\x00".to_vec();
        let cp = CryptoPsbt::new(dummy_psbt.clone());
        let ur_single = cp.to_ur_single();
        assert!(ur_single.starts_with("ur:crypto-psbt/"));

        let decoded = DecodedUrPayload::decode(&ur_single).expect("Decode must succeed");
        match decoded {
            DecodedUrPayload::CryptoPsbt(parsed) => {
                assert_eq!(parsed.psbt_data, dummy_psbt);
            }
            _ => panic!("Expected CryptoPsbt"),
        }
    }
}
