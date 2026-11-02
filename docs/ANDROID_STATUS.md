# Android 優先：整合狀態與後續驗收

更新：2026-10-22。持有人指定 Android 優先；iOS 工作保留在後續排程。
本文件區分程式整合、本機驗證與候選發布，後續依下列順序驗收。

## 分支與證據

| 工作 | 整合入口與目標 | 已驗證範圍 |
| --- | --- | --- |
| 1.2.1 / r20 測試網候選 | [MR !1](https://gitlab.com/aa22396584/mobile_cold_wallet/-/merge_requests/1) → `public-121` | 產品來源 `70d56e8`；APK/AAB 雜湊、簽章、對齊與 AAB audit；Android ARM64 16 KB 安裝與冷啟動 readback |
| Phase 0 開發基礎 | [MR !2](https://gitlab.com/aa22396584/mobile_cold_wallet/-/merge_requests/2) → `phase-0` | 程式快照 `fc955d6`；Rust release/dev 168/178、Flutter 810、Python 252 通過（1 skipped），五個套件分析無問題；dev APK audit 與 ARM64 16 KB 安裝、啟動、網路標籤 readback |

r20 的詳細候選證據見[發版說明](https://gitlab.com/aa22396584/mobile_cold_wallet/-/blob/3d61a1993c53c825a70309a79aba1b115defeef6/docs/releases/v1.2.1.md)。
Phase 0 的範圍與測試結果見[完成紀錄](https://gitlab.com/aa22396584/mobile_cold_wallet/-/blob/fc955d6ac8bdef81546384122f9a91022c2880fa/docs/PHASE0_COMPLETION.md)
及[驗證收據](https://gitlab.com/aa22396584/mobile_cold_wallet/-/blob/fc955d6ac8bdef81546384122f9a91022c2880fa/docs/evidence/phase0-verification.json)。
兩個 MR 的實際合併狀態以連結中的 GitLab readback 為準。

Phase 0 不在 r20 APK/AAB 內：它的 release 網路表只有 Sepolia、沒有 Bitcoin row；
dev 表才加入 Anvil、Hardhat 與 Regtest。Phase 0 APK 使用本機 debug 憑證，僅供內部測試。
Phase 0 保留較早的產品基線，不能將 r20 的相機權限與生命週期修正／驗收結果套用到它。
[ADR-005](ADR/ADR-005-mainnet-networks.md) 已接受；主網、Signet/Testnet4 與其餘階段仍按 ADR 分期處理。

目前倉庫沒有 `.gitlab-ci.yml`，這兩個 MR 沒有關聯 pipeline；以上是本機驗證，並非 CI 通過紀錄。
Whole-workspace Rust 格式檢查仍有已證實的既有基線失敗，見 Phase 0 完成紀錄。

## 下一步順序

1. **Android 測試網候選**：先使用已核對的 r20 產物，補上本輪尚未重跑的相機權限、雙向 QR、簽署／廣播與流量走查。保留 r19 與 r20 各自的證據，不互相代替。
2. **Android 封閉測試與發布條件**：準備商店素材、隱私權政策公開網址與表單，核對 Play App integrity 憑證及跨管道更新，依既定流程安排封閉測試；相機、真實生物識別與機型相容性需取得實體裝置／測試者收據。上傳、送審與公開發布沿用既有確認流程。
3. **Android Phase 0 後續**：先處理較早基線與 r20 的相機／生命週期差異，再擴充同一候選的還原、多帳戶、鎖定及換 key 後請求撤銷等完整流程驗收。每次產品程式改動後重建、重新核對雜湊及收集裝置證據；目前的啟動與標籤 readback 不涵蓋這些流程。
4. **iOS 與其餘 ADR 階段**：保留已記錄的缺口，排在 Android 工作之後。Phase 0 的合併不啟用主網，也不替代後續付款嘗試、遷移或正式簽署驗收。

實體裝置、iOS、Play 身分與正式發布狀態在取得對應收據前維持開放。
來源倉庫公開與產物發布也各自需要 readback；本次文件更新與 MR 合併不變更倉庫可見性。
