-- Pago por Rutas — acceso por rol y puerta (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + semilla.sql +
-- app-datos.sql + ajustes-2026-11-15.sql.
--
-- Corrección de seguridad (2026-11-15): Miguel entró al panel con una
-- cuenta de CHOFER. El panel ocultaba la puerta en pantalla, pero el
-- SERVIDOR aceptaba la sesión. Desde ahora pr_iniciar_sesion valida el
-- CONTEXTO de entrada en el servidor, después de verificar credenciales
-- y licencia:
--   'panel' -> solo empresa, coordinador y superadmin.
--   'admin' -> solo superadmin (el área de Miguel, dueño de RutaNeto).
--   'app'   -> solo chofer y coordinador (y el superadmin, que prueba
--              todo); una cuenta de oficina (rol empresa) no entra.
--   null u otro valor -> comportamiento anterior, sin validación de
--   contexto (compatibilidad con los clientes ya desplegados, que llaman
--   con 2 argumentos).
--
-- Para que PostgREST no quede con sobrecargas ambiguas, se elimina la
-- versión de 2 argumentos y queda UNA sola pr_iniciar_sesion: la de 3
-- argumentos con p_contexto default null. Las llamadas con 2 argumentos
-- siguen funcionando por el default.

drop function if exists pr_iniciar_sesion(text, text);

create or replace function pr_iniciar_sesion(p_codigo text, p_pin text, p_contexto text default null)
returns jsonb language plpgsql security definer as $$
declare
  candidatos int := 0;
  u usuarios;
  e empresas;
  lic licencias;
  o opciones_empresa;
begin
  -- Candidatos: usuarios activos con ese código cuyo PIN coincide.
  select count(*) into candidatos
  from usuarios x
  where x.activo and upper(x.codigo) = upper(trim(p_codigo))
    and pr_verificar_pin(p_pin, x.pin_hash);

  if candidatos = 0 then
    raise exception 'Código o PIN incorrecto';
  end if;
  if candidatos > 1 then
    raise exception 'Ese código existe en más de una empresa. Pide ayuda a RutaNeto para entrar.';
  end if;

  select * into u from usuarios x
  where x.activo and upper(x.codigo) = upper(trim(p_codigo))
    and pr_verificar_pin(p_pin, x.pin_hash);

  -- Superadmin (Miguel): sin empresa ni licencia; entra como dueño del
  -- sistema y puede usar las tres puertas (panel, admin y app).
  if u.empresa_id is null then
    return jsonb_build_object(
      'usuario', jsonb_build_object('id', u.id, 'nombre', u.nombre, 'codigo', u.codigo, 'rol', u.rol),
      'empresa', null,
      'opciones', null,
      'licencia', null
    );
  end if;

  select * into e from empresas where id = u.empresa_id;
  if e.id is null or not e.activa then
    raise exception 'Tu empresa está inactiva. Contacta a RutaNeto.';
  end if;

  select * into lic from licencias where empresa_id = e.id order by creada_en desc limit 1;
  if lic.id is null then
    raise exception 'Tu empresa todavía no tiene licencia. Contacta a RutaNeto.';
  end if;
  if lic.estado = 'suspendida' then
    raise exception 'La licencia de tu empresa está suspendida. Contacta a RutaNeto.';
  end if;
  if lic.estado = 'vencida' or (lic.vence is not null and lic.vence < current_date) then
    raise exception 'La licencia de tu empresa está vencida. Contacta a RutaNeto para renovarla.';
  end if;

  -- ===== Acceso por rol y puerta (ya con credenciales y licencia ok) =====
  if p_contexto = 'panel' and u.rol not in ('empresa', 'coordinador', 'superadmin') then
    raise exception 'Tu cuenta es de chofer: tu acceso es por la app, no por el panel de la empresa.';
  end if;
  if p_contexto = 'admin' and u.rol <> 'superadmin' then
    raise exception 'Esta área es solo del administrador de RutaNeto.';
  end if;
  if p_contexto = 'app' and u.rol not in ('chofer', 'coordinador', 'superadmin') then
    raise exception 'Tu cuenta es de oficina: tu acceso es por el panel web.';
  end if;

  select * into o from opciones_empresa where empresa_id = e.id;

  return jsonb_build_object(
    'usuario', jsonb_build_object('id', u.id, 'nombre', u.nombre, 'codigo', u.codigo, 'rol', u.rol),
    'empresa', jsonb_build_object('id', e.id, 'nombre', e.nombre),
    'opciones', case when o.empresa_id is null then null else jsonb_build_object(
      'empresaId', o.empresa_id,
      'verGanado', o.ver_ganado,
      'voucherApp', o.voucher_app,
      'botonEspecial', o.boton_especial,
      'rutasEmpresaPorDia', o.rutas_empresa_por_dia,
      'sabadoExtra', o.sabado_extra,
      'domingoExtra', o.domingo_extra,
      'feriadoExtra', o.feriado_extra,
      'limiteAnotacion', o.limite_anotacion,
      'diasParaAnotar', o.dias_para_anotar
    ) end,
    'licencia', jsonb_build_object(
      'estado', lic.estado,
      'vence', lic.vence,
      'maxChoferes', lic.max_choferes,
      'ok', true
    )
  );
end;
$$;
