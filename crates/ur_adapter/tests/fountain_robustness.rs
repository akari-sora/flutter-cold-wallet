use ur_adapter::error::UrError;
use ur_adapter::fountain::UrSession;

#[test]
fn test_ur_01_ur_02_single_and_fountain_reassembly() {
    // 1. Single part test
    let sample = "ur:crypto-multi-accounts/onadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddyoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewkbkjkhsiaiajlkpjtjydmjzihieioihjphejzinkoihaxjtgrihkkjkjyjljtihcxeocxgdjpjlaaksdeeyeteeemeciaetieetdyiyeniadyenidhsiyidiheeenhsemieehemecdyiyeoiyiaiyeyeceneciyemahihehdmehdmdyehrnwdjk";
    let mut session = UrSession::new("crypto-multi-accounts");
    let msg = session.receive(sample).unwrap().expect("Single frame complete");
    assert_eq!(msg.len(), 263);
    assert!(session.is_complete());

    // 2. Out-of-order fountain reassembly (3, 1, 2)
    let frame1 = "ur:crypto-multi-accounts/1-3/lpadaxcfadatcyehrnwdjkhdhdonadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddykewehyax";
    let frame2 = "ur:crypto-multi-accounts/2-3/lpaoaxcfadatcyehrnwdjkhdhdoyadlncsdwykcsfnykaeykbkjohsiaiajlkpjtjydmjkjyhsjtiehsjpietaaddlotaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlamtaaddyoyadlecsdwykcsfnykaeykaewkaewklphebsfn";
    let frame3 = "ur:crypto-multi-accounts/3-3/lpaxaxcfadatcyehrnwdjkhdhdbkjkhsiaiajlkpjtjydmjzihieioihjphejzinkoihaxjtgrihkkjkjyjljtihcxeocxgdjpjlaaksdeeyeteeemeciaetieetdyiyeniadyenidhsiyidiheeenhsemieehemecdyiyeoiyiaiyeyeceneciyemahihehdmehdmdyaenycpuoya";

    let mut fountain_session = UrSession::new("crypto-multi-accounts");
    assert!(fountain_session.receive(frame3).unwrap().is_none());
    assert!(!fountain_session.is_complete());
    // Duplicate frame tolerated
    assert!(fountain_session.receive(frame3).unwrap().is_none());
    assert!(fountain_session.receive(frame1).unwrap().is_none());
    let reassembled = fountain_session.receive(frame2).unwrap().expect("Reassembly complete");
    assert_eq!(reassembled.len(), 263);
    assert_eq!(reassembled, msg);
}

#[test]
fn test_ur_03_mismatched_type_splicing_rejected() {
    let mut session = UrSession::new("eth-sign-request");
    let multi_accounts_frame = "ur:crypto-multi-accounts/1-3/lpadaxcfadatcyehrnwdjkhdhdonadcyjksktnbkaolftaaddloxaxhdclaoempfrkknlflotemntynygmgrhlsolkzmfmresglfgsnentrturuyfsnstbaewznlaahdcxtplfjsluknfwlaisaxwypalbjylswzamcxhscyuyloztmwfnldlgskpyptgsdecfamtaaddykewehyax";
    let err = session.receive(multi_accounts_frame).unwrap_err();
    assert!(matches!(err, UrError::TypeMismatch { .. }), "Must reject cross-type stream splicing");
}
