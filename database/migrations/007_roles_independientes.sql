-- =============================================================================
--  Migración 007 — Roles independientes por app
--
--  El empleado es UNO para las dos apps (su ficha en asis_empleados), pero la
--  cuenta de acceso da un rol en cada app por separado:
--    Ventario: ADMIN (director), GERENTE, AUXILIAR_INVENTARIO, VENDEDOR
--    Presente: ADMIN, GERENTE, TALENTO_HUMANO, OPERARIO
--  Alguien puede ser gerente en Presente y vendedor en Ventario, o tener
--  acceso a una sola. La única regla común: el administrador (dueño de la
--  empresa) lo es en las dos apps a la vez.
--
--  Reemplaza la regla anterior de 006 (ADMIN y GERENTE iguales en las dos).
--  Cada sentencia tolera haberse aplicado ya.
-- =============================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE usuarios DROP CONSTRAINT IF EXISTS ck_usuarios_roles;

ALTER TABLE usuarios
  ADD CONSTRAINT IF NOT EXISTS ck_usuarios_roles CHECK ((rol <=> 'ADMIN') = (rol_asistencia <=> 'ADMIN'));
