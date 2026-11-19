-- =====================================================================
-- RutaNeto · El dueño NO aparece en el registro de las empresas
-- (orden de Miguel, 2026-11-19)
--
-- El registro de cada empresa es SUYO, para protegerse ella: solo debe
-- mostrar los movimientos de su propia gente. Las acciones del dueño
-- (superadmin: crear la empresa, licencias, reiniciar el PIN del admin,
-- entrar en modo consulta…) se siguen GUARDANDO en registro_acciones y
-- el dueño las sigue viendo TODAS en su registro global
-- (pr_admin_registro, sin filtro), pero pr_registro_empresa deja de
-- mostrárselas a la empresa.
--
-- Cambio único: en la consulta de pr_registro_empresa se excluyen las
-- filas cuyo actor es el superadmin. Nada más se toca.
-- =====================================================================

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
        and r.actor_rol is distinct from 'superadmin'  -- el dueño es invisible para la empresa
      order by r.creada_en desc
      limit greatest(coalesce(p_limite, 200), 0)
    ) t
  ), '[]'::jsonb);
end;
$$;
