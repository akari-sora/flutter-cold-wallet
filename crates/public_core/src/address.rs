use crate::error::CoreError;
use tiny_keccak::{Hasher, Keccak};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Address([u8; 20]);

impl Address {
    pub const ZERO: Address = Address([0u8; 20]);

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, CoreError> {
        if bytes.len() != 20 {
            return Err(CoreError::InvalidTransactionFormat(format!(
                "Invalid address length: expected 20 bytes, got {}",
                bytes.len()
            )));
        }
        let mut arr = [0u8; 20];
        arr.copy_from_slice(bytes);
        Ok(Address(arr))
    }

    pub fn parse_hex(hex_str: &str) -> Result<Self, CoreError> {
        let clean = hex_str.trim_start_matches("0x");
        let bytes = hex::decode(clean).map_err(|e| {
            CoreError::InvalidTransactionFormat(format!("Hex decode error for address: {e}"))
        })?;
        Self::from_bytes(&bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 20] {
        &self.0
    }

    pub fn is_zero(&self) -> bool {
        self.0.iter().all(|&b| b == 0)
    }

    pub fn to_checksum_string(&self) -> String {
        let hex_addr = hex::encode(self.0);
        let mut hasher = Keccak::v256();
        hasher.update(hex_addr.as_bytes());
        let mut hash = [0u8; 32];
        hasher.finalize(&mut hash);
        let hash_hex = hex::encode(hash);

        let mut checksummed = String::with_capacity(42);
        checksummed.push_str("0x");
        for (i, ch) in hex_addr.chars().enumerate() {
            if ch.is_ascii_digit() {
                checksummed.push(ch);
            } else {
                let nibble = u8::from_str_radix(&hash_hex[i..i + 1], 16).unwrap_or(0);
                if nibble >= 8 {
                    checksummed.push(ch.to_ascii_uppercase());
                } else {
                    checksummed.push(ch.to_ascii_lowercase());
                }
            }
        }
        checksummed
    }
}
