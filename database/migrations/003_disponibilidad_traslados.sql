-- ─────────────────────────────────────────────────────────────────────────────
-- 003 · Disponibilidad entre sedes y despacho de traslados
--
-- Cambia QUIÉN mueve mercancía entre sedes:
--
--   · Cualquier empleado VE en qué sedes hay un producto, cuánto y a qué precio
--     (eso no necesita esquema: es el pull de stock_sedes sin filtrar por sede).
--   · El Gerente de Sede SOLICITA unidades para su sede.
--   · El Director General o el Auxiliar de Inventario de la sede de origen
--     DESPACHAN la solicitud con las unidades que decidan (pueden ser menos de
--     las pedidas), o MUEVEN unidades directamente sin solicitud previa.
--
-- Igual que 002: aditiva y re-ejecutable (migrate.mjs aplica todo cada vez).
-- ─────────────────────────────────────────────────────────────────────────────

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

-- SOLICITUD: la pidió un gerente y espera despacho.
-- DIRECTO:   la movió el director o un auxiliar; nace ya despachada.
ALTER TABLE traslados
  ADD COLUMN IF NOT EXISTS tipo ENUM('SOLICITUD','DIRECTO') NOT NULL DEFAULT 'SOLICITUD' AFTER estado;

-- Lo que de verdad salió. NULL mientras no se despacha (o en traslados
-- anteriores a esta migración, que se despacharon completos). Puede ser menor
-- que lo pedido —o cero para una línea— si en el origen no hay o no conviene.
ALTER TABLE traslado_detalles
  ADD COLUMN IF NOT EXISTS cantidad_enviada DECIMAL(14,3) NULL AFTER cantidad;

-- Los traslados ya aprobados antes de esta migración se movieron completos.
UPDATE traslado_detalles d
  JOIN traslados t ON t.id = d.traslado_id
   SET d.cantidad_enviada = d.cantidad
 WHERE t.estado = 'APROBADO' AND d.cantidad_enviada IS NULL;
