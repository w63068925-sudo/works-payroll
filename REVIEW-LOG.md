# 審查紀錄

## 2026-11-21 第一次完整安全審查

- Codex：Zook 帳號 Waifdance，gpt-6.2-astra，思考強度 high，約 156,862 token。範圍：整個 repo（commit c391a79）。
- 修正後的例行複審已於同日補跑，見下方「第二輪」。
- 回歸測試：`supabase/tests/regression.sql`，12 組全部通過。

### 已修正（commit f43e3e0）
| 來源 | 問題 | 修法 |
|---|---|---|
| Codex＋Claude | 登入失敗回傳剩餘次數，可判斷帳號是否存在 | 失敗一律回同樣訊息 |
| Codex | 同時登入可繞過錯 5 次鎖定；改密碼競態 | 登入、改密碼鎖住帳號列 |
| Codex | 設定碼可被同時用兩次 | 原子消耗 |
| Codex | 同時移除最後兩位管理員；重設密碼可用於自己 | 鎖表；禁止重設自己 |
| Codex＋Claude | LINE 綁定碼可暴力嘗試、非密碼學亂數、可重複兌換 | 密碼學亂數、原子消耗、個人與全域限流、解除綁定撤銷碼 |
| Codex | cron token 空字串可能通過 | 要求 32 字元以上 |
| Codex | 未排班者可掃碼打卡並被計薪；活動結束隔天仍可簽到 | 只限當天錄取者；隔天只能簽退 |
| Codex | 錄取名額、時段重疊在同時操作時可超額；改班次不重查重疊 | 鎖班次與人員列；改班次檢查重疊 |
| Codex | 無班次的活動報名可夾帶別場班次 | 一律驗證 |
| Codex | 契約確認的是伺服器當下重產的文字；條款變動不重簽；舊簽文被覆蓋 | 雜湊比對、契約歷史、活動或雇主條款變動自動失效並重新通知 |
| Codex | 契約逐班時薪，計薪卻整場同一時薪 | 每天用當天錄取班次的時薪 |
| Codex | 有錯誤（如低於最低工資）仍可發布 | 有「須處理」問題不能發布 |
| Codex | 通知同時發送可能重複；5xx 永久失敗 | sending 領取、最多重試 3 次 |
| Codex | LINE 錯綁會外洩實發金額 | 通知不含金額 |
| Codex | 證件調閱稽核失敗仍給連結 | 先寫紀錄再給連結 |
| Codex | 跨夜班列印顯示負工時；工讀生明細回傳內部備註 | 伺服器算淨分鐘；不回傳備註 |
| Codex | 匯款 CSV 用活動發薪日而非單張發薪日 | 改用單張；排除無帳號或帳戶待核者 |
| Codex | 管理頁第三方 QR 腳本無完整性檢查 | 加 SRI |
| Claude | 匯款 CSV、每日匯出試算表可被公式注入 | 加前綴防護 |

### 未修，需要決策或較大改版
| 問題 | 原因 |
|---|---|
| 預設密碼（生日）登入即可改匯款帳戶 | 使用者指定的登入方式；目前以「帳戶待核」排除於匯款清單作緩解 |
| 有報名連結即可冒用未建檔者身分註冊 | 需要人工核身流程；目前以「新登錄人員」提醒核對 |
| 同日跨活動、每週 40 小時的加班合併計算 | 計薪引擎需改為以雇主、勞工、日、週彙總 |
| 休息日／例假以連續天數推估；國定假日未出勤的照給工資 | 需要約定班表與例假日設定 |
| 同日多段出勤；滿 4 小時自動扣休息 | 需改出勤資料結構 |
| 勞保依天數乘日額，未依加退保區間 | 需加退保紀錄 |
| 已發布薪資單不可變版本 | 需版本表與更正流程 |
| 每日匯出使用 secret key | 建議改為專用唯讀匯出函式與權杖 |
| 上傳檔案位元組驗證、孤兒檔、併發替換；Webhook 事件去重；通知全文保存；匯出快照 | 風險較低，排後續 |

### Claude 獨立發現、Codex 未提
- `legacy_rows`、`legacy_norm` 仍保存匯入時的原始個資（身分證、帳號、地址）副本，資料已在正式表中。2026-11-21 經使用者確認後刪除（各 185 列）。

## 2026-11-21 第二輪：修正後例行複審

- Codex：預設帳號，gpt-6.2-sol，思考強度 medium，約 146,243 token。範圍：`git diff c391a79..63baa13`。
- 回歸測試改寫為 13 組，全部通過。單一交易測不到雙連線併發，併發部分靠統一鎖定順序（報名 → 班次 → 人員）與 advisory lock。

### 已修正
| 問題 | 修法 |
|---|---|
| 本人在活動上的「須處理」問題（如未成年）不擋發布 | 發布與核對共用判定：薪資單、本人在該活動或全域的錯誤都擋 |
| 匯款 CSV 用畫面上的舊資料；帳戶核對後仍用薪資單快照 | 下載時呼叫 `admin_payout` 取當下資料；缺發薪日、帳號格式錯、帳戶待核、戶名不符一律排除並列出原因 |
| 改班與錄取的競態（降名額、同人不同班同時移動） | 改班先鎖報名、班次、人員後才檢查；錄取同順序並依固定順序處理批次 |
| 條款更新與簽署的競態；錄取在取鎖前讀契約狀態 | 簽署時共享鎖住活動、雇主、班次；錄取先鎖報名 |
| 一般編輯（備註、名額、無關欄位）就讓契約失效；已結束活動仍會失效 | 只比對實際契約全文雜湊；已結束活動不失效 |
| 重送確認覆寫簽署時間；舊簽文可能遺失 | 同版重送回傳原結果；失效時若無歷史先保存舊簽文 |
| 班次時薪蓋掉人員設定；缺時薪借用別天費率 | 優先順序：當天班次時薪 → 人員設定 → 活動預設；都沒有時標「須處理」；錄取不再把班次時薪寫入人員設定 |
| LINE 限流計數競態；發碼、兌換、解除可死鎖 | 共用 advisory lock |
| 管理員移除與登入／改密碼可能死鎖 | 改用 advisory lock，取鎖後重新驗證 |
| 通知卡在 sending、超過 3 次、429 未送也計次、舊結果覆寫新領取 | 排程也回收逾時項目；以 claim 比對；只計實際送出；429 後未送的釋放回佇列 |
| CSV 帳號欄引號未跳脫；缺單張發薪日時套用活動日期；試算表公式防護未涵蓋前導空白 | 標準 CSV 序列化；缺發薪日排除；防護涵蓋前導空白 |
| QR 狀態頁讓不能簽到的人看到簽到按鈕 | 狀態回傳 `block`，前端直接說明 |

### 判斷不是問題
- 「工讀生薪資單仍回傳出勤備註」：查資料庫，`payroll_payslip` 已不含 `a.note`；Codex 指到的是管理端 `admin_attendance`，管理員本來就要看備註。

## 2026-11-22 管理員密碼下限 10 → 8

- Codex：預設帳號，gpt-6.2-sol，思考強度 high，約 60,958 token。範圍：`git diff HEAD~1..HEAD`（四個管理員密碼入口、管理端文字、測試）。
- 已修正：第 14 組補「更改我的密碼」7 拒絕、8 接受；三個手動輸入表單改以 `Array.from(...).length` 計算字元數，與資料庫一致（表情符號不再被算成兩個字）。
- 回歸測試 14 組（含新增 14g、14h）全部通過。

## 2026-11-23 報名必須上傳身分證正反面與存摺封面

- 資料庫：`payroll_apply` 寫入報名前檢查三項證件（`person_missing_docs`），回傳 `missing_docs`。
- 網頁：報名頁缺證件時顯示上傳區塊；登錄後的上傳頁三項傳完才能繼續。
- 回歸測試 15 組全部通過（新增第 15 組）。
- **Codex 審查尚未執行**：所有帳號額度低於 20%（Waifdance 9%、預設帳號 0%）。使用者 2026-11-23 指示「先部署後補審」，額度恢復後要補跑，範圍 `git diff 82c41a6^..82c41a6`（說明檔：payroll-brief4）。

## 待補審：發薪日模式（指定日期 / 結束後 N 天）— 2026-11-23
- 範圍：admin_create_event、admin_update_event（pay_date 與 pay_within_days 互斥、套用到薪資單）、web/admin.html 發薪設定、regression 第 16 組
- 狀態：Codex 額度用完（exit 3），使用者指示先部署後補審；額度恢復後以 sol（medium）審查此 commit

## 待補審：班表行事曆＋預設指定發薪日 — 2026-11-23
- 範圍：新增 admin_calendar（STABLE、需管理員 token、區間上限 62 天）、web/admin.html 班表頁（全部／單一活動、上下月、年月選擇）、發薪方式預設改指定日期、regression 第 17 組
- 狀態：使用者指示先部署後補審；額度恢復後以 sol（medium）審查此 commit

## 待補審（安全相關，sol high）：舊表證件一次性匯入 — 2026-11-23
- 範圍：docs Edge Function 新增 legacy_import（以一次性匯入金鑰驗證，金鑰 SHA-256 雜湊存 app_settings、7 天到期；只補系統沒有的證件、不覆蓋）、doc_import_ok（僅 service role 可執行）、apps-script/import-documents.gs
- 狀態：使用者指示先部署後補審；額度恢復後審查此 commit

## 待補審（個資匯出，sol high）：加保名冊 Excel 匯出 — 2026-11-23
- 範圍：admin_roster（STABLE、需管理員 token、狀態白名單、上限 5,000 列）、admin_log_export（匯出前先寫 audit_log，失敗不產生檔案）、web/admin.html 加保名冊頁與自製 XLSX 產生器（文字欄一律字串、不依賴外部套件）、regression 第 18 組
- 狀態：先部署後補審；額度恢復後審查此 commit

## 待補審（含個資，sol high）：資料夾全部舊表暫存匯入 — 2026-11-23
- 範圍：legacy_sheets 暫存表（RLS、無對外權限，整理後刪除）、docs Edge Function 新增 legacy_sheet 與 legacy_import 的 check_only、apps-script/import-documents.gs 改為整個資料夾（分段存進度、自動接續觸發器）
- 狀態：先部署後補審

## 待補審（資料匯入，sol medium）：資料夾 260 份舊表匯入 — 2026-11-24
- 範圍：supabase/LEGACY-IMPORT.md 所述規則（一次性 SQL，已執行並刪除暫存）；apps-script/import-documents.gs 修正 importDocuments 逾時時引用未定義變數
- 狀態：先部署後補審

## 待補審（計薪規則，sol high）：簽到退提示與表定計薪 — 2026-11-24
- 範圍：attendance 新增表定時段、提示與核准欄位；payroll_clock 加 p_ack（提早到、遲到、超時須本人確認並存原文）；att_pay_in/att_pay_out/att_minutes（提早不計、超時待核准，核准後照實際）；payroll_compute、admin_attendance、payroll_payslip 改用 att_minutes；admin_approve_attendance；前台確認畫面、後台核准按鈕；regression 第 19 組
- 同批：舊表證件改存 300px／5KB 內縮圖＋雲端原檔 ID（docs Edge Function、people_documents.drive_file_id、後台人員頁顯示縮圖）
- 狀態：先部署後補審
- 2026-11-24 更新：使用者改定「1＋2」：舊證件只存雲端檔案 ID（path 可空，Edge Function legacy_link、legacy_unlink_copies 已把 796 筆複本改成連結並刪檔）；本人上傳在瀏覽器壓到 1000px／約 50KB；後台「資料已核對」呼叫 verify_docs 降成 500px／約 8KB 存證圖並刪原檔。先前 5KB 縮圖方案作廢。
- 2026-11-24 再更新：使用者要舊證件也能直接看縮圖（約 8KB）。Edge Function 新增 legacy_thumb_todo（列出只有連結的雲端檔案 ID）、legacy_thumb（收 Apps Script 從 Google 雲端取得的 500px 縮圖，一次最多 5 張，壓到 ≤9KB、上限 16KB，存成 `-lthumb-`，保留 drive_file_id、設 downgraded_at，只更新仍為 path null 的列）；Apps Script 新增 importThumbs／testThumb；後台舊表證件顯示縮圖並連到雲端原檔。新增部分索引 people_documents_link_only_idx。合成圖測試通過；狀態：先部署後補審。
- 2026-11-24 Codex 安全審查（Zook 帳號 Waifdance，gpt-6.2-sol，high，約 70,931 token）：1 高 4 中 2 低，未發現匯入金鑰繞過。已修：①請求本文上限 8MB、縮圖批次超過 5 筆拒收、base64 長度上限、解碼前讀 JPEG／PNG 寬高（>1200 拒收）；②本人上傳 confirm 後清掉同類別殘留的 `-lthumb-` 檔，縮圖寫入回應出錯時先確認未被引用才刪；③清單查詢加 ID_KINDS、逐筆回傳 stored／partial／error，Apps Script 跑完一輪後從頭再補，最多 3 輪；④Apps Script 加 LockService 防重疊、連續出錯 5 次停止自動接續、配額用完（含運算時間）3 小時後再跑；⑤confirm 只接受 upload_url 核發的檔名格式（擋縮圖、存證圖路徑）；⑥縮圖簽發失敗時退回雲端原檔連結；⑦優先保留 500px（≤16KB 即收），壓不下才退 420px（沒有完全照建議只調畫質：避免約一成縮圖因超過 16KB 被拒）。Edge Function 第 13 版，合成圖測試通過。
