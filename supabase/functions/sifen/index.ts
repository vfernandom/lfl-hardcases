// =====================================================================
// LFL Hardcase · Función de servidor "sifen"
// Emite, consulta, anula y comparte facturas electrónicas vía Yo-Facturo.
// La clave de Yo-Facturo vive SOLO acá, como secreto YOFACTURO_API_KEY.
// Supabase provee automáticamente SUPABASE_URL, SUPABASE_ANON_KEY y SUPABASE_SERVICE_ROLE_KEY.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const YF_BASE = (Deno.env.get("YOFACTURO_BASE_URL") || "https://api.yo-facturo.com/api/v1").replace(/\/$/, "");
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const ACTIVOS = ["pendiente", "signed", "approved", "approved_obs", "unknown"];

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
class Fallo extends Error { constructor(msg: string, public status = 400) { super(msg); } }

// ---------- validaciones (sin red) ----------
export function validarEmision(body: any) {
  const errores: string[] = [];
  const r = body?.receptor || {};
  if (!["ruc", "ci", "none"].includes(r.document_type)) errores.push("Tipo de documento del cliente inválido (ruc, ci o none).");
  if (r.document_type !== "none" && !String(r.document_number || "").trim()) errores.push("Falta el RUC o la cédula del cliente.");
  if (r.document_type === "ruc" && !/^\d{3,9}-\d$/.test(String(r.document_number || "").trim())) errores.push("El RUC debe tener el formato 80012345-6 (con dígito verificador).");
  if (!String(r.name || "").trim()) errores.push("Falta la razón social / nombre del cliente.");
  const items = Array.isArray(body?.items) ? body.items : [];
  if (!items.length) errores.push("La factura no tiene renglones.");
  if (items.length > 50) errores.push("Máximo 50 renglones por factura.");
  items.forEach((it: any, i: number) => {
    const n = i + 1;
    if (!String(it.descripcion || "").trim()) errores.push(`Renglón ${n}: falta la descripción.`);
    if (!(Number(it.cantidad) > 0)) errores.push(`Renglón ${n}: cantidad inválida.`);
    if (!(Number.isInteger(Number(it.importe)) && Number(it.importe) > 0)) errores.push(`Renglón ${n}: el importe debe ser un número entero de guaraníes mayor a 0.`);
    if (![10, 5, 0].includes(Number(it.tasa_iva))) errores.push(`Renglón ${n}: la tasa de IVA debe ser 10, 5 o 0.`);
  });
  if (!["contado", "credito"].includes(body?.condicion)) errores.push("Condición de venta inválida.");
  if (body?.condicion === "credito") {
    const p = Number(body?.plazo_dias);
    if (!(Number.isInteger(p) && p >= 1 && p <= 365)) errores.push("Plazo de crédito: entre 1 y 365 días.");
  }
  const total = items.reduce((s: number, it: any) => s + (Number(it.importe) || 0), 0);
  if (r.document_type === "none" && total >= 60000000) errores.push("Un cliente sin identificar solo se admite por menos de ₲ 60.000.000.");
  return { errores, total };
}

export function armarPayload(body: any, params: any, clientReference: string) {
  const r = body.receptor;
  const p: Record<string, unknown> = {
    tipo_de: 1,
    receptor: {
      document_type: r.document_type,
      ...(r.document_type !== "none" ? { document_number: String(r.document_number).trim() } : {}),
      name: String(r.name).trim(),
      ...(r.email ? { email: String(r.email).trim() } : {}),
    },
    items: body.items.map((it: any) => ({
      descripcion: String(it.descripcion).trim().slice(0, 500),
      cantidad: Number(it.cantidad),
      importe: Math.round(Number(it.importe)),
      tasa_iva: Number(it.tasa_iva),
    })),
    condicion: body.condicion,
    establecimiento: String(params.establecimiento).padStart(3, "0"),
    punto_expedicion: String(params.puntoExpedicion).padStart(3, "0"),
    client_reference: clientReference.slice(0, 64),
  };
  if (body.condicion === "credito") p.plazo_dias = Number(body.plazo_dias);
  return p;
}

// ---------- Yo-Facturo ----------
async function yf(method: string, path: string, body?: unknown, idem?: string) {
  const key = Deno.env.get("YOFACTURO_API_KEY");
  if (!key) throw new Fallo("Falta configurar el secreto YOFACTURO_API_KEY en Supabase.", 500);
  const headers: Record<string, string> = { "X-API-Key": key, "Content-Type": "application/json", Accept: "application/json" };
  if (idem) headers["Idempotency-Key"] = idem;
  let res: Response;
  try {
    res = await fetch(YF_BASE + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  } catch (e) {
    throw new Fallo("No se pudo conectar con Yo-Facturo: " + (e as Error).message, 502);
  }
  const text = await res.text();
  let j: any = null; try { j = JSON.parse(text); } catch { j = { raw: text }; }
  return { ok: res.ok, status: res.status, body: j, data: j?.data ?? j };
}
function mensajeError(r: { status: number; body: any }) {
  const b = r.body || {};
  const m = b.error?.message || b.error || b.detail || b.message || (Array.isArray(b.errors) ? b.errors.map((e: any) => e.message || e).join("; ") : "") || b.raw;
  return `Yo-Facturo respondió ${r.status}${m ? ": " + (typeof m === "string" ? m : JSON.stringify(m)) : ""}`;
}

// ---------- servidor ----------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Método no permitido" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const authHeader = req.headers.get("Authorization") || "";
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: authHeader } } });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) throw new Fallo("Sesión inválida. Volvé a ingresar.", 401);
    const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: perfil } = await db.from("perfiles").select("rol,nombre").eq("user_id", user.id).maybeSingle();
    if (perfil?.rol !== "socio") throw new Fallo("Solo un socio puede emitir o anular facturas.", 403);

    const body = await req.json().catch(() => ({}));
    const accion = body.accion;

    const leerPresupuesto = async (id: string) => {
      const { data } = await db.from("docs").select("data").eq("col", "presupuestos").eq("id", id).maybeSingle();
      if (!data) throw new Fallo("No existe el presupuesto " + id, 404);
      return data.data as any;
    };
    const resumir = async (f: any, texto?: string) => {
      const pres = await leerPresupuesto(f.presupuesto_id);
      pres.factura = { id: f.id, cdc: f.cdc, numero: f.numero, estado: f.estado, ambiente: f.ambiente, total: f.total, at: new Date().toISOString() };
      pres.actualizado = new Date().toISOString();
      if (texto) pres.historial = [...(pres.historial || []), { fecha: new Date().toISOString(), por: user.id, texto }];
      await db.from("docs").update({ data: pres }).eq("col", "presupuestos").eq("id", f.presupuesto_id);
    };
    const leerFactura = async (id: string) => {
      const { data } = await db.from("facturas").select("*").eq("id", id).maybeSingle();
      if (!data) throw new Fallo("No existe la factura", 404);
      return data;
    };
    const refrescar = async (f: any) => {
      if (!f.cdc) return f;
      const r = await yf("GET", `/bill/sifen/documents/${f.cdc}/`);
      if (!r.ok) throw new Fallo(mensajeError(r), 502);
      const d = r.data || {};
      // Si se anuló con nota de crédito, la FE sigue "approved" en SIFEN pero para LFL queda compensada.
      const estado = f.anulacion?.accion === "nce" && (d.status === "approved" || d.status === "approved_obs") ? "nc" : (d.status || f.estado);
      const upd = { estado, numero: d.number || f.numero, ambiente: d.environment || f.ambiente,
        mensajes: d.sifen_messages || f.mensajes, respuesta: r.body, updated_at: new Date().toISOString() };
      const { data } = await db.from("facturas").update(upd).eq("id", f.id).select().single();
      return data;
    };

    if (accion === "emitir") {
      const { errores, total } = validarEmision(body);
      if (errores.length) return json({ ok: false, error: errores.join(" ") }, 400);
      const pres = await leerPresupuesto(body.presupuesto_id);
      if (pres.estado !== "venta") throw new Fallo("Solo se factura un presupuesto en estado “Venta confirmada”.");
      const { data: previas } = await db.from("facturas").select("id,estado,intento").eq("presupuesto_id", body.presupuesto_id);
      if ((previas || []).some((f: any) => ACTIVOS.includes(f.estado))) throw new Fallo("Este presupuesto ya tiene una factura vigente o en proceso. Anulala antes de emitir otra.", 409);
      const { data: cfg } = await db.from("docs").select("data").eq("col", "config").eq("id", "params").maybeSingle();
      const params = cfg?.data || {};
      if (!/^\d{1,3}$/.test(String(params.establecimiento || "")) || !/^\d{1,3}$/.test(String(params.puntoExpedicion || "")))
        throw new Fallo("Configurá el establecimiento y el punto de expedición en Catálogo → Parámetros.");
      const intento = (previas || []).reduce((m: number, f: any) => Math.max(m, f.intento || 0), 0) + 1;
      const ref = `${pres.numero || body.presupuesto_id}-F${intento}`;
      const payload = armarPayload(body, params, ref);
      const { data: fila, error: eIns } = await db.from("facturas").insert({
        presupuesto_id: body.presupuesto_id, intento, client_reference: ref, estado: "pendiente", total,
        receptor: payload.receptor, items: payload.items, condicion: body.condicion, creado_por: user.id,
      }).select().single();
      if (eIns) throw new Fallo("No se pudo registrar la factura: " + eIns.message, 500);

      const r = await yf("POST", "/bill/sifen/documents/", payload, ref);
      let f;
      if (r.ok) {
        const d = r.data || {};
        ({ data: f } = await db.from("facturas").update({ cdc: d.cdc || null, numero: d.number || null, estado: d.status || "signed",
          ambiente: d.environment || null, total: Number(d.total) || total, qr_url: d.qr_url || null, respuesta: r.body,
          updated_at: new Date().toISOString() }).eq("id", fila.id).select().single());
        await resumir(f, `Factura enviada a SIFEN${f.numero ? " N° " + f.numero : ""} (${f.estado}${f.ambiente === "test" ? ", ambiente de PRUEBA" : ""})`);
        return json({ ok: true, factura: f });
      }
      const msg = mensajeError(r);
      ({ data: f } = await db.from("facturas").update({ estado: "error", mensajes: [{ kind: "proveedor", message: msg, at: new Date().toISOString() }],
        respuesta: r.body, updated_at: new Date().toISOString() }).eq("id", fila.id).select().single());
      await resumir(f, "Error al emitir factura: " + msg);
      return json({ ok: false, error: msg, factura: f }, 502);
    }

    if (accion === "estado") {
      const antes = await leerFactura(body.factura_id);
      const f = await refrescar(antes);
      if (f.estado !== antes.estado) {
        const txt = { approved: "Factura APROBADA por SIFEN", approved_obs: "Factura aprobada con observación", rejected: "Factura RECHAZADA por SIFEN", cancelled: "Factura anulada" }[f.estado as string] || `Factura: ${f.estado}`;
        await resumir(f, `${txt}${f.numero ? " · N° " + f.numero : ""}`);
      } else await resumir(f);
      return json({ ok: true, factura: f });
    }

    if (accion === "anular") {
      const reason = String(body.motivo || "").trim();
      if (reason.length < 5 || reason.length > 500) throw new Fallo("El motivo de anulación debe tener entre 5 y 500 caracteres.");
      const f0 = await leerFactura(body.factura_id);
      if (!f0.cdc) throw new Fallo("La factura no tiene CDC: no llegó a SIFEN, no hace falta anularla.");
      const r = await yf("POST", `/bill/sifen/documents/${f0.cdc}/void/`, { reason }, `void-${f0.id}`);
      if (!r.ok) throw new Fallo(mensajeError(r), 502);
      const accionYF = r.data?.action || "";
      await db.from("facturas").update({ anulacion: { accion: accionYF, motivo: reason, por: user.id, at: new Date().toISOString(), respuesta: r.body } }).eq("id", f0.id);
      let f = await refrescar({ ...f0, anulacion: { accion: accionYF } });
      const anulacion = { accion: accionYF, motivo: reason, por: user.id, at: new Date().toISOString(), respuesta: r.body };
      if (accionYF === "cancelacion" || accionYF === "cancelled" || accionYF === "inutilizacion") {
        if (f.estado !== "cancelled") ({ data: f } = await db.from("facturas").update({ estado: "cancelled" }).eq("id", f0.id).select().single());
      } else if (accionYF === "nce") {
        ({ data: f } = await db.from("facturas").update({ estado: "nc", anulacion }).eq("id", f0.id).select().single());
      }
      const det = { cancelacion: "cancelación", nce: "nota de crédito electrónica", inutilizacion: "inutilización", cancelled: "cancelación" }[accionYF as string] || accionYF;
      await resumir(f, `Anulación solicitada (${det}): ${reason}`);
      return json({ ok: true, factura: f, accion: accionYF });
    }

    if (accion === "link") {
      const f = await leerFactura(body.factura_id);
      if (!f.cdc) throw new Fallo("La factura no tiene CDC todavía.");
      const r = await yf("POST", `/bill/sifen/documents/${f.cdc}/public-link/`, { expires_in_seconds: 2592000 });
      if (!r.ok) throw new Fallo(mensajeError(r), 502);
      const d = r.data || {};
      return json({ ok: true, url: d.url || d.public_url || d.link || d.web_url || null, datos: d });
    }

    throw new Fallo("Acción desconocida");
  } catch (e) {
    const st = e instanceof Fallo ? e.status : 500;
    return json({ ok: false, error: (e as Error).message || "Error interno" }, st);
  }
});
