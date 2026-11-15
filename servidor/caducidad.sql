-- Pago por Rutas — aviso de caducidad de licencia (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + semilla.sql +
-- app-datos.sql + ajustes-2026-11-15.sql + acceso-roles.sql +
-- auditoria.sql. No reescribe aquellos archivos: todo va con
-- create or replace, así que correrlo de nuevo no rompe nada.
--
-- Pedido de Miguel (2026-11-15): «un aviso de caducidad de licencia
-- con recordatorios automáticos». La base del aviso vive en el
-- servidor: donde los clientes ya miran la licencia, ahora también
-- viajan los días que faltan para que venza.
--
-- Qué trae (solo se AÑADEN campos; ningún campo existente cambia):
--   1. pr_iniciar_sesion (versión vigente de auditoria.sql: contexto
--      por puerta + registro de auditoría, intactos): el objeto
--      `licencia` de la sesión gana:
--        diasRestantes = vence - hoy (entero; negativo si ya pasó;
--                        null si la licencia no tiene fecha)
--        porVencer     = true si 0 <= diasRestantes <= 30
--      Para el superadmin sin empresa, `licencia` sigue siendo null.
--   2. pr_snapshot (versión vigente de ajustes): su salida no traía la
--      licencia; gana un objeto `licencia` mínimo con
--      {vence, estado, diasRestantes, porVencer} (null si la empresa
--      no tiene licencia). El resto de la foto no cambia.
--   3. pr_admin_resumen (versión vigente de ajustes): cada empresa
--      gana `diasRestantes` y `porVencer` junto a su licencia, y los
--      totales ganan:
--        porVencer = empresas con licencia ACTIVA a 0-30 días de vencer
--        vencidas  = empresas con diasRestantes < 0 y licencia NO
--                    suspendida (la suspendida es decisión de Miguel,
--                    no una caducidad por cobrar)

-- ============ 1. INICIO DE SESIÓN (auditoria, con días restantes) ============
-- Copia fiel de la versión de auditoria.sql (que a su vez trae la de
-- acceso-roles: p_contexto y validación de puerta) con el registro de
-- 'inicio_sesion'. El ÚNICO cambio es el objeto `licencia` del final.
create or replace function pr_iniciar_sesion(p_codigo text, p_pin text, p_contexto text default null)
returns jsonb language plpgsql security definer as $$
declare
  candidatos int := 0;
  u usuarios;
  e empresas;
  lic licencias;
  o opciones_empresa;
  v_detalle text;
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

  v_detalle := case p_contexto
    when 'panel' then 'Inició sesión por el panel de la empresa'
    when 'app' then 'Inició sesión por la app'
    when 'admin' then 'Inició sesión por el panel de administrador de RutaNeto'
    else 'Inició sesión'
  end;

  -- Superadmin (Miguel): sin empresa ni licencia; entra como dueño del
  -- sistema y puede usar las tres puertas (panel, admin y app).
  if u.empresa_id is null then
    perform pr_registrar_accion(null, u.id, 'inicio_sesion', v_detalle);
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

  perform pr_registrar_accion(u.empresa_id, u.id, 'inicio_sesion', v_detalle);

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
      'diasRestantes', case when lic.vence is null then null
                            else lic.vence - current_date end,
      'porVencer', case when lic.vence is null then false
                        else (lic.vence - current_date) between 0 and 30 end,
      'ok', true
    )
  );
end;
$$;

-- ============ 2. SNAPSHOT (ajustes, con objeto licencia) ============
-- Copia fiel de la versión de ajustes-2026-11-15.sql (la que trae
-- diasParaAnotar en opciones). El ÚNICO cambio: se lee la última
-- licencia de la empresa y se añade el objeto `licencia` mínimo.
create or replace function pr_snapshot(p_empresa uuid default null)
returns jsonb language plpgsql security definer as $$
declare
  emp uuid := p_empresa;
  e empresas;
  o opciones_empresa;
  lic licencias;
begin
  if emp is null then
    select id into emp from empresas order by creada_en limit 1;
  end if;
  select * into e from empresas where id = emp;
  if e.id is null then raise exception 'Empresa no encontrada'; end if;
  select * into o from opciones_empresa where empresa_id = emp;
  select * into lic from licencias where empresa_id = emp order by creada_en desc limit 1;

  return jsonb_build_object(
    'empresa', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'activa', e.activa),
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
    'licencia', case when lic.id is null then null else jsonb_build_object(
      'vence', lic.vence,
      'estado', lic.estado,
      'diasRestantes', case when lic.vence is null then null
                            else lic.vence - current_date end,
      'porVencer', case when lic.vence is null then false
                        else (lic.vence - current_date) between 0 and 30 end
    ) end,
    'feriados', coalesce((
      select jsonb_agg(jsonb_build_object('fecha', to_char(f.fecha, 'YYYY-MM-DD'), 'nombre', f.nombre)
                       order by f.fecha)
      from feriados f where f.empresa_id = emp
    ), '[]'::jsonb),
    'usuarios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', u.id, 'rol', u.rol, 'nombre', u.nombre, 'codigo', u.codigo, 'activo', u.activo)
        order by u.nombre)
      from usuarios u where u.empresa_id = emp
    ), '[]'::jsonb),
    'clientes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'nombre', c.nombre, 'activo', c.activo)
                       order by c.nombre)
      from clientes c where c.empresa_id = emp
    ), '[]'::jsonb),
    'rutas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'clienteId', r.cliente_id, 'codigo', r.codigo, 'nombre', r.nombre,
        'precio', r.precio, 'activa', r.activa)
        order by r.codigo)
      from rutas r where r.empresa_id = emp
    ), '[]'::jsonb),
    'anotaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'choferId', a.chofer_id, 'rutaId', a.ruta_id, 'clienteId', a.cliente_id,
        'tipo', a.tipo, 'descripcion', a.descripcion, 'nota', a.nota,
        'fecha', to_char(a.fecha, 'YYYY-MM-DD'), 'clase', a.clase, 'estado', a.estado,
        'precioAplicado', a.precio_aplicado, 'validadaPor', a.validada_por,
        'resolucion', a.resolucion, 'creadaEn', a.creada_en)
        order by a.creada_en desc)
      from anotaciones a where a.empresa_id = emp
    ), '[]'::jsonb),
    'vouchers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'choferId', v.chofer_id, 'folio', v.folio,
        'desde', to_char(v.desde, 'YYYY-MM-DD'), 'hasta', to_char(v.hasta, 'YYYY-MM-DD'),
        'numEmpresa', v.num_empresa, 'numExtra', v.num_extra,
        'totalEmpresa', v.total_empresa, 'totalExtra', v.total_extra, 'total', v.total,
        'detalle', coalesce((
          select jsonb_agg(jsonb_build_object(
            'fecha', to_char(d.fecha, 'YYYY-MM-DD'), 'descripcion', d.descripcion,
            'cliente', d.cliente, 'clase', d.clase, 'precio', d.precio)
            order by d.fecha)
          from voucher_detalle d where d.voucher_id = v.id
        ), '[]'::jsonb))
        order by v.folio)
      from vouchers v where v.empresa_id = emp
    ), '[]'::jsonb)
  );
end;
$$;

-- ============ 3. RESUMEN DEL SUPERADMIN (ajustes, con conteos) ============
-- Copia fiel de la versión de ajustes-2026-11-15.sql. Cambios: cada
-- empresa gana diasRestantes/porVencer junto a su licencia, y los
-- totales ganan porVencer y vencidas (ver el encabezado).
create or replace function pr_admin_resumen(p_quien uuid)
returns jsonb language plpgsql security definer as $$
begin
  perform pr_exigir_superadmin(p_quien);
  return jsonb_build_object(
    'empresas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'nombre', e.nombre,
        'activa', e.activa,
        'licencia', case when l.id is null then null else jsonb_build_object(
          'estado', l.estado, 'vence', l.vence, 'maxChoferes', l.max_choferes) end,
        'diasRestantes', case when l.id is null or l.vence is null then null
                              else l.vence - current_date end,
        'porVencer', case when l.id is null or l.vence is null then false
                          else (l.vence - current_date) between 0 and 30 end,
        'numChoferes', (select count(*) from usuarios u
                        where u.empresa_id = e.id and u.rol = 'chofer' and u.activo),
        'numClientes', (select count(*) from clientes c where c.empresa_id = e.id),
        'numRutas', (select count(*) from rutas r where r.empresa_id = e.id)
      ) order by e.creada_en)
      from empresas e
      left join lateral (
        select li.* from licencias li
        where li.empresa_id = e.id order by li.creada_en desc limit 1
      ) l on true
    ), '[]'::jsonb),
    'totales', jsonb_build_object(
      'empresas', (select count(*) from empresas),
      'empresasActivas', (select count(*) from empresas where activa),
      'choferes', (select count(*) from usuarios where rol = 'chofer' and activo),
      'porVencer', (select count(*)
                    from empresas e2
                    join lateral (
                      select li.estado, li.vence from licencias li
                      where li.empresa_id = e2.id
                      order by li.creada_en desc limit 1
                    ) l2 on true
                    where l2.estado = 'activa' and l2.vence is not null
                      and (l2.vence - current_date) between 0 and 30),
      'vencidas', (select count(*)
                   from empresas e2
                   join lateral (
                     select li.estado, li.vence from licencias li
                     where li.empresa_id = e2.id
                     order by li.creada_en desc limit 1
                   ) l2 on true
                   where l2.vence is not null
                     and (l2.vence - current_date) < 0
                     and l2.estado <> 'suspendida')
    )
  );
end;
$$;
