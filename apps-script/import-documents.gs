/**
 * 舊表證件一次性匯入：把 Google 表單回覆裡的「身分證正面、反面、存摺封面」送進薪資系統。
 *
 * 必須在「表單檔案擁有者」的帳號（mamba20230501@gmail.com）執行，才讀得到上傳的照片。
 * 1. 到 https://script.google.com 新增專案，把這整份貼上。
 * 2. 專案設定 → 指令碼屬性 → 新增 IMPORT_KEY，值貼本機 seed/doc-import-key.local.md 第二行（7 天內有效）。
 * 3. 選 importDocuments → 執行，第一次會要求授權。
 * 4. 每次最多跑 5 分鐘；記錄出現「還沒跑完」就再按一次執行，直到出現「全部完成」。
 *
 * 規則：系統裡已經有的證件（例如本人自己上傳的）不會被覆蓋；同一人在多份表單都有，以最新一場活動為準。
 * 照片不經過任何第三方，直接從你的雲端送到系統的私有儲存區。完成後可以刪除這個 Apps Script 專案。
 */
const ENDPOINT = 'https://rxekuiadnzjfvjcgmrxr.supabase.co/functions/v1/docs';
// 由新到舊：同一人以最新一場的證件為準
const SHEETS = [
  ['2026萬事屋校園巡迴', '1PRc3FcjExA5J1-PySoyG7nYVeDMn6iJWQZWAD4nEdKE'],
  ['0718-0719技嘉', '12tQWREplsqUOf8Us0sKNSZBYKhn_z1gUQlnyrO6SJoY'],
  ['6/25-7/2品牌活動', '14JdrtS_zL_y4fbh5D5m3h9xK6j9e4ETaL2V7xRFx8o0'],
  ['0602、0617 Dcard x 黑松', '17EQ3MkNrFqUkUCSTNS9VXaoTMrz6TJ8jBzzWnXVGjLI'],
  ['2025 9月 Dcard移動萬事屋', '1xavKDUkdEls3IzSUvOQTHtimpXHQOiN6Gm2_tjkZFgY'],
  ['2024 全美家庭日', '1CK0RO2xMgYqdCrEoaNsRHh46fwcsmvxeThOXrsN5Ck8'],
];
const ID_RE = /^[A-Z][0-9A-Z]\d{8}$/;
const URL_RE = /https:\/\/drive\.google\.com\/open\?id=([\w-]+)/g;
const OK_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'];
const MAX_BYTES = 8 * 1024 * 1024;

function importDocuments() {
  const key = PropertiesService.getScriptProperties().getProperty('IMPORT_KEY');
  if (!key) throw new Error('請先在「專案設定 → 指令碼屬性」新增 IMPORT_KEY');
  const store = PropertiesService.getUserProperties();
  const done = JSON.parse(store.getProperty('done') || '{}');
  const start = Date.now();
  const stat = { imported: 0, skipped: 0, noPerson: 0, failed: 0 };
  const fails = [];

  for (const [label, id] of SHEETS) {
    const sh = SpreadsheetApp.openById(id).getSheets()[0];
    const rows = sh.getDataRange().getDisplayValues();
    const head = rows[0].map(h => String(h).replace(/\s+/g, ''));
    const col = re => head.findIndex(h => re.test(h));
    const cId = col(/^身分證字號/), cBank = col(/存摺/), cFront = col(/身分證正面/), cBack = col(/身分證反面/), cBoth = col(/身分證正反面/);
    // 依欄位順序排好的上傳欄，用來對付「整列往右偏移」的列
    const uploadCols = [[cBank, 'bankbook'], [cFront, 'id_front'], [cBack, 'id_back'], [cBoth, 'both']].filter(x => x[0] >= 0).sort((a, b) => a[0] - b[0]);

    for (let r = rows.length - 1; r >= 1; r--) { // 同一表內由新到舊
      if (Date.now() - start > 5 * 60 * 1000) return finish(stat, fails, false);
      const row = rows[r];
      let nid = String(row[cId] || '').trim().toUpperCase();
      if (!ID_RE.test(nid)) nid = (row.map(v => String(v).trim().toUpperCase()).find(v => ID_RE.test(v)) || '');
      if (!nid) continue;

      const files = {};
      const put = (kind, cell) => { const ids = idsIn(cell); if (kind === 'both') { if (ids[0]) files.id_front = ids[0]; if (ids[1]) files.id_back = ids[1]; } else if (ids[0]) files[kind] = ids[0]; };
      uploadCols.forEach(([c, kind]) => put(kind, row[c]));
      if (!Object.keys(files).length) {
        // 欄位偏移：依出現順序對應上傳欄
        const cells = row.filter(v => idsIn(v).length);
        if (cells.length === uploadCols.length) uploadCols.forEach(([, kind], i) => put(kind, cells[i]));
      }

      for (const kind of Object.keys(files)) {
        const tag = nid + ':' + kind;
        if (done[tag]) continue;
        try {
          const blob = fileBlob(files[kind]);
          const res = UrlFetchApp.fetch(ENDPOINT, {
            method: 'post', contentType: 'application/json', muteHttpExceptions: true,
            payload: JSON.stringify({ action: 'legacy_import', import_key: key, national_id: nid, kind, content_type: blob.getContentType(), data: Utilities.base64Encode(blob.getBytes()), source: label }),
          });
          const out = JSON.parse(res.getContentText() || '{}');
          if (res.getResponseCode() === 401) throw new Error('IMPORT_KEY 不正確或已過期');
          if (out.imported) stat.imported++;
          else if (out.skipped) stat.skipped++;
          else if (out.error === 'no_person') stat.noPerson++;
          else { stat.failed++; fails.push(label + ' 第' + (r + 1) + '列 ' + kind + '：' + (out.error || res.getResponseCode())); continue; }
          done[tag] = 1;
          store.setProperty('done', JSON.stringify(done));
        } catch (e) {
          if (String(e.message).includes('IMPORT_KEY')) throw e;
          stat.failed++; fails.push(label + ' 第' + (r + 1) + '列 ' + kind + '：' + e.message);
        }
      }
    }
  }
  return finish(stat, fails, true);
}

function idsIn(cell) {
  const out = []; let m; URL_RE.lastIndex = 0;
  while ((m = URL_RE.exec(String(cell || '')))) out.push(m[1]);
  return out;
}

// 取得檔案；格式不支援就轉 JPEG，太大就改抓 2400px 縮圖
function fileBlob(fileId) {
  let blob = DriveApp.getFileById(fileId).getBlob();
  let type = blob.getContentType();
  if (type === 'image/heif') { blob.setContentType('image/heic'); type = 'image/heic'; }
  if (OK_TYPES.indexOf(type) < 0) { blob = blob.getAs('image/jpeg'); type = 'image/jpeg'; }
  if (blob.getBytes().length > MAX_BYTES) {
    const res = UrlFetchApp.fetch('https://drive.google.com/thumbnail?sz=w2400&id=' + fileId, { headers: { Authorization: 'Bearer ' + ScriptApp.getOAuthToken() } });
    blob = res.getBlob(); blob.setContentType('image/jpeg');
  }
  return blob;
}

function finish(stat, fails, complete) {
  Logger.log((complete ? '全部完成。' : '還沒跑完（每次最多 5 分鐘），請再按一次執行。') +
    ' 本次新增 ' + stat.imported + '、系統已有略過 ' + stat.skipped + '、系統沒有此人 ' + stat.noPerson + '、失敗 ' + stat.failed);
  fails.slice(0, 50).forEach(f => Logger.log('失敗：' + f));
}

// 想從頭重跑時執行這個（系統已有的證件仍會略過，不會重複）
function resetProgress() { PropertiesService.getUserProperties().deleteProperty('done'); }
