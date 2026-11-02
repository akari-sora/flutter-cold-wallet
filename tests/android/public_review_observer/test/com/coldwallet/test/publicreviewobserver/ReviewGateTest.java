package com.coldwallet.test.publicreviewobserver;

public final class ReviewGateTest {
    private static int checks;
    private static ReviewGate valid() {
        ReviewGate gate = new ReviewGate();
        gate.inspect("確認交易", true);
        gate.inspect("核准並簽署", true);
        gate.inspect("等待確認", true);
        return gate;
    }
    private static void check(boolean value, String name) {
        if (!value) throw new AssertionError(name);
        checks++;
    }
    private static ReviewGate frame(String anchor, boolean anchorVisible, boolean titleVisible) {
        ReviewGate gate = new ReviewGate();
        gate.inspect("確認交易", titleVisible);
        gate.inspect(anchor, anchorVisible);
        return gate;
    }
    public static void main(String[] args) {
        check(valid().rejection() == null, "public review accepted");
        check(new ReviewGate().rejection() != null, "blank rejected");
        ReviewGate missingTitle = new ReviewGate();
        missingTitle.inspect("確認交易", false);
        missingTitle.inspect("核准並簽署", true);
        missingTitle.inspect("等待確認", true);
        check(missingTitle.rejection() != null, "invisible review title rejected");
        ReviewGate missingApprove = new ReviewGate();
        missingApprove.inspect("確認交易", true);
        missingApprove.inspect("等待確認", true);
        check(missingApprove.rejection() != null, "missing approve rejected");
        ReviewGate missingPolicy = new ReviewGate();
        missingPolicy.inspect("確認交易", true);
        missingPolicy.inspect("核准並簽署", true);
        check(missingPolicy.rejection() != null, "missing policy rejected");
        String[] secrets = {"輸入助記詞", "解鎖金庫", "App 密碼", "Passphrase", "MNEMONIC", "還原金庫", "備份確認"};
        for (String secret : secrets) {
            ReviewGate gate = valid();
            gate.inspect(secret, false);
            check("SECRET_SURFACE".equals(gate.rejection()), "secret surface rejected");
        }
        ReviewGate publicValues = valid();
        publicValues.inspect("0x1111111111111111111111111111111111111111", true);
        publicValues.inspect("1000000021 wei / Gas", true);
        publicValues.inspect("空（0 筆）", true);
        check(publicValues.rejection() == null, "public values allowed");
        // Actual runtime viewport regression: the approval node is pruned above the bottom.
        check(frame("轉帳金額", true, true).rejection() == null, "top public frame without approval accepted");
        check(frame("Nonce（交易序號）", true, true).rejection() == null, "middle public frame without approval accepted");
        check(valid().rejection() == null, "bottom visible approval and policy accepted");
        check(frame("", true, true).rejection() != null, "title alone rejected");
        check(frame("等待確認", true, true).rejection() != null, "title and policy alone rejected");
        check(frame("Nonce（交易序號）", false, true).rejection() != null, "invisible anchor rejected");
        check(frame("Nonce（交易序號）", true, false).rejection() != null, "invisible title with anchor rejected");
        check(frame("無關內容", true, true).rejection() != null, "unrelated visible node rejected");
        check(frame("Gas上限", true, true).rejection() != null, "non-production alias rejected");
        ReviewGate hiddenBottom = new ReviewGate();
        hiddenBottom.inspect("確認交易", true);
        hiddenBottom.inspect("核准並簽署", false);
        hiddenBottom.inspect("等待確認", false);
        check(hiddenBottom.rejection() != null, "invisible bottom markers rejected");
        ReviewGate hiddenPolicy = new ReviewGate();
        hiddenPolicy.inspect("確認交易", true);
        hiddenPolicy.inspect("核准並簽署", true);
        hiddenPolicy.inspect("等待確認", false);
        check(hiddenPolicy.rejection() != null, "invisible policy with visible approval rejected");
        ReviewGate hiddenApproval = new ReviewGate();
        hiddenApproval.inspect("確認交易", true);
        hiddenApproval.inspect("核准並簽署", false);
        hiddenApproval.inspect("等待確認", true);
        check(hiddenApproval.rejection() != null, "invisible approval with visible policy rejected");
        ReviewGate rejectedBottom = new ReviewGate();
        rejectedBottom.inspect("確認交易", true);
        rejectedBottom.inspect("核准並簽署", true);
        rejectedBottom.inspect("政策拒絕", true);
        check(rejectedBottom.rejection() == null, "bottom policy marker is observation only, not signing authority");
        ReviewGate secretTop = frame("轉帳金額", true, true);
        secretTop.inspect("助記詞", false);
        check("SECRET_SURFACE".equals(secretTop.rejection()), "secret still rejects valid public anchor");
        String[] labels = {"轉帳金額", "外部收款總額", "收款地址", "簽署帳戶", "代幣合約", "簽署路徑",
            "交易類型", "Nonce（交易序號）", "Gas 上限", "Gas 單價", "每單位 Gas 最高費用",
            "每單位 Gas 優先費用", "交易目的地址", "原生幣金額", "呼叫資料", "存取清單",
            "最高手續費限制", "交易手續費", "請求識別碼", "簽署摘要"};
        for (String label : labels) {
            check(frame(label, true, true).rejection() == null, "production visible field accepted: " + label);
        }
        check(frame("轉帳金額\n0.000001 ETH\n收款地址\n0x1111111111111111111111111111111111111111\n網路\nEthereum Sepolia Testnet (11155111)\n等待確認", true, true).rejection() == null,
            "actual combined top public semantics accepted by exact label lines");
        check(frame("交易類型\r\nEIP-1559\r\nNonce（交易序號）\r\n362\r\nGas 上限\r\n12000", true, true).rejection() == null,
            "combined middle CRLF public semantics accepted");
        check(frame("等待確認\n核准並簽署", true, true).rejection() == null,
            "combined bottom visible policy and approval accepted");
        check(frame("前綴轉帳金額\n收款地址後綴", true, true).rejection() != null,
            "merged partial labels rejected");
        check(frame(" 轉帳金額\nGas 上限 ", true, true).rejection() != null,
            "merged labels are not trimmed or approximated");
        check(frame("等待確認\n核准並簽署後綴", true, true).rejection() != null,
            "merged partial approval rejected");
        check(frame("等待確認前綴\n核准並簽署", true, true).rejection() != null,
            "merged partial policy rejected");
        check(frame("轉帳金額\n0.000001 ETH", false, true).rejection() != null,
            "merged invisible public anchor rejected");
        check("SECRET_SURFACE".equals(frame("轉帳金額\n助記詞\n等待確認\n核准並簽署", true, true).rejection()),
            "secret anywhere in merged semantics rejects");
        ReviewGate mergedTitle = new ReviewGate();
        mergedTitle.inspect("確認交易\n轉帳金額", true);
        check(mergedTitle.rejection() != null, "title must remain exact whole-node text");
        System.out.println("ReviewGateTest: " + checks + " checks passed");
    }
}
