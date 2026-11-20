-- Pago por Rutas — prueba de la extensión de la regla del dueño al
-- CRUD del panel (permisos-crud.sql)
-- Se corre sobre una base con la cadena completa aplicada
-- (esquema → conexion → semilla → app-datos → ajustes → acceso-roles
--  → auditoria → caducidad → permisos-dueno → permisos-crud) y la
-- semilla fresca.
--
-- La regla, ahora también en el CRUD: las 10 funciones de mutación
-- del panel que no recibían actor (usuarios, clientes, rutas,
-- feriados y opciones) ganan p_quien opcional al final de la firma.
-- Con p_quien = MIGUEL (superadmin) TODAS rechazan como primera
-- validación, con el mensaje exacto, y SIN tocar los datos. Con
-- p_quien = ADMIN funcionan y la auditoría ya lleva su actor. Sin
-- p_quien siguen funcionando como siempre (compatibilidad con los
-- paneles ya desplegados) y la fila queda sin actor.

-- 1) MIGUEL rechazado en las 10 funciones, mensaje exacto, sin efectos.
do $$
declare
  ok boolean; msg text; n int;
  v_nom text; v_precio numeric; v_act boolean; v_dias int; v_reg int;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  ch01 constant uuid := 'a0000000-0000-0000-0000-000000000104';
  cli constant uuid := 'a0000000-0000-0000-0000-000000000201';
  r01 constant uuid := 'a0000000-0000-0000-0000-000000000301';
  r02 constant uuid := 'a0000000-0000-0000-0000-000000000302';
  exacto constant text := 'El dueño de RutaNeto no opera dentro de la empresa: esto lo hace la administración de la empresa.';
begin
  -- Feriado base para probar pr_quitar_feriado (llamada SIN p_quien:
  -- de paso, compatibilidad). Lo que se registre a partir de aquí es
  -- lo que cuenta para verificar que los rechazos no dejan filas.
  perform pr_agregar_feriado(emp, date '2030-06-15', 'Feriado Base');
  select count(*) into v_reg from registro_acciones;

  -- Foto del estado que no debe cambiar.
  select nombre, precio into v_nom, v_precio from rutas where id = r01;
  select activo into v_act from clientes where id = cli;
  select dias_para_anotar into v_dias from opciones_empresa where empresa_id = emp;

  -- 1. pr_crear_usuario
  ok := false; msg := '';
  begin perform pr_crear_usuario(emp, 'Usuario Fantasma', 'XX-01', 'chofer', '1234', miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no crea usuarios (mensaje exacto)';
  assert not exists (select 1 from usuarios where codigo = 'XX-01'),
    'permisos-crud 1: el usuario fantasma no existe';

  -- 2. pr_cambiar_activo_usuario (intentando desactivar a CH-01)
  ok := false; msg := '';
  begin perform pr_cambiar_activo_usuario(ch01, false, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no activa/desactiva usuarios (mensaje exacto)';
  assert (select activo from usuarios where id = ch01),
    'permisos-crud 1: CH-01 sigue activo';

  -- 3. pr_crear_cliente
  ok := false; msg := '';
  begin perform pr_crear_cliente(emp, 'Cliente Fantasma', miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no crea clientes (mensaje exacto)';
  assert not exists (select 1 from clientes where nombre = 'Cliente Fantasma'),
    'permisos-crud 1: el cliente fantasma no existe';

  -- 4. pr_cambiar_activo_cliente (intentando desactivar San Isidro)
  ok := false; msg := '';
  begin perform pr_cambiar_activo_cliente(cli, false, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no activa/desactiva clientes (mensaje exacto)';
  assert (select activo from clientes where id = cli) = v_act,
    'permisos-crud 1: el cliente sigue como estaba';

  -- 5. pr_crear_ruta
  ok := false; msg := '';
  begin perform pr_crear_ruta(emp, 'R-XX', 'Ruta Fantasma', 100, null, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no crea rutas (mensaje exacto)';
  assert not exists (select 1 from rutas where codigo = 'R-XX'),
    'permisos-crud 1: la ruta fantasma no existe';

  -- 6. pr_actualizar_ruta (intentando renombrar R-01 y bajarle el precio)
  ok := false; msg := '';
  begin perform pr_actualizar_ruta(r01, 'Nombre Cambiado', 1, null, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no edita rutas (mensaje exacto)';
  assert (select nombre from rutas where id = r01) = v_nom
     and (select precio from rutas where id = r01) = v_precio,
    'permisos-crud 1: R-01 quedó intacta';

  -- 7. pr_cambiar_activa_ruta (intentando desactivar R-02)
  ok := false; msg := '';
  begin perform pr_cambiar_activa_ruta(r02, false, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no activa/desactiva rutas (mensaje exacto)';
  assert (select activa from rutas where id = r02),
    'permisos-crud 1: R-02 sigue activa';

  -- 8. pr_agregar_feriado
  ok := false; msg := '';
  begin perform pr_agregar_feriado(emp, date '2030-01-01', 'Fantasma', miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no agrega feriados (mensaje exacto)';
  assert not exists (select 1 from feriados where empresa_id = emp and fecha = date '2030-01-01'),
    'permisos-crud 1: el feriado fantasma no existe';

  -- 9. pr_quitar_feriado (intentando quitar el feriado base)
  ok := false; msg := '';
  begin perform pr_quitar_feriado(emp, date '2030-06-15', miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no quita feriados (mensaje exacto)';
  assert exists (select 1 from feriados where empresa_id = emp and fecha = date '2030-06-15'),
    'permisos-crud 1: el feriado base sigue';

  -- 10. pr_actualizar_opciones (intentando cambiar los días para anotar)
  ok := false; msg := '';
  begin perform pr_actualizar_opciones(emp, '{"diasParaAnotar": 7}'::jsonb, miguel);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok and msg = exacto, 'permisos-crud 1: MIGUEL no cambia opciones (mensaje exacto)';
  assert (select dias_para_anotar from opciones_empresa where empresa_id = emp) = v_dias,
    'permisos-crud 1: las opciones quedaron intactas';

  -- Ningún rechazo dejó fila en el registro.
  select count(*) into n from registro_acciones;
  assert n = v_reg, 'permisos-crud 1: los rechazos no registraron acciones';
end $$;

-- 2) ADMIN ejecuta las 10 con su id: funciona y la auditoría lo trae.
do $$
declare
  u usuarios; c clientes; rta rutas; r record;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
  admin constant uuid := 'a0000000-0000-0000-0000-000000000102';
  coord constant uuid := 'a0000000-0000-0000-0000-000000000103';
begin
  -- 1. Crear usuario.
  u := pr_crear_usuario(emp, 'Chofer Permisos CRUD', 'CH-77', 'chofer', '4321', admin);
  select * into r from registro_acciones where accion = 'usuario_creado'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN' and r.detalle like '%CH-77%',
    'permisos-crud 2: usuario_creado lleva a ADMIN como actor';

  -- 2. Desactivar ese usuario.
  perform pr_cambiar_activo_usuario(u.id, false, admin);
  assert not (select activo from usuarios where id = u.id),
    'permisos-crud 2: ADMIN desactivó al usuario';
  select * into r from registro_acciones where accion = 'usuario_editado'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN' and r.detalle like '%CH-77%',
    'permisos-crud 2: usuario_editado lleva a ADMIN como actor';

  -- 3. Crear cliente.
  c := pr_crear_cliente(emp, 'Cliente Permisos CRUD', admin);
  select * into r from registro_acciones where accion = 'cliente_creado'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN' and r.detalle like '%Cliente Permisos CRUD%',
    'permisos-crud 2: cliente_creado lleva a ADMIN como actor';

  -- 4. Desactivar ese cliente.
  perform pr_cambiar_activo_cliente(c.id, false, admin);
  assert not (select activo from clientes where id = c.id),
    'permisos-crud 2: ADMIN desactivó al cliente';
  select * into r from registro_acciones where accion = 'cliente_editado'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN' and r.detalle like '%Cliente Permisos CRUD%',
    'permisos-crud 2: cliente_editado lleva a ADMIN como actor';

  -- 5. Crear ruta (bajo el cliente de la prueba, ya desactivado: la
  --    función solo exige que el cliente sea de la empresa).
  rta := pr_crear_ruta(emp, 'R-77', 'Ruta Permisos CRUD', 450, c.id, admin);
  select * into r from registro_acciones where accion = 'ruta_creada'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN' and r.detalle like '%R-77%',
    'permisos-crud 2: ruta_creada lleva a ADMIN como actor';

  -- 6. Editar la ruta.
  perform pr_actualizar_ruta(rta.id, 'Ruta Permisos CRUD Editada', 475, c.id, admin);
  assert (select nombre from rutas where id = rta.id) = 'Ruta Permisos CRUD Editada'
     and (select precio from rutas where id = rta.id) = 475,
    'permisos-crud 2: ADMIN editó la ruta';
  select * into r from registro_acciones
  where accion = 'ruta_editada' and detalle like 'Se editó la ruta R-77%'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN',
    'permisos-crud 2: ruta_editada (edición) lleva a ADMIN como actor';

  -- 7. Desactivar la ruta.
  perform pr_cambiar_activa_ruta(rta.id, false, admin);
  assert not (select activa from rutas where id = rta.id),
    'permisos-crud 2: ADMIN desactivó la ruta';
  select * into r from registro_acciones
  where accion = 'ruta_editada' and detalle like 'Se desactivó la ruta R-77%'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN',
    'permisos-crud 2: ruta_editada (desactivación) lleva a ADMIN como actor';

  -- 8. Agregar feriado.
  perform pr_agregar_feriado(emp, date '2030-12-25', 'Navidad de prueba', admin);
  assert exists (select 1 from feriados where empresa_id = emp and fecha = date '2030-12-25'),
    'permisos-crud 2: ADMIN agregó el feriado';
  select * into r from registro_acciones
  where accion = 'feriado_agregado' and detalle like '%25/12/2030%'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN',
    'permisos-crud 2: feriado_agregado lleva a ADMIN como actor';

  -- 9. Quitar el feriado base del bloque 1.
  perform pr_quitar_feriado(emp, date '2030-06-15', admin);
  assert not exists (select 1 from feriados where empresa_id = emp and fecha = date '2030-06-15'),
    'permisos-crud 2: ADMIN quitó el feriado base';
  select * into r from registro_acciones
  where accion = 'feriado_borrado' and detalle like '%15/06/2030%'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN',
    'permisos-crud 2: feriado_borrado lleva a ADMIN como actor';

  -- 10. Cambiar opciones (y restaurar el valor que había).
  perform pr_actualizar_opciones(emp, '{"diasParaAnotar": 5}'::jsonb, admin);
  assert (select dias_para_anotar from opciones_empresa where empresa_id = emp) = 5,
    'permisos-crud 2: ADMIN cambió las opciones';
  select * into r from registro_acciones
  where accion = 'opciones_cambiadas' and detalle like '%diasParaAnotar%'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'ADMIN',
    'permisos-crud 2: opciones_cambiadas lleva a ADMIN como actor';
  perform pr_actualizar_opciones(emp, '{"diasParaAnotar": 1}'::jsonb, admin);

  -- La guarda es solo contra el dueño: COORD como p_quien pasa.
  perform pr_agregar_feriado(emp, date '2030-08-16', 'Feriado COORD', coord);
  select * into r from registro_acciones
  where accion = 'feriado_agregado' and detalle like '%16/08/2030%'
  order by creada_en desc limit 1;
  assert r.actor_codigo = 'COORD',
    'permisos-crud 2: con COORD como actor no hay rechazo y la fila lo trae';
  perform pr_quitar_feriado(emp, date '2030-08-16', admin);
  perform pr_quitar_feriado(emp, date '2030-12-25', admin);
end $$;

-- 3) Compatibilidad: sin p_quien el resto del CRUD sigue funcionando
--    como antes y las filas del registro quedan sin actor (no se
--    inventa). EXCEPCIÓN (correcciones 2026-11-19, crítico 4 de la
--    auditoría): pr_crear_usuario SIN actor era el hueco que dejaba
--    a cualquiera crearse un usuario con la anon key; ahora se
--    rechaza, y la vía válida es con actor de la empresa + PIN
--    explícito (la fila del registro SÍ lleva actor).
do $$
declare
  u usuarios; c clientes; r record; ok boolean;
  emp constant uuid := 'a0000000-0000-0000-0000-000000000001';
  admin constant uuid := 'a0000000-0000-0000-0000-000000000102';
begin
  c := pr_crear_cliente(emp, 'Cliente Compatibilidad');
  select * into r from registro_acciones where accion = 'cliente_creado'
  order by creada_en desc limit 1;
  assert r.actor_id is null and r.actor_codigo is null,
    'permisos-crud 3: sin p_quien, cliente_creado queda sin actor';

  ok := false;
  begin
    perform pr_crear_usuario(emp, 'Chofer Compatibilidad', 'CH-78', 'chofer');
  exception when others then ok := true; end;
  assert ok, 'permisos-crud 3: crear usuario SIN actor ahora se RECHAZA (crítico 4)';
  assert not exists (select 1 from usuarios where codigo = 'CH-78'),
    'permisos-crud 3: el intento sin actor no creó a nadie';

  u := pr_crear_usuario(emp, 'Chofer Compatibilidad', 'CH-78', 'chofer', '4321', admin);
  assert u.id is not null, 'permisos-crud 3: con actor y PIN explícito sí se crea';
  select * into r from registro_acciones where accion = 'usuario_creado'
  order by creada_en desc limit 1;
  assert r.actor_id = admin, 'permisos-crud 3: usuario_creado lleva al actor real';

  perform pr_cambiar_activo_usuario(u.id, false);
  assert not (select activo from usuarios where id = u.id),
    'permisos-crud 3: cambiar activo sin p_quien funciona';

  perform pr_crear_ruta(emp, 'R-78', 'Ruta Compatibilidad', 300, c.id);
  perform pr_actualizar_ruta(
    (select id from rutas where codigo = 'R-78'), 'Ruta Compatibilidad 2', 325, c.id);
  perform pr_cambiar_activa_ruta(
    (select id from rutas where codigo = 'R-78'), false);
  assert (select nombre from rutas where codigo = 'R-78') = 'Ruta Compatibilidad 2',
    'permisos-crud 3: rutas sin p_quien funcionan';

  perform pr_agregar_feriado(emp, date '2031-01-01', 'Compatibilidad');
  perform pr_quitar_feriado(emp, date '2031-01-01');
  assert not exists (select 1 from feriados where empresa_id = emp and fecha = date '2031-01-01'),
    'permisos-crud 3: feriados sin p_quien funcionan';

  perform pr_actualizar_opciones(emp, '{}'::jsonb);
  select * into r from registro_acciones where accion = 'opciones_cambiadas'
  order by creada_en desc limit 1;
  assert r.actor_id is null, 'permisos-crud 3: sin p_quien, opciones_cambiadas queda sin actor';
end $$;

-- 4) Forma final: UNA sola versión de cada función, con p_quien al
--    final (sin sobrecargas ambiguas para PostgREST).
do $$
declare n int; args int;
begin
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_crear_usuario';
  assert n = 1 and args = 7, 'permisos-crud 4: una sola pr_crear_usuario, de 7 argumentos (correcciones 2026-11-19: + p_token)';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_cambiar_activo_usuario';
  assert n = 1 and args = 3, 'permisos-crud 4: una sola pr_cambiar_activo_usuario, de 3 argumentos';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_crear_cliente';
  assert n = 1 and args = 3, 'permisos-crud 4: una sola pr_crear_cliente, de 3 argumentos';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_cambiar_activo_cliente';
  assert n = 1 and args = 3, 'permisos-crud 4: una sola pr_cambiar_activo_cliente, de 3 argumentos';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_crear_ruta';
  assert n = 1 and args = 7, 'permisos-crud 4: una sola pr_crear_ruta, de 7 argumentos (hora-rutas 2026-11-20: + p_hora)';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_actualizar_ruta';
  assert n = 1 and args = 6, 'permisos-crud 4: una sola pr_actualizar_ruta, de 6 argumentos (hora-rutas 2026-11-20: + p_hora)';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_cambiar_activa_ruta';
  assert n = 1 and args = 3, 'permisos-crud 4: una sola pr_cambiar_activa_ruta, de 3 argumentos';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_agregar_feriado';
  assert n = 1 and args = 4, 'permisos-crud 4: una sola pr_agregar_feriado, de 4 argumentos';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_quitar_feriado';
  assert n = 1 and args = 3, 'permisos-crud 4: una sola pr_quitar_feriado, de 3 argumentos';
  select count(*), max(pronargs) into n, args from pg_proc where proname = 'pr_actualizar_opciones';
  assert n = 1 and args = 4, 'permisos-crud 4: una sola pr_actualizar_opciones, de 4 argumentos (correcciones 2026-11-19: + p_token)';
end $$;

select 'PRUEBA DE PERMISOS CRUD OK' as resultado;
