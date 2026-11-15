-- Prueba de acceso por rol y puerta — se corre sobre una base con
-- esquema.sql + conexion.sql + semilla.sql + app-datos.sql +
-- ajustes-2026-11-15.sql + acceso-roles.sql aplicados.
--
-- Matriz esperada de pr_iniciar_sesion(codigo, pin, contexto):
--   CH-01  (chofer)      : 'app' OK, sin contexto OK, 'panel' NO, 'admin' NO
--   ADMIN  (empresa)     : 'panel' OK, 'app' NO, 'admin' NO
--   COORD  (coordinador) : 'panel' OK, 'app' OK, 'admin' NO
--   MIGUEL (superadmin)  : 'panel' OK, 'app' OK, 'admin' OK, sin contexto OK
--   PIN malo             : NO en todos los contextos.

-- Ayudantes de la prueba (se borran al final).
create or replace function prueba_roles_falla(p_codigo text, p_pin text, p_contexto text, p_mensaje text)
returns void language plpgsql as $$
declare msg text := null;
begin
  begin
    perform pr_iniciar_sesion(p_codigo, p_pin, p_contexto);
  exception when others then msg := sqlerrm;
  end;
  assert msg is not null,
    format('roles: %s con contexto %s debió ser rechazado y entró', p_codigo, coalesce(p_contexto, '(sin contexto)'));
  assert msg = p_mensaje,
    format('roles: %s con contexto %s: mensaje esperado «%s», llegó «%s»', p_codigo, coalesce(p_contexto, '(sin contexto)'), p_mensaje, msg);
end;
$$;

-- 0) Queda UNA sola pr_iniciar_sesion (sin sobrecargas ambiguas) y es la
-- de 3 argumentos.
do $$
declare n int;
begin
  select count(*) into n from pg_proc where proname = 'pr_iniciar_sesion';
  assert n = 1, 'roles: debe existir una sola pr_iniciar_sesion';
  select pronargs into n from pg_proc where proname = 'pr_iniciar_sesion';
  assert n = 3, 'roles: pr_iniciar_sesion debe tener 3 argumentos';
end $$;

-- 1) CH-01 (chofer): entra por la app y sin contexto; NO por el panel ni
-- por el área admin, con los mensajes exactos.
do $$
declare s jsonb;
begin
  s := pr_iniciar_sesion('CH-01', '1234', 'app');
  assert s -> 'usuario' ->> 'rol' = 'chofer', 'roles CH-01 app: rol chofer';
  assert (s -> 'opciones' ->> 'diasParaAnotar')::int = 1, 'roles CH-01 app: la sesión conserva diasParaAnotar de ajustes';
  s := pr_iniciar_sesion('CH-01', '1234'); -- 2 argumentos: compatibilidad
  assert s -> 'usuario' ->> 'rol' = 'chofer', 'roles CH-01 sin contexto: entra';
  perform prueba_roles_falla('CH-01', '1234', 'panel',
    'Tu cuenta es de chofer: tu acceso es por la app, no por el panel de la empresa.');
  perform prueba_roles_falla('CH-01', '1234', 'admin',
    'Esta área es solo del administrador de RutaNeto.');
end $$;

-- 2) ADMIN (rol empresa): entra por el panel; NO por la app ni por admin.
do $$
declare s jsonb;
begin
  s := pr_iniciar_sesion('ADMIN', '1234', 'panel');
  assert s -> 'usuario' ->> 'rol' = 'empresa', 'roles ADMIN panel: rol empresa';
  s := pr_iniciar_sesion('ADMIN', '1234'); -- sin contexto: comportamiento anterior
  assert s -> 'usuario' ->> 'rol' = 'empresa', 'roles ADMIN sin contexto: entra';
  perform prueba_roles_falla('ADMIN', '1234', 'app',
    'Tu cuenta es de oficina: tu acceso es por el panel web.');
  perform prueba_roles_falla('ADMIN', '1234', 'admin',
    'Esta área es solo del administrador de RutaNeto.');
end $$;

-- 3) COORD (coordinador): entra por el panel y por la app; NO por admin.
do $$
declare s jsonb;
begin
  s := pr_iniciar_sesion('COORD', '1234', 'panel');
  assert s -> 'usuario' ->> 'rol' = 'coordinador', 'roles COORD panel: rol coordinador';
  s := pr_iniciar_sesion('COORD', '1234', 'app');
  assert s -> 'usuario' ->> 'rol' = 'coordinador', 'roles COORD app: rol coordinador';
  perform prueba_roles_falla('COORD', '1234', 'admin',
    'Esta área es solo del administrador de RutaNeto.');
end $$;

-- 4) MIGUEL (superadmin): entra con los tres contextos y sin contexto.
do $$
declare s jsonb;
begin
  s := pr_iniciar_sesion('MIGUEL', '1234', 'panel');
  assert s -> 'usuario' ->> 'rol' = 'superadmin', 'roles MIGUEL panel: superadmin';
  s := pr_iniciar_sesion('MIGUEL', '1234', 'admin');
  assert s -> 'usuario' ->> 'rol' = 'superadmin', 'roles MIGUEL admin: superadmin';
  s := pr_iniciar_sesion('MIGUEL', '1234', 'app');
  assert s -> 'usuario' ->> 'rol' = 'superadmin', 'roles MIGUEL app: superadmin';
  s := pr_iniciar_sesion('MIGUEL', '1234');
  assert s -> 'usuario' ->> 'rol' = 'superadmin', 'roles MIGUEL sin contexto: superadmin';
end $$;

-- 5) PIN malo: rechazado en TODOS los contextos, con el mensaje de
-- credenciales (la validación de rol va después de las credenciales).
do $$
begin
  perform prueba_roles_falla('CH-01', '9999', 'app', 'Código o PIN incorrecto');
  perform prueba_roles_falla('CH-01', '9999', 'panel', 'Código o PIN incorrecto');
  perform prueba_roles_falla('ADMIN', '9999', 'panel', 'Código o PIN incorrecto');
  perform prueba_roles_falla('ADMIN', '9999', 'admin', 'Código o PIN incorrecto');
  perform prueba_roles_falla('COORD', '9999', 'app', 'Código o PIN incorrecto');
  perform prueba_roles_falla('MIGUEL', '9999', 'admin', 'Código o PIN incorrecto');
  perform prueba_roles_falla('NO-EXISTE', '1234', 'panel', 'Código o PIN incorrecto');
end $$;

-- 6) Contexto desconocido: comportamiento anterior (sin validación).
do $$
declare s jsonb;
begin
  s := pr_iniciar_sesion('CH-01', '1234', 'otra-cosa');
  assert s -> 'usuario' ->> 'rol' = 'chofer', 'roles contexto desconocido: entra como antes';
end $$;

drop function prueba_roles_falla(text, text, text, text);

select 'PRUEBA DE ROLES OK' as resultado;
