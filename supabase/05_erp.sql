-- =====================================================================
-- LFL Hardcase · Órdenes de trabajo, stock por movimientos y cierre de mes
-- Pegar en Supabase → SQL Editor → Run. Se puede volver a correr.
-- El aviso "destructive operations" es por los "drop ... if exists": no borra datos.
-- =====================================================================

-- 1) Nuevas colecciones: órdenes de trabajo (ots) y movimientos de stock (stockmovs)
alter table public.docs drop constraint if exists docs_col_check;
alter table public.docs add constraint docs_col_check check (col in (
  'config','materiales','productos','presupuestos','clientes',
  'plan','fondos','proveedores','compras','ordenes','movimientos','asientos','stockajustes',
  'ots','stockmovs'));

drop policy if exists docs_prod_ins on public.docs;
drop policy if exists docs_prod_upd on public.docs;
create policy docs_prod_ins on public.docs for insert to authenticated with check (col in ('ots','stockmovs'));
create policy docs_prod_upd on public.docs for update to authenticated using (col in ('ots','stockmovs')) with check (col in ('ots','stockmovs'));
-- Borrar: solo administradores (política docs_admin_del de 04_permisos.sql).

-- 2) Numeración de órdenes de trabajo OT-0001…
create sequence if not exists public.ot_seq start 1;
create or replace function public.siguiente_ot() returns text
language sql volatile security definer set search_path = public as $$
  select 'OT-' || lpad(nextval('public.ot_seq')::text, 4, '0');
$$;
revoke all on function public.siguiente_ot() from public, anon;
grant execute on function public.siguiente_ot() to authenticated;

-- 3) Cierre de mes: config/cierres guarda {"meses": ["2026-10", ...]}
create or replace function public.mes_cerrado(f text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(f, '') <> '' and exists (
    select 1 from public.docs where col = 'config' and id = 'cierres' and (data->'meses') ? left(f, 7));
$$;

create or replace function public.control_cierre() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cols text[] := array['movimientos','compras','asientos','stockajustes','stockmovs'];
  quitados int;
begin
  if current_setting('lfl.sistema', true) = '1' then return coalesce(new, old); end if;
  -- Reabrir un mes: solo administradores
  if tg_op = 'UPDATE' and new.col = 'config' and new.id = 'cierres' then
    select count(*) into quitados from jsonb_array_elements_text(coalesce(old.data->'meses','[]'::jsonb)) m
      where not (coalesce(new.data->'meses','[]'::jsonb) ? m);
    if quitados > 0 and not public.es_admin() then raise exception 'Solo un administrador puede reabrir un mes cerrado'; end if;
  end if;
  if tg_op in ('UPDATE','DELETE') and old.col = any(cols) and public.mes_cerrado(old.data->>'fecha') then
    raise exception 'El mes % está cerrado: no se puede modificar ni borrar. Registrá un ajuste en un mes abierto.', left(old.data->>'fecha', 7);
  end if;
  if tg_op in ('INSERT','UPDATE') and new.col = any(cols) and public.mes_cerrado(new.data->>'fecha') then
    raise exception 'El mes % está cerrado: no se pueden cargar movimientos con esa fecha.', left(new.data->>'fecha', 7);
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists trg_control_cierre on public.docs;
create trigger trg_control_cierre before insert or update or delete on public.docs
  for each row execute function public.control_cierre();
