use bip32::{DerivationPath, XPrv};
use bip39::Mnemonic;
use secp256k1::PublicKey;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use std::str::FromStr;
use tiny_keccak::{Hasher, Keccak};

#[derive(Debug, Deserialize)]
struct FixtureFile {
    vectors: Vec<VectorItem>,
}

#[derive(Debug, Deserialize)]
struct VectorItem {
    id: String,
    name: String,
    mnemonic: String,
    #[serde(default)]
    passphrase: String,
}

#[derive(Debug, Serialize)]
struct DerivedOutput {
    master_fingerprint: String,
    account_xpub: String,
    account_compressed_pubkey: String,
    account_chain_code: String,
    leaf_compressed_pubkey: String,
    eip55_address: String,
}

#[derive(Debug, Serialize)]
struct VectorResult {
    id: String,
    name: String,
    derived: DerivedOutput,
}

#[derive(Debug, Serialize)]
struct OracleReport {
    algorithm: String,
    results: Vec<VectorResult>,
}

fn to_eip55(addr_lower: &str) -> String {
    let clean = addr_lower.trim_start_matches("0x");
    let mut hasher = Keccak::v256();
    let mut hash = [0u8; 32];
    hasher.update(clean.as_bytes());
    hasher.finalize(&mut hash);
    let hash_hex = hex::encode(hash);

    let mut out = String::from("0x");
    for (i, c) in clean.chars().enumerate() {
        let nibble = u8::from_str_radix(&hash_hex[i..i + 1], 16).unwrap();
        if nibble >= 8 {
            out.push(c.to_ascii_uppercase());
        } else {
            out.push(c.to_ascii_lowercase());
        }
    }
    out
}

fn derive_vector(mnemonic_str: &str, passphrase: &str) -> DerivedOutput {
    let mnemonic = Mnemonic::parse(mnemonic_str).expect("Valid BIP-39 mnemonic");
    let seed = mnemonic.to_seed(passphrase);

    let master_xprv = XPrv::new(seed).expect("Valid master seed");
    let master_fp = master_xprv.public_key().fingerprint();
    let master_fp_hex = hex::encode(master_fp);

    // Derive Account m/44'/60'/0'
    let account_path = DerivationPath::from_str("m/44'/60'/0'").expect("Valid account path");
    let account_xprv = XPrv::derive_from_path(seed, &account_path).expect("Derive account xprv");
    let account_xpub = account_xprv.public_key();
    let account_xpub_str = account_xpub.to_string(bip32::Prefix::XPUB);
    let account_comp_bytes = account_xpub.to_bytes();
    let account_chain_code = hex::encode(account_xpub.attrs().chain_code);

    // Derive Leaf m/44'/60'/0'/0/0
    let leaf_path = DerivationPath::from_str("m/44'/60'/0'/0/0").expect("Valid leaf path");
    let leaf_xprv = XPrv::derive_from_path(seed, &leaf_path).expect("Derive leaf xprv");
    let leaf_xpub = leaf_xprv.public_key();
    let leaf_comp_bytes = leaf_xpub.to_bytes();

    // Ethereum address from leaf uncompressed pubkey
    let pk = PublicKey::from_slice(&leaf_comp_bytes).expect("Valid secp256k1 pubkey");
    let uncomp = pk.serialize_uncompressed(); // 65 bytes, begins with 0x04
    let pubkey_raw = &uncomp[1..]; // 64 bytes

    let mut hasher = Keccak::v256();
    let mut keccak_hash = [0u8; 32];
    hasher.update(pubkey_raw);
    hasher.finalize(&mut keccak_hash);

    let addr_lower = hex::encode(&keccak_hash[12..]);
    let eip55_addr = to_eip55(&addr_lower);

    DerivedOutput {
        master_fingerprint: master_fp_hex,
        account_xpub: account_xpub_str,
        account_compressed_pubkey: hex::encode(account_comp_bytes),
        account_chain_code,
        leaf_compressed_pubkey: hex::encode(leaf_comp_bytes),
        eip55_address: eip55_addr,
    }
}

fn main() {
    let fixtures_path = Path::new("tools/reference_oracle/fixtures/public_vectors.json");
    let content = fs::read_to_string(fixtures_path)
        .or_else(|_| fs::read_to_string("../fixtures/public_vectors.json"))
        .expect("Read public_vectors.json");

    let fixture: FixtureFile = serde_json::from_str(&content).expect("Parse fixtures");
    let mut results = Vec::new();

    for vec in fixture.vectors {
        let derived = derive_vector(&vec.mnemonic, &vec.passphrase);
        results.push(VectorResult {
            id: vec.id,
            name: vec.name,
            derived,
        });
    }

    let report = OracleReport {
        algorithm: "Algorithm A (Rust secp256k1 / bip32 / bip39 / tiny-keccak)".to_string(),
        results,
    };

    println!("{}", serde_json::to_string_pretty(&report).unwrap());
}
