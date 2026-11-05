-- =====================================================================
-- LFL Hardcase · Permisos: ADMINISTRADOR (elimina registros) y APRUEBA ÓRDENES DE PAGO
-- Pegar en Supabase → SQL Editor → Run. Se puede volver a correr.
-- El aviso "destructive operations" es por los "drop ... if exists": no borra datos.
-- =====================================================================

-- 1) Nuevos permisos por usuario
alter table public.perfiles add column if not exists admin boolean not null default false;
alter table public.perfiles add column if not exists aprueba_op boolean not null default false;

-- El primer socio creado (Fer) queda como administrador y aprobador si todavía no hay ninguno.
update public.perfiles set admin = true, aprueba_op = true
where user_id = (select user_id from public.perfiles where rol = 'socio' order by created_at limit 1)
  and not exists (select 1 from public.perfiles where admin);

create or replace function public.es_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where user_id = auth.uid() and admin);
$$;
create or replace function public.puede_aprobar_op() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where user_id = auth.uid() and aprueba_op and rol = 'socio');
$$;

-- 2) Solo un administrador cambia permisos; nunca puede quedar el sistema sin administrador.
create or replace function public.proteger_rol() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.rol is distinct from old.rol and not public.es_socio() then
    raise exception 'Solo un socio puede cambiar roles';
  end if;
  if (new.admin is distinct from old.admin or new.aprueba_op is distinct from old.aprueba_op) and not public.es_admin() then
    raise exception 'Solo un administrador puede cambiar los permisos';
  end if;
  if old.admin and not new.admin and not exists (select 1 from public.perfiles where admin and user_id <> old.user_id) then
    raise exception 'Tiene que quedar al menos un administrador';
  end if;
  if new.rol <> 'socio' then new.aprueba_op := false; end if;  -- aprobar OP es solo para socios
  return new;
end $$;

-- 3) Eliminar: solo administradores (en cualquier colección y en facturas).
--    Los socios siguen gestionando el catálogo (materiales, productos, parámetros).
drop policy if exists docs_presupuestos_del on public.docs;
drop policy if exists docs_clientes_del on public.docs;
drop policy if exists docs_fin_del on public.docs;
drop policy if exists docs_admin_del on public.docs;
create policy docs_admin_del on public.docs for delete to authenticated using (public.es_admin());
drop policy if exists facturas_admin_del on public.facturas;
create policy facturas_admin_del on public.facturas for delete to authenticated using (public.es_admin());

-- 4) Aprobar o rechazar órdenes de pago: solo socios con el permiso "aprueba_op".
create or replace function public.control_finanzas() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  socio boolean := public.es_socio();
  e_new text; e_old text; op jsonb;
begin
  if current_setting('lfl.sistema', true) = '1' then return new; end if;

  if new.col = 'ordenes' then
    e_new := new.data->>'estado';
    if e_new not in ('pendiente','aprobada','rechazada','pagada','anulada') then
      raise exception 'Estado de orden de pago inválido';
    end if;
    if tg_op = 'INSERT' then
      if e_new <> 'pendiente' then raise exception 'Una orden de pago nace pendiente de aprobación'; end if;
    else
      e_old := old.data->>'estado';
      if e_old in ('pagada','rechazada','anulada') and new.data is distinct from old.data then
        raise exception 'La orden de pago ya está cerrada (%): no se puede modificar', e_old;
      end if;
      if e_new in ('aprobada','rechazada') and e_old = 'pendiente' and not public.puede_aprobar_op() then
        raise exception 'No tenés permiso para aprobar o rechazar órdenes de pago';
      end if;
      if e_old <> 'pendiente' and (new.data->'monto' is distinct from old.data->'monto'
          or new.data->'beneficiario' is distinct from old.data->'beneficiario'
          or new.data->'destino' is distinct from old.data->'destino') then
        raise exception 'No se puede cambiar monto, beneficiario ni destino de una orden ya aprobada';
      end if;
      if e_old = 'aprobada' and e_new not in ('aprobada','pagada') and not public.puede_aprobar_op() then
        raise exception 'Solo quien puede aprobar órdenes de pago puede anular una orden aprobada';
      end if;
      if e_new = 'pagada' and e_old <> 'pagada' then
        raise exception 'Una orden se marca pagada sola al registrar su pago en Caja';
      end if;
    end if;
  end if;

  if new.col = 'movimientos' then
    if tg_op = 'UPDATE' then
      if not socio then raise exception 'Solo un socio puede anular un movimiento'; end if;
      if (new.data - 'anulado' - 'anuladoPor' - 'anuladoAt' - 'motivoAnulacion')
         is distinct from (old.data - 'anulado' - 'anuladoPor' - 'anuladoAt' - 'motivoAnulacion') then
        raise exception 'Un movimiento no se edita: se anula y se registra de nuevo';
      end if;
    end if;
    if (new.data->>'monto')::numeric is null or (new.data->>'monto')::numeric <= 0 then
      raise exception 'El monto del movimiento debe ser mayor a 0';
    end if;
    if new.data->>'tipo' = 'egreso' then
      select d.data into op from public.docs d where d.col = 'ordenes' and d.id = new.data->>'opId';
      if op is null then raise exception 'Todo egreso necesita una orden de pago'; end if;
      if tg_op = 'INSERT' and op->>'estado' <> 'aprobada' then
        raise exception 'La orden de pago % no está aprobada', new.data->>'opId';
      end if;
      if (op->>'monto')::numeric <> (new.data->>'monto')::numeric then
        raise exception 'El monto del pago debe coincidir con la orden de pago';
      end if;
    elsif new.data->>'tipo' not in ('ingreso','transferencia') then
      raise exception 'Tipo de movimiento inválido';
    end if;
  end if;
  return new;
end $$;

-- 5) Si un administrador elimina un pago, su orden vuelve a "aprobada, por pagar".
create or replace function public.op_al_borrar_pago() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.col = 'movimientos' and old.data->>'tipo' = 'egreso' then
    perform set_config('lfl.sistema', '1', true);
    update public.docs set data = (data - 'pagoMovId' - 'pagadaAt') || jsonb_build_object('estado','aprobada')
      where col = 'ordenes' and id = old.data->>'opId' and data->>'pagoMovId' = old.id;
    perform set_config('lfl.sistema', '', true);
  end if;
  return null;
end $$;
drop trigger if exists trg_op_al_borrar_pago on public.docs;
create trigger trg_op_al_borrar_pago after delete on public.docs
  for each row execute function public.op_al_borrar_pago();
