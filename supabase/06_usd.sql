-- =====================================================================
-- LFL Hardcase · Pagos en dólares
-- Pegar en Supabase → SQL Editor → Run. Se puede volver a correr. No borra datos.
-- Cambia una sola regla: una orden de pago en USD se paga por su monto en dólares;
-- el monto en guaraníes puede variar por el tipo de cambio del día (hasta ±10%).
-- =====================================================================

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
      if op->>'moneda' = 'USD' then
        -- Órdenes en dólares: se paga el monto en USD aprobado; en guaraníes puede variar por el tipo de cambio (hasta ±10%)
        if (op->>'montoUSD')::numeric is distinct from (new.data->>'montoUSD')::numeric then
          raise exception 'El monto en dólares del pago debe coincidir con la orden de pago';
        end if;
        if (new.data->>'monto')::numeric < (op->>'monto')::numeric * 0.9 or (new.data->>'monto')::numeric > (op->>'monto')::numeric * 1.1 then
          raise exception 'El tipo de cambio del pago se aleja más del 10%% del aprobado: anulá la orden y creá una nueva';
        end if;
      elsif (op->>'monto')::numeric <> (new.data->>'monto')::numeric then
        raise exception 'El monto del pago debe coincidir con la orden de pago';
      end if;
    elsif new.data->>'tipo' not in ('ingreso','transferencia') then
      raise exception 'Tipo de movimiento inválido';
    end if;
  end if;
  return new;
end $$;
