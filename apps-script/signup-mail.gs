/**
 * 沃克思薪資系統：寄「新人建檔」Email 驗證碼
 *
 * 由 w63068925 帳號建立一個獨立的 Apps Script 專案，貼上這個檔案，
 * 部署成網頁應用程式（執行身分：我；存取權：所有人）。
 * Supabase 的 payroll_signup_start 會用 pg_net 呼叫 /exec，帶 HMAC 簽章（用共用密鑰簽 to|code|ts）。
 *
 * 設定：專案設定 → 指令碼屬性 → 新增 MAIL_KEY（值與資料庫 app_settings.mail_key 相同）。
 * 密鑰不要貼在對話或程式碼裡。
 */
function doPost(e) {
  var out = function (s) { return ContentService.createTextOutput(s); };
  var body;
  try { body = JSON.parse(e.postData.contents); } catch (err) { return out('bad'); }
  var key = PropertiesService.getScriptProperties().getProperty('MAIL_KEY');
  if (!key || !body || body.type !== 'signup_code') return out('denied');
  var to = String(body.to || '').trim();
  var code = String(body.code || '');
  var ts = Number(body.ts);
  // 資料庫只送 HMAC 簽章（to|code|ts），不送密鑰本身；10 分鐘以外的請求不收
  if (!ts || Math.abs(Date.now() / 1000 - ts) > 600) return out('denied');
  var raw = Utilities.computeHmacSha256Signature(to + '|' + code + '|' + ts, key, Utilities.Charset.UTF_8);
  var sig = raw.map(function (b) { return ('0' + (b & 0xff).toString(16)).slice(-2); }).join('');
  if (sig !== String(body.sig || '')) return out('denied');
  if (!/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(to) || to.length > 120 || !/^\d{6}$/.test(code)) return out('bad');
  if (MailApp.getRemainingDailyQuota() < 1) return out('quota');
  MailApp.sendEmail({
    to: to,
    subject: '【沃克思】建立帳號驗證碼 ' + code,
    name: '沃克思 WORKS',
    body: '你好：\n\n你的沃克思薪資系統建立帳號驗證碼是：' + code + '\n\n10 分鐘內有效。請回到建立帳號的頁面輸入。\n' +
      '如果不是你本人申請，請忽略這封信，帳號不會建立。\n\n沃克思 WORKS',
    htmlBody: '<p>你好：</p><p>你的沃克思薪資系統建立帳號驗證碼是：</p>' +
      '<p style="font-size:28px;font-weight:700;letter-spacing:6px;margin:12px 0">' + code + '</p>' +
      '<p>10 分鐘內有效。請回到建立帳號的頁面輸入。</p>' +
      '<p style="color:#6f6b63">如果不是你本人申請，請忽略這封信，帳號不會建立。</p><p>沃克思 WORKS</p>'
  });
  return out('ok');
}

// 部署後在編輯器執行一次，完成寄信授權（會寄一封測試信給自己）
function authorizeOnce() {
  MailApp.sendEmail(Session.getActiveUser().getEmail(), '沃克思驗證信授權測試', '授權完成，這封信可以刪除。');
}
