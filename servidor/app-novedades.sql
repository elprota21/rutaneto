-- Pago por Rutas — novedades en vivo para la APP (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + app-datos.sql +
-- ajustes-2026-11-15.sql (la tabla `reportes` vive en ajustes). Es
-- idempotente: pr_datos_chofer se elimina y se recrea con la MISMA
-- firma (uuid, uuid) -> jsonb; correrlo dos veces no rompe nada.
--
-- Por qué existe: la app 1.4.0 sondea pr_datos_chofer cada 30 s para
-- estar EN VIVO y avisar al usuario con notificación (sonido y
-- vibración) cuando pasa algo suyo. Para detectar esos cambios la foto
-- del chofer necesitaba tres cosas que hoy no baja:
--
--   reportes:           los reportes DEL PROPIO usuario (id, tipo,
--                       texto, estado, creadaEn), para saber cuándo
--                       administración resuelve uno suyo. Hasta ahora la
--                       app solo conocía los enviados en la sesión.
--   vouchers:           se agregan `id` y `creadaEn` a las claves que
--                       ya traía (folio, desde, hasta, totales,
--                       detalle…), para detectar «voucher nuevo» sin
--                       ambigüedad.
--   anotaciones:        se agrega `resolucion` ('unico' | 'ambas' |
--                       null), para contar cómo se resolvió un
--                       conflicto: a su favor, a favor del otro o
--                       aprobadas ambas.
--
--   reportesPendientes: SOLO si quien pide es el COORDINADOR de la
--                       empresa: los reportes en estado 'nuevo' de su
--                       empresa (id, tipo, texto, choferNombre,
--                       esCoordinador, creadaEn), para avisarle cuando
--                       un chofer reporta algo. Hasta ahora la función
--                       rechazaba al coordinador («Chofer no
--                       encontrado»); su foto es mínima: las claves de
--                       chofer (clientes, rutas, anotaciones, vouchers)
--                       van vacías y trae `reportes` (los suyos) +
--                       `reportesPendientes`.
--
-- Compatibilidad: la app 1.3.0 desplegada ignora las claves nuevas y
-- sigue funcionando (las claves actuales quedan intactas, con los
-- mismos nombres y formato). Los roles de oficina (empresa) y el
-- superadmin siguen rechazados con el mismo mensaje de antes.

drop function if exists pr_datos_chofer(uuid, uuid);

create function pr_datos_chofer(p_empresa uuid, p_chofer uuid)
returns jsonb language plpgsql stable security definer as $$
declare u usuarios;
begin
  select * into u from usuarios
  where id = p_chofer and empresa_id = p_empresa and activo
    and rol in ('chofer', 'coordinador');
  if u.id is null then
    raise exception 'Chofer no encontrado en esta empresa';
  end if;

  -- ============ COORDINADOR: foto mínima de reportes ============
  if u.rol = 'coordinador' then
    return jsonb_build_object(
      'clientes', '[]'::jsonb,
      'rutas', '[]'::jsonb,
      'anotaciones', '[]'::jsonb,
      'vouchers', '[]'::jsonb,
      'reportes', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', rp.id, 'tipo', rp.tipo, 'texto', rp.mensaje,
          'estado', rp.estado, 'esCoordinador', true,
          'creadaEn', rp.creada_en)
          order by rp.creada_en desc)
        from (
          select * from reportes
          where empresa_id = p_empresa and autor_id = p_chofer
          order by creada_en desc limit 100
        ) rp
      ), '[]'::jsonb),
      'reportesPendientes', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', rp.id, 'tipo', rp.tipo, 'texto', rp.mensaje,
          'choferNombre', au.nombre,
          'esCoordinador', au.rol = 'coordinador',
          'creadaEn', rp.creada_en)
          order by rp.creada_en desc)
        from reportes rp
        join usuarios au on au.id = rp.autor_id
        where rp.empresa_id = p_empresa and rp.estado = 'nuevo'
      ), '[]'::jsonb)
    );
  end if;

  -- ============ CHOFER: la foto completa de siempre + novedades ============
  return jsonb_build_object(
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
        'estado', a.estado, 'precioAplicado', a.precio_aplicado,
        'resolucion', a.resolucion,
        'creadaEn', a.creada_en)
        order by a.creada_en desc)
      from anotaciones a
      left join rutas r on r.id = a.ruta_id
      left join clientes c on c.id = a.cliente_id
      where a.empresa_id = p_empresa and a.chofer_id = p_chofer
        and a.fecha >= current_date - 45
    ), '[]'::jsonb),
    'vouchers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id, 'folio', v.folio,
        'desde', to_char(v.desde, 'YYYY-MM-DD'),
        'hasta', to_char(v.hasta, 'YYYY-MM-DD'),
        'numEmpresa', v.num_empresa, 'numExtra', v.num_extra,
        'totalEmpresa', v.total_empresa, 'totalExtra', v.total_extra,
        'total', v.total,
        'creadaEn', v.creado_en,
        'detalle', coalesce((
          select jsonb_agg(jsonb_build_object(
            'fecha', to_char(d.fecha, 'YYYY-MM-DD'),
            'descripcion', d.descripcion, 'cliente', d.cliente,
            'clase', d.clase, 'precio', d.precio)
            order by d.fecha)
          from voucher_detalle d where d.voucher_id = v.id
        ), '[]'::jsonb))
        order by v.folio desc)
      from vouchers v
      where v.empresa_id = p_empresa and v.chofer_id = p_chofer
    ), '[]'::jsonb),
    'reportes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', rp.id, 'tipo', rp.tipo, 'texto', rp.mensaje,
        'estado', rp.estado, 'esCoordinador', false,
        'creadaEn', rp.creada_en)
        order by rp.creada_en desc)
      from (
        select * from reportes
        where empresa_id = p_empresa and autor_id = p_chofer
        order by creada_en desc limit 100
      ) rp
    ), '[]'::jsonb)
  );
end;
$$;
