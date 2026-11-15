-- Prueba de la foto de datos de la app del chofer (app-datos.sql).
-- Se corre sobre una base con esquema.sql + conexion.sql + semilla.sql +
-- app-datos.sql aplicados, con la semilla en su estado fresco (antes de
-- prueba-conexion.sql, que resuelve el conflicto y valida la especial).

-- 1) CH-01: 2 clientes, 5 rutas, sus 4 anotaciones de hoy (3 normales
-- aprobadas de empresa + 1 especial pendiente) y ningún voucher todavía.
do $$
declare d jsonb; n int; a jsonb;
begin
  d := pr_datos_chofer('a0000000-0000-0000-0000-000000000001',
                       'a0000000-0000-0000-0000-000000000104');
  select jsonb_array_length(d -> 'clientes') into n;
  assert n = 2, 'app CH-01: deben bajar 2 clientes';
  select jsonb_array_length(d -> 'rutas') into n;
  assert n = 5, 'app CH-01: deben bajar 5 rutas activas';
  select jsonb_array_length(d -> 'anotaciones') into n;
  assert n = 4, 'app CH-01: deben bajar sus 4 anotaciones de hoy';
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 0, 'app CH-01: aún no tiene vouchers';

  -- La especial pendiente trae su cliente ya resuelto.
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'estado' = 'especial_pendiente';
  assert a ->> 'clienteNombre' = 'Parque Industrial Duarte',
    'app CH-01: la especial pendiente es del cliente Duarte';
  assert a ->> 'tipo' = 'especial' and (a ->> 'precioAplicado') is null,
    'app CH-01: la especial pendiente no tiene precio';

  -- Una normal trae nombre de ruta y de cliente resueltos.
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'rutaNombre' = 'San Isidro — Santo Domingo Centro';
  assert a ->> 'clienteNombre' = 'Zona Franca San Isidro',
    'app CH-01: R-01 es del cliente San Isidro';
  assert a ->> 'clase' = 'empresa' and a ->> 'estado' = 'aprobada'
     and (a ->> 'precioAplicado')::numeric = 850,
    'app CH-01: R-01 aprobada de empresa a 850';
end $$;

-- 2) CH-02: 3 anotaciones; la especial validada por el coordinador ya
-- trae su precio (1200) y estado aprobada; el conflicto sigue en conflicto.
do $$
declare d jsonb; n int; a jsonb;
begin
  d := pr_datos_chofer('a0000000-0000-0000-0000-000000000001',
                       'a0000000-0000-0000-0000-000000000105');
  select jsonb_array_length(d -> 'anotaciones') into n;
  assert n = 3, 'app CH-02: deben bajar sus 3 anotaciones de hoy';
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'tipo' = 'especial';
  assert a ->> 'estado' = 'aprobada'
     and (a ->> 'precioAplicado')::numeric = 1200,
    'app CH-02: la especial validada trae precio 1200';
  select count(*) into n from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'estado' = 'conflicto';
  assert n = 1, 'app CH-02: su R-03 sigue en conflicto';
end $$;

-- 3) Vouchers del chofer: la empresa genera el de CH-01 de hoy (3 rutas
-- de empresa: total 0, las 3 líneas en precio 0) y la app lo recibe con
-- su detalle; CH-02 sigue sin vouchers (aislamiento entre choferes).
do $$
declare d jsonb; n int; v jsonb;
begin
  perform pr_generar_voucher('a0000000-0000-0000-0000-000000000001',
    'a0000000-0000-0000-0000-000000000104', current_date, current_date);
  d := pr_datos_chofer('a0000000-0000-0000-0000-000000000001',
                       'a0000000-0000-0000-0000-000000000104');
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 1, 'app voucher: CH-01 debe ver 1 voucher';
  v := d -> 'vouchers' -> 0;
  assert (v ->> 'folio')::int = 1 and (v ->> 'total')::numeric = 0,
    'app voucher: folio 1 con total 0 (todo va en el sueldo)';
  select jsonb_array_length(v -> 'detalle') into n;
  assert n = 3, 'app voucher: el detalle trae las 3 rutas de empresa';
  select count(*) into n from jsonb_array_elements(v -> 'detalle') x
  where (x ->> 'precio')::numeric <> 0;
  assert n = 0, 'app voucher: ninguna línea de empresa trae precio';
  d := pr_datos_chofer('a0000000-0000-0000-0000-000000000001',
                       'a0000000-0000-0000-0000-000000000105');
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 0, 'app voucher: CH-02 no ve el voucher de CH-01';
end $$;

-- 4) Seguridad básica: un usuario que no es chofer (ADMIN) o un chofer
-- con la empresa equivocada no reciben datos.
do $$
declare ok boolean := false;
begin
  begin
    perform pr_datos_chofer('a0000000-0000-0000-0000-000000000001',
                            'a0000000-0000-0000-0000-000000000102');
  exception when others then ok := true;
  end;
  assert ok, 'app: ADMIN (rol empresa) no debe recibir datos de chofer';
  ok := false;
  begin
    perform pr_datos_chofer('b0000000-0000-0000-0000-000000000001',
                            'a0000000-0000-0000-0000-000000000104');
  exception when others then ok := true;
  end;
  assert ok, 'app: con otra empresa el chofer no debe recibir datos';
end $$;

select 'PRUEBA DE APP OK' as resultado;
