use ripemd::Ripemd160;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use thiserror::Error;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum BitcoinError {
    #[error("Serialization error: {0}")]
    SerializationError(String),

    #[error("Deserialization error: {0}")]
    DeserializationError(String),

    #[error("Invalid PSBT magic bytes")]
    InvalidMagic,

    #[error(
        "Missing non-witness UTXO for input {0}: full prior transaction required for fee security"
    )]
    MissingNonWitnessUtxo(usize),

    #[error("UTXO txid mismatch at input {index}: expected {expected}, actual {actual}")]
    UtxoTxidMismatch {
        index: usize,
        expected: String,
        actual: String,
    },

    #[error(
        "OutPoint index {vout} out of bounds for non-witness UTXO (len {len}) at input {index}"
    )]
    InvalidVoutIndex { index: usize, vout: u32, len: usize },

    #[error("Non-witness UTXO and witness UTXO value or script mismatch at input {0}")]
    UtxoMismatch(usize),

    #[error("Non-P2WPKH script at input {0}: only Native SegWit v0 P2WPKH is supported")]
    NonP2wpkhScript(usize),

    #[error("Unsupported sighash type {0}: only SIGHASH_ALL (0x01) is supported")]
    UnsupportedSighashType(u32),

    #[error(
        "Foreign input detected at index {0}: transactions containing foreign inputs are rejected"
    )]
    ForeignInputNotAllowed(usize),

    #[error("Unsupported feature: {0} (Taproot, PSBT v2, and multisig are rejected)")]
    UnsupportedFeature(String),

    #[error(
        "Negative fee or inflation detected: total input {input} sat < total output {output} sat"
    )]
    NegativeFeeOrInflation { input: u64, output: u64 },

    #[error("Excessive fee detected: fee {0} sat exceeds safety ceiling")]
    ExcessiveFee(u64),

    #[error("Bech32 error: {0}")]
    Bech32Error(String),
}

// -----------------------------------------------------------------------------
// Cryptographic Hash Primitives
// -----------------------------------------------------------------------------

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hasher.finalize().into()
}

pub fn double_sha256(data: &[u8]) -> [u8; 32] {
    sha256(&sha256(data))
}

pub fn ripemd160(data: &[u8]) -> [u8; 20] {
    let mut hasher = Ripemd160::new();
    hasher.update(data);
    hasher.finalize().into()
}

pub fn hash160(data: &[u8]) -> [u8; 20] {
    ripemd160(&sha256(data))
}

// -----------------------------------------------------------------------------
// Bech32 / BIP-173 Native SegWit (v0 P2WPKH) Address Encoding
// -----------------------------------------------------------------------------

const BECH32_CHARSET: &[u8; 32] = b"qpzry9x8gf2tvdw0s3jn54khce6mua7l";

fn bech32_polymod(values: &[u8]) -> u32 {
    let mut chk: u32 = 1;
    let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    for &v in values {
        let b = (chk >> 25) as u8;
        chk = ((chk & 0x1ffffff) << 5) ^ (v as u32);
        for (i, &gen) in generator.iter().enumerate() {
            if ((b >> i) & 1) != 0 {
                chk ^= gen;
            }
        }
    }
    chk
}

fn hrp_expand(hrp: &str) -> Vec<u8> {
    let mut v = Vec::with_capacity(hrp.len() * 2 + 1);
    for b in hrp.as_bytes() {
        v.push(b >> 5);
    }
    v.push(0);
    for b in hrp.as_bytes() {
        v.push(b & 31);
    }
    v
}

pub fn convert_bits(
    data: &[u8],
    frombits: u32,
    tobits: u32,
    pad: bool,
) -> Result<Vec<u8>, BitcoinError> {
    let mut acc: u32 = 0;
    let mut bits: u32 = 0;
    let mut ret = Vec::new();
    let maxv: u32 = (1 << tobits) - 1;
    let max_acc: u32 = (1 << (frombits + tobits - 1)) - 1;

    for &val in data {
        acc = ((acc << frombits) | (val as u32)) & max_acc;
        bits += frombits;
        while bits >= tobits {
            bits -= tobits;
            ret.push(((acc >> bits) & maxv) as u8);
        }
    }

    if pad {
        if bits > 0 {
            ret.push(((acc << (tobits - bits)) & maxv) as u8);
        }
    } else if bits >= frombits || ((acc << (tobits - bits)) & maxv) != 0 {
        return Err(BitcoinError::Bech32Error("Invalid bit padding".into()));
    }

    Ok(ret)
}

pub fn encode_p2wpkh_address(hrp: &str, pubkey_hash_20: &[u8; 20]) -> Result<String, BitcoinError> {
    let mut data_5bit = Vec::with_capacity(33);
    data_5bit.push(0); // witness version 0
    let converted = convert_bits(pubkey_hash_20, 8, 5, true)?;
    data_5bit.extend(converted);

    // Compute checksum
    let mut polymod_input = hrp_expand(hrp);
    polymod_input.extend(&data_5bit);
    polymod_input.extend(&[0, 0, 0, 0, 0, 0]);

    let mod_val = bech32_polymod(&polymod_input) ^ 1;
    let mut checksum = Vec::with_capacity(6);
    for i in (0..6).rev() {
        checksum.push(((mod_val >> (5 * i)) & 31) as u8);
    }

    let mut result = String::with_capacity(hrp.len() + 1 + data_5bit.len() + 6);
    result.push_str(hrp);
    result.push('1');
    for &d in &data_5bit {
        result.push(BECH32_CHARSET[d as usize] as char);
    }
    for &c in &checksum {
        result.push(BECH32_CHARSET[c as usize] as char);
    }

    Ok(result)
}

/// Validate a complete BIP173 address and return its native P2WPKH script.
pub fn decode_p2wpkh_address(address: &str, expected_hrp: &str) -> Result<Vec<u8>, BitcoinError> {
    let invalid =
        || BitcoinError::Bech32Error("Invalid P2WPKH address, checksum, or network".into());
    if address.len() > 90
        || !address.is_ascii()
        || (address.bytes().any(|c| c.is_ascii_lowercase())
            && address.bytes().any(|c| c.is_ascii_uppercase()))
    {
        return Err(invalid());
    }
    let normalized = address.to_ascii_lowercase();
    let (hrp, encoded) = normalized.rsplit_once('1').ok_or_else(invalid)?;
    if hrp != expected_hrp || encoded.len() != 39 {
        return Err(invalid());
    }
    let values: Vec<u8> = encoded
        .bytes()
        .map(|c| {
            BECH32_CHARSET
                .iter()
                .position(|known| *known == c)
                .map(|index| index as u8)
                .ok_or_else(invalid)
        })
        .collect::<Result<_, _>>()?;
    let mut checksum = hrp_expand(hrp);
    checksum.extend_from_slice(&values);
    if bech32_polymod(&checksum) != 1 || values[0] != 0 {
        return Err(invalid());
    }
    let hash = convert_bits(&values[1..values.len() - 6], 5, 8, false)?;
    if hash.len() != 20 {
        return Err(invalid());
    }
    let mut script = vec![0, 20];
    script.extend_from_slice(&hash);
    Ok(script)
}

// -----------------------------------------------------------------------------
// Bitcoin Serialization Helpers (CompactSize / VarInt)
// -----------------------------------------------------------------------------

pub fn read_varint(data: &[u8], cursor: &mut usize) -> Result<u64, BitcoinError> {
    if *cursor >= data.len() {
        return Err(BitcoinError::DeserializationError(
            "Unexpected EOF reading varint".into(),
        ));
    }
    let first = data[*cursor];
    *cursor += 1;
    match first {
        0..=0xfc => Ok(first as u64),
        0xfd => {
            if *cursor + 2 > data.len() {
                return Err(BitcoinError::DeserializationError(
                    "EOF reading 16-bit varint".into(),
                ));
            }
            let val = u16::from_le_bytes(data[*cursor..*cursor + 2].try_into().unwrap());
            *cursor += 2;
            if val < 0xfd {
                return Err(BitcoinError::DeserializationError(
                    "Noncanonical CompactSize".into(),
                ));
            }
            Ok(val as u64)
        }
        0xfe => {
            if *cursor + 4 > data.len() {
                return Err(BitcoinError::DeserializationError(
                    "EOF reading 32-bit varint".into(),
                ));
            }
            let val = u32::from_le_bytes(data[*cursor..*cursor + 4].try_into().unwrap());
            *cursor += 4;
            if val <= 0xffff {
                return Err(BitcoinError::DeserializationError(
                    "Noncanonical CompactSize".into(),
                ));
            }
            Ok(val as u64)
        }
        0xff => {
            if *cursor + 8 > data.len() {
                return Err(BitcoinError::DeserializationError(
                    "EOF reading 64-bit varint".into(),
                ));
            }
            let val = u64::from_le_bytes(data[*cursor..*cursor + 8].try_into().unwrap());
            *cursor += 8;
            if val <= 0xffffffff {
                return Err(BitcoinError::DeserializationError(
                    "Noncanonical CompactSize".into(),
                ));
            }
            Ok(val)
        }
    }
}

pub fn write_varint(val: u64, buf: &mut Vec<u8>) {
    match val {
        0..=0xfc => buf.push(val as u8),
        0xfd..=0xffff => {
            buf.push(0xfd);
            buf.extend_from_slice(&(val as u16).to_le_bytes());
        }
        0x10000..=0xffffffff => {
            buf.push(0xfe);
            buf.extend_from_slice(&(val as u32).to_le_bytes());
        }
        _ => {
            buf.push(0xff);
            buf.extend_from_slice(&val.to_le_bytes());
        }
    }
}

fn read_length(data: &[u8], cursor: &mut usize) -> Result<usize, BitcoinError> {
    usize::try_from(read_varint(data, cursor)?)
        .map_err(|_| BitcoinError::DeserializationError("Length exceeds platform bounds".into()))
}

// -----------------------------------------------------------------------------
// Transaction Data Structures
// -----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutPoint {
    pub txid: [u8; 32], // Little-endian bytes
    pub vout: u32,
}

impl OutPoint {
    pub fn txid_hex_display(&self) -> String {
        let mut rev = self.txid;
        rev.reverse();
        hex::encode(rev)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TxIn {
    pub previous_output: OutPoint,
    pub script_sig: Vec<u8>,
    pub sequence: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TxOut {
    pub value: u64, // Satoshis
    pub script_pubkey: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Transaction {
    pub version: i32,
    pub lock_time: u32,
    pub inputs: Vec<TxIn>,
    pub outputs: Vec<TxOut>,
}

impl Transaction {
    pub fn deserialize(data: &[u8], cursor: &mut usize) -> Result<Self, BitcoinError> {
        if *cursor + 4 > data.len() {
            return Err(BitcoinError::DeserializationError(
                "EOF reading tx version".into(),
            ));
        }
        let version = i32::from_le_bytes(data[*cursor..*cursor + 4].try_into().unwrap());
        *cursor += 4;

        let mut input_count = read_length(data, cursor)?;
        let has_witness = input_count == 0 && data.get(*cursor) == Some(&1);
        if has_witness {
            *cursor += 1;
            input_count = read_length(data, cursor)?;
        }
        if input_count == 0 || input_count > data.len().saturating_sub(*cursor) / 41 {
            return Err(BitcoinError::DeserializationError(
                "Invalid or excessive transaction input count".into(),
            ));
        }
        let mut inputs = Vec::with_capacity(input_count);
        for _ in 0..input_count {
            if *cursor + 36 > data.len() {
                return Err(BitcoinError::DeserializationError(
                    "EOF reading tx input outpoint".into(),
                ));
            }
            let mut txid = [0u8; 32];
            txid.copy_from_slice(&data[*cursor..*cursor + 32]);
            *cursor += 32;
            let vout = u32::from_le_bytes(data[*cursor..*cursor + 4].try_into().unwrap());
            *cursor += 4;

            let script_len = read_length(data, cursor)?;
            if script_len > data.len().saturating_sub(*cursor).saturating_sub(4) {
                return Err(BitcoinError::DeserializationError(
                    "EOF reading tx input script".into(),
                ));
            }
            let script_sig = data[*cursor..*cursor + script_len].to_vec();
            *cursor += script_len;

            let sequence = u32::from_le_bytes(data[*cursor..*cursor + 4].try_into().unwrap());
            *cursor += 4;

            inputs.push(TxIn {
                previous_output: OutPoint { txid, vout },
                script_sig,
                sequence,
            });
        }

        let output_count = read_length(data, cursor)?;
        if output_count == 0 || output_count > data.len().saturating_sub(*cursor) / 9 {
            return Err(BitcoinError::DeserializationError(
                "Invalid or excessive transaction output count".into(),
            ));
        }
        let mut outputs = Vec::with_capacity(output_count);
        for _ in 0..output_count {
            if *cursor + 8 > data.len() {
                return Err(BitcoinError::DeserializationError(
                    "EOF reading tx output value".into(),
                ));
            }
            let value = u64::from_le_bytes(data[*cursor..*cursor + 8].try_into().unwrap());
            *cursor += 8;

            let script_len = read_length(data, cursor)?;
            if script_len > data.len().saturating_sub(*cursor) {
                return Err(BitcoinError::DeserializationError(
                    "EOF reading tx output script".into(),
                ));
            }
            let script_pubkey = data[*cursor..*cursor + script_len].to_vec();
            *cursor += script_len;

            outputs.push(TxOut {
                value,
                script_pubkey,
            });
        }

        if has_witness {
            for _ in 0..input_count {
                let count = read_length(data, cursor)?;
                if count > data.len().saturating_sub(*cursor) {
                    return Err(BitcoinError::DeserializationError(
                        "Excessive witness count".into(),
                    ));
                }
                for _ in 0..count {
                    let len = read_length(data, cursor)?;
                    if len > data.len().saturating_sub(*cursor) {
                        return Err(BitcoinError::DeserializationError(
                            "Truncated witness".into(),
                        ));
                    }
                    *cursor += len;
                }
            }
        }
        if *cursor + 4 > data.len() {
            return Err(BitcoinError::DeserializationError(
                "EOF reading tx lock_time".into(),
            ));
        }
        let lock_time = u32::from_le_bytes(data[*cursor..*cursor + 4].try_into().unwrap());
        *cursor += 4;

        Ok(Transaction {
            version,
            lock_time,
            inputs,
            outputs,
        })
    }

    pub fn serialize_legacy(&self) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&self.version.to_le_bytes());
        write_varint(self.inputs.len() as u64, &mut buf);
        for inp in &self.inputs {
            buf.extend_from_slice(&inp.previous_output.txid);
            buf.extend_from_slice(&inp.previous_output.vout.to_le_bytes());
            write_varint(inp.script_sig.len() as u64, &mut buf);
            buf.extend_from_slice(&inp.script_sig);
            buf.extend_from_slice(&inp.sequence.to_le_bytes());
        }
        write_varint(self.outputs.len() as u64, &mut buf);
        for out in &self.outputs {
            buf.extend_from_slice(&out.value.to_le_bytes());
            write_varint(out.script_pubkey.len() as u64, &mut buf);
            buf.extend_from_slice(&out.script_pubkey);
        }
        buf.extend_from_slice(&self.lock_time.to_le_bytes());
        buf
    }

    pub fn txid(&self) -> [u8; 32] {
        double_sha256(&self.serialize_legacy())
    }

    pub fn txid_hex(&self) -> String {
        let mut rev = self.txid();
        rev.reverse();
        hex::encode(rev)
    }

    pub fn serialize_witness(&self, witnesses: &[Vec<Vec<u8>>]) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&self.version.to_le_bytes());
        buf.push(0x00); // SegWit marker
        buf.push(0x01); // SegWit flag
        write_varint(self.inputs.len() as u64, &mut buf);
        for inp in &self.inputs {
            buf.extend_from_slice(&inp.previous_output.txid);
            buf.extend_from_slice(&inp.previous_output.vout.to_le_bytes());
            write_varint(inp.script_sig.len() as u64, &mut buf);
            buf.extend_from_slice(&inp.script_sig);
            buf.extend_from_slice(&inp.sequence.to_le_bytes());
        }
        write_varint(self.outputs.len() as u64, &mut buf);
        for out in &self.outputs {
            buf.extend_from_slice(&out.value.to_le_bytes());
            write_varint(out.script_pubkey.len() as u64, &mut buf);
            buf.extend_from_slice(&out.script_pubkey);
        }
        for w in witnesses {
            write_varint(w.len() as u64, &mut buf);
            for item in w {
                write_varint(item.len() as u64, &mut buf);
                buf.extend_from_slice(item);
            }
        }
        buf.extend_from_slice(&self.lock_time.to_le_bytes());
        buf
    }
}

// -----------------------------------------------------------------------------
// BIP-174 PSBT v0 Data Structures & Parser
// -----------------------------------------------------------------------------

const PSBT_MAGIC: &[u8; 5] = b"psbt\xff";

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PsbtInput {
    pub non_witness_utxo: Option<Transaction>,
    pub witness_utxo: Option<TxOut>,
    pub partial_sigs: BTreeMap<Vec<u8>, Vec<u8>>, // pubkey -> der_signature || sighash_byte
    pub sighash_type: Option<u32>,
    pub bip32_derivation: BTreeMap<Vec<u8>, ([u8; 4], Vec<u32>)>, // pubkey -> (fingerprint, path)
    pub unknown: BTreeMap<Vec<u8>, Vec<u8>>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PsbtOutput {
    pub bip32_derivation: BTreeMap<Vec<u8>, ([u8; 4], Vec<u32>)>,
    pub unknown: BTreeMap<Vec<u8>, Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Psbt {
    pub unsigned_tx: Transaction,
    pub inputs: Vec<PsbtInput>,
    pub outputs: Vec<PsbtOutput>,
    pub unknown_global: BTreeMap<Vec<u8>, Vec<u8>>,
}

type PsbtKv = (Vec<u8>, Vec<u8>);

#[allow(clippy::type_complexity)]
fn read_key_value_pair(data: &[u8], cursor: &mut usize) -> Result<Option<PsbtKv>, BitcoinError> {
    if *cursor >= data.len() {
        return Err(BitcoinError::DeserializationError(
            "EOF reading PSBT map".into(),
        ));
    }
    let key_len = read_length(data, cursor)?;
    if key_len == 0 {
        return Ok(None); // 0x00 separator marks end of map
    }
    if key_len > data.len().saturating_sub(*cursor) {
        return Err(BitcoinError::DeserializationError(
            "EOF reading PSBT key".into(),
        ));
    }
    let key = data[*cursor..*cursor + key_len].to_vec();
    *cursor += key_len;

    let val_len = read_length(data, cursor)?;
    if val_len > data.len().saturating_sub(*cursor) {
        return Err(BitcoinError::DeserializationError(
            "EOF reading PSBT value".into(),
        ));
    }
    let val = data[*cursor..*cursor + val_len].to_vec();
    *cursor += val_len;

    Ok(Some((key, val)))
}

impl Psbt {
    pub fn deserialize(data: &[u8]) -> Result<Self, BitcoinError> {
        if data.len() > 128 * 1024 {
            return Err(BitcoinError::DeserializationError(
                "PSBT exceeds 128 KiB".into(),
            ));
        }
        if data.len() < 5 || &data[0..5] != PSBT_MAGIC {
            return Err(BitcoinError::InvalidMagic);
        }
        let mut cursor = 5;

        // 1. Read Global Map
        let mut unsigned_tx: Option<Transaction> = None;
        let mut unknown_global = BTreeMap::new();

        let mut seen = std::collections::BTreeSet::new();
        while let Some((key, val)) = read_key_value_pair(data, &mut cursor)? {
            if !seen.insert(key.clone()) {
                return Err(BitcoinError::DeserializationError(
                    "Duplicate PSBT key".into(),
                ));
            }
            if key.is_empty() {
                continue;
            }
            match key[0] {
                0x00 => {
                    if key.len() != 1 {
                        return Err(BitcoinError::DeserializationError(
                            "Invalid PSBT_GLOBAL_UNSIGNED_TX key".into(),
                        ));
                    }
                    let mut tx_cursor = 0;
                    let tx = Transaction::deserialize(&val, &mut tx_cursor)?;
                    if tx_cursor != val.len() || val.get(4) == Some(&0) {
                        return Err(BitcoinError::DeserializationError(
                            "Unsigned transaction must use exact legacy encoding".into(),
                        ));
                    }
                    // Must have empty script_sig per BIP-174
                    for inp in &tx.inputs {
                        if !inp.script_sig.is_empty() {
                            return Err(BitcoinError::DeserializationError(
                                "Unsigned tx must have empty script_sig".into(),
                            ));
                        }
                    }
                    unsigned_tx = Some(tx);
                }
                _ => {
                    unknown_global.insert(key, val);
                }
            }
        }

        let unsigned_tx = unsigned_tx.ok_or_else(|| {
            BitcoinError::DeserializationError("PSBT missing global unsigned transaction".into())
        })?;

        // 2. Read Inputs Map
        let mut inputs = Vec::with_capacity(unsigned_tx.inputs.len());
        for _ in 0..unsigned_tx.inputs.len() {
            let mut psbt_in = PsbtInput::default();
            let mut seen = std::collections::BTreeSet::new();
            while let Some((key, val)) = read_key_value_pair(data, &mut cursor)? {
                if !seen.insert(key.clone()) {
                    return Err(BitcoinError::DeserializationError(
                        "Duplicate PSBT key".into(),
                    ));
                }
                if key.is_empty() {
                    continue;
                }
                match key[0] {
                    0x00 => {
                        // PSBT_IN_NON_WITNESS_UTXO
                        let mut utxo_cursor = 0;
                        let tx = Transaction::deserialize(&val, &mut utxo_cursor)?;
                        if key.len() != 1 || utxo_cursor != val.len() {
                            return Err(BitcoinError::DeserializationError(
                                "Malformed non-witness UTXO".into(),
                            ));
                        }
                        psbt_in.non_witness_utxo = Some(tx);
                    }
                    0x01 => {
                        // PSBT_IN_WITNESS_UTXO
                        if val.len() < 8 {
                            return Err(BitcoinError::DeserializationError(
                                "Witness UTXO too short".into(),
                            ));
                        }
                        let mut utxo_cursor = 0;
                        let value = u64::from_le_bytes(val[0..8].try_into().unwrap());
                        utxo_cursor += 8;
                        let script_len = read_length(&val, &mut utxo_cursor)?;
                        if key.len() != 1 || script_len != val.len().saturating_sub(utxo_cursor) {
                            return Err(BitcoinError::DeserializationError(
                                "Malformed witness UTXO".into(),
                            ));
                        }
                        let script_pubkey = val[utxo_cursor..utxo_cursor + script_len].to_vec();
                        psbt_in.witness_utxo = Some(TxOut {
                            value,
                            script_pubkey,
                        });
                    }
                    0x02 => {
                        // PSBT_IN_PARTIAL_SIG: key = 0x02 || pubkey
                        let pubkey = key[1..].to_vec();
                        psbt_in.partial_sigs.insert(pubkey, val);
                    }
                    0x03 => {
                        // PSBT_IN_SIGHASH_TYPE: 4 bytes LE
                        if key.len() != 1 || val.len() != 4 {
                            return Err(BitcoinError::DeserializationError(
                                "Malformed sighash type".into(),
                            ));
                        }
                        if val.len() == 4 {
                            psbt_in.sighash_type =
                                Some(u32::from_le_bytes(val[0..4].try_into().unwrap()));
                        }
                    }
                    0x06 => {
                        // PSBT_IN_BIP32_DERIVATION: key = 0x06 || pubkey
                        if key.len() != 34 || val.len() < 4 || (val.len() - 4) % 4 != 0 {
                            return Err(BitcoinError::DeserializationError(
                                "Malformed BIP32 derivation".into(),
                            ));
                        }
                        if val.len() >= 4 && (val.len() - 4) % 4 == 0 {
                            let mut fp = [0u8; 4];
                            fp.copy_from_slice(&val[0..4]);
                            let mut path = Vec::new();
                            for chunk in val[4..].chunks(4) {
                                path.push(u32::from_le_bytes(chunk.try_into().unwrap()));
                            }
                            psbt_in
                                .bip32_derivation
                                .insert(key[1..].to_vec(), (fp, path));
                        }
                    }
                    _ => {
                        psbt_in.unknown.insert(key, val);
                    }
                }
            }
            inputs.push(psbt_in);
        }

        // 3. Read Outputs Map
        let mut outputs = Vec::with_capacity(unsigned_tx.outputs.len());
        for _ in 0..unsigned_tx.outputs.len() {
            let mut psbt_out = PsbtOutput::default();
            let mut seen = std::collections::BTreeSet::new();
            while let Some((key, val)) = read_key_value_pair(data, &mut cursor)? {
                if !seen.insert(key.clone()) {
                    return Err(BitcoinError::DeserializationError(
                        "Duplicate PSBT key".into(),
                    ));
                }
                if key.is_empty() {
                    continue;
                }
                match key[0] {
                    0x02 => {
                        // PSBT_OUT_BIP32_DERIVATION
                        if key.len() != 34 || val.len() < 4 || (val.len() - 4) % 4 != 0 {
                            return Err(BitcoinError::DeserializationError(
                                "Malformed BIP32 derivation".into(),
                            ));
                        }
                        if val.len() >= 4 && (val.len() - 4) % 4 == 0 {
                            let mut fp = [0u8; 4];
                            fp.copy_from_slice(&val[0..4]);
                            let mut path = Vec::new();
                            for chunk in val[4..].chunks(4) {
                                path.push(u32::from_le_bytes(chunk.try_into().unwrap()));
                            }
                            psbt_out
                                .bip32_derivation
                                .insert(key[1..].to_vec(), (fp, path));
                        }
                    }
                    _ => {
                        psbt_out.unknown.insert(key, val);
                    }
                }
            }
            outputs.push(psbt_out);
        }

        if cursor != data.len() {
            return Err(BitcoinError::DeserializationError(
                "Trailing PSBT bytes".into(),
            ));
        }
        Ok(Psbt {
            unsigned_tx,
            inputs,
            outputs,
            unknown_global,
        })
    }

    pub fn serialize(&self) -> Vec<u8> {
        let mut buf = Vec::from(*PSBT_MAGIC);

        // 1. Global map
        buf.push(1); // key len
        buf.push(0x00); // PSBT_GLOBAL_UNSIGNED_TX
        let raw_tx = self.unsigned_tx.serialize_legacy();
        write_varint(raw_tx.len() as u64, &mut buf);
        buf.extend_from_slice(&raw_tx);

        for (k, v) in &self.unknown_global {
            write_varint(k.len() as u64, &mut buf);
            buf.extend_from_slice(k);
            write_varint(v.len() as u64, &mut buf);
            buf.extend_from_slice(v);
        }
        buf.push(0x00); // End of global map

        // 2. Input maps
        for inp in &self.inputs {
            if let Some(ref non_wit) = inp.non_witness_utxo {
                buf.push(1);
                buf.push(0x00);
                let raw_utxo = non_wit.serialize_legacy();
                write_varint(raw_utxo.len() as u64, &mut buf);
                buf.extend_from_slice(&raw_utxo);
            }
            if let Some(ref wit) = inp.witness_utxo {
                buf.push(1);
                buf.push(0x01);
                let mut wit_bytes = Vec::new();
                wit_bytes.extend_from_slice(&wit.value.to_le_bytes());
                write_varint(wit.script_pubkey.len() as u64, &mut wit_bytes);
                wit_bytes.extend_from_slice(&wit.script_pubkey);
                write_varint(wit_bytes.len() as u64, &mut buf);
                buf.extend_from_slice(&wit_bytes);
            }
            for (pubk, sig) in &inp.partial_sigs {
                let mut k = Vec::with_capacity(1 + pubk.len());
                k.push(0x02);
                k.extend_from_slice(pubk);
                write_varint(k.len() as u64, &mut buf);
                buf.extend_from_slice(&k);
                write_varint(sig.len() as u64, &mut buf);
                buf.extend_from_slice(sig);
            }
            if let Some(st) = inp.sighash_type {
                buf.push(1);
                buf.push(0x03);
                buf.push(4); // len
                buf.extend_from_slice(&st.to_le_bytes());
            }
            for (pubk, (fp, path)) in &inp.bip32_derivation {
                let mut k = Vec::with_capacity(1 + pubk.len());
                k.push(0x06);
                k.extend_from_slice(pubk);
                write_varint(k.len() as u64, &mut buf);
                buf.extend_from_slice(&k);
                let mut v = Vec::with_capacity(4 + path.len() * 4);
                v.extend_from_slice(fp);
                for idx in path {
                    v.extend_from_slice(&idx.to_le_bytes());
                }
                write_varint(v.len() as u64, &mut buf);
                buf.extend_from_slice(&v);
            }
            for (k, v) in &inp.unknown {
                write_varint(k.len() as u64, &mut buf);
                buf.extend_from_slice(k);
                write_varint(v.len() as u64, &mut buf);
                buf.extend_from_slice(v);
            }
            buf.push(0x00); // End of input map
        }

        // 3. Output maps
        for out in &self.outputs {
            for (pubk, (fp, path)) in &out.bip32_derivation {
                let mut k = Vec::with_capacity(1 + pubk.len());
                k.push(0x02);
                k.extend_from_slice(pubk);
                write_varint(k.len() as u64, &mut buf);
                buf.extend_from_slice(&k);
                let mut v = Vec::with_capacity(4 + path.len() * 4);
                v.extend_from_slice(fp);
                for idx in path {
                    v.extend_from_slice(&idx.to_le_bytes());
                }
                write_varint(v.len() as u64, &mut buf);
                buf.extend_from_slice(&v);
            }
            for (k, v) in &out.unknown {
                write_varint(k.len() as u64, &mut buf);
                buf.extend_from_slice(k);
                write_varint(v.len() as u64, &mut buf);
                buf.extend_from_slice(v);
            }
            buf.push(0x00); // End of output map
        }

        buf
    }
}

// -----------------------------------------------------------------------------
// BIP-143 SIGHASH_ALL Calculation for Native SegWit (v0 P2WPKH)
// -----------------------------------------------------------------------------

pub fn compute_bip143_sighash(
    tx: &Transaction,
    input_index: usize,
    script_code: &[u8],
    amount: u64,
    sighash_type: u32,
) -> Result<[u8; 32], BitcoinError> {
    if sighash_type != 1 {
        return Err(BitcoinError::UnsupportedSighashType(sighash_type));
    }
    if input_index >= tx.inputs.len() {
        return Err(BitcoinError::SerializationError(
            "Input index out of bounds".into(),
        ));
    }

    // 1. hashPrevouts
    let mut prevouts = Vec::new();
    for inp in &tx.inputs {
        prevouts.extend_from_slice(&inp.previous_output.txid);
        prevouts.extend_from_slice(&inp.previous_output.vout.to_le_bytes());
    }
    let hash_prevouts = double_sha256(&prevouts);

    // 2. hashSequence
    let mut sequences = Vec::new();
    for inp in &tx.inputs {
        sequences.extend_from_slice(&inp.sequence.to_le_bytes());
    }
    let hash_sequence = double_sha256(&sequences);

    // 3. hashOutputs
    let mut outputs_bytes = Vec::new();
    for out in &tx.outputs {
        outputs_bytes.extend_from_slice(&out.value.to_le_bytes());
        write_varint(out.script_pubkey.len() as u64, &mut outputs_bytes);
        outputs_bytes.extend_from_slice(&out.script_pubkey);
    }
    let hash_outputs = double_sha256(&outputs_bytes);

    // 4. Preimage assembly per BIP-143 Section 3
    let mut preimage = Vec::with_capacity(156 + script_code.len());
    preimage.extend_from_slice(&tx.version.to_le_bytes());
    preimage.extend_from_slice(&hash_prevouts);
    preimage.extend_from_slice(&hash_sequence);

    // outpoint
    let this_in = &tx.inputs[input_index];
    preimage.extend_from_slice(&this_in.previous_output.txid);
    preimage.extend_from_slice(&this_in.previous_output.vout.to_le_bytes());

    // scriptCode (with length prefix)
    write_varint(script_code.len() as u64, &mut preimage);
    preimage.extend_from_slice(script_code);

    // amount
    preimage.extend_from_slice(&amount.to_le_bytes());

    // sequence
    preimage.extend_from_slice(&this_in.sequence.to_le_bytes());

    preimage.extend_from_slice(&hash_outputs);
    preimage.extend_from_slice(&tx.lock_time.to_le_bytes());
    preimage.extend_from_slice(&sighash_type.to_le_bytes());

    Ok(double_sha256(&preimage))
}

// -----------------------------------------------------------------------------
// Fail-Closed PSBT Security Policy & Audit Engine
// -----------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutputDisplay {
    pub address: String,
    pub amount_sat: u64,
    pub is_change: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PsbtPolicyVerdict {
    pub total_input_sat: u64,
    pub total_output_sat: u64,
    pub fee_sat: u64,
    pub inputs_verified_count: usize,
    pub destination_outputs: Vec<OutputDisplay>,
    pub change_outputs: Vec<OutputDisplay>,
    pub master_fingerprint: String,
}

pub fn verify_and_audit_psbt(
    psbt: &Psbt,
    vault_fingerprint: &[u8; 4],
    network_hrp: &str,
) -> Result<PsbtPolicyVerdict, BitcoinError> {
    if psbt.inputs.is_empty()
        || psbt.outputs.is_empty()
        || !psbt.unknown_global.is_empty()
        || psbt.inputs.iter().any(|input| !input.unknown.is_empty())
        || psbt.outputs.iter().any(|output| !output.unknown.is_empty())
    {
        return Err(BitcoinError::UnsupportedFeature(
            "Empty transaction or unsupported PSBT fields".into(),
        ));
    }
    let mut outpoints = std::collections::BTreeSet::new();
    for input in &psbt.unsigned_tx.inputs {
        if !outpoints.insert((input.previous_output.txid, input.previous_output.vout)) {
            return Err(BitcoinError::SerializationError(
                "Duplicate transaction input".into(),
            ));
        }
    }
    if psbt.inputs.len() != psbt.unsigned_tx.inputs.len() {
        return Err(BitcoinError::SerializationError(
            "PSBT input count does not match unsigned tx input count".into(),
        ));
    }
    if psbt.outputs.len() != psbt.unsigned_tx.outputs.len() {
        return Err(BitcoinError::SerializationError(
            "PSBT output count does not match unsigned tx output count".into(),
        ));
    }

    let mut total_input_sat: u64 = 0;

    // Audit each input
    for (i, (inp, txin)) in psbt
        .inputs
        .iter()
        .zip(psbt.unsigned_tx.inputs.iter())
        .enumerate()
    {
        // 1. Mandatory Non-witness UTXO check
        let non_wit = inp
            .non_witness_utxo
            .as_ref()
            .ok_or(BitcoinError::MissingNonWitnessUtxo(i))?;
        let computed_txid = non_wit.txid();
        if computed_txid != txin.previous_output.txid {
            let mut exp = txin.previous_output.txid;
            exp.reverse();
            let mut act = computed_txid;
            act.reverse();
            return Err(BitcoinError::UtxoTxidMismatch {
                index: i,
                expected: hex::encode(exp),
                actual: hex::encode(act),
            });
        }

        let vout = txin.previous_output.vout as usize;
        if vout >= non_wit.outputs.len() {
            return Err(BitcoinError::InvalidVoutIndex {
                index: i,
                vout: txin.previous_output.vout,
                len: non_wit.outputs.len(),
            });
        }

        let utxo_out = &non_wit.outputs[vout];

        // 2. Cross-verify witness_utxo if present
        if let Some(ref wit) = inp.witness_utxo {
            if wit.value != utxo_out.value || wit.script_pubkey != utxo_out.script_pubkey {
                return Err(BitcoinError::UtxoMismatch(i));
            }
        }

        // 3. Script must be P2WPKH: 0x00, 0x14, <20-byte hash>
        if utxo_out.script_pubkey.len() != 22
            || utxo_out.script_pubkey[0] != 0x00
            || utxo_out.script_pubkey[1] != 0x14
        {
            return Err(BitcoinError::NonP2wpkhScript(i));
        }

        // 4. Sighash type must be 1 (SIGHASH_ALL)
        if let Some(st) = inp.sighash_type {
            if st != 1 {
                return Err(BitcoinError::UnsupportedSighashType(st));
            }
        }

        // 5. Must be owned by vault: bip32_derivation must match fingerprint
        let mut is_owned = false;
        for (fp, path) in inp.bip32_derivation.values() {
            if fp == vault_fingerprint
                && path.len() >= 4
                && path[0] == (84 | 0x80000000)
                && path[path.len() - 2] <= 1
            {
                is_owned = true;
                break;
            }
        }
        if !is_owned {
            return Err(BitcoinError::ForeignInputNotAllowed(i));
        }

        total_input_sat = total_input_sat
            .checked_add(utxo_out.value)
            .filter(|total| *total <= 21_000_000 * 100_000_000)
            .ok_or_else(|| BitcoinError::SerializationError("Input satoshi overflow".into()))?;
    }

    // Audit each output
    let mut total_output_sat: u64 = 0;
    let mut destination_outputs = Vec::new();
    let mut change_outputs = Vec::new();

    for (out, txout) in psbt.outputs.iter().zip(psbt.unsigned_tx.outputs.iter()) {
        total_output_sat = total_output_sat
            .checked_add(txout.value)
            .filter(|total| *total <= 21_000_000 * 100_000_000)
            .ok_or_else(|| BitcoinError::SerializationError("Output satoshi overflow".into()))?;

        // Determine address if P2WPKH
        let addr_str = if txout.script_pubkey.len() == 22
            && txout.script_pubkey[0] == 0x00
            && txout.script_pubkey[1] == 0x14
        {
            let mut pkh = [0u8; 20];
            pkh.copy_from_slice(&txout.script_pubkey[2..22]);
            encode_p2wpkh_address(network_hrp, &pkh)?
        } else {
            format!("script:{}", hex::encode(&txout.script_pubkey))
        };

        // Change verification: must have bip32_derivation matching fingerprint AND change branch (1)
        let mut is_change = false;
        for (fp, path) in out.bip32_derivation.values() {
            if fp == vault_fingerprint
                && path.len() >= 4
                && path[0] == (84 | 0x80000000)
                && path[path.len() - 2] == 1
            {
                is_change = true;
                break;
            }
        }

        let item = OutputDisplay {
            address: addr_str,
            amount_sat: txout.value,
            is_change,
        };

        if is_change {
            change_outputs.push(item);
        } else {
            destination_outputs.push(item);
        }
    }

    if total_input_sat < total_output_sat {
        return Err(BitcoinError::NegativeFeeOrInflation {
            input: total_input_sat,
            output: total_output_sat,
        });
    }

    let fee_sat = total_input_sat - total_output_sat;
    // Safety check: fee cannot exceed 0.05 BTC (5,000,000 sats)
    if fee_sat > 5_000_000 {
        return Err(BitcoinError::ExcessiveFee(fee_sat));
    }

    Ok(PsbtPolicyVerdict {
        total_input_sat,
        total_output_sat,
        fee_sat,
        inputs_verified_count: psbt.inputs.len(),
        destination_outputs,
        change_outputs,
        master_fingerprint: hex::encode(vault_fingerprint),
    })
}

pub fn finalize_and_extract_p2wpkh_psbt(psbt: &Psbt) -> Result<Vec<u8>, BitcoinError> {
    if psbt.inputs.is_empty() || psbt.inputs.len() != psbt.unsigned_tx.inputs.len() {
        return Err(BitcoinError::SerializationError(
            "Invalid PSBT input count".into(),
        ));
    }
    let secp = secp256k1::Secp256k1::verification_only();
    let mut witnesses = Vec::new();
    for (i, input) in psbt.inputs.iter().enumerate() {
        if input.partial_sigs.len() != 1 || input.sighash_type.unwrap_or(1) != 1 {
            return Err(BitcoinError::SerializationError(
                "Expected exactly one SIGHASH_ALL signature".into(),
            ));
        }
        let (pubkey, signature) = input.partial_sigs.iter().next().unwrap();
        let previous = input
            .non_witness_utxo
            .as_ref()
            .ok_or(BitcoinError::MissingNonWitnessUtxo(i))?;
        let outpoint = &psbt.unsigned_tx.inputs[i].previous_output;
        if previous.txid() != outpoint.txid {
            return Err(BitcoinError::UtxoMismatch(i));
        }
        let output = previous
            .outputs
            .get(outpoint.vout as usize)
            .ok_or(BitcoinError::UtxoMismatch(i))?;
        let key = secp256k1::PublicKey::from_slice(pubkey)
            .map_err(|e| BitcoinError::SerializationError(e.to_string()))?;
        let pkh = hash160(&key.serialize());
        let mut expected_script = vec![0, 20];
        expected_script.extend_from_slice(&pkh);
        if pubkey.len() != 33
            || output.script_pubkey != expected_script
            || input.witness_utxo.as_ref().is_some_and(|w| w != output)
        {
            return Err(BitcoinError::UtxoMismatch(i));
        }
        if signature.last() != Some(&1) {
            return Err(BitcoinError::UnsupportedSighashType(
                signature.last().copied().unwrap_or(0) as u32,
            ));
        }
        let sig = secp256k1::ecdsa::Signature::from_der(&signature[..signature.len() - 1])
            .map_err(|e| BitcoinError::SerializationError(e.to_string()))?;
        let mut normalized = sig;
        normalized.normalize_s();
        if normalized != sig {
            return Err(BitcoinError::SerializationError(
                "Noncanonical high-S signature".into(),
            ));
        }
        let mut script_code = vec![0x76, 0xa9, 0x14];
        script_code.extend_from_slice(&pkh);
        script_code.extend_from_slice(&[0x88, 0xac]);
        let digest = compute_bip143_sighash(&psbt.unsigned_tx, i, &script_code, output.value, 1)?;
        #[allow(deprecated)]
        secp.verify_ecdsa(secp256k1::Message::from_digest(digest), &sig, &key)
            .map_err(|e| {
                BitcoinError::SerializationError(format!("Signature verification failed: {e}"))
            })?;
        witnesses.push(vec![signature.clone(), pubkey.clone()]);
    }
    Ok(psbt.unsigned_tx.serialize_witness(&witnesses))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bip143_official_native_p2wpkh_digest_vector() {
        // Bitcoin BIP143, Native P2WPKH example (public-domain specification).
        // https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki#native-p2wpkh
        let bytes = hex::decode("0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f0000000000eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac11000000").unwrap();
        let tx = Transaction::deserialize(&bytes, &mut 0).unwrap();
        let code = hex::decode("76a9141d0f172a0ecb48aee1be1f2687d2963ae33f71a188ac").unwrap();
        let digest = compute_bip143_sighash(&tx, 1, &code, 600_000_000, 1).unwrap();
        assert_eq!(
            hex::encode(digest),
            "c37af31116d1b27caf68aae9e3ac82f1477929014d5b917657d0eb49478cb670"
        );
        assert!(compute_bip143_sighash(&tx, 1, &code, 600_000_000, 2).is_err());
    }

    #[test]
    fn bitcoin_untrusted_lengths_and_addresses_fail_closed() {
        let oversized_count = hex::decode("02000000ffffffffffffffffff").unwrap();
        assert!(Transaction::deserialize(&oversized_count, &mut 0).is_err());
        let address = encode_p2wpkh_address("bcrt", &[7; 20]).unwrap();
        assert_eq!(
            decode_p2wpkh_address(&address, "bcrt").unwrap(),
            [vec![0, 20], vec![7; 20]].concat()
        );
        assert!(decode_p2wpkh_address(&address, "bc").is_err());
        assert!(decode_p2wpkh_address(&(address.clone() + "q"), "bcrt").is_err());
        assert!(decode_p2wpkh_address(&address.replacen('b', "B", 1), "bcrt").is_err());
        assert!(read_varint(&[0xfd, 1, 0], &mut 0).is_err());
    }

    #[test]
    fn test_btc_01_bech32_and_bip84_address_vectors() {
        // BIP-84 test vector 1 pubkey hash for m/84'/0'/0'/0/0
        // Expected address: bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu
        let pkh_hex = "c0cebcd6c3d3ca8c75dc5ec62ebe55330ef910e2";
        let pkh_bytes: [u8; 20] = hex::decode(pkh_hex).unwrap().try_into().unwrap();
        let addr = encode_p2wpkh_address("bc", &pkh_bytes).unwrap();
        assert_eq!(addr, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu");

        // Regtest prefix
        let addr_regtest = encode_p2wpkh_address("bcrt", &pkh_bytes).unwrap();
        assert_eq!(addr_regtest, "bcrt1qcr8te4kr609gcawutmrza0j4xv80jy8zeqchgx");
    }

    #[test]
    fn test_btc_02_psbt_v0_roundtrip_serialization() {
        let _dummy_txid = [0xabu8; 32];
        let prev_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: [0x11u8; 32],
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xffffffff,
            }],
            outputs: vec![TxOut {
                value: 100_000,
                script_pubkey: vec![
                    0x00, 0x14, 0x79, 0x75, 0xb5, 0x4d, 0x23, 0xd8, 0x6e, 0x09, 0xc4, 0x2c, 0x84,
                    0xd3, 0x40, 0xde, 0x8e, 0x79, 0xe0, 0xb4, 0x2e, 0x9e,
                ],
            }],
        };
        let computed_txid = prev_tx.txid();

        let unsigned_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: computed_txid,
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xfffffffd,
            }],
            outputs: vec![
                TxOut {
                    value: 80_000,
                    script_pubkey: vec![
                        0x00, 0x14, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa,
                        0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44,
                    ],
                },
                TxOut {
                    value: 18_000,
                    script_pubkey: vec![
                        0x00, 0x14, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee,
                        0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
                    ],
                },
            ],
        };

        let mut in_derivations = BTreeMap::new();
        in_derivations.insert(
            vec![0x02; 33],
            (
                [0x73, 0xc5, 0xda, 0x0a],
                vec![84 | 0x80000000, 0x80000000, 0x80000000, 0, 0],
            ),
        );
        let psbt_in = PsbtInput {
            non_witness_utxo: Some(prev_tx),
            witness_utxo: Some(TxOut {
                value: 100_000,
                script_pubkey: vec![
                    0x00, 0x14, 0x79, 0x75, 0xb5, 0x4d, 0x23, 0xd8, 0x6e, 0x09, 0xc4, 0x2c, 0x84,
                    0xd3, 0x40, 0xde, 0x8e, 0x79, 0xe0, 0xb4, 0x2e, 0x9e,
                ],
            }),
            sighash_type: Some(1),
            bip32_derivation: in_derivations,
            ..Default::default()
        };

        let mut out_derivations = BTreeMap::new();
        out_derivations.insert(
            vec![0x03; 33],
            (
                [0x73, 0xc5, 0xda, 0x0a],
                vec![84 | 0x80000000, 0x80000000, 0x80000000, 1, 0],
            ),
        );
        let psbt_out_change = PsbtOutput {
            bip32_derivation: out_derivations,
            ..Default::default()
        };

        let psbt = Psbt {
            unsigned_tx,
            inputs: vec![psbt_in],
            outputs: vec![PsbtOutput::default(), psbt_out_change],
            unknown_global: BTreeMap::new(),
        };

        let raw = psbt.serialize();
        assert!(&raw[0..5] == PSBT_MAGIC);

        let deserialized = Psbt::deserialize(&raw).expect("Deserialization must succeed");
        let mut trailing = raw.clone();
        trailing.push(0);
        assert!(Psbt::deserialize(&trailing).is_err());
        assert!(Psbt::deserialize(&raw[..raw.len() - 1]).is_err());
        let mut value_cursor = 7;
        let tx_size = read_length(&raw, &mut value_cursor).unwrap();
        let global_end = value_cursor + tx_size;
        let duplicate = [&raw[..global_end], &raw[5..global_end], &raw[global_end..]].concat();
        assert!(
            Psbt::deserialize(&duplicate).is_err(),
            "Duplicate global transaction must fail"
        );
        let mut hostile_witness = raw[..global_end + 1].to_vec();
        hostile_witness.extend_from_slice(&[1, 1, 17]); // input key 1; 17-byte value
        hostile_witness.extend_from_slice(&[0; 8]);
        hostile_witness.push(0xff);
        hostile_witness.extend_from_slice(&u64::MAX.to_le_bytes());
        hostile_witness.extend_from_slice(&[0, 0, 0]);
        assert!(
            Psbt::deserialize(&hostile_witness).is_err(),
            "Truncated witness UTXO must not panic"
        );
        assert_eq!(deserialized.unsigned_tx.version, 2);
        assert_eq!(deserialized.inputs.len(), 1);
        assert_eq!(deserialized.outputs.len(), 2);
        assert!(deserialized.inputs[0].non_witness_utxo.is_some());
    }

    #[test]
    fn test_btc_03_policy_verification_success_and_fee_audit() {
        let prev_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: [0x22u8; 32],
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xffffffff,
            }],
            outputs: vec![TxOut {
                value: 500_000, // 0.005 BTC
                script_pubkey: vec![
                    0x00, 0x14, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
                    0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11,
                ],
            }],
        };
        let computed_txid = prev_tx.txid();

        let unsigned_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: computed_txid,
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xfffffffd,
            }],
            outputs: vec![
                TxOut {
                    value: 400_000,
                    script_pubkey: vec![
                        0x00, 0x14, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
                        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
                    ],
                },
                TxOut {
                    value: 98_000, // Change output
                    script_pubkey: vec![
                        0x00, 0x14, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
                        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
                    ],
                },
            ],
        };

        let mut in_derivations = BTreeMap::new();
        in_derivations.insert(
            vec![0x02; 33],
            (
                [0x73, 0xc5, 0xda, 0x0a],
                vec![84 | 0x80000000, 0x80000000, 0x80000000, 0, 0],
            ),
        );
        let psbt_in = PsbtInput {
            non_witness_utxo: Some(prev_tx),
            bip32_derivation: in_derivations,
            ..Default::default()
        };

        let mut out_derivations = BTreeMap::new();
        out_derivations.insert(
            vec![0x03; 33],
            (
                [0x73, 0xc5, 0xda, 0x0a],
                vec![84 | 0x80000000, 0x80000000, 0x80000000, 1, 0],
            ),
        );
        let psbt_out_change = PsbtOutput {
            bip32_derivation: out_derivations,
            ..Default::default()
        };

        let psbt = Psbt {
            unsigned_tx,
            inputs: vec![psbt_in],
            outputs: vec![PsbtOutput::default(), psbt_out_change],
            unknown_global: BTreeMap::new(),
        };

        let verdict =
            verify_and_audit_psbt(&psbt, &[0x73, 0xc5, 0xda, 0x0a], "bc").expect("Audit must pass");

        assert_eq!(verdict.total_input_sat, 500_000);
        assert_eq!(verdict.total_output_sat, 498_000);
        assert_eq!(verdict.fee_sat, 2_000);
        assert_eq!(verdict.destination_outputs.len(), 1);
        assert_eq!(verdict.change_outputs.len(), 1);
        assert_eq!(verdict.destination_outputs[0].amount_sat, 400_000);
        assert_eq!(verdict.change_outputs[0].amount_sat, 98_000);
    }

    #[test]
    fn test_btc_04_policy_rejections_and_adversarial_tampering() {
        let prev_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: [0x33u8; 32],
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xffffffff,
            }],
            outputs: vec![TxOut {
                value: 100_000,
                script_pubkey: vec![
                    0x00, 0x14, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44,
                    0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44,
                ],
            }],
        };
        let computed_txid = prev_tx.txid();

        // 1. Missing non-witness UTXO
        let unsigned_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: computed_txid,
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xffffffff,
            }],
            outputs: vec![TxOut {
                value: 90_000,
                script_pubkey: vec![
                    0x00, 0x14, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
                    0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
                ],
            }],
        };
        let psbt = Psbt {
            unsigned_tx: unsigned_tx.clone(),
            inputs: vec![PsbtInput::default()],
            outputs: vec![PsbtOutput::default()],
            unknown_global: BTreeMap::new(),
        };

        let err = verify_and_audit_psbt(&psbt, &[0x73, 0xc5, 0xda, 0x0a], "bc").unwrap_err();
        assert!(matches!(err, BitcoinError::MissingNonWitnessUtxo(0)));

        // 2. Mismatched txid
        let mut corrupted_psbt = psbt.clone();
        let mut corrupted_prev = prev_tx.clone();
        corrupted_prev.version = 1; // changes txid
        corrupted_psbt.inputs[0].non_witness_utxo = Some(corrupted_prev);
        let err2 =
            verify_and_audit_psbt(&corrupted_psbt, &[0x73, 0xc5, 0xda, 0x0a], "bc").unwrap_err();
        assert!(matches!(err2, BitcoinError::UtxoTxidMismatch { .. }));

        // 3. Foreign input
        let mut foreign_psbt = psbt.clone();
        foreign_psbt.inputs[0].non_witness_utxo = Some(prev_tx.clone());
        foreign_psbt.inputs[0].bip32_derivation.insert(
            vec![0x02; 33],
            (
                [0xde, 0xad, 0xbe, 0xef],
                vec![84 | 0x80000000, 0x80000000, 0x80000000, 0, 0],
            ),
        );
        let err3 =
            verify_and_audit_psbt(&foreign_psbt, &[0x73, 0xc5, 0xda, 0x0a], "bc").unwrap_err();
        assert!(matches!(err3, BitcoinError::ForeignInputNotAllowed(0)));

        // 4. Inflation / Negative Fee
        let mut inflation_tx = unsigned_tx.clone();
        inflation_tx.outputs[0].value = 200_000; // input is 100_000
        let mut inflation_psbt = psbt.clone();
        inflation_psbt.unsigned_tx = inflation_tx;
        inflation_psbt.inputs[0].non_witness_utxo = Some(prev_tx.clone());
        inflation_psbt.inputs[0].bip32_derivation.insert(
            vec![0x02; 33],
            (
                [0x73, 0xc5, 0xda, 0x0a],
                vec![84 | 0x80000000, 0x80000000, 0x80000000, 0, 0],
            ),
        );
        let err4 =
            verify_and_audit_psbt(&inflation_psbt, &[0x73, 0xc5, 0xda, 0x0a], "bc").unwrap_err();
        assert!(matches!(err4, BitcoinError::NegativeFeeOrInflation { .. }));

        // 5. Unsupported sighash (SIGHASH_NONE = 2)
        let mut bad_sighash_psbt = psbt.clone();
        bad_sighash_psbt.inputs[0].non_witness_utxo = Some(prev_tx.clone());
        bad_sighash_psbt.inputs[0].sighash_type = Some(2);
        bad_sighash_psbt.inputs[0].bip32_derivation.insert(
            vec![0x02; 33],
            (
                [0x73, 0xc5, 0xda, 0x0a],
                vec![84 | 0x80000000, 0x80000000, 0x80000000, 0, 0],
            ),
        );
        let err5 =
            verify_and_audit_psbt(&bad_sighash_psbt, &[0x73, 0xc5, 0xda, 0x0a], "bc").unwrap_err();
        assert!(matches!(err5, BitcoinError::UnsupportedSighashType(2)));
    }
}
