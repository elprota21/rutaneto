-- Prueba del registro de auditoría — se corre sobre una base con
-- esquema.sql + conexion.sql + semilla.sql + app-datos.sql +
-- ajustes-2026-11-15.sql + acceso-roles.sql + auditoria.sql aplicados,
-- con la semilla FRESCA (el conflicto y la especial pendiente intactos;
-- por eso va en su propia base, separada de la regresión, donde
-- prueba-conexion.sql ya resolvió el conflicto).
-- IDs de la semilla: empresa …001, MIGUEL …101, ADMIN …102, COORD …103,
-- CH-01 …104, CH-02 …105, CH-03 …106, clientes …201/…202, rutas …301-305,
-- conflicto …406 (CH-02) y …407 (CH-03) en R-03, especial pendiente …408.

-- 0) La tabla existe, con RLS activa.
do $$
begin
  assert exists (select 1 from pg_tables where tablename = 'registro_acciones'),
    'auditoría 0: existe la tabla registro_acciones';
  assert (select rowsecurity from pg_tables where tablename = 'registro_acciones'),
    'auditoría 0: RLS activa en registro_acciones';
end $$;

-- 1) Inicio de sesión: SOLO se registra cuando la sesión se concede.
do $$
declare
  s jsonb; n0 int; n1 int; r record; ok boolean;
begin
  select count(*) into n0 from registro_acciones where accion = 'inicio_sesion';

  -- PIN malo: excepción y NINGUNA fila nueva.
  ok := false;
  begin perform pr_iniciar_sesion('ADMIN', '9999', 'panel');
  exception when others then ok := true; end;
  assert ok, 'auditoría 1: el PIN malo se rechaza';
  select count(*) into n1 from registro_acciones where accion = 'inicio_sesion';
  assert n1 = n0, 'auditoría 1: el intento fallido NO se registra';

  -- Puerta equivocada (chofer por el panel): tampoco se registra.
  ok := false;
  begin perform pr_iniciar_sesion('CH-01', '1234', 'panel');
  exception when others then ok := true; end;
  assert ok, 'auditoría 1: el chofer no entra por el panel';
  select count(*) into n1 from registro_acciones where accion = 'inicio_sesion';
  assert n1 = n0, 'auditoría 1: la puerta equivocada NO se registra';

  -- Sesión concedida de ADMIN por el panel: se registra con su foto.
  s := pr_iniciar_sesion('ADMIN', '1234', 'panel');
  select * into r from registro_acciones
  where accion = 'inicio_sesion' order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN' and r.actor_rol = 'empresa',
    'auditoría 1: el actor del inicio de sesión es ADMIN (empresa)';
  assert r.empresa_id = 'a0000000-0000-0000-0000-000000000001',
    'auditoría 1: el inicio de sesión lleva la empresa Servivans';
  assert r.detalle like '%panel%', 'auditoría 1: el detalle menciona la puerta (panel)';

  -- Sin contexto: detalle genérico «Inició sesión». (Se filtra por actor:
  -- dentro de un mismo bloque, creada_en empata porque now() es la hora
  -- de la transacción.)
  s := pr_iniciar_sesion('CH-01', '1234');
  select * into r from registro_acciones
  where accion = 'inicio_sesion' and actor_codigo = 'CH-01'
  order by creada_en desc limit 1;
  assert r.detalle = 'Inició sesión', 'auditoría 1: sin contexto, detalle genérico';
end $$;

-- 2) COORD resuelve el conflicto de la semilla en modo «ambas».
do $$
declare r record;
begin
  perform pr_resolver_conflicto('a0000000-0000-0000-0000-000000000407',
                                'a0000000-0000-0000-0000-000000000103', 'ambas');
  select * into r from registro_acciones where accion = 'conflicto_resuelto'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'COORD', 'auditoría 2: el actor es COORD';
  assert r.detalle like '%R-03%', 'auditoría 2: el detalle trae la ruta R-03';
  assert r.detalle like '%Parque Industrial Duarte%', 'auditoría 2: el detalle trae el cliente';
  assert r.detalle like '%ambas%', 'auditoría 2: el detalle dice «aprobando ambas»';
end $$;

-- 3) COORD valida la especial pendiente de CH-01 con precio 800.
do $$
declare r record;
begin
  perform pr_validar_especial('a0000000-0000-0000-0000-000000000408',
                              'a0000000-0000-0000-0000-000000000103', 800, true);
  select * into r from registro_acciones where accion = 'especial_validada'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'COORD', 'auditoría 3: el actor es COORD';
  assert r.detalle like '%Viaje no programado: recoger equipo en el muelle%',
    'auditoría 3: el detalle trae la descripción de la especial';
  assert r.detalle like '%CH-01%', 'auditoría 3: el detalle trae el chofer CH-01';
  assert r.detalle like '%800%', 'auditoría 3: el detalle trae el precio puesto (800)';
end $$;

-- 4) Voucher de CH-01 (hoy): la especial validada suma 800; folio 1.
--    La firma no recibe actor: la fila lleva empresa y detalle, sin actor.
do $$
declare
  v vouchers; r record;
begin
  v := pr_generar_voucher('a0000000-0000-0000-0000-000000000001',
                          'a0000000-0000-0000-0000-000000000104',
                          current_date, current_date);
  assert v.folio = 1 and v.total = 800, 'auditoría 4: voucher folio 1 por 800';
  select * into r from registro_acciones where accion = 'voucher_generado'
  order by creada_en desc limit 1;
  assert r.empresa_id = 'a0000000-0000-0000-0000-000000000001',
    'auditoría 4: el voucher registrado lleva la empresa';
  assert r.detalle like '%CH-01%', 'auditoría 4: el detalle trae el chofer';
  assert r.detalle like '%#1%', 'auditoría 4: el detalle trae el folio';
  assert r.detalle like '%800%', 'auditoría 4: el detalle trae el total';
  assert r.actor_id is null and r.actor_codigo is null,
    'auditoría 4: sin actor en la firma, la fila queda sin actor (no se inventa)';
end $$;

-- 5) Conflicto nuevo en modo «unico»: CH-02 anota R-01 (la tenía CH-01)
--    y ADMIN resuelve a favor de CH-02.
do $$
declare r record;
begin
  perform pr_anotar_ruta('a0000000-0000-0000-0000-000000000001',
                         'a0000000-0000-0000-0000-000000000105',
                         'a0000000-0000-0000-0000-000000000301', current_date);
  perform pr_resolver_conflicto(
    (select id from anotaciones
     where chofer_id = 'a0000000-0000-0000-0000-000000000105'
       and ruta_id = 'a0000000-0000-0000-0000-000000000301' and estado = 'conflicto'),
    'a0000000-0000-0000-0000-000000000102', 'unico');
  select * into r from registro_acciones
  where accion = 'conflicto_resuelto' and actor_codigo = 'ADMIN'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN', 'auditoría 5: el actor es ADMIN';
  assert r.detalle like '%R-01%', 'auditoría 5: el detalle trae la ruta R-01';
  assert r.detalle like '%Zona Franca San Isidro%', 'auditoría 5: el detalle trae el cliente';
  assert r.detalle like '%a favor de CH-02%', 'auditoría 5: el detalle dice a favor de quién';
end $$;

-- 6) Reporte de CH-01 resuelto por COORD.
do $$
declare
  rep jsonb; r record;
begin
  rep := pr_enviar_reporte('a0000000-0000-0000-0000-000000000001',
                           'a0000000-0000-0000-0000-000000000104',
                           'averia', 'Autobús con la goma pinchada en la ruta');
  perform pr_resolver_reporte((rep ->> 'id')::uuid,
                              'a0000000-0000-0000-0000-000000000103');
  select * into r from registro_acciones where accion = 'reporte_resuelto'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'COORD', 'auditoría 6: el actor es COORD';
  assert r.detalle like '%avería%', 'auditoría 6: el detalle trae el tipo (avería)';
  assert r.detalle like '%CH-01%', 'auditoría 6: el detalle trae el autor del reporte';
end $$;

-- 7) CRUD del panel: cliente creado y borrado por ADMIN, usuario creado,
--    ruta creada, opciones cambiadas y feriado agregado/quitado.
do $$
declare
  c clientes; u usuarios; r record;
begin
  c := pr_crear_cliente('a0000000-0000-0000-0000-000000000001', 'Cliente Auditoría');
  select * into r from registro_acciones where accion = 'cliente_creado'
  order by creada_en desc limit 1;
  assert r.detalle like '%Cliente Auditoría%', 'auditoría 7: cliente_creado con el nombre';

  u := pr_crear_usuario('a0000000-0000-0000-0000-000000000001', 'Chofer Auditoría', 'CH-99', 'chofer');
  select * into r from registro_acciones where accion = 'usuario_creado'
  order by creada_en desc limit 1;
  assert r.detalle like '%CH-99%', 'auditoría 7: usuario_creado con el código';

  perform pr_crear_ruta('a0000000-0000-0000-0000-000000000001', 'R-99', 'Ruta Auditoría', 300, c.id);
  select * into r from registro_acciones where accion = 'ruta_creada'
  order by creada_en desc limit 1;
  assert r.detalle like '%R-99%', 'auditoría 7: ruta_creada con el código';

  perform pr_actualizar_opciones('a0000000-0000-0000-0000-000000000001',
    '{"diasParaAnotar": 3}'::jsonb);
  select * into r from registro_acciones where accion = 'opciones_cambiadas'
  order by creada_en desc limit 1;
  assert r.detalle like '%diasParaAnotar%', 'auditoría 7: opciones_cambiadas con la clave tocada';

  perform pr_agregar_feriado('a0000000-0000-0000-0000-000000000001',
    current_date + 30, 'Feriado Auditoría');
  select * into r from registro_acciones where accion = 'feriado_agregado'
  order by creada_en desc limit 1;
  assert r.detalle like '%Feriado Auditoría%', 'auditoría 7: feriado_agregado con el nombre';
  perform pr_quitar_feriado('a0000000-0000-0000-0000-000000000001', current_date + 30);
  select * into r from registro_acciones where accion = 'feriado_borrado'
  order by creada_en desc limit 1;
  assert r.detalle like '%Feriado Auditoría%', 'auditoría 7: feriado_borrado con el nombre';

  -- ADMIN borra el cliente creado para la prueba: queda registrado y la
  -- ruta R-99 pasa a General (FK set null), como manda el diseño.
  perform pr_borrar_cliente(c.id, 'a0000000-0000-0000-0000-000000000102');
  select * into r from registro_acciones where accion = 'cliente_borrado'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN', 'auditoría 7: el actor del borrado es ADMIN';
  assert r.detalle like '%Cliente Auditoría%', 'auditoría 7: cliente_borrado con el nombre';
  assert (select cliente_id from rutas where codigo = 'R-99') is null,
    'auditoría 7: la ruta del cliente borrado quedó en General';
end $$;

-- 8) Cambio de PIN propio (ADMIN) y reinicio por el superadmin.
--    Los PIN usados aquí (8642 y 4321) NO pueden aparecer en NINGÚN detalle.
do $$
declare
  s jsonb; r record; ok boolean; cod text;
begin
  perform pr_cambiar_pin('a0000000-0000-0000-0000-000000000102', '1234', '8642');
  select * into r from registro_acciones where accion = 'pin_cambiado'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN', 'auditoría 8: el actor del cambio de PIN es ADMIN';
  assert r.detalle = 'Cambió su PIN de acceso', 'auditoría 8: detalle fijo, sin valores';

  s := pr_iniciar_sesion('ADMIN', '8642', 'panel');
  assert s -> 'usuario' ->> 'codigo' = 'ADMIN', 'auditoría 8: ADMIN entra con el PIN nuevo';
  ok := false;
  begin perform pr_iniciar_sesion('ADMIN', '1234', 'panel');
  exception when others then ok := true; end;
  assert ok, 'auditoría 8: ADMIN ya no entra con el PIN viejo';

  cod := pr_admin_pin_admin('a0000000-0000-0000-0000-000000000101',
                            'a0000000-0000-0000-0000-000000000001', '4321');
  assert cod = 'ADMIN', 'auditoría 8: el reinicio devuelve el código del admin';
  select * into r from registro_acciones where accion = 'pin_admin_reiniciado'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'MIGUEL', 'auditoría 8: el actor del reinicio es MIGUEL';
  assert r.detalle like '%ADMIN%' and r.detalle like '%Servivans%',
    'auditoría 8: el detalle trae el código del admin y la empresa';
  s := pr_iniciar_sesion('ADMIN', '4321', 'panel');
  assert s -> 'usuario' ->> 'codigo' = 'ADMIN', 'auditoría 8: ADMIN entra con el PIN reiniciado';
end $$;

-- 9) Superadmin: crea una empresa y suspende/extiende la licencia de
--    Servivans (al extender, la licencia vuelve a activa y ADMIN entra).
do $$
declare
  e jsonb; nueva uuid; r record; ok boolean; s jsonb;
begin
  e := pr_admin_crear_empresa('a0000000-0000-0000-0000-000000000101',
    'Transportes Auditoría', 5, 6, 'TA-ADMIN', '2468', 'Admin Auditoría');
  nueva := (e -> 'empresa' ->> 'id')::uuid;
  select * into r from registro_acciones where accion = 'empresa_creada'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'MIGUEL', 'auditoría 9: el actor es MIGUEL';
  assert r.empresa_id = nueva, 'auditoría 9: la fila lleva la empresa NUEVA';
  assert r.detalle like '%Transportes Auditoría%', 'auditoría 9: el detalle trae el nombre';
  assert r.detalle like '%5%', 'auditoría 9: el detalle trae el máx. de choferes';

  perform pr_admin_licencia('a0000000-0000-0000-0000-000000000101',
    'a0000000-0000-0000-0000-000000000001', 'suspender');
  select * into r from registro_acciones where accion = 'licencia_suspendida'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'MIGUEL' and r.detalle like '%Servivans%',
    'auditoría 9: licencia_suspendida de Servivans por MIGUEL';

  ok := false;
  begin perform pr_iniciar_sesion('ADMIN', '4321', 'panel');
  exception when others then ok := true; end;
  assert ok, 'auditoría 9: con la licencia suspendida, ADMIN no entra';

  perform pr_admin_licencia('a0000000-0000-0000-0000-000000000101',
    'a0000000-0000-0000-0000-000000000001', 'extender', 6);
  select * into r from registro_acciones where accion = 'licencia_extendida'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'MIGUEL' and r.detalle like '%Servivans%' and r.detalle like '%6 meses%',
    'auditoría 9: licencia_extendida de Servivans por 6 meses';

  s := pr_iniciar_sesion('ADMIN', '4321', 'panel');
  assert s -> 'usuario' ->> 'codigo' = 'ADMIN', 'auditoría 9: tras extender, ADMIN entra de nuevo';
end $$;

-- 10) Lectura: permisos y contenido.
do $$
declare
  reg jsonb; ok boolean; x jsonb; n int;
begin
  -- El administrador de la empresa SÍ lee su registro, con todo lo hecho.
  reg := pr_registro_empresa('a0000000-0000-0000-0000-000000000001',
                             'a0000000-0000-0000-0000-000000000102');
  assert jsonb_array_length(reg) >= 10, 'auditoría 10: el registro de Servivans trae las acciones';
  select count(*) into n from jsonb_array_elements(reg) it
  where it ->> 'accion' in ('inicio_sesion','conflicto_resuelto','especial_validada',
                            'voucher_generado','reporte_resuelto','cliente_borrado',
                            'pin_cambiado','pin_admin_reiniciado',
                            'licencia_suspendida','licencia_extendida');
  assert n >= 10, 'auditoría 10: están todas las acciones esperadas de Servivans';
  select it into x from jsonb_array_elements(reg) it
  where it ->> 'accion' = 'conflicto_resuelto' limit 1;
  assert x -> 'actor' ->> 'codigo' = 'COORD' or x -> 'actor' ->> 'codigo' = 'ADMIN',
    'auditoría 10: cada item trae su actor con código';

  -- Un CHOFER no puede leer el registro de su empresa.
  ok := false;
  begin perform pr_registro_empresa('a0000000-0000-0000-0000-000000000001',
                                    'a0000000-0000-0000-0000-000000000104');
  exception when others then ok := true; end;
  assert ok, 'auditoría 10: el chofer NO lee pr_registro_empresa';

  -- El COORDINADOR tampoco (solo rol empresa de la empresa o superadmin).
  ok := false;
  begin perform pr_registro_empresa('a0000000-0000-0000-0000-000000000001',
                                    'a0000000-0000-0000-0000-000000000103');
  exception when others then ok := true; end;
  assert ok, 'auditoría 10: el coordinador NO lee pr_registro_empresa';

  -- El registro global es solo del superadmin.
  ok := false;
  begin perform pr_admin_registro('a0000000-0000-0000-0000-000000000102');
  exception when others then ok := true; end;
  assert ok, 'auditoría 10: pr_admin_registro rechaza a un no-superadmin';

  -- Sin filtro: trae las dos empresas, cada item con el nombre de la suya.
  reg := pr_admin_registro('a0000000-0000-0000-0000-000000000101');
  select count(*) into n from jsonb_array_elements(reg) it
  where it ->> 'empresa' = 'Transportes Auditoría';
  assert n >= 1, 'auditoría 10: el registro global trae la empresa nueva con su nombre';
  select it into x from jsonb_array_elements(reg) it
  where it ->> 'accion' = 'empresa_creada' limit 1;
  assert x ->> 'empresa' = 'Transportes Auditoría',
    'auditoría 10: empresa_creada viene con el nombre de su empresa';

  -- Filtrado por Servivans: TODO lo devuelto es de Servivans.
  reg := pr_admin_registro('a0000000-0000-0000-0000-000000000101',
                           'a0000000-0000-0000-0000-000000000001');
  select count(*) into n from jsonb_array_elements(reg) it
  where it ->> 'empresa' is distinct from 'Servivans';
  assert n = 0, 'auditoría 10: el filtro por empresa no mezcla otras empresas';
  select count(*) into n from jsonb_array_elements(reg) it
  where it ->> 'accion' = 'empresa_creada';
  assert n = 0, 'auditoría 10: el filtro excluye la empresa creada (es de otra)';
end $$;

-- 11) Ningún PIN usado en esta prueba aparece en NINGÚN detalle.
do $$
declare n int;
begin
  select count(*) into n from registro_acciones
  where detalle like '%8642%' or detalle like '%4321%'
     or detalle like '%2468%' or detalle like '%1234%';
  assert n = 0, 'auditoría 11: ningún detalle del registro contiene un PIN';
end $$;

select 'PRUEBA DE AUDITORÍA OK' as resultado;
