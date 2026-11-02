use nfc_protocol::{
    encode_cbor_to_apdu_frames, sha256_hex, ApduFrameAssembler, FragmentAssembler, MessageKind,
    NfcEnvelope, SessionManager, INS_NFC_ENVELOPE_FRAME, MAX_HCE_APDU_DATA_LEN,
    MAX_HCE_CAPDU_WIRE_LEN, MIN_ISODEP_MAX_TRANSCEIVE_LEN, PROTOCOL_WIRE_VERSION,
};

fn envelope() -> NfcEnvelope {
    NfcEnvelope {
        wire_version: PROTOCOL_WIRE_VERSION,
        message_kind: MessageKind::SignRequest,
        session_id: "public-test-session".into(),
        request_id: "public-test-request".into(),
        chunk_index: 0,
        total_chunks: 1,
        payload_digest: sha256_hex(b"abc"),
        payload: b"abc".to_vec(),
    }
}

#[test]
fn reject_unsupported_version_even_when_all_fragments_agree() {
    let mut env = envelope();
    env.wire_version = 99;
    assert!(FragmentAssembler::new(&env).is_err());
    assert!(env.to_cbor().is_err());
}

#[test]
fn require_complete_cbor_input_consumption() {
    let mut bytes = envelope().to_cbor().expect("serialize public test envelope");
    bytes.push(0x00); // a second CBOR item must not be silently ignored
    assert!(NfcEnvelope::from_cbor(&bytes).is_err());
}

#[test]
fn valid_v1_envelope_still_assembles() {
    let assembler = FragmentAssembler::new(&envelope()).expect("valid v1");
    assert_eq!(assembler.finalize().expect("complete payload"), b"abc");
}

#[test]
fn reject_duplicate_cbor_map_keys() {
    // CBOR map with 2 entries, both key "wire_version" -> 1
    let mut dup_map = Vec::new();
    dup_map.push(0xa2); // map(2)
    for _ in 0..2 {
        dup_map.push(0x6c); // text(12)
        dup_map.extend_from_slice(b"wire_version");
        dup_map.push(0x01); // unsigned(1)
    }
    let err = NfcEnvelope::from_cbor(&dup_map).unwrap_err();
    assert!(
        err.to_string().contains("Duplicate CBOR map key"),
        "Unexpected error: {err}"
    );
}

#[test]
fn reject_unknown_cbor_field() {
    let valid_bytes = envelope().to_cbor().unwrap();
    // valid_bytes starts with 0xa8 (map of 8 items). Change to 0xa9 (map of 9 items) and append unknown key/value.
    assert_eq!(valid_bytes[0], 0xa8);
    let mut with_unknown = valid_bytes.clone();
    with_unknown[0] = 0xa9;
    with_unknown.push(0x67); // text(7)
    with_unknown.extend_from_slice(b"unknown");
    with_unknown.push(0x01); // unsigned(1)
    assert!(
        NfcEnvelope::from_cbor(&with_unknown).is_err(),
        "Unknown field must be rejected by deny_unknown_fields"
    );
}

#[test]
fn reject_indefinite_length_cbor() {
    // 0xbf = indefinite-length map, 0xff = break
    let bytes = vec![0xbf, 0xff];
    let err = NfcEnvelope::from_cbor(&bytes).unwrap_err();
    assert!(
        err.to_string().contains("Indefinite-length"),
        "Unexpected error: {err}"
    );
}

#[test]
fn reject_excessive_cbor_nesting_depth() {
    // 12 nested 1-element arrays `0x81` followed by `0x00`
    let mut deep = vec![0x81; 12];
    deep.push(0x00);
    let err = NfcEnvelope::from_cbor(&deep).unwrap_err();
    assert!(
        err.to_string().contains("nesting depth"),
        "Unexpected error: {err}"
    );
}

#[test]
fn reject_oversized_text_string_in_cbor() {
    let mut env = envelope();
    env.session_id = "s".repeat(300);
    assert!(env.to_cbor().is_err());

    // Raw CBOR text string of 300 bytes inside a 1-entry map
    let mut raw = vec![0xa1, 0x6a];
    raw.extend_from_slice(b"session_id");
    raw.push(0x79); // text string with 2-byte length
    raw.extend_from_slice(&(300u16.to_be_bytes()));
    raw.extend_from_slice(&vec![b'a'; 300]);
    let err = NfcEnvelope::from_cbor(&raw).unwrap_err();
    assert!(
        err.to_string().contains("exceeds 256-byte limit"),
        "Unexpected error: {err}"
    );
}

#[test]
fn reject_legacy_keccak_digest_in_v1_profile() {
    // Keccak-256("abc") = 4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45
    let mut env = envelope();
    env.payload_digest = "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45".into();
    let asm = FragmentAssembler::new(&env).unwrap();
    let err = asm.finalize().unwrap_err();
    assert!(
        err.to_string().contains("Payload digest mismatch"),
        "Legacy Keccak digest must be rejected by v1 SHA-256 profile: {err}"
    );
}

#[test]
fn session_manager_ttl_eviction_and_error_cleanup_and_replay_rejection() {
    let mut mgr = SessionManager::new(2, 1024, 5000);
    let digest = sha256_hex(b"abcd");

    let s1_c0 = NfcEnvelope {
        wire_version: PROTOCOL_WIRE_VERSION,
        message_kind: MessageKind::SignRequest,
        session_id: "sess-1".into(),
        request_id: "req-1".into(),
        chunk_index: 0,
        total_chunks: 2,
        payload_digest: digest.clone(),
        payload: b"ab".to_vec(),
    };
    let s2_c0 = NfcEnvelope {
        session_id: "sess-2".into(),
        request_id: "req-2".into(),
        ..s1_c0.clone()
    };
    let s3_c0 = NfcEnvelope {
        session_id: "sess-3".into(),
        request_id: "req-3".into(),
        ..s1_c0.clone()
    };

    assert!(mgr.process_envelope(&s1_c0, 1000).unwrap().is_none());
    assert!(mgr.process_envelope(&s2_c0, 1000).unwrap().is_none());
    // Capacity is 2 at t=1000 -> sess-3 rejected
    assert!(mgr.process_envelope(&s3_c0, 1000).is_err());

    // Fatal chunk error on sess-2 evicts sess-2 immediately, freeing capacity
    let mut s2_bad = s2_c0.clone();
    s2_bad.chunk_index = 0;
    s2_bad.payload = b"ZZ".to_vec(); // conflicting duplicate chunk
    assert!(mgr.process_envelope(&s2_bad, 1500).is_err());
    assert!(!mgr.assemblers.contains_key("sess-2"));

    // Now sess-3 can enter at t=1600
    assert!(mgr.process_envelope(&s3_c0, 1600).unwrap().is_none());

    // Advance clock past TTL (t=7000 > 1600 + 5000) -> sess-1 and sess-3 evicted
    assert_eq!(mgr.evict_expired(7000), 2);
    assert_eq!(mgr.assemblers.len(), 0);

    // Complete a single-chunk message and verify replay of the same (session, request, kind) is rejected
    let single = envelope();
    let res = mgr.process_envelope(&single, 8000).unwrap();
    assert!(res.is_some());
    let replay_err = mgr.process_envelope(&single, 8001).unwrap_err();
    assert!(
        replay_err.to_string().contains("Replayed NFC message rejected"),
        "Unexpected error: {replay_err}"
    );
}

#[test]
fn apdu_tier2_framing_respects_128b_hce_and_max_transceive_limits() {
    let mut env = envelope();
    env.payload = vec![0x5a; 100];
    env.payload_digest = sha256_hex(&env.payload);
    let cbor = env.to_cbor().unwrap();
    // cbor is > 128 bytes because of envelope metadata + 100B payload
    assert!(cbor.len() > MAX_HCE_APDU_DATA_LEN);

    let frames = encode_cbor_to_apdu_frames(
        &cbor,
        INS_NFC_ENVELOPE_FRAME,
        MAX_HCE_APDU_DATA_LEN,
        MIN_ISODEP_MAX_TRANSCEIVE_LEN,
    )
    .unwrap();
    assert!(frames.len() >= 2);

    let mut frame_asm = ApduFrameAssembler::new();
    let mut decoded_env = None;
    for (idx, frame) in frames.iter().enumerate() {
        let lc = frame[4] as usize;
        assert!(lc <= MAX_HCE_APDU_DATA_LEN);
        assert_eq!(frame.len(), 6 + lc);
        assert!(frame.len() <= MAX_HCE_CAPDU_WIRE_LEN);
        assert!(frame.len() <= MIN_ISODEP_MAX_TRANSCEIVE_LEN);

        let res = frame_asm.accept_apdu(frame).unwrap();
        if idx < frames.len() - 1 {
            assert!(res.is_none());
        } else {
            decoded_env = res;
        }
    }
    assert_eq!(decoded_env.unwrap(), env);
}

#[test]
fn reject_empty_chunk_payload() {
    let mut env = envelope();
    env.payload = Vec::new();
    env.payload_digest = sha256_hex(&[]);
    assert!(env.validate_fields().is_err());
    assert!(env.to_cbor().is_err());
    assert!(FragmentAssembler::new(&env).is_err());
}

#[test]
fn identical_duplicate_chunk_does_not_extend_session_ttl() {
    let mut mgr = SessionManager::new(4, 4096, 5000);
    let digest = sha256_hex(b"abcd");
    let c0 = NfcEnvelope {
        wire_version: PROTOCOL_WIRE_VERSION,
        message_kind: MessageKind::SignRequest,
        session_id: "sess-dup-ttl".into(),
        request_id: "req-dup-ttl".into(),
        chunk_index: 0,
        total_chunks: 2,
        payload_digest: digest,
        payload: b"ab".to_vec(),
    };

    // Arrive at t=1000
    assert!(mgr.process_envelope(&c0, 1000).unwrap().is_none());
    assert_eq!(mgr.assemblers.get("sess-dup-ttl").unwrap().last_updated_ms, 1000);

    // Send identical duplicate chunk 0 at t=4500 -> must NOT advance last_updated_ms
    assert!(mgr.process_envelope(&c0, 4500).unwrap().is_none());
    assert_eq!(mgr.assemblers.get("sess-dup-ttl").unwrap().last_updated_ms, 1000);

    // At t=6100 (> 1000 + 5000), session must be evicted as expired even though duplicate arrived at 4500
    assert_eq!(mgr.evict_expired(6100), 1);
    assert!(!mgr.assemblers.contains_key("sess-dup-ttl"));

    // Attempting to replay or resume the expired session must be rejected
    let err = mgr.process_envelope(&c0, 6200).unwrap_err();
    assert!(err.to_string().contains("Replayed NFC message rejected"));
}

#[test]
fn bounded_completed_history_evicts_entries_without_allowing_replay() {
    let mut mgr = SessionManager::new(4, 8192, 5000).with_history_bounds(8, 1024, 10_000);
    let mut all_envelopes = Vec::new();

    for i in 0..40usize {
        let payload = format!("msg-{i:04}").into_bytes();
        let env = NfcEnvelope {
            wire_version: PROTOCOL_WIRE_VERSION,
            message_kind: MessageKind::SignRequest,
            session_id: format!("sess-flood-{i:04}"),
            request_id: format!("req-flood-{i:04}"),
            chunk_index: 0,
            total_chunks: 1,
            payload_digest: sha256_hex(&payload),
            payload,
        };
        let out = mgr.process_envelope(&env, 1000 + (i as u64) * 10).unwrap();
        assert!(out.is_some());
        assert!(mgr.completed_messages.len() <= 8);
        assert!(mgr.completed_history_bytes <= 1024);
        all_envelopes.push(env);
    }

    // Oldest entries were evicted from `completed_messages`, yet `evicted_completed_count` tracked them
    assert_eq!(mgr.completed_messages.len(), 8);
    assert_eq!(mgr.evicted_completed_count, 32);

    // Every single one of the 40 historical messages (both evicted and still in window) MUST be rejected on replay
    for (idx, old_env) in all_envelopes.iter().enumerate() {
        let err = mgr.process_envelope(old_env, 3000 + idx as u64).unwrap_err();
        assert!(
            err.to_string().contains("Replayed NFC message rejected"),
            "Expected replay rejection for message #{idx}, got: {err}"
        );
    }
}

#[test]
fn cancelled_session_cannot_be_replayed() {
    let mut mgr = SessionManager::new(4, 4096, 5000);
    let digest = sha256_hex(b"abcd");
    let c0 = NfcEnvelope {
        wire_version: PROTOCOL_WIRE_VERSION,
        message_kind: MessageKind::SignRequest,
        session_id: "sess-cancel-1".into(),
        request_id: "req-cancel-1".into(),
        chunk_index: 0,
        total_chunks: 2,
        payload_digest: digest,
        payload: b"ab".to_vec(),
    };
    assert!(mgr.process_envelope(&c0, 1000).unwrap().is_none());
    assert!(mgr.cancel_session("sess-cancel-1"));
    let err = mgr.process_envelope(&c0, 1100).unwrap_err();
    assert!(err.to_string().contains("Replayed NFC message rejected"));
}

