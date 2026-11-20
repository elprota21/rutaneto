-- ================================================================
-- HORA DE LAS RUTAS (2026-11-20, pedido de Miguel)
-- ================================================================
-- Cada ruta puede tener su HORA (la hora en que se hace / sale la
-- ruta), opcional. Se coloca en el panel al crear o editar la ruta
-- y se ve en el panel (Rutas, Asignaciones y el detalle del chofer)
-- y en la app del chofer junto a la ruta. No afecta al dinero.
--
-- Idempotente: se aplica al final de la cadena, después de
-- asignaciones.sql, y se puede reaplicar sin daño.

-- ============ COLUMNA ============
alter table rutas add column if not exists hora time;

-- ============ CREAR / ACTUALIZAR RUTA CON HORA ============
-- Copia de permisos-crud.sql + el parámetro p_hora (opcional).
drop function if exists pr_crear_ruta(uuid, text, text, numeric, uuid, uuid);
create or replace function pr_crear_ruta(p_empresa uuid, p_codigo text, p_nombre text,
                                         p_precio numeric, p_cliente uuid default null,
                                         p_quien uuid default null,
                                         p_hora time default null)
returns rutas language plpgsql security definer as $$
declare
  nueva rutas;
  cli clientes;
begin
  perform pr_exigir_no_dueno(p_quien);
  if p_cliente is not null and not exists (
    select 1 from clientes where id = p_cliente and empresa_id = p_empresa
  ) then
    raise exception 'Esa empresa cliente no pertenece a tu empresa';
  end if;
  insert into rutas (empresa_id, cliente_id, codigo, nombre, precio, hora)
  values (p_empresa, p_cliente, trim(p_codigo), trim(p_nombre), p_precio, p_hora)
  returning * into nueva;
  select * into cli from clientes where id = nueva.cliente_id;
  perform pr_registrar_accion(p_empresa, p_quien, 'ruta_creada',
    format('Se creó la ruta %s «%s» con precio RD$%s (cliente: %s)%s',
           nueva.codigo, nueva.nombre, to_char(nueva.precio, 'FM999,999,990.00'),
           coalesce(cli.nombre, 'General'),
           case when nueva.hora is null then ''
                else format(', hora %s', to_char(nueva.hora, 'HH24:MI')) end));
  return nueva;
end;
$$;

drop function if exists pr_actualizar_ruta(uuid, text, numeric, uuid, uuid);
create or replace function pr_actualizar_ruta(p_ruta uuid, p_nombre text, p_precio numeric,
                                              p_cliente uuid default null,
                                              p_quien uuid default null,
                                              p_hora time default null)
returns void language plpgsql security definer as $$
declare
  r rutas;
  cli clientes;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into r from rutas where id = p_ruta;
  if r.id is null then raise exception 'Ruta no encontrada'; end if;
  if p_cliente is not null and not exists (
    select 1 from clientes where id = p_cliente and empresa_id = r.empresa_id
  ) then
    raise exception 'Esa empresa cliente no pertenece a tu empresa';
  end if;
  update rutas set nombre = trim(p_nombre), precio = p_precio, cliente_id = p_cliente,
                   hora = p_hora
  where id = p_ruta;
  select * into cli from clientes where id = p_cliente;
  perform pr_registrar_accion(r.empresa_id, p_quien, 'ruta_editada',
    format('Se editó la ruta %s: nombre «%s», precio RD$%s, cliente: %s%s',
           r.codigo, trim(p_nombre), to_char(p_precio, 'FM999,999,990.00'),
           coalesce(cli.nombre, 'General'),
           case when p_hora is null then ', sin hora'
                else format(', hora %s', to_char(p_hora, 'HH24:MI')) end));
end;
$$;

-- ============ SNAPSHOT: las rutas traen su hora ============
-- Copia fiel de asignaciones.sql + la clave 'hora' en las rutas.
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
        'precio', r.precio, 'activa', r.activa,
        'hora', to_char(r.hora, 'HH24:MI'))
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

-- ============ DATOS DEL CHOFER: las rutas traen su hora ============
-- Copia fiel de asignaciones.sql + la clave 'hora' en las rutas.
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
        'nombre', r.nombre, 'precio', r.precio,
        'hora', to_char(r.hora, 'HH24:MI'))
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
