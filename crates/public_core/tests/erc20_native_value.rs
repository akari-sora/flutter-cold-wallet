use public_core::evm::{Eip1559Transaction, LegacyTransaction, ParsedIntent};

#[test]
fn token_review_must_not_hide_a_native_spend() {
    let mut data = vec![0xa9, 0x05, 0x9c, 0xbb];
    data.extend([0_u8; 12]);
    data.extend([0x22_u8; 20]);
    data.extend([0_u8; 31]);
    data.push(1);
    let legacy = LegacyTransaction {
        nonce: 0,
        gas_price: 1,
        gas_limit: 50000,
        to: Some("0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238".into()),
        value_wei: "1".into(),
        data: data.clone(),
        chain_id: 11155111,
    };
    let typed = Eip1559Transaction {
        chain_id: 11155111,
        nonce: 0,
        max_priority_fee_per_gas: 1,
        max_fee_per_gas: 2,
        gas_limit: 50000,
        to: legacy.to.clone(),
        value_wei: "1".into(),
        data,
        access_list: vec![],
    };
    assert!(matches!(
        legacy.to_intent(),
        ParsedIntent::PolicyRejected { .. }
    ));
    assert!(matches!(
        typed.to_intent(),
        ParsedIntent::PolicyRejected { .. }
    ));
    assert!(matches!(
        LegacyTransaction {
            value_wei: "0".into(),
            ..legacy
        }
        .to_intent(),
        ParsedIntent::Erc20Transfer { .. }
    ));
    assert!(matches!(
        Eip1559Transaction {
            value_wei: "0".into(),
            ..typed
        }
        .to_intent(),
        ParsedIntent::Erc20Transfer { .. }
    ));
}
