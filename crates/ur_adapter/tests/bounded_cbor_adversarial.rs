use ur_adapter::bounded_cbor::{BoundedCborParser, BoundedCborValue, MAX_ALLOWED_PAYLOAD};
use ur_adapter::error::CborError;

#[test]
fn test_ur_05_depth_16_allowed_and_17_rejected() {
    // Build nested array of depth 16: [ [ [ ... [ 42 ] ... ] ] ]
    // Each array header is 0x81 (array of 1 item)
    let mut payload = vec![0x81; 16];
    payload.push(42); // Unsigned integer 42

    let val = BoundedCborParser::parse(&payload).expect("Depth 16 must succeed");
    assert!(matches!(val, BoundedCborValue::Array(_)));

    // Now depth 17: 17 array headers
    let mut payload_17 = vec![0x81; 17];
    payload_17.push(42);

    let err = BoundedCborParser::parse(&payload_17).unwrap_err();
    assert_eq!(err, CborError::DepthExceeded(17));
}

#[test]
fn test_ur_05_payload_128k_allowed_and_oversized_rejected() {
    // 128 KiB = 131,072 bytes. A byte string of length (131,072 - 5)
    // Major type 2 with 32-bit length header (0x5a followed by 4 bytes)
    let len = MAX_ALLOWED_PAYLOAD - 5;
    let mut payload = Vec::with_capacity(MAX_ALLOWED_PAYLOAD);
    payload.push(0x5a); // byte string, 4-byte length
    payload.extend_from_slice(&(len as u32).to_be_bytes());
    payload.resize(MAX_ALLOWED_PAYLOAD, 0xaa);

    assert_eq!(payload.len(), MAX_ALLOWED_PAYLOAD);
    let val = BoundedCborParser::parse(&payload).expect("Payload 128 KiB exactly must succeed");
    assert!(matches!(val, BoundedCborValue::Bytes(_)));

    // Oversized: 131,073 bytes
    payload.push(0xbb);
    let err = BoundedCborParser::parse(&payload).unwrap_err();
    assert_eq!(err, CborError::PayloadTooLarge(MAX_ALLOWED_PAYLOAD + 1));
}

#[test]
fn test_ur_04_duplicate_map_key_rejected() {
    // Map with 2 entries: key 1 => "A", key 1 => "B"
    // Header: 0xa2 (map of 2 pairs)
    // Pair 1: 0x01 (unsigned 1), 0x61, 0x41 ("A")
    // Pair 2: 0x01 (duplicate key 1!), 0x61, 0x42 ("B")
    let payload = vec![0xa2, 0x01, 0x61, 0x41, 0x01, 0x61, 0x42];
    let err = BoundedCborParser::parse(&payload).unwrap_err();
    assert!(matches!(err, CborError::DuplicateKey(_)), "Must reject duplicate key: {:?}", err);
}

#[test]
fn test_ur_04_trailing_garbage_rejected() {
    // Valid unsigned integer 42 (0x18, 0x2a), followed by trailing byte 0xff
    let payload = vec![0x18, 0x2a, 0xff];
    let err = BoundedCborParser::parse(&payload).unwrap_err();
    assert_eq!(err, CborError::TrailingBytes(1));
}

#[test]
fn test_ur_04_indefinite_length_rejected() {
    // Indefinite length byte string: 0x5f (major 2, additional info 31)
    let payload = vec![0x5f, 0x41, 0x61, 0xff];
    let err = BoundedCborParser::parse(&payload).unwrap_err();
    assert_eq!(err, CborError::IndefiniteLengthRejected);
}
