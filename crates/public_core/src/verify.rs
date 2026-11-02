use crate::error::CoreError;
use crate::evm::keccak256;
use secp256k1::ecdsa::{RecoverableSignature, RecoveryId};
use secp256k1::Message;

pub fn verify_ethereum_signature(
    digest: &[u8; 32],
    r: &[u8; 32],
    s: &[u8; 32],
    v: u8,
    expected_address: &str,
) -> Result<String, CoreError> {
    // 1. Strict canonical low-s check (BIP-62 / EIP-2)
    // Curve order / 2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0
    const HALF_CURVE_ORDER: [u8; 32] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D, 0xDF, 0xE9, 0x2F, 0x46,
        0x68, 0x1B, 0x20, 0xA0,
    ];
    if s > &HALF_CURVE_ORDER {
        return Err(CoreError::SignatureError("Malleable non-low-s signature rejected".into()));
    }

    // 2. Normalize recovery ID (v: 0/1 or 27/28)
    let recid_byte = match v {
        0 | 1 => v,
        27 | 28 => v - 27,
        _ => {
            return Err(CoreError::SignatureError(format!(
                "Invalid recovery ID v: {v}; expected 0, 1, 27, or 28"
            )));
        }
    };

    let recovery_id = RecoveryId::from_u8_masked(recid_byte);

    let mut compact_sig = [0u8; 64];
    compact_sig[0..32].copy_from_slice(r);
    compact_sig[32..64].copy_from_slice(s);

    let recoverable_sig = RecoverableSignature::from_compact(&compact_sig, recovery_id)
        .map_err(|e| CoreError::SignatureError(format!("Malformed signature: {e}")))?;

    let msg = Message::from_digest(*digest);

    let pubkey = recoverable_sig
        .recover_ecdsa(msg)
        .map_err(|e| CoreError::SignatureError(format!("Public key recovery failed: {e}")))?;

    let uncompressed = pubkey.serialize_uncompressed(); // 65 bytes: 0x04 || X || Y
    let pubkey_hash = keccak256(&uncompressed[1..65]);
    let raw_address = &pubkey_hash[12..32];
    let derived_address = to_checksum_address(raw_address);

    if !expected_address.is_empty()
        && !derived_address.eq_ignore_ascii_case(expected_address)
    {
        return Err(CoreError::AddressMismatch {
            expected: expected_address.to_string(),
            recovered: derived_address,
        });
    }

    Ok(derived_address)
}

pub fn to_checksum_address(address_bytes: &[u8]) -> String {
    let hex_addr = hex::encode(address_bytes);
    let hash = keccak256(hex_addr.as_bytes());
    let hash_hex = hex::encode(hash);

    let mut checksummed = String::with_capacity(42);
    checksummed.push_str("0x");

    for (i, ch) in hex_addr.chars().enumerate() {
        if ch.is_ascii_digit() {
            checksummed.push(ch);
        } else {
            let hash_nibble = u8::from_str_radix(&hash_hex[i..i + 1], 16).unwrap_or(0);
            if hash_nibble >= 8 {
                checksummed.push(ch.to_ascii_uppercase());
            } else {
                checksummed.push(ch.to_ascii_lowercase());
            }
        }
    }
    checksummed
}
