# works-payroll

沃克思工讀生薪資查詢系統。

- `web/index.html`：工讀生登入與薪資單頁
- `web/admin.html`：管理端（核對、發布）
- `apps-script/daily-export.gs`：每日匯出到 Google 試算表，兼作資料庫每日喚醒
- 資料庫在 Supabase；所有資料表開啟 RLS 且沒有對外政策，網頁只能透過登入後的函式讀取本人資料

此 repo 是公開的，不可放入任何真實個資、密碼或 secret key。`seed/` 只留在本機。

本機預覽：`node web/serve.mjs`，開 http://localhost:5190
