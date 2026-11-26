// 證件上傳與調閱。本函式自行驗證：工讀生用登入 token、管理員用管理 token、舊表匯入用一次性匯入金鑰。（部署時 verify_jwt = false）
// 儲存原則：舊表證件存雲端檔案 ID，另存一張縮圖（2026-11-26 使用者改為 1200px 約 60KB 的清楚版，舊的 500px／8KB 縮圖逐批換掉）；
// 本人上傳的在瀏覽器先壓到約 1000px；管理員按「資料已核對」只記錄核對，不再縮小（2026-11-26 使用者決定）。
import { createClient } from "npm:@supabase/supabase-js@2";
import { decode, Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const KINDS = ["id_front", "id_back", "bankbook", "photo"];
const ID_KINDS = ["id_front", "id_back", "bankbook"];
const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "application/pdf": "pdf" };
const DRIVE_ID = /^[A-Za-z0-9_-]{20,80}$/;
const driveUrl = (id: string) => `https://drive.google.com/file/d/${id}/view`;

// 解碼前先讀圖片寬高（JPEG SOF／PNG IHDR），擋掉解碼後過大的圖；讀不到回 null
function imageDims(b: Uint8Array): [number, number] | null {
  if (b.length > 24 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) {
    const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
    return [v.getUint32(16), v.getUint32(20)];
  }
  if (b.length > 4 && b[0] === 0xff && b[1] === 0xd8) {
    let i = 2;
    while (i + 9 < b.length) {
      if (b[i] !== 0xff) { i++; continue; }
      const m = b[i + 1];
      if (m === 0xff) { i++; continue; }
      if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) { i += 2; continue; }
      const len = (b[i + 2] << 8) | b[i + 3];
      if ((m >= 0xc0 && m <= 0xcf) && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return [(b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]];
      i += 2 + len;
    }
  }
  return null;
}
const MAX_BODY = 8 * 1024 * 1024;
// 本人上傳只接受 upload_url 核發的檔名格式（不能拿縮圖、存證圖等既有檔案來確認）
const uploadPathRe = (pid: string, kind: string) => new RegExp(`^${pid}/${kind}-\\d{13}\\.(jpg|png|webp|heic|pdf)$`);

// 縮成長邊不超過 side 的 JPEG：先求不超過 maxBytes；壓不下時逐步縮小尺寸，最後取不超過 hardMax 的最小檔；都不行回 null
async function shrink(bytes: Uint8Array, side: number, maxBytes: number, hardMax = maxBytes * 2, qualities = [60, 50, 40, 32, 25, 18, 12], scales = [1, 0.84, 0.72]): Promise<Uint8Array | null> {
  const img = await decode(bytes);
  if (!(img instanceof Image)) return null;
  let best: Uint8Array | null = null;
  for (const s of scales.map((k) => Math.round(side * k))) {
    const r = img.width >= img.height
      ? img.clone().resize(Math.min(s, img.width), Image.RESIZE_AUTO)
      : img.clone().resize(Image.RESIZE_AUTO, Math.min(s, img.height));
    for (const q of qualities) {
      const out = await r.encodeJPEG(q);
      if (out.length <= maxBytes) return out;
      if (!best || out.length < best.length) best = out;
    }
  }
  return best && best.length <= hardMax ? best : null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ ok: false, error: "too_large" }, 413);
  let b: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) return json({ ok: false, error: "too_large" }, 413);
    b = JSON.parse(text);
  } catch { return json({ ok: false, error: "bad_request" }, 400); }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const kind = String(b.kind ?? "");
  const importKeyOk = async () => (await sb.rpc("doc_import_ok", { p_key: String(b.import_key ?? "") })).data === true;
  try {
    if (b.action === "upload_url" || b.action === "confirm") {
      const { data: pid } = await sb.rpc("payroll_session_person", { p_token: String(b.token ?? "") });
      if (!pid) return json({ ok: false, error: "session" });
      if (!KINDS.includes(kind)) return json({ ok: false, error: "bad_kind" });
      if (b.action === "upload_url") {
        const ext = EXT[String(b.content_type ?? "")];
        if (!ext) return json({ ok: false, error: "bad_type" });
        const path = `${pid}/${kind}-${Date.now()}.${ext}`;
        const { data, error } = await sb.storage.from("documents").createSignedUploadUrl(path);
        if (error || !data) return json({ ok: false, error: "storage" });
        return json({ ok: true, path, signed_url: data.signedUrl });
      }
      const path = String(b.path ?? "");
      if (!uploadPathRe(String(pid), kind).test(path)) return json({ ok: false, error: "bad_path" });
      const { data: found } = await sb.storage.from("documents").list(String(pid), { search: path.split("/")[1] });
      if (!found || !found.some((f) => `${pid}/${f.name}` === path)) return json({ ok: false, error: "missing" });
      const { data: old } = await sb.from("people_documents").select("path").eq("person_id", pid).eq("kind", kind).maybeSingle();
      // 本人重新上傳：取代舊檔與雲端連結，需重新核對
      const { error: upErr } = await sb.from("people_documents").upsert({ person_id: pid, kind, path, drive_file_id: null, downgraded_at: null, uploaded_at: new Date().toISOString() });
      if (upErr) return json({ ok: false, error: "db" });
      if (old?.path && old.path !== path) await sb.storage.from("documents").remove([old.path]);
      // 與縮圖匯入同時發生時可能留下舊表縮圖：本人上傳後同類別的舊表縮圖一律不再使用，清掉
      const stale = [...((await sb.storage.from("documents").list(String(pid), { search: `${kind}-lthumb-` })).data ?? []), ...((await sb.storage.from("documents").list(String(pid), { search: `${kind}-lhd-` })).data ?? [])];
      const orphan = stale.map((f) => `${pid}/${f.name}`).filter((x) => (x.startsWith(`${pid}/${kind}-lthumb-`) || x.startsWith(`${pid}/${kind}-lhd-`)) && x !== path);
      if (orphan.length) await sb.storage.from("documents").remove(orphan);
      await sb.from("audit_log").insert({ actor: String(pid), action: "document_uploaded", table_name: "people_documents", row_id: pid, detail: { kind } });
      return json({ ok: true });
    }
    // 舊表原始內容暫存（Apps Script 送來），之後在資料庫內整理匯入
    if (b.action === "legacy_sheet") {
      if (!(await importKeyOk())) return json({ ok: false, error: "key" }, 401);
      const fileId = String(b.file_id ?? "");
      if (!DRIVE_ID.test(fileId)) return json({ ok: false, error: "bad_id" });
      const vals = b.values;
      if (!Array.isArray(vals) || vals.length > 5000 || !vals.every((r) => Array.isArray(r) && r.length <= 200)) return json({ ok: false, error: "bad_values" });
      const { error } = await sb.from("legacy_sheets").upsert({ file_id: fileId, title: String(b.title ?? "").slice(0, 300), sheet_name: String(b.sheet_name ?? "").slice(0, 100), vals, received_at: new Date().toISOString() });
      if (error) return json({ ok: false, error: "db" });
      return json({ ok: true, rows: vals.length });
    }
    // 舊表證件：只記錄雲端檔案 ID，不複製檔案；不覆蓋本人上傳的
    if (b.action === "legacy_link") {
      if (!(await importKeyOk())) return json({ ok: false, error: "key" }, 401);
      if (!ID_KINDS.includes(kind)) return json({ ok: false, error: "bad_kind" });
      const nid = String(b.national_id ?? "").trim().toUpperCase();
      if (!/^[A-Z][0-9A-Z]\d{8}$/.test(nid)) return json({ ok: false, error: "bad_id" });
      const driveId = String(b.drive_file_id ?? "");
      if (!DRIVE_ID.test(driveId)) return json({ ok: false, error: "bad_drive_id" });
      const { data: person } = await sb.from("people").select("id").eq("national_id", nid).maybeSingle();
      if (!person) return json({ ok: false, error: "no_person" });
      const { data: has } = await sb.from("people_documents").select("path, drive_file_id").eq("person_id", person.id).eq("kind", kind).maybeSingle();
      const legacyCopy = has && has.path && has.path.includes("-legacy-");
      if (has && !legacyCopy) return json({ ok: true, skipped: "exists" });
      if (legacyCopy) {
        // 之前複製進來的舊證件改成只存連結，並刪掉複本
        const { error } = await sb.from("people_documents").update({ path: null, drive_file_id: has.drive_file_id ?? driveId }).eq("person_id", person.id).eq("kind", kind).eq("path", has.path);
        if (error) return json({ ok: false, error: "db" });
        await sb.storage.from("documents").remove([has.path]);
      } else {
        const { error } = await sb.from("people_documents").insert({ person_id: person.id, kind, path: null, drive_file_id: driveId, uploaded_at: new Date().toISOString() });
        if (error) return json({ ok: true, skipped: "exists" });
      }
      return json({ ok: true, linked: true });
    }
    // 舊表證件縮圖：列出還沒有縮圖的雲端檔案 ID（依 ID 排序分頁）
    if (b.action === "legacy_thumb_todo") {
      if (!(await importKeyOk())) return json({ ok: false, error: "key" }, 401);
      const after = String(b.after ?? "");
      const limit = Math.min(200, Math.max(1, Number(b.limit) || 100));
      let q = sb.from("people_documents").select("drive_file_id").is("path", null).not("drive_file_id", "is", null).in("kind", ID_KINDS).order("drive_file_id").limit(limit);
      if (after) q = q.gt("drive_file_id", after);
      const { data, error } = await q;
      if (error) return json({ ok: false, error: "db" });
      return json({ ok: true, ids: [...new Set((data ?? []).map((r) => r.drive_file_id))] });
    }
    // 舊表證件縮圖：Apps Script 送來 Google 雲端產生的 500px 縮圖，壓到約 8KB 後存起來；雲端原檔連結照樣保留
    if (b.action === "legacy_thumb") {
      if (!(await importKeyOk())) return json({ ok: false, error: "key" }, 401);
      if (!Array.isArray(b.items) || b.items.length > 5) return json({ ok: false, error: "bad_items" });
      const items = b.items;
      const results: string[] = [];
      let stored = 0;
      for (const it of items as Record<string, unknown>[]) {
        const driveId = String(it?.drive_file_id ?? "");
        if (!DRIVE_ID.test(driveId)) { results.push("bad_id"); continue; }
        const { data: rows } = await sb.from("people_documents").select("person_id, kind").eq("drive_file_id", driveId).is("path", null).in("kind", ID_KINDS);
        if (!rows || !rows.length) { results.push("not_found"); continue; }
        let small: Uint8Array | null = null;
        try {
          const b64 = String(it.data ?? "");
          if (b64.length > 0 && b64.length <= 560 * 1024) {
            const raw = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
            const dims = imageDims(raw);
            // Google 給的是 500px 縮圖：寬高超過 1200 或讀不到尺寸就不解碼
            if (dims && dims[0] > 0 && dims[1] > 0 && dims[0] <= 1200 && dims[1] <= 1200) {
              // 優先保留 500px（≤16KB 就收），真的壓不下才退到 420px
              small = await shrink(raw, 500, 9 * 1024, 16 * 1024, [45, 35, 27, 20, 14, 10], [1]);
              if (!small) small = await shrink(raw, 500, 9 * 1024, 16 * 1024, [27, 20, 14, 10], [0.84]);
            }
          }
        } catch { small = null; }
        if (!small) { results.push("bad_image"); continue; }
        let ok = 0;
        for (const r of rows) {
          const path = `${r.person_id}/${r.kind}-lthumb-${Date.now()}.jpg`;
          const { error: upErr } = await sb.storage.from("documents").upload(path, small, { contentType: "image/jpeg", upsert: false });
          if (upErr) continue;
          // 只更新仍是「只有連結」的那筆；期間本人已重新上傳就放棄縮圖
          const { data: upd, error: dbErr } = await sb.from("people_documents").update({ path, downgraded_at: new Date().toISOString() })
            .eq("person_id", r.person_id).eq("kind", r.kind).eq("drive_file_id", driveId).is("path", null).select("person_id");
          if (dbErr || !upd || !upd.length) {
            // 回應出錯時更新可能其實已寫入：確認沒被引用才刪
            const { data: now, error: reErr } = await sb.from("people_documents").select("path").eq("person_id", r.person_id).eq("kind", r.kind).maybeSingle();
            if (!reErr && now?.path === path) { ok++; continue; }
            if (!reErr) await sb.storage.from("documents").remove([path]);
            continue;
          }
          ok++;
        }
        stored += ok;
        results.push(ok === rows.length ? "stored" : ok ? "partial" : "error");
      }
      if (stored) await sb.from("audit_log").insert({ actor: "legacy_import", action: "legacy_thumbs_stored", table_name: "people_documents", detail: { count: stored } });
      return json({ ok: true, results });
    }
    // 舊表證件換清楚版：列出還是 500px 舊縮圖（-lthumb-）的雲端檔案 ID
    if (b.action === "legacy_hd_todo") {
      if (!(await importKeyOk())) return json({ ok: false, error: "key" }, 401);
      const after = String(b.after ?? "");
      const limit = Math.min(200, Math.max(1, Number(b.limit) || 100));
      let q = sb.from("people_documents").select("drive_file_id").like("path", "%-lthumb-%").not("drive_file_id", "is", null).in("kind", ID_KINDS).order("drive_file_id").limit(limit);
      if (after) q = q.gt("drive_file_id", after);
      const { data, error } = await q;
      if (error) return json({ ok: false, error: "db" });
      return json({ ok: true, ids: [...new Set((data ?? []).map((r) => r.drive_file_id))] });
    }
    // 舊表證件換清楚版：Apps Script 送來 Google 雲端的 1200px 縮圖，壓到約 60KB（最多 120KB）後取代舊縮圖，並刪掉舊縮圖檔
    if (b.action === "legacy_hd") {
      if (!(await importKeyOk())) return json({ ok: false, error: "key" }, 401);
      if (!Array.isArray(b.items) || b.items.length > 2) return json({ ok: false, error: "bad_items" });
      const results: string[] = [];
      const orphans: string[] = [];   // 刪不掉或不確定的檔案：記進稽核紀錄，之後清理
      let stored = 0;
      for (const it of b.items as Record<string, unknown>[]) {
        const driveId = String(it?.drive_file_id ?? "");
        if (!DRIVE_ID.test(driveId)) { results.push("bad_id"); continue; }
        const { data: rows } = await sb.from("people_documents").select("person_id, kind, path").eq("drive_file_id", driveId).like("path", "%-lthumb-%").in("kind", ID_KINDS);
        if (!rows || !rows.length) { results.push("not_found"); continue; }
        let hd: Uint8Array | null = null;
        try {
          const b64 = String(it.data ?? "");
          if (b64.length > 0 && b64.length <= 1600 * 1024) {
            const raw = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
            const dims = imageDims(raw);
            if (dims && dims[0] > 0 && dims[1] > 0 && dims[0] <= 2400 && dims[1] <= 2400) {
              // 省運算（避免 Edge Function 資源上限 546）：Google 給的 JPEG 已經夠小就直接存，否則最多壓兩次
              const isJpeg = raw[0] === 0xff && raw[1] === 0xd8;
              if (isJpeg && raw.length <= 70 * 1024 && Math.max(dims[0], dims[1]) <= 1300) hd = raw;
              else hd = await shrink(raw, 1200, 70 * 1024, 110 * 1024, [65, 50], [1]);
            }
          }
        } catch { hd = null; }
        if (!hd) { results.push("bad_image"); continue; }
        let ok = 0;
        for (const r of rows) {
          const path = `${r.person_id}/${r.kind}-lhd-${Date.now()}.jpg`;
          const { error: upErr } = await sb.storage.from("documents").upload(path, hd, { contentType: "image/jpeg", upsert: false });
          if (upErr) continue;
          // 只換仍是舊縮圖的那筆（期間本人重新上傳就放棄）
          await sb.from("people_documents").update({ path, downgraded_at: new Date().toISOString() })
            .eq("person_id", r.person_id).eq("kind", r.kind).eq("path", r.path);
          // 不管更新回應如何，都重新讀一次：資料列指向新檔才刪舊縮圖，否則刪掉沒被用到的新檔
          const { data: now, error: reErr } = await sb.from("people_documents").select("path").eq("person_id", r.person_id).eq("kind", r.kind).maybeSingle();
          if (reErr) { orphans.push(path); continue; }
          const drop = now?.path === path ? r.path : path;
          const { error: rmErr } = await sb.storage.from("documents").remove([drop]);
          if (rmErr) orphans.push(drop);
          if (now?.path === path) ok++;
        }
        stored += ok;
        results.push(ok === rows.length ? "stored" : ok ? "partial" : "error");
      }
      if (stored || orphans.length) await sb.from("audit_log").insert({ actor: "legacy_import", action: "legacy_hd_stored", table_name: "people_documents", detail: { count: stored, cleanup_needed: orphans } });
      return json({ ok: true, results });
    }
    // 把之前複製進來的舊證件（縮圖或原尺寸）全部改成只存連結，釋出空間
    if (b.action === "legacy_unlink_copies") {
      if (!(await importKeyOk())) return json({ ok: false, error: "key" }, 401);
      const { data: rows } = await sb.from("people_documents").select("person_id, kind, path, drive_file_id").like("path", "%-legacy-%").limit(200);
      let converted = 0, removed = 0;
      for (const r of rows ?? []) {
        if (r.drive_file_id) {
          const { error } = await sb.from("people_documents").update({ path: null }).eq("person_id", r.person_id).eq("kind", r.kind).eq("path", r.path);
          if (error) continue;
          converted++;
        } else {
          // 沒有雲端 ID 的舊複本：整筆移除，之後由 legacy_link 補上連結
          const { error } = await sb.from("people_documents").delete().eq("person_id", r.person_id).eq("kind", r.kind).eq("path", r.path);
          if (error) continue;
        }
        const { error: rmErr } = await sb.storage.from("documents").remove([r.path]);
        if (!rmErr) removed++;
      }
      return json({ ok: true, converted, removed, more: (rows ?? []).length === 200 });
    }
    // 管理員核對完資料：只記錄核對時間與核對人，證件維持原本的畫質（2026-11-26 起不再縮成存證圖）
    if (b.action === "verify_docs") {
      const { data: actor } = await sb.rpc("admin_actor", { p_token: String(b.admin_token ?? "") });
      if (!actor) return json({ ok: false, error: "session" });
      const personId = String(b.person_id ?? "");
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(personId)) return json({ ok: false, error: "bad_person" });
      const { data: upd, error } = await sb.from("people").update({ docs_verified_at: new Date().toISOString(), docs_verified_by: actor }).eq("id", personId).select("id");
      if (error || !upd || !upd.length) return json({ ok: false, error: "not_found" });
      await sb.from("audit_log").insert({ actor, action: "documents_verified", table_name: "people", row_id: personId, detail: { downgraded: [], kept: "all" } });
      return json({ ok: true, downgraded: [], kept: [] });
    }
    // 現金發薪簽收單照片：管理員上傳到私有空間 receipts/活動ID/，查看時核發 2 分鐘連結並留紀錄
    if (b.action === "receipt_upload_url" || b.action === "receipt_confirm" || b.action === "receipt_view") {
      const { data: actor } = await sb.rpc("admin_actor", { p_token: String(b.admin_token ?? "") });
      if (!actor) return json({ ok: false, error: "session" });
      const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
      if (b.action === "receipt_view") {
        const rid = String(b.receipt_id ?? "");
        if (!UUID.test(rid)) return json({ ok: false, error: "bad_id" });
        const { data: rec } = await sb.from("payout_receipts").select("event_id, path").eq("id", rid).maybeSingle();
        if (!rec) return json({ ok: false, error: "missing" });
        const { error: auditErr } = await sb.from("audit_log").insert({ actor, action: "receipt_url_issued", table_name: "payout_receipts", row_id: rec.event_id, detail: { receipt: rid } });
        if (auditErr) return json({ ok: false, error: "audit" });
        const { data, error } = await sb.storage.from("documents").createSignedUrl(rec.path, 120);
        if (error || !data) return json({ ok: false, error: "storage" });
        return json({ ok: true, url: data.signedUrl });
      }
      const eventId = String(b.event_id ?? "");
      if (!UUID.test(eventId)) return json({ ok: false, error: "bad_event" });
      const { data: ev } = await sb.from("events").select("id").eq("id", eventId).maybeSingle();
      if (!ev) return json({ ok: false, error: "not_found" });
      if (b.action === "receipt_upload_url") {
        const ext = ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "application/pdf": "pdf" } as Record<string, string>)[String(b.content_type ?? "")];
        if (!ext) return json({ ok: false, error: "bad_type" });
        const path = `receipts/${eventId}/${Date.now()}.${ext}`;
        const { data, error } = await sb.storage.from("documents").createSignedUploadUrl(path);
        if (error || !data) return json({ ok: false, error: "storage" });
        return json({ ok: true, path, signed_url: data.signedUrl });
      }
      const path = String(b.path ?? "");
      if (!new RegExp(`^receipts/${eventId}/\\d{13}\\.(jpg|png|webp|pdf)$`).test(path)) return json({ ok: false, error: "bad_path" });
      const { data: found } = await sb.storage.from("documents").list(`receipts/${eventId}`, { search: path.split("/")[2] });
      if (!found || !found.some((f) => `receipts/${eventId}/${f.name}` === path)) return json({ ok: false, error: "missing" });
      const { error: insErr } = await sb.from("payout_receipts").insert({ event_id: eventId, path, uploaded_by: actor });
      if (insErr) return json({ ok: false, error: "db" });
      await sb.from("audit_log").insert({ actor, action: "receipt_uploaded", table_name: "payout_receipts", row_id: eventId, detail: { path } });
      return json({ ok: true });
    }
    if (b.action === "view_url") {
      const { data: actor } = await sb.rpc("admin_actor", { p_token: String(b.admin_token ?? "") });
      if (!actor) return json({ ok: false, error: "session" });
      if (!KINDS.includes(kind)) return json({ ok: false, error: "bad_kind" });
      const personId = String(b.person_id ?? "");
      const { data: doc } = await sb.from("people_documents").select("path, drive_file_id, downgraded_at").eq("person_id", personId).eq("kind", kind).maybeSingle();
      if (!doc) return json({ ok: false, error: "missing" });
      // 先寫入調閱紀錄，寫入失敗就不核發連結
      const { error: auditErr } = await sb.from("audit_log").insert({ actor, action: "document_url_issued", table_name: "people_documents", row_id: personId, detail: { kind } });
      if (auditErr) return json({ ok: false, error: "audit" });
      const drive = doc.drive_file_id ? driveUrl(doc.drive_file_id) : null;
      if (!doc.path) return json({ ok: true, url: null, drive_url: drive, proof: false });
      const { data, error } = await sb.storage.from("documents").createSignedUrl(doc.path, 120);
      if (error || !data) return drive ? json({ ok: true, url: null, drive_url: drive, proof: false }) : json({ ok: false, error: "storage" });
      return json({ ok: true, url: data.signedUrl, drive_url: drive, proof: !!doc.downgraded_at, legacy_thumb: !!drive });
    }
    return json({ ok: false, error: "bad_action" }, 400);
  } catch (_e) {
    return json({ ok: false, error: "server" }, 500);
  }
});
