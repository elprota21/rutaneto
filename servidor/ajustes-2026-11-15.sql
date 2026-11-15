-- Pago por Rutas — ajustes 2026-11-15 (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + app-datos.sql.
-- No reescribe aquellos archivos: todo va con create or replace / if not
-- exists, así que correrlo de nuevo no rompe nada.
--
-- Qué trae (pedidos de Miguel, 2026-11-15):
--   1. Plazo de anotación en DÍAS: la empresa elige cuántos días atrás
--      puede anotar el chofer (opciones_empresa.dias_para_anotar).
--   2. pr_borrar_cliente: borrar una empresa cliente, solo administradores.
--   3. Reportes a administración desde la app (tabla reportes +
--      pr_enviar_reporte / pr_listar_reportes / pr_resolver_reporte);
--      los del coordinador se destacan (esCoordinador).
--   4. Panel de administrador de Miguel (superadmin): pr_admin_resumen,
--      pr_admin_crear_empresa, pr_admin_licencia.
--   5. Cambio de PIN: pr_cambiar_pin (cada quien el suyo, con el actual)
--      y pr_admin_pin_admin (el superadmin reinicia el PIN del admin de
--      una empresa que lo olvidó).

-- ============ 1. PLAZO DE ANOTACIÓN EN DÍAS ============
-- 0 = solo hoy; 1 = hoy y ayer; hasta 30. Al agregar la columna se toma el
-- valor según la regla anterior (limite_anotacion): 'hoy' -> 0,
-- 'hoy_y_ayer' -> 1. La semilla de Servivans queda en 1.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_name = 'opciones_empresa'
                   and column_name = 'dias_para_anotar') then
    alter table opciones_empresa
      add column dias_para_anotar int not null default 1;
    update opciones_empresa set dias_para_anotar = 0
    where limite_anotacion = 'hoy';
  end if;
  if not exists (select 1 from pg_constraint
                 where conname = 'opciones_empresa_dias_rango') then
    alter table opciones_empresa
      add constraint opciones_empresa_dias_rango
      check (dias_para_anotar between 0 and 30);
  end if;
end $$;

-- La revisión de plazo ahora se mide en días (la llaman pr_anotar_ruta y
-- pr_anotar_especial). Sin fila de opciones no hay restricción, como antes.
create or replace function pr_revisar_plazo(p_empresa uuid, p_fecha date) returns void
language plpgsql stable as $$
declare o opciones_empresa; n int;
begin
  o := pr_opciones(p_empresa);
  if o.empresa_id is null then return; end if;
  n := coalesce(o.dias_para_anotar, 1);
  if p_fecha > current_date then
    raise exception 'Fuera del plazo: no se puede anotar una fecha futura';
  end if;
  if p_fecha < current_date - n then
    raise exception 'Fuera del plazo: tu empresa permite anotar hasta % día(s) atrás', n;
  end if;
end;
$$;

-- pr_anotar_ruta y pr_anotar_especial se recrean igual que en esquema.sql:
-- el plazo lo sigue revisando pr_revisar_plazo, que ahora trabaja en días.
create or replace function pr_anotar_ruta(p_empresa uuid, p_chofer uuid, p_ruta uuid,
                                          p_fecha date default current_date, p_nota text default null)
returns anotaciones language plpgsql security definer as $$
declare
  r rutas;
  nueva anotaciones;
  duplicada boolean;
begin
  if not pr_licencia_ok(p_empresa) then raise exception 'Licencia inactiva'; end if;
  perform pr_revisar_plazo(p_empresa, p_fecha);
  select * into r from rutas where id = p_ruta and empresa_id = p_empresa and activa;
  if r.id is null then raise exception 'Ruta no existe o esta inactiva'; end if;

  -- Antifraude por empresa + cliente + ruta + fecha: como cada ruta
  -- pertenece a un solo cliente, el cliente de la anotación es el de la ruta.
  duplicada := exists (
    select 1 from anotaciones a
    where a.empresa_id = p_empresa and a.ruta_id = p_ruta and a.fecha = p_fecha
      and a.cliente_id is not distinct from r.cliente_id
      and a.tipo = 'normal' and a.chofer_id <> p_chofer
      and a.estado in ('aprobada','conflicto')
  );

  if duplicada then
    update anotaciones set estado = 'conflicto'
    where empresa_id = p_empresa and ruta_id = p_ruta and fecha = p_fecha
      and cliente_id is not distinct from r.cliente_id
      and tipo = 'normal' and chofer_id <> p_chofer and estado = 'aprobada';
    insert into anotaciones (empresa_id, chofer_id, ruta_id, cliente_id, tipo, nota, fecha, clase, estado, precio_aplicado)
    values (p_empresa, p_chofer, p_ruta, r.cliente_id, 'normal', p_nota, p_fecha,
            pr_clase_del_dia(p_empresa, p_chofer, p_fecha), 'conflicto', r.precio)
    returning * into nueva;
  else
    insert into anotaciones (empresa_id, chofer_id, ruta_id, cliente_id, tipo, nota, fecha, clase, estado, precio_aplicado)
    values (p_empresa, p_chofer, p_ruta, r.cliente_id, 'normal', p_nota, p_fecha,
            pr_clase_del_dia(p_empresa, p_chofer, p_fecha), 'aprobada', r.precio)
    returning * into nueva;
  end if;
  return nueva;
end;
$$;

create or replace function pr_anotar_especial(p_empresa uuid, p_chofer uuid, p_descripcion text,
                                              p_cliente uuid default null,
                                              p_fecha date default current_date, p_nota text default null)
returns anotaciones language plpgsql security definer as $$
declare
  o opciones_empresa;
  nueva anotaciones;
begin
  if not pr_licencia_ok(p_empresa) then raise exception 'Licencia inactiva'; end if;
  o := pr_opciones(p_empresa);
  if o.empresa_id is not null and not o.boton_especial then
    raise exception 'Esta empresa no permite rutas especiales';
  end if;
  if p_cliente is not null and not exists (
    select 1 from clientes where id = p_cliente and empresa_id = p_empresa and activo
  ) then
    raise exception 'Esa empresa cliente no existe o esta inactiva';
  end if;
  perform pr_revisar_plazo(p_empresa, p_fecha);
  insert into anotaciones (empresa_id, chofer_id, cliente_id, tipo, descripcion, nota, fecha, clase, estado, precio_aplicado)
  values (p_empresa, p_chofer, p_cliente, 'especial', p_descripcion, p_nota, p_fecha, 'extra', 'especial_pendiente', null)
  returning * into nueva;
  return nueva;
end;
$$;

-- pr_iniciar_sesion y pr_snapshot (de conexion.sql) ahora incluyen
-- diasParaAnotar en el JSON de opciones.
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
      'limiteAnotacion', o.limite_anotacion,
      'diasParaAnotar', o.dias_para_anotar
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

-- El guardado de opciones del panel acepta también diasParaAnotar (0–30).
create or replace function pr_actualizar_opciones(p_empresa uuid, p_cambios jsonb)
returns opciones_empresa language plpgsql security definer as $$
declare o opciones_empresa;
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
  return o;
end;
$$;

-- ============ 2. BORRAR EMPRESA CLIENTE (solo administradores) ============
-- Solo rol 'empresa' (el administrador de la transportista) o 'superadmin'.
-- El coordinador NO puede. Al borrar, las rutas y anotaciones que
-- referencian al cliente quedan en «General» (FK on delete set null).
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
end;
$$;

-- ============ 3. REPORTES A ADMINISTRACIÓN ============
-- Los choferes y coordinadores reportan desde la app lo que pasa en la
-- ruta (calle cerrada, avería, accidente…). Los del coordinador se
-- destacan en el panel (esCoordinador = true).
create table if not exists reportes (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  autor_id uuid not null references usuarios(id),
  tipo text not null check (tipo in ('calle_cerrada','averia','accidente','retraso','seguridad','otro')),
  mensaje text not null,
  estado text not null default 'nuevo' check (estado in ('nuevo','resuelto')),
  creada_en timestamptz not null default now(),
  resuelto_por uuid references usuarios(id),
  resuelto_en timestamptz
);
alter table reportes enable row level security;
create index if not exists idx_reportes_empresa on reportes(empresa_id, estado, creada_en desc);

create or replace function pr_enviar_reporte(p_empresa uuid, p_autor uuid,
                                             p_tipo text, p_mensaje text)
returns jsonb language plpgsql security definer as $$
declare
  a usuarios;
  rep reportes;
begin
  if p_tipo not in ('calle_cerrada','averia','accidente','retraso','seguridad','otro') then
    raise exception 'Tipo de reporte no válido: %', p_tipo;
  end if;
  if p_mensaje is null or length(trim(p_mensaje)) = 0 then
    raise exception 'El reporte necesita un mensaje';
  end if;
  select * into a from usuarios
  where id = p_autor and empresa_id = p_empresa and activo;
  if a.id is null then
    raise exception 'El autor no es un usuario activo de esta empresa';
  end if;
  if a.rol not in ('chofer','coordinador') then
    raise exception 'Solo choferes y coordinadores pueden enviar reportes';
  end if;
  if not pr_licencia_ok(p_empresa) then raise exception 'Licencia inactiva'; end if;

  insert into reportes (empresa_id, autor_id, tipo, mensaje)
  values (p_empresa, p_autor, p_tipo, trim(p_mensaje))
  returning * into rep;

  return jsonb_build_object(
    'id', rep.id,
    'empresaId', rep.empresa_id,
    'autor', jsonb_build_object('id', a.id, 'nombre', a.nombre, 'codigo', a.codigo, 'rol', a.rol),
    'esCoordinador', a.rol = 'coordinador',
    'tipo', rep.tipo,
    'mensaje', rep.mensaje,
    'estado', rep.estado,
    'creadaEn', rep.creada_en
  );
end;
$$;

-- Lista para el panel: primero los nuevos (con los del coordinador por
-- delante) y luego por fecha descendente.
create or replace function pr_listar_reportes(p_empresa uuid, p_quien uuid)
returns jsonb language plpgsql security definer as $$
declare q usuarios;
begin
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  if q.rol = 'superadmin' then
    null; -- el superadmin puede ver los reportes de cualquier empresa
  elsif q.rol in ('empresa','coordinador') and q.empresa_id = p_empresa then
    null;
  else
    raise exception 'No tienes permiso para ver los reportes de esta empresa';
  end if;

  return coalesce((
    select jsonb_agg(item order by es_nuevo desc, coord_nuevo desc, creada_en desc)
    from (
      select jsonb_build_object(
        'id', r.id,
        'autor', jsonb_build_object('nombre', u.nombre, 'codigo', u.codigo, 'rol', u.rol),
        'esCoordinador', u.rol = 'coordinador',
        'tipo', r.tipo,
        'mensaje', r.mensaje,
        'estado', r.estado,
        'creadaEn', r.creada_en
      ) as item,
      (r.estado = 'nuevo') as es_nuevo,
      (r.estado = 'nuevo' and u.rol = 'coordinador') as coord_nuevo,
      r.creada_en as creada_en
      from reportes r
      join usuarios u on u.id = r.autor_id
      where r.empresa_id = p_empresa
    ) t
  ), '[]'::jsonb);
end;
$$;

create or replace function pr_resolver_reporte(p_reporte uuid, p_quien uuid)
returns jsonb language plpgsql security definer as $$
declare
  q usuarios;
  rep reportes;
  a usuarios;
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

-- ============ 4. PANEL DE ADMINISTRADOR DE MIGUEL (superadmin) ============
create or replace function pr_exigir_superadmin(p_quien uuid) returns usuarios
language plpgsql stable security definer as $$
declare q usuarios;
begin
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null or q.rol <> 'superadmin' then
    raise exception 'Solo el administrador de RutaNeto puede hacer esto';
  end if;
  return q;
end;
$$;

-- Foto de TODAS las empresas contratadas: licencia vigente, cuántos
-- choferes/clientes/rutas tiene cada una, y totales del sistema.
-- numChoferes cuenta choferes ACTIVOS (los que mide la licencia);
-- numClientes y numRutas cuentan todo lo registrado de la empresa.
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
        'licencia', case when l.id is null then null else jsonb_build_object(
          'estado', l.estado, 'vence', l.vence, 'maxChoferes', l.max_choferes) end,
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
      'choferes', (select count(*) from usuarios where rol = 'chofer' and activo)
    )
  );
end;
$$;

-- Alta completa de una empresa que firmó con RutaNeto: empresa + licencia
-- activa (vence hoy + p_meses) + opciones por defecto + su usuario
-- administrador (rol 'empresa') con el PIN dado (guardado con hash).
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

  return jsonb_build_object(
    'empresa', jsonb_build_object('id', e.id, 'nombre', e.nombre, 'activa', e.activa),
    'licencia', jsonb_build_object('estado', lic.estado, 'vence', lic.vence,
                                   'maxChoferes', lic.max_choferes),
    'admin', jsonb_build_object('id', adm.id, 'codigo', adm.codigo,
                                'nombre', adm.nombre, 'rol', adm.rol)
  );
end;
$$;

-- Manejo de la licencia de una empresa: activar / suspender / extender.
-- Extender suma p_meses al vencimiento (desde el vence actual o desde hoy
-- si ya venció) y deja la licencia activa.
create or replace function pr_admin_licencia(p_quien uuid, p_empresa uuid,
                                             p_accion text, p_meses int default null)
returns jsonb language plpgsql security definer as $$
declare lic licencias;
begin
  perform pr_exigir_superadmin(p_quien);
  select * into lic from licencias
  where empresa_id = p_empresa order by creada_en desc limit 1;
  if lic.id is null then raise exception 'Esta empresa no tiene licencia'; end if;

  if p_accion = 'activar' then
    update licencias set estado = 'activa' where id = lic.id returning * into lic;
  elsif p_accion = 'suspender' then
    update licencias set estado = 'suspendida' where id = lic.id returning * into lic;
  elsif p_accion = 'extender' then
    if p_meses is null or p_meses <= 0 then
      raise exception 'Para extender la licencia indica los meses';
    end if;
    update licencias
    set estado = 'activa',
        vence = (greatest(coalesce(vence, current_date), current_date)
                 + (p_meses || ' months')::interval)::date
    where id = lic.id returning * into lic;
  else
    raise exception 'Acción no válida: %', p_accion;
  end if;

  return jsonb_build_object('estado', lic.estado, 'vence', lic.vence,
                            'maxChoferes', lic.max_choferes);
end;
$$;

-- ============ 5. CAMBIO DE PIN ============
-- Cada usuario cambia SU PIN sabiendo el actual (vale para todos los
-- roles). El nuevo debe tener mínimo 4 caracteres.
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
  return true;
end;
$$;

-- El superadmin le pone un PIN nuevo al administrador (rol 'empresa') de
-- una empresa que lo olvidó; devuelve el código de ese administrador.
create or replace function pr_admin_pin_admin(p_quien uuid, p_empresa uuid,
                                              p_pin_nuevo text)
returns text language plpgsql security definer as $$
declare adm usuarios;
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
  return adm.codigo;
end;
$$;
