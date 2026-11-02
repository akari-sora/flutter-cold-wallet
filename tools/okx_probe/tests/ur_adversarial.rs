use ur::Decoder;

#[test]
fn test_rust_ur_decoder_valid_single_roundtrip() {
    let sample = "ur:crypto-multi-accounts/onadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddyoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewkbkjkhsiaiajlkpjtjydmjzihieioihjphejzinkoihaxjtgrihkkjkjyjljtihcxeocxgdjpjlaaksdeeyeteeemeciaetieetdyiyeniadyenidhsiyidiheeenhsemieehemecdyiyeoiyiaiyeyeceneciyemahihehdmehdmdyehrnwdjk";
    let (ur_type, message) = ur::decode(sample).expect("decode valid single frame");
    assert_eq!(format!("{:?}", ur_type), "SinglePart");
    assert_eq!(message.len(), 263);

    // Verify Decoder::receive fails-closed on single frame with NotMultiPart
    let mut multipart_decoder = Decoder::default();
    let err = multipart_decoder.receive(sample).unwrap_err();
    assert_eq!(format!("{:?}", err), "NotMultiPart");
}

#[test]
fn test_rust_ur_decoder_rejects_corrupted_crc() {
    let mut decoder = Decoder::default();
    // Tamper with last 2 characters
    let corrupted = "ur:crypto-multi-accounts/onadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddyoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewkbkjkhsiaiajlkpjtjydmjzihieioihjphejzinkoihaxjtgrihkkjkjyjljtihcxeocxgdjpjlaaksdeeyeteeemeciaetieetdyiyeniadyenidhsiyidiheeenhsemieehemecdyiyeoiyiaiyeyeceneciyemahihehdmehdmdyehrnwdzz";
    let res = decoder.receive(corrupted);
    assert!(res.is_err(), "Must reject corrupted CRC");
}

#[test]
fn test_rust_ur_decoder_rejects_truncated_or_empty() {
    let mut decoder = Decoder::default();
    assert!(decoder.receive("").is_err());
    assert!(decoder.receive("ur:").is_err());
    assert!(decoder.receive("ur:crypto-multi-accounts").is_err());
    assert!(decoder.receive("ur:crypto-multi-accounts/").is_err());
    assert!(decoder.receive("ur:crypto-multi-accounts/oxa").is_err());
    assert!(decoder.receive("ur:crypto-multi-accounts/zzzz").is_err());
}

#[test]
fn test_rust_ur_decoder_fountain_reassembly_and_corrupted_frame() {
    let mut decoder = Decoder::default();
    let frame1 = "ur:crypto-multi-accounts/1-3/lpadaxcfadatcyehrnwdjkhdhdonadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddykewehyax";
    let frame2 = "ur:crypto-multi-accounts/2-3/lpaoaxcfadatcyehrnwdjkhdhdoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewklphebsfn";
    let frame3 = "ur:crypto-multi-accounts/3-3/lpaxaxcfadatcyehrnwdjkhdhdbkjkhsiaiajlkpjtjydmjzihieioihjphejzinkoihaxjtgrihkkjkjyjljtihcxeocxgdjpjlaaksdeeyeteeemeciaetieetdyiyeniadyenidhsiyidiheeenhsemieehemecdyiyeoiyiaiyeyeceneciyemahihehdmehdmdyaenycpuoya";

    // Feed corrupted frame (tampered CRC)
    let corrupted_frame1 = "ur:crypto-multi-accounts/1-3/lpadaxcfadatcyehrnwdjkhdhdonadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddykewehzzz";
    assert!(decoder.receive(corrupted_frame1).is_err(), "Must reject corrupted fountain frame");

    // Feed valid frames out of order: frame3, frame1, frame2
    decoder.receive(frame3).expect("receive frame 3");
    assert!(!decoder.complete());
    decoder.receive(frame1).expect("receive frame 1");
    assert!(!decoder.complete());
    decoder.receive(frame2).expect("receive frame 2");
    assert!(decoder.complete());

    let message = decoder.message().expect("get message").expect("message exists");
    assert_eq!(message.len(), 263);
}

#[test]
fn test_rust_ur_decoder_fountain_seq_greater_than_seqlen() {
    let mut decoder = Decoder::default();
    // Luby transform parts where seq_num > seq_len (e.g. part 4, 5, 6, 7.. of 3 parts)
    let frame4 = "ur:crypto-multi-accounts/4-3/lpaaaxcfadatcyehrnwdjkhdhdpejpkgbeolrelbjzynyljngertiefsguhlhptasnctlyvamkwmpmwldsdkeopspssfckvwrowefdvdrewzvdwsbkptreetmtoyeefmcmrkprflwlcwdkvobtemtptifdbeprskeobeatdtrywmnyolasrsrootnspsdtcfememylehdybeiavwvl";
    let frame5 = "ur:crypto-multi-accounts/5-3/lpahaxcfadatcyehrnwdjkhdhdoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewkcmwnhdpl";
    let frame6 = "ur:crypto-multi-accounts/6-3/lpamaxcfadatcyehrnwdjkhdhdaaaensjewldlbgfmkttawkdatyidfrfwjnfwuetkghwnztprvtpfzocxdllrspothhfswewmlakgdldsrdhlguwybgaonynbtdhkmepsdirfssfpyabactyksrehimfwvsgowzwkrhiosrtnrohlmdrpmeoydyqdmdrhdewpamdpadssmernkila";

    // Feeding part 4, 5, 6 should be accepted
    decoder.receive(frame4).expect("receive frame 4 (seq > seq_len)");
    decoder.receive(frame5).expect("receive frame 5 (seq > seq_len)");
    decoder.receive(frame6).expect("receive frame 6 (seq > seq_len)");
}
