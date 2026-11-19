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
    if (b.action === "view_url") {
      const { data: actor } = await sb.rpc("admin_actor", { p_token: String(b.admin_token ?? "") });
      if (!actor) return json({ ok: false, error: "session" });
      if (!KINDS.includes(kind)) return json({ ok: false, error: "bad_kind" });
      const personId = String(b.person_id ?? "");
      const { data: doc } = await sb.from("people_documents").select("path").eq("person_id", personId).eq("kind", kind).maybeSingle();
      if (!doc) return json({ ok: false, error: "missing" });
      const { data, error } = await sb.storage.from("documents").createSignedUrl(doc.path, 120);
      if (error || !data) return json({ ok: false, error: "storage" });
      await sb.from("audit_log").insert({ actor, action: "document_viewed", table_name: "people_documents", row_id: personId, detail: { kind } });
      return json({ ok: true, url: data.signedUrl });
    }
    return json({ ok: false, error: "bad_action" }, 400);
  } catch (_e) {
    return json({ ok: false, error: "server" }, 500);
  }
});
