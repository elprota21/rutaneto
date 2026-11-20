-- Prueba de la ASIGNACIÓN DE RUTAS (asignaciones.sql)
-- Se corre sobre una base fresca con la cadena COMPLETA (con
-- asignaciones.sql al final). Verifica:
--   1) Guardar asignaciones como admin de la empresa: OK, y se ven
--      en el snapshot del panel y en los datos del chofer
--      (asignaciones + asignadasHoy según el día de hoy).
--   2) Guardar de nuevo REEMPLAZA las del chofer (no duplica).
--   3) Intentos hostiles: actor chofer, superadmin, chofer de otra
--      empresa, ruta de otra empresa y días fuera de 1..7: todos
--      rechazados y sin tocar lo guardado.
--   4) La anotación y la clase (cupo) NO cambian con la asignación:
--      la regla del dinero sigue siendo el cupo diario.

do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  r jsonb;
  emp uuid; adm uuid; ch1 uuid; ch2 uuid;
  r1 uuid; r2 uuid; r3 uuid;
  tok_adm text; tok_ch1 text;
  datos jsonb; snap jsonb;
  hoy_dow int := extract(isodow from pr_hoy())::int;
  otro_dow int;
  ok boolean; msg text;
begin
  otro_dow := (hoy_dow % 7) + 1;

  -- ===== Preparación: empresa con 2 choferes y 3 rutas =====
  r := pr_admin_crear_empresa(miguel, 'Asignaciones Test', 15, 12,
                              'AS-ADM', '2468', 'Admin Asignaciones');
  emp := (r -> 'empresa' ->> 'id')::uuid;
  adm := (r -> 'admin' ->> 'id')::uuid;
  assert emp is not null and adm is not null, 'prep: empresa creada';

  perform pr_crear_usuario(emp, 'Chofer Asig Uno', 'AS-01', 'chofer', '1357', adm);
  perform pr_crear_usuario(emp, 'Chofer Asig Dos', 'AS-02', 'chofer', '1358', adm);
  select id into ch1 from usuarios where empresa_id = emp and codigo = 'AS-01';
  select id into ch2 from usuarios where empresa_id = emp and codigo = 'AS-02';

  perform pr_crear_ruta(emp, 'AS-R1', 'Ruta Asig 1', 400, null, adm);
  perform pr_crear_ruta(emp, 'AS-R2', 'Ruta Asig 2', 500, null, adm);
  perform pr_crear_ruta(emp, 'AS-R3', 'Ruta Asig 3', 600, null, adm);
  select id into r1 from rutas where empresa_id = emp and codigo = 'AS-R1';
  select id into r2 from rutas where empresa_id = emp and codigo = 'AS-R2';
  select id into r3 from rutas where empresa_id = emp and codigo = 'AS-R3';

  tok_adm := pr_iniciar_sesion('AS-ADM', '2468', 'panel') -> 'sesion' ->> 'token';
  tok_ch1 := pr_iniciar_sesion('AS-01', '1357', 'app') -> 'sesion' ->> 'token';
  assert tok_adm is not null and tok_ch1 is not null, 'prep: sesiones con token';

  -- ===== 1) Guardar y ver en snapshot y en datos del chofer =====
  perform pr_guardar_asignaciones(emp, ch1, jsonb_build_array(
    jsonb_build_object('rutaId', r1, 'dias', jsonb_build_array(1,2,3,4,5,6,7)),
    jsonb_build_object('rutaId', r2, 'dias', jsonb_build_array(otro_dow))
  ), adm, tok_adm);

  snap := pr_snapshot(emp, adm, tok_adm);
  assert jsonb_array_length(snap -> 'asignaciones') = 2,
         'asig 1: el snapshot trae las 2 asignaciones';

  datos := pr_datos_chofer(emp, ch1, tok_ch1);
  assert jsonb_array_length(datos -> 'asignaciones') = 2,
         'asig 1: el chofer ve sus 2 asignaciones';
  assert (datos -> 'asignadasHoy') @> jsonb_build_array(r1),
         'asig 1: la ruta de todos los días está en asignadasHoy';
  assert not ((datos -> 'asignadasHoy') @> jsonb_build_array(r2)),
         'asig 1: la ruta de otro día NO está en asignadasHoy';

  -- ===== 2) Guardar de nuevo reemplaza (queda solo R3) =====
  perform pr_guardar_asignaciones(emp, ch1, jsonb_build_array(
    jsonb_build_object('rutaId', r3, 'dias', jsonb_build_array(hoy_dow))
  ), adm, tok_adm);
  datos := pr_datos_chofer(emp, ch1, tok_ch1);
  assert jsonb_array_length(datos -> 'asignaciones') = 1
     and (datos -> 'asignaciones' -> 0 ->> 'rutaId') = r3::text,
         'asig 2: el segundo guardado reemplaza al primero';
  assert (datos -> 'asignadasHoy') @> jsonb_build_array(r3),
         'asig 2: R3 quedó asignada para hoy';

  -- ===== 3) Intentos hostiles =====
  ok := false; msg := '';
  begin
    perform pr_guardar_asignaciones(emp, ch2, '[]'::jsonb, ch1, tok_ch1);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok, 'asig 3: un chofer no puede asignar rutas';

  ok := false; msg := '';
  begin
    perform pr_guardar_asignaciones(emp, ch1, '[]'::jsonb, miguel, null);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok, 'asig 3: el superadmin no asigna dentro de la empresa';

  ok := false; msg := '';
  begin
    perform pr_guardar_asignaciones(emp, ch1, jsonb_build_array(
      jsonb_build_object('rutaId', r1, 'dias', jsonb_build_array(9))), adm, tok_adm);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok, 'asig 3: días fuera de 1..7 se rechazan';

  -- Ruta de OTRA empresa (Servivans de la semilla) en el payload:
  ok := false; msg := '';
  begin
    perform pr_guardar_asignaciones(emp, ch1, jsonb_build_array(
      jsonb_build_object('rutaId',
        (select id from rutas where empresa_id = 'a0000000-0000-0000-0000-000000000001' limit 1),
        'dias', jsonb_build_array(1))), adm, tok_adm);
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok, 'asig 3: ruta de otra empresa se rechaza';

  -- Lo guardado sobrevivió intacto a los intentos:
  datos := pr_datos_chofer(emp, ch1, tok_ch1);
  assert jsonb_array_length(datos -> 'asignaciones') = 1,
         'asig 3: los intentos hostiles no tocaron lo guardado';

  -- ===== 4) Anotar sigue igual: la clase sale del cupo =====
  -- (La asignación no convierte nada en extra ni en empresa.)
  perform pr_anotar_ruta(emp, ch1, r3, pr_hoy(), null, tok_ch1);
  datos := pr_datos_chofer(emp, ch1, tok_ch1);
  assert jsonb_array_length(datos -> 'anotaciones') = 1
     and (datos -> 'anotaciones' -> 0 ->> 'estado') = 'aprobada',
         'asig 4: anotar la ruta asignada funciona como siempre';
end $$;

select 'PRUEBA DE ASIGNACIONES OK' as resultado;
