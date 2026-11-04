-- =====================================================================
-- LFL Hardcase · Sistema de presupuestos + facturación SIFEN
-- Pegar COMPLETO en Supabase → SQL Editor → Run (una sola vez).
-- =====================================================================

-- ---------- Perfiles y roles ----------
create table if not exists public.perfiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  nombre     text not null default '',
  rol        text not null default 'comercial' check (rol in ('socio','comercial')),
  created_at timestamptz not null default now()
);

-- ¿El usuario actual es socio?
create or replace function public.es_socio() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where user_id = auth.uid() and rol = 'socio');
$$;

-- Al crear un usuario se crea su perfil. El PRIMER usuario queda como socio.
create or replace function public.nuevo_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (user_id, nombre, rol)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email, '@', 1)),
    case when exists (select 1 from public.perfiles where rol = 'socio') then 'comercial' else 'socio' end
  )
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_nuevo_perfil on auth.users;
create trigger trg_nuevo_perfil after insert on auth.users
  for each row execute function public.nuevo_perfil();

-- Perfiles de usuarios que ya existían antes de correr este script
insert into public.perfiles (user_id, nombre)
select id, split_part(email, '@', 1) from auth.users
on conflict (user_id) do nothing;
update public.perfiles set rol = 'socio'
where user_id = (select user_id from public.perfiles order by created_at limit 1)
  and not exists (select 1 from public.perfiles where rol = 'socio');

alter table public.perfiles enable row level security;
drop policy if exists perfiles_leer on public.perfiles;
create policy perfiles_leer on public.perfiles for select to authenticated using (true);
drop policy if exists perfiles_editar on public.perfiles;
-- Cada uno edita su nombre; solo un socio cambia roles (ver trigger abajo).
create policy perfiles_editar on public.perfiles for update to authenticated
  using (user_id = auth.uid() or public.es_socio())
  with check (user_id = auth.uid() or public.es_socio());

create or replace function public.proteger_rol() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.rol is distinct from old.rol and not public.es_socio() then
    raise exception 'Solo un socio puede cambiar roles';
  end if;
  return new;
end $$;
drop trigger if exists trg_proteger_rol on public.perfiles;
create trigger trg_proteger_rol before update on public.perfiles
  for each row execute function public.proteger_rol();

-- ---------- Documentos de la app (parámetros, materiales, productos, presupuestos) ----------
create table if not exists public.docs (
  col        text not null check (col in ('config','materiales','productos','presupuestos')),
  id         text not null,
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (col, id)
);

alter table public.docs enable row level security;
drop policy if exists docs_leer on public.docs;
create policy docs_leer on public.docs for select to authenticated using (true);
drop policy if exists docs_presupuestos on public.docs;
drop policy if exists docs_presupuestos_ins on public.docs;
drop policy if exists docs_presupuestos_upd on public.docs;
drop policy if exists docs_presupuestos_del on public.docs;
create policy docs_presupuestos_ins on public.docs for insert to authenticated
  with check (col = 'presupuestos');
create policy docs_presupuestos_upd on public.docs for update to authenticated
  using (col = 'presupuestos') with check (col = 'presupuestos');
create policy docs_presupuestos_del on public.docs for delete to authenticated
  using (col = 'presupuestos' and public.es_socio());
drop policy if exists docs_catalogo on public.docs;
create policy docs_catalogo on public.docs for all to authenticated
  using (col in ('config','materiales','productos') and public.es_socio())
  with check (col in ('config','materiales','productos') and public.es_socio());

create or replace function public.tocar_docs() returns trigger language plpgsql as $$
begin new.updated_at := now(); new.updated_by := auth.uid(); return new; end $$;
drop trigger if exists trg_tocar_docs on public.docs;
create trigger trg_tocar_docs before insert or update on public.docs
  for each row execute function public.tocar_docs();

-- ---------- Numeración de presupuestos LFL-001, LFL-002… ----------
create sequence if not exists public.presupuesto_seq start 1;
create or replace function public.siguiente_numero() returns text
language sql volatile security definer set search_path = public as $$
  select 'LFL-' || lpad(nextval('public.presupuesto_seq')::text, 3, '0');
$$;
revoke all on function public.siguiente_numero() from public, anon;
grant execute on function public.siguiente_numero() to authenticated;

-- ---------- Facturas electrónicas (solo las escribe la función de servidor) ----------
create table if not exists public.facturas (
  id               uuid primary key default gen_random_uuid(),
  presupuesto_id   text not null,
  intento          int  not null default 1,
  client_reference text not null unique,
  cdc              text unique,
  numero           text,
  estado           text not null default 'pendiente',   -- signed / approved / approved_obs / rejected / unknown / cancelled / error
  ambiente         text,                                  -- test / prod (lo informa Yo-Facturo)
  total            numeric,
  receptor         jsonb,
  items            jsonb,
  condicion        text,
  mensajes         jsonb not null default '[]'::jsonb,   -- mensajes de SIFEN
  qr_url           text,
  anulacion        jsonb,
  respuesta        jsonb,                                 -- última respuesta cruda del proveedor
  creado_por       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists facturas_presupuesto_idx on public.facturas (presupuesto_id);

alter table public.facturas enable row level security;
drop policy if exists facturas_leer on public.facturas;
create policy facturas_leer on public.facturas for select to authenticated using (true);
-- Sin políticas de escritura: solo la función de servidor (service role) inserta/actualiza.

-- ---------- Tiempo real ----------
do $$ begin
  begin alter publication supabase_realtime add table public.docs; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.facturas; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.perfiles; exception when duplicate_object then null; end;
end $$;

-- ---------- Datos iniciales de EJEMPLO (reemplazar desde la app) ----------
insert into public.docs (col, id, data) values
('config','params', '{
  "ejemplo": true, "tarifaHora": 25000, "gastosMensuales": 6000000, "horasProductivasMes": 320,
  "desperdicioPct": 12, "margenObjetivo": 35, "margenMinimo": 25, "descuentoMax": 10, "redondeo": 1000,
  "ivaPct": 0, "validezDias": 15, "anticipoPct": 50, "plazoEntrega": "A confirmar", "seguimientoDias": 7,
  "establecimiento": "", "puntoExpedicion": "", "ivaDefecto": 10,
  "motivosPerdida": ["Precio","Plazo de entrega","Competencia","Sin respuesta del cliente","Cambió la necesidad","Otro"]
}'::jsonb),
('materiales','m-placa',     '{"nombre":"Placa fenólico 9 mm","rol":"placa","unidad":"m²","precio":95000,"proveedor":"","ejemplo":true}'::jsonb),
('materiales','m-perfil',    '{"nombre":"Perfil aluminio unión","rol":"perfil","unidad":"m","precio":28000,"proveedor":"","ejemplo":true}'::jsonb),
('materiales','m-espuma',    '{"nombre":"Espuma 10 mm","rol":"espuma","unidad":"m²","precio":40000,"proveedor":"","ejemplo":true}'::jsonb),
('materiales','m-cierre',    '{"nombre":"Cierre mariposa","rol":"cierre","unidad":"unidad","precio":35000,"proveedor":"","ejemplo":true}'::jsonb),
('materiales','m-manija',    '{"nombre":"Manija retráctil","rol":"manija","unidad":"unidad","precio":30000,"proveedor":"","ejemplo":true}'::jsonb),
('materiales','m-bisagra',   '{"nombre":"Bisagra","rol":"bisagra","unidad":"unidad","precio":15000,"proveedor":"","ejemplo":true}'::jsonb),
('materiales','m-esquinero', '{"nombre":"Esquinero bola","rol":"esquinero","unidad":"unidad","precio":9000,"proveedor":"","ejemplo":true}'::jsonb),
('materiales','m-consumible','{"nombre":"Remaches y consumibles (kit)","rol":"consumible","unidad":"kit","precio":15000,"proveedor":"","ejemplo":true}'::jsonb)
on conflict (col, id) do nothing;
