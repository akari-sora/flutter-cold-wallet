use public_core::error::CoreError;
use public_core::evm::{keccak256, AccessListItem, Eip1559Transaction, ParsedIntent};
use public_core::policy::{PolicyEngine, PolicyVerdict};
use public_core::rlp::{encode_bytes, encode_list, encode_u64};

const SEPOLIA_CHAIN_ID: u64 = 11_155_111;
const RECIPIENT: &str = "f39fd6e51aad88f6f4ce6ab8827279cfffb92266";

fn unsigned_type2(chain_id: u64, gas_limit: u64, to: &[u8], data: &[u8]) -> Vec<u8> {
    let fields = [
        encode_u64(chain_id),
        encode_u64(362),
        encode_u64(1_000_000_000),
        encode_u64(1_000_000_021),
        encode_u64(gas_limit),
        encode_bytes(to),
        encode_u64(1_000_000_000_000),
        encode_bytes(data),
        encode_list(&[]),
    ];
    let mut raw = vec![0x02];
    raw.extend_from_slice(&encode_list(&fields));
    raw
}

#[test]
fn current_okx_sepolia_request_preserves_12000_gas_and_signing_payload() {
    // Same shape as the unsigned Type-2 self-transfer stock OKX 6.192.0 produced on
    // 2026-10-15, with Anvil account #0 as signer and recipient.
    let raw = hex::decode(
        "02f183aa36a782016a843b9aca00843b9aca15822ee094f39fd6e51aad88f6f4ce6ab8827279cfffb9226685e8d4a5100080c0",
    )
    .unwrap();
    let tx = Eip1559Transaction::decode(&raw, SEPOLIA_CHAIN_ID)
        .expect("post-Amsterdam Sepolia accepts a 12,000 gas structural floor");

    assert_eq!(tx.chain_id, SEPOLIA_CHAIN_ID);
    assert_eq!(tx.nonce, 362);
    assert_eq!(tx.max_priority_fee_per_gas, 1_000_000_000);
    assert_eq!(tx.max_fee_per_gas, 1_000_000_021);
    assert_eq!(tx.gas_limit, 12_000);
    assert_eq!(
        tx.to.as_ref().unwrap().to_lowercase(),
        format!("0x{RECIPIENT}")
    );
    assert_eq!(tx.value_wei, "1000000000000");
    assert!(tx.data.is_empty());
    assert!(tx.access_list.is_empty());
    assert_eq!(tx.signing_preimage_hash(), keccak256(&raw));
    tx.validate_gas_for_signer(&format!("0x{RECIPIENT}"))
        .expect("the request is a self-transfer for its expected signer");

    let intent = tx.to_intent();
    assert!(matches!(
        &intent,
        ParsedIntent::NativeTransfer { fee_cap_wei, .. }
            if fee_cap_wei == "12000000252000"
    ));
    assert!(matches!(
        PolicyEngine::default().evaluate_intent(&intent),
        PolicyVerdict::Approved { .. }
    ));
}

#[test]
fn sepolia_rejects_gas_below_12000() {
    let recipient = hex::decode(RECIPIENT).unwrap();
    let raw = unsigned_type2(SEPOLIA_CHAIN_ID, 11_999, &recipient, &[]);
    assert!(matches!(
        Eip1559Transaction::decode(&raw, SEPOLIA_CHAIN_ID),
        Err(CoreError::InvalidGasParameters(_))
    ));
}

#[test]
fn other_chains_keep_the_21000_gas_floor() {
    let recipient = hex::decode(RECIPIENT).unwrap();
    for chain_id in [1, 1337, 31337, 17000] {
        for gas_limit in [12_000, 20_999] {
            let raw = unsigned_type2(chain_id, gas_limit, &recipient, &[]);
            assert!(
                matches!(
                    Eip1559Transaction::decode(&raw, chain_id),
                    Err(CoreError::InvalidGasParameters(_))
                ),
                "chain {chain_id} must reject gas limit {gas_limit}"
            );
        }
        let raw = unsigned_type2(chain_id, 21_000, &recipient, &[]);
        assert_eq!(
            Eip1559Transaction::decode(&raw, chain_id)
                .expect("other chains retain the existing 21,000 gas floor")
                .gas_limit,
            21_000
        );
    }
}

#[test]
fn sepolia_still_accepts_21000_gas() {
    let recipient = hex::decode(RECIPIENT).unwrap();
    let raw = unsigned_type2(SEPOLIA_CHAIN_ID, 21_000, &recipient, &[]);
    assert_eq!(
        Eip1559Transaction::decode(&raw, SEPOLIA_CHAIN_ID)
            .unwrap()
            .gas_limit,
        21_000
    );
}

#[test]
fn mainnet_still_requires_policy_rejection() {
    let recipient = hex::decode(RECIPIENT).unwrap();
    let raw = unsigned_type2(1, 21_000, &recipient, &[]);
    let tx = Eip1559Transaction::decode(&raw, 1).unwrap();
    assert!(matches!(
        PolicyEngine::default().evaluate_intent(&tx.to_intent()),
        PolicyVerdict::Rejected { reason } if reason.contains("not in the allowed network list")
    ));
}

#[test]
fn sepolia_gas_floor_does_not_bypass_unsupported_payload_policy() {
    let recipient = hex::decode(RECIPIENT).unwrap();
    for (to, data) in [
        (recipient.as_slice(), &[0x12, 0x34, 0x56, 0x78][..]),
        (&[][..], &[][..]),
    ] {
        let raw = unsigned_type2(SEPOLIA_CHAIN_ID, 12_000, to, data);
        let tx = Eip1559Transaction::decode(&raw, SEPOLIA_CHAIN_ID).unwrap();
        assert!(tx
            .validate_gas_for_signer(&format!("0x{RECIPIENT}"))
            .is_err());
        assert!(matches!(
            PolicyEngine::default().evaluate_intent(&tx.to_intent()),
            PolicyVerdict::Rejected { .. }
        ));
    }
}

#[test]
fn low_gas_signer_guard_rejects_wrong_sender_data_access_list_and_other_chains() {
    let recipient = hex::decode(RECIPIENT).unwrap();
    let raw = unsigned_type2(SEPOLIA_CHAIN_ID, 12_000, &recipient, &[]);
    let tx = Eip1559Transaction::decode(&raw, SEPOLIA_CHAIN_ID).unwrap();
    let signer = format!("0x{RECIPIENT}");
    assert!(tx
        .validate_gas_for_signer("0x9858effd232b4033e47d90003d41ec34ecaeda94")
        .is_err());

    let mut with_data = tx.clone();
    with_data.data = vec![0x01];
    assert!(with_data.validate_gas_for_signer(&signer).is_err());

    let mut with_access = tx.clone();
    with_access.access_list.push(AccessListItem {
        address: signer.clone(),
        storage_keys: vec![],
    });
    assert!(with_access.validate_gas_for_signer(&signer).is_err());

    for chain_id in [1, 1337, 31337, 17000] {
        let mut other_chain = tx.clone();
        other_chain.chain_id = chain_id;
        assert!(other_chain.validate_gas_for_signer(&signer).is_err());
    }
}

#[test]
fn low_gas_wire_parser_rejects_malformed_nonempty_access_list() {
    let recipient = hex::decode(RECIPIENT).unwrap();
    let fields = [
        encode_u64(SEPOLIA_CHAIN_ID),
        encode_u64(362),
        encode_u64(1_000_000_000),
        encode_u64(1_000_000_021),
        encode_u64(12_000),
        encode_bytes(&recipient),
        encode_u64(1_000_000_000_000),
        encode_bytes(&[]),
        encode_list(&[encode_bytes(&[])]),
    ];
    let mut raw = vec![0x02];
    raw.extend_from_slice(&encode_list(&fields));
    assert!(matches!(
        Eip1559Transaction::decode(&raw, SEPOLIA_CHAIN_ID),
        Err(CoreError::InvalidGasParameters(_))
    ));
}
