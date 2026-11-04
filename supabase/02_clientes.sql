-- =====================================================================
-- LFL Hardcase · Agrega el catastro de CLIENTES
-- Pegar en Supabase → SQL Editor → Run (una sola vez). Se puede repetir sin problema.
-- Supabase puede mostrar el aviso "destructive operations": es por los
-- "drop ... if exists", que solo reemplazan reglas con el mismo nombre. No borra datos.
-- =====================================================================
alter table public.docs drop constraint if exists docs_col_check;
alter table public.docs add constraint docs_col_check
  check (col in ('config','materiales','productos','presupuestos','clientes'));

-- Todos los usuarios con sesión pueden agendar y editar clientes; solo un socio borra.
drop policy if exists docs_clientes_ins on public.docs;
drop policy if exists docs_clientes_upd on public.docs;
drop policy if exists docs_clientes_del on public.docs;
create policy docs_clientes_ins on public.docs for insert to authenticated
  with check (col = 'clientes');
create policy docs_clientes_upd on public.docs for update to authenticated
  using (col = 'clientes') with check (col = 'clientes');
create policy docs_clientes_del on public.docs for delete to authenticated
  using (col = 'clientes' and public.es_socio());
