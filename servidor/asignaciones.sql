-- ================================================================
-- ASIGNACIÓN DE RUTAS A CHOFERES (2026-11-19, pedido de Miguel)
-- ================================================================
-- La EMPRESA asigna rutas a cada chofer desde el panel: pueden ser
-- 3, 4, 8 o 10, sin límite; el chofer hace las que le pertenecen en
-- el día. La asignación se define por días de la semana (1=lunes …
-- 7=domingo, ISO) porque las rutas de transporte se repiten cada
-- semana. En la app el chofer ve sus rutas asignadas de hoy.
--
-- OJO — la asignación NO cambia la regla del dinero: si una ruta
-- cuenta como «de la empresa» (sueldo) o como «extra» (pagada) lo
-- sigue decidiendo el cupo diario que la empresa configura
-- (rutas_empresa_por_dia: ej. 5 de la empresa y el resto extra),
-- igual que antes de esta función.
--
-- Idempotente: se aplica al final de la cadena, después de
-- correcciones-venta.sql, y se puede reaplicar sin daño.

-- ============ TABLA ============
create table if not exists asignaciones_ruta (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  chofer_id uuid not null references usuarios(id) on delete cascade,
  ruta_id uuid not null references rutas(id) on delete cascade,
  dias_semana int[] not null default '{1,2,3,4,5}',
  creada_en timestamptz not null default now(),
  unique (empresa_id, chofer_id, ruta_id)
);
alter table asignaciones_ruta enable row level security;
create index if not exists idx_asignaciones_empresa_chofer
  on asignaciones_ruta (empresa_id, chofer_id);

-- ============ GUARDAR (reemplazo completo por chofer) ============
-- Solo la administración o el coordinador DE LA EMPRESA (el
-- superadmin no opera dentro de las empresas: regla del dueño).
-- p_asignaciones: [{"rutaId": uuid, "dias": [1,2,3,4,5]}]; un
-- elemento con dias vacío equivale a no asignar esa ruta.
create or replace function pr_guardar_asignaciones(
    p_empresa uuid, p_chofer uuid, p_asignaciones jsonb,
    p_actor uuid default null, p_token text default null)
returns void language plpgsql security definer as $$
declare
  a usuarios;
  chof usuarios;
  item jsonb;
  v_ruta uuid;
  v_dias int[];
  d int;
begin
  if p_actor is null then
    raise exception 'Para asignar rutas debes iniciar sesión';
  end if;
  select * into a from usuarios where id = p_actor and activo;
  if a.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_actor, p_token);
  if a.rol = 'superadmin' then
    raise exception 'El dueño no opera dentro de las empresas';
  end if;
  if a.rol not in ('empresa', 'coordinador') then
    raise exception 'Solo la administración o el coordinador de la empresa asignan rutas';
  end if;
  if a.empresa_id is distinct from p_empresa then
    raise exception 'No tienes permiso para asignar rutas en esta empresa';
  end if;

  select * into chof from usuarios where id = p_chofer;
  if chof.id is null then raise exception 'El chofer indicado no existe'; end if;
  if chof.empresa_id is distinct from p_empresa then
    raise exception 'Ese chofer no pertenece a esta empresa';
  end if;
  if chof.rol not in ('chofer', 'coordinador') then
    raise exception 'Solo se asignan rutas a choferes y coordinadores';
  end if;
  if not chof.activo then raise exception 'Ese chofer está desactivado'; end if;

  if p_asignaciones is null or jsonb_typeof(p_asignaciones) <> 'array' then
    raise exception 'La lista de asignaciones no es válida';
  end if;

  -- Validar TODO antes de tocar nada: rutas de esta empresa y
  -- días entre 1 y 7.
  for item in select * from jsonb_array_elements(p_asignaciones) loop
    v_ruta := (item ->> 'rutaId')::uuid;
    if not exists (select 1 from rutas r
                   where r.id = v_ruta and r.empresa_id = p_empresa) then
      raise exception 'Una de las rutas no pertenece a esta empresa';
    end if;
    select array_agg(x::int) into v_dias
    from jsonb_array_elements_text(coalesce(item -> 'dias', '[]'::jsonb)) x;
    if v_dias is not null then
      foreach d in array v_dias loop
        if d < 1 or d > 7 then
          raise exception 'Los días de la semana van de 1 (lunes) a 7 (domingo)';
        end if;
      end loop;
    end if;
  end loop;

  delete from asignaciones_ruta
  where empresa_id = p_empresa and chofer_id = p_chofer;

  for item in select * from jsonb_array_elements(p_asignaciones) loop
    v_ruta := (item ->> 'rutaId')::uuid;
    select array_agg(distinct x::int) into v_dias
    from jsonb_array_elements_text(coalesce(item -> 'dias', '[]'::jsonb)) x;
    if v_dias is not null and array_length(v_dias, 1) > 0 then
      insert into asignaciones_ruta (empresa_id, chofer_id, ruta_id, dias_semana)
      values (p_empresa, p_chofer, v_ruta, v_dias);
    end if;
  end loop;
end;
$$;

-- ============ SNAPSHOT: la foto del panel trae las asignaciones ============
-- Copia fiel de correcciones-venta.sql + la clave 'asignaciones'.
drop function if exists pr_snapshot(uuid);
create or replace function pr_snapshot(p_empresa uuid default null,
                                       p_quien uuid default null,
                                       p_token text default null)
returns jsonb language plpgsql security definer as $$
declare
  emp uuid := p_empresa;
  e empresas;
  o opciones_empresa;
  lic licencias;
  q usuarios;
begin
  if p_quien is null then
    raise exception 'Para ver los datos de una empresa debes iniciar sesión';
  end if;
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);

  if emp is null then
    if q.rol = 'superadmin' then
      select id into emp from empresas order by creada_en limit 1;
    else
      emp := q.empresa_id;
    end if;
  end if;
  if emp is null then raise exception 'Empresa no encontrada'; end if;
  if q.rol <> 'superadmin' and q.empresa_id is distinct from emp then
    raise exception 'No tienes permiso para ver los datos de esta empresa';
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
                            else lic.vence - pr_hoy() end,
      'porVencer', case when lic.vence is null then false
                        else (lic.vence - pr_hoy()) between 0 and 30 end
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
    'asignaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'choferId', ar.chofer_id, 'rutaId', ar.ruta_id, 'dias', ar.dias_semana)
        order by ar.chofer_id, ar.ruta_id)
      from asignaciones_ruta ar where ar.empresa_id = emp
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
        'anulado', v.anulado, 'anuladoMotivo', v.anulado_motivo,
        'anuladoEn', v.anulado_en,
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

-- ============ DATOS DEL CHOFER: sus asignaciones y las de hoy ============
-- Copia fiel de correcciones-venta.sql + las claves 'asignaciones'
-- (todas las suyas, con sus días) y 'asignadasHoy' (ids de rutas
-- cuyo día coincide con hoy, hora de RD vía pr_hoy()).
drop function if exists pr_datos_chofer(uuid, uuid);
drop function if exists pr_datos_chofer(uuid, uuid, text);
create or replace function pr_datos_chofer(p_empresa uuid, p_chofer uuid,
                                           p_token text default null)
returns jsonb language plpgsql stable security definer as $$
declare
  u usuarios;
  o opciones_empresa;
  foto jsonb;
  v_ver text;
  v_vapp boolean;
  v_ultimo date;
begin
  select * into u from usuarios
  where id = p_chofer and empresa_id = p_empresa and activo
    and rol in ('chofer', 'coordinador');
  if u.id is null then
    raise exception 'Chofer no encontrado en esta empresa';
  end if;
  perform pr_validar_token(p_chofer, p_token);
  perform pr_exigir_empresa_operativa(p_empresa);

  o := pr_opciones(p_empresa);
  v_ver := coalesce(o.ver_ganado, 'todo');
  v_vapp := coalesce(o.voucher_app, true);
  select max(fecha) into v_ultimo from anotaciones
  where empresa_id = p_empresa and chofer_id = p_chofer and estado = 'aprobada';

  foto := jsonb_build_object(
    'clientes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'nombre', c.nombre)
                       order by c.nombre)
      from clientes c
      where c.empresa_id = p_empresa and c.activo
    ), '[]'::jsonb),
    'rutas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'clienteId', r.cliente_id, 'codigo', r.codigo,
        'nombre', r.nombre, 'precio', r.precio)
        order by r.codigo)
      from rutas r
      where r.empresa_id = p_empresa and r.activa
    ), '[]'::jsonb),
    'anotaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'rutaId', a.ruta_id, 'clienteId', a.cliente_id,
        'rutaNombre', r.nombre, 'clienteNombre', c.nombre,
        'tipo', a.tipo, 'descripcion', a.descripcion, 'nota', a.nota,
        'fecha', to_char(a.fecha, 'YYYY-MM-DD'), 'clase', a.clase,
        'estado', a.estado,
        'precioAplicado', case
          when v_ver = 'nada' then null
          when v_ver = 'ultimo_dia' and a.fecha is distinct from v_ultimo then null
          else a.precio_aplicado end,
        'resolucion', a.resolucion,
        'creadaEn', a.creada_en)
        order by a.creada_en desc)
      from anotaciones a
      left join rutas r on r.id = a.ruta_id
      left join clientes c on c.id = a.cliente_id
      where a.empresa_id = p_empresa and a.chofer_id = p_chofer
        and a.fecha >= pr_hoy() - 45
    ), '[]'::jsonb),
    'vouchers', case when not v_vapp then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'folio', v.folio,
        'desde', to_char(v.desde, 'YYYY-MM-DD'),
        'hasta', to_char(v.hasta, 'YYYY-MM-DD'),
        'numEmpresa', v.num_empresa, 'numExtra', v.num_extra,
        'totalEmpresa', case when v_ver = 'nada' then null else v.total_empresa end,
        'totalExtra', case when v_ver = 'nada' then null else v.total_extra end,
        'total', case when v_ver = 'nada' then null else v.total end,
        'anulado', v.anulado, 'anuladoMotivo', v.anulado_motivo,
        'creadaEn', v.creado_en,
        'detalle', coalesce((
          select jsonb_agg(jsonb_build_object(
            'fecha', to_char(d.fecha, 'YYYY-MM-DD'),
            'descripcion', d.descripcion, 'cliente', d.cliente,
            'clase', d.clase,
            'precio', case when v_ver = 'nada' then null else d.precio end)
            order by d.fecha)
          from voucher_detalle d where d.voucher_id = v.id
        ), '[]'::jsonb))
        order by v.folio desc)
      from vouchers v
      where v.empresa_id = p_empresa and v.chofer_id = p_chofer
    ), '[]'::jsonb) end,
    'asignaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'rutaId', ar.ruta_id, 'dias', ar.dias_semana)
        order by ar.ruta_id)
      from asignaciones_ruta ar
      where ar.empresa_id = p_empresa and ar.chofer_id = p_chofer
    ), '[]'::jsonb),
    'asignadasHoy', coalesce((
      select jsonb_agg(ar.ruta_id)
      from asignaciones_ruta ar
      where ar.empresa_id = p_empresa and ar.chofer_id = p_chofer
        and extract(isodow from pr_hoy())::int = any(ar.dias_semana)
    ), '[]'::jsonb),
    'reportes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', rp.id, 'tipo', rp.tipo, 'texto', rp.mensaje,
        'estado', rp.estado, 'esCoordinador', u.rol = 'coordinador',
        'autorNombre', u.nombre,
        'creadaEn', rp.creada_en)
        order by rp.creada_en desc)
      from (
        select * from reportes
        where empresa_id = p_empresa and autor_id = p_chofer
        order by creada_en desc limit 100
      ) rp
    ), '[]'::jsonb)
  );

  -- Solo el coordinador: los reportes pendientes de su empresa.
  if u.rol = 'coordinador' then
    foto := foto || jsonb_build_object(
      'reportesPendientes', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', rp.id, 'tipo', rp.tipo, 'texto', rp.mensaje,
          'choferNombre', au.nombre,
          'autorNombre', au.nombre,
          'esCoordinador', au.rol = 'coordinador',
          'creadaEn', rp.creada_en)
          order by rp.creada_en desc)
        from reportes rp
        join usuarios au on au.id = rp.autor_id
        where rp.empresa_id = p_empresa and rp.estado = 'nuevo'
      ), '[]'::jsonb)
    );
  end if;

  return foto;
end;
$$;
