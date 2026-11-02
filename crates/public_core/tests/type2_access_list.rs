use public_core::evm::{keccak256, Eip1559Transaction};
use public_core::rlp::{encode_bytes, encode_list, encode_u64};

const CHAIN_ID: u64 = 11_155_111;

fn unsigned_type2(access_list: Vec<u8>) -> Vec<u8> {
    let fields = [
        encode_u64(CHAIN_ID),
        encode_u64(5),
        encode_u64(1_000_000_000),
        encode_u64(2_000_000_000),
        // Exercise the access-list decoder rather than the low-gas guard.
        encode_u64(50_000),
        encode_bytes(&[0x11; 20]),
        encode_u64(123),
        encode_bytes(&[]),
        access_list,
    ];
    let mut raw = vec![0x02];
    raw.extend_from_slice(&encode_list(&fields));
    raw
}

fn entry(address: &[u8], keys: &[&[u8]]) -> Vec<u8> {
    let keys: Vec<_> = keys.iter().map(|key| encode_bytes(key)).collect();
    encode_list(&[encode_bytes(address), encode_list(&keys)])
}

fn assert_rejected(access_list: Vec<u8>) {
    let raw = unsigned_type2(access_list);
    if let Ok(tx) = Eip1559Transaction::decode(&raw, CHAIN_ID) {
        let original_hash = keccak256(&raw);
        let reconstructed_hash = tx.signing_preimage_hash();
        panic!(
            "malformed access list accepted: original_unsigned_hash={}, reconstructed_signing_hash={}, preimage_changed={}",
            hex::encode(original_hash),
            hex::encode(reconstructed_hash),
            original_hash != reconstructed_hash,
        );
    }
}

fn assert_roundtrip(access_list: Vec<u8>) -> Eip1559Transaction {
    let raw = unsigned_type2(access_list);
    let tx = Eip1559Transaction::decode(&raw, CHAIN_ID).expect("canonical access list must decode");
    assert_eq!(tx.signing_preimage_hash(), keccak256(&raw));
    tx
}

macro_rules! rejects_access_list {
    ($name:ident, $access_list:expr) => {
        #[test]
        fn $name() {
            assert_rejected($access_list);
        }
    };
}

rejects_access_list!(rejects_outer_empty_bytes, encode_bytes(&[]));
rejects_access_list!(rejects_outer_nonempty_bytes, encode_bytes(&[0x01]));
rejects_access_list!(rejects_empty_byte_entry, encode_list(&[encode_bytes(&[])]));
rejects_access_list!(
    rejects_nonempty_byte_entry,
    encode_list(&[encode_bytes(&[0x01])])
);
rejects_access_list!(
    rejects_entry_without_fields,
    encode_list(&[encode_list(&[])])
);
rejects_access_list!(
    rejects_entry_without_keys,
    encode_list(&[encode_list(&[encode_bytes(&[0x11; 20])])])
);
rejects_access_list!(
    rejects_entry_with_extra_field,
    encode_list(&[encode_list(&[
        encode_bytes(&[0x11; 20]),
        encode_list(&[]),
        encode_bytes(&[0x01]),
    ])])
);
rejects_access_list!(
    rejects_empty_byte_key_container,
    encode_list(&[encode_list(
        &[encode_bytes(&[0x11; 20]), encode_bytes(&[]),]
    )])
);
rejects_access_list!(
    rejects_nonempty_byte_key_container,
    encode_list(&[encode_list(&[
        encode_bytes(&[0x11; 20]),
        encode_bytes(&[0x01]),
    ])])
);
rejects_access_list!(rejects_empty_address, encode_list(&[entry(&[], &[])]));
rejects_access_list!(
    rejects_19_byte_address,
    encode_list(&[entry(&[0x11; 19], &[])])
);
rejects_access_list!(
    rejects_21_byte_address,
    encode_list(&[entry(&[0x11; 21], &[])])
);
rejects_access_list!(
    rejects_list_address,
    encode_list(&[encode_list(&[encode_list(&[]), encode_list(&[])])])
);
rejects_access_list!(
    rejects_empty_key,
    encode_list(&[entry(&[0x11; 20], &[&[]])])
);
rejects_access_list!(
    rejects_31_byte_key,
    encode_list(&[entry(&[0x11; 20], &[&[0x22; 31]])])
);
rejects_access_list!(
    rejects_33_byte_key,
    encode_list(&[entry(&[0x11; 20], &[&[0x22; 33]])])
);
rejects_access_list!(
    rejects_list_key,
    encode_list(&[encode_list(&[
        encode_bytes(&[0x11; 20]),
        encode_list(&[encode_list(&[])]),
    ])])
);

#[test]
fn rejects_malformed_entry_at_any_position_among_valid_entries() {
    let valid = entry(&[0x11; 20], &[&[0x22; 32]]);
    for malformed in [
        encode_bytes(&[]),
        encode_list(&[]),
        encode_list(&[encode_bytes(&[0x11; 20])]),
        encode_list(&[
            encode_bytes(&[0x11; 20]),
            encode_list(&[]),
            encode_list(&[]),
        ]),
    ] {
        for position in 0..=2 {
            let mut entries = vec![valid.clone(), valid.clone()];
            entries.insert(position, malformed.clone());
            assert_rejected(encode_list(&entries));
        }
    }
}

#[test]
fn rejects_malformed_key_at_any_position_among_valid_keys() {
    let valid = encode_bytes(&[0x22; 32]);
    for malformed in [
        encode_bytes(&[]),
        encode_bytes(&[0x22; 31]),
        encode_bytes(&[0x22; 33]),
        encode_list(&[]),
    ] {
        for position in 0..=2 {
            let mut keys = vec![valid.clone(), valid.clone()];
            keys.insert(position, malformed.clone());
            assert_rejected(encode_list(&[encode_list(&[
                encode_bytes(&[0x11; 20]),
                encode_list(&keys),
            ])]));
        }
    }
}

#[test]
fn preserves_empty_access_list_preimage() {
    let tx = assert_roundtrip(encode_list(&[]));
    assert!(tx.access_list.is_empty());
}

#[test]
fn preserves_zero_address_and_zero_storage_key_widths() {
    let tx = assert_roundtrip(encode_list(&[entry(&[0; 20], &[&[0; 32]])]));
    assert_eq!(tx.access_list[0].address, format!("0x{}", "00".repeat(20)));
    assert_eq!(
        tx.access_list[0].storage_keys,
        vec![format!("0x{}", "00".repeat(32))]
    );
}

#[test]
fn preserves_entry_with_empty_storage_key_list() {
    let tx = assert_roundtrip(encode_list(&[entry(&[0x11; 20], &[])]));
    assert_eq!(tx.access_list.len(), 1);
    assert_eq!(tx.access_list[0].address, format!("0x{}", "11".repeat(20)));
    assert!(tx.access_list[0].storage_keys.is_empty());
}

#[test]
fn preserves_multiple_entries_keys_order_and_duplicates() {
    let address_a = [0x22; 20];
    let address_b = [0x11; 20];
    let mut key_a = [0u8; 32];
    key_a[31] = 7;
    let mut key_b = [0u8; 32];
    key_b[31] = 3;
    let repeated = entry(&address_a, &[&key_a, &key_b, &key_a]);
    let tx = assert_roundtrip(encode_list(&[
        repeated.clone(),
        entry(&address_b, &[]),
        repeated,
    ]));
    assert_eq!(tx.access_list.len(), 3);
    assert_eq!(tx.access_list[0].address, format!("0x{}", "22".repeat(20)));
    assert_eq!(tx.access_list[1].address, format!("0x{}", "11".repeat(20)));
    assert!(tx.access_list[1].storage_keys.is_empty());
    assert_eq!(tx.access_list[0], tx.access_list[2]);
    assert_eq!(
        tx.access_list[0].storage_keys,
        vec![
            format!("0x{}", hex::encode(key_a)),
            format!("0x{}", hex::encode(key_b)),
            format!("0x{}", hex::encode(key_a)),
        ]
    );
}
