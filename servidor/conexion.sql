-- Pago por Rutas — conexión oficial v1 (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql y ANTES de semilla.sql.
--
-- Qué trae (solo lo que esquema.sql no tiene; la lógica de negocio —
-- clases, duplicados, cálculo, vouchers — sigue en las pr_* de esquema.sql):
--   1. Hash seguro de PIN con pgcrypto y helpers pr_hash_pin / pr_verificar_pin.
--   2. pr_iniciar_sesion: inicio de sesión por código + PIN para panel y app.
--   3. Lectura base en una llamada: pr_snapshot, pr_resumen_periodo,
--      pr_voucher_detalle (RLS está activa sin políticas: el cliente no lee
--      tablas directo, todo pasa por funciones security definer).
--   4. CRUD administrativo mínimo que el panel necesita (usuarios, clientes,
--      rutas, opciones, feriados) como funciones pr_*, para que el cliente
--      nunca escriba tablas directo.
--
-- pgcrypto: en Supabase vive en el esquema `extensions` (ya instalado en el
-- proyecto). Los helpers intentan primero extensions.crypt / gen_salt y, si
-- no están ahí, los del esquema visible (p. ej. public en un PG local). En
-- local basta: create schema if not exists extensions;
--              create extension if not exists pgcrypto schema extensions;
create extension if not exists pgcrypto;

-- ============ 1. PIN CON HASH SEGURO (pgcrypto / bcrypt) ============
create or replace function pr_hash_pin(p_pin text) returns text
language plpgsql as $$
declare v text;
begin
  begin
    execute 'select extensions.crypt($1, extensions.gen_salt(''bf'', 8))' into v using p_pin;
  exception when invalid_schema_name or undefined_function or undefined_object then
    execute 'select crypt($1, gen_salt(''bf'', 8))' into v using p_pin;
  end;
  return v;
end;
$$;

create or replace function pr_verificar_pin(p_pin text, p_hash text) returns boolean
language plpgsql stable as $$
declare v boolean;
begin
  if p_pin is null or p_hash is null then return false; end if;
  begin
    execute 'select extensions.crypt($1, $2) = $2' into v using p_pin, p_hash;
  exception when invalid_schema_name or undefined_function or undefined_object then
    execute 'select crypt($1, $2) = $2' into v using p_pin, p_hash;
  end;
  return coalesce(v, false);
end;
$$;

-- ============ 2. INICIO DE SESIÓN (panel y app) ============
-- Localiza al usuario por código (sin importar mayúsculas). Los códigos son
-- únicos por empresa; si el mismo código + PIN existiera en dos empresas, la
-- sesión se rechaza por ambigua en vez de adivinar. Devuelve usuario,
-- empresa, rol, opciones de la empresa y estado de la licencia en un JSON.
-- Si la empresa está inactiva o su licencia no está vigente, NO hay sesión:
-- se lanza un error con mensaje claro para mostrar en pantalla.
create or replace function pr_iniciar_sesion(p_codigo text, p_pin text)
returns jsonb language plpgsql security definer as $$
declare
  candidatos int := 0;
  u usuarios;
  e empresas;
  lic licencias;
  o opciones_empresa;
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

  -- Superadmin (Miguel): sin empresa ni licencia; entra como dueño del sistema.
  if u.empresa_id is null then
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

  select * into o from opciones_empresa where empresa_id = e.id;

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
      'limiteAnotacion', o.limite_anotacion
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

-- ============ 3. LECTURA BASE EN UNA LLAMADA ============
-- Foto completa que el panel necesita para pintar, con las claves ya en el
-- formato del panel (camelCase). Si p_empresa es null (sesión superadmin),
-- se usa la primera empresa creada.
create or replace function pr_snapshot(p_empresa uuid default null)
returns jsonb language plpgsql security definer as $$
declare
  emp uuid := p_empresa;
  e empresas;
  o opciones_empresa;
begin
  if emp is null then
    select id into emp from empresas order by creada_en limit 1;
  end if;
  select * into e from empresas where id = emp;
  if e.id is null then raise exception 'Empresa no encontrada'; end if;
  select * into o from opciones_empresa where empresa_id = emp;

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
      'limiteAnotacion', o.limite_anotacion
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

-- Resumen de TODOS los choferes de la empresa en un período (para Pagos).
-- No duplica lógica: llama a pr_resumen_chofer por cada chofer.
create or replace function pr_resumen_periodo(p_empresa uuid, p_desde date, p_hasta date)
returns table (chofer_id uuid, num_empresa int, num_extra int,
               total_empresa numeric, total_extra numeric, total numeric)
language sql stable security definer as $$
  select u.id, r.num_empresa, r.num_extra, r.total_empresa, r.total_extra, r.total
  from usuarios u
  cross join lateral pr_resumen_chofer(p_empresa, u.id, p_desde, p_hasta) r
  where u.empresa_id = p_empresa and u.rol = 'chofer'
  order by u.nombre;
$$;

-- Detalle de un voucher ya generado (para mostrarlo/imprimirlo tras crearlo).
create or replace function pr_voucher_detalle(p_voucher uuid)
returns table (fecha date, descripcion text, cliente text, clase text, precio numeric)
language sql stable security definer as $$
  select d.fecha, d.descripcion, d.cliente, d.clase, d.precio
  from voucher_detalle d
  where d.voucher_id = p_voucher
  order by d.fecha;
$$;

-- ============ 4. CRUD ADMINISTRATIVO DEL PANEL ============
-- Usuarios: el PIN nace como 1234 (hash) salvo que se pase otro; se cambia
-- luego desde la app/panel. No se puede crear un superadmin desde el panel.
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
  return nuevo;
end;
$$;

create or replace function pr_cambiar_activo_usuario(p_usuario uuid, p_activo boolean)
returns void language plpgsql security definer as $$
begin
  update usuarios set activo = p_activo where id = p_usuario;
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
  return nuevo;
end;
$$;

create or replace function pr_cambiar_activo_cliente(p_cliente uuid, p_activo boolean)
returns void language plpgsql security definer as $$
begin
  update clientes set activo = p_activo where id = p_cliente;
end;
$$;

create or replace function pr_crear_ruta(p_empresa uuid, p_codigo text, p_nombre text,
                                         p_precio numeric, p_cliente uuid default null)
returns rutas language plpgsql security definer as $$
declare nueva rutas;
begin
  if p_cliente is not null and not exists (
    select 1 from clientes where id = p_cliente and empresa_id = p_empresa
  ) then
    raise exception 'Esa empresa cliente no pertenece a tu empresa';
  end if;
  insert into rutas (empresa_id, cliente_id, codigo, nombre, precio)
  values (p_empresa, p_cliente, trim(p_codigo), trim(p_nombre), p_precio)
  returning * into nueva;
  return nueva;
end;
$$;

create or replace function pr_actualizar_ruta(p_ruta uuid, p_nombre text, p_precio numeric,
                                              p_cliente uuid default null)
returns void language plpgsql security definer as $$
declare r rutas;
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
end;
$$;

create or replace function pr_cambiar_activa_ruta(p_ruta uuid, p_activa boolean)
returns void language plpgsql security definer as $$
begin
  update rutas set activa = p_activa where id = p_ruta;
end;
$$;

-- Opciones: p_cambios es un JSON con las claves del panel (camelCase); solo
-- se tocan las claves presentes. rutasEmpresaPorDia acepta null explícito
-- (= todas las rutas del día son de la empresa, salvo días extra).
create or replace function pr_actualizar_opciones(p_empresa uuid, p_cambios jsonb)
returns opciones_empresa language plpgsql security definer as $$
declare o opciones_empresa;
begin
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
    limite_anotacion = coalesce(p_cambios ->> 'limiteAnotacion', limite_anotacion)
  where empresa_id = p_empresa
  returning * into o;
  if o.empresa_id is null then
    raise exception 'Esta empresa no tiene opciones registradas';
  end if;
  return o;
end;
$$;

create or replace function pr_agregar_feriado(p_empresa uuid, p_fecha date, p_nombre text default null)
returns void language plpgsql security definer as $$
begin
  insert into feriados (empresa_id, fecha, nombre) values (p_empresa, p_fecha, p_nombre)
  on conflict (empresa_id, fecha) do nothing;
end;
$$;

create or replace function pr_quitar_feriado(p_empresa uuid, p_fecha date)
returns void language plpgsql security definer as $$
begin
  delete from feriados where empresa_id = p_empresa and fecha = p_fecha;
end;
$$;
