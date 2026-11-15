-- Pago por Rutas — datos de la APP del chofer v1 (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql (en producción basta
-- correrlo una vez en el editor SQL; es idempotente: create or replace).
--
-- Por qué existe: RLS está activa sin políticas, así que la app no puede
-- leer tablas directo con la anon key, y pr_snapshot (del panel) devuelve
-- TODA la empresa — anotaciones y vouchers de todos los choferes —, que no
-- es lo que debe bajar al teléfono de un chofer. Esta es la foto mínima
-- del propio chofer, en una sola llamada:
--
--   pr_datos_chofer(empresa, chofer) -> jsonb con:
--     clientes:    empresas cliente activas de la transportista (id, nombre)
--     rutas:       rutas activas con su precio (id, clienteId, codigo,
--                  nombre, precio)
--     anotaciones: las DEL CHOFER de los últimos 45 días, con el nombre de
--                  la ruta y del cliente ya resueltos (también para rutas
--                  ya desactivadas), más recientes primero
--     vouchers:    los vouchers DEL CHOFER con su detalle, folio mayor
--                  primero (mismo formato que pr_snapshot)
--
-- La lógica de negocio no se duplica: anotar va por pr_anotar_ruta /
-- pr_anotar_especial, el ganado por pr_mi_ganado / pr_resumen_chofer y la
-- generación de vouchers es de la empresa (panel); aquí solo se lee.

create or replace function pr_datos_chofer(p_empresa uuid, p_chofer uuid)
returns jsonb language plpgsql stable security definer as $$
declare u usuarios;
begin
  select * into u from usuarios
  where id = p_chofer and empresa_id = p_empresa and rol = 'chofer' and activo;
  if u.id is null then
    raise exception 'Chofer no encontrado en esta empresa';
  end if;

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
    ), '[]'::jsonb)
  );
end;
$$;
