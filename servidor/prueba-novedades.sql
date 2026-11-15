-- Prueba de las novedades en vivo de la app (app-novedades.sql).
-- Se corre sobre una base con la cadena completa (esquema + conexion +
-- semilla + app-datos + ajustes + acceso-roles + auditoria + caducidad
-- + permisos-dueno + permisos-crud) y app-novedades.sql aplicado, con
-- la semilla en su estado fresco.
--
-- Empresa Servivans a0000000-0000-0000-0000-000000000001;
-- ADMIN …0102, COORD …0103, CH-01 …0104, CH-02 …0105, CH-03 …0106.

-- 1) CH-01: las claves de siempre quedan intactas y llegan las nuevas:
-- reportes (vacío: aún no envía ninguno) y `resolucion` en anotaciones.
do $$
declare d jsonb; n int; a jsonb;
begin
  d := pr_datos_chofer('a0000000-0000-0000-0000-000000000001',
                       'a0000000-0000-0000-0000-000000000104');
  select jsonb_array_length(d -> 'clientes') into n;
  assert n = 2, 'novedades CH-01: deben bajar 2 clientes';
  select jsonb_array_length(d -> 'rutas') into n;
  assert n = 5, 'novedades CH-01: deben bajar 5 rutas activas';
  select jsonb_array_length(d -> 'anotaciones') into n;
  assert n = 4, 'novedades CH-01: deben bajar sus 4 anotaciones de hoy';
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 0, 'novedades CH-01: aún no tiene vouchers';
  assert d ? 'reportes', 'novedades CH-01: la foto trae la clave reportes';
  select jsonb_array_length(d -> 'reportes') into n;
  assert n = 0, 'novedades CH-01: aún no ha enviado reportes';
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'estado' = 'especial_pendiente';
  assert (a ->> 'resolucion') is null,
    'novedades CH-01: la especial pendiente no trae resolución';
end $$;

-- 2) Reportes propios: CH-01 envía uno y la foto lo trae como 'nuevo';
-- administración lo resuelve y la foto lo trae 'resuelto'.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare r jsonb; d jsonb; n int; x jsonb;
begin
  r := pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000104',
                         'calle_cerrada', 'La Duarte está cerrada');
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000104');
  select jsonb_array_length(d -> 'reportes') into n;
  assert n = 1, 'novedades reporte: CH-01 debe ver su reporte';
  x := d -> 'reportes' -> 0;
  assert x ->> 'id' = r ->> 'id'
     and x ->> 'tipo' = 'calle_cerrada'
     and x ->> 'texto' = 'La Duarte está cerrada'
     and x ->> 'estado' = 'nuevo'
     and (x ->> 'esCoordinador')::boolean = false
     and (x ->> 'creadaEn') is not null,
    'novedades reporte: el reporte propio baja completo y nuevo';

  perform pr_resolver_reporte((r ->> 'id')::uuid,
                              'a0000000-0000-0000-0000-000000000102');
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000104');
  x := d -> 'reportes' -> 0;
  assert x ->> 'estado' = 'resuelto',
    'novedades reporte: tras resolverlo, baja como resuelto';

  -- Aislamiento: el reporte de CH-01 no aparece en la foto de CH-02.
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000105');
  select jsonb_array_length(d -> 'reportes') into n;
  assert n = 0, 'novedades reporte: CH-02 no ve el reporte de CH-01';
end $$;

-- 3) Especial validada: el coordinador valida la especial pendiente de
-- CH-01 (…0408) con precio 900 y la foto lo refleja aprobada con precio.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare d jsonb; a jsonb;
begin
  perform pr_validar_especial('a0000000-0000-0000-0000-000000000408',
                              'a0000000-0000-0000-0000-000000000103', 900);
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000104');
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = 'a0000000-0000-0000-0000-000000000408';
  assert a ->> 'estado' = 'aprobada'
     and (a ->> 'precioAplicado')::numeric = 900,
    'novedades especial: la validada baja aprobada con su precio';
end $$;

-- 4) Conflicto resuelto en modo 'unico': CH-01 anota R-05, que CH-02 ya
-- tenía aprobada (…0404) → ambas en conflicto. Gana CH-01: la suya baja
-- aprobada con resolucion 'unico' y la de CH-02, rechazada con 'unico'.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare nueva anotaciones; d jsonb; a jsonb;
begin
  nueva := pr_anotar_ruta(emp, 'a0000000-0000-0000-0000-000000000104',
                          'a0000000-0000-0000-0000-000000000305');
  assert nueva.estado = 'conflicto',
    'novedades conflicto: la R-05 de CH-01 nace en conflicto';
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000104');
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = nueva.id::text;
  assert a ->> 'estado' = 'conflicto' and (a ->> 'resolucion') is null,
    'novedades conflicto: en conflicto aún no hay resolución';

  perform pr_resolver_conflicto(nueva.id,
                                'a0000000-0000-0000-0000-000000000103', 'unico');
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000104');
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = nueva.id::text;
  assert a ->> 'estado' = 'aprobada' and a ->> 'resolucion' = 'unico',
    'novedades conflicto: el ganador baja aprobado con resolucion unico';
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000105');
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = 'a0000000-0000-0000-0000-000000000404';
  assert a ->> 'estado' = 'rechazada' and a ->> 'resolucion' = 'unico',
    'novedades conflicto: el perdedor baja rechazado con resolucion unico';
end $$;

-- 5) Conflicto resuelto en modo 'ambas': el de la semilla (R-03 entre
-- CH-02 …0406 y CH-03 …0407) queda aprobado para los dos, con
-- resolucion 'ambas' en la foto de cada uno.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare d jsonb; a jsonb;
begin
  perform pr_resolver_conflicto('a0000000-0000-0000-0000-000000000406',
                                'a0000000-0000-0000-0000-000000000103', 'ambas');
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000105');
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = 'a0000000-0000-0000-0000-000000000406';
  assert a ->> 'estado' = 'aprobada' and a ->> 'resolucion' = 'ambas',
    'novedades ambas: CH-02 baja aprobado con resolucion ambas';
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000106');
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = 'a0000000-0000-0000-0000-000000000407';
  assert a ->> 'estado' = 'aprobada' and a ->> 'resolucion' = 'ambas',
    'novedades ambas: CH-03 baja aprobado con resolucion ambas';
end $$;

-- 6) Voucher nuevo: la empresa genera el de CH-01 y su foto lo trae con
-- id y creadaEn (además de las claves de siempre); CH-02 no lo ve.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare d jsonb; n int; v jsonb;
begin
  perform pr_generar_voucher(emp, 'a0000000-0000-0000-0000-000000000104',
                             current_date, current_date);
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000104');
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 1, 'novedades voucher: CH-01 debe ver su voucher';
  v := d -> 'vouchers' -> 0;
  assert (v ->> 'id') is not null and (v ->> 'creadaEn') is not null
     and (v ->> 'folio')::int = 1
     and v ? 'detalle',
    'novedades voucher: trae id, creadaEn y las claves de siempre';
  -- El total incluye la especial validada en la prueba 3 (RD$900 extra).
  select count(*) into n from jsonb_array_elements(v -> 'detalle') x
  where (x ->> 'precio')::numeric = 900;
  assert n = 1 and (v ->> 'total')::numeric >= 900,
    'novedades voucher: el detalle trae la especial validada a 900';
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000105');
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 0, 'novedades voucher: CH-02 no ve el voucher de CH-01';
end $$;

-- 7) Coordinador: ya NO es rechazado y su foto es COMPLETA (también
-- hace rutas: clientes y rutas como un chofer, más sus reportes y los
-- pendientes de la empresa). Un reporte nuevo de un chofer aparece en
-- reportesPendientes con el nombre del autor; el suyo propio también
-- (destacado) y en reportes. Al resolverse, sale de pendientes.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare coord uuid := 'a0000000-0000-0000-0000-000000000103';
declare d jsonb; n int; x jsonb; r jsonb;
begin
  d := pr_datos_chofer(emp, coord);
  select jsonb_array_length(d -> 'clientes') into n;
  assert n = 2, 'novedades coord: baja los 2 clientes, como un chofer';
  select jsonb_array_length(d -> 'rutas') into n;
  assert n = 5, 'novedades coord: baja las 5 rutas, como un chofer';
  select jsonb_array_length(d -> 'anotaciones') into n;
  assert n = 0, 'novedades coord: aún no tiene anotaciones propias';
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 0, 'novedades coord: aún no tiene vouchers';
  assert d ? 'reportesPendientes',
    'novedades coord: la foto trae reportesPendientes';
  select jsonb_array_length(d -> 'reportesPendientes') into n;
  assert n = 0, 'novedades coord: sin pendientes al inicio '
    '(el de CH-01 ya se resolvió en la prueba 2)';

  r := pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000105',
                         'averia', 'El autobús 12 está varado');
  d := pr_datos_chofer(emp, coord);
  select jsonb_array_length(d -> 'reportesPendientes') into n;
  assert n = 1, 'novedades coord: el reporte nuevo del chofer es pendiente';
  x := d -> 'reportesPendientes' -> 0;
  assert x ->> 'id' = r ->> 'id'
     and x ->> 'tipo' = 'averia'
     and x ->> 'texto' = 'El autobús 12 está varado'
     and x ->> 'choferNombre' = 'José Ramírez'
     and (x ->> 'esCoordinador')::boolean = false
     and (x ->> 'creadaEn') is not null,
    'novedades coord: el pendiente trae autor, tipo, texto y fecha';

  perform pr_enviar_reporte(emp, coord, 'seguridad', 'Revisar la zona norte');
  d := pr_datos_chofer(emp, coord);
  select jsonb_array_length(d -> 'reportesPendientes') into n;
  assert n = 2, 'novedades coord: también ve pendiente el suyo propio';
  select count(*) into n from jsonb_array_elements(d -> 'reportesPendientes') y
  where (y ->> 'esCoordinador')::boolean;
  assert n = 1, 'novedades coord: su reporte va marcado esCoordinador';
  select jsonb_array_length(d -> 'reportes') into n;
  assert n = 1, 'novedades coord: su reporte propio baja en reportes';

  perform pr_resolver_reporte((r ->> 'id')::uuid,
                              'a0000000-0000-0000-0000-000000000102');
  d := pr_datos_chofer(emp, coord);
  select jsonb_array_length(d -> 'reportesPendientes') into n;
  assert n = 1, 'novedades coord: el resuelto sale de pendientes';
end $$;

-- 8) El coordinador ANOTA como un chofer: anota R-04, que CH-01 ya
-- tenía aprobada hoy (…0403) → CONFLICTO coordinador↔chofer (y la de
-- CH-01 también cae en conflicto). Se resuelve «ambas»: las dos
-- cuentan. Su clase sale del cupo de su empresa (empresa, es su
-- primera del día). Después anota una especial, administración la
-- valida a 700 y su ganado (pr_mi_ganado, sin filtro de rol) la suma.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare coord uuid := 'a0000000-0000-0000-0000-000000000103';
declare nueva anotaciones; d jsonb; a jsonb; g record;
begin
  nueva := pr_anotar_ruta(emp, coord,
                          'a0000000-0000-0000-0000-000000000304');
  assert nueva.estado = 'conflicto' and nueva.clase = 'empresa',
    'novedades coord-ruta: su R-04 nace en conflicto y clase empresa';
  d := pr_datos_chofer(emp, 'a0000000-0000-0000-0000-000000000104');
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = 'a0000000-0000-0000-0000-000000000403';
  assert a ->> 'estado' = 'conflicto',
    'novedades coord-ruta: la R-04 de CH-01 también cae en conflicto';

  perform pr_resolver_conflicto(nueva.id,
                                'a0000000-0000-0000-0000-000000000102', 'ambas');
  d := pr_datos_chofer(emp, coord);
  select x into a from jsonb_array_elements(d -> 'anotaciones') x
  where x ->> 'id' = nueva.id::text;
  assert a ->> 'estado' = 'aprobada' and a ->> 'resolucion' = 'ambas',
    'novedades coord-ruta: resuelto «ambas», la suya cuenta';

  nueva := pr_anotar_especial(emp, coord, 'Coordinación: llevar documentos a la planta');
  assert nueva.estado = 'especial_pendiente',
    'novedades coord-ruta: su especial nace pendiente';
  perform pr_validar_especial(nueva.id,
                              'a0000000-0000-0000-0000-000000000102', 700);
  select * into g from pr_mi_ganado(emp, coord);
  assert g.modo = 'todo' and g.total = 700,
    'novedades coord-ruta: su ganado suma la especial validada (700)';
end $$;

-- 9) Pagos: el resumen del período incluye al coordinador CON
-- anotaciones (y su dinero), no incluye a un coordinador sin
-- anotaciones ni a la administración; el voucher del coordinador se
-- genera y baja en su foto con el total de su especial.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare coord uuid := 'a0000000-0000-0000-0000-000000000103';
declare coord2 usuarios; n int; d jsonb; v jsonb;
begin
  select count(*) into n from pr_resumen_periodo(emp, current_date, current_date) rp
  where rp.chofer_id = coord and rp.num_empresa = 1 and rp.num_extra = 1
    and rp.total = 700;
  assert n = 1, 'novedades coord-pagos: el resumen lo trae con su dinero';
  select count(*) into n from pr_resumen_periodo(emp, current_date, current_date) rp
  where rp.chofer_id = 'a0000000-0000-0000-0000-000000000102';
  assert n = 0, 'novedades coord-pagos: la administración no sale en el resumen';
  select count(*) into n from pr_resumen_periodo(emp, current_date, current_date) rp
  where rp.chofer_id = 'a0000000-0000-0000-0000-000000000104';
  assert n = 1, 'novedades coord-pagos: los choferes salen como siempre';

  coord2 := pr_crear_usuario(emp, 'Coordinador Dos', 'COORD2', 'coordinador', '1234');
  select count(*) into n from pr_resumen_periodo(emp, current_date, current_date) rp
  where rp.chofer_id = coord2.id;
  assert n = 0, 'novedades coord-pagos: sin anotaciones, el coordinador no sale';

  perform pr_generar_voucher(emp, coord, current_date, current_date);
  d := pr_datos_chofer(emp, coord);
  select jsonb_array_length(d -> 'vouchers') into n;
  assert n = 1, 'novedades coord-pagos: el coordinador ve su voucher';
  v := d -> 'vouchers' -> 0;
  assert (v ->> 'total')::numeric = 700 and (v ->> 'id') is not null,
    'novedades coord-pagos: su voucher totaliza su especial (700)';
  select count(*) into n from jsonb_array_elements(v -> 'detalle') x
  where (x ->> 'precio')::numeric = 700;
  assert n = 1, 'novedades coord-pagos: el detalle trae la especial a 700';
end $$;

-- 10) Nombre del autor en TODA lista de reportes: un reporte del
-- coordinador devuelve su nombre real ('Coordinación Servivans') en
-- sus propios `reportes`, en los `reportesPendientes` del coordinador
-- y en pr_listar_reportes (la del panel), que además mantiene el
-- objeto `autor` anidado. Un reporte de chofer lleva su nombre.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare coord uuid := 'a0000000-0000-0000-0000-000000000103';
declare rc jsonb; rd jsonb; d jsonb; x jsonb; lista jsonb;
begin
  rc := pr_enviar_reporte(emp, coord, 'otro', 'Coordinación: cambio de turno en la planta');
  rd := pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000104',
                          'averia', 'El autobús 12 suena raro al frenar');

  d := pr_datos_chofer(emp, coord);
  select e into x from jsonb_array_elements(d -> 'reportes') e
  where e ->> 'id' = rc ->> 'id';
  assert x ->> 'autorNombre' = 'Coordinación Servivans'
     and (x ->> 'esCoordinador')::boolean,
    'novedades autor: su propio reporte trae su nombre y su rol';

  select e into x from jsonb_array_elements(d -> 'reportesPendientes') e
  where e ->> 'id' = rc ->> 'id';
  assert x ->> 'autorNombre' = 'Coordinación Servivans'
     and x ->> 'choferNombre' = 'Coordinación Servivans'
     and (x ->> 'esCoordinador')::boolean,
    'novedades autor: en pendientes el coordinador sale con su nombre';
  select e into x from jsonb_array_elements(d -> 'reportesPendientes') e
  where e ->> 'id' = rd ->> 'id';
  assert x ->> 'autorNombre' = 'Carlos Méndez'
     and not (x ->> 'esCoordinador')::boolean,
    'novedades autor: en pendientes el chofer sale con su nombre';

  lista := pr_listar_reportes(emp, 'a0000000-0000-0000-0000-000000000102');
  select e into x from jsonb_array_elements(lista) e
  where e ->> 'id' = rc ->> 'id';
  assert x ->> 'autorNombre' = 'Coordinación Servivans'
     and x -> 'autor' ->> 'nombre' = 'Coordinación Servivans'
     and (x ->> 'esCoordinador')::boolean,
    'novedades autor: el panel ve el nombre del coordinador';
  select e into x from jsonb_array_elements(lista) e
  where e ->> 'id' = rd ->> 'id';
  assert x ->> 'autorNombre' = 'Carlos Méndez',
    'novedades autor: el panel ve el nombre del chofer';
end $$;

-- 11) Revalidación de la sesión persistida: pr_datos_chofer rechaza
-- con el mensaje del login si la licencia se suspende o vence, o si
-- la empresa se desactiva (la app, al reabrir, expulsa la sesión
-- guardada con ese mensaje). Todo se restaura dentro del bloque.
do $$
declare emp uuid := 'a0000000-0000-0000-0000-000000000001';
declare ch1 uuid := 'a0000000-0000-0000-0000-000000000104';
declare msg text; d jsonb;
begin
  update licencias set estado = 'suspendida' where empresa_id = emp;
  begin
    perform pr_datos_chofer(emp, ch1);
    raise exception 'debió rechazar por licencia suspendida';
  exception when others then msg := sqlerrm;
  end;
  assert msg like 'La licencia de tu empresa está suspendida%',
    'novedades revalida: licencia suspendida expulsa';
  update licencias set estado = 'activa', vence = current_date - 1
  where empresa_id = emp;
  begin
    perform pr_datos_chofer(emp, ch1);
    raise exception 'debió rechazar por licencia vencida';
  exception when others then msg := sqlerrm;
  end;
  assert msg like 'La licencia de tu empresa está vencida%',
    'novedades revalida: licencia vencida expulsa';
  update licencias set vence = date '2027-11-15' where empresa_id = emp;
  update empresas set activa = false where id = emp;
  begin
    perform pr_datos_chofer(emp, ch1);
    raise exception 'debió rechazar por empresa inactiva';
  exception when others then msg := sqlerrm;
  end;
  assert msg like 'Tu empresa está inactiva%',
    'novedades revalida: empresa inactiva expulsa';
  update empresas set activa = true where id = emp;
  d := pr_datos_chofer(emp, ch1);
  assert jsonb_array_length(d -> 'anotaciones') >= 1,
    'novedades revalida: restaurado todo, la foto vuelve';
end $$;

-- 12) Seguridad tras el drop + recreate: los roles de oficina siguen
-- rechazados y queda UNA sola versión de la función.
do $$
declare ok boolean := false; n int;
begin
  begin
    perform pr_datos_chofer('a0000000-0000-0000-0000-000000000001',
                            'a0000000-0000-0000-0000-000000000102');
  exception when others then ok := true;
  end;
  assert ok, 'novedades: ADMIN (rol empresa) sigue rechazado';
  ok := false;
  begin
    perform pr_datos_chofer('b0000000-0000-0000-0000-000000000001',
                            'a0000000-0000-0000-0000-000000000104');
  exception when others then ok := true;
  end;
  assert ok, 'novedades: con otra empresa el chofer sigue rechazado';
  select count(*) into n from pg_proc where proname = 'pr_datos_chofer';
  assert n = 1, 'novedades: debe quedar una sola pr_datos_chofer';
end $$;

select 'PRUEBA DE NOVEDADES OK' as resultado;
