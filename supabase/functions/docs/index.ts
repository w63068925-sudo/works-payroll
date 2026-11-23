// 證件上傳與調閱。本函式自行驗證：工讀生用登入 token、管理員用管理 token。（部署時 verify_jwt = false）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const KINDS = ["id_front", "id_back", "bankbook", "photo"];
const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic", "application/pdf": "pdf" };

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return json({ ok: false, error: "bad_request" }, 400); }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const kind = String(b.kind ?? "");
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
      if (!path.startsWith(`${pid}/${kind}-`) || path.includes("..")) return json({ ok: false, error: "bad_path" });
      const { data: found } = await sb.storage.from("documents").list(String(pid), { search: path.split("/")[1] });
      if (!found || !found.some((f) => `${pid}/${f.name}` === path)) return json({ ok: false, error: "missing" });
      const { data: old } = await sb.from("people_documents").select("path").eq("person_id", pid).eq("kind", kind).maybeSingle();
      const { error: upErr } = await sb.from("people_documents").upsert({ person_id: pid, kind, path, uploaded_at: new Date().toISOString() });
      if (upErr) return json({ ok: false, error: "db" });
      if (old?.path && old.path !== path) await sb.storage.from("documents").remove([old.path]);
      await sb.from("audit_log").insert({ actor: String(pid), action: "document_uploaded", table_name: "people_documents", row_id: pid, detail: { kind } });
      return json({ ok: true });
    }
    // 舊表原始內容暫存（Apps Script 送來），之後在資料庫內整理匯入
    if (b.action === "legacy_sheet") {
      const { data: ok } = await sb.rpc("doc_import_ok", { p_key: String(b.import_key ?? "") });
      if (ok !== true) return json({ ok: false, error: "key" }, 401);
      const fileId = String(b.file_id ?? "");
      if (!/^[A-Za-z0-9_-]{20,80}$/.test(fileId)) return json({ ok: false, error: "bad_id" });
      const vals = b.values;
      if (!Array.isArray(vals) || vals.length > 5000 || !vals.every((r) => Array.isArray(r) && r.length <= 200)) return json({ ok: false, error: "bad_values" });
      const { error } = await sb.from("legacy_sheets").upsert({ file_id: fileId, title: String(b.title ?? "").slice(0, 300), sheet_name: String(b.sheet_name ?? "").slice(0, 100), vals, received_at: new Date().toISOString() });
      if (error) return json({ ok: false, error: "db" });
      return json({ ok: true, rows: vals.length });
    }
    // 舊表證件一次性匯入（Apps Script 從表單擁有者的雲端送來）：只補沒有的，不覆蓋本人上傳的
    if (b.action === "legacy_import") {
      const { data: ok } = await sb.rpc("doc_import_ok", { p_key: String(b.import_key ?? "") });
      if (ok !== true) return json({ ok: false, error: "key" }, 401);
      if (!["id_front", "id_back", "bankbook"].includes(kind)) return json({ ok: false, error: "bad_kind" });
      const nid = String(b.national_id ?? "").trim().toUpperCase();
      if (!/^[A-Z][0-9A-Z]\d{8}$/.test(nid)) return json({ ok: false, error: "bad_id" });
      const { data: person } = await sb.from("people").select("id").eq("national_id", nid).maybeSingle();
      if (!person) return json({ ok: false, error: "no_person" });
      const { data: has } = await sb.from("people_documents").select("path").eq("person_id", person.id).eq("kind", kind).maybeSingle();
      if (has) return json({ ok: true, skipped: "exists" });
      if (b.check_only === true) return json({ ok: true, need: true });
      const type = String(b.content_type ?? ""), ext = EXT[type];
      if (!ext) return json({ ok: false, error: "bad_type", type });
      let bytes: Uint8Array;
      try { bytes = Uint8Array.from(atob(String(b.data ?? "")), (c) => c.charCodeAt(0)); } catch { return json({ ok: false, error: "bad_data" }); }
      if (bytes.length < 100 || bytes.length > 8 * 1024 * 1024) return json({ ok: false, error: "bad_size", size: bytes.length });
      const path = `${person.id}/${kind}-legacy-${Date.now()}.${ext}`;
      const { error: stErr } = await sb.storage.from("documents").upload(path, bytes, { contentType: type, upsert: false });
      if (stErr) return json({ ok: false, error: "storage" });
      const { error: insErr } = await sb.from("people_documents").insert({ person_id: person.id, kind, path, uploaded_at: new Date().toISOString() });
      if (insErr) { await sb.storage.from("documents").remove([path]); return json({ ok: true, skipped: "exists" }); }
      await sb.from("audit_log").insert({ actor: "legacy_import", action: "document_imported", table_name: "people_documents", row_id: person.id, detail: { kind, source: String(b.source ?? "").slice(0, 80) } });
      return json({ ok: true, imported: true });
    }
    if (b.action === "view_url") {
      const { data: actor } = await sb.rpc("admin_actor", { p_token: String(b.admin_token ?? "") });
      if (!actor) return json({ ok: false, error: "session" });
      if (!KINDS.includes(kind)) return json({ ok: false, error: "bad_kind" });
      const personId = String(b.person_id ?? "");
      const { data: doc } = await sb.from("people_documents").select("path").eq("person_id", personId).eq("kind", kind).maybeSingle();
      if (!doc) return json({ ok: false, error: "missing" });
      // 先寫入調閱紀錄，寫入失敗就不核發連結
      const { error: auditErr } = await sb.from("audit_log").insert({ actor, action: "document_url_issued", table_name: "people_documents", row_id: personId, detail: { kind } });
      if (auditErr) return json({ ok: false, error: "audit" });
      const { data, error } = await sb.storage.from("documents").createSignedUrl(doc.path, 120);
      if (error || !data) return json({ ok: false, error: "storage" });
      return json({ ok: true, url: data.signedUrl });
    }
    return json({ ok: false, error: "bad_action" }, 400);
  } catch (_e) {
    return json({ ok: false, error: "server" }, 500);
  }
});
