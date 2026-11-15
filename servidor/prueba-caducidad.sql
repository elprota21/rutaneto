-- Prueba del aviso de caducidad de licencia — se corre sobre una base
-- con esquema.sql + conexion.sql + semilla.sql + app-datos.sql +
-- ajustes-2026-11-15.sql + acceso-roles.sql + auditoria.sql +
-- caducidad.sql aplicados (semilla fresca).
-- IDs de la semilla: empresa Servivans …001, su licencia …501,
-- MIGUEL …101 (superadmin), ADMIN …102.
-- La prueba mueve la fecha de vencimiento de la licencia de Servivans
-- con updates directos y observa los tres sitios donde viaja el aviso:
-- pr_iniciar_sesion, pr_snapshot y pr_admin_resumen.

-- 0) Estado de la semilla (vence en 1 año): hay aviso calculado y NO
--    está por vencer; el superadmin sigue sin licencia (null).
do $$
declare s jsonb; snap jsonb;
begin
  s := pr_iniciar_sesion('ADMIN', '1234', 'panel');
  assert s -> 'licencia' ? 'diasRestantes',
    'caducidad 0: la sesión trae diasRestantes';
  assert (s -> 'licencia' ->> 'diasRestantes')::int > 30,
    'caducidad 0: con la semilla faltan más de 30 días';
  assert (s -> 'licencia' -> 'porVencer') = 'false'::jsonb,
    'caducidad 0: con la semilla porVencer es false';

  s := pr_iniciar_sesion('MIGUEL', '1234', 'admin');
  assert (s -> 'licencia') = 'null'::jsonb,
    'caducidad 0: el superadmin sigue con licencia null';

  snap := pr_snapshot('a0000000-0000-0000-0000-000000000001');
  assert snap -> 'licencia' ->> 'estado' = 'activa',
    'caducidad 0: el snapshot trae la licencia activa';
  assert (snap -> 'licencia' ->> 'diasRestantes')::int > 30,
    'caducidad 0: el snapshot calcula los días restantes';
  assert (snap -> 'licencia' -> 'porVencer') = 'false'::jsonb,
    'caducidad 0: el snapshot marca porVencer false';
end $$;

-- 1) Vence en 10 días: por vencer en los tres sitios, y el resumen del
--    superadmin la cuenta en totales.porVencer.
do $$
declare s jsonb; snap jsonb; res jsonb; emp jsonb;
begin
  update licencias set vence = current_date + 10
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';

  s := pr_iniciar_sesion('ADMIN', '1234', 'panel');
  assert (s -> 'licencia' ->> 'diasRestantes')::int = 10,
    'caducidad 1: la sesión trae diasRestantes = 10';
  assert (s -> 'licencia' -> 'porVencer') = 'true'::jsonb,
    'caducidad 1: la sesión trae porVencer = true';

  snap := pr_snapshot('a0000000-0000-0000-0000-000000000001');
  assert (snap -> 'licencia' ->> 'diasRestantes')::int = 10,
    'caducidad 1: el snapshot trae diasRestantes = 10';
  assert (snap -> 'licencia' -> 'porVencer') = 'true'::jsonb,
    'caducidad 1: el snapshot trae porVencer = true';

  res := pr_admin_resumen('a0000000-0000-0000-0000-000000000101');
  emp := res -> 'empresas' -> 0;
  assert (emp ->> 'diasRestantes')::int = 10,
    'caducidad 1: el resumen trae diasRestantes = 10 junto a la licencia';
  assert (emp -> 'porVencer') = 'true'::jsonb,
    'caducidad 1: el resumen trae porVencer = true';
  assert (res -> 'totales' ->> 'porVencer')::int = 1,
    'caducidad 1: totales.porVencer cuenta a Servivans';
  assert (res -> 'totales' ->> 'vencidas')::int = 0,
    'caducidad 1: totales.vencidas sigue en 0';
end $$;

-- 2) Vence en 90 días: lejos, sin aviso en ningún sitio.
do $$
declare s jsonb; res jsonb;
begin
  update licencias set vence = current_date + 90
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';

  s := pr_iniciar_sesion('ADMIN', '1234', 'panel');
  assert (s -> 'licencia' ->> 'diasRestantes')::int = 90,
    'caducidad 2: la sesión trae diasRestantes = 90';
  assert (s -> 'licencia' -> 'porVencer') = 'false'::jsonb,
    'caducidad 2: a 90 días porVencer es false';

  res := pr_admin_resumen('a0000000-0000-0000-0000-000000000101');
  assert (res -> 'empresas' -> 0 -> 'porVencer') = 'false'::jsonb,
    'caducidad 2: el resumen marca porVencer false';
  assert (res -> 'totales' ->> 'porVencer')::int = 0,
    'caducidad 2: totales.porVencer vuelve a 0';
end $$;

-- 3) Bordes de la ventana de aviso: hoy (0) y 30 días SÍ avisan;
--    31 días ya no. Vencer hoy todavía deja entrar (vence >= hoy).
do $$
declare s jsonb; snap jsonb;
begin
  update licencias set vence = current_date
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';
  s := pr_iniciar_sesion('ADMIN', '1234', 'panel');
  assert (s -> 'licencia' ->> 'diasRestantes')::int = 0,
    'caducidad 3: vencer hoy da diasRestantes = 0';
  assert (s -> 'licencia' -> 'porVencer') = 'true'::jsonb,
    'caducidad 3: vencer hoy SÍ es porVencer';

  update licencias set vence = current_date + 30
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';
  snap := pr_snapshot('a0000000-0000-0000-0000-000000000001');
  assert (snap -> 'licencia' -> 'porVencer') = 'true'::jsonb,
    'caducidad 3: a 30 días SÍ es porVencer';

  update licencias set vence = current_date + 31
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';
  snap := pr_snapshot('a0000000-0000-0000-0000-000000000001');
  assert (snap -> 'licencia' ->> 'diasRestantes')::int = 31,
    'caducidad 3: a 31 días diasRestantes = 31';
  assert (snap -> 'licencia' -> 'porVencer') = 'false'::jsonb,
    'caducidad 3: a 31 días ya NO es porVencer';
end $$;

-- 4) Venció ayer: diasRestantes = -1 donde se puede mirar (snapshot y
--    resumen) y el login sigue rechazado, como hasta hoy.
do $$
declare snap jsonb; res jsonb; ok boolean; msg text;
begin
  update licencias set vence = current_date - 1
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';

  ok := false; msg := null;
  begin perform pr_iniciar_sesion('ADMIN', '1234', 'panel');
  exception when others then ok := true; msg := sqlerrm; end;
  assert ok, 'caducidad 4: con la licencia vencida el login se rechaza';
  assert msg = 'La licencia de tu empresa está vencida. Contacta a RutaNeto para renovarla.',
    'caducidad 4: el rechazo es el mensaje de vencida de siempre';

  snap := pr_snapshot('a0000000-0000-0000-0000-000000000001');
  assert (snap -> 'licencia' ->> 'diasRestantes')::int = -1,
    'caducidad 4: el snapshot trae diasRestantes = -1';
  assert (snap -> 'licencia' -> 'porVencer') = 'false'::jsonb,
    'caducidad 4: vencida ya no es porVencer';

  res := pr_admin_resumen('a0000000-0000-0000-0000-000000000101');
  assert (res -> 'empresas' -> 0 ->> 'diasRestantes')::int = -1,
    'caducidad 4: el resumen trae diasRestantes = -1';
  assert (res -> 'totales' ->> 'vencidas')::int = 1,
    'caducidad 4: totales.vencidas cuenta a Servivans';
  assert (res -> 'totales' ->> 'porVencer')::int = 0,
    'caducidad 4: totales.porVencer no la cuenta';
end $$;

-- 5) Suspendida NO cuenta como vencida ni como por vencer (es una
--    decisión de Miguel, no una caducidad), aunque la fecha ya pasó
--    o esté dentro de la ventana.
do $$
declare res jsonb; ok boolean;
begin
  update licencias set estado = 'suspendida', vence = current_date - 5
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';
  res := pr_admin_resumen('a0000000-0000-0000-0000-000000000101');
  assert (res -> 'totales' ->> 'vencidas')::int = 0,
    'caducidad 5: suspendida y pasada de fecha NO cuenta como vencida';

  update licencias set vence = current_date + 10
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';
  res := pr_admin_resumen('a0000000-0000-0000-0000-000000000101');
  assert (res -> 'totales' ->> 'porVencer')::int = 0,
    'caducidad 5: suspendida a 10 días NO cuenta como porVencer';

  ok := false;
  begin perform pr_iniciar_sesion('ADMIN', '1234', 'panel');
  exception when others then ok := true; end;
  assert ok, 'caducidad 5: suspendida sigue sin dejar entrar';

  -- Se deja la licencia como la trajo la semilla.
  update licencias set estado = 'activa', vence = current_date + interval '1 year'
  where empresa_id = 'a0000000-0000-0000-0000-000000000001';
end $$;

-- 6) Lo de las rondas anteriores sigue vivo tras la recreación: el
--    login concedido se registra en auditoría y la puerta equivocada
--    se sigue rechazando.
do $$
declare n0 int; n1 int; ok boolean;
begin
  select count(*) into n0 from registro_acciones where accion = 'inicio_sesion';
  perform pr_iniciar_sesion('ADMIN', '1234', 'panel');
  select count(*) into n1 from registro_acciones where accion = 'inicio_sesion';
  assert n1 = n0 + 1, 'caducidad 6: el inicio de sesión se sigue registrando';

  ok := false;
  begin perform pr_iniciar_sesion('CH-01', '1234', 'panel');
  exception when others then ok := true; end;
  assert ok, 'caducidad 6: el chofer sigue sin entrar por el panel';
end $$;

select 'PRUEBA DE CADUCIDAD OK' as resultado;
