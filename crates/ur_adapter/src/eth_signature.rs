use crate::bounded_cbor::{BoundedCborParser, BoundedCborValue};
use crate::error::UrError;
use ciborium::value::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthSignature {
    pub request_id: Option<[u8; 16]>,
    pub signature: [u8; 65], // r[32] || s[32] || v[1]
    pub origin: Option<String>,
}

impl EthSignature {
    pub const CBOR_TAG: u64 = 402;
    pub const UR_TYPE: &'static str = "eth-signature";

    pub fn new(
        request_id: Option<[u8; 16]>,
        signature: [u8; 65],
        origin: Option<String>,
    ) -> Self {
        Self {
            request_id,
            signature,
            origin,
        }
    }

    pub fn from_cbor_bytes(bytes: &[u8]) -> Result<Self, UrError> {
        let ast = BoundedCborParser::parse(bytes)?;
        Self::from_cbor_value(&ast)
    }

    pub fn from_cbor_value(ast: &BoundedCborValue) -> Result<Self, UrError> {
        let map_val = match ast {
            BoundedCborValue::Tag(tag, inner) => {
                if *tag != Self::CBOR_TAG {
                    return Err(UrError::TypeMismatch {
                        expected: "Tag 402 (eth-signature)".into(),
                        got: format!("Tag {}", tag),
                    });
                }
                inner.as_ref()
            }
            BoundedCborValue::Map(_) => ast,
            _ => {
                return Err(UrError::TypeMismatch {
                    expected: "Map or Tag 402".into(),
                    got: "Other".to_string(),
                })
            }
        };

        // Key 1: request_id (UUID 16 bytes, optional)
        let request_id = if let Some(id_val) = map_val.get_map_value(1) {
            let bytes = match id_val {
                BoundedCborValue::Tag(37, inner) => inner.as_bytes()?,
                BoundedCborValue::Bytes(b) => b.as_slice(),
                _ => return Err(UrError::MissingRequiredField("valid UUID bytes for request_id")),
            };
            if bytes.len() != 16 {
                return Err(UrError::InvalidDerivationPath(
                    "request_id must be exactly 16 bytes UUID".into(),
                ));
            }
            let mut arr = [0u8; 16];
            arr.copy_from_slice(bytes);
            Some(arr)
        } else {
            None
        };

        // Key 2: signature (Bytes 65) - REQUIRED
        let sig_bytes = map_val
            .get_map_value(2)
            .ok_or(UrError::MissingRequiredField("signature (key 2)"))?
            .as_bytes()?;

        if sig_bytes.len() != 65 {
            return Err(UrError::InvalidSignatureLength(sig_bytes.len()));
        }

        let mut signature = [0u8; 65];
        signature.copy_from_slice(sig_bytes);

        // Key 3: origin (Text, optional)
        let origin = if let Some(orig_val) = map_val.get_map_value(3) {
            Some(orig_val.as_str()?.to_string())
        } else {
            None
        };

        Ok(Self {
            request_id,
            signature,
            origin,
        })
    }

    pub fn to_cbor_bytes(&self) -> Vec<u8> {
        let mut map = Vec::new();

        if let Some(ref rid) = self.request_id {
            map.push((
                Value::Integer(1.into()),
                Value::Tag(37, Box::new(Value::Bytes(rid.to_vec()))),
            ));
        }

        map.push((Value::Integer(2.into()), Value::Bytes(self.signature.to_vec())));

        if let Some(ref orig) = self.origin {
            map.push((Value::Integer(3.into()), Value::Text(orig.clone())));
        }

        let mut buf = Vec::new();
        let tagged_root = Value::Tag(Self::CBOR_TAG, Box::new(Value::Map(map)));
        ciborium::into_writer(&tagged_root, &mut buf).expect("CBOR write");
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
}
