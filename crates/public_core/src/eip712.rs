use crate::address::Address;
use crate::error::CoreError;
use crate::evm::{dec_string_to_be_bytes, keccak256};
use serde_json::Value;
use std::collections::HashSet;

pub struct Eip712Parser;

impl Eip712Parser {
    pub fn parse_and_hash(json_str: &str) -> Result<([u8; 32], String), CoreError> {
        let v: Value = serde_json::from_str(json_str)
            .map_err(|e| CoreError::Eip712Error(format!("Invalid JSON: {e}")))?;

        let types = v.get("types").and_then(Value::as_object).ok_or_else(|| {
            CoreError::Eip712Error("Missing 'types' object".into())
        })?;

        let primary_type = v.get("primaryType").and_then(Value::as_str).ok_or_else(|| {
            CoreError::Eip712Error("Missing 'primaryType' string".into())
        })?;

        let domain = v.get("domain").ok_or_else(|| {
            CoreError::Eip712Error("Missing 'domain' object".into())
        })?;

        let message = v.get("message").ok_or_else(|| {
            CoreError::Eip712Error("Missing 'message' object".into())
        })?;

        // Fail-Closed policy check: Permit / Permit2 / PermitSingle / PermitBatch rejected
        let pt_lower = primary_type.to_lowercase();
        if pt_lower.contains("permit") {
            return Err(CoreError::PermitRejected(format!(
                "EIP-712 primaryType '{primary_type}' represents an unvetted Permit/Allowance"
            )));
        }

        let domain_separator = Self::hash_struct("EIP712Domain", domain, types)?;
        let message_hash = Self::hash_struct(primary_type, message, types)?;

        // digest = keccak256("\x19\x01" || domainSeparator || messageHash)
        let mut final_preimage = Vec::with_capacity(2 + 32 + 32);
        final_preimage.extend_from_slice(b"\x19\x01");
        final_preimage.extend_from_slice(&domain_separator);
        final_preimage.extend_from_slice(&message_hash);

        let digest = keccak256(&final_preimage);
        Ok((digest, primary_type.to_string()))
    }

    pub fn encode_type(
        primary_type: &str,
        types: &serde_json::Map<String, Value>,
    ) -> Result<String, CoreError> {
        let mut referenced = HashSet::new();
        Self::find_referenced_types(primary_type, types, &mut referenced)?;
        referenced.remove(primary_type);

        let mut sorted_refs: Vec<&str> = referenced.into_iter().collect();
        sorted_refs.sort_unstable();

        let mut result = Self::format_single_type(primary_type, types)?;
        for sub_type in sorted_refs {
            result.push_str(&Self::format_single_type(sub_type, types)?);
        }
        Ok(result)
    }

    fn format_single_type(
        type_name: &str,
        types: &serde_json::Map<String, Value>,
    ) -> Result<String, CoreError> {
        let fields = types.get(type_name).and_then(Value::as_array).ok_or_else(|| {
            CoreError::Eip712Error(format!("Type definition not found for '{type_name}'"))
        })?;

        let mut s = format!("{type_name}(");
        for (i, f) in fields.iter().enumerate() {
            if i > 0 {
                s.push(',');
            }
            let name = f.get("name").and_then(Value::as_str).ok_or_else(|| {
                CoreError::Eip712Error("Field name missing".into())
            })?;
            let ftype = f.get("type").and_then(Value::as_str).ok_or_else(|| {
                CoreError::Eip712Error("Field type missing".into())
            })?;
            s.push_str(&format!("{ftype} {name}"));
        }
        s.push(')');
        Ok(s)
    }

    fn find_referenced_types<'a>(
        type_name: &'a str,
        types: &'a serde_json::Map<String, Value>,
        referenced: &mut HashSet<&'a str>,
    ) -> Result<(), CoreError> {
        if !types.contains_key(type_name) {
            return Ok(());
        }
        if referenced.insert(type_name) {
            if let Some(fields) = types.get(type_name).and_then(Value::as_array) {
                for f in fields {
                    if let Some(ftype) = f.get("type").and_then(Value::as_str) {
                        let clean_type = ftype.trim_end_matches("[]");
                        Self::find_referenced_types(clean_type, types, referenced)?;
                    }
                }
            }
        }
        Ok(())
    }

    pub fn hash_struct(
        type_name: &str,
        data: &Value,
        types: &serde_json::Map<String, Value>,
    ) -> Result<[u8; 32], CoreError> {
        let type_str = Self::encode_type(type_name, types)?;
        let type_hash = keccak256(type_str.as_bytes());

        let fields = types.get(type_name).and_then(Value::as_array).ok_or_else(|| {
            CoreError::Eip712Error(format!("Type '{type_name}' not defined in types"))
        })?;

        let mut encoded_data = Vec::with_capacity(32 + fields.len() * 32);
        encoded_data.extend_from_slice(&type_hash);

        for f in fields {
            let field_name = f.get("name").and_then(Value::as_str).unwrap();
            let field_type = f.get("type").and_then(Value::as_str).unwrap();
            let field_val = data.get(field_name).ok_or_else(|| {
                CoreError::Eip712Error(format!("Field '{field_name}' missing from value"))
            })?;

            let field_encoded = Self::encode_field(field_type, field_val, types)?;
            encoded_data.extend_from_slice(&field_encoded);
        }

        Ok(keccak256(&encoded_data))
    }

    fn encode_field(
        field_type: &str,
        val: &Value,
        types: &serde_json::Map<String, Value>,
    ) -> Result<[u8; 32], CoreError> {
        if types.contains_key(field_type) {
            return Self::hash_struct(field_type, val, types);
        }

        if let Some(inner_type) = field_type.strip_suffix("[]") {
            let arr = val.as_array().ok_or_else(|| {
                CoreError::Eip712Error(format!("Expected array for field type '{field_type}'"))
            })?;
            let mut concatenated = Vec::with_capacity(arr.len() * 32);
            for item in arr {
                let encoded_item = Self::encode_field(inner_type, item, types)?;
                concatenated.extend_from_slice(&encoded_item);
            }
            return Ok(keccak256(&concatenated));
        }

        match field_type {
            "string" => {
                let s = val
                    .as_str()
                    .ok_or_else(|| CoreError::Eip712Error("Expected string".into()))?;
                Ok(keccak256(s.as_bytes()))
            }
            "bytes" => {
                let b_hex = val
                    .as_str()
                    .ok_or_else(|| CoreError::Eip712Error("Expected hex string for bytes".into()))?;
                let raw_b = hex::decode(b_hex.trim_start_matches("0x"))
                    .map_err(|e| CoreError::Eip712Error(format!("Invalid hex for bytes: {e}")))?;
                Ok(keccak256(&raw_b))
            }
            "bytes32" => {
                let b_hex = val.as_str().ok_or_else(|| {
                    CoreError::Eip712Error("Expected hex string for bytes32".into())
                })?;
                let raw_b = hex::decode(b_hex.trim_start_matches("0x"))
                    .map_err(|e| CoreError::Eip712Error(format!("Invalid hex: {e}")))?;
                if raw_b.len() != 32 {
                    return Err(CoreError::Eip712Error(
                        "bytes32 must be exactly 32 bytes".into(),
                    ));
                }
                let mut out = [0u8; 32];
                out.copy_from_slice(&raw_b);
                Ok(out)
            }
            "address" => {
                let addr_str = val
                    .as_str()
                    .ok_or_else(|| CoreError::Eip712Error("Expected string address".into()))?;
                let addr = Address::parse_hex(addr_str)?;
                let mut out = [0u8; 32];
                out[12..32].copy_from_slice(addr.as_bytes());
                Ok(out)
            }
            "bool" => {
                let b = val
                    .as_bool()
                    .ok_or_else(|| CoreError::Eip712Error("Expected bool".into()))?;
                let mut out = [0u8; 32];
                if b {
                    out[31] = 1;
                }
                Ok(out)
            }
            "uint256" | "uint" => {
                let mut out = [0u8; 32];
                if let Some(n) = val.as_u64() {
                    let b = n.to_be_bytes();
                    out[24..32].copy_from_slice(&b);
                } else if let Some(s) = val.as_str() {
                    let clean = s.trim_start_matches("0x");
                    if s.starts_with("0x") {
                        let raw = hex::decode(clean)
                            .map_err(|e| CoreError::Eip712Error(e.to_string()))?;
                        if raw.len() > 32 {
                            return Err(CoreError::Eip712Error("uint256 overflow".into()));
                        }
                        out[32 - raw.len()..].copy_from_slice(&raw);
                    } else {
                        let be_bytes = dec_string_to_be_bytes(s);
                        if be_bytes.len() > 32 {
                            return Err(CoreError::Eip712Error(
                                "uint256 decimal overflow".into(),
                            ));
                        }
                        out[32 - be_bytes.len()..].copy_from_slice(&be_bytes);
                    }
                } else {
                    return Err(CoreError::Eip712Error(
                        "Invalid uint256 representation".into(),
                    ));
                }
                Ok(out)
            }
            _ => Err(CoreError::Eip712Error(format!(
                "Unsupported EIP-712 field type '{field_type}'"
            ))),
        }
    }
}
