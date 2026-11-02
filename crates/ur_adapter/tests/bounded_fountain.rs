use ur_adapter::ffi_decode::decode_json;
use ur_adapter::{encode_ur_fountain_frames, UrSession};

#[test]
fn native_reassembly_handles_loss_duplicates_and_mixed_session_rejection() {
    let payload: Vec<u8> = (0..=255).cycle().take(700).collect();
    let mut encoder = ur::Encoder::new(&payload, 80, "eth-sign-request").unwrap();
    let mut session = UrSession::new("eth-sign-request");
    let mut result = None;
    // Discard every odd frame, including direct fragments. XOR recovery is needed.
    for index in 1..=200 {
        let frame = encoder.next_part().unwrap();
        if index % 2 == 1 {
            continue;
        }
        result = session.receive(&frame).unwrap();
        if result.is_some() {
            break;
        }
        assert!(session.receive(&frame).unwrap().is_none());
        assert!(session.resolved_fragments() < session.total_fragments());
    }
    assert_eq!(result, Some(payload));

    let a = encode_ur_fountain_frames("crypto-psbt", &[7; 300], 100).unwrap();
    let b = encode_ur_fountain_frames("crypto-psbt", &[8; 300], 100).unwrap();
    let mut session = UrSession::new("crypto-psbt");
    assert!(session.receive(&a[0]).unwrap().is_none());
    assert!(session.receive(&b[1]).is_err());
    assert_eq!(session.resolved_fragments(), 1);
    session.receive(&a[1]).unwrap();
    assert_eq!(session.receive(&a[2]).unwrap(), Some(vec![7; 300]));
}

#[test]
fn rejects_checksum_corruption_and_unbounded_fountain_metadata() {
    let valid = encode_ur_fountain_frames("bytes", b"data", 0)
        .unwrap()
        .remove(0);
    let corrupt = format!("{}ae", &valid[..valid.len() - 2]);
    let mut session = UrSession::new("bytes");
    assert!(session.receive(&corrupt).is_err());
    assert!(!session.is_complete());
    assert_eq!(session.receive(&valid).unwrap(), Some(b"data".to_vec()));

    // A valid Bytewords checksum cannot bypass bounds on claimed allocation.
    let mut cbor = Vec::new();
    ciborium::ser::into_writer(
        &(1u64, 1_000_000u64, 131_073u64, 1u64, vec![1u8]),
        &mut cbor,
    )
    .unwrap();
    let body = ur::bytewords::encode(&cbor, ur::bytewords::Style::Minimal);
    let frame = format!("ur:bytes/1-1000000/{body}");
    assert!(UrSession::new("bytes").receive(&frame).is_err());
}

#[test]
fn ffi_status_requires_actual_payload_and_checksums() {
    let frames = encode_ur_fountain_frames("crypto-psbt", &[1; 500], 100).unwrap();
    let incomplete = decode_json(
        &serde_json::json!({"expected_type":"crypto-psbt", "frames":[frames[0]]}).to_string(),
    );
    assert_eq!(incomplete["status"], "incomplete");
    assert_eq!(incomplete["resolved_fragments"], 1);
    assert_eq!(incomplete["total_fragments"], 5);
    let complete = decode_json(
        &serde_json::json!({"expected_type":"crypto-psbt", "frames":frames}).to_string(),
    );
    assert_eq!(complete["status"], "complete");
    assert_eq!(complete["payload_hex"], "01".repeat(500));
    let fake =
        decode_json(r#"{"expected_type":"crypto-psbt","frames":["ur:crypto-psbt/partpayload"]}"#);
    assert_eq!(fake["status"], "error");
    let oversized = decode_json(&serde_json::json!({"expected_type":"crypto-psbt", "frames":vec!["ur:crypto-psbt/ae"; 513]}).to_string());
    assert_eq!(oversized["status"], "error");
}
