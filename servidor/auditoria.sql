-- Pago por Rutas — registro de auditoría (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + semilla.sql +
-- app-datos.sql + ajustes-2026-11-15.sql + acceso-roles.sql.
-- No reescribe aquellos archivos: todo va con create or replace /
-- if not exists, así que correrlo de nuevo no rompe nada.
--
-- Pedido de Miguel (2026-11-15): «que el sistema lleve un registro de
-- cada cosa que haga cada administrador, así se evitan confusiones».
--
-- Qué trae:
--   1. Tabla registro_acciones: una fila por acción, con la FOTO del
--      actor en el momento de la acción (código, nombre y rol), la
--      empresa afectada y un detalle legible en español.
--   2. pr_registrar_accion: ayudante interno que deja la fila. NUNCA
--      tumba la operación principal: cualquier fallo de la auditoría
--      se traga en su bloque de excepción.
--   3. Las funciones de negocio y de administración recreadas igual que
--      su versión vigente, añadiendo la llamada al registro:
--      conflictos, especiales, vouchers, clientes, reportes, PIN,
--      CRUD del panel (usuarios/clientes/rutas/opciones/feriados),
--      pr_admin_* e inicios de sesión concedidos.
--   4. Lectura: pr_registro_empresa (el administrador de la empresa o
--      el superadmin) y pr_admin_registro (solo superadmin, todas las
--      empresas o una filtrada).
--
-- Nota sobre el actor: las funciones cuya firma recibe quién actúa
-- (p_quien, p_coordinador, p_usuario, el propio login) guardan al actor
-- completo. El CRUD del panel de conexion.sql y pr_generar_voucher NO
-- reciben actor en su firma (y la firma no cambia, por compatibilidad
-- con el panel ya desplegado): esas filas llevan la empresa y el
-- detalle, con el actor en null.
-- NINGÚN detalle guarda valores de PIN, jamás.

-- ============ 1. TABLA DE REGISTRO ============
create table if not exists registro_acciones (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid references empresas(id) on delete cascade,
  -- actor_id con set null al borrar el usuario: el rastro NO se pierde
  -- porque la foto (código/nombre/rol) queda guardada en la fila.
  actor_id uuid references usuarios(id) on delete set null,
  actor_codigo text,
  actor_nombre text,
  actor_rol text,
  accion text not null,
  detalle text not null,
  creada_en timestamptz not null default now()
);
-- RLS activa como el resto: el acceso real pasa por las funciones pr_*.
alter table registro_acciones enable row level security;
create index if not exists idx_registro_empresa_fecha
  on registro_acciones(empresa_id, creada_en desc);

-- ============ 2. AYUDANTE INTERNO ============
-- Deja la fila del registro con la foto del actor. Si el actor es null
-- o no existe, la fila queda sin actor (nunca se inventa uno). Si algo
-- falla, la excepción se traga: la auditoría jamás rompe el negocio.
create or replace function pr_registrar_accion(p_empresa uuid, p_actor uuid,
                                               p_accion text, p_detalle text)
returns void language plpgsql security definer as $$
declare u usuarios;
begin
  begin
    if p_actor is not null then
      select * into u from usuarios where id = p_actor;
    end if;
    insert into registro_acciones
      (empresa_id, actor_id, actor_codigo, actor_nombre, actor_rol, accion, detalle)
    values
      (p_empresa,
       case when u.id is null then null else u.id end,
       u.codigo, u.nombre, u.rol,
       p_accion, p_detalle);
  exception when others then
    null; -- la auditoría nunca tumba la acción de negocio
  end;
end;
$$;

-- ============ 3. CONFLICTOS (esquema.sql, instrumentada) ============
drop function if exists pr_resolver_conflicto(uuid, uuid);
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

-- ============ 4. RUTAS ESPECIALES (esquema.sql, instrumentada) ============
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

-- ============ 5. VOUCHERS (esquema.sql, instrumentada) ============
-- La firma no recibe quién lo genera: la fila lleva la empresa y el
-- detalle (chofer, folio, período y total), con el actor en null.
create or replace function pr_generar_voucher(p_empresa uuid, p_chofer uuid, p_desde date, p_hasta date)
returns vouchers language plpgsql security definer as $$
declare
  res record;
  v vouchers;
  nuevo_folio int;
  chof usuarios;
begin
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
  perform pr_registrar_accion(p_empresa, null, 'voucher_generado',
    format('Se generó el voucher #%s para %s (%s) del %s al %s por RD$%s',
           v.folio, chof.codigo, chof.nombre,
           to_char(v.desde, 'DD/MM/YYYY'), to_char(v.hasta, 'DD/MM/YYYY'),
           to_char(v.total, 'FM999,999,990.00')));
  return v;
end;
$$;

-- ============ 6. CRUD DEL PANEL (conexion.sql, instrumentado) ============
-- Estas firmas tampoco reciben actor: filas con empresa y detalle.
create or replace function pr_crear_usuario(p_empresa uuid, p_nombre text, p_codigo text,
                                            p_rol text, p_pin text default '1234')
returns usuarios language plpgsql security definer as $$
declare
  nuevo usuarios;
  lic licencias;
  ya int;
begin
  if p_rol not in ('empresa','coordinador','chofer') then
    raise exception 'Rol no válido para el panel: %', p_rol;
  end if;
  if exists (select 1 from usuarios where empresa_id = p_empresa and upper(codigo) = upper(trim(p_codigo))) then
    raise exception 'Ya existe un usuario con el código %', p_codigo;
  end if;
  if p_rol = 'chofer' then
    select * into lic from licencias where empresa_id = p_empresa order by creada_en desc limit 1;
    if lic.max_choferes is not null then
      select count(*) into ya from usuarios
      where empresa_id = p_empresa and rol = 'chofer' and activo;
      if ya >= lic.max_choferes then
        raise exception 'Tu licencia permite hasta % choferes. Contacta a RutaNeto para ampliarla.', lic.max_choferes;
      end if;
    end if;
  end if;
  insert into usuarios (empresa_id, rol, nombre, codigo, pin_hash)
  values (p_empresa, p_rol, trim(p_nombre), trim(p_codigo), pr_hash_pin(p_pin))
  returning * into nuevo;
  perform pr_registrar_accion(p_empresa, null, 'usuario_creado',
    format('Se creó el usuario %s (%s, %s)', nuevo.codigo, nuevo.nombre, nuevo.rol));
  return nuevo;
end;
$$;

create or replace function pr_cambiar_activo_usuario(p_usuario uuid, p_activo boolean)
returns void language plpgsql security definer as $$
declare u usuarios;
begin
  select * into u from usuarios where id = p_usuario;
  update usuarios set activo = p_activo where id = p_usuario;
  if u.id is not null then
    perform pr_registrar_accion(u.empresa_id, null, 'usuario_editado',
      format('%s al usuario %s (%s)', case when p_activo then 'Se activó' else 'Se desactivó' end,
             u.codigo, u.nombre));
  end if;
end;
$$;

create or replace function pr_crear_cliente(p_empresa uuid, p_nombre text)
returns clientes language plpgsql security definer as $$
declare nuevo clientes;
begin
  if exists (select 1 from clientes where empresa_id = p_empresa and lower(nombre) = lower(trim(p_nombre))) then
    raise exception 'Ya existe una empresa cliente con el nombre %', p_nombre;
  end if;
  insert into clientes (empresa_id, nombre) values (p_empresa, trim(p_nombre))
  returning * into nuevo;
  perform pr_registrar_accion(p_empresa, null, 'cliente_creado',
    format('Se creó la empresa cliente «%s»', nuevo.nombre));
  return nuevo;
end;
$$;

create or replace function pr_cambiar_activo_cliente(p_cliente uuid, p_activo boolean)
returns void language plpgsql security definer as $$
declare c clientes;
begin
  select * into c from clientes where id = p_cliente;
  update clientes set activo = p_activo where id = p_cliente;
  if c.id is not null then
    perform pr_registrar_accion(c.empresa_id, null, 'cliente_editado',
      format('%s la empresa cliente «%s»', case when p_activo then 'Se activó' else 'Se desactivó' end,
             c.nombre));
  end if;
end;
$$;

create or replace function pr_crear_ruta(p_empresa uuid, p_codigo text, p_nombre text,
                                         p_precio numeric, p_cliente uuid default null)
returns rutas language plpgsql security definer as $$
declare
  nueva rutas;
  cli clientes;
begin
  if p_cliente is not null and not exists (
    select 1 from clientes where id = p_cliente and empresa_id = p_empresa
  ) then
    raise exception 'Esa empresa cliente no pertenece a tu empresa';
  end if;
  insert into rutas (empresa_id, cliente_id, codigo, nombre, precio)
  values (p_empresa, p_cliente, trim(p_codigo), trim(p_nombre), p_precio)
  returning * into nueva;
  select * into cli from clientes where id = nueva.cliente_id;
  perform pr_registrar_accion(p_empresa, null, 'ruta_creada',
    format('Se creó la ruta %s «%s» con precio RD$%s (cliente: %s)',
           nueva.codigo, nueva.nombre, to_char(nueva.precio, 'FM999,999,990.00'),
           coalesce(cli.nombre, 'General')));
  return nueva;
end;
$$;

create or replace function pr_actualizar_ruta(p_ruta uuid, p_nombre text, p_precio numeric,
                                              p_cliente uuid default null)
returns void language plpgsql security definer as $$
declare
  r rutas;
  cli clientes;
begin
  select * into r from rutas where id = p_ruta;
  if r.id is null then raise exception 'Ruta no encontrada'; end if;
  if p_cliente is not null and not exists (
    select 1 from clientes where id = p_cliente and empresa_id = r.empresa_id
  ) then
    raise exception 'Esa empresa cliente no pertenece a tu empresa';
  end if;
  update rutas set nombre = trim(p_nombre), precio = p_precio, cliente_id = p_cliente
  where id = p_ruta;
  select * into cli from clientes where id = p_cliente;
  perform pr_registrar_accion(r.empresa_id, null, 'ruta_editada',
    format('Se editó la ruta %s: nombre «%s», precio RD$%s, cliente: %s',
           r.codigo, trim(p_nombre), to_char(p_precio, 'FM999,999,990.00'),
           coalesce(cli.nombre, 'General')));
end;
$$;

create or replace function pr_cambiar_activa_ruta(p_ruta uuid, p_activa boolean)
returns void language plpgsql security definer as $$
declare r rutas;
begin
  select * into r from rutas where id = p_ruta;
  update rutas set activa = p_activa where id = p_ruta;
  if r.id is not null then
    perform pr_registrar_accion(r.empresa_id, null, 'ruta_editada',
      format('%s la ruta %s «%s»', case when p_activa then 'Se activó' else 'Se desactivó' end,
             r.codigo, r.nombre));
  end if;
end;
$$;

create or replace function pr_agregar_feriado(p_empresa uuid, p_fecha date, p_nombre text default null)
returns void language plpgsql security definer as $$
declare n int;
begin
  insert into feriados (empresa_id, fecha, nombre) values (p_empresa, p_fecha, p_nombre)
  on conflict (empresa_id, fecha) do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    perform pr_registrar_accion(p_empresa, null, 'feriado_agregado',
      format('Se agregó el feriado del %s%s', to_char(p_fecha, 'DD/MM/YYYY'),
             case when p_nombre is not null then format(' («%s»)', p_nombre) else '' end));
  end if;
end;
$$;

create or replace function pr_quitar_feriado(p_empresa uuid, p_fecha date)
returns void language plpgsql security definer as $$
declare
  f feriados;
  n int;
begin
  select * into f from feriados where empresa_id = p_empresa and fecha = p_fecha;
  delete from feriados where empresa_id = p_empresa and fecha = p_fecha;
  get diagnostics n = row_count;
  if n > 0 then
    perform pr_registrar_accion(p_empresa, null, 'feriado_borrado',
      format('Se quitó el feriado del %s%s', to_char(p_fecha, 'DD/MM/YYYY'),
             case when f.nombre is not null then format(' («%s»)', f.nombre) else '' end));
  end if;
end;
$$;

-- ============ 7. OPCIONES (versión de ajustes, instrumentada) ============
create or replace function pr_actualizar_opciones(p_empresa uuid, p_cambios jsonb)
returns opciones_empresa language plpgsql security definer as $$
declare
  o opciones_empresa;
  claves text;
begin
  if p_cambios ? 'diasParaAnotar' and p_cambios ->> 'diasParaAnotar' is not null
     and (p_cambios ->> 'diasParaAnotar')::int not between 0 and 30 then
    raise exception 'Los días para anotar deben estar entre 0 y 30';
  end if;
  update opciones_empresa set
    ver_ganado = coalesce(p_cambios ->> 'verGanado', ver_ganado),
    voucher_app = coalesce((p_cambios ->> 'voucherApp')::boolean, voucher_app),
    boton_especial = coalesce((p_cambios ->> 'botonEspecial')::boolean, boton_especial),
    rutas_empresa_por_dia = case
      when p_cambios ? 'rutasEmpresaPorDia' then (p_cambios ->> 'rutasEmpresaPorDia')::int
      else rutas_empresa_por_dia end,
    sabado_extra = coalesce((p_cambios ->> 'sabadoExtra')::boolean, sabado_extra),
    domingo_extra = coalesce((p_cambios ->> 'domingoExtra')::boolean, domingo_extra),
    feriado_extra = coalesce((p_cambios ->> 'feriadoExtra')::boolean, feriado_extra),
    limite_anotacion = coalesce(p_cambios ->> 'limiteAnotacion', limite_anotacion),
    dias_para_anotar = coalesce((p_cambios ->> 'diasParaAnotar')::int, dias_para_anotar)
  where empresa_id = p_empresa
  returning * into o;
  if o.empresa_id is null then
    raise exception 'Esta empresa no tiene opciones registradas';
  end if;
  select string_agg(k, ', ') into claves from jsonb_object_keys(p_cambios) as k;
  perform pr_registrar_accion(p_empresa, null, 'opciones_cambiadas',
    case when claves is null then 'Se actualizaron las opciones de la empresa'
         else format('Se actualizaron las opciones de la empresa (%s)', claves) end);
  return o;
end;
$$;

-- ============ 8. BORRAR CLIENTE (ajustes, instrumentada) ============
create or replace function pr_borrar_cliente(p_cliente uuid, p_quien uuid)
returns void language plpgsql security definer as $$
declare
  q usuarios;
  c clientes;
begin
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  if q.rol not in ('empresa','superadmin') then
    raise exception 'Solo un administrador puede borrar empresas cliente';
  end if;
  select * into c from clientes where id = p_cliente;
  if c.id is null then raise exception 'Esa empresa cliente no existe'; end if;
  if q.rol = 'empresa' and c.empresa_id <> q.empresa_id then
    raise exception 'Esa empresa cliente no pertenece a tu empresa';
  end if;
  delete from clientes where id = p_cliente;
  perform pr_registrar_accion(c.empresa_id, p_quien, 'cliente_borrado',
    format('Borró la empresa cliente «%s»: sus rutas y anotaciones pasaron a General', c.nombre));
end;
$$;

-- ============ 9. REPORTES (ajustes, instrumentada) ============
create or replace function pr_resolver_reporte(p_reporte uuid, p_quien uuid)
returns jsonb language plpgsql security definer as $$
declare
  q usuarios;
  rep reportes;
  a usuarios;
  v_tipo text;
begin
  select * into rep from reportes where id = p_reporte;
  if rep.id is null then raise exception 'Ese reporte no existe'; end if;
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  if q.rol = 'superadmin' then
    null;
  elsif q.rol in ('empresa','coordinador') and q.empresa_id = rep.empresa_id then
    null;
  else
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

-- ============ 10. CAMBIO DE PIN (ajustes, instrumentado) ============
-- El detalle jamás incluye el PIN, ni el viejo ni el nuevo.
create or replace function pr_cambiar_pin(p_usuario uuid, p_pin_actual text,
                                          p_pin_nuevo text)
returns boolean language plpgsql security definer as $$
declare u usuarios;
begin
  select * into u from usuarios where id = p_usuario;
  if u.id is null then raise exception 'Usuario no encontrado'; end if;
  if not pr_verificar_pin(p_pin_actual, u.pin_hash) then
    raise exception 'El PIN actual no es correcto';
  end if;
  if p_pin_nuevo is null or length(p_pin_nuevo) < 4 then
    raise exception 'El PIN nuevo debe tener al menos 4 caracteres';
  end if;
  update usuarios set pin_hash = pr_hash_pin(p_pin_nuevo) where id = p_usuario;
  perform pr_registrar_accion(u.empresa_id, p_usuario, 'pin_cambiado',
    'Cambió su PIN de acceso');
  return true;
end;
$$;

-- ============ 11. PANEL DE ADMINISTRADOR (ajustes, instrumentado) ============
create or replace function pr_admin_crear_empresa(p_quien uuid, p_nombre text,
                                                  p_max_choferes int, p_meses int,
                                                  p_admin_codigo text, p_admin_pin text,
                                                  p_admin_nombre text)
returns jsonb language plpgsql security definer as $$
declare
  e empresas;
  lic licencias;
  adm usuarios;
begin
  perform pr_exigir_superadmin(p_quien);
  if exists (select 1 from empresas where lower(nombre) = lower(trim(p_nombre))) then
    raise exception 'Ya existe una empresa con el nombre %', p_nombre;
  end if;
  if exists (select 1 from usuarios
             where rol = 'empresa' and upper(codigo) = upper(trim(p_admin_codigo))) then
    raise exception 'Ya existe un administrador con el código %', p_admin_codigo;
  end if;
  if p_admin_pin is null or length(p_admin_pin) < 4 then
    raise exception 'El PIN del administrador debe tener al menos 4 caracteres';
  end if;

  insert into empresas (nombre) values (trim(p_nombre)) returning * into e;
  insert into licencias (empresa_id, estado, vence, max_choferes)
  values (e.id, 'activa', (current_date + (p_meses || ' months')::interval)::date, p_max_choferes)
  returning * into lic;
  insert into opciones_empresa (empresa_id, ver_ganado, voucher_app, boton_especial,
    rutas_empresa_por_dia, dias_para_anotar, sabado_extra, domingo_extra,
    feriado_extra, limite_anotacion)
  values (e.id, 'todo', true, true, 5, 1, false, false, false, 'hoy_y_ayer');
  insert into usuarios (empresa_id, rol, nombre, codigo, pin_hash)
  values (e.id, 'empresa', trim(p_admin_nombre), trim(p_admin_codigo), pr_hash_pin(p_admin_pin))
  returning * into adm;

  perform pr_registrar_accion(e.id, p_quien, 'empresa_creada',
    format('Creó la empresa «%s» (máx. %s choferes, licencia de %s meses) y su administrador %s',
           e.nombre, coalesce(p_max_choferes::text, 'sin tope'), p_meses, adm.codigo));

  return jsonb_build_object(
    'empresa', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'activa', e.activa),
    'licencia', jsonb_build_object('estado', lic.estado, 'vence', lic.vence,
                                   'maxChoferes', lic.max_choferes),
    'admin', jsonb_build_object('id', adm.id, 'codigo', adm.codigo,
                                'nombre', adm.nombre, 'rol', adm.rol)
  );
end;
$$;

create or replace function pr_admin_licencia(p_quien uuid, p_empresa uuid,
                                             p_accion text, p_meses int default null)
returns jsonb language plpgsql security definer as $$
declare
  lic licencias;
  emp empresas;
  v_accion text;
  v_detalle text;
begin
  perform pr_exigir_superadmin(p_quien);
  select * into lic from licencias
  where empresa_id = p_empresa order by creada_en desc limit 1;
  if lic.id is null then raise exception 'Esta empresa no tiene licencia'; end if;
  select * into emp from empresas where id = p_empresa;

  if p_accion = 'activar' then
    update licencias set estado = 'activa' where id = lic.id returning * into lic;
    v_accion := 'licencia_activada';
    v_detalle := format('Activó la licencia de la empresa «%s»', emp.nombre);
  elsif p_accion = 'suspender' then
    update licencias set estado = 'suspendida' where id = lic.id returning * into lic;
    v_accion := 'licencia_suspendida';
    v_detalle := format('Suspendió la licencia de la empresa «%s»', emp.nombre);
  elsif p_accion = 'extender' then
    if p_meses is null or p_meses <= 0 then
      raise exception 'Para extender la licencia indica los meses';
    end if;
    update licencias
    set estado = 'activa',
        vence = (greatest(coalesce(vence, current_date), current_date)
                 + (p_meses || ' months')::interval)::date
    where id = lic.id returning * into lic;
    v_accion := 'licencia_extendida';
    v_detalle := format('Extendió la licencia de la empresa «%s» por %s meses (nuevo vencimiento: %s)',
                        emp.nombre, p_meses, to_char(lic.vence, 'DD/MM/YYYY'));
  else
    raise exception 'Acción no válida: %', p_accion;
  end if;

  perform pr_registrar_accion(p_empresa, p_quien, v_accion, v_detalle);

  return jsonb_build_object('estado', lic.estado, 'vence', lic.vence,
                            'maxChoferes', lic.max_choferes);
end;
$$;

-- El detalle trae la empresa y el código del admin, nunca el PIN.
create or replace function pr_admin_pin_admin(p_quien uuid, p_empresa uuid,
                                              p_pin_nuevo text)
returns text language plpgsql security definer as $$
declare
  adm usuarios;
  emp empresas;
begin
  perform pr_exigir_superadmin(p_quien);
  if p_pin_nuevo is null or length(p_pin_nuevo) < 4 then
    raise exception 'El PIN nuevo debe tener al menos 4 caracteres';
  end if;
  select * into adm from usuarios
  where empresa_id = p_empresa and rol = 'empresa' and activo
  order by codigo limit 1;
  if adm.id is null then
    raise exception 'Esta empresa no tiene usuario administrador';
  end if;
  update usuarios set pin_hash = pr_hash_pin(p_pin_nuevo) where id = adm.id;
  select * into emp from empresas where id = p_empresa;
  perform pr_registrar_accion(p_empresa, p_quien, 'pin_admin_reiniciado',
    format('Reinició el PIN del administrador %s de la empresa «%s»', adm.codigo, emp.nombre));
  return adm.codigo;
end;
$$;

-- ============ 12. INICIO DE SESIÓN (acceso-roles, instrumentado) ============
-- Se registra 'inicio_sesion' SOLO cuando la sesión se concede (los
-- intentos con PIN malo o puerta equivocada levantan excepción antes
-- de llegar al registro). Incluye la puerta cuando viene el contexto.
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
      'ok', true
    )
  );
end;
$$;

-- ============ 13. LECTURA DEL REGISTRO ============
-- El registro de UNA empresa: solo su administrador (rol 'empresa' de
-- esa misma empresa) o el superadmin. Ni choferes ni coordinadores.
create or replace function pr_registro_empresa(p_empresa uuid, p_quien uuid,
                                               p_limite int default 200)
returns jsonb language plpgsql security definer as $$
declare q usuarios;
begin
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  if q.rol = 'superadmin' then
    null;
  elsif q.rol = 'empresa' and q.empresa_id = p_empresa then
    null;
  else
    raise exception 'No tienes permiso para ver el registro de esta empresa';
  end if;

  return coalesce((
    select jsonb_agg(item order by creada_en desc)
    from (
      select jsonb_build_object(
        'id', r.id,
        'actor', jsonb_build_object('nombre', r.actor_nombre, 'codigo', r.actor_codigo, 'rol', r.actor_rol),
        'accion', r.accion,
        'detalle', r.detalle,
        'creadaEn', r.creada_en
      ) as item,
      r.creada_en as creada_en
      from registro_acciones r
      where r.empresa_id = p_empresa
      order by r.creada_en desc
      limit greatest(coalesce(p_limite, 200), 0)
    ) t
  ), '[]'::jsonb);
end;
$$;

-- El registro de TODO el sistema (o de una empresa), solo superadmin.
-- Cada item trae además el nombre de la empresa.
create or replace function pr_admin_registro(p_quien uuid, p_empresa uuid default null,
                                             p_limite int default 200)
returns jsonb language plpgsql security definer as $$
begin
  perform pr_exigir_superadmin(p_quien);

  return coalesce((
    select jsonb_agg(item order by creada_en desc)
    from (
      select jsonb_build_object(
        'id', r.id,
        'empresaId', r.empresa_id,
        'empresa', e.nombre,
        'actor', jsonb_build_object('nombre', r.actor_nombre, 'codigo', r.actor_codigo, 'rol', r.actor_rol),
        'accion', r.accion,
        'detalle', r.detalle,
        'creadaEn', r.creada_en
      ) as item,
      r.creada_en as creada_en
      from registro_acciones r
      left join empresas e on e.id = r.empresa_id
      where p_empresa is null or r.empresa_id = p_empresa
      order by r.creada_en desc
      limit greatest(coalesce(p_limite, 200), 0)
    ) t
  ), '[]'::jsonb);
end;
$$;
