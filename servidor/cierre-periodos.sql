-- ================================================================
-- CIERRE DE PERÍODOS — FASE 2 de la preparación para la venta
-- (auditoría integral acordada con Miguel el 2026-11-19: «cierre de
-- períodos + registro con valor anterior/nuevo y motivo»; esta
-- pieza es el CIERRE. El registro con antes/después es la pieza
-- siguiente y NO va aquí.)
-- ================================================================
-- PROBLEMA QUE RESUELVE: hoy un período ya pagado sigue «vivo».
-- Nada impide anotar una ruta con fecha del mes pasado, validar
-- una especial vieja, resolver un conflicto viejo, rechazar una
-- anotación ya incluida en un voucher, anular el voucher o generar
-- otro: cualquiera de esos movimientos cambia la nómina DESPUÉS de
-- pagada, sin dejar rastro del porqué. Para vender bajo contrato
-- eso es inaceptable: lo pagado tiene que quedar congelado.
--
-- QUÉ HACE ESTE ARCHIVO:
--   0) Tabla `periodos_cerrados`: un cierre = un rango de fechas
--      [desde, hasta] de UNA empresa. Sin solapes entre cierres de
--      la misma empresa (lo garantiza pr_cerrar_periodo).
--   1) Ayudantes: ¿una fecha cae en un período cerrado? ¿un rango
--      de voucher se cruza con un período cerrado?
--   2) pr_cerrar_periodo / pr_reabrir_periodo: solo administración
--      (empresa/coordinador) DE esa empresa, con token; el dueño
--      NO opera dentro de la empresa (su regla: solo consulta).
--      Cerrar EXIGE: sin conflictos ni especiales pendientes en el
--      rango, y todo chofer con rutas aprobadas ya con su voucher
--      activo que cubra el período completo. Reabrir EXIGE motivo
--      y queda en el registro. Cerrar también queda en el registro
--      con el total pagado en vouchers del período.
--   3) La guarda en cada mutación que toca un período cerrado:
--        pr_anotar_ruta / pr_anotar_especial   (fecha cerrada)
--        pr_validar_especial                   (su fecha)
--        pr_resolver_conflicto                 (su fecha)
--        pr_rechazar_anotacion                 (su fecha)
--        pr_generar_voucher                    (rango que se cruce;
--                                               si ya existe el voucher
--                                               activo de ese rango,
--                                               se sigue devolviendo:
--                                               mostrarlo no muta nada)
--        pr_anular_voucher                     (su rango se cruza)
--      Son COPIAS FIELES de las versiones vigentes (correcciones-
--      venta.sql; pr_validar_especial de permisos-dueno.sql) con
--      la guarda añadida y marcada «FASE 2» en comentario.
--   4) pr_snapshot gana la clave `periodosCerrados` (copia fiel de
--      hora-rutas.sql + esa clave): el panel pinta el candado y
--      ofrece cerrar/reabrir desde Pagos.
--
-- LO QUE NO HACE (a propósito):
--   - No congela lecturas: pr_resumen_periodo, pr_resumen_chofer,
--     pr_mi_ganado y pr_datos_chofer siguen mostrando el período
--     cerrado (consultar lo pagado es legítimo y necesario).
--   - No toca asignaciones, rutas, clientes, usuarios ni opciones:
--     el cierre congela el DINERO del período, no el catálogo.
--   - No cierra nada por su cuenta: ningún período nace cerrado;
--     alguien de la empresa tiene que cerrarlo desde el panel.
--
-- COMPATIBILIDAD: sin firmas nuevas en las funciones existentes
-- (las dos de gestión son nuevas). Idempotente: se puede reaplicar.
-- NO APLICAR A PRODUCCIÓN SIN LA APROBACIÓN DE MIGUEL.

-- ================================================================
-- 0. TABLA DE PERÍODOS CERRADOS
-- ================================================================
create table if not exists periodos_cerrados (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references empresas(id) on delete cascade,
  desde date not null,
  hasta date not null,
  cerrado_por uuid references usuarios(id),
  cerrado_en timestamptz not null default now(),
  motivo text,
  constraint periodos_cerrados_rango_valido check (desde <= hasta)
);
create index if not exists idx_periodos_cerrados_empresa
  on periodos_cerrados(empresa_id, desde, hasta);
alter table periodos_cerrados enable row level security;

-- ================================================================
-- 1. AYUDANTES
-- ================================================================
-- ¿La fecha cae dentro de un período cerrado de la empresa?
create or replace function pr_periodo_cerrado(p_empresa uuid, p_fecha date)
returns boolean language sql stable security definer as $$
  select exists (
    select 1 from periodos_cerrados pc
    where pc.empresa_id = p_empresa
      and p_fecha between pc.desde and pc.hasta
  );
$$;

-- Falla con mensaje claro si la fecha está en un período cerrado.
create or replace function pr_exigir_periodo_abierto(p_empresa uuid, p_fecha date)
returns void language plpgsql stable security definer as $$
declare pc periodos_cerrados;
begin
  select * into pc from periodos_cerrados
  where empresa_id = p_empresa and p_fecha between desde and hasta
  order by desde
  limit 1;
  if pc.id is not null then
    raise exception 'Período cerrado: el % está dentro del período cerrado del % al %. Reabre el período para hacer cambios.',
      to_char(p_fecha, 'DD/MM/YYYY'),
      to_char(pc.desde, 'DD/MM/YYYY'),
      to_char(pc.hasta, 'DD/MM/YYYY');
  end if;
end;
$$;

-- Falla si el rango [p_desde, p_hasta] se cruza con un período
-- cerrado (para vouchers: su rango completo debe estar abierto).
create or replace function pr_exigir_rango_abierto(p_empresa uuid, p_desde date, p_hasta date)
returns void language plpgsql stable security definer as $$
declare pc periodos_cerrados;
begin
  select * into pc from periodos_cerrados
  where empresa_id = p_empresa and desde <= p_hasta and p_desde <= hasta
  order by desde
  limit 1;
  if pc.id is not null then
    raise exception 'Período cerrado: el rango del % al % se cruza con el período cerrado del % al %. Reabre el período para hacer cambios.',
      to_char(p_desde, 'DD/MM/YYYY'),
      to_char(p_hasta, 'DD/MM/YYYY'),
      to_char(pc.desde, 'DD/MM/YYYY'),
      to_char(pc.hasta, 'DD/MM/YYYY');
  end if;
end;
$$;

-- ================================================================
-- 2. CERRAR Y REABRIR (solo administración de la empresa)
-- ================================================================
-- Cerrar un período lo congela: desde ese momento el servidor
-- rechaza anotar, validar, resolver, rechazar, generar o anular
-- dentro del rango (sección 3). Para poder cerrar:
--   - el rango no puede cruzarse con otro período ya cerrado;
--   - no pueden quedar conflictos ni rutas especiales pendientes
--     con fecha en el rango (hay que resolverlos antes);
--   - todo chofer con rutas aprobadas en el rango debe tener ya
--     su voucher ACTIVO que cubra el período completo (si no, el
--     cierre dejaría trabajo aprobado sin comprobante y sin forma
--     de generarlo después).
-- El cierre queda en el registro con el total pagado del período.
create or replace function pr_cerrar_periodo(p_empresa uuid, p_desde date, p_hasta date,
                                             p_quien uuid, p_token text default null,
                                             p_motivo text default null)
returns periodos_cerrados language plpgsql security definer as $$
declare
  q usuarios;
  pc periodos_cerrados;
  v_pendientes int;
  v_sin_voucher int;
  v_aprobadas int;
  v_total numeric;
begin
  perform pr_exigir_no_dueno(p_quien);
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);
  if q.rol not in ('empresa','coordinador') or q.empresa_id is distinct from p_empresa then
    raise exception 'Solo la administración de esta empresa puede cerrar un período';
  end if;
  if p_desde is null or p_hasta is null or p_desde > p_hasta then
    raise exception 'El período no es válido: revisa las fechas';
  end if;

  -- Un cierre por empresa a la vez (la transacción libera el
  -- bloqueo al terminar): dos cierres simultáneos no se cuelan.
  perform pg_advisory_xact_lock(hashtextextended('rutaneto-periodo-' || p_empresa::text, 0));

  if exists (select 1 from periodos_cerrados
             where empresa_id = p_empresa and desde <= p_hasta and p_desde <= hasta) then
    raise exception 'Ese período se cruza con otro período ya cerrado';
  end if;

  select count(*) into v_pendientes from anotaciones
  where empresa_id = p_empresa and fecha between p_desde and p_hasta
    and estado in ('conflicto','especial_pendiente');
  if v_pendientes > 0 then
    raise exception 'No se puede cerrar: quedan % anotación(es) sin resolver en el período (conflictos o rutas especiales pendientes)', v_pendientes;
  end if;

  select count(*) into v_sin_voucher
  from (select distinct a.chofer_id from anotaciones a
        where a.empresa_id = p_empresa and a.estado = 'aprobada'
          and a.fecha between p_desde and p_hasta) s
  where not exists (
    select 1 from vouchers v
    where v.empresa_id = p_empresa and v.chofer_id = s.chofer_id
      and not v.anulado and v.desde <= p_desde and v.hasta >= p_hasta
  );
  if v_sin_voucher > 0 then
    raise exception 'No se puede cerrar: % chofer(es) tienen rutas aprobadas sin voucher en el período. Genera los vouchers antes de cerrar.', v_sin_voucher;
  end if;

  select count(*) into v_aprobadas from anotaciones
  where empresa_id = p_empresa and estado = 'aprobada'
    and fecha between p_desde and p_hasta;
  select coalesce(sum(total), 0) into v_total from vouchers
  where empresa_id = p_empresa and not anulado
    and desde >= p_desde and hasta <= p_hasta;

  insert into periodos_cerrados (empresa_id, desde, hasta, cerrado_por, motivo)
  values (p_empresa, p_desde, p_hasta, p_quien,
          nullif(trim(coalesce(p_motivo, '')), ''))
  returning * into pc;

  perform pr_registrar_accion(p_empresa, p_quien, 'periodo_cerrado',
    format('Cerró el período del %s al %s (%s rutas aprobadas; total en vouchers: RD$%s)%s',
           to_char(p_desde, 'DD/MM/YYYY'), to_char(p_hasta, 'DD/MM/YYYY'),
           v_aprobadas, to_char(v_total, 'FM999,999,990.00'),
           case when pc.motivo is not null
                then format('. Motivo: %s', pc.motivo) else '' end));
  return pc;
end;
$$;

-- Reabrir devuelve el período a la vida (se podrán anotar, validar
-- y generar de nuevo). Exige motivo y queda en el registro: una
-- reapertura sin explicación es justo lo que la auditoría prohibe.
create or replace function pr_reabrir_periodo(p_periodo uuid, p_quien uuid,
                                              p_motivo text, p_token text default null)
returns void language plpgsql security definer as $$
declare
  pc periodos_cerrados;
  q usuarios;
begin
  select * into pc from periodos_cerrados where id = p_periodo;
  if pc.id is null then raise exception 'Ese período cerrado no existe'; end if;
  perform pr_exigir_no_dueno(p_quien);
  select * into q from usuarios where id = p_quien and activo;
  if q.id is null then raise exception 'Usuario no válido'; end if;
  perform pr_validar_token(p_quien, p_token);
  if q.rol not in ('empresa','coordinador') or q.empresa_id is distinct from pc.empresa_id then
    raise exception 'Solo la administración de esta empresa puede reabrir un período';
  end if;
  if p_motivo is null or length(trim(p_motivo)) = 0 then
    raise exception 'Para reabrir un período indica el motivo';
  end if;
  delete from periodos_cerrados where id = p_periodo;
  perform pr_registrar_accion(pc.empresa_id, p_quien, 'periodo_reabierto',
    format('Reabrió el período del %s al %s. Motivo: %s',
           to_char(pc.desde, 'DD/MM/YYYY'), to_char(pc.hasta, 'DD/MM/YYYY'),
           trim(p_motivo)));
end;
$$;

-- ================================================================
-- 3. LA GUARDA EN LAS MUTACIONES (copias fieles + FASE 2)
-- ================================================================
-- Cada función de esta sección es la versión VIGENTE hoy en
-- producción con UNA línea añadida (marcada «FASE 2»): la guarda
-- del período cerrado. Nada más cambia.

-- ---- 3a. ANOTAR RUTA NORMAL (copia de correcciones-venta.sql) ----
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
  -- FASE 2: no se anota con fecha de un período cerrado.
  perform pr_exigir_periodo_abierto(p_empresa, v_fecha);
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

-- ---- 3b. ANOTAR RUTA ESPECIAL (copia de correcciones-venta.sql) ----
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
  -- FASE 2: no se anota con fecha de un período cerrado.
  perform pr_exigir_periodo_abierto(p_empresa, v_fecha);
  insert into anotaciones (empresa_id, chofer_id, cliente_id, tipo, descripcion, nota, fecha, clase, estado, precio_aplicado)
  values (p_empresa, p_chofer, p_cliente, 'especial', p_descripcion, p_nota, v_fecha, 'extra', 'especial_pendiente', null)
  returning * into nueva;
  return nueva;
end;
$$;

-- ---- 3c. VALIDAR RUTA ESPECIAL (copia de permisos-dueno.sql) ----
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
  -- FASE 2: una especial de un período cerrado ya no se valida ni
  -- se rechaza: su fecha quedó congelada al cerrar.
  perform pr_exigir_periodo_abierto(a.empresa_id, a.fecha);
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

-- ---- 3d. RESOLVER CONFLICTO (copia de correcciones-venta.sql) ----
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
  -- FASE 2: un conflicto de un período cerrado quedó congelado al
  -- cerrar (de hecho, cerrar exige no dejar conflictos pendientes).
  perform pr_exigir_periodo_abierto(a.empresa_id, a.fecha);

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

-- ---- 3e. RECHAZAR ANOTACIÓN (copia de correcciones-venta.sql) ----
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
  -- FASE 2: una anotación de un período cerrado no se rechaza:
  -- si ya se pagó, su voucher la respalda tal como quedó.
  perform pr_exigir_periodo_abierto(a.empresa_id, a.fecha);
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

-- ---- 3f. GENERAR VOUCHER (copia de correcciones-venta.sql) ----
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

  -- FASE 2: generar un voucher NUEVO cuyo rango se cruce con un
  -- período cerrado queda prohibido (el período ya se cerró con
  -- sus vouchers; uno nuevo cambiaría lo pagado). El «return» de
  -- arriba va ANTES a propósito: mostrar el voucher ya existente
  -- de un período cerrado no muta nada y debe seguir funcionando.
  perform pr_exigir_rango_abierto(p_empresa, p_desde, p_hasta);

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

-- ---- 3g. ANULAR VOUCHER (copia de correcciones-venta.sql) ----
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
  -- FASE 2: anular un voucher de un período cerrado desharía lo
  -- pagado; primero hay que reabrir el período (con motivo).
  perform pr_exigir_rango_abierto(v.empresa_id, v.desde, v.hasta);
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
-- 4. SNAPSHOT: LOS PERÍODOS CERRADOS VIAJAN AL PANEL
-- ================================================================
-- Copia fiel de hora-rutas.sql + la clave `periodosCerrados`
-- (id, rango, quién cerró, cuándo y motivo): el panel pinta el
-- candado en Pagos y desde ahí se cierra y se reabre.
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
        'precio', r.precio, 'activa', r.activa,
        'hora', to_char(r.hora, 'HH24:MI'))
        order by r.codigo)
      from rutas r where r.empresa_id = emp
    ), '[]'::jsonb),
    'asignaciones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'choferId', ar.chofer_id, 'rutaId', ar.ruta_id, 'dias', ar.dias_semana)
        order by ar.chofer_id, ar.ruta_id)
      from asignaciones_ruta ar where ar.empresa_id = emp
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
    ), '[]'::jsonb),
    -- FASE 2: los períodos cerrados de la empresa, del más
    -- reciente al más antiguo.
    'periodosCerrados', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'desde', to_char(pc.desde, 'YYYY-MM-DD'),
        'hasta', to_char(pc.hasta, 'YYYY-MM-DD'),
        'cerradoPorId', pc.cerrado_por,
        'cerradoPorNombre', cu.nombre,
        'cerradoEn', pc.cerrado_en,
        'motivo', pc.motivo)
        order by pc.desde desc)
      from periodos_cerrados pc
      left join usuarios cu on cu.id = pc.cerrado_por
      where pc.empresa_id = emp
    ), '[]'::jsonb)
  );
end;
$$;
