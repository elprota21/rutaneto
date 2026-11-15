-- Pago por Rutas — borrar empresa del dueño (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + semilla.sql +
-- app-datos.sql + ajustes-2026-11-15.sql + acceso-roles.sql +
-- auditoria.sql + caducidad.sql + permisos-dueno.sql +
-- permisos-crud.sql + app-novedades.sql.
-- No reescribe aquellos archivos: todo va con create or replace /
-- if not exists, así que correrlo de nuevo no rompe nada.
--
-- Pedido de Miguel (2026-11-15): en SU panel (el del dueño) debe
-- existir la opción de BORRAR una empresa, con confirmación de
-- seguridad, y al borrarla su licencia queda CANCELADA: nadie de esa
-- empresa puede seguir entrando, ni al panel ni a la app.
--
-- Qué trae:
--   1. pr_admin_borrar_empresa(p_empresa, p_quien): SOLO superadmin
--      (pr_exigir_superadmin, como crear empresa o gestionar
--      licencias). Es una función DEL DUEÑO sobre el contrato, no una
--      operación dentro de la empresa: la regla «el dueño no opera
--      dentro de la empresa» (permisos-dueno.sql) NO aplica aquí.
--   2. Diseño del borrado: BORRADO FÍSICO. La fila de `empresas` se
--      elimina y con ella TODO lo de la empresa: su licencia
--      (cancelada de forma definitiva: deja de existir, y sin empresa
--      ni usuarios nadie puede entrar), opciones, feriados, usuarios,
--      clientes, rutas, anotaciones, vouchers y sus filas del
--      registro. Las tablas con FK sin cascada hacia las demás
--      (voucher_detalle, anotaciones, vouchers, reportes) se borran
--      primero a mano y en orden; el resto cae con la cascada. Por eso
--      la empresa desaparece de pr_admin_resumen y de cualquier
--      listado sin tocar esas funciones, y el acceso se corta al
--      instante: pr_iniciar_sesion ya no encuentra a sus usuarios y
--      pr_licencia_ok ya no encuentra su licencia. No se deshace.
--   3. Lápida `empresas_eliminadas`: antes de borrar se guarda el
--      nombre de la empresa y los CÓDIGOS de sus usuarios (sin FK a
--      empresas: sobrevive al borrado). Sirve para que el login de un
--      ex usuario de esa empresa responda con un mensaje claro —
--      «Esta empresa fue eliminada de RutaNeto» — en vez del genérico
--      «Código o PIN incorrecto». No guarda PIN ni datos personales;
--      los nombres de los usuarios NO se guardan, solo sus códigos.
--   4. pr_iniciar_sesion (copia fiel de la versión vigente de
--      caducidad.sql — contexto por puerta, registro de auditoría y
--      diasRestantes/porVencer intactos): el ÚNICO cambio es la rama
--      de «sin candidatos», que consulta la lápida antes de dar el
--      error genérico. La lápida solo manda si el código ya NO
--      pertenece a ningún usuario vivo: si otra empresa registra
--      después un usuario con el mismo código, ese usuario entra con
--      normalidad y la lápida no estorba.
--   5. Auditoría: el borrado queda en el registro GLOBAL
--      (registro_acciones con empresa_id null, para que la fila
--      sobreviva a la cascada) con el actor y el detalle
--      «Empresa eliminada: <nombre> — licencia cancelada». Se ve en
--      pr_admin_registro sin filtro de empresa.

-- ============ 1. LÁPIDA DE EMPRESAS ELIMINADAS ============
-- Sin FK a `empresas` a propósito: la empresa deja de existir y la
-- lápida tiene que sobrevivir. `eliminada_por` sí referencia a
-- usuarios (el superadmin sigue existiendo) con set null.
create table if not exists empresas_eliminadas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  codigos text[] not null default '{}',
  eliminada_por uuid references usuarios(id) on delete set null,
  eliminada_en timestamptz not null default now()
);
-- RLS activa como el resto: el acceso real pasa por las funciones pr_*.
alter table empresas_eliminadas enable row level security;

-- ============ 2. BORRAR EMPRESA (solo el dueño) ============
-- Devuelve un resumen de lo borrado para que el panel confirme:
-- {empresa, usuarios, licenciaCancelada: true}.
create or replace function pr_admin_borrar_empresa(p_empresa uuid, p_quien uuid)
returns jsonb language plpgsql security definer as $$
declare
  emp empresas;
  v_codigos text[];
  v_usuarios int;
begin
  -- Solo el dueño de RutaNeto (superadmin). Cualquier otro rol recibe
  -- «Solo el administrador de RutaNeto puede hacer esto».
  perform pr_exigir_superadmin(p_quien);

  select * into emp from empresas where id = p_empresa;
  if emp.id is null then
    raise exception 'Esa empresa no existe (¿ya fue eliminada?)';
  end if;

  -- Foto para la lápida ANTES de borrar: nombre y códigos (en
  -- mayúsculas, como los compara el login) de todos sus usuarios.
  select coalesce(array_agg(upper(codigo)), '{}'::text[]), count(*)
  into v_codigos, v_usuarios
  from usuarios where empresa_id = p_empresa;

  insert into empresas_eliminadas (nombre, codigos, eliminada_por)
  values (emp.nombre, v_codigos, p_quien);

  -- Borrado físico. OJO: la cascada sola NO basta —
  -- voucher_detalle.anotacion_id referencia a anotaciones SIN acción
  -- de borrado, y PostgreSQL rechaza la cascada si el detalle del
  -- voucher se borra después que su anotación. Por eso primero se
  -- borran a mano, en orden de dependencia, las tablas con FK sin
  -- cascada hacia lo demás, y al final la empresa, cuya cascada se
  -- lleva el resto (licencia, opciones, feriados, usuarios, clientes
  -- y rutas). La licencia queda cancelada: deja de existir junto a
  -- la empresa y ningún usuario suyo puede volver a entrar.
  delete from voucher_detalle
  where voucher_id in (select id from vouchers where empresa_id = p_empresa);
  delete from reportes where empresa_id = p_empresa;
  delete from anotaciones where empresa_id = p_empresa;
  delete from vouchers where empresa_id = p_empresa;
  delete from registro_acciones where empresa_id = p_empresa;
  delete from empresas where id = p_empresa;

  -- Registro GLOBAL (empresa_id null): la fila sobrevive a la cascada
  -- y se ve en pr_admin_registro sin filtro.
  perform pr_registrar_accion(null, p_quien, 'empresa_eliminada',
    format('Empresa eliminada: %s — licencia cancelada', emp.nombre));

  return jsonb_build_object(
    'empresa', emp.nombre,
    'usuarios', v_usuarios,
    'licenciaCancelada', true
  );
end;
$$;

-- ============ 3. INICIO DE SESIÓN (caducidad, con lápida) ============
-- Copia fiel de la versión de caducidad.sql (que a su vez trae la de
-- auditoria.sql/acceso-roles.sql: p_contexto, registro de
-- 'inicio_sesion' y diasRestantes/porVencer). El ÚNICO cambio es la
-- rama de «sin candidatos»: si el código quedó en la lápida de una
-- empresa eliminada y ya no es de ningún usuario vivo, el mensaje es
-- «Esta empresa fue eliminada de RutaNeto».
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
    -- ¿El código era de una empresa ELIMINADA por el dueño? La lápida
    -- guarda sus códigos; solo manda si el código ya no pertenece a
    -- ningún usuario vivo (otra empresa pudo registrarlo después).
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
      'diasRestantes', case when lic.vence is null then null
                            else lic.vence - current_date end,
      'porVencer', case when lic.vence is null then false
                        else (lic.vence - current_date) between 0 and 30 end,
      'ok', true
    )
  );
end;
$$;
