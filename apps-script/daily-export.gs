/**
 * 沃克思薪資系統：每日把 Supabase 資料匯出到這份 Google 試算表。
 * 同時讓免費方案的 Supabase 專案每天有請求，不會因閒置被暫停。
 *
 * 安裝：
 * 1. 專案設定 → 指令碼屬性 → 新增 SUPABASE_SECRET_KEY（值從 Supabase 後台 Settings → API Keys 的 secret key 複製）
 * 2. 選 setup 函式 → 執行 → 依畫面授權
 * 這份試算表含身分證與帳戶資料，請勿開啟「知道連結的人」共用。
 */
const SUPABASE_URL = 'https://rxekuiadnzjfvjcgmrxr.supabase.co';

const TABS = [
  { sheet: '人員', table: 'people', order: 'name',
    select: 'national_id,name,nickname,phone,email,birth_date,address,bank_code,bank_branch,bank_account_name,bank_account,profile_source,updated_at' },
  { sheet: '活動', table: 'events', order: 'start_date',
    select: 'name,start_date,end_date,pay_date,pay_within_days' },
  { sheet: '薪資單', table: 'payslips', order: 'period_start,id',
    select: 'event:events(name),person:people(name,national_id),relation,role,work_dates_text,period_start,period_end,pay_date,basis,gross,allowances,deductions,net,status,note,pay_bank_code,pay_bank_branch,pay_account_name,pay_account' },
  { sheet: '薪資明細', table: 'payslip_items', order: 'payslip_id,sort,work_date',
    select: 'payslip:payslips(person:people(name),event:events(name)),kind,label,work_date,hours,rate,amount' },
  { sheet: '出勤', table: 'attendance', order: 'work_date,id',
    select: 'event:events(name),person:people(name),work_date,clock_in,clock_out,break_minutes,scheduled_text,source,note' },
  { sheet: '待處理問題', table: 'data_issues', order: 'resolved,severity,id',
    select: 'severity,code,detail,resolved,event:events(name),person:people(name),created_at' },
];

const EMBEDS = ['event', 'person', 'payslip'];

const HEADERS = {
  'national_id': '身分證字號', 'name': '姓名', 'nickname': '暱稱', 'phone': '電話', 'email': 'Email',
  'birth_date': '生日', 'address': '戶籍地址', 'bank_code': '銀行代碼', 'bank_branch': '分行',
  'bank_account_name': '戶名', 'bank_account': '帳號', 'profile_source': '資料來源', 'updated_at': '更新時間',
  'start_date': '開始日', 'end_date': '結束日', 'pay_date': '發薪日', 'pay_within_days': '活動後幾日內發薪',
  'event.name': '活動', 'person.name': '姓名', 'person.national_id': '身分證字號',
  'payslip.person.name': '姓名', 'payslip.event.name': '活動',
  'relation': '關係', 'role': '崗位', 'work_dates_text': '工作日期（原填）', 'period_start': '計薪起日', 'period_end': '計薪迄日',
  'basis': '計薪方式', 'gross': '應發工資', 'allowances': '津貼', 'deductions': '扣款', 'net': '實發', 'status': '狀態', 'note': '備註',
  'pay_bank_code': '匯款銀行代碼', 'pay_bank_branch': '匯款分行', 'pay_account_name': '匯款戶名', 'pay_account': '匯款帳號',
  'kind': '類別', 'label': '項目', 'work_date': '日期', 'hours': '時數', 'rate': '時薪', 'amount': '金額',
  'clock_in': '上班', 'clock_out': '下班', 'break_minutes': '休息分鐘', 'scheduled_text': '時段', 'source': '來源',
  'severity': '嚴重度', 'code': '代碼', 'detail': '說明', 'resolved': '已處理', 'created_at': '建立時間',
};

function setup() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'dailyExport')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('dailyExport').timeBased().everyDays(1).atHour(6).create();
  dailyExport();
}

function dailyExport() {
  const key = PropertiesService.getScriptProperties().getProperty('SUPABASE_SECRET_KEY');
  if (!key) throw new Error('尚未設定指令碼屬性 SUPABASE_SECRET_KEY');
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  const summary = [];
  TABS.forEach(tab => {
    const rows = fetchAll_(tab, key).map(r => flatten_(r));
    writeTab_(ss, tab.sheet, rows);
    summary.push([tab.sheet, rows.length]);
  });
  const log = ss.getSheetByName('匯出紀錄') || ss.insertSheet('匯出紀錄');
  log.clear();
  log.getRange(1, 1, 1, 2).setValues([['最後匯出時間', Utilities.formatDate(new Date(), 'Asia/Taipei', 'yyyy-MM-dd HH:mm:ss')]]);
  log.getRange(3, 1, summary.length, 2).setValues(summary);
}

function fetchAll_(tab, key) {
  const out = [];
  const size = 1000;
  for (let offset = 0; ; offset += size) {
    const url = SUPABASE_URL + '/rest/v1/' + tab.table +
      '?select=' + encodeURIComponent(tab.select) +
      '&order=' + encodeURIComponent(tab.order) +
      '&limit=' + size + '&offset=' + offset;
    const res = UrlFetchApp.fetch(url, {
      headers: { apikey: key, Authorization: 'Bearer ' + key },
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() !== 200) {
      throw new Error(tab.table + ' 讀取失敗（' + res.getResponseCode() + '）：' + res.getContentText().slice(0, 300));
    }
    const page = JSON.parse(res.getContentText());
    out.push.apply(out, page);
    if (page.length < size) return out;
  }
}

function flatten_(obj, prefix, acc) {
  acc = acc || {};
  Object.keys(obj).forEach(k => {
    const path = prefix ? prefix + '.' + k : k;
    const v = obj[k];
    if (v && typeof v === 'object' && !Array.isArray(v)) flatten_(v, path, acc);
    else if (v === null && EMBEDS.indexOf(k) >= 0) return; // 沒有關聯資料的欄位略過
    else acc[path] = v === null || v === undefined ? '' : String(v);
  });
  return acc;
}

function writeTab_(ss, name, rows) {
  const sheet = ss.getSheetByName(name) || ss.insertSheet(name);
  sheet.clear();
  if (!rows.length) { sheet.getRange(1, 1).setValue('（沒有資料）'); return; }
  const keys = [];
  rows.forEach(r => Object.keys(r).forEach(k => { if (keys.indexOf(k) < 0) keys.push(k); }));
  const values = [keys.map(k => HEADERS[k] || k)].concat(rows.map(r => keys.map(k => r[k] === undefined ? '' : r[k])));
  const range = sheet.getRange(1, 1, values.length, keys.length);
  range.setNumberFormat('@'); // 純文字，保留帳號與電話開頭的 0
  range.setValues(values);
  sheet.setFrozenRows(1);
  sheet.getRange(1, 1, 1, keys.length).setFontWeight('bold');
}
