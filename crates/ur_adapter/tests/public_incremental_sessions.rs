//! Public transport data only: no keys, signing, devices, or RPC.
use serde_json::{json, Value};
use ur_adapter::{
    default_fragment_len, encode_ur_fountain_frames, ffi_decode::decode_json, MAX_ALLOWED_PAYLOAD,
};

fn command(value: Value) -> Value {
    decode_json(&value.to_string())
}

#[test]
fn public_incremental_sessions_are_bounded_isolated_and_recoverable() {
    let mut ids = Vec::new();
    for _ in 0..16 {
        let result = command(json!({"op":"start","expected_type":"bytes"}));
        assert_eq!(result["status"], "started", "{result}");
        let id = result["session_id"].as_u64().unwrap();
        assert!(id > 0);
        assert!(ids.last().is_none_or(|previous| id > *previous));
        ids.push(id);
    }
    let full = command(json!({"op":"start","expected_type":"bytes"}));
    assert_eq!(full["error_code"], "ERR_UR_SESSION_LIMIT");
    let id = ids.pop().unwrap();
    for _ in 0..2 {
        assert_eq!(
            command(json!({"op":"close","session_id":id}))["status"],
            "closed"
        );
    }
    let replacement = command(json!({"op":"start","expected_type":"bytes"}));
    let replacement_id = replacement["session_id"].as_u64().unwrap();
    assert!(replacement_id > id);
    ids.push(replacement_id);

    let public_payload = vec![0x42; MAX_ALLOWED_PAYLOAD];
    let frames = encode_ur_fountain_frames(
        "bytes",
        &public_payload,
        default_fragment_len(&public_payload).unwrap(),
    )
    .unwrap();
    assert_eq!(frames.len(), 512);
    let first = command(json!({"op":"receive","session_id":replacement_id,"frame":frames[0]}));
    assert_eq!(first["status"], "incomplete");
    let wrong_type = encode_ur_fountain_frames("crypto-psbt", &[0x55; 240], 120).unwrap();
    let rejected =
        command(json!({"op":"receive","session_id":replacement_id,"frame":wrong_type[0]}));
    assert_eq!(rejected["error_code"], "ERR_UR_FRAME");
    let duplicate = command(json!({"op":"receive","session_id":replacement_id,"frame":frames[0]}));
    assert_eq!(duplicate["resolved_fragments"], first["resolved_fragments"]);
    let mut result = duplicate;
    for frame in frames.iter().skip(1) {
        result = command(json!({"op":"receive","session_id":replacement_id,"frame":frame}));
        if result["status"] == "complete" {
            break;
        }
        assert_eq!(result["status"], "incomplete", "{result}");
    }
    assert_eq!(result["status"], "complete");
    assert_eq!(result["payload_hex"], hex::encode(&public_payload));
    let released = command(json!({"op":"start","expected_type":"bytes"}));
    assert!(released["session_id"].as_u64().unwrap() > replacement_id);
    assert_eq!(
        command(json!({"op":"close","session_id":released["session_id"]}))["status"],
        "closed"
    );
    assert_eq!(
        command(json!({"op":"receive","session_id":replacement_id,"frame":frames[0]}))
            ["error_code"],
        "ERR_UR_SESSION_NOT_FOUND"
    );
    // Batch callers keep their original JSON shape and decoding behavior.
    let batch = command(json!({"expected_type":"bytes","frames":frames}));
    assert_eq!(batch["payload_hex"], hex::encode(public_payload));
    for id in ids {
        assert_eq!(
            command(json!({"op":"close","session_id":id}))["status"],
            "closed"
        );
    }
}
