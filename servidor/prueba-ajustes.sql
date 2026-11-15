-- Prueba de ajustes 2026-11-15 — se corre sobre una base con esquema.sql +
-- conexion.sql + semilla.sql + app-datos.sql + ajustes-2026-11-15.sql,
-- DESPUÉS de prueba-app.sql y prueba-conexion.sql (que ya resolvieron el
-- conflicto de la semilla y limpiaron su propio CRUD).
-- IDs de la semilla: empresa …001, MIGUEL …101, ADMIN …102, COORD …103,
-- CH-01 …104, CH-02 …105, CH-03 …106, clientes …201/…202, rutas …301-305.

-- 1) diasParaAnotar viene en la sesión y en el snapshot; la semilla queda en 1.
do $$
declare s jsonb;
begin
  s := pr_iniciar_sesion('CH-01', '1234');
  assert (s -> 'opciones' ->> 'diasParaAnotar')::int = 1,
    'ajustes 1: la sesión de CH-01 trae diasParaAnotar = 1';
  s := pr_snapshot('a0000000-0000-0000-0000-000000000001');
  assert (s -> 'opciones' ->> 'diasParaAnotar')::int = 1,
    'ajustes 1: el snapshot trae diasParaAnotar = 1';
end $$;

-- 2) Panel del superadmin: resumen, alta de empresa y manejo de licencia.
do $$
declare
  r jsonb; e jsonb; s jsonb; ok boolean; msg text;
  tp uuid; vence0 date; lic jsonb; n int;
begin
  -- Un no-superadmin no puede usar ninguna pr_admin_*.
  ok := false;
  begin perform pr_admin_resumen('a0000000-0000-0000-0000-000000000102');
  exception when others then ok := true; end;
  assert ok, 'ajustes 2: pr_admin_resumen rechaza al ADMIN de una empresa';
  ok := false;
  begin perform pr_admin_crear_empresa('a0000000-0000-0000-0000-000000000102',
    'Empresa Intrusa', 5, 6, 'INT-ADMIN', '1234', 'Intruso');
  exception when others then ok := true; end;
  assert ok, 'ajustes 2: pr_admin_crear_empresa rechaza a un no-superadmin';
  ok := false;
  begin perform pr_admin_licencia('a0000000-0000-0000-0000-000000000103',
    'a0000000-0000-0000-0000-000000000001', 'suspender');
  exception when others then ok := true; end;
  assert ok, 'ajustes 2: pr_admin_licencia rechaza al coordinador';

  -- Resumen inicial: solo Servivans (3 choferes, 2 clientes, 5 rutas).
  r := pr_admin_resumen('a0000000-0000-0000-0000-000000000101');
  assert (r -> 'totales' ->> 'empresas')::int = 1, 'ajustes 2: totales 1 empresa';
  assert (r -> 'totales' ->> 'empresasActivas')::int = 1, 'ajustes 2: totales 1 activa';
  assert (r -> 'totales' ->> 'choferes')::int = 3, 'ajustes 2: totales 3 choferes';
  select x into e from jsonb_array_elements(r -> 'empresas') x
  where x ->> 'nombre' = 'Servivans';
  assert (e ->> 'numChoferes')::int = 3, 'ajustes 2: Servivans 3 choferes';
  assert (e ->> 'numClientes')::int = 2, 'ajustes 2: Servivans 2 clientes';
  assert (e ->> 'numRutas')::int = 5, 'ajustes 2: Servivans 5 rutas';
  assert e -> 'licencia' ->> 'estado' = 'activa', 'ajustes 2: Servivans licencia activa';
  assert (e -> 'licencia' ->> 'maxChoferes')::int = 15, 'ajustes 2: Servivans máx. 15';

  -- Alta completa de una empresa nueva.
  e := pr_admin_crear_empresa('a0000000-0000-0000-0000-000000000101',
    'Transporte Prueba', 10, 6, 'TP-ADMIN', '4321', 'Admin Prueba');
  tp := (e -> 'empresa' ->> 'id')::uuid;
  assert e -> 'empresa' ->> 'nombre' = 'Transporte Prueba', 'ajustes 2: empresa creada';
  assert e -> 'admin' ->> 'codigo' = 'TP-ADMIN', 'ajustes 2: admin TP-ADMIN creado';
  vence0 := (e -> 'licencia' ->> 'vence')::date;
  assert vence0 = (current_date + interval '6 months')::date,
    'ajustes 2: la licencia vence en 6 meses';

  -- Duplicados: nombre de empresa y código de administrador.
  ok := false; msg := '';
  begin perform pr_admin_crear_empresa('a0000000-0000-0000-0000-000000000101',
    'transporte prueba', 5, 6, 'OTRO-ADMIN', '1234', 'Otro');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%Ya existe una empresa con el nombre%',
    'ajustes 2: nombre duplicado rechazado';
  ok := false; msg := '';
  begin perform pr_admin_crear_empresa('a0000000-0000-0000-0000-000000000101',
    'Otra Empresa', 5, 6, 'TP-ADMIN', '1234', 'Otro');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%Ya existe un administrador con el código%',
    'ajustes 2: código de admin repetido rechazado';

  -- El admin nuevo entra con su PIN y trae las opciones por defecto.
  s := pr_iniciar_sesion('TP-ADMIN', '4321');
  assert s -> 'empresa' ->> 'nombre' = 'Transporte Prueba', 'ajustes 2: TP-ADMIN entra';
  assert (s -> 'opciones' ->> 'rutasEmpresaPorDia')::int = 5, 'ajustes 2: TP cupo 5';
  assert (s -> 'opciones' ->> 'diasParaAnotar')::int = 1, 'ajustes 2: TP días 1';

  -- Suspender: el admin ya NO puede entrar.
  lic := pr_admin_licencia('a0000000-0000-0000-0000-000000000101', tp, 'suspender');
  assert lic ->> 'estado' = 'suspendida', 'ajustes 2: licencia suspendida';
  ok := false; msg := '';
  begin perform pr_iniciar_sesion('TP-ADMIN', '4321');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%suspendida%',
    'ajustes 2: con la licencia suspendida no hay sesión';

  -- Extender sin meses: error. Extender 6: activa y vence = vence anterior + 6.
  ok := false;
  begin perform pr_admin_licencia('a0000000-0000-0000-0000-000000000101', tp, 'extender');
  exception when others then ok := true; end;
  assert ok, 'ajustes 2: extender sin meses da error';
  lic := pr_admin_licencia('a0000000-0000-0000-0000-000000000101', tp, 'extender', 6);
  assert lic ->> 'estado' = 'activa', 'ajustes 2: extender reactiva la licencia';
  assert (lic ->> 'vence')::date = (vence0 + interval '6 months')::date,
    'ajustes 2: extender suma 6 meses al vencimiento';
  perform pr_iniciar_sesion('TP-ADMIN', '4321'); -- vuelve a entrar

  -- Activar tras suspender, y acción inválida.
  perform pr_admin_licencia('a0000000-0000-0000-0000-000000000101', tp, 'suspender');
  lic := pr_admin_licencia('a0000000-0000-0000-0000-000000000101', tp, 'activar');
  assert lic ->> 'estado' = 'activa', 'ajustes 2: activar deja la licencia activa';
  perform pr_iniciar_sesion('TP-ADMIN', '4321');
  ok := false;
  begin perform pr_admin_licencia('a0000000-0000-0000-0000-000000000101', tp, 'borrar');
  exception when others then ok := true; end;
  assert ok, 'ajustes 2: acción inválida rechazada';

  -- El resumen ya cuenta 2 empresas.
  r := pr_admin_resumen('a0000000-0000-0000-0000-000000000101');
  assert (r -> 'totales' ->> 'empresas')::int = 2, 'ajustes 2: totales 2 empresas';

  -- Borrar clientes entre empresas: ni el admin de Servivans puede borrar
  -- un cliente de Transporte Prueba, ni el de TP uno de Servivans.
  perform pr_crear_cliente(tp, 'Cliente de TP');
  ok := false; msg := '';
  begin perform pr_borrar_cliente(
    (select id from clientes where empresa_id = tp and nombre = 'Cliente de TP'),
    'a0000000-0000-0000-0000-000000000102');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%no pertenece a tu empresa%',
    'ajustes 2: ADMIN de Servivans no borra clientes de otra empresa';
  ok := false;
  begin perform pr_borrar_cliente('a0000000-0000-0000-0000-000000000202',
    (select id from usuarios where codigo = 'TP-ADMIN'));
  exception when others then ok := true; end;
  assert ok, 'ajustes 2: TP-ADMIN no borra clientes de Servivans';
  select count(*) into n from clientes
  where id = 'a0000000-0000-0000-0000-000000000202';
  assert n = 1, 'ajustes 2: el cliente Duarte sigue intacto';
end $$;

-- 3) Borrar empresa cliente: solo administradores, con confirmación de
-- efectos (las rutas que lo referencian quedan en General).
do $$
declare
  c clientes; r rutas; ok boolean; msg text; n int;
begin
  c := pr_crear_cliente('a0000000-0000-0000-0000-000000000001', 'Cliente Borrable');
  r := pr_crear_ruta('a0000000-0000-0000-0000-000000000001', 'R-98', 'Ruta del Borrable', 300, c.id);
  assert r.cliente_id = c.id, 'ajustes 3: la ruta nace con su cliente';

  ok := false; msg := '';
  begin perform pr_borrar_cliente(c.id, 'a0000000-0000-0000-0000-000000000103');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%Solo un administrador%',
    'ajustes 3: el coordinador NO puede borrar clientes';
  ok := false;
  begin perform pr_borrar_cliente(c.id, 'a0000000-0000-0000-0000-000000000104');
  exception when others then ok := true; end;
  assert ok, 'ajustes 3: el chofer NO puede borrar clientes';

  perform pr_borrar_cliente(c.id, 'a0000000-0000-0000-0000-000000000102'); -- ADMIN sí
  select count(*) into n from clientes where id = c.id;
  assert n = 0, 'ajustes 3: el cliente quedó borrado';
  select cliente_id into r.cliente_id from rutas where id = r.id;
  assert r.cliente_id is null, 'ajustes 3: su ruta quedó en General (cliente null)';

  ok := false; msg := '';
  begin perform pr_borrar_cliente('ffffffff-ffff-ffff-ffff-ffffffffffff',
    'a0000000-0000-0000-0000-000000000102');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%no existe%', 'ajustes 3: borrar un cliente inexistente da error';

  -- Regla del dueño (permisos-dueno.sql): el superadmin YA NO borra
  -- clientes de una empresa — lo hace la administración de la empresa.
  ok := false; msg := '';
  begin perform pr_borrar_cliente(
    (select id from clientes where nombre = 'Cliente de TP'),
    'a0000000-0000-0000-0000-000000000101');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%no opera dentro de la empresa%',
    'ajustes 3: el superadmin ya NO puede borrar clientes (regla del dueño)';
  -- Limpieza de lo creado aquí: lo borra el admin de Transporte Prueba.
  perform pr_borrar_cliente(
    (select id from clientes where nombre = 'Cliente de TP'),
    (select id from usuarios where codigo = 'TP-ADMIN'));
  delete from rutas where id = r.id;
end $$;

-- 4) Plazo de anotación en días: con 1, con 7 y con 0.
do $$
declare
  u usuarios; r rutas; o opciones_empresa; s jsonb;
  ok boolean; msg text; n int;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
begin
  u := pr_crear_usuario(emp, 'Chofer Plazos', 'CH-04', 'chofer');
  r := pr_crear_ruta(emp, 'R-99', 'Ruta de Plazos', 100);

  -- dias = 1 (defecto de la semilla): hoy y ayer sí; hace 2 días y mañana no.
  perform pr_anotar_ruta(emp, u.id, r.id, current_date);
  perform pr_anotar_ruta(emp, u.id, r.id, current_date - 1);
  ok := false; msg := '';
  begin perform pr_anotar_ruta(emp, u.id, r.id, current_date - 2);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%Fuera del plazo%' and msg like '%hasta 1 día(s)%',
    'ajustes 4: hace 2 días con dias=1 se rechaza con el mensaje del plazo';
  ok := false; msg := '';
  begin perform pr_anotar_ruta(emp, u.id, r.id, current_date + 1);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%Fuera del plazo%', 'ajustes 4: una fecha futura se rechaza';
  perform pr_anotar_especial(emp, u.id, 'Especial de hoy', null, current_date);
  ok := false; msg := '';
  begin perform pr_anotar_especial(emp, u.id, 'Especial vieja', null, current_date - 2);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%Fuera del plazo%', 'ajustes 4: la especial también respeta el plazo';

  -- dias = 7 desde las opciones del panel.
  select * into o from pr_actualizar_opciones(emp, '{"diasParaAnotar": 7}'::jsonb);
  assert o.dias_para_anotar = 7, 'ajustes 4: las opciones guardan diasParaAnotar = 7';
  s := pr_iniciar_sesion('CH-01', '1234');
  assert (s -> 'opciones' ->> 'diasParaAnotar')::int = 7,
    'ajustes 4: la sesión ya trae diasParaAnotar = 7';
  perform pr_anotar_ruta(emp, u.id, r.id, current_date - 5);
  ok := false; msg := '';
  begin perform pr_anotar_ruta(emp, u.id, r.id, current_date - 8);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%hasta 7 día(s)%',
    'ajustes 4: hace 8 días con dias=7 se rechaza';

  -- dias = 0: solo hoy.
  perform pr_actualizar_opciones(emp, '{"diasParaAnotar": 0}'::jsonb);
  ok := false;
  begin perform pr_anotar_ruta(emp, u.id, r.id, current_date - 1);
  exception when others then ok := true; end;
  assert ok, 'ajustes 4: con dias=0 ayer ya no se puede anotar';
  perform pr_anotar_ruta(emp, u.id, r.id, current_date);

  -- Fuera de rango desde el panel: error claro.
  ok := false; msg := '';
  begin perform pr_actualizar_opciones(emp, '{"diasParaAnotar": 40}'::jsonb);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%entre 0 y 30%', 'ajustes 4: diasParaAnotar fuera de rango rechazado';

  -- Se deja la semilla como estaba (dias = 1).
  perform pr_actualizar_opciones(emp, '{"diasParaAnotar": 1}'::jsonb);
  s := pr_iniciar_sesion('CH-01', '1234');
  assert (s -> 'opciones' ->> 'diasParaAnotar')::int = 1, 'ajustes 4: dias vuelve a 1';
  select count(*) into n from anotaciones where chofer_id = u.id and estado = 'aprobada';
  assert n = 4, 'ajustes 4: quedaron 4 anotaciones válidas de CH-04 (hoy x2, ayer, hace 5)';

  -- Limpieza: lo creado para el plazo no queda en la base (así las demás
  -- pruebas, que buscan la especial pendiente sin filtrar empresa, no se
  -- cruzan con estos datos).
  delete from anotaciones where chofer_id = u.id;
  delete from rutas where id = r.id;
  delete from usuarios where id = u.id;
end $$;

-- 5) Reportes a administración: chofer y coordinador, con destaque.
do $$
declare
  r1 jsonb; r2 jsonb; lista jsonb; ok boolean; msg text; n int;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
begin
  r1 := pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000104',
    'calle_cerrada', 'Calle cerrada en el centro, desvío por la Duarte');
  assert (r1 ->> 'esCoordinador')::boolean = false, 'ajustes 5: reporte de chofer sin destaque';
  assert r1 ->> 'estado' = 'nuevo', 'ajustes 5: el reporte nace nuevo';
  assert r1 -> 'autor' ->> 'codigo' = 'CH-01', 'ajustes 5: autor CH-01';

  ok := false;
  begin perform pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000104',
    'inventado', 'tipo malo');
  exception when others then ok := true; end;
  assert ok, 'ajustes 5: un tipo de reporte inválido se rechaza';
  ok := false; msg := '';
  begin perform pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000102',
    'otro', 'el admin no reporta por la app');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%choferes y coordinadores%',
    'ajustes 5: el rol empresa no envía reportes';

  r2 := pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000103',
    'averia', 'Autobús varado en la ruta R-03');
  assert (r2 ->> 'esCoordinador')::boolean = true, 'ajustes 5: reporte de coordinador destacado';

  -- Listar: el chofer no puede; la empresa sí, y el del coordinador va primero.
  ok := false;
  begin perform pr_listar_reportes(emp, 'a0000000-0000-0000-0000-000000000104');
  exception when others then ok := true; end;
  assert ok, 'ajustes 5: el chofer no puede listar reportes';
  lista := pr_listar_reportes(emp, 'a0000000-0000-0000-0000-000000000102');
  assert jsonb_array_length(lista) >= 2, 'ajustes 5: la lista trae los 2 reportes';
  assert (lista -> 0 ->> 'esCoordinador')::boolean = true,
    'ajustes 5: entre los nuevos, el del coordinador va primero';
  assert lista -> 0 -> 'autor' ->> 'codigo' = 'COORD', 'ajustes 5: primero el de COORD';
  lista := pr_listar_reportes(emp, 'a0000000-0000-0000-0000-000000000101');
  assert jsonb_array_length(lista) >= 2, 'ajustes 5: el superadmin también lista';

  -- Resolver: el chofer no; el coordinador sí; dos veces no.
  ok := false;
  begin perform pr_resolver_reporte((r1 ->> 'id')::uuid, 'a0000000-0000-0000-0000-000000000105');
  exception when others then ok := true; end;
  assert ok, 'ajustes 5: el chofer no puede resolver reportes';
  r1 := pr_resolver_reporte((r1 ->> 'id')::uuid, 'a0000000-0000-0000-0000-000000000103');
  assert r1 ->> 'estado' = 'resuelto', 'ajustes 5: el reporte quedó resuelto';
  select count(*) into n from reportes
  where id = (r1 ->> 'id')::uuid and resuelto_por = 'a0000000-0000-0000-0000-000000000103'
    and resuelto_en is not null;
  assert n = 1, 'ajustes 5: quedó quién y cuándo lo resolvió';
  ok := false; msg := '';
  begin perform pr_resolver_reporte((r1 ->> 'id')::uuid, 'a0000000-0000-0000-0000-000000000103');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%ya está resuelto%', 'ajustes 5: resolver dos veces da error';
end $$;

-- 6) Cambio de PIN: el propio con el actual, y reinicio por el superadmin.
do $$
declare
  ok boolean; msg text; cod text; s jsonb;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
  ch02 constant uuid := 'a0000000-0000-0000-0000-000000000105';
begin
  -- PIN actual incorrecto.
  ok := false; msg := '';
  begin perform pr_cambiar_pin(ch02, '0000', '5678');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = 'El PIN actual no es correcto',
    'ajustes 6: PIN actual incorrecto rechazado con su mensaje';
  -- PIN nuevo demasiado corto.
  ok := false; msg := '';
  begin perform pr_cambiar_pin(ch02, '1234', '12');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%al menos 4 caracteres%', 'ajustes 6: PIN nuevo corto rechazado';
  -- Cambio bueno: entra con el nuevo, ya no con el viejo.
  assert pr_cambiar_pin(ch02, '1234', '5678'), 'ajustes 6: cambiar el PIN devuelve ok';
  s := pr_iniciar_sesion('CH-02', '5678');
  assert s -> 'usuario' ->> 'codigo' = 'CH-02', 'ajustes 6: CH-02 entra con el PIN nuevo';
  ok := false;
  begin perform pr_iniciar_sesion('CH-02', '1234');
  exception when others then ok := true; end;
  assert ok, 'ajustes 6: CH-02 ya no entra con el PIN viejo';
  assert pr_cambiar_pin(ch02, '5678', '1234'), 'ajustes 6: PIN de CH-02 restaurado';

  -- Reinicio por superadmin: un no-superadmin no puede.
  ok := false;
  begin perform pr_admin_pin_admin('a0000000-0000-0000-0000-000000000102', emp, '9999');
  exception when others then ok := true; end;
  assert ok, 'ajustes 6: pr_admin_pin_admin rechaza a un no-superadmin';
  cod := pr_admin_pin_admin('a0000000-0000-0000-0000-000000000101', emp, '9999');
  assert cod = 'ADMIN', 'ajustes 6: el reinicio devuelve el código del admin';
  ok := false;
  begin perform pr_iniciar_sesion('ADMIN', '1234');
  exception when others then ok := true; end;
  assert ok, 'ajustes 6: ADMIN ya no entra con el PIN viejo';
  s := pr_iniciar_sesion('ADMIN', '9999');
  assert s -> 'usuario' ->> 'rol' = 'empresa', 'ajustes 6: ADMIN entra con el PIN reiniciado';
  -- Se deja el PIN de arranque como estaba.
  perform pr_admin_pin_admin('a0000000-0000-0000-0000-000000000101', emp, '1234');
  perform pr_iniciar_sesion('ADMIN', '1234');
end $$;

select 'PRUEBA DE AJUSTES OK' as resultado;
