use crate::error::CoreError;
use crate::rlp::{decode_rlp, encode_bytes, encode_list, encode_u64, RlpItem};
use serde::{Deserialize, Serialize};
use tiny_keccak::{Hasher, Keccak};

const STANDARD_TYPE2_GAS_FLOOR: u64 = 21_000;
const SEPOLIA_AMSTERDAM_TYPE2_GAS_FLOOR: u64 = 12_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransactionType {
    Legacy = 0,
    Eip1559 = 2,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccessListItem {
    pub address: String,
    pub storage_keys: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LegacyTransaction {
    pub nonce: u64,
    pub gas_price: u64,
    pub gas_limit: u64,
    pub to: Option<String>,
    pub value_wei: String,
    pub data: Vec<u8>,
    pub chain_id: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Eip1559Transaction {
    pub chain_id: u64,
    pub nonce: u64,
    pub max_priority_fee_per_gas: u64,
    pub max_fee_per_gas: u64,
    pub gas_limit: u64,
    pub to: Option<String>,
    pub value_wei: String,
    pub data: Vec<u8>,
    pub access_list: Vec<AccessListItem>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParsedIntent {
    NativeTransfer {
        chain_id: u64,
        recipient: String,
        value_wei: String,
        fee_cap_wei: String,
    },
    Erc20Transfer {
        chain_id: u64,
        token_contract: String,
        recipient: String,
        token_amount_raw: String,
        fee_cap_wei: String,
    },
    PolicyRejected {
        reason: String,
    },
}

impl LegacyTransaction {
    /// Inspect a six-field unsigned payload or a nine-field EIP-155 envelope.
    pub fn decode(raw_rlp: &[u8], declared_chain_id: u64) -> Result<Self, CoreError> {
        Self::decode_inner(raw_rlp, declared_chain_id, false)
    }

    /// Signing preparation accepts only unsigned payloads, never existing signatures.
    pub fn decode_unsigned(raw_rlp: &[u8], declared_chain_id: u64) -> Result<Self, CoreError> {
        Self::decode_inner(raw_rlp, declared_chain_id, true)
    }

    fn decode_inner(raw_rlp: &[u8], declared_chain_id: u64, unsigned_only: bool) -> Result<Self, CoreError> {
        let root = decode_rlp(raw_rlp)?;
        let items = root.as_list()?;
        if !matches!(items.len(), 6 | 9) {
            return Err(CoreError::InvalidTransactionFormat(
                "Legacy transaction RLP requires exactly 6 or 9 fields".into(),
            ));
        }

        let nonce = items[0].as_u64()?;
        let gas_price = items[1].as_u64()?;
        let gas_limit = items[2].as_u64()?;
        let to = items[3].as_optional_address()?;
        let value_bytes = items[4].as_u256_bytes()?;
        let value_wei = if value_bytes.is_empty() {
            "0".to_string()
        } else {
            bytes_to_dec_string(value_bytes)
        };
        let data = items[5].as_bytes()?.to_vec();

        let chain_id = if items.len() == 9 {
            let v = items[6].as_u64()?;
            let r = items[7].as_u256_bytes()?;
            let s = items[8].as_u256_bytes()?;
            let r_empty = r.is_empty();
            let s_empty = s.is_empty();
            if r_empty != s_empty {
                return Err(CoreError::InvalidTransactionFormat("Incomplete legacy signature".into()));
            }
            if !r_empty {
                if unsigned_only {
                    return Err(CoreError::InvalidTransactionFormat("Signing request must be unsigned".into()));
                }
                validate_signature_scalars(r, s)?;
            }
            if v == 0 || v == 27 || v == 28 {
                return Err(CoreError::ReplayProtectionMissing);
            }
            if r_empty && s_empty {
                if declared_chain_id != 0 && v == declared_chain_id {
                    v
                } else if v >= 35 && declared_chain_id != 0 && (v - 35) / 2 == declared_chain_id {
                    (v - 35) / 2
                } else if v == 11155111 || v == 1337 || v == 31337 || v == 1 {
                    v
                } else if v >= 35 {
                    (v - 35) / 2
                } else {
                    return Err(CoreError::ReplayProtectionMissing);
                }
            } else {
                if v < 35 {
                    return Err(CoreError::ReplayProtectionMissing);
                }
                (v - 35) / 2
            }
        } else if items.len() == 6 {
            if declared_chain_id == 0 {
                return Err(CoreError::ReplayProtectionMissing);
            }
            declared_chain_id
        } else {
            return Err(CoreError::InvalidTransactionFormat(format!(
                "Invalid legacy transaction field count: {}",
                items.len()
            )));
        };

        if declared_chain_id != 0 && chain_id != declared_chain_id {
            return Err(CoreError::ChainIdMismatch {
                declared: declared_chain_id,
                payload: chain_id,
            });
        }

        Ok(Self {
            nonce,
            gas_price,
            gas_limit,
            to,
            value_wei,
            data,
            chain_id,
        })
    }

    pub fn signing_preimage_hash(&self) -> [u8; 32] {
        let value_bytes = dec_string_to_be_bytes(&self.value_wei);
        let to_encoded = match &self.to {
            Some(addr_str) => {
                let to_bytes = hex::decode(addr_str.trim_start_matches("0x")).unwrap_or_default();
                encode_bytes(&to_bytes)
            }
            None => encode_bytes(&[]),
        };

        let fields = vec![
            encode_u64(self.nonce),
            encode_u64(self.gas_price),
            encode_u64(self.gas_limit),
            to_encoded,
            encode_bytes(&value_bytes),
            encode_bytes(&self.data),
            encode_u64(self.chain_id),
            encode_u64(0),
            encode_u64(0),
        ];

        let rlp_encoded = encode_list(&fields);
        keccak256(&rlp_encoded)
    }

    pub fn to_intent(&self) -> ParsedIntent {
        let fee_cap = (self.gas_limit as u128).saturating_mul(self.gas_price as u128);
        let recipient = match &self.to {
            Some(addr) => addr.clone(),
            None => {
                return ParsedIntent::PolicyRejected {
                    reason: "Contract deployment is strictly rejected in MVP".into(),
                };
            }
        };

        if self.data.is_empty() {
            ParsedIntent::NativeTransfer {
                chain_id: self.chain_id,
                recipient,
                value_wei: self.value_wei.clone(),
                fee_cap_wei: fee_cap.to_string(),
            }
        } else if self.data.len() >= 4 {
            let selector = &self.data[0..4];
            if selector == [0x09, 0x5e, 0xa7, 0xb3] {
                return ParsedIntent::PolicyRejected {
                    reason:
                        "Approval transactions (approve) are strictly rejected by policy (MSG-03)"
                            .into(),
                };
            }
            if selector == [0x39, 0x50, 0x93, 0x51] {
                return ParsedIntent::PolicyRejected {
                    reason: "Allowance transactions (increaseAllowance) are strictly rejected by policy (MSG-03)".into(),
                };
            }
            if selector == [0xa2, 0x2c, 0xb4, 0x65] {
                return ParsedIntent::PolicyRejected {
                    reason: "NFT operator approval (setApprovalForAll) is strictly rejected by policy (MSG-03)".into(),
                };
            }
            if selector == [0xd5, 0x05, 0xac, 0xcf] {
                return ParsedIntent::PolicyRejected {
                    reason: "Permit2 transactions are strictly rejected by policy (MSG-03)".into(),
                };
            }

            if self.data.len() == 68 && selector == [0xa9, 0x05, 0x9c, 0xbb] {
                if self.value_wei != "0" {
                    return ParsedIntent::PolicyRejected {
                        reason: "ERC-20 transfer must not include a hidden native value".into(),
                    };
                }
                // Check dirty padding: first 12 bytes of recipient parameter must be 0
                if self.data[4..16] != [0u8; 12] {
                    return ParsedIntent::PolicyRejected {
                        reason: "Dirty padding detected in ERC-20 transfer recipient: first 12 bytes must be zero".into(),
                    };
                }
                let recipient_bytes = &self.data[16..36];
                let token_recipient = format!("0x{}", hex::encode(recipient_bytes));
                let amount_bytes = &self.data[36..68];
                let amount_dec = bytes_to_dec_string(amount_bytes);

                ParsedIntent::Erc20Transfer {
                    chain_id: self.chain_id,
                    token_contract: recipient,
                    recipient: token_recipient,
                    token_amount_raw: amount_dec,
                    fee_cap_wei: fee_cap.to_string(),
                }
            } else {
                ParsedIntent::PolicyRejected {
                    reason: "Data field is not an empty transfer or known ERC-20 transfer(address,uint256)".into(),
                }
            }
        } else {
            ParsedIntent::PolicyRejected {
                reason: "Data field is truncated (< 4 bytes)".into(),
            }
        }
    }
}

impl Eip1559Transaction {
    /// Inspect the nine-field preimage or twelve-field signed Type-2 envelope.
    pub fn decode(raw_payload: &[u8], declared_chain_id: u64) -> Result<Self, CoreError> {
        Self::decode_inner(raw_payload, declared_chain_id, false)
    }

    pub fn decode_unsigned(raw_payload: &[u8], declared_chain_id: u64) -> Result<Self, CoreError> {
        Self::decode_inner(raw_payload, declared_chain_id, true)
    }

    fn decode_inner(raw_payload: &[u8], declared_chain_id: u64, unsigned_only: bool) -> Result<Self, CoreError> {
        if raw_payload.is_empty() || raw_payload[0] != 0x02 {
            return Err(CoreError::UnsupportedTransactionType(
                raw_payload.first().copied().unwrap_or(0),
            ));
        }

        let root = decode_rlp(&raw_payload[1..])?;
        let items = root.as_list()?;
        if !matches!(items.len(), 9 | 12) {
            return Err(CoreError::InvalidTransactionFormat(
                "EIP-1559 transaction RLP requires exactly 9 or 12 fields".into(),
            ));
        }
        if items.len() == 12 {
            if unsigned_only {
                return Err(CoreError::InvalidTransactionFormat("Signing request must be unsigned".into()));
            }
            if items[9].as_u64()? > 1 {
                return Err(CoreError::InvalidTransactionFormat("Invalid Type-2 signature parity".into()));
            }
            validate_signature_scalars(items[10].as_u256_bytes()?, items[11].as_u256_bytes()?)?;
        }

        let chain_id = items[0].as_u64()?;
        if declared_chain_id != 0 && chain_id != declared_chain_id {
            return Err(CoreError::ChainIdMismatch {
                declared: declared_chain_id,
                payload: chain_id,
            });
        }

        let nonce = items[1].as_u64()?;
        let max_priority_fee_per_gas = items[2].as_u64()?;
        let max_fee_per_gas = items[3].as_u64()?;
        let gas_limit = items[4].as_u64()?;

        if max_priority_fee_per_gas > max_fee_per_gas {
            return Err(CoreError::InvalidGasParameters(
                "max_priority_fee_per_gas cannot exceed max_fee_per_gas".into(),
            ));
        }
        // Sepolia activated Amsterdam on 2026-10-06; EIP-2780 sets TX_BASE_COST
        // to 12,000. This wire floor is not a full intrinsic-gas calculation.
        // https://github.com/ethereum/go-ethereum/releases/tag/v1.17.6
        // https://eips.ethereum.org/EIPS/eip-2780
        let gas_floor = if chain_id == 11_155_111 {
            SEPOLIA_AMSTERDAM_TYPE2_GAS_FLOOR
        } else {
            STANDARD_TYPE2_GAS_FLOOR
        };
        if gas_limit < gas_floor {
            return Err(CoreError::InvalidGasParameters(format!(
                "gas_limit cannot be lower than {gas_floor}"
            )));
        }

        let to = items[5].as_optional_address()?;
        let value_bytes = items[6].as_u256_bytes()?;
        let value_wei = if value_bytes.is_empty() {
            "0".to_string()
        } else {
            bytes_to_dec_string(value_bytes)
        };
        let data = items[7].as_bytes()?.to_vec();

        // Only the canonical empty access list is supported by the low-gas
        // self-transfer exception; malformed entries must not look empty.
        if gas_limit < STANDARD_TYPE2_GAS_FLOOR
            && !matches!(&items[8], RlpItem::List(list) if list.is_empty())
        {
            return Err(CoreError::InvalidGasParameters(
                "gas_limit below 21,000 requires an empty access list".into(),
            ));
        }

        let entries = items[8].as_list()?;
        let mut access_list = Vec::with_capacity(entries.len());
        for item in entries {
            let entry = item.as_list()?;
            if entry.len() != 2 {
                return Err(CoreError::InvalidTransactionFormat(
                    "access_list entry must have exactly 2 fields".into(),
                ));
            }
            let addr =
                crate::address::Address::from_bytes(entry[0].as_bytes()?)?.to_checksum_string();
            let key_items = entry[1].as_list()?;
            let mut keys = Vec::with_capacity(key_items.len());
            for key in key_items {
                let key_bytes = key.as_bytes()?;
                if key_bytes.len() != 32 {
                    return Err(CoreError::InvalidTransactionFormat(
                        "access_list storage key must be exactly 32 bytes".into(),
                    ));
                }
                keys.push(format!("0x{}", hex::encode(key_bytes)));
            }
            access_list.push(AccessListItem {
                address: addr,
                storage_keys: keys,
            });
        }

        Ok(Self {
            chain_id,
            nonce,
            max_priority_fee_per_gas,
            max_fee_per_gas,
            gas_limit,
            to,
            value_wei,
            data,
            access_list,
        })
    }

    /// Bind the bounded low-gas exception to the actual or expected signer.
    /// This does not calculate full intrinsic gas or guarantee execution.
    pub fn validate_gas_for_signer(&self, signer_address: &str) -> Result<(), CoreError> {
        if self.gas_limit >= STANDARD_TYPE2_GAS_FLOOR {
            return Ok(());
        }
        let is_self_transfer = self
            .to
            .as_deref()
            .is_some_and(|recipient| recipient.eq_ignore_ascii_case(signer_address));
        if self.chain_id == 11_155_111
            && self.gas_limit >= SEPOLIA_AMSTERDAM_TYPE2_GAS_FLOOR
            && self.data.is_empty()
            && self.access_list.is_empty()
            && is_self_transfer
        {
            Ok(())
        } else {
            Err(CoreError::InvalidGasParameters(
                "gas_limit below 21,000 requires an empty Sepolia self-transfer for the bound signer"
                    .into(),
            ))
        }
    }

    pub fn signing_preimage_hash(&self) -> [u8; 32] {
        let value_bytes = dec_string_to_be_bytes(&self.value_wei);
        let to_encoded = match &self.to {
            Some(addr_str) => {
                let to_bytes = hex::decode(addr_str.trim_start_matches("0x")).unwrap_or_default();
                encode_bytes(&to_bytes)
            }
            None => encode_bytes(&[]),
        };

        let mut access_list_encoded_items = Vec::new();
        for item in &self.access_list {
            let addr_bytes = hex::decode(item.address.trim_start_matches("0x")).unwrap_or_default();
            let mut keys_encoded = Vec::new();
            for k in &item.storage_keys {
                let raw_k = hex::decode(k.trim_start_matches("0x")).unwrap_or_default();
                keys_encoded.push(encode_bytes(&raw_k));
            }
            let entry_encoded =
                encode_list(&[encode_bytes(&addr_bytes), encode_list(&keys_encoded)]);
            access_list_encoded_items.push(entry_encoded);
        }

        let fields = vec![
            encode_u64(self.chain_id),
            encode_u64(self.nonce),
            encode_u64(self.max_priority_fee_per_gas),
            encode_u64(self.max_fee_per_gas),
            encode_u64(self.gas_limit),
            to_encoded,
            encode_bytes(&value_bytes),
            encode_bytes(&self.data),
            encode_list(&access_list_encoded_items),
        ];

        let rlp_encoded = encode_list(&fields);
        let mut full_preimage = Vec::with_capacity(1 + rlp_encoded.len());
        full_preimage.push(0x02);
        full_preimage.extend_from_slice(&rlp_encoded);

        keccak256(&full_preimage)
    }

    pub fn to_intent(&self) -> ParsedIntent {
        let fee_cap = (self.gas_limit as u128).saturating_mul(self.max_fee_per_gas as u128);
        let recipient = match &self.to {
            Some(addr) => addr.clone(),
            None => {
                return ParsedIntent::PolicyRejected {
                    reason: "Contract deployment is strictly rejected in MVP".into(),
                };
            }
        };

        if self.data.is_empty() {
            ParsedIntent::NativeTransfer {
                chain_id: self.chain_id,
                recipient,
                value_wei: self.value_wei.clone(),
                fee_cap_wei: fee_cap.to_string(),
            }
        } else if self.data.len() >= 4 {
            let selector = &self.data[0..4];
            if selector == [0x09, 0x5e, 0xa7, 0xb3] {
                return ParsedIntent::PolicyRejected {
                    reason:
                        "Approval transactions (approve) are strictly rejected by policy (MSG-03)"
                            .into(),
                };
            }
            if selector == [0x39, 0x50, 0x93, 0x51] {
                return ParsedIntent::PolicyRejected {
                    reason: "Allowance transactions (increaseAllowance) are strictly rejected by policy (MSG-03)".into(),
                };
            }
            if selector == [0xa2, 0x2c, 0xb4, 0x65] {
                return ParsedIntent::PolicyRejected {
                    reason: "NFT operator approval (setApprovalForAll) is strictly rejected by policy (MSG-03)".into(),
                };
            }
            if selector == [0xd5, 0x05, 0xac, 0xcf] {
                return ParsedIntent::PolicyRejected {
                    reason: "Permit2 transactions are strictly rejected by policy (MSG-03)".into(),
                };
            }

            if self.data.len() == 68 && selector == [0xa9, 0x05, 0x9c, 0xbb] {
                if self.value_wei != "0" {
                    return ParsedIntent::PolicyRejected {
                        reason: "ERC-20 transfer must not include a hidden native value".into(),
                    };
                }
                if self.data[4..16] != [0u8; 12] {
                    return ParsedIntent::PolicyRejected {
                        reason: "Dirty padding detected in ERC-20 transfer recipient: first 12 bytes must be zero".into(),
                    };
                }
                let recipient_bytes = &self.data[16..36];
                let token_recipient = format!("0x{}", hex::encode(recipient_bytes));
                let amount_bytes = &self.data[36..68];
                let amount_dec = bytes_to_dec_string(amount_bytes);

                ParsedIntent::Erc20Transfer {
                    chain_id: self.chain_id,
                    token_contract: recipient,
                    recipient: token_recipient,
                    token_amount_raw: amount_dec,
                    fee_cap_wei: fee_cap.to_string(),
                }
            } else {
                ParsedIntent::PolicyRejected {
                    reason:
                        "EIP-1559 payload data is not an empty transfer or known ERC-20 transfer"
                            .into(),
                }
            }
        } else {
            ParsedIntent::PolicyRejected {
                reason: "Data field is truncated (< 4 bytes)".into(),
            }
        }
    }
}

fn validate_signature_scalars(r: &[u8], s: &[u8]) -> Result<(), CoreError> {
    const ORDER: [u8; 32] = [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
        0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b,
        0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41,
    ];
    const HALF_ORDER: [u8; 32] = [
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x5d, 0x57, 0x6e, 0x73, 0x57, 0xa4, 0x50, 0x1d,
        0xdf, 0xe9, 0x2f, 0x46, 0x68, 0x1b, 0x20, 0xa0,
    ];
    if r.is_empty() || s.is_empty() {
        return Err(CoreError::InvalidTransactionFormat("Signature scalars must be nonzero".into()));
    }
    let mut padded_r = [0u8; 32];
    let mut padded_s = [0u8; 32];
    padded_r[32 - r.len()..].copy_from_slice(r);
    padded_s[32 - s.len()..].copy_from_slice(s);
    if padded_r >= ORDER || padded_s > HALF_ORDER {
        return Err(CoreError::InvalidTransactionFormat("Signature scalars are outside canonical bounds".into()));
    }
    Ok(())
}

pub fn keccak256(bytes: &[u8]) -> [u8; 32] {
    let mut hasher = Keccak::v256();
    hasher.update(bytes);
    let mut out = [0u8; 32];
    hasher.finalize(&mut out);
    out
}

pub fn bytes_to_dec_string(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return "0".to_string();
    }
    let mut result = vec![0u8];
    for &byte in bytes {
        let mut carry = byte as u32;
        for digit in result.iter_mut() {
            let temp = (*digit as u32) * 256 + carry;
            *digit = (temp % 10) as u8;
            carry = temp / 10;
        }
        while carry > 0 {
            result.push((carry % 10) as u8);
            carry /= 10;
        }
    }
    result.reverse();
    result.into_iter().map(|d| (b'0' + d) as char).collect()
}

pub fn dec_string_to_be_bytes(s: &str) -> Vec<u8> {
    let s = s.trim();
    if s.is_empty() || s == "0" {
        return vec![];
    }
    let mut bytes = vec![0u8];
    for ch in s.chars() {
        if !ch.is_ascii_digit() {
            continue;
        }
        let digit = ch.to_digit(10).unwrap();
        let mut carry = digit;
        for byte in bytes.iter_mut() {
            let temp = (*byte as u32) * 10 + carry;
            *byte = (temp & 0xff) as u8;
            carry = temp >> 8;
        }
        while carry > 0 {
            bytes.push((carry & 0xff) as u8);
            carry >>= 8;
        }
    }
    bytes.reverse();
    while bytes.len() > 1 && bytes[0] == 0 {
        bytes.remove(0);
    }
    bytes
}
