//! Valid public data and size metadata only; no keys, signing, or RPC.
use std::collections::BTreeMap;
use public_core::bitcoin::{OutPoint, Psbt, PsbtInput, PsbtOutput, Transaction, TxIn, TxOut};
use ur_adapter::{default_fragment_len, decode_ur_frames, encode_ur_fountain_frames,
    BoundedCborParser, BoundedCborValue, CryptoKeyPath, CryptoPsbt, DataType,
    DecodedUrPayload, EthSignRequest, MAX_ALLOWED_PAYLOAD};
use ur_adapter::fountain::{MAX_UR_DISPLAY_CHARS, MAX_UR_FRAME_CHARS, MAX_UR_FRAMES, MAX_UR_SESSION_CHARS};

fn public_psbt() -> Psbt {
    Psbt {
        unsigned_tx: Transaction {
            version: 2, lock_time: 0,
            inputs: vec![TxIn {
                previous_output: OutPoint { txid: [0x11; 32], vout: 0 },
                script_sig: vec![], sequence: 0xfffffffd,
            }],
            outputs: vec![TxOut { value: 1_000, script_pubkey: vec![0, 20] }],
        },
        inputs: vec![PsbtInput::default()],
        outputs: vec![PsbtOutput::default()],
        unknown_global: BTreeMap::new(),
    }
}

fn pad_public_metadata(psbt: &mut Psbt, target: usize) {
    psbt.unknown_global.insert(vec![0x50], vec![0x55; target]);
    let excess = psbt.serialize().len() - target;
    let metadata = psbt.unknown_global.get_mut(&vec![0x50]).unwrap();
    metadata.truncate(metadata.len() - excess);
    assert_eq!(psbt.serialize().len(), target);
}

fn assert_bounded(frames: &[String]) {
    assert!(frames.len() <= MAX_UR_FRAMES);
    assert!(frames.iter().all(|frame| frame.len() <= MAX_UR_FRAME_CHARS));
    assert!(frames.iter().all(|frame| frame.len() <= MAX_UR_DISPLAY_CHARS));
    assert!(frames.iter().map(String::len).sum::<usize>() <= MAX_UR_SESSION_CHARS);
}

#[test]
fn maximum_valid_crypto_psbt_cbor_roundtrips_in_the_default_session() {
    let mut psbt = public_psbt();
    pad_public_metadata(&mut psbt, MAX_ALLOWED_PAYLOAD - 8);
    let bytes = psbt.serialize();
    assert_eq!(Psbt::deserialize(&bytes).unwrap(), psbt);
    let payload = CryptoPsbt::new(bytes.clone());
    let cbor = payload.to_cbor_bytes();
    let raw_single = payload.to_ur_single();
    assert!(raw_single.starts_with("ur:crypto-psbt/"));
    assert!(raw_single.len() > MAX_UR_DISPLAY_CHARS);
    assert!(ur_adapter::displayable_single_ur(CryptoPsbt::UR_TYPE, &cbor).is_none());
    assert_eq!(cbor.len(), MAX_ALLOWED_PAYLOAD);
    BoundedCborParser::parse(&cbor).unwrap();
    let frames = payload.to_ur_fountain(default_fragment_len(&cbor).unwrap()).unwrap();
    assert_bounded(&frames);
    assert_eq!(frames.len(), MAX_UR_FRAMES);
    assert!(frames.iter().all(|frame| frame.starts_with("ur:crypto-psbt/")));
    assert_eq!(decode_ur_frames("crypto-psbt", &frames).unwrap(), cbor);
    assert_eq!(DecodedUrPayload::decode_frames(&frames).unwrap(), DecodedUrPayload::CryptoPsbt(payload));
}

#[test]
fn explicit_fragment_cap_preserves_valid_sessions_above_256_source_parts() {
    let mut cbor = Vec::new();
    ciborium::into_writer(&ciborium::value::Value::Bytes(vec![0x44; 30_720]), &mut cbor).unwrap();
    let frames = encode_ur_fountain_frames("bytes", &cbor, 120).unwrap();
    assert_eq!(frames.len(), MAX_UR_FRAMES);
    assert_bounded(&frames);
    assert_eq!(decode_ur_frames("bytes", &frames).unwrap(), cbor);
}

#[test]
fn p2wpkh_response_preflight_accepts_the_conservative_capacity_boundary() {
    let mut psbt = public_psbt();
    // One input reserves 109 bytes for a partial-signature map entry plus
    // eight bytes for the largest supported crypto-psbt CBOR envelope.
    pad_public_metadata(&mut psbt, MAX_ALLOWED_PAYLOAD - 109 - 8);
    CryptoPsbt::ensure_p2wpkh_response_capacity(&psbt).unwrap();
    assert_eq!(psbt.serialize().len() + 109 + 8, MAX_ALLOWED_PAYLOAD);
    assert!(psbt.inputs.iter().all(|input| input.partial_sigs.is_empty()));
}

#[test]
fn valid_cbor_integer_ranges_and_public_keypath_metadata_are_preserved() {
    let mut cbor = Vec::new();
    ciborium::into_writer(&ciborium::value::Value::Array(vec![
        ciborium::value::Value::Integer(u64::MAX.into()),
        ciborium::value::Value::Integer(ciborium::value::Integer::try_from(-1i128 - u64::MAX as i128).unwrap()),
        ciborium::value::Value::Bool(true),
        ciborium::value::Value::Null,
    ]), &mut cbor).unwrap();
    assert_eq!(BoundedCborParser::parse(&cbor).unwrap(), BoundedCborValue::Array(vec![
        BoundedCborValue::Unsigned(u64::MAX),
        BoundedCborValue::Negative(-1i128 - u64::MAX as i128),
        BoundedCborValue::Bool(true), BoundedCborValue::Null,
    ]));
    let request = EthSignRequest {
        request_id: Some([0x22; 16]), sign_data: vec![2], data_type: DataType::TypedTransaction,
        chain_id: Some(11_155_111),
        derivation_path: CryptoKeyPath::from_string_path("m/44'/60'/0'/0/1", Some(u32::MAX.to_be_bytes())).unwrap(),
        address: Some([0x11; 20]), origin: Some("public capacity verification".into()),
    };
    assert_eq!(EthSignRequest::from_cbor_bytes(&request.to_cbor_bytes()).unwrap(), request);
}
