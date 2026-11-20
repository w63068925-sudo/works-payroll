// LINE 官方帳號：接收 Webhook（綁定）、發送通知、檢查連線狀態。
// 需要的 Edge Function Secrets：LINE_CHANNEL_SECRET、LINE_CHANNEL_ACCESS_TOKEN（部署時 verify_jwt = false，本函式自行驗證）
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-cron-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const SECRET = Deno.env.get("LINE_CHANNEL_SECRET") ?? "";
const TOKEN = Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN") ?? "";
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function validSignature(raw: string, sig: string): Promise<boolean> {
  if (!SECRET || !sig) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw)));
  const expected = btoa(String.fromCharCode(...mac));
  if (expected.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
}
async function line(path: string, init: RequestInit = {}) {
  return fetch("https://api.line.me" + path, { ...init, headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json", ...(init.headers ?? {}) } });
}
async function reply(token: string, text: string) {
  await line("/v2/bot/message/reply", { method: "POST", body: JSON.stringify({ replyToken: token, messages: [{ type: "text", text }] }) });
}
async function siteUrl() {
  const { data } = await sb.from("app_settings").select("value").eq("key", "site_url").maybeSingle();
  return data?.value ?? "";
}

async function flush() {
  if (!TOKEN) return { ok: false, error: "not_configured" };
  let sent = 0, failed = 0;
  for (let round = 0; round < 10; round++) {
    const { data: batch, error } = await sb.rpc("notify_batch", { p_limit: 25 });
    if (error) return { ok: false, error: "db" };
    if (!batch || batch.length === 0) break;
    const results: { id: string; status: string; error: string | null }[] = [];
    let stop = false;
    for (const m of batch as { id: string; to: string; text: string }[]) {
      if (stop) { results.push({ id: m.id, status: "pending", error: null }); continue; }
      const res = await line("/v2/bot/message/push", { method: "POST", headers: { "X-Line-Retry-Key": m.id }, body: JSON.stringify({ to: m.to, messages: [{ type: "text", text: m.text }] }) });
      if (res.ok || res.status === 409) { results.push({ id: m.id, status: "sent", error: null }); sent++; }
      else if (res.status === 429) { stop = true; results.push({ id: m.id, status: "retry", error: "http_429" }); failed++; }
      else if (res.status >= 500) { results.push({ id: m.id, status: "retry", error: `http_${res.status}` }); failed++; }
      else { results.push({ id: m.id, status: "failed", error: `http_${res.status}` }); failed++; }
    }
    // 尚未嘗試的維持 sending，10 分鐘後由下一輪重新領取
    const { error: markErr } = await sb.rpc("notify_mark", { p_results: results.filter((r) => r.status !== "pending") });
    if (markErr) return { ok: false, error: "mark_failed", sent, failed };
    if (stop) break;
  }
  return { ok: true, sent, failed };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false }, 405);
  const raw = await req.text();

  // 1. LINE Webhook
  const sig = req.headers.get("x-line-signature");
  if (sig !== null) {
    if (!(await validSignature(raw, sig))) return json({ ok: false, error: "signature" }, 401);
    let body: { events?: Record<string, any>[] } = {};
    try { body = JSON.parse(raw); } catch { return json({ ok: true }); }
    const site = await siteUrl();
    for (const ev of body.events ?? []) {
      const uid = ev.source?.type === "user" ? ev.source.userId : null;
      if (!uid) continue;
      if (ev.type === "unfollow") { const { error } = await sb.rpc("line_unfollow", { p_user: uid }); if (error) return json({ ok: false }, 500); continue; }
      if (ev.type === "follow") {
        await reply(ev.replyToken, `歡迎加入沃克思！\n要收到錄取、上班前一天提醒和薪資單通知，請到薪資查詢網站登入 → 我的資料 → 綁定 LINE，再把 6 位數綁定碼傳給我。\n${site}`);
        continue;
      }
      if (ev.type === "message" && ev.message?.type === "text") {
        const m = String(ev.message.text).match(/\b(\d{6})\b/);
        if (m) {
          const { data, error } = await sb.rpc("line_bind", { p_code: m[1], p_user: uid });
          if (error) return json({ ok: false }, 500);
          await reply(ev.replyToken, data?.ok
            ? `綁定完成！${data.name}，之後錄取通知、上班前一天提醒和薪資單發布都會在這裡通知你。`
            : data?.error === "too_many"
            ? `嘗試次數太多，請一小時後再試。`
            : `綁定碼不正確或已過期（15 分鐘內有效），請到網站重新產生。\n${site}`);
        } else {
          await reply(ev.replyToken, `這個帳號負責發送排班與薪資通知，無法回覆訊息。有問題請直接聯絡活動負責人。\n薪資查詢：${site}`);
        }
      }
    }
    return json({ ok: true });
  }

  // 2. 系統呼叫
  let b: Record<string, unknown> = {};
  try { b = JSON.parse(raw); } catch { return json({ ok: false, error: "bad_request" }, 400); }
  const cronOk = (await sb.rpc("line_cron_ok", { p_token: req.headers.get("x-cron-token") ?? "" })).data === true;
  const { data: admin } = b.admin_token ? await sb.rpc("admin_actor", { p_token: String(b.admin_token) }) : { data: null };
  if (!cronOk && !admin) return json({ ok: false, error: "session" });

  if (b.action === "flush") return json(await flush());
  if (b.action === "status" && admin) {
    if (!SECRET || !TOKEN) return json({ ok: true, configured: false, has_secret: !!SECRET, has_token: !!TOKEN });
    const info = await line("/v2/bot/info");
    if (!info.ok) return json({ ok: true, configured: true, valid: false, error: `http_${info.status}` });
    const i = await info.json();
    const quota = await (await line("/v2/bot/message/quota")).json().catch(() => ({}));
    const used = await (await line("/v2/bot/message/quota/consumption")).json().catch(() => ({}));
    return json({ ok: true, configured: true, valid: true, basic_id: i.basicId, name: i.displayName, quota: quota.value ?? null, quota_type: quota.type, used: used.totalUsage ?? null });
  }
  return json({ ok: false, error: "bad_action" }, 400);
});
