//! Regtest-only, watch-only PSBT construction and response verification.
use bip32::{ChildNumber, ExtendedKeyAttrs, Prefix, XPub};
use public_core::bitcoin::{
    self as btc, OutPoint, Psbt, PsbtInput, PsbtOutput, Transaction, TxIn, TxOut,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::str::FromStr;

const MAX_MONEY: u64 = 21_000_000 * 100_000_000;
const MAX_INPUTS: usize = 64;
const DUST_SAT: u64 = 294;
const ACCOUNT_PATH: &str = "m/84'/1'/0'";

fn child(key: &XPub, branch: u32, index: u32) -> Result<XPub, String> {
    if branch > 1 || index >= 0x80000000 {
        return Err("Only non-hardened receive/change children are supported".into());
    }
    key.derive_child(ChildNumber::new(branch, false).map_err(|e| e.to_string())?)
        .and_then(|key| key.derive_child(ChildNumber::new(index, false)?))
        .map_err(|e| e.to_string())
}
fn script(key: &XPub) -> Vec<u8> {
    let mut script = vec![0, 20];
    script.extend_from_slice(&btc::hash160(&key.to_bytes()));
    script
}
fn address(key: &XPub) -> Result<String, String> {
    btc::encode_p2wpkh_address("bcrt", &btc::hash160(&key.to_bytes())).map_err(|e| e.to_string())
}
fn parse_xpub(value: &str) -> Result<XPub, String> {
    if !value.starts_with("tpub") {
        return Err("Regtest requires a test-network account tpub".into());
    }
    let key = XPub::from_str(value).map_err(|e| e.to_string())?;
    if key.attrs().depth != 3
        || key.attrs().child_number != ChildNumber::new(0, true).map_err(|e| e.to_string())?
    {
        return Err("Expected the BIP84 test-network account at m/84'/1'/0'".into());
    }
    Ok(key)
}
fn fingerprint(value: &str) -> Result<[u8; 4], String> {
    hex::decode(value)
        .map_err(|e| e.to_string())?
        .try_into()
        .map_err(|_| "Expected an eight-hex-digit master fingerprint".into())
}
fn satoshis(value: &str) -> Result<u64, String> {
    if value.is_empty() || value.len() > 16 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return Err("Satoshis must be an unsigned integer decimal string".into());
    }
    let amount = value.parse::<u64>().map_err(|e| e.to_string())?;
    if amount > MAX_MONEY {
        return Err("Satoshi amount exceeds Bitcoin supply".into());
    }
    Ok(amount)
}
fn decode_hex(value: &str) -> Result<Vec<u8>, String> {
    if value.len() > 256 * 1024 {
        return Err("Encoded transaction exceeds 128 KiB".into());
    }
    hex::decode(value).map_err(|e| e.to_string())
}
fn path(branch: u32, index: u32) -> Vec<u32> {
    vec![84 | 0x80000000, 1 | 0x80000000, 0x80000000, branch, index]
}

pub fn btc_account_from_hdkey(
    key: &ur_adapter::CryptoHDKey,
    master: [u8; 4],
) -> Result<Value, String> {
    if key.origin.to_string_path() != ACCOUNT_PATH
        || key.origin.source_fingerprint != Some(master)
        || key.origin.depth.is_some_and(|depth| depth != 3)
    {
        return Err("BTC pairing requires the complete regtest BIP84 account origin".into());
    }
    let chain_code: [u8; 32] = key
        .chain_code
        .as_ref()
        .ok_or("BTC account chain code is missing")?
        .as_slice()
        .try_into()
        .map_err(|_| "BTC chain code must contain 32 bytes")?;
    let parent = key
        .parent_fingerprint
        .ok_or("BTC account parent fingerprint is missing")?;
    let public = bip32::secp256k1::ecdsa::VerifyingKey::from_sec1_bytes(&key.key_data)
        .map_err(|e| e.to_string())?;
    if key.key_data.len() != 33 {
        return Err("Compressed BTC account public key required".into());
    }
    let account = XPub::new(
        public,
        ExtendedKeyAttrs {
            depth: 3,
            parent_fingerprint: parent,
            child_number: ChildNumber::new(0, true).map_err(|e| e.to_string())?,
            chain_code,
        },
    );
    account_json(&account, master)
}
fn account_json(account: &XPub, master: [u8; 4]) -> Result<Value, String> {
    let external = child(account, 0, 0)?;
    let change = child(account, 1, 0)?;
    let tpub = account.to_string(Prefix::TPUB);
    let fp = hex::encode(master);
    Ok(
        json!({ "chain_family": "BTC", "chain_id": 0, "network": "regtest", "account_index": 0,
        "master_fingerprint": fp, "derivation_path": "m/84'/1'/0'/0/0", "account_derivation_path": ACCOUNT_PATH,
        "change_derivation_path": "m/84'/1'/0'/1/0", "receive_address_regtest": address(&external)?,
        "address": address(&external)?, "change_address": address(&change)?, "account_xpub": tpub,
        "extended_public_key": tpub, "compressed_pubkey_hex": hex::encode(external.to_bytes()),
        "descriptor": format!("wpkh([{fp}/84'/1'/0']{tpub}/0/*)"),
        "change_descriptor": format!("wpkh([{fp}/84'/1'/0']{tpub}/1/*)"), "verified": true }),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PublicAccountRequest {
    account_xpub: String,
    master_fingerprint: String,
}

/// Recompute the supported account's public description for backup validation.
/// The master fingerprint is origin metadata; an account tpub cannot prove it.
pub fn verify_regtest_account(input: &str) -> Result<Value, String> {
    if input.len() > 4096 {
        return Err("Public account request exceeds the supported size".into());
    }
    let request: PublicAccountRequest = serde_json::from_str(input).map_err(|e| e.to_string())?;
    let account = parse_xpub(&request.account_xpub)?;
    let master = fingerprint(&request.master_fingerprint)?;
    let mut canonical = account_json(&account, master)?;
    canonical["status"] = json!("SUCCESS");
    Ok(canonical)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Utxo {
    txid: String,
    vout: u32,
    previous_tx_hex: String,
    branch: u32,
    address_index: u32,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BuildRequest {
    account_xpub: String,
    master_fingerprint: String,
    recipient_address: String,
    amount_sat: String,
    fee_sat: String,
    change_index: u32,
    utxos: Vec<Utxo>,
}

pub fn build_regtest_psbt(input: &str) -> Result<Value, String> {
    if input.len() > 512 * 1024 {
        return Err("PSBT request exceeds the supported size".into());
    }
    let request: BuildRequest = serde_json::from_str(input).map_err(|e| e.to_string())?;
    let account = parse_xpub(&request.account_xpub)?;
    let fp = fingerprint(&request.master_fingerprint)?;
    let amount = satoshis(&request.amount_sat)?;
    let fee = satoshis(&request.fee_sat)?;
    if amount < DUST_SAT || fee > 5_000_000 {
        return Err("Recipient is below dust or fee exceeds the policy ceiling".into());
    }
    if request.utxos.is_empty() || request.utxos.len() > MAX_INPUTS {
        return Err("Select between 1 and 64 UTXOs".into());
    }
    let recipient_script = btc::decode_p2wpkh_address(&request.recipient_address, "bcrt")
        .map_err(|e| e.to_string())?;
    let mut total = 0u64;
    let mut inputs = Vec::new();
    let mut tx_inputs = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for utxo in &request.utxos {
        let bytes = decode_hex(&utxo.previous_tx_hex)?;
        let mut cursor = 0;
        let previous = Transaction::deserialize(&bytes, &mut cursor).map_err(|e| e.to_string())?;
        if cursor != bytes.len() || previous.txid_hex() != utxo.txid.to_ascii_lowercase() {
            return Err("Previous transaction bytes do not match the selected UTXO txid".into());
        }
        if !seen.insert((utxo.txid.to_ascii_lowercase(), utxo.vout)) {
            return Err("Duplicate selected UTXO".into());
        }
        let output = previous
            .outputs
            .get(utxo.vout as usize)
            .ok_or("UTXO output index out of range")?
            .clone();
        let key = child(&account, utxo.branch, utxo.address_index)?;
        if output.script_pubkey != script(&key) {
            return Err("UTXO script does not belong to the selected public account".into());
        }
        total = total
            .checked_add(output.value)
            .filter(|total| *total <= MAX_MONEY)
            .ok_or("UTXO amount overflow")?;
        tx_inputs.push(TxIn {
            previous_output: OutPoint {
                txid: previous.txid(),
                vout: utxo.vout,
            },
            script_sig: vec![],
            sequence: 0xfffffffd,
        });
        let mut derivation = BTreeMap::new();
        derivation.insert(
            key.to_bytes().to_vec(),
            (fp, path(utxo.branch, utxo.address_index)),
        );
        inputs.push(PsbtInput {
            non_witness_utxo: Some(previous),
            witness_utxo: Some(output),
            sighash_type: Some(1),
            bip32_derivation: derivation,
            ..Default::default()
        });
    }
    let change_sat = total
        .checked_sub(amount.checked_add(fee).ok_or("Amount plus fee overflow")?)
        .ok_or("Insufficient selected UTXOs")?;
    if change_sat > 0 && change_sat < DUST_SAT {
        return Err("Change is below dust; adjust the explicit fee or selected UTXOs".into());
    }
    let change_key = child(&account, 1, request.change_index)?;
    let mut tx_outputs = vec![TxOut {
        value: amount,
        script_pubkey: recipient_script,
    }];
    let mut outputs = vec![PsbtOutput::default()];
    if change_sat > 0 {
        tx_outputs.push(TxOut {
            value: change_sat,
            script_pubkey: script(&change_key),
        });
        let mut derivation = BTreeMap::new();
        derivation.insert(
            change_key.to_bytes().to_vec(),
            (fp, path(1, request.change_index)),
        );
        outputs.push(PsbtOutput {
            bip32_derivation: derivation,
            ..Default::default()
        });
    }
    let psbt = Psbt {
        unsigned_tx: Transaction {
            version: 2,
            lock_time: 0,
            inputs: tx_inputs,
            outputs: tx_outputs,
        },
        inputs,
        outputs,
        unknown_global: BTreeMap::new(),
    };
    btc::verify_and_audit_psbt(&psbt, &fp, "bcrt").map_err(|e| e.to_string())?;
    ur_adapter::CryptoPsbt::ensure_p2wpkh_response_capacity(&psbt).map_err(|e| e.to_string())?;
    let bytes = psbt.serialize();
    if bytes.len() > 128 * 1024 {
        return Err("PSBT exceeds the QR payload limit".into());
    }
    let ur = ur_adapter::CryptoPsbt::new(bytes.clone());
    let cbor_bytes = ur.to_cbor_bytes();
    let fragment_len = ur_adapter::default_fragment_len(&cbor_bytes).map_err(|e| e.to_string())?;
    let frames = ur_adapter::encode_ur_fountain_frames(
        ur_adapter::CryptoPsbt::UR_TYPE,
        &cbor_bytes,
        fragment_len,
    )
    .map_err(|e| e.to_string())?;
    Ok(
        json!({ "status": "SUCCESS", "network": "regtest", "psbt_hex": hex::encode(&bytes),
        "expected_digest": hex::encode(btc::sha256(&bytes)), "ur_frames": frames,
        "txid": psbt.unsigned_tx.txid_hex(), "unsigned_tx_hex": hex::encode(psbt.unsigned_tx.serialize_legacy()),
        "recipient_address": request.recipient_address, "change_address": address(&change_key)?,
        "amount_sat": amount.to_string(), "fee_sat": fee.to_string(), "change_sat": change_sat.to_string() }),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ResponseRequest {
    original_psbt_hex: String,
    expected_digest: String,
    #[serde(default)]
    response_ur: Option<String>,
    #[serde(default)]
    signed_psbt_hex: Option<String>,
}
pub fn verify_regtest_psbt_response(input: &str) -> Result<Value, String> {
    if input.len() > 1024 * 1024 {
        return Err("Signed response exceeds the supported size".into());
    }
    let request: ResponseRequest = serde_json::from_str(input).map_err(|e| e.to_string())?;
    let original_bytes = decode_hex(&request.original_psbt_hex)?;
    if hex::encode(btc::sha256(&original_bytes)) != request.expected_digest {
        return Err("Local pending PSBT digest does not match".into());
    }
    let original = Psbt::deserialize(&original_bytes).map_err(|e| e.to_string())?;
    if original.inputs.iter().any(|i| !i.partial_sigs.is_empty()) {
        return Err("Local pending PSBT must be unsigned".into());
    }
    let signed_bytes = match (request.response_ur, request.signed_psbt_hex) {
        (Some(ur), None) => {
            match ur_adapter::DecodedUrPayload::decode(&ur).map_err(|e| e.to_string())? {
                ur_adapter::DecodedUrPayload::CryptoPsbt(psbt) => psbt.psbt_data,
                _ => return Err("Expected a crypto-psbt response".into()),
            }
        }
        (None, Some(hex)) => decode_hex(&hex)?,
        _ => return Err("Supply exactly one signed PSBT response encoding".into()),
    };
    let signed = Psbt::deserialize(&signed_bytes).map_err(|e| e.to_string())?;
    let mut stripped = signed.clone();
    for input in &mut stripped.inputs {
        input.partial_sigs.clear();
    }
    if stripped != original {
        return Err(
            "Returned PSBT differs from the immutable pending transaction or derivation metadata"
                .into(),
        );
    }
    let fp = original
        .inputs
        .first()
        .and_then(|i| i.bip32_derivation.values().next())
        .map(|(fp, _)| *fp)
        .ok_or("Pending PSBT has no account derivation")?;
    for input in &original.inputs {
        for (source, path) in input.bip32_derivation.values() {
            if *source != fp
                || path.len() != 5
                || path[..3] != [0x80000054, 0x80000001, 0x80000000]
                || path[3] > 1
                || path[4] >= 0x80000000
            {
                return Err("Only the pending BIP84 regtest account is supported".into());
            }
        }
    }
    btc::verify_and_audit_psbt(&signed, &fp, "bcrt").map_err(|e| e.to_string())?;
    let raw = btc::finalize_and_extract_p2wpkh_psbt(&signed).map_err(|e| e.to_string())?;
    Ok(
        json!({ "status": "VERIFIED", "network": "regtest", "tx_hex": hex::encode(raw), "txid": signed.unsigned_tx.txid_hex() }),
    )
}

fn ffi_json(pointer: *const c_char, operation: fn(&str) -> Result<Value, String>) -> *mut c_char {
    if pointer.is_null() {
        return std::ptr::null_mut();
    }
    let result = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|e| e.to_string())
        .and_then(operation);
    let output = result.unwrap_or_else(|error| json!({"status":"ERROR", "error":error}));
    CString::new(output.to_string())
        .expect("JSON escapes interior NUL")
        .into_raw()
}
#[no_mangle]
pub extern "C" fn wallet_build_regtest_psbt_json(input: *const c_char) -> *mut c_char {
    ffi_json(input, build_regtest_psbt)
}
#[no_mangle]
pub extern "C" fn wallet_verify_regtest_psbt_response_json(input: *const c_char) -> *mut c_char {
    ffi_json(input, verify_regtest_psbt_response)
}

#[no_mangle]
pub extern "C" fn wallet_verify_regtest_account_json(input: *const c_char) -> *mut c_char {
    ffi_json(input, verify_regtest_account)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backup_public_account_is_rederived_and_rejects_claimed_derivations() {
        let (request, account) = fixture();
        let input = json!({"account_xpub":request["account_xpub"],"master_fingerprint":request["master_fingerprint"]});
        let canonical = verify_regtest_account(&input.to_string()).unwrap();
        assert_eq!(canonical["status"], "SUCCESS");
        assert_eq!(
            canonical["address"],
            address(&child(&account.public_key(), 0, 0).unwrap()).unwrap()
        );
        assert_eq!(
            canonical["change_address"],
            address(&child(&account.public_key(), 1, 0).unwrap()).unwrap()
        );
        assert_eq!(canonical["derivation_path"], "m/84'/1'/0'/0/0");
        for (name, value) in [
            ("derivation_path", json!("m/84'/0'/0'/0/0")),
            ("address", json!("bcrt1qfake")),
            ("descriptor", json!("wpkh(attacker)")),
        ] {
            let mut tampered = input.clone();
            tampered[name] = value;
            assert!(
                verify_regtest_account(&tampered.to_string()).is_err(),
                "Unexpected claim {name}"
            );
        }
        let mut wrong_network = input.clone();
        wrong_network["account_xpub"] = json!(account.public_key().to_string(Prefix::XPUB));
        assert!(verify_regtest_account(&wrong_network.to_string()).is_err());
        let mut wrong_depth = input.clone();
        wrong_depth["account_xpub"] = json!(account
            .derive_child(ChildNumber::new(0, false).unwrap())
            .unwrap()
            .public_key()
            .to_string(Prefix::TPUB));
        assert!(verify_regtest_account(&wrong_depth.to_string()).is_err());
        let mut wrong_fp = input.clone();
        wrong_fp["master_fingerprint"] = json!("not-a-fingerprint");
        assert!(verify_regtest_account(&wrong_fp.to_string()).is_err());
        assert!(verify_regtest_account(&" ".repeat(4097)).is_err());
    }
    fn fixture() -> (Value, bip32::XPrv) {
        let master = bip32::XPrv::new([7u8; 64]).unwrap();
        let fp = master.public_key().fingerprint();
        let mut account = master;
        for index in [84, 1, 0] {
            account = account
                .derive_child(ChildNumber::new(index, true).unwrap())
                .unwrap();
        }
        let public = account.public_key();
        let receive = child(&public, 0, 0).unwrap();
        let previous = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: [4; 32],
                    vout: 0,
                },
                script_sig: vec![1, 1],
                sequence: u32::MAX,
            }],
            outputs: vec![TxOut {
                value: 100_000,
                script_pubkey: script(&receive),
            }],
        };
        (
            json!({"account_xpub":public.to_string(Prefix::TPUB), "master_fingerprint":hex::encode(fp),
            "recipient_address":address(&child(&public,0,9).unwrap()).unwrap(), "amount_sat":"80000", "fee_sat":"1000", "change_index":0,
            "utxos":[{"txid":previous.txid_hex(),"vout":0,"previous_tx_hex":hex::encode(previous.serialize_legacy()),"branch":0,"address_index":0}]}),
            account,
        )
    }
    fn sign(result: &Value, account: &bip32::XPrv) -> Psbt {
        let mut psbt =
            Psbt::deserialize(&hex::decode(result["psbt_hex"].as_str().unwrap()).unwrap()).unwrap();
        let secp = secp256k1::Secp256k1::new();
        let key = account
            .derive_child(ChildNumber::new(0, false).unwrap())
            .unwrap()
            .derive_child(ChildNumber::new(0, false).unwrap())
            .unwrap();
        let secret =
            secp256k1::SecretKey::from_secret_bytes(key.private_key().to_bytes().into()).unwrap();
        let public = secret.public_key();
        let mut code = vec![0x76, 0xa9, 0x14];
        code.extend_from_slice(&btc::hash160(&public.serialize()));
        code.extend_from_slice(&[0x88, 0xac]);
        let digest = btc::compute_bip143_sighash(&psbt.unsigned_tx, 0, &code, 100_000, 1).unwrap();
        #[allow(deprecated)]
        let mut signature = secp
            .sign_ecdsa(secp256k1::Message::from_digest(digest), &secret)
            .serialize_der()
            .to_vec();
        signature.push(1);
        psbt.inputs[0]
            .partial_sigs
            .insert(public.serialize().to_vec(), signature);
        psbt
    }
    fn response(result: &Value, signed: &Psbt) -> Value {
        json!({"original_psbt_hex":result["psbt_hex"],"expected_digest":result["expected_digest"],"signed_psbt_hex":hex::encode(signed.serialize())})
    }
    #[test]
    fn regtest_real_psbt_build_verify_finalize_and_reject_mutations() {
        let (request, private) = fixture();
        let built = build_regtest_psbt(&request.to_string()).unwrap();
        assert_eq!(built["change_sat"], "19000");
        assert!(built["ur_frames"]
            .as_array()
            .unwrap()
            .iter()
            .all(|frame| frame.as_str().unwrap().starts_with("ur:crypto-psbt/")));
        let signed = sign(&built, &private);
        let verified =
            verify_regtest_psbt_response(&response(&built, &signed).to_string()).unwrap();
        assert_eq!(verified["status"], "VERIFIED");
        assert_eq!(verified["txid"], built["txid"]);
        let mut changed = signed.clone();
        changed.unsigned_tx.outputs[0].value += 1;
        assert!(verify_regtest_psbt_response(&response(&built, &changed).to_string()).is_err());
        let mut changed = signed.clone();
        changed.inputs[0].partial_sigs.values_mut().next().unwrap()[8] ^= 1;
        assert!(verify_regtest_psbt_response(&response(&built, &changed).to_string()).is_err());
        let mut changed = response(&built, &signed);
        changed["expected_digest"] = json!("00".repeat(32));
        assert!(verify_regtest_psbt_response(&changed.to_string()).is_err());
        let mut changed = signed.clone();
        changed.inputs[0]
            .bip32_derivation
            .values_mut()
            .next()
            .unwrap()
            .1[4] += 1;
        assert!(verify_regtest_psbt_response(&response(&built, &changed).to_string()).is_err());
    }
    #[test]
    fn regtest_builder_rejects_false_utxos_invalid_amount_and_mainnet() {
        let (request, _) = fixture();
        for mutation in [
            "amount",
            "txid",
            "derivation",
            "network",
            "duplicate",
            "dust",
        ] {
            let mut changed = request.clone();
            match mutation {
                "amount" => changed["amount_sat"] = json!("-1"),
                "txid" => changed["utxos"][0]["txid"] = json!("00".repeat(32)),
                "derivation" => changed["utxos"][0]["address_index"] = json!(1),
                "network" => {
                    changed["recipient_address"] =
                        json!(btc::encode_p2wpkh_address("bc", &[3; 20]).unwrap())
                }
                "duplicate" => {
                    let duplicate = changed["utxos"][0].clone();
                    changed["utxos"].as_array_mut().unwrap().push(duplicate);
                }
                "dust" => changed["amount_sat"] = json!("1"),
                _ => unreachable!(),
            }
            assert!(
                build_regtest_psbt(&changed.to_string()).is_err(),
                "{mutation}"
            );
        }
    }
    #[test]
    fn regtest_pairing_derives_both_branches_from_public_origin() {
        let (request, private) = fixture();
        let public = private.public_key();
        let fp = fingerprint(request["master_fingerprint"].as_str().unwrap()).unwrap();
        let key = ur_adapter::CryptoHDKey {
            name: None,
            key_data: public.to_bytes().to_vec(),
            chain_code: Some(public.attrs().chain_code.to_vec()),
            parent_fingerprint: Some(public.attrs().parent_fingerprint),
            origin: ur_adapter::CryptoKeyPath::from_string_path(ACCOUNT_PATH, Some(fp)).unwrap(),
            note: None,
        };
        let result = btc_account_from_hdkey(&key, fp).unwrap();
        assert_eq!(result["account_xpub"], request["account_xpub"]);
        assert_ne!(result["receive_address_regtest"], result["change_address"]);
        let mut incomplete = key.clone();
        incomplete.chain_code = None;
        assert!(btc_account_from_hdkey(&incomplete, fp).is_err());
    }
}
