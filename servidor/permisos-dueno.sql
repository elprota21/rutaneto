-- Pago por Rutas — permisos del dueño (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + semilla.sql +
-- app-datos.sql + ajustes-2026-11-15.sql + acceso-roles.sql +
-- auditoria.sql + caducidad.sql.
-- No reescribe aquellos archivos: todo va con create or replace
-- (y un drop puntual de firma en pr_generar_voucher), así que
-- correrlo de nuevo no rompe nada.
--
-- Regla de Miguel (2026-11-15): el dueño de RutaNeto (superadmin) NO
-- opera dentro de las empresas. Su panel de administrador no abre la
-- administración de una empresa salvo que él le dé a «Entrar», y ni
-- así puede aprobar ni editar nada de la empresa: la operación es de
-- la empresa. ÚNICA excepción: reiniciar la contraseña/PIN del
-- administrador de la empresa si la pierde (pr_admin_pin_admin, que
-- ya existía y se queda tal cual).
--
-- Qué trae:
--   1. pr_exigir_no_dueno: ayudante interno. Si el actor es un
--      superadmin, levanta el mensaje exacto de la regla. Se llama
--      como PRIMERA validación (antes de tocar los datos de la
--      empresa) en cada función de operación interna que recibe
--      actor.
--   2. Funciones que pasan a rechazar al superadmin con ese mensaje:
--        pr_resolver_conflicto(p_quien)
--        pr_validar_especial(p_coordinador)
--        pr_rechazar_anotacion(p_quien)   (esquema.sql)
--        pr_borrar_cliente(p_quien)       (pasa a ser SOLO rol empresa)
--        pr_resolver_reporte(p_quien)     (pierde la vía superadmin)
--        pr_generar_voucher               (ver punto 3)
--   3. pr_generar_voucher no recibía actor: gana el parámetro
--      opcional p_quien uuid default null AL FINAL de la firma (se
--      elimina la firma anterior para que quede UNA sola función y
--      PostgREST no tenga sobrecargas ambiguas; las llamadas sin
--      p_quien siguen funcionando por el default). Si p_quien viene
--      y es superadmin → el mismo rechazo; si viene, la fila de
--      auditoría 'voucher_generado' ya lleva su actor (antes quedaba
--      sin actor porque la firma no lo traía).
--
-- Funciones SIN actor en su firma (no se puede validar un rol que no
-- se recibe; quedan como están y se listan para que conste):
--   pr_crear_usuario, pr_cambiar_activo_usuario, pr_crear_cliente,
--   pr_cambiar_activo_cliente, pr_crear_ruta, pr_actualizar_ruta,
--   pr_cambiar_activa_ruta, pr_agregar_feriado, pr_quitar_feriado
--   (CRUD del panel) y pr_actualizar_opciones.
--
-- Se MANTIENE permitido para el superadmin (consulta o su área):
--   pr_admin_resumen, pr_admin_crear_empresa, pr_admin_licencia,
--   pr_admin_pin_admin (LA excepción), pr_admin_registro,
--   pr_registro_empresa (lectura de supervisión), pr_snapshot
--   (lectura), pr_iniciar_sesion con contexto 'panel' (entrar a VER,
--   en modo consulta) y pr_cambiar_pin sobre su propia cuenta.

-- ============ 1. AYUDANTE INTERNO ============
-- Levanta el mensaje de la regla si el actor es superadmin. Con
-- p_quien null (llamadas sin actor) o un actor inexistente no hace
-- nada: la validación de existencia la sigue haciendo cada función
-- como hasta ahora.
create or replace function pr_exigir_no_dueno(p_quien uuid)
returns void language plpgsql security definer as $$
declare u usuarios;
begin
  if p_quien is null then return; end if;
  select * into u from usuarios where id = p_quien;
  if u.id is not null and u.rol = 'superadmin' then
    raise exception 'El dueño de RutaNeto no opera dentro de la empresa: esto lo hace la administración de la empresa.';
  end if;
end;
$$;

-- ============ 2. CONFLICTOS (auditoria.sql + guarda del dueño) ============
create or replace function pr_resolver_conflicto(p_anotacion uuid, p_quien uuid,
                                                 p_modo text default 'unico')
returns void language plpgsql security definer as $$
declare
  a anotaciones;
  r rutas;
  c clientes;
  ganador usuarios;
  v_detalle text;
begin
  perform pr_exigir_no_dueno(p_quien);
  if p_modo not in ('unico','ambas') then
    raise exception 'Modo de resolucion no valido: %', p_modo;
  end if;
  select * into a from anotaciones where id = p_anotacion and estado = 'conflicto';
  if a.id is null then raise exception 'Esa anotacion no esta en conflicto'; end if;

  select * into r from rutas where id = a.ruta_id;
  select * into c from clientes where id = a.cliente_id;
  select * into ganador from usuarios where id = a.chofer_id;
  if p_modo = 'ambas' then
    v_detalle := format('Resolvió el conflicto de la ruta %s «%s» (cliente: %s) aprobando ambas anotaciones',
                        r.codigo, r.nombre, coalesce(c.nombre, 'General'));
  else
    v_detalle := format('Resolvió el conflicto de la ruta %s «%s» (cliente: %s) a favor de %s',
                        r.codigo, r.nombre, coalesce(c.nombre, 'General'), ganador.codigo);
  end if;

  if p_modo = 'ambas' then
    update anotaciones
    set estado = 'aprobada', validada_por = p_quien, resolucion = 'ambas'
    where empresa_id = a.empresa_id and ruta_id = a.ruta_id and fecha = a.fecha
      and cliente_id is not distinct from a.cliente_id
      and tipo = 'normal' and estado = 'conflicto';
    perform pr_registrar_accion(a.empresa_id, p_quien, 'conflicto_resuelto', v_detalle);
    return;
  end if;

  update anotaciones set estado = 'aprobada', validada_por = p_quien, resolucion = 'unico'
  where id = p_anotacion;
  update anotaciones set estado = 'rechazada', validada_por = p_quien, resolucion = 'unico'
  where empresa_id = a.empresa_id and ruta_id = a.ruta_id and fecha = a.fecha
    and cliente_id is not distinct from a.cliente_id
    and tipo = 'normal' and id <> p_anotacion and estado = 'conflicto';
  perform pr_registrar_accion(a.empresa_id, p_quien, 'conflicto_resuelto', v_detalle);
end;
$$;

-- ============ 3. RUTAS ESPECIALES (auditoria.sql + guarda del dueño) ============
create or replace function pr_validar_especial(p_anotacion uuid, p_coordinador uuid, p_precio numeric,
                                               p_aprobar boolean default true,
                                               p_convertir boolean default false,
                                               p_codigo text default null)
returns anotaciones language plpgsql security definer as $$
declare
  a anotaciones;
  coord usuarios;
  nueva_ruta rutas;
  chof usuarios;
begin
  perform pr_exigir_no_dueno(p_coordinador);
  select * into a from anotaciones where id = p_anotacion and tipo = 'especial' and estado = 'especial_pendiente';
  if a.id is null then raise exception 'Esa ruta especial no esta pendiente'; end if;
  select * into coord from usuarios where id = p_coordinador and empresa_id = a.empresa_id
    and rol in ('coordinador','empresa') and activo;
  if coord.id is null then raise exception 'Solo el coordinador o la empresa pueden validar'; end if;
  select * into chof from usuarios where id = a.chofer_id;

  if not p_aprobar then
    update anotaciones set estado = 'rechazada', validada_por = p_coordinador
    where id = p_anotacion returning * into a;
    perform pr_registrar_accion(a.empresa_id, p_coordinador, 'especial_rechazada',
      format('Rechazó la ruta especial «%s» de %s', a.descripcion, chof.codigo));
    return a;
  end if;
  if p_precio is null or p_precio < 0 then raise exception 'La validacion necesita un precio'; end if;

  if p_convertir then
    insert into rutas (empresa_id, cliente_id, codigo, nombre, precio)
    values (a.empresa_id, a.cliente_id, coalesce(p_codigo, 'ESP-' || to_char(now(),'YYMMDDHH24MI')),
            a.descripcion, p_precio)
    returning * into nueva_ruta;
    update anotaciones set ruta_id = nueva_ruta.id where id = p_anotacion;
  end if;

  update anotaciones set estado = 'aprobada', precio_aplicado = p_precio, validada_por = p_coordinador
  where id = p_anotacion returning * into a;
  perform pr_registrar_accion(a.empresa_id, p_coordinador, 'especial_validada',
    format('Validó la ruta especial «%s» de %s con precio RD$%s%s',
           a.descripcion, chof.codigo, to_char(p_precio, 'FM999,999,990.00'),
           case when p_convertir
                then format(' y la convirtió en la ruta %s', nueva_ruta.codigo)
                else '' end));
  return a;
end;
$$;

-- ============ 4. RECHAZO MANUAL (esquema.sql + guarda del dueño) ============
-- Rechazar una anotación también es operar dentro de la empresa:
-- recibe actor (p_quien) y la regla le aplica igual.
create or replace function pr_rechazar_anotacion(p_anotacion uuid, p_quien uuid)
returns void language plpgsql security definer as $$
begin
  perform pr_exigir_no_dueno(p_quien);
  update anotaciones set estado = 'rechazada', validada_por = p_quien
  where id = p_anotacion and estado <> 'rechazada';
end;
$$;

-- ============ 5. VOUCHERS (auditoria.sql + p_quien opcional) ============
-- Se elimina la firma anterior de 4 argumentos y se recrea con
-- p_quien al final (default null): queda UNA sola pr_generar_voucher
-- y las llamadas de 4 argumentos siguen funcionando por el default.
drop function if exists pr_generar_voucher(uuid, uuid, date, date);
drop function if exists pr_generar_voucher(uuid, uuid, date, date, uuid);
create or replace function pr_generar_voucher(p_empresa uuid, p_chofer uuid, p_desde date, p_hasta date,
                                              p_quien uuid default null)
returns vouchers language plpgsql security definer as $$
declare
  res record;
  v vouchers;
  nuevo_folio int;
  chof usuarios;
begin
  perform pr_exigir_no_dueno(p_quien);
  if not pr_licencia_ok(p_empresa) then raise exception 'Licencia inactiva'; end if;
  select * into res from pr_resumen_chofer(p_empresa, p_chofer, p_desde, p_hasta);
  select coalesce(max(folio), 0) + 1 into nuevo_folio from vouchers where empresa_id = p_empresa;
  insert into vouchers (empresa_id, chofer_id, folio, desde, hasta, num_empresa, num_extra,
                        total_empresa, total_extra, total)
  values (p_empresa, p_chofer, nuevo_folio, p_desde, p_hasta, res.num_empresa, res.num_extra,
          res.total_empresa, res.total_extra, res.total)
  returning * into v;
  insert into voucher_detalle (voucher_id, anotacion_id, fecha, descripcion, cliente, clase, precio)
  select v.id, a.id, a.fecha,
         coalesce(r.nombre, a.descripcion, 'Ruta especial'),
         c.nombre,
         a.clase,
         case when a.clase = 'extra' then a.precio_aplicado else 0 end
  from anotaciones a left join rutas r on r.id = a.ruta_id
  left join clientes c on c.id = a.cliente_id
  where a.empresa_id = p_empresa and a.chofer_id = p_chofer
    and a.estado = 'aprobada' and a.fecha between p_desde and p_hasta
  order by a.fecha, a.creada_en;
  select * into chof from usuarios where id = p_chofer;
  perform pr_registrar_accion(p_empresa, p_quien, 'voucher_generado',
    format('Se generó el voucher #%s para %s (%s) del %s al %s por RD$%s',
           v.folio, chof.codigo, chof.nombre,
           to_char(v.desde, 'DD/MM/YYYY'), to_char(v.hasta, 'DD/MM/YYYY'),
           to_char(v.total, 'FM999,999,990.00')));
  return v;
end;
$$;

-- ============ 6. BORRAR CLIENTE (auditoria.sql + guarda; SOLO rol empresa) ============
create or replace function pr_borrar_cliente(p_cliente uuid, p_quien uuid)
returns void language plpgsql security definer as $$
declare
  q usuarios;
  c clientes;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  if q.rol <> 'empresa' then
    raise exception 'Solo un administrador puede borrar empresas cliente';
  end if;
  select * into c from clientes where id = p_cliente;
  if c.id is null then raise exception 'Esa empresa cliente no existe'; end if;
  if c.empresa_id <> q.empresa_id then
    raise exception 'Esa empresa cliente no pertenece a tu empresa';
  end if;
  delete from clientes where id = p_cliente;
  perform pr_registrar_accion(c.empresa_id, p_quien, 'cliente_borrado',
    format('Borró la empresa cliente «%s»: sus rutas y anotaciones pasaron a General', c.nombre));
end;
$$;

-- ============ 7. REPORTES (auditoria.sql + guarda del dueño) ============
create or replace function pr_resolver_reporte(p_reporte uuid, p_quien uuid)
returns jsonb language plpgsql security definer as $$
declare
  q usuarios;
  rep reportes;
  a usuarios;
  v_tipo text;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into rep from reportes where id = p_reporte;
  if rep.id is null then raise exception 'Ese reporte no existe'; end if;
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  if not (q.rol in ('empresa','coordinador') and q.empresa_id = rep.empresa_id) then
    raise exception 'No tienes permiso para resolver este reporte';
  end if;
  if rep.estado = 'resuelto' then
    raise exception 'Ese reporte ya está resuelto';
  end if;

  update reportes
  set estado = 'resuelto', resuelto_por = p_quien, resuelto_en = now()
  where id = p_reporte
  returning * into rep;
  select * into a from usuarios where id = rep.autor_id;

  v_tipo := case rep.tipo
    when 'calle_cerrada' then 'calle cerrada'
    when 'averia' then 'avería'
    when 'accidente' then 'accidente'
    when 'retraso' then 'retraso'
    when 'seguridad' then 'seguridad'
    else 'otro'
  end;
  perform pr_registrar_accion(rep.empresa_id, p_quien, 'reporte_resuelto',
    format('Marcó como resuelto el reporte de %s de %s: «%s»',
           v_tipo, a.codigo, left(rep.mensaje, 80)));

  return jsonb_build_object(
    'id', rep.id,
    'empresaId', rep.empresa_id,
    'autor', jsonb_build_object('nombre', a.nombre, 'codigo', a.codigo, 'rol', a.rol),
    'esCoordinador', a.rol = 'coordinador',
    'tipo', rep.tipo,
    'mensaje', rep.mensaje,
    'estado', rep.estado,
    'creadaEn', rep.creada_en,
    'resueltoPor', rep.resuelto_por,
    'resueltoEn', rep.resuelto_en
  );
end;
$$;
