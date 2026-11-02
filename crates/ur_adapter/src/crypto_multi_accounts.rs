use crate::bounded_cbor::{BoundedCborParser, BoundedCborValue};
use crate::crypto_keypath::CryptoKeyPath;
use crate::error::UrError;
use ciborium::value::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CryptoHDKey {
    pub key_data: Vec<u8>,
    pub chain_code: Option<Vec<u8>>,
    pub parent_fingerprint: Option<[u8; 4]>,
    pub origin: CryptoKeyPath,
    pub name: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CryptoMultiAccounts {
    pub master_fingerprint: u32,
    pub keys: Vec<CryptoHDKey>,
    pub device: Option<String>,
    pub device_id: Option<String>,
    pub version: Option<String>,
}

impl CryptoMultiAccounts {
    pub const CBOR_TAG: u64 = 1103;
    pub const UR_TYPE: &'static str = "crypto-multi-accounts";

    pub fn from_cbor_bytes(bytes: &[u8]) -> Result<Self, UrError> {
        let ast = BoundedCborParser::parse(bytes)?;
        Self::from_cbor_value(&ast)
    }

    pub fn from_cbor_value(ast: &BoundedCborValue) -> Result<Self, UrError> {
        let map_val = match ast {
            BoundedCborValue::Tag(tag, inner) => {
                if *tag != Self::CBOR_TAG {
                    return Err(UrError::TypeMismatch {
                        expected: "Tag 1103 (crypto-multi-accounts)".into(),
                        got: format!("Tag {}", tag),
                    });
                }
                inner.as_ref()
            }
            BoundedCborValue::Map(_) => ast,
            _ => {
                return Err(UrError::TypeMismatch {
                    expected: "Map or Tag 1103".into(),
                    got: "Other".to_string(),
                })
            }
        };

        // Key 1: master_fingerprint (u32)
        let master_fingerprint = map_val
            .get_map_value(1)
            .ok_or(UrError::MissingRequiredField("master_fingerprint (key 1)"))?
            .as_u32()?;

        // Key 2: keys (Array of Tag 303 CryptoHDKey)
        let keys_val = map_val
            .get_map_value(2)
            .ok_or(UrError::MissingRequiredField("keys (key 2)"))?
            .as_array()?;

        let mut keys = Vec::with_capacity(keys_val.len());
        for k_item in keys_val {
            let k_map = match k_item {
                BoundedCborValue::Tag(303, inner) => inner.as_map()?,
                BoundedCborValue::Map(m) => m.as_slice(),
                _ => {
                    return Err(UrError::TypeMismatch {
                        expected: "Tag 303 or Map for CryptoHDKey".into(),
                        got: "Other".to_string(),
                    })
                }
            };

            let mut key_data = None;
            let mut chain_code = None;
            let mut parent_fingerprint = None;
            let mut origin = None;
            let mut name = None;
            let mut note = None;

            for (k, v) in k_map {
                if let BoundedCborValue::Unsigned(k_int) = k {
                    match k_int {
                        2 => match v {
                            BoundedCborValue::Bool(false) => {}
                            BoundedCborValue::Bool(true) => {
                                return Err(UrError::TypeMismatch {
                                    expected: "Public CryptoHDKey (is-private=false)".into(),
                                    got: "Private CryptoHDKey".into(),
                                })
                            }
                            _ => {
                                return Err(UrError::TypeMismatch {
                                    expected: "Boolean is-private flag".into(),
                                    got: "Other".into(),
                                })
                            }
                        },
                        3 => key_data = Some(v.as_bytes()?.to_vec()),
                        4 => chain_code = Some(v.as_bytes()?.to_vec()),
                        6 => {
                            let origin_val = match v {
                                BoundedCborValue::Tag(304, inner) => inner.as_ref(),
                                _ => v,
                            };
                            origin = Some(CryptoKeyPath::from_cbor_value(origin_val)?);
                        }
                        8 => {
                            let fp = u32::try_from(v.as_u64()?).map_err(|_| {
                                UrError::InvalidDerivationPath(
                                    "Parent fingerprint exceeds u32".into(),
                                )
                            })?;
                            parent_fingerprint = Some(fp.to_be_bytes());
                        }
                        9 => name = Some(v.as_str()?.to_string()),
                        10 => note = Some(v.as_str()?.to_string()),
                        _ => {}
                    }
                }
            }

            let key_data = key_data.ok_or(UrError::MissingRequiredField(
                "key_data (key 3 in CryptoHDKey)",
            ))?;
            let origin = origin.ok_or(UrError::MissingRequiredField(
                "origin (key 6 in CryptoHDKey)",
            ))?;

            keys.push(CryptoHDKey {
                key_data,
                chain_code,
                parent_fingerprint,
                origin,
                name,
                note,
            });
        }

        let device = map_val
            .get_map_value(3)
            .and_then(|v| v.as_str().ok())
            .map(|s| s.to_string());
        let device_id = map_val
            .get_map_value(4)
            .and_then(|v| v.as_str().ok())
            .map(|s| s.to_string());
        let version = map_val
            .get_map_value(5)
            .and_then(|v| v.as_str().ok())
            .map(|s| s.to_string());

        Ok(Self {
            master_fingerprint,
            keys,
            device,
            device_id,
            version,
        })
    }

    pub fn to_cbor_bytes(&self) -> Vec<u8> {
        let mut map = Vec::new();
        map.push((
            Value::Integer(1.into()),
            Value::Integer(self.master_fingerprint.into()),
        ));

        let mut keys_arr = Vec::new();
        for k in &self.keys {
            let mut k_map = Vec::new();
            k_map.push((Value::Integer(3.into()), Value::Bytes(k.key_data.clone())));
            if let Some(ref cc) = k.chain_code {
                k_map.push((Value::Integer(4.into()), Value::Bytes(cc.clone())));
            }

            if let Some(fp) = k.parent_fingerprint {
                k_map.push((
                    Value::Integer(8.into()),
                    Value::Integer(u32::from_be_bytes(fp).into()),
                ));
            }
            let mut origin_map = Vec::new();
            let mut comp_arr = Vec::new();
            for c in &k.origin.components {
                comp_arr.push(Value::Integer(c.index.into()));
                comp_arr.push(Value::Bool(c.hardened));
            }
            origin_map.push((Value::Integer(1.into()), Value::Array(comp_arr)));
            if let Some(fp) = k.origin.source_fingerprint {
                origin_map.push((
                    Value::Integer(2.into()),
                    Value::Integer(u32::from_be_bytes(fp).into()),
                ));
            }
            if let Some(d) = k.origin.depth {
                origin_map.push((Value::Integer(3.into()), Value::Integer(d.into())));
            }
            k_map.push((
                Value::Integer(6.into()),
                Value::Tag(304, Box::new(Value::Map(origin_map))),
            ));

            if let Some(ref name) = k.name {
                k_map.push((Value::Integer(9.into()), Value::Text(name.clone())));
            }
            if let Some(ref note) = k.note {
                k_map.push((Value::Integer(10.into()), Value::Text(note.clone())));
            }

            keys_arr.push(Value::Tag(303, Box::new(Value::Map(k_map))));
        }
        map.push((Value::Integer(2.into()), Value::Array(keys_arr)));

        if let Some(ref dev) = self.device {
            map.push((Value::Integer(3.into()), Value::Text(dev.clone())));
        }
        if let Some(ref dev_id) = self.device_id {
            map.push((Value::Integer(4.into()), Value::Text(dev_id.clone())));
        }
        if let Some(ref ver) = self.version {
            map.push((Value::Integer(5.into()), Value::Text(ver.clone())));
        }

        let mut buf = Vec::new();
        ciborium::into_writer(&Value::Map(map), &mut buf).expect("CBOR write");
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
