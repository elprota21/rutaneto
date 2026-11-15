-- Pago por Rutas — novedades en vivo para la APP (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql + conexion.sql + app-datos.sql +
-- ajustes-2026-11-15.sql (la tabla `reportes` vive en ajustes). Es
-- idempotente: las funciones se eliminan/recrean con la MISMA firma;
-- correrlo dos veces no rompe nada.
--
-- Por qué existe: la app 1.4.0 sondea pr_datos_chofer cada 30 s para
-- estar EN VIVO y avisar al usuario con notificación (sonido y
-- vibración) cuando pasa algo suyo. Para detectar esos cambios la foto
-- del chofer necesitaba tres cosas que hoy no baja:
--
--   autorNombre:        TODA lista de reportes lleva el nombre real
--                       de quien lo envió (reportes, reportesPendientes
--                       y pr_listar_reportes, redefinida abajo): en la
--                       app y en el panel un reporte de coordinador se
--                       ve «<Nombre> · Coordinador», nunca una etiqueta
--                       genérica sin nombre.
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
--                       un chofer reporta algo.
--
-- EL COORDINADOR TAMBIÉN HACE RUTAS (pedido de Miguel, 2026-11-15):
-- muchas veces los coordinadores también salen a ruta, así que su foto
-- deja de ser la mínima de reportes: pr_datos_chofer le devuelve LO
-- MISMO que a un chofer (clientes, rutas, SUS anotaciones, SUS
-- vouchers, SUS reportes) MÁS reportesPendientes. Lo demás ya lo
-- permitía el servidor y aquí solo se amplía donde hacía falta:
--   - pr_anotar_ruta / pr_anotar_especial nunca validaron el rol del
--     anotador: el coordinador ya podía anotar, con el mismo cupo
--     diario (pr_clase_del_dia), el mismo plazo y el mismo antifraude
--     (su anotación puede entrar en conflicto con la de un chofer y
--     viceversa). Sin cambios.
--   - pr_resumen_chofer / pr_mi_ganado no filtran por rol: el ganado
--     del coordinador ya se calculaba. Sin cambios.
--   - pr_generar_voucher recibe el usuario directo, sin filtro de
--     rol: ya podía generar el voucher de un coordinador. Sin cambios.
--   - pr_resumen_periodo SÍ filtraba rol = 'chofer': se recrea para
--     incluir a los coordinadores QUE TENGAN anotaciones en el
--     período (los demás coordinadores no aparecen; los choferes
--     salen como siempre, tengan o no anotaciones).
--
-- Compatibilidad: la app 1.3.0 desplegada ignora las claves nuevas y
-- sigue funcionando (las claves actuales quedan intactas, con los
-- mismos nombres y formato). Los roles de oficina (empresa) y el
-- superadmin siguen rechazados en pr_datos_chofer con el mismo
-- mensaje de antes.

-- ============ EMPRESA OPERATIVA: LA VERIFICACIÓN DE TODA LA APP ============
-- TODAS las operaciones de la app (ver datos, anotar ruta, ruta
-- especial, enviar reporte) exigen empresa ACTIVA y licencia vigente,
-- con mensajes claros y distintos — los mismos de pr_iniciar_sesion.
-- (Antes, anotar/especial/reporte solo miraban pr_licencia_ok y
-- rechazaban todo con el mensaje genérico «Licencia inactiva», y
-- pr_datos_chofer ni siquiera miraba: con la empresa desactivada la
-- app seguía mostrando las rutas como si nada.)
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
  if lic.estado = 'vencida' or (lic.vence is not null and lic.vence < current_date) then
    raise exception 'La licencia de tu empresa está vencida. Contacta a RutaNeto para renovarla.';
  end if;
end;
$$;

drop function if exists pr_datos_chofer(uuid, uuid);

create function pr_datos_chofer(p_empresa uuid, p_chofer uuid)
returns jsonb language plpgsql stable security definer as $$
declare
  u usuarios;
  foto jsonb;
begin
  select * into u from usuarios
  where id = p_chofer and empresa_id = p_empresa and activo
    and rol in ('chofer', 'coordinador');
  if u.id is null then
    raise exception 'Chofer no encontrado en esta empresa';
  end if;

  -- Empresa activa y licencia vigente: la app persiste la sesión en
  -- el teléfono y revalida contra esta función al reabrir (y en cada
  -- sondeo); si la empresa se desactivó o la licencia venció/se
  -- suspendió, la app expulsa la sesión guardada con ese mensaje.
  perform pr_exigir_empresa_operativa(p_empresa);

  -- La foto completa, igual para chofer y coordinador: el coordinador
  -- también hace rutas y ve sus clientes, rutas, anotaciones,
  -- vouchers y reportes como cualquier chofer.
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

-- ============ RESUMEN DEL PERÍODO: TAMBIÉN EL COORDINADOR QUE HACE RUTAS ============
-- Igual que en conexion.sql, pero la fila de usuarios incluye a los
-- coordinadores CON anotaciones en el período (si un coordinador no
-- hizo rutas en el período, no aparece; la empresa y el superadmin
-- nunca aparecen). Los choferes salen como siempre.
create or replace function pr_resumen_periodo(p_empresa uuid, p_desde date, p_hasta date)
returns table (chofer_id uuid, num_empresa int, num_extra int,
               total_empresa numeric, total_extra numeric, total numeric)
language sql stable security definer as $$
  select u.id, r.num_empresa, r.num_extra, r.total_empresa, r.total_extra, r.total
  from usuarios u
  cross join lateral pr_resumen_chofer(p_empresa, u.id, p_desde, p_hasta) r
  where u.empresa_id = p_empresa
    and (u.rol = 'chofer'
         or (u.rol = 'coordinador' and exists (
               select 1 from anotaciones a
               where a.empresa_id = p_empresa and a.chofer_id = u.id
                 and a.fecha between p_desde and p_hasta)))
  order by u.nombre;
$$;

-- ============ REPORTES DEL PANEL: CON EL NOMBRE DEL AUTOR ============
-- pr_listar_reportes (de ajustes-2026-11-15.sql) redefinida SIN
-- cambiar firma ni campos: cada reporte suma `autorNombre` (el
-- nombre real de quien lo envió; el objeto `autor` anidado se
-- mantiene). Así el panel puede mostrar «<Nombre> · Coordinador»
-- en vez de una etiqueta genérica.
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
        'autorNombre', u.nombre,
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

-- ============ EL SALDO DEL CHOFER: SECURITY DEFINER (ARREGLO) ============
-- BUG (reportado por Miguel): «el saldo no le aparece a los choferes
-- aunque la opción esté activa». Causa: pr_resumen_chofer y
-- pr_mi_ganado eran las ÚNICAS funciones que la app llama por
-- PostgREST SIN `security definer`. La app entra con la clave anónima
-- y TODAS las tablas tienen RLS sin políticas (el acceso real es por
-- las funciones definer), así que esas dos corrían como `anon`, no
-- veían ni una fila de `anotaciones`/`opciones_empresa` y devolvían
-- total 0 / conteos 0: la app pintaba «RD$0» aunque el chofer tuviera
-- extras aprobadas. En las pruebas locales no se veía porque corren
-- como superusuario, que salta la RLS. Se redefinen IGUAL que en
-- esquema.sql, solo añadiendo `security definer` (la regla del
-- proyecto). pr_resumen_periodo (panel) no sufría el bug: es definer
-- y su llamada interna a pr_resumen_chofer ya corría como dueño.
create or replace function pr_resumen_chofer(p_empresa uuid, p_chofer uuid, p_desde date, p_hasta date)
returns table (num_empresa int, num_extra int, total_empresa numeric, total_extra numeric, total numeric)
language sql stable security definer as $$
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

create or replace function pr_mi_ganado(p_empresa uuid, p_chofer uuid)
returns table (modo text, desde date, hasta date, total numeric)
language plpgsql stable security definer as $$
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

-- ============ ANOTAR Y REPORTAR: TAMBIÉN CON EMPRESA OPERATIVA ============
-- pr_anotar_ruta, pr_anotar_especial y pr_enviar_reporte redefinidas
-- con el cuerpo de ajustes-2026-11-15.sql, cambiando SOLO la
-- verificación inicial: en vez del genérico «Licencia inactiva» de
-- pr_licencia_ok, ahora pr_exigir_empresa_operativa distingue
-- empresa inactiva / sin licencia / suspendida / vencida, para que
-- la app pueda expulsar la sesión con el mensaje exacto.
create or replace function pr_anotar_ruta(p_empresa uuid, p_chofer uuid, p_ruta uuid,
                                          p_fecha date default current_date, p_nota text default null)
returns anotaciones language plpgsql security definer as $$
declare
  r rutas;
  nueva anotaciones;
  duplicada boolean;
begin
  perform pr_exigir_empresa_operativa(p_empresa);
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
  perform pr_exigir_empresa_operativa(p_empresa);
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
  perform pr_exigir_empresa_operativa(p_empresa);

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
