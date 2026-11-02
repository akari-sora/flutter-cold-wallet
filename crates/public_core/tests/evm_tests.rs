use public_core::eip712::Eip712Parser;
use public_core::error::CoreError;
use public_core::evm::{keccak256, Eip1559Transaction, LegacyTransaction, ParsedIntent};
use public_core::policy::{PolicyEngine, PolicyVerdict};
use public_core::rlp::{decode_rlp, encode_bytes, encode_list, encode_u64};
use public_core::verify::verify_ethereum_signature;
use secp256k1::ecdsa::RecoverableSignature;
use secp256k1::{Message, SecretKey};

#[test]
fn test_legacy_native_transfer_parsing_and_preimage() {
    let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
    let fields = vec![
        encode_u64(0),                      // nonce = 0
        encode_u64(20_000_000_000),         // gasPrice = 20 gwei
        encode_u64(21000),                  // gasLimit = 21000
        encode_bytes(&to_addr),             // to
        encode_u64(1_000_000_000_000_000),  // 0.001 ETH
        encode_bytes(&[]),                  // empty data (native transfer)
        encode_u64(11155111 * 2 + 35),      // EIP-155 v for Sepolia
        encode_u64(0),                      // r = 0
        encode_u64(0),                      // s = 0
    ];
    let raw_rlp = encode_list(&fields);

    let tx = LegacyTransaction::decode(&raw_rlp, 11155111).expect("Decode should succeed");
    assert_eq!(tx.nonce, 0);
    assert_eq!(tx.gas_limit, 21000);
    assert_eq!(tx.chain_id, 11155111);
    assert_eq!(tx.to.as_ref().unwrap().to_lowercase(), "0x9858effd232b4033e47d90003d41ec34ecaeda94");

    let intent = tx.to_intent();
    match &intent {
        ParsedIntent::NativeTransfer { chain_id, recipient, value_wei, fee_cap_wei } => {
            assert_eq!(*chain_id, 11155111);
            assert_eq!(recipient.to_lowercase(), "0x9858effd232b4033e47d90003d41ec34ecaeda94");
            assert_eq!(value_wei, "1000000000000000");
            assert_eq!(fee_cap_wei, "420000000000000");
        }
        _ => panic!("Expected NativeTransfer"),
    }

    let policy = PolicyEngine::default();
    let verdict = policy.evaluate_intent(&intent);
    match verdict {
        PolicyVerdict::Approved { chain_id, recipient, .. } => {
            assert_eq!(chain_id, 11155111);
            assert_eq!(recipient.to_lowercase(), "0x9858effd232b4033e47d90003d41ec34ecaeda94");
        }
        PolicyVerdict::Rejected { reason } => panic!("Policy unexpectedly rejected: {reason}"),
    }
}

#[test]
fn test_evm_01_legacy_replay_protection_strict_enforcement() {
    let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
    // Pre-EIP-155 transaction with v = 27 (unprotected)
    let fields = vec![
        encode_u64(0),
        encode_u64(20_000_000_000),
        encode_u64(21000),
        encode_bytes(&to_addr),
        encode_u64(1_000_000_000_000_000),
        encode_bytes(&[]),
        encode_u64(27), // v < 35 -> Unprotected!
        encode_u64(0),
        encode_u64(0),
    ];
    let raw_rlp = encode_list(&fields);

    let err = LegacyTransaction::decode(&raw_rlp, 1).unwrap_err();
    assert_eq!(err, CoreError::ReplayProtectionMissing);

    // Also with v = 28
    let mut fields_v28 = fields.clone();
    fields_v28[6] = encode_u64(28);
    let raw_rlp_v28 = encode_list(&fields_v28);
    let err28 = LegacyTransaction::decode(&raw_rlp_v28, 1).unwrap_err();
    assert_eq!(err28, CoreError::ReplayProtectionMissing);
}

#[test]
fn test_evm_02_eip1559_transaction_parsing_and_access_list() {
    let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
    let acc_addr = hex::decode("1111111111111111111111111111111111111111").unwrap();
    let storage_k1 = vec![0xaa; 32];
    let storage_k2 = vec![0xbb; 32];

    let access_item = encode_list(&[
        encode_bytes(&acc_addr),
        encode_list(&[encode_bytes(&storage_k1), encode_bytes(&storage_k2)]),
    ]);
    let access_list_encoded = encode_list(&[access_item]);

    let fields = vec![
        encode_u64(11155111),               // chain_id
        encode_u64(5),                      // nonce
        encode_u64(2_000_000_000),          // max_priority_fee = 2 gwei
        encode_u64(30_000_000_000),         // max_fee = 30 gwei
        encode_u64(21000),                  // gas_limit
        encode_bytes(&to_addr),             // to
        encode_u64(500_000_000_000_000),    // value = 0.0005 ETH
        encode_bytes(&[]),                  // empty data
        access_list_encoded,                // structured access_list
    ];
    let rlp_payload = encode_list(&fields);
    let mut raw_type2 = vec![0x02];
    raw_type2.extend_from_slice(&rlp_payload);

    let tx = Eip1559Transaction::decode(&raw_type2, 11155111).expect("Decode EIP-1559 should succeed");
    assert_eq!(tx.chain_id, 11155111);
    assert_eq!(tx.nonce, 5);
    assert_eq!(tx.max_fee_per_gas, 30_000_000_000);
    assert_eq!(tx.access_list.len(), 1);
    assert_eq!(tx.access_list[0].storage_keys.len(), 2);

    let preimage_hash = tx.signing_preimage_hash();
    assert_ne!(preimage_hash, [0u8; 32]);

    let intent = tx.to_intent();
    let policy = PolicyEngine::default();
    let verdict = policy.evaluate_intent(&intent);
    assert!(matches!(verdict, PolicyVerdict::Approved { .. }));
}

#[test]
fn test_evm_03_fail_closed_chain_id_checks() {
    let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
    // Mismatched chain_id
    let fields = vec![
        encode_u64(0),
        encode_u64(20_000_000_000),
        encode_u64(21000),
        encode_bytes(&to_addr),
        encode_u64(1_000_000_000),
        encode_bytes(&[]),
        encode_u64(11155111 * 2 + 35), // Payload chain_id 11155111
        encode_u64(0),
        encode_u64(0),
    ];
    let raw_rlp = encode_list(&fields);

    // Outer declared chain_id is 1337 -> Mismatch!
    let err = LegacyTransaction::decode(&raw_rlp, 1337).unwrap_err();
    assert!(matches!(err, CoreError::ChainIdMismatch { declared: 1337, payload: 11155111 }));

    // Mainnet (1) is not in default policy signing allowlist
    let policy = PolicyEngine::default();
    assert!(!policy.allowed_chain_ids.contains(&1), "Mainnet must not be in default signing allowlist in MVP");
}

#[test]
fn test_evm_04_erc20_dirty_padding_rejected() {
    let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
    // 68 bytes calldata for transfer(address,uint256)
    // Corrupt dirty padding in bytes 4..16 (set byte 5 to 0x01)
    let mut data = vec![0u8; 68];
    data[0..4].copy_from_slice(&[0xa9, 0x05, 0x9c, 0xbb]);
    data[5] = 0x01; // DIRTY PADDING!
    data[16..36].copy_from_slice(&to_addr);
    data[67] = 0x64; // amount = 100

    let fields = vec![
        encode_u64(0),
        encode_u64(20_000_000_000),
        encode_u64(21000),
        encode_bytes(&to_addr),
        encode_u64(0),
        encode_bytes(&data),
        encode_u64(11155111 * 2 + 35),
        encode_u64(0),
        encode_u64(0),
    ];
    let raw_rlp = encode_list(&fields);
    let tx = LegacyTransaction::decode(&raw_rlp, 11155111).unwrap();
    let intent = tx.to_intent();
    match intent {
        ParsedIntent::PolicyRejected { reason } => {
            assert!(reason.contains("Dirty padding detected"), "Must reject dirty padding: {reason}");
        }
        _ => panic!("Expected PolicyRejected due to dirty padding"),
    }
}

#[test]
fn test_evm_05_gas_boundary_checks() {
    let to_addr = hex::decode("9858effd232b4033e47d90003d41ec34ecaeda94").unwrap();
    // max_priority_fee (50 gwei) > max_fee (30 gwei)
    let fields = vec![
        encode_u64(11155111),
        encode_u64(5),
        encode_u64(50_000_000_000), // priority fee > max fee!
        encode_u64(30_000_000_000), // max fee
        encode_u64(21000),
        encode_bytes(&to_addr),
        encode_u64(500_000_000_000_000),
        encode_bytes(&[]),
        encode_list(&[]),
    ];
    let mut raw_type2 = vec![0x02];
    raw_type2.extend_from_slice(&encode_list(&fields));

    let err = Eip1559Transaction::decode(&raw_type2, 11155111).unwrap_err();
    assert!(matches!(err, CoreError::InvalidGasParameters(_)));

    // A distinct-recipient transfer still cannot use the self-transfer gas exception.
    let mut fields_low_gas = fields.clone();
    fields_low_gas[2] = encode_u64(10_000_000_000);
    fields_low_gas[4] = encode_u64(15000); // < 21000!
    let mut raw_low_gas = vec![0x02];
    raw_low_gas.extend_from_slice(&encode_list(&fields_low_gas));
    let tx_low_gas = Eip1559Transaction::decode(&raw_low_gas, 11155111).unwrap();
    let err_gas = tx_low_gas
        .validate_gas_for_signer("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266")
        .unwrap_err();
    assert!(matches!(err_gas, CoreError::InvalidGasParameters(_)));
}

#[test]
fn test_evm_06_contract_deployment_rejected() {
    // Contract deployment has empty 'to' bytes (0x80 in RLP)
    let fields = vec![
        encode_u64(0),
        encode_u64(20_000_000_000),
        encode_u64(21000),
        encode_bytes(&[]), // empty to -> contract deployment!
        encode_u64(0),
        encode_bytes(&[0x60, 0x80, 0x60, 0x40]), // bytecode
        encode_u64(11155111 * 2 + 35),
        encode_u64(0),
        encode_u64(0),
    ];
    let raw_rlp = encode_list(&fields);
    let tx = LegacyTransaction::decode(&raw_rlp, 11155111).unwrap();
    assert_eq!(tx.to, None);

    let intent = tx.to_intent();
    match intent {
        ParsedIntent::PolicyRejected { reason } => {
            assert!(reason.contains("Contract deployment is strictly rejected"), "{reason}");
        }
        _ => panic!("Expected contract deployment rejection"),
    }
}

#[test]
fn test_evm_07_canonical_rlp_rejections() {
    // Leading zero in RLP integer: e.g. 0x82 0x00 0x05 instead of 0x05
    let non_canonical_int = vec![0x82, 0x00, 0x05];
    let res = decode_rlp(&non_canonical_int).unwrap();
    assert!(res.as_u64().is_err(), "Must reject integer with leading zero");

    // Long string header for short payload: prefix 0xb8 (length 1), payload 0x42
    let non_canonical_str = vec![0xb8, 0x01, 0x42];
    let err = decode_rlp(&non_canonical_str).unwrap_err();
    assert!(format!("{err}").contains("Non-canonical long string"));
}

#[test]
fn test_msg_01_eip712_complex_vector_hashing() {
    let json_vector = r#"{
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"}
            ],
            "Person": [
                {"name": "name", "type": "string"},
                {"name": "wallet", "type": "address"}
            ],
            "Mail": [
                {"name": "from", "type": "Person"},
                {"name": "to", "type": "Person"},
                {"name": "contents", "type": "string"}
            ]
        },
        "primaryType": "Mail",
        "domain": {
            "name": "Ether Mail",
            "version": "1",
            "chainId": 11155111,
            "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
        },
        "message": {
            "from": {
                "name": "Cow",
                "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"
            },
            "to": {
                "name": "Bob",
                "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"
            },
            "contents": "Hello, Bob!"
        }
    }"#;

    let (digest, primary_type) = Eip712Parser::parse_and_hash(json_vector).expect("EIP-712 parse must succeed");
    assert_eq!(primary_type, "Mail");
    assert_ne!(digest, [0u8; 32]);
}

#[test]
fn test_msg_02_msg_03_permit_and_approve_rejected() {
    let permit_json = r#"{
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"}
            ],
            "Permit": [
                {"name": "owner", "type": "address"},
                {"name": "spender", "type": "address"},
                {"name": "value", "type": "uint256"},
                {"name": "nonce", "type": "uint256"},
                {"name": "deadline", "type": "uint256"}
            ]
        },
        "primaryType": "Permit",
        "domain": {
            "name": "USD Coin"
        },
        "message": {
            "owner": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
            "spender": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
            "value": "1000000",
            "nonce": 0,
            "deadline": 1999999999
        }
    }"#;

    let err = Eip712Parser::parse_and_hash(permit_json).unwrap_err();
    assert!(matches!(err, CoreError::PermitRejected(_)), "Permit must be rejected: {err}");

    // Policy template check
    let policy = PolicyEngine::default();
    let verdict = policy.evaluate_eip712_template("Permit");
    assert!(matches!(verdict, PolicyVerdict::Rejected { .. }));

    // Unapproved template check
    let unapproved_verdict = policy.evaluate_eip712_template("UnapprovedDeFiSwap");
    assert!(matches!(unapproved_verdict, PolicyVerdict::Rejected { .. }));

    // Approved template check
    let approved_verdict = policy.evaluate_eip712_template("Mail");
    assert!(matches!(approved_verdict, PolicyVerdict::Approved { .. }));
}

#[test]
fn test_signature_verification_and_address_recovery() {
    let secret_key = SecretKey::from_secret_bytes([0x42; 32]).unwrap();
    let pubkey = secret_key.public_key();

    let uncompressed = pubkey.serialize_uncompressed();
    let pubkey_hash = keccak256(&uncompressed[1..65]);
    let expected_address = format!("0x{}", hex::encode(&pubkey_hash[12..32]));

    let digest = [0x77u8; 32];
    let msg = Message::from_digest(digest);
    let sig = RecoverableSignature::sign_ecdsa_recoverable(msg, &secret_key);
    let (recid, compact) = sig.serialize_compact();

    let mut r = [0u8; 32];
    let mut s = [0u8; 32];
    r.copy_from_slice(&compact[0..32]);
    s.copy_from_slice(&compact[32..64]);
    let v = u8::from(recid) + 27; // wire format 27/28

    let recovered = verify_ethereum_signature(&digest, &r, &s, v, &expected_address).unwrap();
    assert!(recovered.eq_ignore_ascii_case(&expected_address));

    // Negative test: Mismatched expected address rejected
    let bad_expected = "0x0000000000000000000000000000000000000001";
    let err = verify_ethereum_signature(&digest, &r, &s, v, bad_expected).unwrap_err();
    assert!(format!("{err}").contains("Address mismatch"));

    // Negative test: High-s malleability rejected
    let high_s = [0xff; 32];
    let err_high_s = verify_ethereum_signature(&digest, &r, &high_s, v, &expected_address).unwrap_err();
    assert!(format!("{err_high_s}").contains("Malleable non-low-s signature rejected"));
}
