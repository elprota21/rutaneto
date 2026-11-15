-- Pago por Rutas — panel por empresa (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de la cadena completa hasta borrar-empresa.sql
-- (esquema + conexion + semilla + app-datos + ajustes + acceso-roles +
-- auditoria + caducidad + permisos-dueno + permisos-crud +
-- app-novedades + borrar-empresa). No reescribe aquellos archivos:
-- todo va con create or replace / if not exists, así que correrlo de
-- nuevo no rompe nada.
--
-- Pedido de Miguel (2026-11-15): el panel de Servivans es
-- PERSONALIZADO para esa empresa (un ejemplo). Las demás empresas
-- podrán pedir su panel personalizado; si no, les sale el panel
-- PREDETERMINADO (el RutaNeto genérico). Pero al crear una empresa
-- nueva y darle a «ver empresa», salía el panel de Servivans sin ser
-- esa empresa: el botón «Entrar» del panel del dueño apuntaba fijo
-- al panel de Servivans para todas.
--
-- Qué trae:
--   1. Columna `empresas.panel_url` (text, nullable): la URL del
--      panel personalizado de esa empresa, si tiene. Null = usa el
--      panel predeterminado de RutaNeto.
--   2. pr_admin_resumen (copia fiel de la versión vigente de
--      caducidad.sql): cada empresa gana `panelUrl` con su URL
--      personalizada (o null). Ningún otro campo cambia.
--   3. pr_admin_fijar_panel(p_empresa, p_quien, p_panel_url): SOLO
--      superadmin. Guarda la URL personalizada de la empresa, o la
--      quita si p_panel_url viene null o vacío (la empresa vuelve al
--      panel predeterminado). Valida que la URL empiece con http://
--      o https://. Queda en el registro de auditoría ('panel_fijado'
--      / 'panel_quitado', con la URL en el detalle).
--   4. Dato semilla de esta ronda: Servivans (…001) queda con su
--      panel personalizado real, el que ya usa:
--      https://pago-rutas-panel.ml14211338.workers.dev
--      La actualización solo corre si aún no tiene panel fijado,
--      para no pisar un cambio posterior hecho desde el panel.

-- ============ 1. COLUMNA panel_url ============
alter table empresas add column if not exists panel_url text;

-- ============ 2. RESUMEN DEL SUPERADMIN (caducidad, con panelUrl) ============
-- Copia fiel de la versión de caducidad.sql. El ÚNICO cambio: cada
-- empresa gana 'panelUrl' (su empresas.panel_url, null si no tiene).
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
        'panelUrl', e.panel_url,
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

-- ============ 3. FIJAR / QUITAR EL PANEL PERSONALIZADO ============
-- p_panel_url null o vacío = quitar (la empresa vuelve al panel
-- predeterminado de RutaNeto). Devuelve {panelUrl} ya guardado.
create or replace function pr_admin_fijar_panel(p_empresa uuid, p_quien uuid,
                                                p_panel_url text default null)
returns jsonb language plpgsql security definer as $$
declare
  emp empresas;
  v_url text := nullif(trim(coalesce(p_panel_url, '')), '');
begin
  perform pr_exigir_superadmin(p_quien);

  select * into emp from empresas where id = p_empresa;
  if emp.id is null then
    raise exception 'Esa empresa no existe (¿ya fue eliminada?)';
  end if;

  if v_url is not null and v_url !~ '^https?://' then
    raise exception 'La URL del panel debe empezar con http:// o https://';
  end if;

  update empresas set panel_url = v_url where id = p_empresa;

  if v_url is null then
    perform pr_registrar_accion(p_empresa, p_quien, 'panel_quitado',
      format('Quitó el panel personalizado de la empresa «%s»: vuelve al panel predeterminado de RutaNeto',
             emp.nombre));
  else
    perform pr_registrar_accion(p_empresa, p_quien, 'panel_fijado',
      format('Fijó el panel personalizado de la empresa «%s»: %s', emp.nombre, v_url));
  end if;

  return jsonb_build_object('panelUrl', v_url);
end;
$$;

-- ============ 4. SERVIVANS: SU PANEL PERSONALIZADO ============
-- Solo si aún no tiene uno fijado (no pisa cambios del panel).
update empresas
set panel_url = 'https://pago-rutas-panel.ml14211338.workers.dev'
where id = 'a0000000-0000-0000-0000-000000000001'
  and panel_url is null;
