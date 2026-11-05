-- =====================================================================
-- LFL Hardcase · WhatsApp (conversaciones y mensajes)
-- Pegar en Supabase → SQL Editor → Run. Se puede volver a correr. No borra datos.
-- Los mensajes los graba la función "whatsapp" del servidor (con la clave de servicio).
-- La app solo puede marcar una conversación como leída o asignarle un cliente.
-- =====================================================================
alter table public.docs drop constraint if exists docs_col_check;
alter table public.docs add constraint docs_col_check check (col in (
  'config','materiales','productos','presupuestos','clientes',
  'plan','fondos','proveedores','compras','ordenes','movimientos','asientos','stockajustes',
  'ots','stockmovs','wachats','wamsgs'));

drop policy if exists docs_wa_upd on public.docs;
create policy docs_wa_upd on public.docs for update to authenticated
  using (col = 'wachats') with check (col = 'wachats');

-- Que la app no pueda cambiar el contenido de los mensajes ni el número de una conversación
create or replace function public.control_whatsapp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('lfl.sistema', true) = '1' or auth.uid() is null then return new; end if; -- servidor / clave de servicio
  if new.col = 'wachats' and tg_op = 'UPDATE' and new.data->>'tel' is distinct from old.data->>'tel' then
    raise exception 'No se puede cambiar el número de una conversación';
  end if;
  return new;
end $$;
drop trigger if exists trg_control_whatsapp on public.docs;
create trigger trg_control_whatsapp before update on public.docs
  for each row when (new.col = 'wachats') execute function public.control_whatsapp();
