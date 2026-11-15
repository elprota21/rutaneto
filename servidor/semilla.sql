-- Pago por Rutas — semilla OFICIAL de arranque (PostgreSQL / Supabase)
-- Se aplica DESPUÉS de esquema.sql y conexion.sql.
--
-- Crea la empresa Servivans con licencia activa, sus usuarios (todos con
-- PIN 1234, guardado con hash de pr_hash_pin), sus empresas cliente, sus
-- rutas y actividad de HOY (CURRENT_DATE) para que el sistema se vea vivo
-- desde el primer inicio de sesión.
--
-- Es idempotente: todos los ids son fijos y cada insert lleva
-- ON CONFLICT (id) DO NOTHING — correrlo dos veces no duplica nada
-- (y no pisa PIN ni precios que ya se hayan cambiado).
--
-- Accesos iniciales (código / PIN 1234):
--   MIGUEL  superadmin (sin empresa)      ADMIN  administrador de Servivans
--   COORD   coordinador de Servivans     CH-01  Carlos Méndez (chofer)
--   CH-02   José Ramírez (chofer)        CH-03  Luis Peña (chofer)

begin;

-- ============ EMPRESA Y LICENCIA ============
insert into empresas (id, nombre, activa) values
  ('a0000000-0000-0000-0000-000000000001', 'Servivans', true)
on conflict (id) do nothing;

-- Licencia activa: vence en 1 año, hasta 15 choferes.
insert into licencias (id, empresa_id, estado, vence, max_choferes) values
  ('a0000000-0000-0000-0000-000000000501', 'a0000000-0000-0000-0000-000000000001',
   'activa', current_date + interval '1 year', 15)
on conflict (id) do nothing;

-- Opciones por defecto: 5 rutas de empresa por día (las del sueldo),
-- el chofer ve todo su ganado, voucher en la app y botón de ruta especial
-- activos, fines de semana y feriados NO son extra por defecto.
insert into opciones_empresa (empresa_id, ver_ganado, voucher_app, boton_especial,
  rutas_empresa_por_dia, sabado_extra, domingo_extra, feriado_extra, limite_anotacion) values
  ('a0000000-0000-0000-0000-000000000001', 'todo', true, true, 5, false, false, false, 'hoy_y_ayer')
on conflict (empresa_id) do nothing;

-- ============ USUARIOS (PIN 1234 para todos, con hash) ============
insert into usuarios (id, empresa_id, rol, nombre, codigo, pin_hash, activo) values
  ('a0000000-0000-0000-0000-000000000101', null,
   'superadmin', 'Miguel Medina', 'MIGUEL', pr_hash_pin('1234'), true),
  ('a0000000-0000-0000-0000-000000000102', 'a0000000-0000-0000-0000-000000000001',
   'empresa', 'Administración Servivans', 'ADMIN', pr_hash_pin('1234'), true),
  ('a0000000-0000-0000-0000-000000000103', 'a0000000-0000-0000-0000-000000000001',
   'coordinador', 'Coordinación Servivans', 'COORD', pr_hash_pin('1234'), true),
  ('a0000000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000001',
   'chofer', 'Carlos Méndez', 'CH-01', pr_hash_pin('1234'), true),
  ('a0000000-0000-0000-0000-000000000105', 'a0000000-0000-0000-0000-000000000001',
   'chofer', 'José Ramírez', 'CH-02', pr_hash_pin('1234'), true),
  ('a0000000-0000-0000-0000-000000000106', 'a0000000-0000-0000-0000-000000000001',
   'chofer', 'Luis Peña', 'CH-03', pr_hash_pin('1234'), true)
on conflict (id) do nothing;

-- ============ EMPRESAS CLIENTE ============
insert into clientes (id, empresa_id, nombre, activo) values
  ('a0000000-0000-0000-0000-000000000201', 'a0000000-0000-0000-0000-000000000001', 'Zona Franca San Isidro', true),
  ('a0000000-0000-0000-0000-000000000202', 'a0000000-0000-0000-0000-000000000001', 'Parque Industrial Duarte', true)
on conflict (id) do nothing;

-- ============ RUTAS (repartidas entre los clientes y General) ============
insert into rutas (id, empresa_id, cliente_id, codigo, nombre, precio, activa) values
  ('a0000000-0000-0000-0000-000000000301', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000201', 'R-01', 'San Isidro — Santo Domingo Centro', 850, true),
  ('a0000000-0000-0000-0000-000000000302', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000201', 'R-02', 'San Isidro — Boca Chica', 600, true),
  ('a0000000-0000-0000-0000-000000000303', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000202', 'R-03', 'Duarte — San Cristóbal', 700, true),
  ('a0000000-0000-0000-0000-000000000304', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000202', 'R-04', 'Duarte — Baní', 950, true),
  ('a0000000-0000-0000-0000-000000000305', 'a0000000-0000-0000-0000-000000000001',
   null, 'R-05', 'Centro — Haina', 550, true)
on conflict (id) do nothing;

-- ============ ACTIVIDAD DE HOY (CURRENT_DATE) ============
-- CH-01 Carlos: tres rutas normales aprobadas (clase empresa: van en su
-- sueldo, constan pero no suman dinero por ruta).
insert into anotaciones (id, empresa_id, chofer_id, ruta_id, cliente_id, tipo, fecha, clase, estado, precio_aplicado) values
  ('a0000000-0000-0000-0000-000000000401', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000301',
   'a0000000-0000-0000-0000-000000000201', 'normal', current_date, 'empresa', 'aprobada', 850),
  ('a0000000-0000-0000-0000-000000000402', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000302',
   'a0000000-0000-0000-0000-000000000201', 'normal', current_date, 'empresa', 'aprobada', 600),
  ('a0000000-0000-0000-0000-000000000403', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000104', 'a0000000-0000-0000-0000-000000000304',
   'a0000000-0000-0000-0000-000000000202', 'normal', current_date, 'empresa', 'aprobada', 950)
on conflict (id) do nothing;

-- CH-02 José: una ruta normal aprobada (empresa) y una especial ya validada
-- por el coordinador (extra: es lo único que suma dinero hoy, RD$1,200).
insert into anotaciones (id, empresa_id, chofer_id, ruta_id, cliente_id, tipo, descripcion, fecha, clase, estado, precio_aplicado, validada_por) values
  ('a0000000-0000-0000-0000-000000000404', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000105', 'a0000000-0000-0000-0000-000000000305',
   null, 'normal', null, current_date, 'empresa', 'aprobada', 550, null),
  ('a0000000-0000-0000-0000-000000000405', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000105', null,
   'a0000000-0000-0000-0000-000000000201', 'especial', 'Traslado extra: personal a la planta norte',
   current_date, 'extra', 'aprobada', 1200, 'a0000000-0000-0000-0000-000000000103')
on conflict (id) do nothing;

-- CONFLICTO sin resolver: CH-02 y CH-03 anotaron la MISMA ruta (R-03,
-- cliente Duarte) hoy. Ninguna suma hasta que el coordinador resuelva
-- (un solo ganador, o «ambas» si la ruta se cubrió entre dos autobuses).
insert into anotaciones (id, empresa_id, chofer_id, ruta_id, cliente_id, tipo, fecha, clase, estado, precio_aplicado) values
  ('a0000000-0000-0000-0000-000000000406', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000105', 'a0000000-0000-0000-0000-000000000303',
   'a0000000-0000-0000-0000-000000000202', 'normal', current_date, 'empresa', 'conflicto', 700),
  ('a0000000-0000-0000-0000-000000000407', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000106', 'a0000000-0000-0000-0000-000000000303',
   'a0000000-0000-0000-0000-000000000202', 'normal', current_date, 'empresa', 'conflicto', 700)
on conflict (id) do nothing;

-- Ruta ESPECIAL pendiente de CH-01: no suma hasta que el coordinador la
-- valide y le ponga precio.
insert into anotaciones (id, empresa_id, chofer_id, ruta_id, cliente_id, tipo, descripcion, nota, fecha, clase, estado, precio_aplicado) values
  ('a0000000-0000-0000-0000-000000000408', 'a0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000104', null,
   'a0000000-0000-0000-0000-000000000202', 'especial', 'Viaje no programado: recoger equipo en el muelle',
   'Salió de urgencia', current_date, 'extra', 'especial_pendiente', null)
on conflict (id) do nothing;

commit;
