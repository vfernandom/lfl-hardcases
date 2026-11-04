-- =====================================================================
-- LFL Hardcase · Módulos CAJA y CONTABILIDAD
-- Pegar en Supabase → SQL Editor → Run. Se puede volver a correr sin problema.
-- El aviso "destructive operations" es por los "drop ... if exists": no borra datos.
-- =====================================================================

-- 1) Colecciones permitidas
alter table public.docs drop constraint if exists docs_col_check;
alter table public.docs add constraint docs_col_check check (col in (
  'config','materiales','productos','presupuestos','clientes',
  'plan','fondos','proveedores','compras','ordenes','movimientos','asientos','stockajustes'));

-- 2) Permisos
--    Socios: plan de cuentas, cuentas de dinero (fondos) y asientos manuales.
--    Todos con sesión: proveedores, compras, órdenes de pago, movimientos y ajustes de stock
--    (con los controles del punto 3). Borrar: solo socios.
drop policy if exists docs_fin_socio on public.docs;
create policy docs_fin_socio on public.docs for all to authenticated
  using (col in ('plan','fondos','asientos') and public.es_socio())
  with check (col in ('plan','fondos','asientos') and public.es_socio());

drop policy if exists docs_fin_ins on public.docs;
drop policy if exists docs_fin_upd on public.docs;
drop policy if exists docs_fin_del on public.docs;
create policy docs_fin_ins on public.docs for insert to authenticated
  with check (col in ('proveedores','compras','ordenes','movimientos','stockajustes'));
create policy docs_fin_upd on public.docs for update to authenticated
  using (col in ('proveedores','compras','ordenes','movimientos','stockajustes'))
  with check (col in ('proveedores','compras','ordenes','movimientos','stockajustes'));
create policy docs_fin_del on public.docs for delete to authenticated
  using (col in ('proveedores','compras','ordenes','stockajustes') and public.es_socio());
-- Los movimientos de dinero nunca se borran: se anulan (solo un socio).

-- 3) Controles de negocio (se aplican aunque alguien intente saltarse la pantalla)
create or replace function public.control_finanzas() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  socio boolean := public.es_socio();
  e_new text; e_old text; op jsonb;
begin
  -- Cambios internos hechos por la propia base (marcar OP pagada / reabrirla)
  if current_setting('lfl.sistema', true) = '1' then return new; end if;

  -- Órdenes de pago
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
      if e_new in ('aprobada','rechazada') and e_old = 'pendiente' and not socio then
        raise exception 'Solo un socio puede aprobar o rechazar órdenes de pago';
      end if;
      if e_old <> 'pendiente' and (new.data->'monto' is distinct from old.data->'monto'
          or new.data->'beneficiario' is distinct from old.data->'beneficiario'
          or new.data->'destino' is distinct from old.data->'destino') then
        raise exception 'No se puede cambiar monto, beneficiario ni destino de una orden ya aprobada';
      end if;
      if e_old = 'aprobada' and e_new not in ('aprobada','pagada') and not socio then
        raise exception 'Solo un socio puede anular una orden aprobada';
      end if;
      if e_new = 'pagada' and e_old <> 'pagada' then
        raise exception 'Una orden se marca pagada sola al registrar su pago en Caja';
      end if;
    end if;
  end if;

  -- Movimientos de dinero
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

drop trigger if exists trg_control_finanzas on public.docs;
create trigger trg_control_finanzas before insert or update on public.docs
  for each row when (new.col in ('ordenes','movimientos'))
  execute function public.control_finanzas();

-- 3b) Al registrar un pago la OP pasa a "pagada" en el mismo paso; si un socio anula ese pago, vuelve a "aprobada".
create or replace function public.sincronizar_op() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.data->>'tipo' <> 'egreso' then return null; end if;
  perform set_config('lfl.sistema', '1', true);
  if tg_op = 'INSERT' then
    update public.docs set data = data || jsonb_build_object('estado','pagada','pagoMovId', new.id, 'pagadaAt', now())
      where col = 'ordenes' and id = new.data->>'opId';
  elsif coalesce((new.data->>'anulado')::boolean, false) and not coalesce((old.data->>'anulado')::boolean, false) then
    update public.docs set data = (data - 'pagoMovId' - 'pagadaAt') || jsonb_build_object('estado','aprobada','pagoAnulado', new.id)
      where col = 'ordenes' and id = new.data->>'opId';
  end if;
  perform set_config('lfl.sistema', '', true);
  return null;
end $$;
drop trigger if exists trg_sincronizar_op on public.docs;
create trigger trg_sincronizar_op after insert or update on public.docs
  for each row when (new.col = 'movimientos')
  execute function public.sincronizar_op();

-- 4) Numeración de órdenes de pago OP-0001…
create sequence if not exists public.op_seq start 1;
create or replace function public.siguiente_op() returns text
language sql volatile security definer set search_path = public as $$
  select 'OP-' || lpad(nextval('public.op_seq')::text, 4, '0');
$$;
revoke all on function public.siguiente_op() from public, anon;
grant execute on function public.siguiente_op() to authenticated;

-- 5) Cuentas de dinero iniciales (renombrables desde la app; saldo inicial en 0)
insert into public.docs (col, id, data) values
('fondos','f-caja',  '{"nombre":"Caja","tipo":"caja","cuenta":"1.1.01","saldoInicial":0,"fechaSaldo":"2026-11-01","activo":true}'::jsonb),
('fondos','f-banco', '{"nombre":"Banco (cuenta corriente)","tipo":"banco","cuenta":"1.1.02","saldoInicial":0,"fechaSaldo":"2026-11-01","activo":true}'::jsonb)
on conflict (col, id) do nothing;
