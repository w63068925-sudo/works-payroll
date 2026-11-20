# 資料庫架構與安全模型

- 前端是 GitHub Pages 上的靜態頁（`web/`），只持有 publishable key。
- 所有資料表開啟 RLS 且沒有任何 policy；anon／authenticated 對資料表沒有任何權限。
- 前端只能呼叫 `public.payroll_*`（工讀生）與 `public.admin_*`（管理員）這些 SECURITY DEFINER 函式。
  每個函式第一步用自家 session token（`sessions`／`admin_sessions`，只存 SHA-256）驗證身分。
- 內部輔助函式（`payroll_session_person`、`admin_actor`、`payroll_compute`、`notify_*`、`line_*` 等）已撤銷 anon／authenticated 的 EXECUTE。
- Edge Functions（`supabase/functions/`）以 service role 執行，`verify_jwt = false`，自行驗證：
  - `docs`：工讀生 token 上傳證件、管理員 token 取得 120 秒簽名網址。
  - `line`：LINE Webhook 以 HMAC 簽章驗證；系統呼叫以 `x-cron-token`（存在 `app_settings`）或管理員 token 驗證。
- pg_cron：`line-notify-tick` 每 2 分鐘、`line-reminders` 每天 10:00 UTC。
- Storage bucket `documents` 為私有。
- `functions.sql` 是從資料庫匯出的實際函式定義。
