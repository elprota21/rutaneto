-- Pago por Rutas — esquema v1 (PostgreSQL / Supabase)
-- TODA la lógica de negocio vive aquí, en el servidor (funciones pr_*).
-- El panel y la app solo muestran pantallas y llaman estas funciones.
-- Fuente de verdad del proyecto. No aplicar a producción sin revisión.

-- gen_random_uuid() es parte del nucleo desde PostgreSQL 13 (Supabase incluido).

-- ============ EMPRESAS Y LICENCIAS ============
create table if not exists empresas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  activa boolean not null default true,
  creada_en timestamptz not null default now()
);

create table if not exists licencias (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  estado text not null default 'activa' check (estado in ('activa','suspendida','vencida')),
  vence date,
  max_choferes int,
  creada_en timestamptz not null default now()
);

-- ============ OPCIONES POR EMPRESA (los interruptores del panel) ============
create table if not exists opciones_empresa (
  empresa_id uuid primary key references empresas(id) on delete cascade,
  ver_ganado text not null default 'todo' check (ver_ganado in ('todo','ultimo_dia','nada')),
  voucher_app boolean not null default true,
  boton_especial boolean not null default true,
  rutas_empresa_por_dia int,
  sabado_extra boolean not null default false,
  domingo_extra boolean not null default false,
  feriado_extra boolean not null default false,
  limite_anotacion text not null default 'hoy_y_ayer' check (limite_anotacion in ('hoy','hoy_y_ayer'))
);

create table if not exists feriados (
  empresa_id uuid not null references empresas(id) on delete cascade,
  fecha date not null,
  nombre text,
  primary key (empresa_id, fecha)
);

-- ============ PERSONAS ============
create table if not exists usuarios (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid references empresas(id) on delete cascade,
  rol text not null check (rol in ('superadmin','empresa','coordinador','chofer')),
  nombre text not null,
  codigo text not null,
  pin_hash text,
  auth_id uuid,
  activo boolean not null default true,
  unique (empresa_id, codigo)
);

-- ============ EMPRESAS CLIENTE ============
-- A quién le brinda servicio la transportista (zonas francas, parques
-- industriales, plantas...). Cada cliente pertenece a UNA empresa de
-- transporte; las rutas se reparten entre sus clientes.
create table if not exists clientes (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  nombre text not null,
  activo boolean not null default true,
  creada_en timestamptz not null default now(),
  unique (empresa_id, nombre)
);

-- ============ RUTAS ============
-- cliente_id: la empresa cliente dueña de la ruta. NULL = ruta «General»
-- (no pertenece a ningún cliente en particular).
create table if not exists rutas (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  cliente_id uuid references clientes(id) on delete set null,
  codigo text not null,
  nombre text not null,
  precio numeric(12,2) not null check (precio >= 0),
  activa boolean not null default true,
  unique (empresa_id, codigo)
);
-- Por si la tabla ya existía sin la columna (esquema v1):
alter table rutas add column if not exists cliente_id uuid references clientes(id) on delete set null;

-- ============ ANOTACIONES ============
-- normal:  nace 'aprobada' y suma de una vez, salvo duplicado -> 'conflicto' (no suma).
-- especial: nace 'especial_pendiente', sin precio; suma solo si el coordinador la valida.
create table if not exists anotaciones (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  chofer_id uuid not null references usuarios(id),
  ruta_id uuid references rutas(id),
  -- Cliente de la anotación: en las normales se copia de la ruta al anotar
  -- (queda fijo aunque la ruta cambie de cliente después); en las especiales
  -- lo elige el chofer. NULL = «General».
  cliente_id uuid references clientes(id) on delete set null,
  tipo text not null check (tipo in ('normal','especial')),
  descripcion text,
  nota text,
  fecha date not null,
  clase text not null check (clase in ('empresa','extra')),
  estado text not null check (estado in ('aprobada','conflicto','rechazada','especial_pendiente')),
  precio_aplicado numeric(12,2),
  validada_por uuid references usuarios(id),
  -- Auditoría de la resolución de un conflicto: 'unico' (ganó un solo chofer)
  -- o 'ambas' (la ruta se cubrió entre dos autobuses y cuentan las dos).
  resolucion text check (resolucion in ('unico','ambas')),
  creada_en timestamptz not null default now()
);
alter table anotaciones add column if not exists cliente_id uuid references clientes(id) on delete set null;
alter table anotaciones add column if not exists resolucion text check (resolucion in ('unico','ambas'));
create index if not exists idx_anot_empresa_fecha on anotaciones(empresa_id, fecha);
create index if not exists idx_anot_chofer_fecha on anotaciones(chofer_id, fecha);
create index if not exists idx_anot_ruta_fecha on anotaciones(empresa_id, ruta_id, fecha);
create index if not exists idx_anot_cliente_fecha on anotaciones(empresa_id, cliente_id, fecha);

-- ============ VOUCHERS ============
create table if not exists vouchers (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  chofer_id uuid not null references usuarios(id),
  folio int not null,
  desde date not null,
  hasta date not null,
  num_empresa int not null default 0,
  num_extra int not null default 0,
  total_empresa numeric(12,2) not null default 0,
  total_extra numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  creado_en timestamptz not null default now(),
  unique (empresa_id, folio)
);

create table if not exists voucher_detalle (
  voucher_id uuid not null references vouchers(id) on delete cascade,
  anotacion_id uuid references anotaciones(id),
  fecha date not null,
  descripcion text not null,
  cliente text,
  clase text not null,
  precio numeric(12,2) not null
);
alter table voucher_detalle add column if not exists cliente text;

-- RLS activa en todo: el acceso real pasa por las funciones pr_* (security definer).
alter table empresas enable row level security;
alter table licencias enable row level security;
alter table opciones_empresa enable row level security;
alter table feriados enable row level security;
alter table usuarios enable row level security;
alter table clientes enable row level security;
alter table rutas enable row level security;
alter table anotaciones enable row level security;
alter table vouchers enable row level security;
alter table voucher_detalle enable row level security;

-- ============ AYUDANTES ============
create or replace function pr_licencia_ok(p_empresa uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from empresas e
    join licencias l on l.empresa_id = e.id
    where e.id = p_empresa and e.activa
      and l.estado = 'activa' and (l.vence is null or l.vence >= current_date)
  );
$$;

create or replace function pr_opciones(p_empresa uuid) returns opciones_empresa
language sql stable as $$
  select * from opciones_empresa where empresa_id = p_empresa;
$$;

-- Clase (empresa/extra) de la PRÓXIMA anotación de un chofer en una fecha.
create or replace function pr_clase_del_dia(p_empresa uuid, p_chofer uuid, p_fecha date)
returns text language plpgsql stable as $$
declare
  o opciones_empresa;
  ya int;
begin
  o := pr_opciones(p_empresa);
  if o.empresa_id is null then return 'empresa'; end if;
  if o.feriado_extra and exists (select 1 from feriados f where f.empresa_id = p_empresa and f.fecha = p_fecha) then
    return 'extra';
  end if;
  if o.sabado_extra and extract(isodow from p_fecha) = 6 then return 'extra'; end if;
  if o.domingo_extra and extract(isodow from p_fecha) = 7 then return 'extra'; end if;
  if o.rutas_empresa_por_dia is not null then
    select count(*) into ya from anotaciones a
    where a.empresa_id = p_empresa and a.chofer_id = p_chofer and a.fecha = p_fecha
      and a.estado <> 'rechazada';
    if ya >= o.rutas_empresa_por_dia then return 'extra'; end if;
  end if;
  return 'empresa';
end;
$$;

create or replace function pr_revisar_plazo(p_empresa uuid, p_fecha date) returns void
language plpgsql stable as $$
declare o opciones_empresa;
begin
  o := pr_opciones(p_empresa);
  if o.limite_anotacion = 'hoy' and p_fecha <> current_date then
    raise exception 'Esta empresa solo permite anotar el mismo dia';
  end if;
  if o.limite_anotacion = 'hoy_y_ayer' and (p_fecha > current_date or p_fecha < current_date - 1) then
    raise exception 'Solo se puede anotar hoy o ayer';
  end if;
end;
$$;

-- ============ ANOTAR RUTA NORMAL (con detector de duplicados) ============
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

-- ============ ANOTAR RUTA ESPECIAL ============
-- p_cliente: la empresa cliente del viaje (la elige el chofer en la app);
-- null = «General». Debe ser un cliente activo de la misma empresa.
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

-- ============ VALIDAR RUTA ESPECIAL (coordinador) ============
create or replace function pr_validar_especial(p_anotacion uuid, p_coordinador uuid, p_precio numeric,
                                               p_aprobar boolean default true,
                                               p_convertir boolean default false,
                                               p_codigo text default null)
returns anotaciones language plpgsql security definer as $$
declare
  a anotaciones;
  coord usuarios;
  nueva_ruta rutas;
begin
  select * into a from anotaciones where id = p_anotacion and tipo = 'especial' and estado = 'especial_pendiente';
  if a.id is null then raise exception 'Esa ruta especial no esta pendiente'; end if;
  select * into coord from usuarios where id = p_coordinador and empresa_id = a.empresa_id
    and rol in ('coordinador','empresa') and activo;
  if coord.id is null then raise exception 'Solo el coordinador o la empresa pueden validar'; end if;

  if not p_aprobar then
    update anotaciones set estado = 'rechazada', validada_por = p_coordinador
    where id = p_anotacion returning * into a;
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
  return a;
end;
$$;

-- ============ RESOLVER CONFLICTO (duplicado) ============
-- Modos de resolución (p_modo):
--  - 'unico' (defecto): ganó UN chofer; la suya queda aprobada y las demás
--    del conflicto, rechazadas. Es la salida antifraude normal.
--  - 'ambas': la ruta se cubrió ENTRE DOS autobuses (caso real: un autobús
--    de 50 pasajeros se daña y mandan 2 de 30 a hacer la misma ruta; los dos
--    choferes tienen la razón). TODAS las anotaciones del conflicto quedan
--    aprobadas y cuentan con normalidad: cada una conserva la clase que ya
--    traía según el día y el cupo de SU chofer (empresa hasta el cupo, extra
--    después), así que el dinero sigue la regla de siempre (empresa = sueldo,
--    extra = su precio). Queda registrado quién resolvió (validada_por) y con
--    qué modo (resolucion = 'ambas').
-- Se elimina la firma vieja de 2 argumentos para que no convivan dos
-- versiones de la función; las llamadas de 2 argumentos siguen funcionando
-- porque p_modo tiene valor por defecto.
drop function if exists pr_resolver_conflicto(uuid, uuid);
create or replace function pr_resolver_conflicto(p_anotacion uuid, p_quien uuid,
                                                 p_modo text default 'unico')
returns void language plpgsql security definer as $$
declare a anotaciones;
begin
  if p_modo not in ('unico','ambas') then
    raise exception 'Modo de resolucion no valido: %', p_modo;
  end if;
  select * into a from anotaciones where id = p_anotacion and estado = 'conflicto';
  if a.id is null then raise exception 'Esa anotacion no esta en conflicto'; end if;

  if p_modo = 'ambas' then
    update anotaciones
    set estado = 'aprobada', validada_por = p_quien, resolucion = 'ambas'
    where empresa_id = a.empresa_id and ruta_id = a.ruta_id and fecha = a.fecha
      and cliente_id is not distinct from a.cliente_id
      and tipo = 'normal' and estado = 'conflicto';
    return;
  end if;

  update anotaciones set estado = 'aprobada', validada_por = p_quien, resolucion = 'unico'
  where id = p_anotacion;
  update anotaciones set estado = 'rechazada', validada_por = p_quien, resolucion = 'unico'
  where empresa_id = a.empresa_id and ruta_id = a.ruta_id and fecha = a.fecha
    and cliente_id is not distinct from a.cliente_id
    and tipo = 'normal' and id <> p_anotacion and estado = 'conflicto';
end;
$$;

-- Rechazo manual de la empresa (corregir un error).
create or replace function pr_rechazar_anotacion(p_anotacion uuid, p_quien uuid)
returns void language plpgsql security definer as $$
begin
  update anotaciones set estado = 'rechazada', validada_por = p_quien
  where id = p_anotacion and estado <> 'rechazada';
end;
$$;

-- ============ CÁLCULO ============
-- REGLA DEL DINERO (corrección de Miguel, 2026-11-15): las rutas clase 'empresa'
-- NO se pagan por ruta — las cubre el sueldo mensual del chofer (importe 0).
-- Solo suman dinero las clase 'extra' (incluidas las especiales validadas).
-- total_empresa queda en 0 a propósito: es constancia de trabajo, no pago.
create or replace function pr_resumen_chofer(p_empresa uuid, p_chofer uuid, p_desde date, p_hasta date)
returns table (num_empresa int, num_extra int, total_empresa numeric, total_extra numeric, total numeric)
language sql stable as $$
  select
    count(*) filter (where clase = 'empresa')::int,
    count(*) filter (where clase = 'extra')::int,
    0::numeric,
    coalesce(sum(precio_aplicado) filter (where clase = 'extra'), 0),
    coalesce(sum(precio_aplicado) filter (where clase = 'extra'), 0)
  from anotaciones
  where empresa_id = p_empresa and chofer_id = p_chofer
    and estado = 'aprobada' and fecha between p_desde and p_hasta;
$$;

-- Lo que el chofer puede VER de su ganancia, según el interruptor de su empresa.
-- 'nada' -> sin filas con dinero (total null). 'ultimo_dia' -> solo su último día anotado.
-- 'todo' -> del primer día del mes actual a hoy.
create or replace function pr_mi_ganado(p_empresa uuid, p_chofer uuid)
returns table (modo text, desde date, hasta date, total numeric)
language plpgsql stable as $$
declare o opciones_empresa; ultimo date;
begin
  o := pr_opciones(p_empresa);
  if o.empresa_id is null or o.ver_ganado = 'todo' then
    return query select 'todo', date_trunc('month', current_date)::date, current_date,
      (select r.total from pr_resumen_chofer(p_empresa, p_chofer, date_trunc('month', current_date)::date, current_date) r);
  elsif o.ver_ganado = 'ultimo_dia' then
    select max(fecha) into ultimo from anotaciones
      where empresa_id = p_empresa and chofer_id = p_chofer and estado = 'aprobada';
    if ultimo is null then
      return query select 'ultimo_dia', current_date, current_date, 0::numeric;
    else
      return query select 'ultimo_dia', ultimo, ultimo,
        (select r.total from pr_resumen_chofer(p_empresa, p_chofer, ultimo, ultimo) r);
    end if;
  else
    return query select 'nada', current_date, current_date, null::numeric;
  end if;
end;
$$;

-- ============ GENERAR VOUCHER ============
create or replace function pr_generar_voucher(p_empresa uuid, p_chofer uuid, p_desde date, p_hasta date)
returns vouchers language plpgsql security definer as $$
declare
  res record;
  v vouchers;
  nuevo_folio int;
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
  return v;
end;
$$;
