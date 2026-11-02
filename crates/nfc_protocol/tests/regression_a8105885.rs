use nfc_protocol::{sha256_hex, FragmentAssembler, MessageKind, NfcEnvelope, PROTOCOL_WIRE_VERSION};

fn fragments() -> (NfcEnvelope, NfcEnvelope) {
    let digest = sha256_hex(b"abcd");
    let a = NfcEnvelope {
        wire_version: PROTOCOL_WIRE_VERSION,
        message_kind: MessageKind::SignRequest,
        session_id: "public-review-session".into(),
        request_id: "public-review-request-A".into(),
        chunk_index: 0,
        total_chunks: 2,
        payload_digest: digest,
        payload: b"ab".to_vec(),
    };
    let mut b = a.clone();
    b.chunk_index = 1;
    b.payload = b"cd".to_vec();
    (a, b)
}

#[test]
fn sha256_abc_is_actual_sha256() {
    assert_eq!(
        sha256_hex(b"abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
}

#[test]
fn changing_request_id_is_rejected() {
    let (a, mut b) = fragments();
    b.request_id = "public-review-request-B".into();
    let mut assembler = FragmentAssembler::new(&a).unwrap();
    assert!(
        assembler.add_chunk(&b).is_err(),
        "Must bind all chunks to one request"
    );
}

#[test]
fn changing_message_kind_is_rejected() {
    let (a, mut b) = fragments();
    b.message_kind = MessageKind::SignResponse;
    let mut assembler = FragmentAssembler::new(&a).unwrap();
    assert!(
        assembler.add_chunk(&b).is_err(),
        "Must bind message kind across chunks"
    );
}

#[test]
fn changing_wire_version_is_rejected() {
    let (a, mut b) = fragments();
    b.wire_version = 999;
    let mut assembler = FragmentAssembler::new(&a).unwrap();
    assert!(
        assembler.add_chunk(&b).is_err(),
        "Must reject changed/unknown version"
    );
}

#[test]
fn changing_declared_digest_is_rejected() {
    let (a, mut b) = fragments();
    b.payload_digest = "00".repeat(32);
    let mut assembler = FragmentAssembler::new(&a).unwrap();
    assert!(
        assembler.add_chunk(&b).is_err(),
        "Must reject inconsistent commitment"
    );
}

#[test]
fn conflicting_duplicate_is_rejected() {
    let (a, _) = fragments();
    let mut assembler = FragmentAssembler::new(&a).unwrap();
    let mut duplicate = a.clone();
    duplicate.payload = b"ZZ".to_vec();
    assert!(
        assembler.add_chunk(&duplicate).is_err(),
        "Conflicting duplicate must not be silently discarded"
    );
}

#[test]
fn same_message_positive_control() {
    let (a, b) = fragments();
    let mut assembler = FragmentAssembler::new(&a).unwrap();
    assert!(assembler.add_chunk(&b).unwrap());
    assert_eq!(assembler.finalize().unwrap(), b"abcd");
}
