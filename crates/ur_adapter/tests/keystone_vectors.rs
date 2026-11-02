use ur_adapter::crypto_keypath::{CryptoKeyPath, PathComponent};
use ur_adapter::crypto_multi_accounts::{CryptoHDKey, CryptoMultiAccounts};
use ur_adapter::eth_sign_request::{DataType, EthSignRequest};
use ur_adapter::eth_signature::EthSignature;
use ur_adapter::DecodedUrPayload;

#[test]
fn test_ur_06_request_id_byte_for_byte_equality() {
    let req_id: [u8; 16] = [
        0x9b, 0x1d, 0xeb, 0x4d, 0x3b, 0x7d, 0x4b, 0xa3, 0xa4, 0x1a, 0x66, 0x5a, 0x3e, 0x78, 0x7a,
        0xb7,
    ];

    let derivation_path = CryptoKeyPath {
        components: vec![
            PathComponent {
                index: 44,
                hardened: true,
            },
            PathComponent {
                index: 60,
                hardened: true,
            },
            PathComponent {
                index: 0,
                hardened: true,
            },
            PathComponent {
                index: 0,
                hardened: false,
            },
            PathComponent {
                index: 0,
                hardened: false,
            },
        ],
        source_fingerprint: Some([0x73, 0xc5, 0xda, 0x0a]),
        depth: Some(5),
    };

    let sign_req = EthSignRequest {
        request_id: Some(req_id),
        sign_data: vec![0xf8, 0x49, 0x01, 0x82, 0x03, 0xe8],
        data_type: DataType::Transaction,
        chain_id: Some(11155111),
        derivation_path,
        address: Some([0x11; 20]),
        origin: Some("metamask".into()),
    };

    let cbor_bytes = sign_req.to_cbor_bytes();
    // Invariant: EthSignRequest CBOR must be wrapped in Tag 401 (0xd9, 0x01, 0x91)
    assert_eq!(&cbor_bytes[0..3], &[0xd9, 0x01, 0x91]);

    let decoded_req = EthSignRequest::from_cbor_bytes(&cbor_bytes).unwrap();
    assert_eq!(decoded_req.request_id, Some(req_id));
    assert_eq!(decoded_req.chain_id, Some(11155111));
    assert_eq!(
        decoded_req.derivation_path.to_string_path(),
        "m/44'/60'/0'/0/0"
    );

    // Vault constructs signature response and returns the exact same request_id
    let sig_65 = [0x55u8; 65];
    let eth_sig = EthSignature::new(decoded_req.request_id, sig_65, Some("MobileVault".into()));
    let sig_cbor = eth_sig.to_cbor_bytes();
    // Invariant: EthSignature CBOR must be wrapped in Tag 402 (0xd9, 0x01, 0x92)
    assert_eq!(&sig_cbor[0..3], &[0xd9, 0x01, 0x92]);

    let decoded_sig = EthSignature::from_cbor_bytes(&sig_cbor).unwrap();

    // Invariant: request_id must match byte-for-byte!
    assert_eq!(decoded_sig.request_id, Some(req_id));
    assert_eq!(decoded_sig.signature, sig_65);
}

#[test]
fn test_keystone_crypto_multi_accounts_roundtrip() {
    let keypath = CryptoKeyPath {
        components: vec![
            PathComponent {
                index: 44,
                hardened: true,
            },
            PathComponent {
                index: 60,
                hardened: true,
            },
            PathComponent {
                index: 0,
                hardened: true,
            },
        ],
        source_fingerprint: Some([0x73, 0xc5, 0xda, 0x0a]),
        depth: Some(3),
    };

    let hd_key = CryptoHDKey {
        name: None,
        parent_fingerprint: None,
        key_data: vec![0x02; 33],
        chain_code: Some(vec![0xcc; 32]),
        origin: keypath,
        note: Some("account.standard".into()),
    };

    let accounts = CryptoMultiAccounts {
        master_fingerprint: 0x73c5da0a,
        keys: vec![hd_key],
        device: Some("Keystone 3 Pro".into()),
        device_id: Some("dev-id-123".into()),
        version: Some("1.1.0".into()),
    };

    let ur_single = accounts.to_ur_single();
    let decoded = DecodedUrPayload::decode(&ur_single).expect("Decode multi-accounts");
    match decoded {
        DecodedUrPayload::MultiAccounts(acc) => {
            assert_eq!(acc.master_fingerprint, 0x73c5da0a);
            assert_eq!(acc.keys.len(), 1);
            assert_eq!(acc.keys[0].origin.to_string_path(), "m/44'/60'/0'");
        }
        _ => panic!("Expected MultiAccounts payload"),
    }
}

#[test]
fn public_pairing_preserves_hdkey_name_and_rejects_private_flag() {
    let public_key = CryptoHDKey {
        key_data: vec![0x02; 33],
        chain_code: Some(vec![0xcc; 32]),
        parent_fingerprint: Some([0x12, 0x34, 0x56, 0x78]),
        origin: CryptoKeyPath::from_string_path("m/44'/60'/0'", Some([0x73, 0xc5, 0xda, 0x0a]))
            .unwrap(),
        name: Some("Keystone".into()),
        note: Some("account.standard".into()),
    };
    let accounts = CryptoMultiAccounts {
        master_fingerprint: 0x73c5da0a,
        keys: vec![public_key],
        device: None,
        device_id: None,
        version: None,
    };
    let bytes = accounts.to_cbor_bytes();
    assert_eq!(
        CryptoMultiAccounts::from_cbor_bytes(&bytes).unwrap(),
        accounts
    );
    let mut cbor: ciborium::value::Value = ciborium::from_reader(bytes.as_slice()).unwrap();
    let ciborium::value::Value::Map(ref mut map) = cbor else {
        panic!("Expected map")
    };
    let (_, ciborium::value::Value::Array(keys)) = &mut map[1] else {
        panic!("Expected keys")
    };
    let ciborium::value::Value::Tag(303, hdkey) = &mut keys[0] else {
        panic!("Expected hdkey tag")
    };
    let ciborium::value::Value::Map(hdkey) = hdkey.as_mut() else {
        panic!("Expected hdkey map")
    };
    hdkey.push((
        ciborium::value::Value::Integer(2.into()),
        ciborium::value::Value::Bool(true),
    ));
    let mut private_flag_bytes = Vec::new();
    ciborium::into_writer(&cbor, &mut private_flag_bytes).unwrap();
    assert!(
        CryptoMultiAccounts::from_cbor_bytes(&private_flag_bytes).is_err(),
        "Public-only pairing must reject is-private=true even with compressed public key bytes"
    );
    let ciborium::value::Value::Map(ref mut map) = cbor else {
        unreachable!()
    };
    let (_, ciborium::value::Value::Array(keys)) = &mut map[1] else {
        unreachable!()
    };
    let ciborium::value::Value::Tag(_, hdkey) = &mut keys[0] else {
        unreachable!()
    };
    let ciborium::value::Value::Map(hdkey) = hdkey.as_mut() else {
        unreachable!()
    };
    hdkey.last_mut().unwrap().1 = ciborium::value::Value::Bool(false);
    let mut public_flag_bytes = Vec::new();
    ciborium::into_writer(&cbor, &mut public_flag_bytes).unwrap();
    assert_eq!(
        CryptoMultiAccounts::from_cbor_bytes(&public_flag_bytes).unwrap(),
        accounts
    );
}

#[test]
fn official_keystone_eth_account_hdkey_fixture_decodes_without_private_material() {
    // Primary reference: KeystoneHQ/ur-registry-eth at
    // 09363fb0a71015c31b301d97974a5532157e4dec, CryptoHDKey.test.ts.
    // Its map order differs from our pre-existing encoder; both encode the
    // same registry fields. Keep existing own-profile bytes unchanged.
    let hdkey = hex::decode(concat!(
        "a403582102eae4b876a8696134b868f88cc2f51f715f2dbedb7446b8e6edf3d4541c4eb67b",
        "045820d882718b7a42806803eeb17f7483f20620611adb88fc943c898dc5aba94c2819",
        "06d90130a20186182cf5183cf500f5021ae9181cf3081ad32e4508"
    ))
    .unwrap();
    // Wrap the literal official HDKey in crypto-multi-accounts, including its
    // registry tag, rather than constructing fixture bytes with our encoder.
    let mut bytes = hex::decode("a2011ae9181cf30281d9012f").unwrap();
    bytes.extend_from_slice(&hdkey);
    let accounts = CryptoMultiAccounts::from_cbor_bytes(&bytes).unwrap();
    let key = &accounts.keys[0];
    assert_eq!(accounts.master_fingerprint, 0xe9181cf3);
    assert_eq!(key.origin.to_string_path(), "m/44'/60'/0'");
    assert_eq!(
        key.origin.source_fingerprint,
        Some([0xe9, 0x18, 0x1c, 0xf3])
    );
    assert_eq!(key.origin.depth, None);
    assert_eq!(key.parent_fingerprint, Some([0xd3, 0x2e, 0x45, 0x08]));
    assert_eq!(
        hex::encode(&key.key_data),
        "02eae4b876a8696134b868f88cc2f51f715f2dbedb7446b8e6edf3d4541c4eb67b"
    );
    assert_eq!(
        hex::encode(key.chain_code.as_ref().unwrap()),
        "d882718b7a42806803eeb17f7483f20620611adb88fc943c898dc5aba94c2819"
    );
    assert_eq!(key.name, None);
    assert_eq!(key.note, None);
    assert_eq!(
        CryptoMultiAccounts::from_cbor_bytes(&accounts.to_cbor_bytes()).unwrap(),
        accounts
    );
}
