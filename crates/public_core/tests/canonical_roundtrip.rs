//! Public transaction bytes only; these tests never create keys or sign.
use public_core::evm::{keccak256, Eip1559Transaction, LegacyTransaction};
use public_core::rlp::{encode_bytes, encode_list, encode_u64};

const CHAIN: u64 = 11_155_111;

fn legacy_fields(value: &[u8]) -> Vec<Vec<u8>> {
    vec![
        encode_u64(1), encode_u64(2_000_000_000), encode_u64(21_000),
        encode_bytes(&[0x11; 20]), encode_bytes(value), encode_bytes(&[]),
        encode_u64(CHAIN), encode_u64(0), encode_u64(0),
    ]
}

fn values() -> Vec<Vec<u8>> {
    vec![vec![], vec![1], vec![127], vec![128], vec![1; 9], vec![0xff; 32]]
}

#[test]
fn canonical_legacy_u256_values_preserve_preimage_bytes() {
    for value in values() {
        let raw = encode_list(&legacy_fields(&value));
        let tx = LegacyTransaction::decode_unsigned(&raw, CHAIN).unwrap();
        assert_eq!(tx.signing_preimage_hash(), keccak256(&raw));
        assert_eq!(LegacyTransaction::decode(&raw, CHAIN).unwrap(), tx);
    }
}

#[test]
fn six_field_legacy_uses_the_explicit_chain_domain() {
    let fields = legacy_fields(&[0x80]);
    let raw = encode_list(&fields[..6]);
    let tx = LegacyTransaction::decode_unsigned(&raw, CHAIN).unwrap();
    assert_eq!(tx.chain_id, CHAIN);
    assert_eq!(tx.signing_preimage_hash(), keccak256(&encode_list(&fields)));
}

#[test]
fn declared_chain_preserves_existing_legacy_placeholder_compatibility() {
    let canonical = legacy_fields(&[1]);
    let mut compatibility = canonical.clone();
    compatibility[6] = encode_u64(CHAIN * 2 + 35);
    let tx = LegacyTransaction::decode_unsigned(&encode_list(&compatibility), CHAIN).unwrap();
    assert_eq!(tx.signing_preimage_hash(), keccak256(&encode_list(&canonical)));
}

#[test]
fn canonical_type2_values_and_ordered_duplicate_access_entries_preserve_digest() {
    let entry = encode_list(&[
        encode_bytes(&[0x22; 20]),
        encode_list(&[encode_bytes(&[0x33; 32]), encode_bytes(&[0x33; 32])]),
    ]);
    let access_list = encode_list(&[
        entry.clone(),
        encode_list(&[encode_bytes(&[0x44; 20]), encode_list(&[])]),
        entry,
    ]);
    for value in values() {
        let fields = vec![
            encode_u64(CHAIN), encode_u64(1), encode_u64(1_000_000_000),
            encode_u64(2_000_000_000), encode_u64(60_000),
            encode_bytes(&[0x11; 20]), encode_bytes(&value), encode_bytes(&[]),
            access_list.clone(),
        ];
        let mut raw = vec![2];
        raw.extend(encode_list(&fields));
        let tx = Eip1559Transaction::decode_unsigned(&raw, CHAIN).unwrap();
        assert_eq!(tx.access_list.len(), 3);
        assert_eq!(tx.access_list[0], tx.access_list[2]);
        assert_eq!(tx.signing_preimage_hash(), keccak256(&raw));
        assert_eq!(Eip1559Transaction::decode(&raw, CHAIN).unwrap(), tx);
    }
}

#[test]
fn existing_public_eip155_envelope_remains_inspectable() {
    // Published EIP-155 signed transaction; decoding performs no signing.
    let raw = hex::decode(concat!(
        "f86c098504a817c800825208943535353535353535353535353535353535353535",
        "880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276",
        "a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
    )).unwrap();
    let tx = LegacyTransaction::decode(&raw, 1).unwrap();
    assert_eq!(tx.chain_id, 1);
    assert_eq!(hex::encode(tx.signing_preimage_hash()),
        "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53");
}
