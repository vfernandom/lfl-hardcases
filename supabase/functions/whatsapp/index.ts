// =====================================================================
// LFL Hardcase · Función de servidor "whatsapp" (WhatsApp Cloud API de Meta)
//  - GET  : verificación del webhook (Meta llama una vez al configurarlo)
//  - POST de Meta : mensajes entrantes y estados de entrega (firma X-Hub-Signature-256)
//  - POST de la app : enviar texto o un PDF a un cliente (requiere sesión de LFL Gestión)
// Secretos (Supabase → Edge Functions → Secrets). NUNCA en la app ni en GitHub:
//   WA_TOKEN         token permanente del usuario del sistema de Meta
//   WA_PHONE_ID      Phone Number ID del número de LFL
//   WA_APP_SECRET    "Clave secreta de la app" (Configuración básica de la app de Meta)
//   WA_VERIFY_TOKEN  una palabra cualquiera que también se carga en el webhook de Meta
//   WA_GRAPH_VERSION opcional, por defecto v23.0
// Se despliega SIN verificación de JWT (Meta no manda sesión): la función valida
// la firma de Meta o la sesión del usuario según quién llama.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
class Fallo extends Error { constructor(msg: string, public status = 400) { super(msg); } }
const env = (k: string, d = "") => Deno.env.get(k) || d;
const GRAPH = () => `https://graph.facebook.com/${env("WA_GRAPH_VERSION", "v23.0")}`;
const VENTANA_MS = 24 * 3600 * 1000;

// ---------- utilidades puras (testeables) ----------
export function normTel(t: string): string {
  let d = String(t || "").replace(/\D/g, "");
  if (d.startsWith("00")) d = d.slice(2);
  if (d.startsWith("0")) d = "595" + d.slice(1);
  if (/^9\d{8}$/.test(d)) d = "595" + d;
  return d;
}
export function textoDeMensaje(m: any): string {
  switch (m?.type) {
    case "text": return m.text?.body || "";
    case "image": return "[Imagen] " + (m.image?.caption || "");
    case "document": return "[Documento] " + (m.document?.filename || "") + (m.document?.caption ? " · " + m.document.caption : "");
    case "audio": return "[Audio]";
    case "video": return "[Video] " + (m.video?.caption || "");
    case "location": return `[Ubicación] ${m.location?.latitude},${m.location?.longitude}`;
    case "button": return m.button?.text || "[Botón]";
    case "interactive": return m.interactive?.button_reply?.title || m.interactive?.list_reply?.title || "[Respuesta]";
    default: return `[${m?.type || "mensaje"}]`;
  }
}
export async function firmaValida(cuerpo: string, firma: string | null, secreto: string): Promise<boolean> {
  if (!firma || !secreto || !firma.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secreto), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(cuerpo)));
  const hex = [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
  const dada = firma.slice(7);
  if (hex.length !== dada.length) return false;
  let r = 0; for (let i = 0; i < hex.length; i++) r |= hex.charCodeAt(i) ^ dada.charCodeAt(i);
  return r === 0;
}

// ---------- llamadas a Meta ----------
async function meta(path: string, init: RequestInit) {
  const r = await fetch(`${GRAPH()}/${path}`, { ...init, headers: { Authorization: `Bearer ${env("WA_TOKEN")}`, ...(init.headers || {}) } });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Fallo("WhatsApp respondió: " + (j?.error?.error_user_msg || j?.error?.message || r.status), 502);
  return j;
}
async function subirPDF(base64: string, nombre: string): Promise<string> {
  const bytes = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  if (bytes.length > 15 * 1024 * 1024) throw new Fallo("El PDF supera el tamaño permitido.");
  const fd = new FormData();
  fd.append("messaging_product", "whatsapp");
  fd.append("type", "application/pdf");
  fd.append("file", new Blob([bytes], { type: "application/pdf" }), nombre);
  const j = await meta(`${env("WA_PHONE_ID")}/media`, { method: "POST", body: fd });
  return j.id;
}
const enviar = (payload: unknown) => meta(`${env("WA_PHONE_ID")}/messages`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ messaging_product: "whatsapp", ...payload as object }) });

// ---------- base de datos ----------
const ahora = () => new Date().toISOString();
async function leer(db: any, col: string, id: string) { const { data } = await db.from("docs").select("data").eq("col", col).eq("id", id).maybeSingle(); return data?.data || null; }
async function guardar(db: any, col: string, id: string, data: unknown) { const { error } = await db.from("docs").upsert({ col, id, data }, { onConflict: "col,id" }); if (error) throw new Fallo("Base de datos: " + error.message, 500); }
async function params(db: any) { return (await leer(db, "config", "params")) || {}; }

async function registrarEntrante(db: any, value: any) {
  const P = await params(db);
  const nombres: Record<string, string> = {};
  (value.contacts || []).forEach((c: any) => nombres[c.wa_id] = c.profile?.name || "");
  for (const m of value.messages || []) {
    const tel = normTel(m.from); const chatId = "wa-" + tel; const at = new Date(Number(m.timestamp) * 1000 || Date.now()).toISOString();
    await guardar(db, "wamsgs", "wm-" + m.id, { tel, dir: "in", tipo: m.type, texto: textoDeMensaje(m), waId: m.id, at });
    const chat = (await leer(db, "wachats", chatId)) || { tel, creado: at, noLeidos: 0 };
    const nuevaVentana = !chat.ultimoEntrante || (Date.parse(at) - Date.parse(chat.ultimoEntrante)) > 12 * 3600 * 1000;
    Object.assign(chat, { nombre: chat.nombre || nombres[m.from] || "", ultimo: at, ultimoEntrante: at, ultimoTexto: textoDeMensaje(m).slice(0, 140), noLeidos: (chat.noLeidos || 0) + 1 });
    await guardar(db, "wachats", chatId, chat);
    const auto = String(P.waAutoRespuesta || "").trim();
    if (auto && P.waActivo && nuevaVentana) {
      try { const r = await enviar({ to: tel, type: "text", text: { body: auto } });
        await guardar(db, "wamsgs", "wm-" + r.messages?.[0]?.id, { tel, dir: "out", tipo: "text", texto: auto, waId: r.messages?.[0]?.id, estado: "sent", at: ahora(), auto: true }); } catch (_) { /* la respuesta automática nunca frena la recepción */ }
    }
  }
  for (const s of value.statuses || []) {
    const id = "wm-" + s.id; const d = await leer(db, "wamsgs", id); if (!d) continue;
    const orden = ["sent", "delivered", "read"]; if (s.status === "failed" || orden.indexOf(s.status) > orden.indexOf(d.estado || "")) {
      d.estado = s.status; if (s.status === "failed") d.error = s.errors?.[0]?.title || s.errors?.[0]?.message || "falló";
      await guardar(db, "wamsgs", id, d);
    }
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });

  // 1) verificación del webhook
  if (req.method === "GET") {
    if (url.searchParams.get("hub.mode") === "subscribe" && env("WA_VERIFY_TOKEN") && url.searchParams.get("hub.verify_token") === env("WA_VERIFY_TOKEN"))
      return new Response(url.searchParams.get("hub.challenge") || "", { status: 200 });
    return new Response("forbidden", { status: 403 });
  }
  if (req.method !== "POST") return json({ ok: false, error: "Método no permitido" }, 405);

  const cuerpo = await req.text();
  // 2) eventos de Meta
  const firma = req.headers.get("x-hub-signature-256");
  if (firma) {
    if (!(await firmaValida(cuerpo, firma, env("WA_APP_SECRET")))) return new Response("firma inválida", { status: 401 });
    try { const b = JSON.parse(cuerpo); for (const e of b.entry || []) for (const c of e.changes || []) if (c.field === "messages") await registrarEntrante(db, c.value || {}); }
    catch (e) { console.error("webhook", e); }
    return new Response("ok", { status: 200 }); // siempre 200 para que Meta no reintente en bucle
  }

  // 3) pedidos de la app (sesión de LFL Gestión)
  try {
    const asUser = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: req.headers.get("Authorization") || "" } } });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) throw new Fallo("Sesión inválida. Volvé a ingresar.", 401);
    if (!env("WA_TOKEN") || !env("WA_PHONE_ID")) throw new Fallo("WhatsApp todavía no está configurado en el servidor (faltan WA_TOKEN / WA_PHONE_ID).", 503);
    const b = JSON.parse(cuerpo || "{}");
    const tel = normTel(b.tel);
    if (!/^\d{10,15}$/.test(tel)) throw new Fallo("Número de WhatsApp inválido. Usá el formato 595981…");
    const chatId = "wa-" + tel;
    const chat = (await leer(db, "wachats", chatId)) || { tel, nombre: b.nombre || "", creado: ahora(), noLeidos: 0 };
    const abierta = chat.ultimoEntrante && (Date.now() - Date.parse(chat.ultimoEntrante)) < VENTANA_MS;
    const P = await params(db);
    let r: any, registro: any;

    if (b.accion === "texto") {
      const texto = String(b.texto || "").trim(); if (!texto) throw new Fallo("Mensaje vacío.");
      if (!abierta) throw new Fallo("Pasaron más de 24 h desde el último mensaje del cliente: WhatsApp solo permite enviar una plantilla aprobada (por ejemplo, un documento).");
      r = await enviar({ to: tel, type: "text", text: { body: texto.slice(0, 4000) } });
      registro = { tipo: "text", texto };
    } else if (b.accion === "documento") {
      const nombre = String(b.nombreArchivo || "documento.pdf").replace(/[^\w.\-]/g, "_");
      const mediaId = await subirPDF(String(b.pdf || ""), nombre);
      const leyenda = String(b.leyenda || "").slice(0, 900);
      if (abierta) r = await enviar({ to: tel, type: "document", document: { id: mediaId, filename: nombre, caption: leyenda } });
      else {
        const plantilla = String(P.waPlantillaDoc || "documento_lfl");
        r = await enviar({ to: tel, type: "template", template: { name: plantilla, language: { code: P.waPlantillaIdioma || "es" }, components: [
          { type: "header", parameters: [{ type: "document", document: { id: mediaId, filename: nombre } }] },
          { type: "body", parameters: [{ type: "text", text: String(b.nombre || chat.nombre || "cliente").slice(0, 60) }, { type: "text", text: String(b.descripcion || nombre).slice(0, 120) }] }] } });
      }
      registro = { tipo: "document", texto: `[Documento] ${nombre}${leyenda ? " · " + leyenda : ""}`, plantilla: !abierta };
    } else throw new Fallo("Acción desconocida.");

    const waId = r?.messages?.[0]?.id || crypto.randomUUID();
    await guardar(db, "wamsgs", "wm-" + waId, { tel, dir: "out", ...registro, waId, estado: "sent", at: ahora(), por: user.id, ref: b.ref || null });
    Object.assign(chat, { nombre: chat.nombre || b.nombre || "", ultimo: ahora(), ultimoTexto: registro.texto.slice(0, 140), clienteId: chat.clienteId || b.clienteId || null });
    await guardar(db, "wachats", chatId, chat);
    return json({ ok: true, id: waId, plantilla: !!registro.plantilla });
  } catch (e) {
    const f = e instanceof Fallo ? e : new Fallo(String((e as Error)?.message || e), 500);
    return json({ ok: false, error: f.message }, f.status);
  }
});
