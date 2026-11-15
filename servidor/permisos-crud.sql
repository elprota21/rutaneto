-- Pago por Rutas — permisos del dueño en el CRUD del panel (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + semilla.sql +
-- app-datos.sql + ajustes-2026-11-15.sql + acceso-roles.sql +
-- auditoria.sql + caducidad.sql + permisos-dueno.sql.
-- No reescribe aquellos archivos: todo va con drop puntual de firma
-- + create or replace, así que correrlo de nuevo no rompe nada.
--
-- Extensión de la regla de Miguel (2026-11-15): «que no se me permita
-- aprobar o editar NADA de lo de ese panel». En permisos-dueno.sql
-- quedó documentado que el CRUD del panel y pr_actualizar_opciones
-- NO recibían actor, así que el servidor no podía rechazar ahí al
-- superadmin. Este archivo cierra ese hueco igual que se hizo con
-- pr_generar_voucher:
--
--   A cada función de mutación del panel que no recibía actor se le
--   añade el parámetro opcional `p_quien uuid default null` AL FINAL
--   de la firma. Se elimina la firma anterior (y la nueva, por
--   idempotencia) para que quede UNA sola versión de cada función,
--   sin sobrecargas ambiguas para PostgREST; las llamadas sin
--   p_quien siguen funcionando por el default (compatibilidad con
--   los paneles ya desplegados).
--
--   Si p_quien viene, la PRIMERA validación es
--   pr_exigir_no_dueno(p_quien) — el ayudante de permisos-dueno.sql,
--   con su mensaje exacto: «El dueño de RutaNeto no opera dentro de
--   la empresa: esto lo hace la administración de la empresa.»
--   (Con p_quien null el ayudante no hace nada.)
--
--   Y cuando la función ya dejaba fila de auditoría sin actor
--   (usuario_creado/editado, cliente_creado/editado,
--   ruta_creada/editada, feriado_agregado/borrado,
--   opciones_cambiadas), la fila ahora lleva ese actor.
--
-- Funciones tocadas (10):
--   pr_crear_usuario, pr_cambiar_activo_usuario,
--   pr_crear_cliente, pr_cambiar_activo_cliente,
--   pr_crear_ruta, pr_actualizar_ruta, pr_cambiar_activa_ruta,
--   pr_agregar_feriado, pr_quitar_feriado,
--   pr_actualizar_opciones.
-- Los cuerpos son copia fiel de los vigentes en auditoria.sql.

-- ============ 1. USUARIOS (auditoria.sql + p_quien opcional) ============
drop function if exists pr_crear_usuario(uuid, text, text, text, text);
drop function if exists pr_crear_usuario(uuid, text, text, text, text, uuid);
create or replace function pr_crear_usuario(p_empresa uuid, p_nombre text, p_codigo text,
                                            p_rol text, p_pin text default '1234',
                                            p_quien uuid default null)
returns usuarios language plpgsql security definer as $$
declare
  nuevo usuarios;
  lic licencias;
  ya int;
begin
  perform pr_exigir_no_dueno(p_quien);
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
  perform pr_registrar_accion(p_empresa, p_quien, 'usuario_creado',
    format('Se creó el usuario %s (%s, %s)', nuevo.codigo, nuevo.nombre, nuevo.rol));
  return nuevo;
end;
$$;

drop function if exists pr_cambiar_activo_usuario(uuid, boolean);
drop function if exists pr_cambiar_activo_usuario(uuid, boolean, uuid);
create or replace function pr_cambiar_activo_usuario(p_usuario uuid, p_activo boolean,
                                                     p_quien uuid default null)
returns void language plpgsql security definer as $$
declare u usuarios;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into u from usuarios where id = p_usuario;
  update usuarios set activo = p_activo where id = p_usuario;
  if u.id is not null then
    perform pr_registrar_accion(u.empresa_id, p_quien, 'usuario_editado',
      format('%s al usuario %s (%s)', case when p_activo then 'Se activó' else 'Se desactivó' end,
             u.codigo, u.nombre));
  end if;
end;
$$;

-- ============ 2. EMPRESAS CLIENTE (auditoria.sql + p_quien opcional) ============
drop function if exists pr_crear_cliente(uuid, text);
drop function if exists pr_crear_cliente(uuid, text, uuid);
create or replace function pr_crear_cliente(p_empresa uuid, p_nombre text,
                                            p_quien uuid default null)
returns clientes language plpgsql security definer as $$
declare nuevo clientes;
begin
  perform pr_exigir_no_dueno(p_quien);
  if exists (select 1 from clientes where empresa_id = p_empresa and lower(nombre) = lower(trim(p_nombre))) then
    raise exception 'Ya existe una empresa cliente con el nombre %', p_nombre;
  end if;
  insert into clientes (empresa_id, nombre) values (p_empresa, trim(p_nombre))
  returning * into nuevo;
  perform pr_registrar_accion(p_empresa, p_quien, 'cliente_creado',
    format('Se creó la empresa cliente «%s»', nuevo.nombre));
  return nuevo;
end;
$$;

drop function if exists pr_cambiar_activo_cliente(uuid, boolean);
drop function if exists pr_cambiar_activo_cliente(uuid, boolean, uuid);
create or replace function pr_cambiar_activo_cliente(p_cliente uuid, p_activo boolean,
                                                     p_quien uuid default null)
returns void language plpgsql security definer as $$
declare c clientes;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into c from clientes where id = p_cliente;
  update clientes set activo = p_activo where id = p_cliente;
  if c.id is not null then
    perform pr_registrar_accion(c.empresa_id, p_quien, 'cliente_editado',
      format('%s la empresa cliente «%s»', case when p_activo then 'Se activó' else 'Se desactivó' end,
             c.nombre));
  end if;
end;
$$;

-- ============ 3. RUTAS (auditoria.sql + p_quien opcional) ============
drop function if exists pr_crear_ruta(uuid, text, text, numeric, uuid);
drop function if exists pr_crear_ruta(uuid, text, text, numeric, uuid, uuid);
create or replace function pr_crear_ruta(p_empresa uuid, p_codigo text, p_nombre text,
                                         p_precio numeric, p_cliente uuid default null,
                                         p_quien uuid default null)
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
  insert into rutas (empresa_id, cliente_id, codigo, nombre, precio)
  values (p_empresa, p_cliente, trim(p_codigo), trim(p_nombre), p_precio)
  returning * into nueva;
  select * into cli from clientes where id = nueva.cliente_id;
  perform pr_registrar_accion(p_empresa, p_quien, 'ruta_creada',
    format('Se creó la ruta %s «%s» con precio RD$%s (cliente: %s)',
           nueva.codigo, nueva.nombre, to_char(nueva.precio, 'FM999,999,990.00'),
           coalesce(cli.nombre, 'General')));
  return nueva;
end;
$$;

drop function if exists pr_actualizar_ruta(uuid, text, numeric, uuid);
drop function if exists pr_actualizar_ruta(uuid, text, numeric, uuid, uuid);
create or replace function pr_actualizar_ruta(p_ruta uuid, p_nombre text, p_precio numeric,
                                              p_cliente uuid default null,
                                              p_quien uuid default null)
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
  update rutas set nombre = trim(p_nombre), precio = p_precio, cliente_id = p_cliente
  where id = p_ruta;
  select * into cli from clientes where id = p_cliente;
  perform pr_registrar_accion(r.empresa_id, p_quien, 'ruta_editada',
    format('Se editó la ruta %s: nombre «%s», precio RD$%s, cliente: %s',
           r.codigo, trim(p_nombre), to_char(p_precio, 'FM999,999,990.00'),
           coalesce(cli.nombre, 'General')));
end;
$$;

drop function if exists pr_cambiar_activa_ruta(uuid, boolean);
drop function if exists pr_cambiar_activa_ruta(uuid, boolean, uuid);
create or replace function pr_cambiar_activa_ruta(p_ruta uuid, p_activa boolean,
                                                  p_quien uuid default null)
returns void language plpgsql security definer as $$
declare r rutas;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into r from rutas where id = p_ruta;
  update rutas set activa = p_activa where id = p_ruta;
  if r.id is not null then
    perform pr_registrar_accion(r.empresa_id, p_quien, 'ruta_editada',
      format('%s la ruta %s «%s»', case when p_activa then 'Se activó' else 'Se desactivó' end,
             r.codigo, r.nombre));
  end if;
end;
$$;

-- ============ 4. FERIADOS (auditoria.sql + p_quien opcional) ============
drop function if exists pr_agregar_feriado(uuid, date, text);
drop function if exists pr_agregar_feriado(uuid, date, text, uuid);
create or replace function pr_agregar_feriado(p_empresa uuid, p_fecha date, p_nombre text default null,
                                              p_quien uuid default null)
returns void language plpgsql security definer as $$
declare n int;
begin
  perform pr_exigir_no_dueno(p_quien);
  insert into feriados (empresa_id, fecha, nombre) values (p_empresa, p_fecha, p_nombre)
  on conflict (empresa_id, fecha) do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    perform pr_registrar_accion(p_empresa, p_quien, 'feriado_agregado',
      format('Se agregó el feriado del %s%s', to_char(p_fecha, 'DD/MM/YYYY'),
             case when p_nombre is not null then format(' («%s»)', p_nombre) else '' end));
  end if;
end;
$$;

drop function if exists pr_quitar_feriado(uuid, date);
drop function if exists pr_quitar_feriado(uuid, date, uuid);
create or replace function pr_quitar_feriado(p_empresa uuid, p_fecha date,
                                             p_quien uuid default null)
returns void language plpgsql security definer as $$
declare
  f feriados;
  n int;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into f from feriados where empresa_id = p_empresa and fecha = p_fecha;
  delete from feriados where empresa_id = p_empresa and fecha = p_fecha;
  get diagnostics n = row_count;
  if n > 0 then
    perform pr_registrar_accion(p_empresa, p_quien, 'feriado_borrado',
      format('Se quitó el feriado del %s%s', to_char(p_fecha, 'DD/MM/YYYY'),
             case when f.nombre is not null then format(' («%s»)', f.nombre) else '' end));
  end if;
end;
$$;

-- ============ 5. OPCIONES (auditoria.sql + p_quien opcional) ============
drop function if exists pr_actualizar_opciones(uuid, jsonb);
drop function if exists pr_actualizar_opciones(uuid, jsonb, uuid);
create or replace function pr_actualizar_opciones(p_empresa uuid, p_cambios jsonb,
                                                  p_quien uuid default null)
returns opciones_empresa language plpgsql security definer as $$
declare
  o opciones_empresa;
  claves text;
begin
  perform pr_exigir_no_dueno(p_quien);
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
  perform pr_registrar_accion(p_empresa, p_quien, 'opciones_cambiadas',
    case when claves is null then 'Se actualizaron las opciones de la empresa'
         else format('Se actualizaron las opciones de la empresa (%s)', claves) end);
  return o;
end;
$$;
