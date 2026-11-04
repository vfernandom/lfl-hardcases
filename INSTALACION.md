# LFL Hardcase · Sistema de presupuestos con factura electrónica

Guía de instalación (≈ 30 min). Los nombres de los menús de Supabase y Yo-Facturo pueden variar un poco; si algo no coincide, buscá la opción más parecida.

> **Modo de facturación.** La app tiene dos modos (Catálogo → Parámetros → *Cómo se emite la factura*):
> - **Manual en e-Kuatia'i** (por defecto, el que usa LFL hoy): la app arma los datos para copiar, la factura se emite en la web de la DNIT y después se registra el número en la app. **No necesita la Parte A5 ni la Parte B.**
> - **Automática (e-Kuatia vía Yo-Facturo)**: la app emite sola. Requiere estar habilitado en **e-Kuatia** con certificado de un prestador cualificado (el CCFE gratuito de e-Kuatia'i no sirve). Ahí sí hacen falta A5 y B.

**Qué se usa**
- `sistema.html` → la app (se publica sola en GitHub Pages).
- `supabase/01_base.sql` → base de datos, usuarios y permisos.
- `supabase/functions/sifen/index.ts` → función de servidor que habla con Yo-Facturo.

> 🔒 **Nunca** pegues en la app, en GitHub ni en un chat: la clave de Yo-Facturo, la `service_role` de Supabase, el certificado ni el CSC. Solo van en los paneles de Supabase y Yo-Facturo.

---

## Parte A · Supabase (base de datos y servidor)

1. **Crear el proyecto**
   - Entrá a supabase.com → *Start your project* (podés ingresar con GitHub).
   - *New project*: nombre `lfl-presupuestos`, una contraseña de base de datos (guardala), región **South America (São Paulo)**, plan gratuito.
   - Esperá 1–2 min a que termine de crearse.

2. **Crear las tablas**
   - Menú izquierdo → **SQL Editor** → *New query*.
   - Abrí [01_base.sql](https://raw.githubusercontent.com/vfernandom/lfl-hardcases/main/supabase/01_base.sql), copiá **todo** y pegalo.
   - Tocá **Run**. Tiene que decir *Success*. Se puede volver a correr sin problema.

3. **Cerrar el registro público**
   - **Authentication** → *Sign In / Providers* (o *Settings*) → desactivá **Allow new users to sign up**.
   - **Authentication** → *URL Configuration* → **Site URL**: `https://vfernandom.github.io/lfl-hardcases/sistema.html` (sirve para “Olvidé mi contraseña”).

4. **Crear los usuarios**
   - **Authentication** → **Users** → *Add user* → *Create new user*.
   - Primero **vos** (email + contraseña, marcá *Auto Confirm User*). El primer usuario queda como **socio**.
   - Después los demás. Entran como **comercial**; los pasás a socio desde la app (*Catálogo → Usuarios*).

5. **Crear la función de facturación** *(solo modo automático)*
   - **Edge Functions** → *Deploy a new function* → *Via Editor*.
   - Nombre: **`sifen`** (exacto, en minúscula).
   - Borrá el ejemplo, abrí [index.ts](https://raw.githubusercontent.com/vfernandom/lfl-hardcases/main/supabase/functions/sifen/index.ts), copiá todo y pegalo → **Deploy**.
   - Dejá activado *Verify JWT* (viene así por defecto).

6. **Pasarme los datos públicos**
   - **Project Settings** → **API** (o *Data API*): copiá **Project URL** y la clave **anon / public**.
   - Mandámelas: son públicas por diseño. Las cargo en `sistema.html`.

## Parte B · Yo-Facturo (solo modo automático, requiere e-Kuatia)

1. Creá la cuenta en yo-facturo.com (tiene prueba de 15 días).
2. Cargá los **datos fiscales de LFL**: RUC y DV, timbrado electrónico con sus fechas, establecimiento, punto de expedición, dirección y ciudad. Dejá el ambiente en **prueba (test)**.
3. Subí el **certificado digital (.p12/.pfx)** y el **CSC** del ambiente de prueba. Si no tenés el CSC de prueba, consultalo con Yo-Facturo o el contador.
4. Creá una **clave de API** que empiece con `yf_live_` con permisos de facturas (lectura y escritura).
   - Ojo: las claves `yf_test_` son un sandbox que **no** envía nada a SIFEN. Para probar contra SIFEN de verdad (sin valor fiscal) se usa `yf_live_` con el contribuyente en ambiente *test*.
5. Volvé a Supabase → **Edge Functions** → **Secrets** (o *Project Settings → Edge Functions → Secrets*) → *Add new secret*:
   - Name: `YOFACTURO_API_KEY`
   - Value: la clave `yf_live_…`

## Parte C · Primera prueba

1. Entrá a **https://vfernandom.github.io/lfl-hardcases/sistema.html** con tu usuario.
2. **Catálogo → Parámetros**: completá **establecimiento** y **punto de expedición** (los mismos del timbrado), el IVA general y los costos reales → *Guardar*.
3. Creá un presupuesto con el **RUC** del cliente (sección “Datos para la factura”) → aprobalo → *Marcar como enviado* → *Venta confirmada*.
4. **Modo manual (e-Kuatia'i):** en el presupuesto tocá **Preparar factura** → revisá renglones e IVA → **Copiar datos** → **Abrir e-Kuatia'i** y emití la factura ahí → volvé y tocá **Ya la emití: registrar N°** con el número (001-001-0000123), la fecha y, si querés, el CDC.
5. **Modo automático:** tocá **Facturar** → **Emitir factura**. Tiene que aparecer **“Prueba · sin valor fiscal”** y, en unos segundos, **Aprobada por SIFEN**.
6. Las ventas sin factura aparecen en el **Tablero → Casos que necesitan seguimiento**.

## Pasar a producción

Cuando el contador valide las facturas de prueba (IVA, datos, numeración): en Yo-Facturo cambiá el ambiente a **producción** y cargá el CSC de producción. En la app no hay que cambiar nada.

## Antes de producción, confirmar con el contador
- Si los precios de los presupuestos se expresan **con o sin IVA** (hoy, si el IVA está en 0 en Parámetros, la app factura el precio como **IVA incluido**).
- La tasa de IVA de cada producto y de transporte/instalación.
- Establecimiento y punto de expedición correctos.

## Quién puede hacer qué
| Acción | Socio | Comercial |
|---|---|---|
| Crear presupuestos, seguimiento | ✅ | ✅ |
| Aprobar presupuestos | ✅ | — |
| Editar costos, materiales, productos | ✅ | — |
| Facturar y anular | ✅ | — |
| Cambiar roles | ✅ | — |
