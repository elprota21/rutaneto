-- Prueba de borrar empresa del dueño — se corre sobre una base con la
-- cadena completa aplicada (esquema + conexion + semilla + app-datos +
-- ajustes + acceso-roles + auditoria + caducidad + permisos-dueno +
-- permisos-crud + app-novedades + borrar-empresa) y semilla fresca.
-- IDs de la semilla: empresa Servivans …001, MIGUEL …101 (superadmin),
-- ADMIN …102 (administrador de Servivans).
--
-- Historia de la prueba:
--   1. El dueño crea una empresa de juguete con la función real
--      (pr_admin_crear_empresa) y le da actividad: chofer, cliente,
--      ruta, anotación, reporte y voucher.
--   2. Un NO superadmin intenta borrarla -> rechazado.
--   3. El dueño la borra -> resumen de lo borrado.
--   4. Verificaciones: la empresa y todo lo suyo desaparecen (tablas y
--      pr_admin_resumen), sus usuarios ya no entran y reciben
--      «Esta empresa fue eliminada de RutaNeto» en panel y en app, el
--      error genérico sigue para códigos que nunca existieron, el
--      registro global anota la eliminación, y Servivans queda intacta.
--   5. Borrar dos veces / un id que no existe -> error claro.
--   6. Los códigos liberados se pueden registrar otra vez en una
--      empresa nueva, que entra con normalidad (la lápida no estorba).

create temp table tmp_borrado (clave text primary key, valor text) on commit preserve rows;
delete from tmp_borrado;

-- ============ 1. EMPRESA DE JUGUETE CON ACTIVIDAD ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  r jsonb;
  v_emp uuid;
  u usuarios;
  c clientes;
  ru rutas;
  s jsonb;
begin
  r := pr_admin_crear_empresa(miguel, 'Transportes Borrado Test', 15, 12,
                              'TB-ADM', '1234', 'Admin Borrado');
  v_emp := (r -> 'empresa' ->> 'id')::uuid;
  assert v_emp is not null, 'borrar 1: la empresa de juguete se creó';
  insert into tmp_borrado values ('empresa', v_emp::text);

  u := pr_crear_usuario(v_emp, 'Chofer Borrado', 'TB-01', 'chofer', '1234');
  insert into tmp_borrado values ('chofer', u.id::text);

  c := pr_crear_cliente(v_emp, 'Cliente Borrado');
  ru := pr_crear_ruta(v_emp, 'TB-R1', 'Ruta de prueba', 500, c.id);
  insert into tmp_borrado values ('ruta', ru.id::text);

  perform pr_anotar_ruta(v_emp, u.id, ru.id);
  perform pr_enviar_reporte(v_emp, u.id, 'averia', 'Reporte de prueba para el borrado');
  perform pr_generar_voucher(v_emp, u.id, current_date, current_date);

  -- Antes de borrar, sus usuarios entran con normalidad por sus puertas.
  s := pr_iniciar_sesion('TB-ADM', '1234', 'panel');
  assert s -> 'empresa' ->> 'nombre' = 'Transportes Borrado Test',
    'borrar 1: el admin de juguete entra al panel antes del borrado';
  s := pr_iniciar_sesion('TB-01', '1234', 'app');
  assert s -> 'usuario' ->> 'codigo' = 'TB-01',
    'borrar 1: el chofer de juguete entra a la app antes del borrado';
end $$;

-- ============ 2. UN NO SUPERADMIN NO PUEDE BORRAR ============
do $$
declare
  v_emp uuid := (select valor::uuid from tmp_borrado where clave = 'empresa');
  v_chofer uuid := (select valor::uuid from tmp_borrado where clave = 'chofer');
  admin_servivans constant uuid := 'a0000000-0000-0000-0000-000000000102';
  v_msg text;
  v_ok boolean;
begin
  -- El administrador de OTRA empresa (rol empresa):
  v_ok := false; v_msg := null;
  begin
    perform pr_admin_borrar_empresa(v_emp, admin_servivans);
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Solo el administrador de RutaNeto puede hacer esto',
    'borrar 2: rol empresa rechazado (msg: ' || coalesce(v_msg, 'sin error') || ')';

  -- Un chofer de la PROPIA empresa de juguete:
  v_ok := false; v_msg := null;
  begin
    perform pr_admin_borrar_empresa(v_emp, v_chofer);
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Solo el administrador de RutaNeto puede hacer esto',
    'borrar 2: rol chofer rechazado (msg: ' || coalesce(v_msg, 'sin error') || ')';

  -- Y la empresa sigue viva tras los intentos.
  assert exists (select 1 from empresas where id = v_emp),
    'borrar 2: la empresa sigue existiendo tras los intentos ajenos';
end $$;

-- ============ 3. EL DUEÑO LA BORRA ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  v_emp uuid := (select valor::uuid from tmp_borrado where clave = 'empresa');
  r jsonb;
begin
  r := pr_admin_borrar_empresa(v_emp, miguel);
  assert r ->> 'empresa' = 'Transportes Borrado Test',
    'borrar 3: el resumen trae el nombre de la empresa';
  assert (r ->> 'usuarios')::int = 2,
    'borrar 3: el resumen cuenta sus 2 usuarios (admin + chofer)';
  assert (r ->> 'licenciaCancelada')::boolean is true,
    'borrar 3: el resumen confirma la licencia cancelada';
end $$;

-- ============ 4. VERIFICACIONES TRAS EL BORRADO ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  v_emp uuid := (select valor::uuid from tmp_borrado where clave = 'empresa');
  res jsonb;
  reg jsonb;
  s jsonb;
  v_msg text;
  v_ok boolean;
begin
  -- Nada queda en las tablas.
  assert not exists (select 1 from empresas where id = v_emp), 'borrar 4: empresa fuera';
  assert not exists (select 1 from licencias where empresa_id = v_emp), 'borrar 4: licencia fuera (cancelada)';
  assert not exists (select 1 from usuarios where empresa_id = v_emp), 'borrar 4: usuarios fuera';
  assert not exists (select 1 from opciones_empresa where empresa_id = v_emp), 'borrar 4: opciones fuera';
  assert not exists (select 1 from clientes where empresa_id = v_emp), 'borrar 4: clientes fuera';
  assert not exists (select 1 from rutas where empresa_id = v_emp), 'borrar 4: rutas fuera';
  assert not exists (select 1 from anotaciones where empresa_id = v_emp), 'borrar 4: anotaciones fuera';
  assert not exists (select 1 from vouchers where empresa_id = v_emp), 'borrar 4: vouchers fuera';
  assert not exists (select 1 from reportes where empresa_id = v_emp), 'borrar 4: reportes fuera';

  -- Fuera del resumen del dueño; solo queda Servivans (semilla).
  res := pr_admin_resumen(miguel);
  assert not exists (
    select 1 from jsonb_array_elements(res -> 'empresas') x
    where x ->> 'nombre' = 'Transportes Borrado Test'),
    'borrar 4: el resumen del dueño ya no la lista';
  assert (res -> 'totales' ->> 'empresas')::int = 1,
    'borrar 4: el total de empresas del resumen es 1 (solo Servivans)';

  -- La lápida guarda nombre y códigos.
  assert exists (
    select 1 from empresas_eliminadas
    where nombre = 'Transportes Borrado Test'
      and 'TB-ADM' = any (codigos) and 'TB-01' = any (codigos)),
    'borrar 4: la lápida guarda el nombre y los códigos';

  -- Login del ex admin (panel) y del ex chofer (app): mensaje claro.
  v_ok := false; v_msg := null;
  begin
    perform pr_iniciar_sesion('TB-ADM', '1234', 'panel');
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Esta empresa fue eliminada de RutaNeto',
    'borrar 4: ex admin rechazado con mensaje claro (msg: ' || coalesce(v_msg, 'sin error') || ')';

  v_ok := false; v_msg := null;
  begin
    perform pr_iniciar_sesion('TB-01', '1234', 'app');
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Esta empresa fue eliminada de RutaNeto',
    'borrar 4: ex chofer rechazado con mensaje claro (msg: ' || coalesce(v_msg, 'sin error') || ')';

  -- Un código que NUNCA existió sigue con el error genérico.
  v_ok := false; v_msg := null;
  begin
    perform pr_iniciar_sesion('NO-EXISTE', '1234', 'panel');
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Código o PIN incorrecto',
    'borrar 4: código inexistente conserva el error genérico';

  -- El registro GLOBAL anota la eliminación con actor y detalle.
  reg := pr_admin_registro(miguel, null, 50);
  assert exists (
    select 1 from jsonb_array_elements(reg) x
    where x ->> 'accion' = 'empresa_eliminada'
      and x ->> 'detalle' = 'Empresa eliminada: Transportes Borrado Test — licencia cancelada'
      and x -> 'actor' ->> 'codigo' = 'MIGUEL'),
    'borrar 4: el registro global trae la eliminación con su actor';

  -- Servivans intacta: su admin entra y su foto sale completa.
  s := pr_iniciar_sesion('ADMIN', '1234', 'panel');
  assert s -> 'empresa' ->> 'nombre' = 'Servivans',
    'borrar 4: Servivans sigue entrando';
  s := pr_snapshot('a0000000-0000-0000-0000-000000000001');
  assert jsonb_array_length(s -> 'usuarios') = 5,
    'borrar 4: Servivans conserva sus 5 usuarios de empresa';
end $$;

-- ============ 5. BORRAR LO QUE YA NO EXISTE ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  v_emp uuid := (select valor::uuid from tmp_borrado where clave = 'empresa');
  v_msg text;
  v_ok boolean;
begin
  v_ok := false; v_msg := null;
  begin
    perform pr_admin_borrar_empresa(v_emp, miguel);
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Esa empresa no existe (¿ya fue eliminada?)',
    'borrar 5: borrar dos veces da el error claro';

  v_ok := false; v_msg := null;
  begin
    perform pr_admin_borrar_empresa(gen_random_uuid(), miguel);
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Esa empresa no existe (¿ya fue eliminada?)',
    'borrar 5: un id cualquiera da el mismo error claro';
end $$;

-- ============ 6. LOS CÓDIGOS LIBERADOS SE REUSAN ============
do $$
declare
  miguel constant uuid := 'a0000000-0000-0000-0000-000000000101';
  r jsonb;
  s jsonb;
  v_emp uuid;
  v_msg text;
  v_ok boolean;
begin
  -- El mismo código de admin que tenía la empresa borrada:
  r := pr_admin_crear_empresa(miguel, 'Transportes Reuso', 5, 6,
                              'TB-ADM', '1234', 'Admin Reuso');
  v_emp := (r -> 'empresa' ->> 'id')::uuid;

  -- Entra con normalidad: la lápida no manda sobre un usuario vivo.
  s := pr_iniciar_sesion('TB-ADM', '1234', 'panel');
  assert s -> 'empresa' ->> 'nombre' = 'Transportes Reuso',
    'borrar 6: el código reusado entra a su empresa nueva';

  -- Limpieza: se borra también la de reuso, y el código vuelve a dar
  -- el mensaje de empresa eliminada (ya no hay usuario vivo con él).
  perform pr_admin_borrar_empresa(v_emp, miguel);
  v_ok := false; v_msg := null;
  begin
    perform pr_iniciar_sesion('TB-ADM', '1234', 'panel');
    v_ok := true;
  exception when others then v_msg := sqlerrm;
  end;
  assert not v_ok and v_msg = 'Esta empresa fue eliminada de RutaNeto',
    'borrar 6: tras borrar la de reuso, el mensaje claro vuelve';
end $$;

select 'PRUEBA DE BORRAR EMPRESA OK' as resultado;
