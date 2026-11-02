use bip32::{DerivationPath, XPrv};
use bip39::{Language, Mnemonic};
use public_core::evm::keccak256;
use public_core::verify::to_checksum_address;
use secp256k1::ecdsa::RecoverableSignature;
use secp256k1::{Message, SecretKey};
use std::str::FromStr;
use thiserror::Error;
use unicode_normalization::UnicodeNormalization;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

pub mod storage;

#[derive(Error, Debug, Clone, PartialEq, Eq)]
pub enum VaultError {
    #[error("Mnemonic error: {0}")]
    MnemonicError(String),

    #[error("Invalid mnemonic checksum")]
    InvalidChecksum,

    #[error("Derivation error: {0}")]
    DerivationError(String),

    #[error("Signing error: {0}")]
    SigningError(String),

    #[error("Self-verification failed: recovered address {recovered} does not match expected {expected}")]
    SelfVerificationFailed { expected: String, recovered: String },
}

#[derive(Zeroize, ZeroizeOnDrop)]
pub struct SecretMaterial {
    seed: [u8; 64],
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct EvmPublicAccount {
    pub account_index: u32,
    pub master_fingerprint: String,
    pub derivation_path: String,
    pub address: String,
    pub compressed_pubkey_hex: String,
    pub chain_code_hex: String,
    pub account_xpub: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct BtcPublicAccount {
    pub account_index: u32,
    pub master_fingerprint: String,
    pub derivation_path: String,
    pub change_derivation_path: String,
    pub receive_address: String,
    pub change_address: String,
    pub compressed_pubkey_hex: String,
    pub account_xpub: String,
    pub descriptor: String,
    pub change_descriptor: String,
    pub account_derivation_path: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct MultiAccountsExport {
    pub master_fingerprint: String,
    pub master_fingerprint_u32: u32,
    pub device: String,
    pub evm_accounts: Vec<EvmPublicAccount>,
    pub btc_accounts: Vec<BtcPublicAccount>,
    pub cbor_hex: String,
    pub ur_single: String,
    pub fountain_frames: Vec<String>,
}

pub struct KeyVault {
    secret: SecretMaterial,
    master_fingerprint: [u8; 4],
    has_passphrase_hint: bool,
    primitive_sign_invocations: std::sync::atomic::AtomicU64,
}

impl std::fmt::Debug for KeyVault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KeyVault")
            .field("master_fingerprint", &hex::encode(self.master_fingerprint))
            .field("has_passphrase_hint", &self.has_passphrase_hint)
            .field("secret", &"[REDACTED]")
            .finish()
    }
}

impl KeyVault {
    pub fn generate_mnemonic(word_count: usize) -> Result<String, VaultError> {
        let entropy_len = match word_count {
            12 => 16,
            24 => 32,
            other => {
                return Err(VaultError::MnemonicError(format!(
                    "Unsupported word count {other}; must be 12 or 24"
                )))
            }
        };
        let mut entropy = Zeroizing::new(vec![0u8; entropy_len]);
        getrandom::fill(&mut entropy)
            .map_err(|e| VaultError::MnemonicError(format!("CSPRNG entropy error: {e}")))?;
        let mnemonic = Mnemonic::from_entropy_in(Language::English, &entropy)
            .map_err(|e| VaultError::MnemonicError(e.to_string()))?;
        Ok(mnemonic.to_string())
    }

    pub fn validate_mnemonic_detailed(phrase: &str) -> Result<usize, VaultError> {
        let normalized_phrase: String = phrase.nfkd().collect();
        let words: Vec<&str> = normalized_phrase.split_whitespace().collect();
        if words.len() != 12 && words.len() != 24 {
            return Err(VaultError::MnemonicError(format!(
                "Invalid word count: expected 12 or 24 words, got {}",
                words.len()
            )));
        }
        let word_list = Language::English.word_list();
        for (idx, w) in words.iter().enumerate() {
            let lower = w.to_lowercase();
            if !word_list.contains(&lower.as_str()) {
                return Err(VaultError::MnemonicError(format!(
                    "Unknown BIP-39 word at position {}: '{}'",
                    idx + 1,
                    w
                )));
            }
        }
        let clean_joined = words
            .iter()
            .map(|w| w.to_lowercase())
            .collect::<Vec<_>>()
            .join(" ");
        Mnemonic::parse_in_normalized(Language::English, &clean_joined).map_err(|e| {
            let msg = e.to_string();
            if msg.to_lowercase().contains("checksum") {
                VaultError::MnemonicError(format!("Invalid BIP-39 mnemonic checksum: {msg}"))
            } else {
                VaultError::MnemonicError(msg)
            }
        })?;
        Ok(words.len())
    }

    pub fn from_mnemonic(phrase: &str, passphrase: &str) -> Result<Self, VaultError> {
        let _ = Self::validate_mnemonic_detailed(phrase)?;
        let normalized_phrase: String = phrase
            .nfkd()
            .collect::<String>()
            .split_whitespace()
            .map(|w| w.to_lowercase())
            .collect::<Vec<_>>()
            .join(" ");
        let normalized_passphrase: String = passphrase.nfkd().collect();

        let mnemonic = Mnemonic::parse_in_normalized(Language::English, &normalized_phrase)
            .map_err(|e| VaultError::MnemonicError(e.to_string()))?;
        let seed = mnemonic.to_seed(&normalized_passphrase);

        Self::from_seed(seed, !normalized_passphrase.is_empty())
    }

    pub fn from_seed(seed: [u8; 64], has_passphrase_hint: bool) -> Result<Self, VaultError> {
        let xprv = XPrv::new(seed).map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let fp_bytes: [u8; 4] = xprv.public_key().fingerprint();

        Ok(Self {
            secret: SecretMaterial { seed },
            master_fingerprint: fp_bytes,
            has_passphrase_hint,
            primitive_sign_invocations: std::sync::atomic::AtomicU64::new(0),
        })
    }

    pub fn seed_bytes(&self) -> &[u8; 64] {
        &self.secret.seed
    }

    pub fn has_passphrase_hint(&self) -> bool {
        self.has_passphrase_hint
    }

    pub fn master_fingerprint(&self) -> [u8; 4] {
        self.master_fingerprint
    }

    pub fn primitive_sign_invocations(&self) -> u64 {
        self.primitive_sign_invocations
            .load(std::sync::atomic::Ordering::SeqCst)
    }

    pub fn derive_evm_public_account(
        &self,
        account_index: u32,
    ) -> Result<EvmPublicAccount, VaultError> {
        let master_xprv =
            XPrv::new(&self.secret.seed).map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let account_path = DerivationPath::from_str("m/44'/60'/0'")
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let mut acc_xprv = master_xprv.clone();
        for child in account_path {
            acc_xprv = acc_xprv
                .derive_child(child)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        }
        let account_xpub = acc_xprv.public_key().to_string(bip32::Prefix::XPUB);

        let leaf_path_str = format!("m/44'/60'/0'/0/{account_index}");
        let leaf_path = DerivationPath::from_str(&leaf_path_str)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let mut leaf_xprv = master_xprv;
        for child in leaf_path {
            leaf_xprv = leaf_xprv
                .derive_child(child)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        }
        let leaf_xpub = leaf_xprv.public_key();
        let comp_bytes = leaf_xpub.to_bytes();
        let chain_code = leaf_xpub.attrs().chain_code;

        let mut priv_arr = Zeroizing::new(<[u8; 32]>::from(leaf_xprv.private_key().to_bytes()));
        let secret_key = SecretKey::from_secret_bytes(*priv_arr)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        priv_arr.zeroize();

        let uncompressed = secret_key.public_key().serialize_uncompressed();
        let pubkey_hash = keccak256(&uncompressed[1..65]);
        let address = to_checksum_address(&pubkey_hash[12..32]);

        Ok(EvmPublicAccount {
            account_index,
            master_fingerprint: hex::encode(self.master_fingerprint),
            derivation_path: leaf_path_str,
            address,
            compressed_pubkey_hex: hex::encode(comp_bytes),
            chain_code_hex: hex::encode(chain_code),
            account_xpub,
        })
    }

    pub fn derive_btc_public_account(
        &self,
        account_index: u32,
        hrp: &str,
    ) -> Result<BtcPublicAccount, VaultError> {
        let master_xprv =
            XPrv::new(&self.secret.seed).map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let coin = if hrp == "bc" {
            0
        } else if hrp == "tb" || hrp == "bcrt" {
            1
        } else {
            return Err(VaultError::DerivationError(
                "Unsupported Bitcoin network".into(),
            ));
        };
        let account_path_str = format!("m/84'/{coin}'/0'");
        let account_path = DerivationPath::from_str(&account_path_str)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let mut acc_xprv = master_xprv;
        for child in account_path {
            acc_xprv = acc_xprv
                .derive_child(child)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        }
        let account_xpub = acc_xprv.public_key().to_string(if coin == 0 {
            bip32::Prefix::XPUB
        } else {
            bip32::Prefix::TPUB
        });

        let recv_path = format!("{account_path_str}/0/{account_index}");
        let change_path = format!("{account_path_str}/1/{account_index}");
        let (receive_address, recv_pubk) = self.derive_bitcoin_address(&recv_path, hrp)?;
        let (change_address, _) = self.derive_bitcoin_address(&change_path, hrp)?;
        let fp_hex = hex::encode(self.master_fingerprint);
        let origin = account_path_str.trim_start_matches("m/");
        let descriptor = format!("wpkh([{fp_hex}/{origin}]{account_xpub}/0/*)");
        let change_descriptor = format!("wpkh([{fp_hex}/{origin}]{account_xpub}/1/*)");

        Ok(BtcPublicAccount {
            account_index,
            master_fingerprint: fp_hex,
            derivation_path: recv_path,
            change_derivation_path: change_path,
            receive_address,
            change_address,
            compressed_pubkey_hex: hex::encode(recv_pubk),
            account_xpub,
            descriptor,
            change_descriptor,
            account_derivation_path: account_path_str,
        })
    }

    pub fn build_multi_accounts_ur(
        &self,
        indices: &[u32],
        device: &str,
        max_fragment_len: usize,
    ) -> Result<MultiAccountsExport, VaultError> {
        use ur_adapter::{
            encode_ur_fountain_frames, CryptoHDKey, CryptoKeyPath, CryptoMultiAccounts,
        };
        let active_indices = if indices.is_empty() {
            vec![0, 1]
        } else {
            indices.to_vec()
        };

        let mut evm_accounts = Vec::with_capacity(active_indices.len());
        let mut btc_accounts = Vec::with_capacity(active_indices.len());
        let mut hd_keys = Vec::new();

        for &idx in &active_indices {
            let evm = self.derive_evm_public_account(idx)?;
            let origin = CryptoKeyPath::from_string_path(
                &evm.derivation_path,
                Some(self.master_fingerprint),
            )
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
            hd_keys.push(CryptoHDKey {
                key_data: hex::decode(&evm.compressed_pubkey_hex).unwrap_or_default(),
                chain_code: Some(hex::decode(&evm.chain_code_hex).unwrap_or_default()),
                parent_fingerprint: None,
                origin,
                name: None,
                note: Some("account.standard".to_string()),
            });
            evm_accounts.push(evm);

            let btc = self.derive_btc_public_account(idx, "bcrt")?;
            // Account-level public material enables both receive and change derivation.
            // Emit this account once, regardless of the displayed receive indices.
            if btc_accounts.is_empty() {
                let btc_xpub = bip32::XPub::from_str(&btc.account_xpub)
                    .map_err(|e| VaultError::DerivationError(e.to_string()))?;
                let btc_origin = CryptoKeyPath::from_string_path(
                    &btc.account_derivation_path,
                    Some(self.master_fingerprint),
                )
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
                hd_keys.push(CryptoHDKey {
                    key_data: btc_xpub.to_bytes().to_vec(),
                    chain_code: Some(btc_xpub.attrs().chain_code.to_vec()),
                    parent_fingerprint: Some(btc_xpub.attrs().parent_fingerprint),
                    origin: btc_origin,
                    name: None,
                    note: Some("account.btc_bip84.regtest".to_owned()),
                });
            }
            btc_accounts.push(btc);
        }

        let fp_u32 = u32::from_be_bytes(self.master_fingerprint);
        let fp_hex = hex::encode(self.master_fingerprint);
        let multi = CryptoMultiAccounts {
            master_fingerprint: fp_u32,
            keys: hd_keys,
            device: Some(device.to_string()),
            device_id: Some(format!("vault-{fp_hex}")),
            version: Some("1.1.0".to_string()),
        };

        let cbor_bytes = multi.to_cbor_bytes();
        let ur_single = ur_adapter::displayable_single_ur(CryptoMultiAccounts::UR_TYPE, &cbor_bytes).unwrap_or_default();
        let max_fragment_len = if max_fragment_len == 0 {
            ur_adapter::default_fragment_len(&cbor_bytes)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?
        } else { max_fragment_len };
        let fountain_frames =
            encode_ur_fountain_frames(CryptoMultiAccounts::UR_TYPE, &cbor_bytes, max_fragment_len)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;

        Ok(MultiAccountsExport {
            master_fingerprint: fp_hex,
            master_fingerprint_u32: fp_u32,
            device: device.to_string(),
            evm_accounts,
            btc_accounts,
            cbor_hex: hex::encode(&cbor_bytes),
            ur_single,
            fountain_frames,
        })
    }

    /// Dedicated OKX/Keystone EVM profile. The account public key and chain code
    /// must originate from the same BIP32 node, so receivers can derive /0/n.
    /// The explicit leaf follows KeystoneFW's OKX account.ledger_live entry;
    /// its full path carries no chain code and is never mixed with account data.
    pub fn build_okx_multi_accounts_ur(
        &self,
        max_fragment_len: usize,
    ) -> Result<MultiAccountsExport, VaultError> {
        use ur_adapter::{
            encode_ur_fountain_frames, CryptoHDKey, CryptoKeyPath, CryptoMultiAccounts,
        };
        let evm_accounts = [0, 1]
            .into_iter()
            .map(|index| self.derive_evm_public_account(index))
            .collect::<Result<Vec<_>, _>>()?;
        let account_xpub = bip32::XPub::from_str(&evm_accounts[0].account_xpub)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let origin = CryptoKeyPath::from_string_path("m/44'/60'/0'", Some(self.master_fingerprint))
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let leaf = &evm_accounts[0];
        let leaf_pubkey = hex::decode(&leaf.compressed_pubkey_hex)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let leaf_origin =
            CryptoKeyPath::from_string_path(&leaf.derivation_path, Some(self.master_fingerprint))
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        let fp_u32 = u32::from_be_bytes(self.master_fingerprint);
        let fp_hex = hex::encode(self.master_fingerprint);
        let multi = CryptoMultiAccounts {
            master_fingerprint: fp_u32,
            keys: vec![
                CryptoHDKey {
                    key_data: account_xpub.to_bytes().to_vec(),
                    chain_code: Some(account_xpub.attrs().chain_code.to_vec()),
                    parent_fingerprint: Some(account_xpub.attrs().parent_fingerprint),
                    origin,
                    name: Some("Keystone".into()),
                    note: Some("account.standard".into()),
                },
                CryptoHDKey {
                    key_data: leaf_pubkey,
                    chain_code: None,
                    parent_fingerprint: None,
                    origin: leaf_origin,
                    name: Some("Keystone".into()),
                    note: Some("account.ledger_live".into()),
                },
            ],
            device: Some("Keystone".into()),
            device_id: Some(format!("vault-{fp_hex}")),
            version: Some("1.1.0".into()),
        };
        let cbor_bytes = multi.to_cbor_bytes();
        let max_fragment_len = if max_fragment_len == 0 {
            ur_adapter::default_fragment_len(&cbor_bytes)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?
        } else { max_fragment_len };
        let fountain_frames =
            encode_ur_fountain_frames(CryptoMultiAccounts::UR_TYPE, &cbor_bytes, max_fragment_len)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        Ok(MultiAccountsExport {
            master_fingerprint: fp_hex,
            master_fingerprint_u32: fp_u32,
            device: "Keystone".into(),
            evm_accounts,
            btc_accounts: Vec::new(),
            cbor_hex: hex::encode(&cbor_bytes),
            ur_single: ur_adapter::displayable_single_ur(CryptoMultiAccounts::UR_TYPE, &cbor_bytes).unwrap_or_default(),
            fountain_frames,
        })
    }

    pub fn derive_address_and_sign(
        &self,
        path_str: &str,
        digest: &[u8; 32],
    ) -> Result<(String, [u8; 65]), VaultError> {
        let xprv =
            XPrv::new(&self.secret.seed).map_err(|e| VaultError::DerivationError(e.to_string()))?;

        let path = DerivationPath::from_str(path_str)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;

        let mut derived = xprv;
        for child in path {
            derived = derived
                .derive_child(child)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        }

        let mut priv_arr = Zeroizing::new(<[u8; 32]>::from(derived.private_key().to_bytes()));
        let secret_key = SecretKey::from_secret_bytes(*priv_arr)
            .map_err(|e| VaultError::SigningError(e.to_string()))?;
        priv_arr.zeroize();

        let pubkey = secret_key.public_key();
        let uncompressed = pubkey.serialize_uncompressed();
        let pubkey_hash = keccak256(&uncompressed[1..65]);
        let address = to_checksum_address(&pubkey_hash[12..32]);

        let msg = Message::from_digest(*digest);
        self.primitive_sign_invocations
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let sig = RecoverableSignature::sign_ecdsa_recoverable(msg, &secret_key);
        let (recid, compact) = sig.serialize_compact();

        let mut out_sig = [0u8; 65];
        out_sig[0..64].copy_from_slice(&compact);
        let v = u8::from(recid) + 27; // 27 or 28
        out_sig[64] = v;

        // Mandatory self-verification: ecrecover from signature, verify against expected address
        let mut r = [0u8; 32];
        let mut s = [0u8; 32];
        r.copy_from_slice(&compact[0..32]);
        s.copy_from_slice(&compact[32..64]);

        let recovered = public_core::verify::verify_ethereum_signature(digest, &r, &s, v, &address)
            .map_err(|e| VaultError::SigningError(format!("Self-verification failed: {e}")))?;
        if !recovered.eq_ignore_ascii_case(&address) {
            out_sig.zeroize();
            return Err(VaultError::SelfVerificationFailed {
                expected: address,
                recovered,
            });
        }

        Ok((address, out_sig))
    }

    pub fn derive_bitcoin_address(
        &self,
        path_str: &str,
        hrp: &str,
    ) -> Result<(String, [u8; 33]), VaultError> {
        let xprv =
            XPrv::new(&self.secret.seed).map_err(|e| VaultError::DerivationError(e.to_string()))?;

        let path = DerivationPath::from_str(path_str)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;

        let mut derived = xprv;
        for child in path {
            derived = derived
                .derive_child(child)
                .map_err(|e| VaultError::DerivationError(e.to_string()))?;
        }

        let mut priv_arr = Zeroizing::new(<[u8; 32]>::from(derived.private_key().to_bytes()));
        let secret_key = SecretKey::from_secret_bytes(*priv_arr)
            .map_err(|e| VaultError::SigningError(e.to_string()))?;
        priv_arr.zeroize();

        let pubkey = secret_key.public_key();
        let compressed = pubkey.serialize();
        let pkh = public_core::bitcoin::hash160(&compressed);
        let address = public_core::bitcoin::encode_p2wpkh_address(hrp, &pkh)
            .map_err(|e| VaultError::DerivationError(e.to_string()))?;

        Ok((address, compressed))
    }

    pub fn audit_psbt_p2wpkh(
        &self,
        psbt: &public_core::bitcoin::Psbt,
        hrp: &str,
    ) -> Result<public_core::bitcoin::PsbtPolicyVerdict, VaultError> {
        let coin = match hrp {
            "bc" => 0,
            "tb" | "bcrt" => 1,
            _ => {
                return Err(VaultError::SigningError(
                    "Unsupported Bitcoin network".into(),
                ))
            }
        };
        let verify_key = |pubkey: &[u8],
                          fingerprint: &[u8; 4],
                          path: &[u32],
                          script: &[u8]|
         -> Result<(), VaultError> {
            if *fingerprint != self.master_fingerprint
                || path.len() != 5
                || path[0] != 84 | 0x80000000
                || path[1] != coin | 0x80000000
                || path[2] != 0x80000000
                || path[3] > 1
                || path[4] >= 0x80000000
            {
                return Err(VaultError::SigningError(
                    "Unsupported or foreign BIP84 derivation".into(),
                ));
            }
            let full_path = format!("m/84'/{coin}'/0'/{}/{}", path[3], path[4]);
            let (_, derived) = self.derive_bitcoin_address(&full_path, hrp)?;
            let mut expected = vec![0, 20];
            expected.extend_from_slice(&public_core::bitcoin::hash160(&derived));
            if pubkey != derived || script != expected {
                return Err(VaultError::SigningError(
                    "BIP84 public key or script differs from local derivation".into(),
                ));
            }
            Ok(())
        };
        let verdict =
            public_core::bitcoin::verify_and_audit_psbt(psbt, &self.master_fingerprint, hrp)
                .map_err(|e| VaultError::SigningError(e.to_string()))?;
        for (input, txin) in psbt.inputs.iter().zip(&psbt.unsigned_tx.inputs) {
            if input.bip32_derivation.len() != 1 {
                return Err(VaultError::SigningError(
                    "Expected one input derivation".into(),
                ));
            }
            let (key, (fingerprint, path)) = input.bip32_derivation.iter().next().unwrap();
            let output = &input.non_witness_utxo.as_ref().unwrap().outputs
                [txin.previous_output.vout as usize];
            verify_key(key, fingerprint, path, &output.script_pubkey)?;
        }
        for (output, txout) in psbt.outputs.iter().zip(&psbt.unsigned_tx.outputs) {
            for (key, (fingerprint, path)) in &output.bip32_derivation {
                verify_key(key, fingerprint, path, &txout.script_pubkey)?;
            }
        }
        Ok(verdict)
    }

    pub fn sign_psbt_p2wpkh(
        &self,
        psbt: &mut public_core::bitcoin::Psbt,
    ) -> Result<usize, VaultError> {
        let coin = psbt
            .inputs
            .first()
            .and_then(|input| input.bip32_derivation.values().next())
            .and_then(|(_, path)| path.get(1))
            .copied();
        let hrp = if coin == Some(0x80000000) {
            "bc"
        } else {
            "bcrt"
        };
        self.audit_psbt_p2wpkh(psbt, hrp)?;
        let secp = secp256k1::Secp256k1::new();
        let xprv =
            XPrv::new(&self.secret.seed).map_err(|e| VaultError::DerivationError(e.to_string()))?;

        let mut signed_count = 0;

        for i in 0..psbt.inputs.len() {
            let (pubkey_bytes, path_indices) = {
                let inp = &psbt.inputs[i];
                let mut found = None;
                for (pubk, (fp, path)) in &inp.bip32_derivation {
                    if *fp == self.master_fingerprint {
                        found = Some((pubk.clone(), path.clone()));
                        break;
                    }
                }
                found.ok_or_else(|| {
                    VaultError::SigningError(format!(
                        "No matching BIP32 derivation for input {} belonging to this vault",
                        i
                    ))
                })?
            };

            let mut derived = xprv.clone();
            for idx in path_indices {
                let is_hardened = (idx & 0x80000000) != 0;
                let raw_idx = idx & 0x7fffffff;
                let child = bip32::ChildNumber::new(raw_idx, is_hardened)
                    .map_err(|e| VaultError::DerivationError(e.to_string()))?;
                derived = derived
                    .derive_child(child)
                    .map_err(|e| VaultError::DerivationError(e.to_string()))?;
            }

            let mut priv_arr = Zeroizing::new(<[u8; 32]>::from(derived.private_key().to_bytes()));
            let secret_key = SecretKey::from_secret_bytes(*priv_arr)
                .map_err(|e| VaultError::SigningError(e.to_string()))?;
            priv_arr.zeroize();

            let derived_pubkey = secret_key.public_key();
            let compressed = derived_pubkey.serialize();
            if compressed != pubkey_bytes.as_slice() {
                return Err(VaultError::SigningError(format!(
                    "Derived pubkey does not match PSBT derivation pubkey for input {}",
                    i
                )));
            }

            let non_wit = psbt.inputs[i].non_witness_utxo.as_ref().ok_or_else(|| {
                VaultError::SigningError(format!("Missing non-witness UTXO for input {}", i))
            })?;
            let vout = psbt.unsigned_tx.inputs[i].previous_output.vout as usize;
            let utxo_out = non_wit.outputs.get(vout).ok_or_else(|| {
                VaultError::SigningError(format!(
                    "Vout {} out of range for non-witness UTXO at input {}",
                    vout, i
                ))
            })?;
            let amount = utxo_out.value;

            let pkh = public_core::bitcoin::hash160(&compressed);
            let mut script_code = vec![0x76, 0xa9, 0x14];
            script_code.extend_from_slice(&pkh);
            script_code.extend_from_slice(&[0x88, 0xac]);

            let sighash = public_core::bitcoin::compute_bip143_sighash(
                &psbt.unsigned_tx,
                i,
                &script_code,
                amount,
                1, // SIGHASH_ALL
            )
            .map_err(|e| VaultError::SigningError(e.to_string()))?;

            let msg = Message::from_digest(sighash);
            self.primitive_sign_invocations
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            #[allow(deprecated)]
            let sig = secp.sign_ecdsa(msg, &secret_key);

            // Mandatory self-verification
            #[allow(deprecated)]
            secp.verify_ecdsa(msg, &sig, &derived_pubkey).map_err(|e| {
                VaultError::SigningError(format!("ECDSA self-verification failed: {e}"))
            })?;

            let der = sig.serialize_der();
            let mut sig_with_type = der.to_vec();
            sig_with_type.push(0x01); // SIGHASH_ALL

            psbt.inputs[i]
                .partial_sigs
                .insert(pubkey_bytes, sig_with_type);
            signed_count += 1;
        }

        Ok(signed_count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_key_01_bip39_vectors_and_checksum() {
        // Valid 12-word vector
        let phrase_12 = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let vault_12 = KeyVault::from_mnemonic(phrase_12, "").expect("Valid 12-word mnemonic");
        assert_eq!(vault_12.master_fingerprint(), [0x73, 0xc5, 0xda, 0x0a]);

        // Valid 24-word vector (24 abandons ends with art)
        let phrase_24 = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art";
        let vault_24 = KeyVault::from_mnemonic(phrase_24, "").expect("Valid 24-word mnemonic");
        assert_ne!(vault_24.master_fingerprint(), [0u8; 4]);

        // Invalid checksum: changing last word to 'abandon' fails checksum validation
        let invalid_phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon";
        let err = KeyVault::from_mnemonic(invalid_phrase, "").unwrap_err();
        assert!(
            matches!(err, VaultError::MnemonicError(_)),
            "Invalid checksum must fail"
        );
    }

    #[test]
    fn test_key_02_passphrase_separation() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let vault_empty_pass = KeyVault::from_mnemonic(phrase, "").unwrap();
        let vault_trezor_pass = KeyVault::from_mnemonic(phrase, "TREZOR").unwrap();

        // Fingerprints must be completely distinct
        assert_ne!(
            vault_empty_pass.master_fingerprint(),
            vault_trezor_pass.master_fingerprint()
        );

        let digest = [0x42u8; 32];
        let (addr_empty, _) = vault_empty_pass
            .derive_address_and_sign("m/44'/60'/0'/0/0", &digest)
            .unwrap();
        let (addr_trezor, _) = vault_trezor_pass
            .derive_address_and_sign("m/44'/60'/0'/0/0", &digest)
            .unwrap();

        // Derived addresses must be valid and completely different
        assert_eq!(addr_empty, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
        assert_ne!(addr_empty, addr_trezor);
    }

    #[test]
    fn test_key_03_key_05_derivation_and_signature_self_verification() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let vault = KeyVault::from_mnemonic(phrase, "").unwrap();
        assert_eq!(vault.master_fingerprint(), [0x73, 0xc5, 0xda, 0x0a]);

        let digest = [0x55u8; 32];
        let (address, sig) = vault
            .derive_address_and_sign("m/44'/60'/0'/0/0", &digest)
            .unwrap();

        assert_eq!(address, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94");
        assert_eq!(sig.len(), 65);
        assert!(sig[64] == 27 || sig[64] == 28);
    }

    #[test]
    fn test_btc_01_vault_bitcoin_p2wpkh_derivation() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let vault = KeyVault::from_mnemonic(phrase, "").unwrap();
        assert_eq!(vault.master_fingerprint(), [0x73, 0xc5, 0xda, 0x0a]);

        // BIP-84 m/84'/0'/0'/0/0 -> bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu
        let (addr, pubk) = vault
            .derive_bitcoin_address("m/84'/0'/0'/0/0", "bc")
            .unwrap();
        assert_eq!(addr, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu");
        assert_eq!(pubk.len(), 33);

        // BIP-84 m/84'/0'/0'/1/0 (change) -> bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el
        let (change_addr, _) = vault
            .derive_bitcoin_address("m/84'/0'/0'/1/0", "bc")
            .unwrap();
        assert_eq!(change_addr, "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el");
    }

    #[test]
    fn test_btc_02_vault_psbt_signing_and_verification() {
        use public_core::bitcoin::{
            OutPoint, Psbt, PsbtInput, PsbtOutput, Transaction, TxIn, TxOut,
        };
        use std::collections::BTreeMap;

        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let vault = KeyVault::from_mnemonic(phrase, "").unwrap();

        // 1. Derive input pubkey
        let (_addr, pubk) = vault
            .derive_bitcoin_address("m/84'/0'/0'/0/0", "bc")
            .unwrap();

        // 2. Build non_witness_utxo
        let prev_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: [0xaa; 32],
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xffffffff,
            }],
            outputs: vec![TxOut {
                value: 200_000,
                script_pubkey: vec![
                    0x00, 0x14, 0xc0, 0xce, 0xbc, 0xd6, 0xc3, 0xd3, 0xca, 0x8c, 0x75, 0xdc, 0x5e,
                    0xc6, 0x2e, 0xbe, 0x55, 0x33, 0x0e, 0xf9, 0x10, 0xe2,
                ],
            }],
        };
        let prev_txid = prev_tx.txid();

        // 3. Build unsigned tx
        let unsigned_tx = Transaction {
            version: 2,
            lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint {
                    txid: prev_txid,
                    vout: 0,
                },
                script_sig: vec![],
                sequence: 0xfffffffd,
            }],
            outputs: vec![TxOut {
                value: 195_000,
                script_pubkey: vec![
                    0x00, 0x14, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
                    0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44,
                ],
            }],
        };

        let mut in_derivations = BTreeMap::new();
        in_derivations.insert(
            pubk.to_vec(),
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

        let mut psbt = Psbt {
            unsigned_tx,
            inputs: vec![psbt_in],
            outputs: vec![PsbtOutput::default()],
            unknown_global: BTreeMap::new(),
        };

        let mut forged_change = psbt.clone();
        forged_change.outputs[0].bip32_derivation.insert(
            pubk.to_vec(),
            (
                vault.master_fingerprint(),
                vec![0x80000054, 0x80000000, 0x80000000, 1, 0],
            ),
        );
        assert!(vault.audit_psbt_p2wpkh(&forged_change, "bc").is_err());
        assert!(vault.sign_psbt_p2wpkh(&mut forged_change).is_err());
        assert_eq!(
            vault.primitive_sign_invocations(),
            0,
            "Reject forged change before signing"
        );

        let signed_count = vault
            .sign_psbt_p2wpkh(&mut psbt)
            .expect("PSBT signing must succeed");
        assert_eq!(signed_count, 1);
        assert_eq!(psbt.inputs[0].partial_sigs.len(), 1);
        assert!(
            public_core::bitcoin::finalize_and_extract_p2wpkh_psbt(&psbt).is_ok(),
            "A self-verified signature must also pass the independent finalizer"
        );

        let sig = psbt.inputs[0].partial_sigs.get(pubk.as_slice()).unwrap();
        assert!(sig.len() >= 71);
        assert_eq!(*sig.last().unwrap(), 0x01); // SIGHASH_ALL byte
    }

    #[test]
    fn okx_account_standard_exports_actual_account_xpub_and_derivable_children() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        for passphrase in ["", "isolated-passphrase-2026"] {
            let vault = KeyVault::from_mnemonic(phrase, passphrase).unwrap();
            let own = vault.build_multi_accounts_ur(&[0, 1], "bcrt", 80).unwrap();
            let export = vault.build_okx_multi_accounts_ur(80).unwrap();
            let multi = ur_adapter::CryptoMultiAccounts::from_cbor_bytes(
                &hex::decode(&export.cbor_hex).unwrap(),
            )
            .unwrap();
            assert_eq!(multi.keys.len(), 2);
            assert!(export.btc_accounts.is_empty());
            assert_eq!(export.evm_accounts, own.evm_accounts);
            let key = &multi.keys[0];
            assert_eq!(key.origin.to_string_path(), "m/44'/60'/0'");
            assert_eq!(key.origin.depth, Some(3));
            assert_eq!(
                key.origin.source_fingerprint,
                Some(vault.master_fingerprint())
            );
            assert_eq!(key.name.as_deref(), Some("Keystone"));
            assert_eq!(key.note.as_deref(), Some("account.standard"));
            let xpub = bip32::XPub::from_str(&export.evm_accounts[0].account_xpub).unwrap();
            assert_eq!(key.key_data, xpub.to_bytes());
            assert_eq!(
                key.chain_code.as_deref(),
                Some(xpub.attrs().chain_code.as_slice())
            );
            assert_eq!(
                key.parent_fingerprint,
                Some(xpub.attrs().parent_fingerprint)
            );
            let leaf = &multi.keys[1];
            assert_eq!(
                hex::encode(&leaf.key_data),
                export.evm_accounts[0].compressed_pubkey_hex
            );
            assert_eq!(leaf.chain_code, None);
            assert_eq!(leaf.parent_fingerprint, None);
            assert_eq!(leaf.origin.to_string_path(), "m/44'/60'/0'/0/0");
            assert_eq!(
                leaf.origin.source_fingerprint,
                Some(vault.master_fingerprint())
            );
            assert_eq!(leaf.origin.depth, Some(5));
            assert_eq!(leaf.name.as_deref(), Some("Keystone"));
            assert_eq!(leaf.note.as_deref(), Some("account.ledger_live"));
            for account in &export.evm_accounts {
                let change = xpub
                    .derive_child(bip32::ChildNumber::new(0, false).unwrap())
                    .unwrap();
                let child = change
                    .derive_child(bip32::ChildNumber::new(account.account_index, false).unwrap())
                    .unwrap();
                assert_eq!(hex::encode(child.to_bytes()), account.compressed_pubkey_hex);
                let pubkey = secp256k1::PublicKey::from_slice(&child.to_bytes())
                    .unwrap()
                    .serialize_uncompressed();
                let digest = keccak256(&pubkey[1..]);
                assert_eq!(to_checksum_address(&digest[12..]), account.address);
            }
            assert_eq!(
                ur_adapter::DecodedUrPayload::decode(&export.ur_single).unwrap(),
                ur_adapter::DecodedUrPayload::MultiAccounts(multi)
            );
            assert!(export.fountain_frames.len() > 1);
            assert_eq!(vault.primitive_sign_invocations(), 0);
            assert_eq!(
                vault.build_multi_accounts_ur(&[0, 1], "bcrt", 80).unwrap(),
                own
            );
        }
    }

    #[test]
    fn test_key_04_generate_and_multi_accounts_ur_export() {
        let m12_a = KeyVault::generate_mnemonic(12).expect("12-word generation");
        let m12_b = KeyVault::generate_mnemonic(12).expect("12-word generation");
        assert_ne!(m12_a, m12_b, "CSPRNG must produce distinct mnemonics");
        assert_eq!(KeyVault::validate_mnemonic_detailed(&m12_a).unwrap(), 12);

        let m24 = KeyVault::generate_mnemonic(24).expect("24-word generation");
        assert_eq!(KeyVault::validate_mnemonic_detailed(&m24).unwrap(), 24);

        assert!(
            KeyVault::generate_mnemonic(15).is_err(),
            "15 words must be rejected"
        );
        assert!(
            KeyVault::validate_mnemonic_detailed("abandon abandon abandon").is_err(),
            "3 words must be rejected"
        );
        assert!(
            KeyVault::validate_mnemonic_detailed(
                "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon notaword"
            )
            .is_err(),
            "Unknown word must be rejected"
        );

        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let vault = KeyVault::from_mnemonic(phrase, "").unwrap();
        let export = vault.build_multi_accounts_ur(&[0, 1], "bcrt", 80).unwrap();
        assert_eq!(export.master_fingerprint, "73c5da0a");
        assert_eq!(export.evm_accounts.len(), 2);
        assert_eq!(
            export.evm_accounts[0].address,
            "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
        );
        assert_eq!(export.btc_accounts.len(), 2);
        assert!(export.btc_accounts[0].receive_address.starts_with("bcrt1q"));
        assert!(export.ur_single.starts_with("ur:crypto-multi-accounts/"));
        assert!(!export.fountain_frames.is_empty());
    }
}
