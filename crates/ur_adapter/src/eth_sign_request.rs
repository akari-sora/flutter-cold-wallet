use crate::bounded_cbor::{BoundedCborParser, BoundedCborValue};
use crate::crypto_keypath::CryptoKeyPath;
use crate::error::UrError;
use ciborium::value::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum DataType {
    Transaction = 1,
    TypedData = 2,
    PersonalMessage = 3,
    TypedTransaction = 4,
}

impl DataType {
    pub fn from_u32(val: u32) -> Result<Self, UrError> {
        match val {
            1 => Ok(Self::Transaction),
            2 => Ok(Self::TypedData),
            3 => Ok(Self::PersonalMessage),
            4 => Ok(Self::TypedTransaction),
            other => Err(UrError::InvalidDerivationPath(format!(
                "Invalid data_type: {}, expected 1, 2, 3, or 4",
                other
            ))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EthSignRequest {
    pub request_id: Option<[u8; 16]>,
    pub sign_data: Vec<u8>,
    pub data_type: DataType,
    pub chain_id: Option<u64>,
    pub derivation_path: CryptoKeyPath,
    pub address: Option<[u8; 20]>,
    pub origin: Option<String>,
}

impl EthSignRequest {
    pub const CBOR_TAG: u64 = 401;
    pub const UR_TYPE: &'static str = "eth-sign-request";

    pub fn from_cbor_bytes(bytes: &[u8]) -> Result<Self, UrError> {
        let ast = BoundedCborParser::parse(bytes)?;
        Self::from_cbor_value(&ast)
    }

    pub fn from_cbor_value(ast: &BoundedCborValue) -> Result<Self, UrError> {
        let map_val = match ast {
            BoundedCborValue::Tag(tag, inner) => {
                if *tag != Self::CBOR_TAG {
                    return Err(UrError::TypeMismatch {
                        expected: "Tag 401 (eth-sign-request)".into(),
                        got: format!("Tag {}", tag),
                    });
                }
                inner.as_ref()
            }
            BoundedCborValue::Map(_) => ast,
            _ => {
                return Err(UrError::TypeMismatch {
                    expected: "Map or Tag 401".into(),
                    got: "Other".to_string(),
                })
            }
        };

        // Key 1: request_id (UUID 16 bytes, Tag 37 or raw Bytes)
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

        // Key 2: sign_data (Bytes) - REQUIRED
        let sign_data = map_val
            .get_map_value(2)
            .ok_or(UrError::MissingRequiredField("sign_data (key 2)"))?
            .as_bytes()?
            .to_vec();

        if sign_data.is_empty() {
            return Err(UrError::MissingRequiredField("non-empty sign_data"));
        }

        // Key 3: data_type (Integer) - REQUIRED
        let dt_val = map_val
            .get_map_value(3)
            .ok_or(UrError::MissingRequiredField("data_type (key 3)"))?
            .as_u64()?;
        let data_type = DataType::from_u32(u32::try_from(dt_val).map_err(|_| {
            UrError::InvalidDerivationPath("data_type exceeds u32".into())
        })?)?;

        // Key 4: chain_id (Integer, optional)
        let chain_id = if let Some(cid_val) = map_val.get_map_value(4) {
            Some(cid_val.as_u64()?)
        } else {
            None
        };

        // Key 5: derivation_path (Tag 304 CryptoKeypath) - REQUIRED
        let path_val = map_val
            .get_map_value(5)
            .ok_or(UrError::MissingRequiredField("derivation_path (key 5)"))?;
        let derivation_path = CryptoKeyPath::from_cbor_value(path_val)?;

        // Key 6: address (Bytes 20, optional)
        let address = if let Some(addr_val) = map_val.get_map_value(6) {
            let bytes = addr_val.as_bytes()?;
            if bytes.len() != 20 {
                return Err(UrError::InvalidDerivationPath(
                    "address must be exactly 20 bytes".into(),
                ));
            }
            let mut arr = [0u8; 20];
            arr.copy_from_slice(bytes);
            Some(arr)
        } else {
            None
        };

        // Key 7: origin (Text, optional)
        let origin = if let Some(orig_val) = map_val.get_map_value(7) {
            Some(orig_val.as_str()?.to_string())
        } else {
            None
        };

        Ok(Self {
            request_id,
            sign_data,
            data_type,
            chain_id,
            derivation_path,
            address,
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

        map.push((Value::Integer(2.into()), Value::Bytes(self.sign_data.clone())));
        map.push((
            Value::Integer(3.into()),
            Value::Integer((self.data_type as u32).into()),
        ));

        if let Some(cid) = self.chain_id {
            map.push((Value::Integer(4.into()), Value::Integer(cid.into())));
        }

        // CryptoKeypath
        let mut path_map = Vec::new();
        let mut comp_arr = Vec::new();
        for c in &self.derivation_path.components {
            comp_arr.push(Value::Integer(c.index.into()));
            comp_arr.push(Value::Bool(c.hardened));
        }
        path_map.push((Value::Integer(1.into()), Value::Array(comp_arr)));

        if let Some(fp) = self.derivation_path.source_fingerprint {
            path_map.push((
                Value::Integer(2.into()),
                Value::Integer(u32::from_be_bytes(fp).into()),
            ));
        }
        if let Some(d) = self.derivation_path.depth {
            path_map.push((Value::Integer(3.into()), Value::Integer(d.into())));
        }
        map.push((
            Value::Integer(5.into()),
            Value::Tag(304, Box::new(Value::Map(path_map))),
        ));

        if let Some(ref addr) = self.address {
            map.push((Value::Integer(6.into()), Value::Bytes(addr.to_vec())));
        }
        if let Some(ref orig) = self.origin {
            map.push((Value::Integer(7.into()), Value::Text(orig.clone())));
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
