-- Pago por Rutas — CORRECCIONES PREVIAS A LA VENTA (PostgreSQL / Supabase)
-- Se aplica AL FINAL de la cadena: esquema, conexion, semilla, app-datos,
-- ajustes-2026-11-15, acceso-roles, auditoria, caducidad, permisos-dueno,
-- permisos-crud, app-novedades, borrar-empresa, panel-por-empresa.
-- Es IDEMPOTENTE: todo va con create or replace / if not exists / drop
-- puntual de firma; correrlo dos veces no rompe nada.
--
-- Origen: auditoría previa a la venta del 2026-11-19
-- (REVISION-PREVIA-VENTA.md): 4 críticos y 8 mayores. Este archivo los
-- corrige SIN tocar la regla del dinero (el sueldo cubre las rutas de
-- empresa; solo las extras pagan) y manteniendo la regla del dueño
-- (el superadmin no opera dentro de las empresas: solo consulta).
--
-- QUÉ TRAE:
--   0. Hora de República Dominicana: pr_hoy() / pr_ahora_rd() y todas
--      las fechas del servidor calculadas con ellas (mayor 8).
--   1. SESIONES REALES con token (crítico 2, mayor 12): tabla
--      `sesiones` (solo se guarda el HASH del token), pr_iniciar_sesion
--      devuelve {token, expiraEn} (12 h panel/admin, 30 días app),
--      pr_validar_token() para las RPC sensibles, revocación al
--      cambiar el PIN, al reiniciarlo el dueño y al desactivar al
--      usuario, y pr_cerrar_sesion().
--      INTERRUPTOR DE DESPLIEGUE: fila `exigir_token` en `configuracion`
--      (nace en 'false'). Con 'false', las llamadas SIN token siguen
--      pasando (compatibilidad con la app 1.4.0 publicada y los paneles
--      actuales), pero un token PRESENTE siempre se valida: inválido,
--      expirado, revocado o de otro usuario = rechazo. El paso final
--      de producción (tras desplegar paneles con token y la app 1.4.1)
--      es ponerlo en 'true' con pr_fijar_exigir_token(): desde ahí,
--      sin token no entra ninguna RPC sensible.
--   2. pr_snapshot y pr_resumen_periodo EXIGEN actor (crítico 1):
--      usuario activo de la empresa (empresa/coordinador/chofer de
--      esa empresa) o el superadmin en modo consulta. Sin actor o con
--      actor de otra empresa: error claro en español.
--   3. pr_anotar_ruta / pr_anotar_especial validan chofer∈empresa,
--      activo y rol chofer/coordinador (crítico 3), y BLOQUEAN la
--      doble anotación del mismo chofer+ruta+fecha (mayor 11).
--   4. pr_crear_usuario exige actor con rol empresa/coordinador DE
--      ESA empresa (el superadmin recibe el mensaje de la regla del
--      dueño) y PIN explícito de 4-6 dígitos distinto de '1234'
--      (crítico 4). Sin PIN por defecto.
--   5. pr_resolver_conflicto / pr_rechazar_anotacion validan rol
--      (empresa/coordinador) y empresa del actor (mayor 5).
--   6. Cupo rutasEmpresaPorDia: CHECK >= 0 en la tabla y validación
--      en pr_actualizar_opciones (mayor 6).
--   7. Vouchers (mayor 7 + menores): columnas de anulación; folio con
--      advisory lock por empresa; si ya existe un voucher ACTIVO del
--      mismo chofer y rango, pr_generar_voucher devuelve ESE (no crea
--      otro); nueva pr_anular_voucher (empresa/coordinador de la
--      empresa, con motivo obligatorio) que lo marca anulado y
--      permite regenerar; pr_generar_voucher valida chofer∈empresa.
--   8. pr_clase_del_dia: el cupo lo consumen SOLO las anotaciones
--      normales APROBADAS (mayor 10): las especiales pendientes y los
--      conflictos ya no empujan rutas normales a extra.
--   9. pr_datos_chofer aplica ver_ganado y voucher_app EN EL SERVIDOR
--      (mayor 9): 'nada' -> sin montos (precioAplicado y totales en
--      null); 'ultimo_dia' -> montos solo del último día anotado;
--      voucher_app=false -> sin vouchers.
--  10. Menores: pr_resumen_periodo excluye choferes desactivados;
--      errores en español sin nombres internos cuando el dato no
--      existe (chofer/ruta/anotación/voucher inexistentes).
--
-- COMPATIBILIDAD: los parámetros nuevos van AL FINAL con default
-- null (p_quien / p_token); las llamadas actuales de paneles y app
-- siguen funcionando. Las firmas viejas se eliminan para que
-- PostgREST no tenga sobrecargas ambiguas.

-- ================================================================
-- 0. HORA DE REPÚBLICA DOMINICANA (mayor 8)
-- ================================================================
-- «Hoy» para el negocio es el día en Santo Domingo, no el día UTC
-- del servidor de Supabase (que desde las 8:00 p. m. AST ya marca
-- mañana y descuadraba plazos, clase del día, ganado y licencias).
create or replace function pr_hoy() returns date
language sql stable as $$
  select (now() at time zone 'America/Santo_Domingo')::date;
$$;

create or replace function pr_ahora_rd() returns timestamp
language sql stable as $$
  select now() at time zone 'America/Santo_Domingo';
$$;

-- Vigencia de licencia con el día dominicano (antes: current_date UTC).
create or replace function pr_licencia_ok(p_empresa uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from empresas e
    join licencias l on l.empresa_id = e.id
    where e.id = p_empresa and e.activa
      and l.estado = 'activa' and (l.vence is null or l.vence >= pr_hoy())
  );
$$;

-- ================================================================
-- 1. SESIONES CON TOKEN (crítico 2, mayor 12)
-- ================================================================
create table if not exists configuracion (
  clave text primary key,
  valor text not null,
  descripcion text
);
alter table configuracion enable row level security;

-- El interruptor nace APAGADO: ver el encabezado (paso final de
-- producción). on conflict do nothing: re-aplicar este archivo NO
-- vuelve a apagar un interruptor ya activado en producción.
insert into configuracion (clave, valor, descripcion) values
  ('exigir_token', 'false',
   'Si vale true, las RPC sensibles rechazan llamadas sin token de sesión. Activar SOLO tras desplegar paneles con token y la app 1.4.1.')
on conflict (clave) do nothing;

create or replace function pr_exigir_token() returns boolean
language sql stable security definer as $$
  select coalesce(
    (select valor from configuracion where clave = 'exigir_token'),
    'false') = 'true';
$$;

-- Solo el dueño (superadmin) mueve el interruptor, desde su panel o
-- el editor SQL. Pensado para el paso final del despliegue.
create or replace function pr_fijar_exigir_token(p_quien uuid, p_valor boolean)
returns boolean language plpgsql security definer as $$
begin
  perform pr_exigir_superadmin(p_quien);
  insert into configuracion (clave, valor) values ('exigir_token', p_valor::text)
  on conflict (clave) do update set valor = excluded.valor;
  perform pr_registrar_accion(null, p_quien, 'exigir_token_cambiado',
    format('El interruptor exigir_token quedó en %s', p_valor));
  return p_valor;
end;
$$;

create table if not exists sesiones (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references usuarios(id) on delete cascade,
  empresa_id uuid references empresas(id) on delete cascade,
  contexto text,
  token_hash text not null unique,
  creada_en timestamptz not null default now(),
  expira_en timestamptz not null,
  ultimo_uso timestamptz not null default now(),
  revocada_en timestamptz
);
alter table sesiones enable row level security;
create index if not exists idx_sesiones_token on sesiones(token_hash);
create index if not exists idx_sesiones_usuario on sesiones(usuario_id);

-- Token opaco aleatorio (64 hex = 32 bytes). Mismo patrón de
-- compatibilidad que pr_hash_pin: pgcrypto puede vivir en
-- `extensions` (Supabase) o en el esquema visible (PG local).
create or replace function pr_gen_token() returns text
language plpgsql as $$
declare v text;
begin
  begin
    execute 'select encode(extensions.gen_random_bytes(32), ''hex'')' into v;
  exception when invalid_schema_name or undefined_function or undefined_object then
    execute 'select encode(gen_random_bytes(32), ''hex'')' into v;
  end;
  return v;
end;
$$;

-- Del token solo se guarda su hash SHA-256: la base nunca contiene
-- un token usable.
create or replace function pr_hash_token(p_token text) returns text
language plpgsql immutable as $$
declare v text;
begin
  if p_token is null then return null; end if;
  begin
    execute 'select encode(extensions.digest($1, ''sha256''), ''hex'')' into v using p_token;
  exception when invalid_schema_name or undefined_function or undefined_object then
    execute 'select encode(digest($1, ''sha256''), ''hex'')' into v using p_token;
  end;
  return v;
end;
$$;

-- Usuario dueño de la sesión que trae p_token, o null si el token no
-- existe / está revocado / expiró / su usuario está desactivado.
create or replace function pr_actor_de_token(p_token text) returns usuarios
language plpgsql stable security definer as $$
declare
  s sesiones;
  u usuarios;
begin
  if p_token is null or length(trim(p_token)) = 0 then return null; end if;
  select * into s from sesiones
  where token_hash = pr_hash_token(p_token) and revocada_en is null;
  if s.id is null or s.expira_en <= now() then return null; end if;
  select * into u from usuarios where id = s.usuario_id and activo;
  if u.id is null then return null; end if;
  return u;
end;
$$;

-- Valida que p_token es una sesión viva DE p_actor.
--  - p_token null: pasa solo si el interruptor exigir_token está
--    apagado (compatibilidad con clientes sin token); si está
--    encendido, error.
--  - p_token presente: se valida SIEMPRE (exista o no interruptor).
-- Los mensajes distinguen «expiró» de «no es válida» para que
-- paneles y app borren la sesión guardada y muestren el login.
create or replace function pr_validar_token(p_actor uuid, p_token text)
returns void language plpgsql security definer as $$
declare
  s sesiones;
  dueno usuarios;
begin
  if p_token is null then
    if pr_exigir_token() then
      raise exception 'Debes iniciar sesión de nuevo: esta operación necesita una sesión válida';
    end if;
    return;
  end if;
  select * into s from sesiones where token_hash = pr_hash_token(p_token);
  if s.id is null or s.revocada_en is not null then
    raise exception 'Tu sesión no es válida: vuelve a iniciar sesión';
  end if;
  if s.expira_en <= now() then
    raise exception 'Tu sesión expiró: vuelve a iniciar sesión';
  end if;
  if s.usuario_id <> p_actor then
    raise exception 'Tu sesión no es válida: vuelve a iniciar sesión';
  end if;
  select * into dueno from usuarios where id = p_actor and activo;
  if dueno.id is null then
    raise exception 'Tu sesión no es válida: vuelve a iniciar sesión';
  end if;
  update sesiones set ultimo_uso = now() where id = s.id;
end;
$$;

-- Variante para anotar: el token puede ser del propio chofer o de
-- un usuario de oficina (empresa/coordinador) DE LA MISMA empresa
-- que anota por él desde el panel.
create or replace function pr_validar_token_anotacion(p_empresa uuid, p_chofer uuid, p_token text)
returns void language plpgsql security definer as $$
declare actor usuarios;
begin
  if p_token is null then
    if pr_exigir_token() then
      raise exception 'Debes iniciar sesión de nuevo: esta operación necesita una sesión válida';
    end if;
    return;
  end if;
  actor := pr_actor_de_token(p_token);
  if actor.id is null then
    -- ¿Existió la sesión pero expiró? Mensaje de expiración exacto.
    if exists (select 1 from sesiones
               where token_hash = pr_hash_token(p_token)
                 and revocada_en is null and expira_en <= now()) then
      raise exception 'Tu sesión expiró: vuelve a iniciar sesión';
    end if;
    raise exception 'Tu sesión no es válida: vuelve a iniciar sesión';
  end if;
  if actor.id = p_chofer then return; end if;
  if actor.empresa_id is not distinct from p_empresa
     and actor.rol in ('empresa','coordinador') then return; end if;
  raise exception 'Tu sesión no es válida: vuelve a iniciar sesión';
end;
$$;

-- Revoca TODAS las sesiones vivas de un usuario (cambio de PIN,
-- reinicio por el dueño, desactivación).
create or replace function pr_revocar_sesiones(p_usuario uuid)
returns void language plpgsql security definer as $$
begin
  update sesiones set revocada_en = now()
  where usuario_id = p_usuario and revocada_en is null;
end;
$$;

-- Cierre de sesión voluntario («Salir»): revoca ese token.
create or replace function pr_cerrar_sesion(p_token text)
returns void language plpgsql security definer as $$
begin
  if p_token is null then return; end if;
  update sesiones set revocada_en = now()
  where token_hash = pr_hash_token(p_token) and revocada_en is null;
end;
$$;

-- ================================================================
-- 2. FECHAS RD EN PLAZO, CLASE DEL DÍA Y EMPRESA OPERATIVA
-- ================================================================
-- Plazo de anotación en días, contra el día dominicano.
create or replace function pr_revisar_plazo(p_empresa uuid, p_fecha date) returns void
language plpgsql stable as $$
declare o opciones_empresa; n int;
begin
  o := pr_opciones(p_empresa);
  if o.empresa_id is null then return; end if;
  n := coalesce(o.dias_para_anotar, 1);
  if p_fecha > pr_hoy() then
    raise exception 'Fuera del plazo: no se puede anotar una fecha futura';
  end if;
  if p_fecha < pr_hoy() - n then
    raise exception 'Fuera del plazo: tu empresa permite anotar hasta % día(s) atrás', n;
  end if;
end;
$$;

-- Clase del día (mayor 10): el cupo de rutas de empresa SOLO lo
-- consumen las anotaciones normales APROBADAS de ese chofer ese
-- día. Antes contaba todo lo no rechazado: una especial pendiente
-- o un conflicto empujaban rutas normales a «extra» (sobrepago).
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
      and a.tipo = 'normal' and a.estado = 'aprobada';
    if ya >= o.rutas_empresa_por_dia then return 'extra'; end if;
  end if;
  return 'empresa';
end;
$$;

-- Empresa operativa con vencimiento medido en día dominicano.
create or replace function pr_exigir_empresa_operativa(p_empresa uuid)
returns void language plpgsql stable security definer as $$
declare
  e empresas;
  lic licencias;
begin
  select * into e from empresas where id = p_empresa;
  if e.id is null or not e.activa then
    raise exception 'Tu empresa está inactiva. Contacta a RutaNeto.';
  end if;
  select * into lic from licencias where empresa_id = p_empresa
  order by creada_en desc limit 1;
  if lic.id is null then
    raise exception 'Tu empresa todavía no tiene licencia. Contacta a RutaNeto.';
  end if;
  if lic.estado = 'suspendida' then
    raise exception 'La licencia de tu empresa está suspendida. Contacta a RutaNeto.';
  end if;
  if lic.estado = 'vencida' or (lic.vence is not null and lic.vence < pr_hoy()) then
    raise exception 'La licencia de tu empresa está vencida. Contacta a RutaNeto para renovarla.';
  end if;
end;
$$;

-- El saldo del chofer con el mes dominicano (antes: current_date UTC).
create or replace function pr_mi_ganado(p_empresa uuid, p_chofer uuid)
returns table (modo text, desde date, hasta date, total numeric)
language plpgsql stable security definer as $$
declare o opciones_empresa; ultimo date; hoy date := pr_hoy();
begin
  o := pr_opciones(p_empresa);
  if o.empresa_id is null or o.ver_ganado = 'todo' then
    return query select 'todo', date_trunc('month', hoy)::date, hoy,
      (select r.total from pr_resumen_chofer(p_empresa, p_chofer, date_trunc('month', hoy)::date, hoy) r);
  elsif o.ver_ganado = 'ultimo_dia' then
    select max(fecha) into ultimo from anotaciones
      where empresa_id = p_empresa and chofer_id = p_chofer and estado = 'aprobada';
    if ultimo is null then
      return query select 'ultimo_dia', hoy, hoy, 0::numeric;
    else
      return query select 'ultimo_dia', ultimo, ultimo,
        (select r.total from pr_resumen_chofer(p_empresa, p_chofer, ultimo, ultimo) r);
    end if;
  else
    return query select 'nada', hoy, hoy, null::numeric;
  end if;
end;
$$;

-- ================================================================
-- 3. INICIO DE SESIÓN CON TOKEN (crítico 2)
-- ================================================================
-- Copia fiel de la versión vigente de borrar-empresa.sql (contexto
-- por puerta, lápida de empresas eliminadas, registro de auditoría y
-- diasRestantes/porVencer), con estos cambios:
--   a) Al entrar se crea una fila en `sesiones` y la respuesta gana
--      el objeto `sesion`: {token, expiraEn}. Panel/admin: 12 horas.
--      App: 30 días (renovable entrando de nuevo).
--   b) diasRestantes/porVencer y el vencimiento se miden con
--      pr_hoy() (día dominicano).
-- Los clientes viejos ignoran la clave `sesion` y siguen entrando.
create or replace function pr_iniciar_sesion(p_codigo text, p_pin text, p_contexto text default null)
returns jsonb language plpgsql security definer as $$
declare
  candidatos int := 0;
  u usuarios;
  e empresas;
  lic licencias;
  o opciones_empresa;
  v_detalle text;
  v_token text;
  v_expira timestamptz;
  v_sesion jsonb;
begin
  -- Candidatos: usuarios activos con ese código cuyo PIN coincide.
  select count(*) into candidatos
  from usuarios x
  where x.activo and upper(x.codigo) = upper(trim(p_codigo))
    and pr_verificar_pin(p_pin, x.pin_hash);

  if candidatos = 0 then
    -- ¿El código era de una empresa ELIMINADA por el dueño? (lápida
    -- de borrar-empresa.sql: solo manda si ya no es de nadie vivo).
    if exists (select 1 from empresas_eliminadas ee
               where upper(trim(p_codigo)) = any (ee.codigos))
       and not exists (select 1 from usuarios x
                       where upper(x.codigo) = upper(trim(p_codigo))) then
      raise exception 'Esta empresa fue eliminada de RutaNeto';
    end if;
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

  -- Superadmin (Miguel): sin empresa ni licencia; entra como dueño
  -- del sistema y puede usar las tres puertas (panel, admin y app).
  if u.empresa_id is null then
    perform pr_registrar_accion(null, u.id, 'inicio_sesion', v_detalle);
    v_token := pr_gen_token();
    v_expira := now() + interval '12 hours';
    insert into sesiones (usuario_id, empresa_id, contexto, token_hash, expira_en)
    values (u.id, null, p_contexto, pr_hash_token(v_token), v_expira);
    return jsonb_build_object(
      'usuario', jsonb_build_object('id', u.id, 'nombre', u.nombre, 'codigo', u.codigo, 'rol', u.rol),
      'empresa', null,
      'opciones', null,
      'licencia', null,
      'sesion', jsonb_build_object('token', v_token, 'expiraEn', v_expira)
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
  if lic.estado = 'vencida' or (lic.vence is not null and lic.vence < pr_hoy()) then
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

  -- La sesión nace SOLO tras pasar credenciales, licencia y puerta.
  v_token := pr_gen_token();
  v_expira := now() + case when p_contexto = 'app'
                           then interval '30 days'
                           else interval '12 hours' end;
  insert into sesiones (usuario_id, empresa_id, contexto, token_hash, expira_en)
  values (u.id, u.empresa_id, p_contexto, pr_hash_token(v_token), v_expira);
  v_sesion := jsonb_build_object('token', v_token, 'expiraEn', v_expira);

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
      'diasRestantes', case when lic.vence is null then null
                            else lic.vence - pr_hoy() end,
      'porVencer', case when lic.vence is null then false
                        else (lic.vence - pr_hoy()) between 0 and 30 end,
      'ok', true
    ),
    'sesion', v_sesion
  );
end;
$$;

-- ================================================================
-- 4. SNAPSHOT Y RESUMEN DEL PERÍODO CON ACTOR (crítico 1)
-- ================================================================
-- Copia fiel del snapshot vigente de caducidad.sql (con su objeto
-- `licencia`), con estos cambios:
--   a) Firma nueva: (p_empresa, p_quien, p_token). SIN actor ya no
--      se entrega NADA: el actor debe ser un usuario activo de ESA
--      empresa o el superadmin (que entra en modo consulta, como ya
--      permitía prueba-permisos). Con p_empresa null se usa la
--      primera empresa SOLO si el actor es el superadmin; un usuario
--      de empresa sin indicar empresa ve la suya.
--   b) diasRestantes/porVencer con pr_hoy().
--   c) Los vouchers traen su estado de anulación.
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

-- Resumen del período (la nómina por chofer): misma foto que la
-- versión de app-novedades.sql (choferes + coordinadores con
-- anotaciones), pero EXIGE actor de la empresa o superadmin, y
-- excluye a los usuarios DESACTIVADOS (menor de la auditoría).
drop function if exists pr_resumen_periodo(uuid, date, date);
create or replace function pr_resumen_periodo(p_empresa uuid, p_desde date, p_hasta date,
                                              p_quien uuid default null,
                                              p_token text default null)
returns table (chofer_id uuid, num_empresa int, num_extra int,
               total_empresa numeric, total_extra numeric, total numeric)
language plpgsql stable security definer as $$
declare q usuarios;
begin
  if p_quien is null then
    raise exception 'Para ver el resumen de una empresa debes iniciar sesión';
  end if;
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);
  if q.rol <> 'superadmin' and q.empresa_id is distinct from p_empresa then
    raise exception 'No tienes permiso para ver el resumen de esta empresa';
  end if;

  return query
  select u.id, r.num_empresa, r.num_extra, r.total_empresa, r.total_extra, r.total
  from usuarios u
  cross join lateral pr_resumen_chofer(p_empresa, u.id, p_desde, p_hasta) r
  where u.empresa_id = p_empresa and u.activo
    and (u.rol = 'chofer'
         or (u.rol = 'coordinador' and exists (
               select 1 from anotaciones a
               where a.empresa_id = p_empresa and a.chofer_id = u.id
                 and a.fecha between p_desde and p_hasta)))
  order by u.nombre;
end;
$$;

-- ================================================================
-- 5. DATOS DEL CHOFER: TOKEN + INTERRUPTORES EN EL SERVIDOR
-- ================================================================
-- Copia fiel de app-novedades.sql (foto completa de chofer y
-- coordinador + reportesPendientes), con:
--   a) p_token opcional al final (validado contra el propio chofer).
--   b) ver_ganado aplicado EN EL SERVIDOR (mayor 9):
--        'nada'       -> precioAplicado de las anotaciones en null y
--                        totales de vouchers en null (con su detalle
--                        sin precios): la app ya no puede mostrar
--                        dinero aunque ignore la opción.
--        'ultimo_dia' -> precioAplicado visible SOLO en las
--                        anotaciones del último día anotado.
--        'todo'       -> como siempre.
--   c) voucher_app=false -> la lista de vouchers baja vacía.
--   d) La ventana de 45 días se mide con pr_hoy().
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

-- ================================================================
-- 6. ANOTAR: CHOFER∈EMPRESA + SIN DOBLE ANOTACIÓN (crítico 3, mayor 11)
-- ================================================================
drop function if exists pr_anotar_ruta(uuid, uuid, uuid, date, text);
drop function if exists pr_anotar_ruta(uuid, uuid, uuid, date, text, text);
create or replace function pr_anotar_ruta(p_empresa uuid, p_chofer uuid, p_ruta uuid,
                                          p_fecha date default null, p_nota text default null,
                                          p_token text default null)
returns anotaciones language plpgsql security definer as $$
declare
  r rutas;
  nueva anotaciones;
  duplicada boolean;
  chof usuarios;
  v_fecha date := coalesce(p_fecha, pr_hoy());
begin
  perform pr_exigir_empresa_operativa(p_empresa);
  -- El chofer debe EXISTIR, ser DE ESTA empresa, estar activo y
  -- tener rol de ruta (antes no se validaba nada: un chofer de
  -- Servivans pudo anotar dentro de otra empresa).
  select * into chof from usuarios where id = p_chofer;
  if chof.id is null then raise exception 'El chofer indicado no existe'; end if;
  if chof.empresa_id is distinct from p_empresa then
    raise exception 'Ese chofer no pertenece a esta empresa';
  end if;
  if not chof.activo then raise exception 'Ese chofer está desactivado'; end if;
  if chof.rol not in ('chofer','coordinador') then
    raise exception 'Solo los choferes y coordinadores pueden anotar rutas';
  end if;
  perform pr_validar_token_anotacion(p_empresa, p_chofer, p_token);
  perform pr_revisar_plazo(p_empresa, v_fecha);
  select * into r from rutas where id = p_ruta and empresa_id = p_empresa and activa;
  if r.id is null then raise exception 'Ruta no existe o esta inactiva'; end if;

  -- Mayor 11: el MISMO chofer no puede anotar la misma ruta dos
  -- veces el mismo día (antes ambas nacían y ambas podían pagar).
  if exists (
    select 1 from anotaciones a
    where a.empresa_id = p_empresa and a.chofer_id = p_chofer
      and a.ruta_id = p_ruta and a.fecha = v_fecha
      and a.tipo = 'normal' and a.estado <> 'rechazada'
  ) then
    raise exception 'Ya anotaste esta ruta en esta fecha: no se puede anotar dos veces';
  end if;

  -- Antifraude por empresa + cliente + ruta + fecha (entre choferes
  -- DISTINTOS): como cada ruta pertenece a un solo cliente, el
  -- cliente de la anotación es el de la ruta.
  duplicada := exists (
    select 1 from anotaciones a
    where a.empresa_id = p_empresa and a.ruta_id = p_ruta and a.fecha = v_fecha
      and a.cliente_id is not distinct from r.cliente_id
      and a.tipo = 'normal' and a.chofer_id <> p_chofer
      and a.estado in ('aprobada','conflicto')
  );

  if duplicada then
    update anotaciones set estado = 'conflicto'
    where empresa_id = p_empresa and ruta_id = p_ruta and fecha = v_fecha
      and cliente_id is not distinct from r.cliente_id
      and tipo = 'normal' and chofer_id <> p_chofer and estado = 'aprobada';
    insert into anotaciones (empresa_id, chofer_id, ruta_id, cliente_id, tipo, nota, fecha, clase, estado, precio_aplicado)
    values (p_empresa, p_chofer, p_ruta, r.cliente_id, 'normal', p_nota, v_fecha,
            pr_clase_del_dia(p_empresa, p_chofer, v_fecha), 'conflicto', r.precio)
    returning * into nueva;
  else
    insert into anotaciones (empresa_id, chofer_id, ruta_id, cliente_id, tipo, nota, fecha, clase, estado, precio_aplicado)
    values (p_empresa, p_chofer, p_ruta, r.cliente_id, 'normal', p_nota, v_fecha,
            pr_clase_del_dia(p_empresa, p_chofer, v_fecha), 'aprobada', r.precio)
    returning * into nueva;
  end if;
  return nueva;
end;
$$;

drop function if exists pr_anotar_especial(uuid, uuid, text, uuid, date, text);
drop function if exists pr_anotar_especial(uuid, uuid, text, uuid, date, text, text);
create or replace function pr_anotar_especial(p_empresa uuid, p_chofer uuid, p_descripcion text,
                                              p_cliente uuid default null,
                                              p_fecha date default null, p_nota text default null,
                                              p_token text default null)
returns anotaciones language plpgsql security definer as $$
declare
  o opciones_empresa;
  nueva anotaciones;
  chof usuarios;
  v_fecha date := coalesce(p_fecha, pr_hoy());
begin
  perform pr_exigir_empresa_operativa(p_empresa);
  select * into chof from usuarios where id = p_chofer;
  if chof.id is null then raise exception 'El chofer indicado no existe'; end if;
  if chof.empresa_id is distinct from p_empresa then
    raise exception 'Ese chofer no pertenece a esta empresa';
  end if;
  if not chof.activo then raise exception 'Ese chofer está desactivado'; end if;
  if chof.rol not in ('chofer','coordinador') then
    raise exception 'Solo los choferes y coordinadores pueden anotar rutas';
  end if;
  perform pr_validar_token_anotacion(p_empresa, p_chofer, p_token);
  o := pr_opciones(p_empresa);
  if o.empresa_id is not null and not o.boton_especial then
    raise exception 'Esta empresa no permite rutas especiales';
  end if;
  if p_cliente is not null and not exists (
    select 1 from clientes where id = p_cliente and empresa_id = p_empresa and activo
  ) then
    raise exception 'Esa empresa cliente no existe o esta inactiva';
  end if;
  perform pr_revisar_plazo(p_empresa, v_fecha);
  insert into anotaciones (empresa_id, chofer_id, cliente_id, tipo, descripcion, nota, fecha, clase, estado, precio_aplicado)
  values (p_empresa, p_chofer, p_cliente, 'especial', p_descripcion, p_nota, v_fecha, 'extra', 'especial_pendiente', null)
  returning * into nueva;
  return nueva;
end;
$$;

-- ================================================================
-- 7. CONFLICTOS Y RECHAZOS: ROL Y EMPRESA DEL ACTOR (mayor 5)
-- ================================================================
-- Cuerpos de permisos-dueno.sql (con su registro de auditoría y la
-- guarda del dueño) + validación de que quien resuelve/rechaza es
-- empresa o coordinador DE LA EMPRESA de la anotación, + token.
drop function if exists pr_resolver_conflicto(uuid, uuid);
drop function if exists pr_resolver_conflicto(uuid, uuid, text);
drop function if exists pr_resolver_conflicto(uuid, uuid, text, text);
create or replace function pr_resolver_conflicto(p_anotacion uuid, p_quien uuid,
                                                 p_modo text default 'unico',
                                                 p_token text default null)
returns void language plpgsql security definer as $$
declare
  a anotaciones;
  r rutas;
  c clientes;
  ganador usuarios;
  q usuarios;
  v_detalle text;
begin
  perform pr_exigir_no_dueno(p_quien);
  if p_modo not in ('unico','ambas') then
    raise exception 'Modo de resolucion no valido: %', p_modo;
  end if;
  select * into a from anotaciones where id = p_anotacion and estado = 'conflicto';
  if a.id is null then raise exception 'Esa anotacion no esta en conflicto'; end if;

  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);
  if q.rol not in ('empresa','coordinador') or q.empresa_id is distinct from a.empresa_id then
    raise exception 'Solo el coordinador o la administración de esta empresa pueden resolver conflictos';
  end if;

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

drop function if exists pr_rechazar_anotacion(uuid, uuid);
drop function if exists pr_rechazar_anotacion(uuid, uuid, text);
create or replace function pr_rechazar_anotacion(p_anotacion uuid, p_quien uuid,
                                                 p_token text default null)
returns void language plpgsql security definer as $$
declare
  a anotaciones;
  q usuarios;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into a from anotaciones where id = p_anotacion;
  if a.id is null then raise exception 'Esa anotación no existe'; end if;
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);
  if q.rol not in ('empresa','coordinador') or q.empresa_id is distinct from a.empresa_id then
    raise exception 'Solo el coordinador o la administración de esta empresa pueden rechazar anotaciones';
  end if;
  update anotaciones set estado = 'rechazada', validada_por = p_quien
  where id = p_anotacion and estado <> 'rechazada';
end;
$$;

-- ================================================================
-- 8. VOUCHERS: ÚNICO POR CHOFER+PERÍODO + ANULACIÓN (mayor 7)
-- ================================================================
alter table vouchers add column if not exists anulado boolean not null default false;
alter table vouchers add column if not exists anulado_por uuid references usuarios(id);
alter table vouchers add column if not exists anulado_motivo text;
alter table vouchers add column if not exists anulado_en timestamptz;

-- Cuerpo de permisos-dueno.sql (auditoría + guarda del dueño) con:
--   a) validación chofer∈empresa (menor: antes un chofer ajeno o
--      inexistente consumía folio con un voucher vacío);
--   b) advisory lock por empresa: el folio max+1 ya no colisiona
--      con generaciones simultáneas;
--   c) unicidad: si ya hay un voucher ACTIVO de ese chofer para
--      EXACTAMENTE ese rango, se devuelve ese mismo (doble clic =
--      mismo comprobante, nunca dos). Para regenerar con datos
--      nuevos hay que anularlo antes (pr_anular_voucher);
--   d) token del actor cuando viene p_quien.
drop function if exists pr_generar_voucher(uuid, uuid, date, date);
drop function if exists pr_generar_voucher(uuid, uuid, date, date, uuid);
drop function if exists pr_generar_voucher(uuid, uuid, date, date, uuid, text);
create or replace function pr_generar_voucher(p_empresa uuid, p_chofer uuid, p_desde date, p_hasta date,
                                              p_quien uuid default null,
                                              p_token text default null)
returns vouchers language plpgsql security definer as $$
declare
  res record;
  v vouchers;
  nuevo_folio int;
  chof usuarios;
begin
  perform pr_exigir_no_dueno(p_quien);
  if p_quien is not null then
    perform pr_validar_token(p_quien, p_token);
  end if;
  select * into chof from usuarios where id = p_chofer;
  if chof.id is null then raise exception 'El chofer indicado no existe'; end if;
  if chof.empresa_id is distinct from p_empresa then
    raise exception 'Ese chofer no pertenece a esta empresa';
  end if;
  if not pr_licencia_ok(p_empresa) then raise exception 'Licencia inactiva'; end if;

  -- A partir de aquí, una sola generación de vouchers por empresa
  -- a la vez (la transacción libera el bloqueo al terminar).
  perform pg_advisory_xact_lock(hashtextextended('rutaneto-voucher-' || p_empresa::text, 0));

  select * into v from vouchers
  where empresa_id = p_empresa and chofer_id = p_chofer
    and desde = p_desde and hasta = p_hasta and not anulado
  limit 1;
  if v.id is not null then
    return v;  -- ya existe: doble clic no duplica comprobantes
  end if;

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
  perform pr_registrar_accion(p_empresa, p_quien, 'voucher_generado',
    format('Se generó el voucher #%s para %s (%s) del %s al %s por RD$%s',
           v.folio, chof.codigo, chof.nombre,
           to_char(v.desde, 'DD/MM/YYYY'), to_char(v.hasta, 'DD/MM/YYYY'),
           to_char(v.total, 'FM999,999,990.00')));
  return v;
end;
$$;

-- Anular un voucher: solo empresa/coordinador DE ESA empresa, con
-- motivo obligatorio. El voucher queda marcado (no se borra: el
-- folio y el motivo quedan para auditoría) y deja de bloquear la
-- regeneración: el próximo pr_generar_voucher del mismo chofer y
-- rango crea uno nuevo con folio nuevo.
create or replace function pr_anular_voucher(p_voucher uuid, p_quien uuid,
                                             p_motivo text,
                                             p_token text default null)
returns vouchers language plpgsql security definer as $$
declare
  v vouchers;
  q usuarios;
  chof usuarios;
begin
  select * into v from vouchers where id = p_voucher;
  if v.id is null then raise exception 'Ese voucher no existe'; end if;
  perform pr_exigir_no_dueno(p_quien);
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);
  if q.rol not in ('empresa','coordinador') or q.empresa_id is distinct from v.empresa_id then
    raise exception 'Solo la administración de esta empresa puede anular un voucher';
  end if;
  if v.anulado then raise exception 'Ese voucher ya está anulado'; end if;
  if p_motivo is null or length(trim(p_motivo)) = 0 then
    raise exception 'Para anular un voucher indica el motivo';
  end if;
  update vouchers
  set anulado = true, anulado_por = p_quien,
      anulado_motivo = trim(p_motivo), anulado_en = now()
  where id = p_voucher
  returning * into v;
  select * into chof from usuarios where id = v.chofer_id;
  perform pr_registrar_accion(v.empresa_id, p_quien, 'voucher_anulado',
    format('Se anuló el voucher #%s de %s (%s): %s',
           v.folio, chof.codigo, chof.nombre, trim(p_motivo)));
  return v;
end;
$$;

-- ================================================================
-- 9. CREAR USUARIO: ACTOR Y PIN OBLIGATORIOS (crítico 4)
-- ================================================================
-- Cuerpo de permisos-crud.sql con la guarda nueva PRIMERO:
--   - p_quien es OBLIGATORIO y debe ser empresa/coordinador activo
--     DE ESA empresa. Sin actor ya no se crea nadie (antes bastaba
--     la anon key). El superadmin recibe el mensaje de la regla
--     del dueño (él crea empresas, no usuarios dentro de ellas).
--   - p_pin deja de tener default: PIN explícito de 4 a 6 dígitos,
--     distinto de '1234'. Sin PIN no hay usuario.
drop function if exists pr_crear_usuario(uuid, text, text, text, text);
drop function if exists pr_crear_usuario(uuid, text, text, text, text, uuid);
drop function if exists pr_crear_usuario(uuid, text, text, text, text, uuid, text);
create or replace function pr_crear_usuario(p_empresa uuid, p_nombre text, p_codigo text,
                                            p_rol text, p_pin text default null,
                                            p_quien uuid default null,
                                            p_token text default null)
returns usuarios language plpgsql security definer as $$
declare
  nuevo usuarios;
  lic licencias;
  ya int;
  q usuarios;
begin
  if p_quien is null then
    raise exception 'Para crear un usuario debes iniciar sesión: falta quién lo crea';
  end if;
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);
  perform pr_exigir_no_dueno(p_quien);
  if q.rol not in ('empresa','coordinador') or q.empresa_id is distinct from p_empresa then
    raise exception 'No tienes permiso para crear usuarios en esta empresa';
  end if;
  if p_rol not in ('empresa','coordinador','chofer') then
    raise exception 'Rol no válido para el panel: %', p_rol;
  end if;
  if p_pin is null or length(trim(p_pin)) = 0 then
    raise exception 'El PIN es obligatorio: indica un PIN de 4 a 6 dígitos para el usuario nuevo';
  end if;
  if trim(p_pin) !~ '^[0-9]{4,6}$' then
    raise exception 'El PIN debe tener de 4 a 6 dígitos';
  end if;
  if trim(p_pin) = '1234' then
    raise exception 'El PIN 1234 está prohibido por seguridad: elige otro PIN';
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
  values (p_empresa, p_rol, trim(p_nombre), trim(p_codigo), pr_hash_pin(trim(p_pin)))
  returning * into nuevo;
  perform pr_registrar_accion(p_empresa, p_quien, 'usuario_creado',
    format('Se creó el usuario %s (%s, %s)', nuevo.codigo, nuevo.nombre, nuevo.rol));
  return nuevo;
end;
$$;

-- Desactivar un usuario ahora también revoca sus sesiones (antes
-- el token/UUID seguía «vivo» en su teléfono o navegador).
-- (Cuerpo de permisos-crud.sql + la revocación.)
create or replace function pr_cambiar_activo_usuario(p_usuario uuid, p_activo boolean,
                                                     p_quien uuid default null)
returns void language plpgsql security definer as $$
declare u usuarios;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into u from usuarios where id = p_usuario;
  update usuarios set activo = p_activo where id = p_usuario;
  if not p_activo then
    perform pr_revocar_sesiones(p_usuario);
  end if;
  if u.id is not null then
    perform pr_registrar_accion(u.empresa_id, p_quien, 'usuario_editado',
      format('%s al usuario %s (%s)', case when p_activo then 'Se activó' else 'Se desactivó' end,
             u.codigo, u.nombre));
  end if;
end;
$$;

-- Cambiar el PIN revoca las sesiones: quien tenía el PIN viejo
-- (o un token robado) sale de todos lados. (Cuerpo de
-- auditoria.sql + la revocación.)
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
  perform pr_revocar_sesiones(p_usuario);
  perform pr_registrar_accion(u.empresa_id, p_usuario, 'pin_cambiado',
    'Cambió su PIN de acceso');
  return true;
end;
$$;

-- El reinicio del PIN del admin por el dueño también revoca las
-- sesiones de ese administrador. (Cuerpo de auditoria.sql, con su
-- fila 'pin_admin_reiniciado', + la revocación.)
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
  perform pr_revocar_sesiones(adm.id);
  select * into emp from empresas where id = p_empresa;
  perform pr_registrar_accion(p_empresa, p_quien, 'pin_admin_reiniciado',
    format('Reinició el PIN del administrador %s de la empresa «%s»', adm.codigo, emp.nombre));
  return adm.codigo;
end;
$$;

-- ================================================================
-- 10. OPCIONES: CUPO SIN NEGATIVOS (mayor 6)
-- ================================================================
do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'opciones_empresa_cupo_no_negativo') then
    alter table opciones_empresa
      add constraint opciones_empresa_cupo_no_negativo
      check (rutas_empresa_por_dia is null or rutas_empresa_por_dia >= 0);
  end if;
end $$;

-- Cuerpo de permisos-crud.sql + validación del cupo (y de los días
-- para anotar, que ya existía) + token del actor cuando viene.
drop function if exists pr_actualizar_opciones(uuid, jsonb);
drop function if exists pr_actualizar_opciones(uuid, jsonb, uuid);
drop function if exists pr_actualizar_opciones(uuid, jsonb, uuid, text);
create or replace function pr_actualizar_opciones(p_empresa uuid, p_cambios jsonb,
                                                  p_quien uuid default null,
                                                  p_token text default null)
returns opciones_empresa language plpgsql security definer as $$
declare
  o opciones_empresa;
  claves text;
begin
  perform pr_exigir_no_dueno(p_quien);
  if p_quien is not null then
    perform pr_validar_token(p_quien, p_token);
  end if;
  if p_cambios ? 'diasParaAnotar' and p_cambios ->> 'diasParaAnotar' is not null
     and (p_cambios ->> 'diasParaAnotar')::int not between 0 and 30 then
    raise exception 'Los días para anotar deben estar entre 0 y 30';
  end if;
  if p_cambios ? 'rutasEmpresaPorDia' and p_cambios ->> 'rutasEmpresaPorDia' is not null
     and (p_cambios ->> 'rutasEmpresaPorDia')::int < 0 then
    raise exception 'El cupo de rutas de empresa por día no puede ser negativo';
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
