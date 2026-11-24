/**
 * 舊表一次性匯入：把雲端資料夾裡所有表單回覆表的「人員、薪資資料」與「身分證正反面、存摺封面」送進薪資系統。
 *
 * 必須在「表單檔案擁有者」的帳號（mamba20230501@gmail.com）執行，才讀得到上傳的照片。
 * 1. 到 https://script.google.com 新增專案，把這整份貼上。
 * 2. 專案設定 → 指令碼屬性 → 新增 IMPORT_KEY，值貼本機 seed/doc-import-key.local.md 第二行（有效期限內使用）。
 * 3. 第一步：選 importSheets → 執行（第一次會要求授權）。把每份表的內容送進系統暫存區。
 *    跑不完會自動在 1 分鐘後接著跑，不用一直按；全部完成會在執行紀錄寫「表格全部送出」。
 * 4. 等系統整理好人員資料後，第二步：選 importDocuments → 執行。同樣會自動接續，直到「證件全部完成」。
 * 5. 第三步：選 importThumbs → 執行。向 Google 雲端要每張證件的 500px 縮圖送進系統（系統再壓到約 8KB），
 *    後台就能直接看到縮圖；會自動接續，直到「縮圖全部完成」。
 *
 * 規則：系統裡已經有的證件（例如本人自己上傳的）不會被覆蓋；同一人在多份表單都有，以最新一場活動為準。
 * 舊證件原檔不複製進系統：記錄雲端檔案 ID，另存一張約 8KB 的縮圖；點縮圖會開雲端原檔（只有被分享的帳號打得開）。
 * 資料不經過任何第三方，直接從你的雲端送到系統的私有儲存區。全部完成後可以刪除這個 Apps Script 專案。
 */
const ENDPOINT = 'https://rxekuiadnzjfvjcgmrxr.supabase.co/functions/v1/docs';
const FOLDER_ID = '18YMg_0INusMi4Jyo7n0nA3tbyHjTmfk5';
const ID_RE = /^[A-Z][0-9A-Z]\d{8}$/;
const URL_RE = /https:\/\/drive\.google\.com\/open\?id=([\w-]+)/g;
const BUDGET_MS = 4.5 * 60 * 1000;

function key_() {
  const k = PropertiesService.getScriptProperties().getProperty('IMPORT_KEY');
  if (!k) throw new Error('請先在「專案設定 → 指令碼屬性」新增 IMPORT_KEY');
  return k;
}
function req_(body) { return { url: ENDPOINT, method: 'post', contentType: 'application/json', muteHttpExceptions: true, payload: JSON.stringify(body) }; }
function post_(body) {
  const res = UrlFetchApp.fetch(ENDPOINT, { method: 'post', contentType: 'application/json', muteHttpExceptions: true, payload: JSON.stringify(body) });
  if (res.getResponseCode() === 401) throw new Error('IMPORT_KEY 不正確或已過期');
  return JSON.parse(res.getContentText() || '{}');
}
// 每個屬性最多 9KB，進度資料切成多段存
function getBig_(name, dflt) {
  const p = PropertiesService.getUserProperties(), n = Number(p.getProperty(name + '#n') || 0);
  if (!n) return dflt;
  let s = ''; for (let i = 0; i < n; i++) s += p.getProperty(name + '#' + i) || '';
  return JSON.parse(s);
}
function setBig_(name, obj) {
  const p = PropertiesService.getUserProperties(), s = JSON.stringify(obj), parts = {};
  let n = 0; for (let i = 0; i < s.length; i += 2000) parts[name + '#' + (n++)] = s.slice(i, i + 2000);
  parts[name + '#n'] = String(n);
  p.setProperties(parts);
}
function done_(name) { return getBig_(name, {}); }
function saveDone_(name, obj) { setBig_(name, obj); }
// 時間用完：1 分鐘後自動接著跑
function continueLater_(fn, minutes) {
  ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === fn).forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger(fn).timeBased().after((minutes || 1) * 60 * 1000).create();
}
function stopTriggers_(fn) { ScriptApp.getProjectTriggers().filter(t => t.getHandlerFunction() === fn).forEach(t => ScriptApp.deleteTrigger(t)); }
function sheetFiles_() {
  const out = [], it = DriveApp.getFolderById(FOLDER_ID).getFilesByType(MimeType.GOOGLE_SHEETS);
  while (it.hasNext()) { const f = it.next(); out.push({ id: f.getId(), title: f.getName() }); }
  return out;
}

/* ---------- 第一步：表格內容 ---------- */
function importSheets() {
  const key = key_(), start = Date.now(), done = done_('sheets');
  const files = sheetFiles_();
  let sent = 0, failed = [];
  for (const f of files) {
    if (done[f.id]) continue;
    if (Date.now() - start > BUDGET_MS) { saveDone_('sheets', done); continueLater_('importSheets'); Logger.log('還沒跑完，1 分鐘後自動接著跑。已送 ' + Object.keys(done).length + '／' + files.length); return; }
    try {
      const sh = SpreadsheetApp.openById(f.id).getSheets()[0];
      const values = sh.getDataRange().getDisplayValues().slice(0, 5000).map(r => r.slice(0, 200));
      const out = post_({ action: 'legacy_sheet', import_key: key, file_id: f.id, title: f.title, sheet_name: sh.getName(), values });
      if (out.ok) { done[f.id] = 1; sent++; } else failed.push(f.title + '：' + out.error);
    } catch (e) {
      if (String(e.message).includes('IMPORT_KEY')) throw e;
      failed.push(f.title + '：' + e.message);
    }
  }
  saveDone_('sheets', done);
  stopTriggers_('importSheets');
  Logger.log('表格全部送出：' + Object.keys(done).length + '／' + files.length + '（本次 ' + sent + '）');
  failed.forEach(x => Logger.log('失敗：' + x));
}

/* ---------- 第二步：證件照片 ---------- */
function importDocuments() {
  const key = key_(), start = Date.now();
  const stat = { imported: 0, skipped: 0, noPerson: 0, failed: 0 }, fails = [];
  // 最新的表先處理（同一人以最新一場的證件為準）；順序只在第一次計算後記住
  let order = getBig_('docOrder', null);
  if (!order) {
    order = sheetFiles_().map(f => ({ id: f.id, title: f.title, latest: Math.max(0, ...SpreadsheetApp.openById(f.id).getSheets()[0].getRange('A2:A').getDisplayValues().map(r => stamp_(r[0]))) }))
      .sort((a, b) => b.latest - a.latest).map(x => [x.id, x.title.slice(0, 40)]);
    setBig_('docOrder', order);
  }
  const sheetDone = done_('docSheets');
  for (const [fid, ftitle] of order) {
    if (sheetDone[fid]) continue;
    if (Date.now() - start > BUDGET_MS) { continueLater_('importDocuments'); return finish_(stat, fails, false); }
    const f = { id: fid, title: ftitle };
    const rows = SpreadsheetApp.openById(fid).getSheets()[0].getDataRange().getDisplayValues();
    let missingPerson = false;
    if (!rows.length) { sheetDone[fid] = 1; saveDone_('docSheets', sheetDone); continue; }
    const head = rows[0].map(h => String(h).replace(/\s+/g, ''));
    const col = re => head.findIndex(h => re.test(h));
    const cId = col(/身分證字號|身份證字號/), cBank = col(/存摺/), cFront = col(/身[分份]證正面/), cBack = col(/身[分份]證反面/), cBoth = col(/身[分份]證正反面/);
    const uploadCols = [[cBank, 'bankbook'], [cFront, 'id_front'], [cBack, 'id_back'], [cBoth, 'both']].filter(x => x[0] >= 0).sort((a, b) => a[0] - b[0]);
    if (!uploadCols.length) { sheetDone[fid] = 1; saveDone_('docSheets', sheetDone); continue; }

    // 整份表先收集要處理的照片
    const items = [];
    for (let r = rows.length - 1; r >= 1; r--) {
      const row = rows[r];
      let nid = cId >= 0 ? String(row[cId] || '').trim().toUpperCase() : '';
      if (!ID_RE.test(nid)) nid = (row.map(v => String(v).trim().toUpperCase()).find(v => ID_RE.test(v)) || '');
      if (!nid) continue;
      const files = {};
      const put = (kind, cell) => { const ids = idsIn_(cell); if (kind === 'both') { if (ids[0]) files.id_front = ids[0]; if (ids[1]) files.id_back = ids[1]; } else if (ids[0]) files[kind] = ids[0]; };
      uploadCols.forEach(([c, kind]) => put(kind, row[c]));
      if (!Object.keys(files).length) {
        const cells = row.filter(v => idsIn_(v).length); // 整列偏移時依出現順序對應
        if (cells.length === uploadCols.length) uploadCols.forEach(([, kind], i) => put(kind, cells[i]));
      }
      Object.keys(files).forEach(kind => { if (!items.some(x => x.nid === nid && x.kind === kind)) items.push({ nid, kind, fileId: files[kind], r }); });
    }
    // 只送雲端檔案 ID（不下載、不複製照片）；系統已有的（例如本人上傳）會略過
    for (let i = 0; i < items.length; i += 50) {
      if (Date.now() - start > BUDGET_MS) { continueLater_('importDocuments'); return finish_(stat, fails, false); }
      const part = items.slice(i, i + 50);
      UrlFetchApp.fetchAll(part.map(it => req_({ action: 'legacy_link', import_key: key, national_id: it.nid, kind: it.kind, drive_file_id: it.fileId }))).forEach((x, j) => {
        if (x.getResponseCode() === 401) throw new Error('IMPORT_KEY 不正確或已過期');
        const o = JSON.parse(x.getContentText() || '{}');
        if (o.linked) stat.imported++;
        else if (o.skipped) stat.skipped++;
        else if (o.error === 'no_person') { stat.noPerson++; missingPerson = true; }
        else { stat.failed++; fails.push(f.title + ' 第' + (part[j].r + 1) + '列 ' + part[j].kind + '：' + (o.error || x.getResponseCode())); }
      });
    }
    // 有「系統還沒有此人」的表不標記完成，之後重跑會再補
    if (!missingPerson) { sheetDone[fid] = 1; saveDone_('docSheets', sheetDone); }
  }
  stopTriggers_('importDocuments');
  finish_(stat, fails, true);
}

function stamp_(v) { const m = String(v || '').match(/(\d{4})\/(\d{1,2})\/(\d{1,2})/); return m ? Number(m[1]) * 10000 + Number(m[2]) * 100 + Number(m[3]) : 0; }
function idsIn_(cell) { const out = []; let m; URL_RE.lastIndex = 0; while ((m = URL_RE.exec(String(cell || '')))) out.push(m[1]); return out; }
function finish_(stat, fails, complete) {
  Logger.log((complete ? '證件全部完成。' : '還沒跑完，1 分鐘後自動接著跑。') +
    ' 本次建立連結 ' + stat.imported + '、系統已有略過 ' + stat.skipped + '、系統還沒有此人 ' + stat.noPerson + '、失敗 ' + stat.failed);
  fails.slice(0, 50).forEach(f => Logger.log('失敗：' + f));
}

/* ---------- 第三步：證件縮圖 ---------- */
// 向 Google 雲端要 500px 縮圖（Google 負責縮小，不下載原檔）
function thumbReq_(id, token) { return { url: 'https://drive.google.com/thumbnail?sz=w500&id=' + encodeURIComponent(id), headers: { Authorization: 'Bearer ' + token }, muteHttpExceptions: true, followRedirects: true }; }
function isImage_(res) { return res.getResponseCode() === 200 && /^image\//.test(String(res.getHeaders()['Content-Type'] || res.getHeaders()['content-type'] || '')); }

function importThumbs() {
  const key = key_(), start = Date.now(), token = ScriptApp.getOAuthToken(), props = PropertiesService.getUserProperties();
  const stat = { stored: 0, noThumb: 0, failed: 0 };
  let cursor = props.getProperty('thumbCursor') || '';
  // 保險：萬一這次中途出錯，15 分鐘後自動再試
  continueLater_('importThumbs', 15);
  try {
    while (true) {
      const todo = post_({ action: 'legacy_thumb_todo', import_key: key, after: cursor, limit: 100 });
      if (!todo.ok) throw new Error('清單取得失敗：' + todo.error);
      if (!todo.ids.length) break;
      for (let i = 0; i < todo.ids.length; i += 20) {
        if (Date.now() - start > BUDGET_MS) { props.setProperty('thumbCursor', cursor); continueLater_('importThumbs', 1); return thumbLog_(stat, false); }
        const ids = todo.ids.slice(i, i + 20);
        const items = [];
        UrlFetchApp.fetchAll(ids.map(id => thumbReq_(id, token))).forEach((res, j) => {
          if (isImage_(res)) items.push({ drive_file_id: ids[j], data: Utilities.base64Encode(res.getContent()) });
          else stat.noThumb++;
        });
        const groups = [];
        for (let k = 0; k < items.length; k += 4) groups.push(items.slice(k, k + 4));
        UrlFetchApp.fetchAll(groups.map(g => req_({ action: 'legacy_thumb', import_key: key, items: g }))).forEach(res => {
          if (res.getResponseCode() === 401) throw new Error('IMPORT_KEY 不正確或已過期');
          const o = JSON.parse(res.getContentText() || '{}');
          (o.results || []).forEach(r => { if (r === 'stored') stat.stored++; else stat.failed++; });
          if (!o.ok) stat.failed += 4;
        });
        cursor = ids[ids.length - 1];
        props.setProperty('thumbCursor', cursor);
      }
    }
  } catch (e) {
    // 每日次數用完：3 小時後再接著跑
    if (/too many times|次數過多|Bandwidth quota|Service invoked/i.test(String(e.message))) { props.setProperty('thumbCursor', cursor); continueLater_('importThumbs', 180); Logger.log('今天的 Google 呼叫次數用完了，3 小時後自動再接著跑。'); return thumbLog_(stat, false); }
    if (String(e.message).includes('IMPORT_KEY')) stopTriggers_('importThumbs');
    throw e;
  }
  stopTriggers_('importThumbs');
  props.deleteProperty('thumbCursor');
  thumbLog_(stat, true);
}
function thumbLog_(stat, complete) {
  Logger.log((complete ? '縮圖全部完成。' : '還沒跑完，會自動接著跑。') + ' 本次存入縮圖 ' + stat.stored + '、雲端沒有縮圖 ' + stat.noThumb + '、失敗 ' + stat.failed);
}
// 先試一張：看 Google 雲端給的縮圖格式與大小
function testThumb() {
  const todo = post_({ action: 'legacy_thumb_todo', import_key: key_(), after: '', limit: 3 });
  const res = UrlFetchApp.fetchAll(todo.ids.map(id => thumbReq_(id, ScriptApp.getOAuthToken())));
  res.forEach(r => Logger.log('狀態 ' + r.getResponseCode() + '、格式 ' + (r.getHeaders()['Content-Type'] || '') + '、大小 ' + r.getContent().length + ' bytes'));
}

// 想從頭重跑時執行（系統已有的資料仍會略過，不會重複）
function resetProgress() { PropertiesService.getUserProperties().deleteAllProperties(); stopTriggers_('importSheets'); stopTriggers_('importDocuments'); stopTriggers_('importThumbs'); }
