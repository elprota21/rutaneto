-- Prueba de la HORA de las rutas (hora-rutas.sql): crear con hora,
-- verla en el snapshot del panel y en los datos del chofer, editarla
-- y quitarla. Termina en PASS o revienta con el motivo.
do $$
declare
  emp uuid;
  cli uuid;
  adm uuid;
  chof uuid;
  r1 rutas;
  r2 rutas;
  snap jsonb;
  datos jsonb;
  v_hora text;
begin
  select id into emp from empresas where nombre like 'Servivans%' limit 1;
  select id into cli from clientes where empresa_id = emp limit 1;
  select id into adm from usuarios where empresa_id = emp and rol = 'empresa' limit 1;
  select id into chof from usuarios where empresa_id = emp and rol = 'chofer' and activo limit 1;

  -- 1) Crear ruta CON hora.
  r1 := pr_crear_ruta(emp, 'H-01', 'Ruta con hora', 500, cli, adm, '05:30');
  if r1.hora is distinct from '05:30:00'::time then
    raise exception 'FALLO: la ruta creada no guardó la hora (trae %)', r1.hora;
  end if;

  -- 2) Crear ruta SIN hora: queda en null, sin romperse.
  r2 := pr_crear_ruta(emp, 'H-02', 'Ruta sin hora', 300, cli, adm);
  if r2.hora is not null then
    raise exception 'FALLO: la ruta sin hora trae hora %', r2.hora;
  end if;

  -- 3) El snapshot del panel trae la hora de cada ruta.
  snap := pr_snapshot(emp, adm);
  select x ->> 'hora' into v_hora
  from jsonb_array_elements(snap -> 'rutas') x where x ->> 'id' = r1.id::text;
  if v_hora is distinct from '05:30' then
    raise exception 'FALLO: el snapshot no trae la hora de la ruta (trae %)', v_hora;
  end if;
  select x ->> 'hora' into v_hora
  from jsonb_array_elements(snap -> 'rutas') x where x ->> 'id' = r2.id::text;
  if v_hora is not null then
    raise exception 'FALLO: el snapshot inventa una hora para la ruta sin hora (%)', v_hora;
  end if;

  -- 4) Los datos del chofer (la app) traen la hora.
  datos := pr_datos_chofer(emp, chof);
  select x ->> 'hora' into v_hora
  from jsonb_array_elements(datos -> 'rutas') x where x ->> 'id' = r1.id::text;
  if v_hora is distinct from '05:30' then
    raise exception 'FALLO: la app no recibe la hora de la ruta (trae %)', v_hora;
  end if;

  -- 5) Editar la hora: 05:30 -> 06:45.
  perform pr_actualizar_ruta(r1.id, 'Ruta con hora', 500, cli, adm, '06:45');
  snap := pr_snapshot(emp, adm);
  select x ->> 'hora' into v_hora
  from jsonb_array_elements(snap -> 'rutas') x where x ->> 'id' = r1.id::text;
  if v_hora is distinct from '06:45' then
    raise exception 'FALLO: la hora editada no se refleja (trae %)', v_hora;
  end if;

  -- 6) Quitar la hora (null) desde la edición.
  perform pr_actualizar_ruta(r1.id, 'Ruta con hora', 500, cli, adm, null);
  snap := pr_snapshot(emp, adm);
  select x ->> 'hora' into v_hora
  from jsonb_array_elements(snap -> 'rutas') x where x ->> 'id' = r1.id::text;
  if v_hora is not null then
    raise exception 'FALLO: no se pudo quitar la hora (trae %)', v_hora;
  end if;

  raise notice 'PASS';
end $$;

select 'PRUEBA DE HORA DE RUTAS OK' as resultado;
