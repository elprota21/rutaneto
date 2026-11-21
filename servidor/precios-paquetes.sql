-- Pago por Rutas — precios y paquetes registrados (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de la cadena completa hasta panel-por-empresa.sql.
-- Todo va con create or replace / if not exists: correrlo de nuevo
-- no rompe nada (la semilla del catálogo se refresca por clave).
--
-- Pedido de Miguel (2026-11-21): los precios están aprobados («los
-- números están bien») y quiere «que todas esas cuentas estén en mi
-- panel, que todo quede registrado bien». La tabla oficial vive en
-- documentos/PAQUETES-Y-PRECIOS.md; este archivo la lleva al
-- servidor para que el panel del dueño la muestre y cada empresa
-- quede registrada con lo que contrató y lo que paga:
--
--   1. Tabla `catalogo_precios`: la tabla oficial aprobada —
--      RutaNeto y TallerNeto por nivel (instalación US$99;
--      US$19/39/69/99/149 al mes según nivel 1–5), extras sueltos
--      de TallerNeto (Lavado US$10, Combustible US$15, ambos
--      US$19) y el PAQUETE DÚO (instalación única US$149; sin
--      extras US$29/59/109/159/239; con extras US$44/74/124/174/254).
--   2. La licencia de cada empresa gana su contratación:
--      `paquete` (rutaneto / tallerneto / duo_sin_extras /
--      duo_con_extras), `extra_lavado`, `extra_combustible`,
--      `instalacion_usd` y `mensualidad_usd`.
--   3. `pr_admin_catalogo(p_quien)`: el catálogo completo, solo
--      superadmin, para pintar la tabla de precios en su panel.
--   4. `pr_admin_fijar_contratacion(...)`: solo superadmin. Fija el
--      paquete y los extras de la empresa; el nivel sale del tope
--      de su licencia (max_choferes) o de sus choferes reales, y el
--      precio se CALCULA desde el catálogo (nadie escribe cifras a
--      mano). Queda en el registro de auditoría.
--   5. `pr_admin_resumen` (copia fiel de panel-por-empresa.sql):
--      cada empresa gana el objeto `contratacion` y los totales
--      ganan `mensualidadTotal` (suma de las mensualidades de las
--      licencias activas ya fijadas).

-- ============ 1. CATÁLOGO DE PRECIOS (tabla oficial aprobada) ============
create table if not exists catalogo_precios (
  clave text primary key,
  descripcion text not null,
  nivel_min int,
  nivel_max int,
  instalacion_usd numeric(10,2) not null default 0,
  mensualidad_usd numeric(10,2) not null default 0
);
alter table catalogo_precios enable row level security;

insert into catalogo_precios (clave, descripcion, nivel_min, nivel_max, instalacion_usd, mensualidad_usd) values
  ('rutaneto_n1',   'RutaNeto · nivel 1 (1–5)',          1,   5,   99,  19),
  ('rutaneto_n2',   'RutaNeto · nivel 2 (6–15)',         6,   15,  99,  39),
  ('rutaneto_n3',   'RutaNeto · nivel 3 (16–40)',        16,  40,  99,  69),
  ('rutaneto_n4',   'RutaNeto · nivel 4 (41–80)',        41,  80,  99,  99),
  ('rutaneto_n5',   'RutaNeto · nivel 5 (81–150)',       81,  150, 99,  149),
  ('tallerneto_n1', 'TallerNeto · nivel 1 (1–5)',        1,   5,   99,  19),
  ('tallerneto_n2', 'TallerNeto · nivel 2 (6–15)',       6,   15,  99,  39),
  ('tallerneto_n3', 'TallerNeto · nivel 3 (16–40)',      16,  40,  99,  69),
  ('tallerneto_n4', 'TallerNeto · nivel 4 (41–80)',      41,  80,  99,  99),
  ('tallerneto_n5', 'TallerNeto · nivel 5 (81–150)',     81,  150, 99,  149),
  ('duo_sin_n1',    'Paquete Dúo sin extras · nivel 1',  1,   5,   149, 29),
  ('duo_sin_n2',    'Paquete Dúo sin extras · nivel 2',  6,   15,  149, 59),
  ('duo_sin_n3',    'Paquete Dúo sin extras · nivel 3',  16,  40,  149, 109),
  ('duo_sin_n4',    'Paquete Dúo sin extras · nivel 4',  41,  80,  149, 159),
  ('duo_sin_n5',    'Paquete Dúo sin extras · nivel 5',  81,  150, 149, 239),
  ('duo_con_n1',    'Paquete Dúo con extras · nivel 1',  1,   5,   149, 44),
  ('duo_con_n2',    'Paquete Dúo con extras · nivel 2',  6,   15,  149, 74),
  ('duo_con_n3',    'Paquete Dúo con extras · nivel 3',  16,  40,  149, 124),
  ('duo_con_n4',    'Paquete Dúo con extras · nivel 4',  41,  80,  149, 174),
  ('duo_con_n5',    'Paquete Dúo con extras · nivel 5',  81,  150, 149, 254),
  ('extra_lavado',      'Extra de TallerNeto: Lavado',      null, null, 0, 10),
  ('extra_combustible', 'Extra de TallerNeto: Combustible', null, null, 0, 15),
  ('extras_ambos',      'Extras de TallerNeto: Lavado + Combustible', null, null, 0, 19)
on conflict (clave) do update set
  descripcion = excluded.descripcion,
  nivel_min = excluded.nivel_min,
  nivel_max = excluded.nivel_max,
  instalacion_usd = excluded.instalacion_usd,
  mensualidad_usd = excluded.mensualidad_usd;

-- ============ 2. LA CONTRATACIÓN VIVE EN LA LICENCIA ============
alter table licencias add column if not exists paquete text not null default 'rutaneto';
alter table licencias add column if not exists extra_lavado boolean not null default false;
alter table licencias add column if not exists extra_combustible boolean not null default false;
alter table licencias add column if not exists instalacion_usd numeric(10,2);
alter table licencias add column if not exists mensualidad_usd numeric(10,2);

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'licencias_paquete_check') then
    alter table licencias add constraint licencias_paquete_check
      check (paquete in ('rutaneto','tallerneto','duo_sin_extras','duo_con_extras'));
  end if;
end $$;

-- ============ 3. NIVEL Y CÁLCULO DESDE EL CATÁLOGO ============
-- Nivel 1–5 según el tamaño de la empresa (choferes o vehículos).
create or replace function pr__nivel_precio(p_tamano int) returns int
language sql immutable as $$
  select case when coalesce(p_tamano, 0) <= 5  then 1
              when p_tamano <= 15 then 2
              when p_tamano <= 40 then 3
              when p_tamano <= 80 then 4
              else 5 end;
$$;

-- Precio de una contratación, siempre leído del catálogo.
create or replace function pr__calcular_contratacion(p_paquete text, p_nivel int,
                                                     p_extra_lavado boolean,
                                                     p_extra_combustible boolean)
returns jsonb language plpgsql stable security definer as $$
declare
  v_prefijo text;
  v_base catalogo_precios;
  v_mes numeric(10,2);
begin
  if p_paquete not in ('rutaneto','tallerneto','duo_sin_extras','duo_con_extras') then
    raise exception 'Paquete no válido: %', p_paquete;
  end if;
  if p_paquete = 'rutaneto' and (p_extra_lavado or p_extra_combustible) then
    raise exception 'Los extras de Lavado y Combustible son de TallerNeto: no aplican a un plan de solo RutaNeto';
  end if;
  if p_paquete = 'duo_sin_extras' and (p_extra_lavado or p_extra_combustible) then
    raise exception 'El Paquete Dúo sin extras no incluye Lavado ni Combustible: usa el Dúo con extras';
  end if;
  v_prefijo := case p_paquete
                 when 'rutaneto' then 'rutaneto'
                 when 'tallerneto' then 'tallerneto'
                 when 'duo_sin_extras' then 'duo_sin'
                 else 'duo_con' end;
  select * into v_base from catalogo_precios
  where clave = v_prefijo || '_n' || p_nivel;
  if v_base.clave is null then
    raise exception 'No hay precio en el catálogo para el paquete % en el nivel %', p_paquete, p_nivel;
  end if;
  v_mes := v_base.mensualidad_usd;
  if p_paquete = 'tallerneto' then
    if p_extra_lavado and p_extra_combustible then
      v_mes := v_mes + (select mensualidad_usd from catalogo_precios where clave = 'extras_ambos');
    elsif p_extra_lavado then
      v_mes := v_mes + (select mensualidad_usd from catalogo_precios where clave = 'extra_lavado');
    elsif p_extra_combustible then
      v_mes := v_mes + (select mensualidad_usd from catalogo_precios where clave = 'extra_combustible');
    end if;
  end if;
  return jsonb_build_object(
    'instalacionUsd', v_base.instalacion_usd,
    'mensualidadUsd', v_mes,
    'nivel', p_nivel);
end;
$$;

-- ============ 4. EL CATÁLOGO PARA EL PANEL DEL DUEÑO ============
create or replace function pr_admin_catalogo(p_quien uuid)
returns jsonb language plpgsql security definer as $$
begin
  perform pr_exigir_superadmin(p_quien);
  return jsonb_build_object('precios', coalesce((
    select jsonb_agg(jsonb_build_object(
      'clave', c.clave,
      'descripcion', c.descripcion,
      'nivelMin', c.nivel_min,
      'nivelMax', c.nivel_max,
      'instalacionUsd', c.instalacion_usd,
      'mensualidadUsd', c.mensualidad_usd
    ) order by c.clave)
    from catalogo_precios c
  ), '[]'::jsonb));
end;
$$;

-- ============ 5. FIJAR LA CONTRATACIÓN DE UNA EMPRESA ============
-- El nivel sale del tope de la licencia vigente (max_choferes) o,
-- si la licencia no tiene tope, de los choferes reales de la
-- empresa. El precio se calcula desde el catálogo y queda guardado
-- en la licencia: eso es «todo registrado».
create or replace function pr_admin_fijar_contratacion(p_quien uuid, p_empresa uuid,
                                                       p_paquete text,
                                                       p_extra_lavado boolean default false,
                                                       p_extra_combustible boolean default false)
returns jsonb language plpgsql security definer as $$
declare
  emp empresas;
  lic licencias;
  v_tamano int;
  v_nivel int;
  v_calc jsonb;
  v_lav boolean := coalesce(p_extra_lavado, false);
  v_com boolean := coalesce(p_extra_combustible, false);
begin
  perform pr_exigir_superadmin(p_quien);

  select * into emp from empresas where id = p_empresa;
  if emp.id is null then
    raise exception 'Esa empresa no existe (¿ya fue eliminada?)';
  end if;

  select * into lic from licencias
  where empresa_id = p_empresa order by creada_en desc limit 1;
  if lic.id is null then
    raise exception 'La empresa «%» no tiene licencia: créala primero', emp.nombre;
  end if;

  -- En el Dúo con extras, los dos extras quedan registrados como
  -- incluidos (su precio ya va dentro de la fila del catálogo).
  if p_paquete = 'duo_con_extras' then
    v_lav := true;
    v_com := true;
  end if;

  v_tamano := coalesce(lic.max_choferes,
    (select count(*)::int from usuarios u
     where u.empresa_id = p_empresa and u.rol = 'chofer' and u.activo), 0);
  v_nivel := pr__nivel_precio(v_tamano);
  v_calc := pr__calcular_contratacion(p_paquete, v_nivel, v_lav, v_com);

  update licencias set
    paquete = p_paquete,
    extra_lavado = v_lav,
    extra_combustible = v_com,
    instalacion_usd = (v_calc ->> 'instalacionUsd')::numeric,
    mensualidad_usd = (v_calc ->> 'mensualidadUsd')::numeric
  where id = lic.id;

  perform pr_registrar_accion(p_empresa, p_quien, 'contratacion_fijada',
    format('Contratación de «%s»: paquete %s, nivel %s, instalación US$%s, mensualidad US$%s (extras: lavado %s, combustible %s)',
           emp.nombre, p_paquete, v_nivel,
           v_calc ->> 'instalacionUsd', v_calc ->> 'mensualidadUsd',
           case when v_lav then 'sí' else 'no' end,
           case when v_com then 'sí' else 'no' end));

  return jsonb_build_object(
    'paquete', p_paquete,
    'nivel', v_nivel,
    'extraLavado', v_lav,
    'extraCombustible', v_com,
    'instalacionUsd', (v_calc ->> 'instalacionUsd')::numeric,
    'mensualidadUsd', (v_calc ->> 'mensualidadUsd')::numeric);
end;
$$;

-- ============ 6. RESUMEN DEL SUPERADMIN (panel-por-empresa + contratación) ============
-- Copia fiel de la versión de panel-por-empresa.sql. Los cambios:
-- cada empresa gana el objeto `contratacion` (desde su última
-- licencia) y los totales ganan `mensualidadTotal`.
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
        'contratacion', case when l.id is null then null else jsonb_build_object(
          'paquete', l.paquete,
          'extraLavado', l.extra_lavado,
          'extraCombustible', l.extra_combustible,
          'instalacionUsd', l.instalacion_usd,
          'mensualidadUsd', l.mensualidad_usd) end,
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
      'mensualidadTotal', (select coalesce(sum(l3.mensualidad_usd), 0)
                    from empresas e3
                    join lateral (
                      select li.estado, li.mensualidad_usd from licencias li
                      where li.empresa_id = e3.id
                      order by li.creada_en desc limit 1
                    ) l3 on true
                    where l3.estado = 'activa'),
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
