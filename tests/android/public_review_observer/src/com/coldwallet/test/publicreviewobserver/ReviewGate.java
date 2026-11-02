package com.coldwallet.test.publicreviewobserver;

import java.util.Locale;

/** Pure validation shared with host tests; never emits text from a rejected surface. */
final class ReviewGate {
    static final String VAULT = "com.coldwallet.vault";
    // Exact static labels from TransactionReviewCard; no guessed aliases or transaction values.
    private static final String[] PUBLIC_FIELD_LABELS = {
        "轉帳金額", "外部收款總額", "收款地址", "簽署帳戶", "代幣合約", "簽署路徑",
        "交易類型", "Nonce（交易序號）", "Gas 上限", "Gas 單價", "每單位 Gas 最高費用",
        "每單位 Gas 優先費用", "交易目的地址", "原生幣金額", "呼叫資料", "存取清單",
        "最高手續費限制", "交易手續費", "請求識別碼", "簽署摘要"
    };
    private boolean title;
    private boolean publicField;
    private boolean approval;
    private boolean policy;
    private boolean secret;

    void inspect(String value, boolean visible) {
        if (value == null || value.isEmpty()) return;
        if (visible && value.equals("確認交易")) title = true;
        if (visible) {
            // Flutter can merge card labels into one multiline semantics node.
            // Match original complete lines only; never trim, substring-match, or fill values.
            for (String line : value.split("\\r\\n|\\n|\\r", -1)) {
                if (line.equals("核准並簽署")) approval = true;
                if (line.equals("等待確認") || line.equals("政策拒絕")) policy = true;
                for (String label : PUBLIC_FIELD_LABELS) {
                    if (line.equals(label)) publicField = true;
                }
            }
        }
        String lower = value.toLowerCase(Locale.ROOT);
        String[] forbidden = {"助記詞", "解鎖", "金庫密碼", "密碼", "備份", "還原", "建立金庫",
            "mnemonic", "passphrase", "password", "seed phrase", "recovery phrase"};
        for (String marker : forbidden) {
            if (lower.contains(marker)) secret = true;
        }
    }

    String rejection() {
        if (secret) return "SECRET_SURFACE";
        if (!title || !(publicField || (approval && policy))) return "NOT_CONFIRMED_PUBLIC_REVIEW";
        return null;
    }
}
