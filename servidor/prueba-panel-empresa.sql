-- Prueba de panel por empresa — se corre sobre una base con la cadena
-- completa aplicada (… + borrar-empresa.sql + panel-por-empresa.sql)
-- y semilla fresca.
-- IDs de la semilla: empresa Servivans …001, MIGUEL …101 (superadmin),
-- ADMIN …102 (administrador de Servivans).
--
-- Qué se prueba:
--   1. El resumen trae panelUrl: Servivans con SU panel personalizado
--      (el fijado por el propio panel-por-empresa.sql) y una empresa
--      nueva sin panel (null = panel predeterminado de RutaNeto).
--   2. Un NO superadmin no puede fijar paneles.
--   3. El dueño fija una URL: el resumen la muestra y el registro
--      global anota 'panel_fijado' con la URL en el detalle.
--   4. URL sin http(s):// se rechaza; empresa inexistente también.
--   5. Quitar el panel (null y también con texto vacío): la empresa
--      vuelve a null en el resumen y el registro anota 'panel_quitado'.
--   6. Servivans queda intacta y la empresa de juguete se limpia
--      borrándola con pr_admin_borrar_empresa.

create temp table tmp_panel (clave text primary key, valor text) on commit preserve rows;
delete from tmp_panel;

-- ============ 1. panelUrl EN EL RESUMEN ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  res jsonb;
  r jsonb;
  v_emp uuid;
begin
  res := pr_admin_resumen(miguel);
  assert exists (
    select 1 from jsonb_array_elements(res -> 'empresas') x
    where x ->> 'nombre' = 'Servivans'
      and x ->> 'panelUrl' = 'https://pago-rutas-panel.ml14211338.workers.dev'),
    'panel 1: Servivans trae su panel personalizado en el resumen';

  r := pr_admin_crear_empresa(miguel, 'Transportes Panel Test', 15, 12,
                              'TP-ADM', '1234', 'Admin Panel');
  v_emp := (r -> 'empresa' ->> 'id')::uuid;
  insert into tmp_panel values ('empresa', v_emp::text);

  res := pr_admin_resumen(miguel);
  assert exists (
    select 1 from jsonb_array_elements(res -> 'empresas') x
    where (x ->> 'id')::uuid = v_emp and (x -> 'panelUrl') = 'null'::jsonb),
    'panel 1: la empresa nueva no tiene panel personalizado (null)';
end $$;

-- ============ 2. UN NO SUPERADMIN NO PUEDE FIJAR ============
do $$
declare
  v_emp uuid := (select valor::uuid from tmp_panel where clave = 'empresa');
  admin_servivans constant uuid := 'a0000000-0000-0000-0000-000000000102';
  v_msg text;
  v_ok boolean := false;
begin
  begin
    perform pr_admin_fijar_panel(v_emp, admin_servivans, 'https://panel.ejemplo.com');
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Solo el administrador de RutaNeto puede hacer esto',
    'panel 2: rol empresa rechazado (msg: ' || coalesce(v_msg, 'sin error') || ')';
end $$;

-- ============ 3. EL DUEÑO FIJA LA URL ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  v_emp uuid := (select valor::uuid from tmp_panel where clave = 'empresa');
  r jsonb;
  res jsonb;
  reg jsonb;
begin
  r := pr_admin_fijar_panel(v_emp, miguel, 'https://panel.ejemplo.com');
  assert r ->> 'panelUrl' = 'https://panel.ejemplo.com',
    'panel 3: la función devuelve la URL guardada';

  res := pr_admin_resumen(miguel);
  assert exists (
    select 1 from jsonb_array_elements(res -> 'empresas') x
    where (x ->> 'id')::uuid = v_emp
      and x ->> 'panelUrl' = 'https://panel.ejemplo.com'),
    'panel 3: el resumen ya muestra el panel personalizado';

  reg := pr_admin_registro(miguel, null, 50);
  assert exists (
    select 1 from jsonb_array_elements(reg) x
    where x ->> 'accion' = 'panel_fijado'
      and x ->> 'detalle' = 'Fijó el panel personalizado de la empresa «Transportes Panel Test»: https://panel.ejemplo.com'
      and x -> 'actor' ->> 'codigo' = 'MIGUEL'),
    'panel 3: el registro anota panel_fijado con la URL y el actor';
end $$;

-- ============ 4. VALIDACIONES ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  v_emp uuid := (select valor::uuid from tmp_panel where clave = 'empresa');
  v_msg text;
  v_ok boolean;
begin
  v_ok := false; v_msg := null;
  begin
    perform pr_admin_fijar_panel(v_emp, miguel, 'panel.ejemplo.com');
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'La URL del panel debe empezar con http:// o https://',
    'panel 4: URL sin esquema rechazada (msg: ' || coalesce(v_msg, 'sin error') || ')';

  v_ok := false; v_msg := null;
  begin
    perform pr_admin_fijar_panel(gen_random_uuid(), miguel, 'https://panel.ejemplo.com');
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Esa empresa no existe (¿ya fue eliminada?)',
    'panel 4: empresa inexistente rechazada (msg: ' || coalesce(v_msg, 'sin error') || ')';
end $$;

-- ============ 5. QUITAR EL PANEL (null y texto vacío) ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  v_emp uuid := (select valor::uuid from tmp_panel where clave = 'empresa');
  r jsonb;
  res jsonb;
  reg jsonb;
begin
  r := pr_admin_fijar_panel(v_emp, miguel, null);
  assert (r -> 'panelUrl') = 'null'::jsonb,
    'panel 5: quitar con null devuelve panelUrl null';

  res := pr_admin_resumen(miguel);
  assert exists (
    select 1 from jsonb_array_elements(res -> 'empresas') x
    where (x ->> 'id')::uuid = v_emp and (x -> 'panelUrl') = 'null'::jsonb),
    'panel 5: el resumen vuelve a null (panel predeterminado)';

  reg := pr_admin_registro(miguel, null, 50);
  assert exists (
    select 1 from jsonb_array_elements(reg) x
    where x ->> 'accion' = 'panel_quitado'
      and x ->> 'detalle' like 'Quitó el panel personalizado de la empresa «Transportes Panel Test»%'),
    'panel 5: el registro anota panel_quitado';

  -- Fijar otra vez y quitar con texto vacío: mismo resultado.
  perform pr_admin_fijar_panel(v_emp, miguel, 'https://otro.ejemplo.com');
  r := pr_admin_fijar_panel(v_emp, miguel, '   ');
  assert (r -> 'panelUrl') = 'null'::jsonb,
    'panel 5: quitar con texto vacío también deja null';
end $$;

-- ============ 6. CIERRE: SERVIVANS INTACTA Y LIMPIEZA ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  v_emp uuid := (select valor::uuid from tmp_panel where clave = 'empresa');
  res jsonb;
begin
  res := pr_admin_resumen(miguel);
  assert exists (
    select 1 from jsonb_array_elements(res -> 'empresas') x
    where x ->> 'nombre' = 'Servivans'
      and x ->> 'panelUrl' = 'https://pago-rutas-panel.ml14211338.workers.dev'),
    'panel 6: Servivans conserva su panel personalizado';

  perform pr_admin_borrar_empresa(v_emp, miguel);
  assert not exists (select 1 from empresas where id = v_emp),
    'panel 6: la empresa de juguete quedó borrada (limpieza)';
end $$;

select 'PRUEBA DE PANEL POR EMPRESA OK' as resultado;
