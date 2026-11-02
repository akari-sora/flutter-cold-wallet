# QR 主 App 介面調整

從 `ea341512693a19b047e3ecd32df9b244a6daf6c2` 延續。使用者要求降低介面的模板感；本輪維持既有 QR 核心及 local/testnet 政策。

先以既有 Wallet／Vault 測試鎖定行為，再調整畫面，最後重跑流程、窄螢幕／大字級與實機檢查。

1. 共用紙白／石墨主題、深綠主操作、系統字型；取消霓虹文字、emoji 及反覆中英雙語。48dp 觸控區、16dp 內文，地址可換行且完整顯示。
2. Wallet 依帳戶、餘額／更新狀態、轉帳／收款、紀錄、帳戶／節點設定排序。空狀態用短說明及掃描／備份還原入口；費用進階設定分組。
3. Vault 初次設定依原狀態分步，鎖定頁突出解鎖及真實錯誤，已解鎖首頁突出掃描交易，配對／核對地址／備份分區。角色文字不得宣稱尚未驗證的實體隔離。
4. 交易審查以金額為首，完整收款、網路、簽署帳戶、合約、費用、BTC 輸出／找零、政策與錯誤皆在批准控制之前展開。公開回傳保留原請求識別與摘要。

保留既有 Key、身分驗證、取消／背景撤銷、不可變請求、持久化、原生驗章與明確廣播；不以樣式修改改變安全行為。公開 UR／協定資料可作次要資訊，但真實錯誤與必要審查不可隱藏。

沿用現有依賴，以 Flutter／Dart 官方 CLI、既有 widget 測試及無秘密畫面截圖驗證；不新增執行時字型下載、分析、廣告或網路 SDK。Vault 實機仍遵守 FLAG_SECURE，不拍攝助記詞。

實作已套用於兩個主 App。審查頁另補上同一份 native 解析物件提供的交易類型、nonce、Gas 上限、精確費率、原生幣數量、完整 calldata 及 access list；這些欄位皆展開於批准前。缺少、格式無效或與 intent／費用不一致時禁止簽署，並保留原取消及背景撤銷行為。

公開交易金額及各欄位的 `SelectableText` 使用 Flutter 既有 `semanticsLabel` 提供完整讀屏文字，長按選取仍保留。僅處理交易卡上的公開資料，不套用至助記詞、私鑰或密碼，也不更動 FLAG_SECURE。Widget 語意標籤／長按測試與 Android 實際可讀性各自列證據，不把 UI hierarchy 缺值直接歸因於截圖防護。

還原啟用後不沿用表單底部的捲動位置：金庫角色切換至已解鎖／已鎖定時回到頂端，主要掃描／解鎖控制可立即操作；同一角色內的表單重建保留位置。回歸測試使用真正 native 還原、320dp／200% 字級，並先重現原問題。

使用 `ui-ux-pro-max` 與 Flutter integration-testing 指引檢查資訊層級、48dp 操作區、320dp 寬度及 200% 字級。官方 Flutter／Dart CLI 使用固定 Flutter 3.41.3／Dart 3.11.1 的 `flutter analyze`、`flutter test`、`flutter build apk`；檢查過 `dart mcp-server --help`，沒有為此安裝或啟用新的伺服器。新專案用的廣告／分析初始化指引不套用於本離線金庫。

參考：[Flutter CLI](https://docs.flutter.dev/reference/flutter-cli)、[Flutter accessibility](https://docs.flutter.dev/ui/accessibility-and-internationalization/accessibility)、[Dart MCP server](https://dart.dev/tools/mcp-server)。主 App 的安全性及流程依實際測試判定，不以視覺評分當作簽章或相機驗收。
