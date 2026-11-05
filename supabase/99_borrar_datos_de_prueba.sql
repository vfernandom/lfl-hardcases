-- =====================================================================
-- LFL Hardcase · BORRAR DATOS DE PRUEBA
-- ⚠️ IRREVERSIBLE. Correr solo antes de empezar a usar el sistema en serio.
--
-- BORRA: presupuestos, facturas, clientes, proveedores, compras, órdenes de pago,
--        movimientos de caja, asientos manuales y ajustes de stock.
--        Reinicia la numeración: el próximo presupuesto será LFL-001 y la próxima orden OP-0001.
-- CONSERVA: usuarios, parámetros de costo, materiales, productos, plan de cuentas
--           y las cuentas de dinero (Caja/Banco) con su saldo inicial.
--
-- Paso 1: corré SOLO el bloque "VER" para ver qué se va a borrar.
-- Paso 2: corré el bloque "BORRAR".
-- =====================================================================

-- ===== VER (no borra nada) =====
select col as que, count(*) as cantidad from public.docs
where col in ('presupuestos','clientes','proveedores','compras','ordenes','movimientos','asientos','stockajustes')
group by col
union all select 'facturas', count(*) from public.facturas
order by 1;

-- ===== BORRAR =====
-- Si querés CONSERVAR los clientes agendados, borrá 'clientes', de la lista de abajo.
begin;
delete from public.docs
where col in ('presupuestos','clientes','proveedores','compras','ordenes','movimientos','asientos','stockajustes');
delete from public.facturas;
alter sequence public.presupuesto_seq restart with 1;
alter sequence public.op_seq restart with 1;
commit;
