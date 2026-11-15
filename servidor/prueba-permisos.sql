-- Pago por Rutas — prueba de la regla del dueño (permisos-dueno.sql)
-- Se corre sobre una base con la cadena completa aplicada
-- (esquema → conexion → semilla → app-datos → ajustes → acceso-roles
--  → auditoria → caducidad → permisos-dueno) y la semilla fresca.
--
-- La regla: el superadmin (MIGUEL) NO opera dentro de la empresa.
-- En cada función operativa que recibe actor es rechazado como
-- primera validación, con el mensaje exacto, y SIN tocar los datos.
-- La empresa (ADMIN / COORD) sigue operando normal, y el dueño
-- conserva su área: entrar a ver (panel), registros de supervisión,
-- licencias, crear empresas y LA excepción — reiniciar el PIN del
-- administrador de la empresa, verificado de punta a punta.

-- 1) MIGUEL rechazado en todo lo operativo, mensaje exacto, sin efectos.
do $$
declare
  ok boolean; msg text; n int; rep jsonb; est text;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  exacto constant text := 'El dueño de RutaNeto no opera dentro de la empresa: esto lo hace la administración de la empresa.';
begin
  -- Resolver un conflicto.
  ok := false; msg := '';
  begin perform pr_resolver_conflicto('a0000000-0000-0000-0000-000000000407', miguel, 'ambas');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos 1: MIGUEL no resuelve conflictos (mensaje exacto)';
  select estado into est from anotaciones where id = 'a0000000-0000-0000-0000-000000000407';
  assert est = 'conflicto', 'permisos 1: el conflicto sigue intacto';
  select estado into est from anotaciones where id = 'a0000000-0000-0000-0000-000000000406';
  assert est = 'conflicto', 'permisos 1: la otra anotación del conflicto sigue intacta';

  -- Validar una ruta especial.
  ok := false; msg := '';
  begin perform pr_validar_especial('a0000000-0000-0000-0000-000000000408', miguel, 500, true);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos 1: MIGUEL no valida especiales (mensaje exacto)';
  select estado into est from anotaciones where id = 'a0000000-0000-0000-0000-000000000408';
  assert est = 'especial_pendiente', 'permisos 1: la especial sigue pendiente';

  -- Rechazar una anotación a mano.
  ok := false; msg := '';
  begin perform pr_rechazar_anotacion('a0000000-0000-0000-0000-000000000401', miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos 1: MIGUEL no rechaza anotaciones (mensaje exacto)';
  select estado into est from anotaciones where id = 'a0000000-0000-0000-0000-000000000401';
  assert est = 'aprobada', 'permisos 1: la anotación sigue aprobada';

  -- Borrar una empresa cliente.
  ok := false; msg := '';
  begin perform pr_borrar_cliente('a0000000-0000-0000-0000-000000000202', miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos 1: MIGUEL no borra clientes (mensaje exacto)';
  select count(*) into n from clientes where id = 'a0000000-0000-0000-0000-000000000202';
  assert n = 1, 'permisos 1: el cliente Duarte sigue existiendo';

  -- Resolver un reporte (se crea uno de CH-01 para la prueba).
  rep := pr_enviar_reporte(emp, 'a0000000-0000-0000-0000-000000000104',
                           'averia', 'Prueba de permisos: avería de mentira');
  ok := false; msg := '';
  begin perform pr_resolver_reporte((rep ->> 'id')::uuid, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos 1: MIGUEL no resuelve reportes (mensaje exacto)';
  select estado into est from reportes where id = (rep ->> 'id')::uuid;
  assert est = 'nuevo', 'permisos 1: el reporte sigue nuevo';

  -- Generar un voucher pasándole su id.
  ok := false; msg := '';
  begin perform pr_generar_voucher(emp, 'a0000000-0000-0000-0000-000000000104',
                                   current_date, current_date, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos 1: MIGUEL no genera vouchers (mensaje exacto)';
  select count(*) into n from vouchers;
  assert n = 0, 'permisos 1: no se creó ningún voucher';
end $$;

-- 2) La empresa sigue operando normal (COORD y ADMIN).
do $$
declare
  v vouchers; r record; est text; ok boolean; msg text; c clientes; aid uuid;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
  admin constant uuid := 'a0000000-0000-0000-0000-000000000102';
  coord constant uuid := 'a0000000-0000-0000-0000-000000000103';
begin
  -- COORD resuelve el conflicto de la semilla aprobando ambas.
  perform pr_resolver_conflicto('a0000000-0000-0000-0000-000000000407', coord, 'ambas');
  select estado into est from anotaciones where id = 'a0000000-0000-0000-0000-000000000406';
  assert est = 'aprobada', 'permisos 2: COORD resolvió el conflicto (ambas, 406)';
  select estado into est from anotaciones where id = 'a0000000-0000-0000-0000-000000000407';
  assert est = 'aprobada', 'permisos 2: COORD resolvió el conflicto (ambas, 407)';

  -- COORD valida la especial pendiente de CH-01 con precio 800.
  perform pr_validar_especial('a0000000-0000-0000-0000-000000000408', coord, 800, true);
  select estado into est from anotaciones where id = 'a0000000-0000-0000-0000-000000000408';
  assert est = 'aprobada', 'permisos 2: COORD validó la especial';

  -- ADMIN genera el voucher de CH-01 PASANDO su id: funciona y la
  -- auditoría ya lleva su actor (antes la firma no lo traía).
  v := pr_generar_voucher(emp, 'a0000000-0000-0000-0000-000000000104',
                          current_date, current_date, admin);
  assert v.folio = 1 and v.total = 800, 'permisos 2: voucher de ADMIN, folio 1 por 800';
  select * into r from registro_acciones
  where accion = 'voucher_generado' and detalle like '%CH-01%'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN', 'permisos 2: el voucher generado con p_quien lleva su actor';

  -- Sin p_quien (la llamada de siempre, 4 argumentos) sigue funcionando
  -- y la fila queda sin actor, como antes.
  v := pr_generar_voucher(emp, 'a0000000-0000-0000-0000-000000000105',
                          current_date, current_date);
  assert v.folio = 2 and v.total = 1200, 'permisos 2: voucher sin p_quien, folio 2 por 1200';
  select * into r from registro_acciones
  where accion = 'voucher_generado' and detalle like '%CH-02%'
  order by creada_en desc limit 1;
  assert r.actor_id is null, 'permisos 2: sin p_quien, la fila queda sin actor';

  -- ADMIN resuelve el reporte creado en el bloque 1.
  perform pr_resolver_reporte(
    (select id from reportes where mensaje like 'Prueba de permisos%' and estado = 'nuevo'),
    admin);
  select estado into est from reportes where mensaje like 'Prueba de permisos%';
  assert est = 'resuelto', 'permisos 2: ADMIN resolvió el reporte';

  -- Borrar cliente sigue siendo SOLO del administrador de la empresa:
  -- COORD no puede y ADMIN sí.
  c := pr_crear_cliente(emp, 'Cliente Permisos');
  ok := false; msg := '';
  begin perform pr_borrar_cliente(c.id, coord);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg like '%Solo un administrador%',
    'permisos 2: COORD sigue sin poder borrar clientes';
  perform pr_borrar_cliente(c.id, admin);
  assert (select count(*) from clientes where id = c.id) = 0,
    'permisos 2: ADMIN borró el cliente de la prueba';

  -- ADMIN rechaza a mano una anotación en conflicto (CH-03 anota R-05,
  -- que ya tiene aprobada CH-02 hoy: nace en conflicto).
  perform pr_anotar_ruta(emp, 'a0000000-0000-0000-0000-000000000106',
                         'a0000000-0000-0000-0000-000000000305', current_date);
  select id into aid from anotaciones
  where chofer_id = 'a0000000-0000-0000-0000-000000000106'
    and ruta_id = 'a0000000-0000-0000-0000-000000000305' and fecha = current_date;
  perform pr_rechazar_anotacion(aid, admin);
  select estado into est from anotaciones where id = aid;
  assert est = 'rechazada', 'permisos 2: ADMIN rechazó la anotación a mano';
end $$;

-- 3) El dueño conserva su área (consulta, licencias, empresas y la
--    excepción del PIN), todo verificado de punta a punta.
do $$
declare
  s jsonb; reg jsonb; e jsonb; cod text; ok boolean; est text;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
begin
  -- Entra por la puerta 'panel' a VER (modo consulta).
  s := pr_iniciar_sesion('MIGUEL', '1234', 'panel');
  assert s -> 'usuario' ->> 'rol' = 'superadmin', 'permisos 3: MIGUEL entra por panel a ver';

  -- Lee los registros de supervisión.
  reg := pr_registro_empresa(emp, miguel);
  assert jsonb_typeof(reg) = 'array' and jsonb_array_length(reg) >= 1,
    'permisos 3: MIGUEL lee pr_registro_empresa';
  reg := pr_admin_registro(miguel);
  assert jsonb_typeof(reg) = 'array', 'permisos 3: MIGUEL lee pr_admin_registro';

  -- Foto de supervisión y resumen de su panel.
  s := pr_snapshot(emp);
  assert s is not null, 'permisos 3: MIGUEL lee pr_snapshot';
  s := pr_admin_resumen(miguel);
  assert (s -> 'totales' ->> 'empresas')::int >= 1, 'permisos 3: MIGUEL lee pr_admin_resumen';

  -- Licencias: suspender y extender siguen siendo suyas.
  perform pr_admin_licencia(miguel, emp, 'suspender');
  select estado into est from licencias where empresa_id = emp
  order by creada_en desc limit 1;
  assert est = 'suspendida', 'permisos 3: MIGUEL suspendió la licencia';
  perform pr_admin_licencia(miguel, emp, 'extender', 6);
  select estado into est from licencias where empresa_id = emp
  order by creada_en desc limit 1;
  assert est = 'activa', 'permisos 3: MIGUEL extendió y la licencia volvió a activa';

  -- Crear empresas sigue siendo suyo.
  e := pr_admin_crear_empresa(miguel, 'Transportes Permisos', 5, 6,
                              'TPM-ADMIN', '1357', 'Admin Permisos');
  assert (e -> 'empresa' ->> 'id') is not null, 'permisos 3: MIGUEL creó una empresa';

  -- LA EXCEPCIÓN, de punta a punta: reinicia el PIN del admin de
  -- Servivans y ese admin entra con el PIN nuevo (y ya no con el viejo).
  cod := pr_admin_pin_admin(miguel, emp, '9753');
  assert cod = 'ADMIN', 'permisos 3: el reinicio devuelve el código del admin';
  s := pr_iniciar_sesion('ADMIN', '9753', 'panel');
  assert s -> 'usuario' ->> 'codigo' = 'ADMIN', 'permisos 3: ADMIN entra con el PIN reiniciado';
  ok := false;
  begin perform pr_iniciar_sesion('ADMIN', '1234', 'panel');
  exception when others then ok := true; end;
  assert ok, 'permisos 3: ADMIN ya no entra con el PIN viejo';

  -- Cambiar SU propio PIN también sigue permitido (y se restaura).
  assert pr_cambiar_pin(miguel, '1234', '8642'), 'permisos 3: MIGUEL cambió su propio PIN';
  s := pr_iniciar_sesion('MIGUEL', '8642', 'admin');
  assert s -> 'usuario' ->> 'codigo' = 'MIGUEL', 'permisos 3: MIGUEL entra con su PIN nuevo';
  assert pr_cambiar_pin(miguel, '8642', '1234'), 'permisos 3: PIN de MIGUEL restaurado';
end $$;

-- 4) Forma final: una sola pr_generar_voucher, de 5 argumentos.
do $$
declare n int; args int;
begin
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_generar_voucher';
  assert n = 1, 'permisos 4: existe UNA sola pr_generar_voucher (sin sobrecargas ambiguas)';
  assert args = 5, 'permisos 4: la firma final tiene 5 argumentos (p_quien al final)';
end $$;

select 'PRUEBA DE PERMISOS OK' as resultado;
