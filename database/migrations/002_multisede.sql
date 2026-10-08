-- ─────────────────────────────────────────────────────────────────────────────
-- 002 · Multisede, roles por sede, horarios, traslados, cierres de caja y
--       cuentas por cobrar
--
-- El negocio pasa a tener varias sedes. Hasta aquí había UN stock por producto
-- y ningún concepto de sede, así que con dos tiendas sólo se sabía el total.
--
-- Reglas de esta migración:
--
--   1. ADITIVA. No borra ni renombra nada. Lo existente pasa a «Sede principal».
--   2. RE-EJECUTABLE. `scripts/migrate.mjs` aplica schema.sql y TODAS las
--      migraciones en cada corrida: cada sentencia tolera haberse aplicado ya
--      (IF NOT EXISTS, INSERT IGNORE, UPDATE ... WHERE ... IS NULL).
--   3. COMPATIBLE CON LO QUE YA ESTÁ EN LA CALLE. Entre aplicar esto y desplegar
--      el backend nuevo, el backend viejo sigue insertando ventas y movimientos
--      sin `sede_id`; los triggers les asignan la sede del dispositivo o, en su
--      defecto, la principal. Y los teléfonos con la app vieja siguen leyendo
--      `productos.stock_actual`, que se mantiene como TOTAL de todas las sedes.
--
-- Orden en producción: respaldo → esta migración → backend nuevo → app nueva
-- en todos los teléfonos → recién entonces crear la segunda sede.
-- ─────────────────────────────────────────────────────────────────────────────

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. SEDES
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS sedes (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid          CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  nombre        VARCHAR(120) NOT NULL,
  -- Código corto para listas y tickets: «NOR», «CEN».
  codigo        VARCHAR(10) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  direccion     VARCHAR(200) NULL,
  telefono      VARCHAR(30)  NULL,
  -- La sede a la que se asigna todo lo que llega sin sede (datos previos a
  -- esta migración y clientes viejos). Exactamente una.
  es_principal  TINYINT(1) NOT NULL DEFAULT 0,
  activo        TINYINT(1) NOT NULL DEFAULT 1,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at    DATETIME(3) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_sedes_uuid   (uuid),
  UNIQUE KEY uk_sedes_codigo (codigo),
  KEY idx_sedes_sync (updated_at, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- La sede principal hereda la dirección y el teléfono que el negocio ya tenía
-- configurados, para que sus tickets no cambien.
INSERT INTO sedes (uuid, nombre, codigo, direccion, telefono, es_principal)
SELECT UUID(), 'Sede principal', 'PRI',
       NULLIF((SELECT valor FROM configuracion WHERE clave = 'direccion'), ''),
       NULLIF((SELECT valor FROM configuracion WHERE clave = 'telefono'), ''),
       1
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM sedes WHERE es_principal = 1);

DROP FUNCTION IF EXISTS fn_sede_principal;
DELIMITER $$
CREATE FUNCTION fn_sede_principal()
RETURNS BIGINT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  RETURN (SELECT id FROM sedes
           WHERE es_principal = 1 AND deleted_at IS NULL
           ORDER BY id LIMIT 1);
END$$
DELIMITER ;


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. ROLES, PERTENENCIA A SEDES Y HORARIOS
--
--   ADMIN               → Director General: todas las sedes. Se conserva el valor
--                         para no migrar filas y que la app vieja lo siga
--                         reconociendo como administrador.
--   GERENTE             → Gerente de Sede: una o varias sedes.
--   AUXILIAR_INVENTARIO → registra entradas; sus ajustes requieren aprobación.
--   VENDEDOR            → vende.
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE usuarios
  MODIFY COLUMN rol ENUM('ADMIN','GERENTE','AUXILIAR_INVENTARIO','VENDEDOR')
                    NOT NULL DEFAULT 'VENDEDOR';

-- Horario semanal como documento JSON:
--   [{"dia":1,"inicio":"08:00","fin":"17:00"}, {"dia":5,"inicio":"18:00","fin":"02:00"}]
-- dia 1 = lunes … 7 = domingo; `fin <= inicio` es un turno que cruza la
-- medianoche. Se edita entero, así que un documento es más simple que una
-- tabla de tramos, y viaja al dispositivo junto con el usuario.
ALTER TABLE usuarios
  ADD COLUMN IF NOT EXISTS restringir_horario TINYINT(1) NOT NULL DEFAULT 0 AFTER activo,
  ADD COLUMN IF NOT EXISTS horario            LONGTEXT    NULL AFTER restringir_horario,
  -- Permiso puntual fuera de horario que da un gerente o el director.
  ADD COLUMN IF NOT EXISTS acceso_extra_hasta DATETIME(3) NULL AFTER horario;

-- Vendedor y auxiliar: exactamente una sede. Gerente: una o más. Director:
-- ninguna fila (ve todas). La regla de cardinalidad la impone el servicio.
CREATE TABLE IF NOT EXISTS usuario_sedes (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  usuario_id  BIGINT UNSIGNED NOT NULL,
  sede_id     BIGINT UNSIGNED NOT NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_usuario_sede (usuario_id, sede_id),
  KEY idx_usuario_sedes_sede (sede_id),
  CONSTRAINT fk_us_usuario FOREIGN KEY (usuario_id)
    REFERENCES usuarios (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_us_sede FOREIGN KEY (sede_id)
    REFERENCES sedes (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Los vendedores que ya existían trabajan en la sede principal.
INSERT IGNORE INTO usuario_sedes (usuario_id, sede_id)
SELECT u.id, fn_sede_principal()
  FROM usuarios u
 WHERE u.rol = 'VENDEDOR'
   AND u.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM usuario_sedes us WHERE us.usuario_id = u.id);

-- Registro de cada acceso extra concedido: quién, a quién, hasta cuándo y por qué.
CREATE TABLE IF NOT EXISTS accesos_extra (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid          CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  usuario_id    BIGINT UNSIGNED NOT NULL,
  otorgado_por  BIGINT UNSIGNED NULL,
  hasta         DATETIME(3) NOT NULL,
  motivo        VARCHAR(255) NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_accesos_extra_uuid (uuid),
  KEY idx_accesos_extra_usuario (usuario_id, created_at),
  CONSTRAINT fk_ae_usuario FOREIGN KEY (usuario_id)
    REFERENCES usuarios (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_ae_otorgado FOREIGN KEY (otorgado_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Petición de un empleado para pasar a otra sede. Al aceptarse o rechazarse se
-- BORRA (decisión del negocio); lo que queda es la auditoría del cambio.
CREATE TABLE IF NOT EXISTS solicitudes_cambio_sede (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid             CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  usuario_id       BIGINT UNSIGNED NOT NULL,
  sede_destino_id  BIGINT UNSIGNED NOT NULL,
  motivo           VARCHAR(255) NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_scs_uuid (uuid),
  -- Una sola solicitud abierta por empleado.
  UNIQUE KEY uk_scs_usuario (usuario_id),
  KEY idx_scs_destino (sede_destino_id),
  CONSTRAINT fk_scs_usuario FOREIGN KEY (usuario_id)
    REFERENCES usuarios (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_scs_sede FOREIGN KEY (sede_destino_id)
    REFERENCES sedes (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. SEDE EN DISPOSITIVOS, VENTAS, MOVIMIENTOS, ALERTAS Y AUDITORÍA
--    Nullable a propósito: el backend viejo no la envía, y los triggers la
--    completan. El backend nuevo siempre la envía.
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE dispositivos
  ADD COLUMN IF NOT EXISTS sede_id BIGINT UNSIGNED NULL AFTER usuario_id,
  ADD KEY IF NOT EXISTS idx_dispositivos_sede (sede_id),
  ADD CONSTRAINT fk_dispositivos_sede FOREIGN KEY IF NOT EXISTS (sede_id)
    REFERENCES sedes (id) ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE ventas
  ADD COLUMN IF NOT EXISTS sede_id    BIGINT UNSIGNED NULL AFTER dispositivo_uuid,
  -- Turno de caja en el que se cobró (cierres_caja.uuid).
  ADD COLUMN IF NOT EXISTS turno_uuid CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NULL AFTER sede_id,
  ADD KEY IF NOT EXISTS idx_ventas_sede  (sede_id, fecha_local),
  ADD KEY IF NOT EXISTS idx_ventas_turno (turno_uuid),
  ADD CONSTRAINT fk_ventas_sede FOREIGN KEY IF NOT EXISTS (sede_id)
    REFERENCES sedes (id) ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE movimientos_inventario
  ADD COLUMN IF NOT EXISTS sede_id       BIGINT UNSIGNED NULL AFTER producto_id,
  ADD COLUMN IF NOT EXISTS traslado_id   BIGINT UNSIGNED NULL AFTER venta_id,
  -- Quién aprobó el ajuste cuando lo solicitó un auxiliar de inventario.
  ADD COLUMN IF NOT EXISTS aprobado_por  BIGINT UNSIGNED NULL AFTER usuario_id,
  ADD KEY IF NOT EXISTS idx_mov_sede     (sede_id, producto_id, fecha),
  ADD KEY IF NOT EXISTS idx_mov_traslado (traslado_id),
  ADD CONSTRAINT fk_mov_sede FOREIGN KEY IF NOT EXISTS (sede_id)
    REFERENCES sedes (id) ON DELETE RESTRICT ON UPDATE CASCADE,
  ADD CONSTRAINT fk_mov_aprobado FOREIGN KEY IF NOT EXISTS (aprobado_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE alertas
  ADD COLUMN IF NOT EXISTS sede_id BIGINT UNSIGNED NULL AFTER producto_id,
  ADD KEY IF NOT EXISTS idx_alertas_sede (sede_id, tipo, resuelta_en),
  ADD CONSTRAINT fk_alertas_sede FOREIGN KEY IF NOT EXISTS (sede_id)
    REFERENCES sedes (id) ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE auditoria
  ADD COLUMN IF NOT EXISTS sede_id          BIGINT UNSIGNED NULL AFTER usuario_id,
  ADD COLUMN IF NOT EXISTS dispositivo_uuid CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NULL AFTER sede_id,
  ADD KEY IF NOT EXISTS idx_audit_sede (sede_id, created_at),
  ADD CONSTRAINT fk_audit_sede FOREIGN KEY IF NOT EXISTS (sede_id)
    REFERENCES sedes (id) ON DELETE SET NULL ON UPDATE CASCADE;

-- Todo lo que existía ocurrió en la sede principal.
UPDATE dispositivos           SET sede_id = fn_sede_principal() WHERE sede_id IS NULL;
UPDATE ventas                 SET sede_id = fn_sede_principal() WHERE sede_id IS NULL;
UPDATE movimientos_inventario SET sede_id = fn_sede_principal() WHERE sede_id IS NULL;
UPDATE alertas                SET sede_id = fn_sede_principal() WHERE sede_id IS NULL AND producto_id IS NOT NULL;


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. STOCK POR SEDE
--    `stock_sedes` es la proyección por sede del libro de movimientos.
--    `productos.stock_actual` sigue existiendo como TOTAL: lo leen los
--    reportes globales y los teléfonos con la app vieja.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS stock_sedes (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  producto_id   BIGINT UNSIGNED NOT NULL,
  sede_id       BIGINT UNSIGNED NOT NULL,
  stock_actual  DECIMAL(14,3) NOT NULL DEFAULT 0.000 COMMENT 'DERIVADO — lo mantienen los triggers',
  -- NULL = usa el mínimo general del producto. Cada sede puede necesitar uno
  -- distinto: la del centro vende el triple que la del barrio.
  stock_minimo  DECIMAL(14,3) NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_stock_sede (producto_id, sede_id),
  KEY idx_stock_sedes_sede (sede_id, stock_actual),
  KEY idx_stock_sedes_sync (updated_at, id),
  CONSTRAINT fk_ss_producto FOREIGN KEY (producto_id)
    REFERENCES productos (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_ss_sede FOREIGN KEY (sede_id)
    REFERENCES sedes (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- El stock actual es el de la sede principal. INSERT IGNORE: en una segunda
-- corrida la fila ya existe y la mantienen los triggers; pisarla con el total
-- descuadraría la sede.
INSERT IGNORE INTO stock_sedes (producto_id, sede_id, stock_actual)
SELECT p.id, fn_sede_principal(), p.stock_actual
  FROM productos p;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. TRASLADOS ENTRE SEDES
--    Flujo simple: el stock se mueve al aprobar. Siempre confirma «la otra
--    parte»: si lo pide un empleado lo aprueba un gerente; si lo pide un
--    gerente lo confirma alguien de la sede origen.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS traslados (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid             CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  numero           VARCHAR(30) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  sede_origen_id   BIGINT UNSIGNED NOT NULL,
  sede_destino_id  BIGINT UNSIGNED NOT NULL,
  estado           ENUM('PENDIENTE','APROBADO','RECHAZADO','CANCELADO') NOT NULL DEFAULT 'PENDIENTE',
  -- Quién debe confirmarlo:
  --   GESTOR → un gerente de la sede origen o el director (lo pidió un empleado)
  --   ORIGEN → cualquier empleado o gerente de la sede origen (lo pidió un gestor)
  confirma         ENUM('GESTOR','ORIGEN') NOT NULL DEFAULT 'GESTOR',
  notas            VARCHAR(500) NULL,
  solicitado_por   BIGINT UNSIGNED NULL,
  solicitado_en    DATETIME(3) NOT NULL,
  resuelto_por     BIGINT UNSIGNED NULL,
  resuelto_en      DATETIME(3) NULL,
  motivo_rechazo   VARCHAR(255) NULL,
  dispositivo_uuid CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at       DATETIME(3) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_traslados_uuid   (uuid),
  UNIQUE KEY uk_traslados_numero (numero),
  KEY idx_traslados_estado  (estado, sede_origen_id),
  KEY idx_traslados_destino (sede_destino_id),
  KEY idx_traslados_sync    (updated_at, id),
  -- Sin ON UPDATE CASCADE: MariaDB no admite un CHECK (ck_tr_sedes) sobre
  -- columnas con acción en cascada. Los id de sede no cambian nunca.
  CONSTRAINT fk_tr_origen  FOREIGN KEY (sede_origen_id)  REFERENCES sedes (id),
  CONSTRAINT fk_tr_destino FOREIGN KEY (sede_destino_id) REFERENCES sedes (id),
  CONSTRAINT fk_tr_solicitado FOREIGN KEY (solicitado_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_tr_resuelto FOREIGN KEY (resuelto_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_tr_sedes CHECK (sede_origen_id <> sede_destino_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS traslado_detalles (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid         CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  traslado_id  BIGINT UNSIGNED NOT NULL,
  producto_id  BIGINT UNSIGNED NULL,
  -- Instantánea, como en venta_detalles: el traslado histórico no cambia si
  -- mañana se renombra el producto.
  descripcion  VARCHAR(180) NOT NULL,
  cantidad     DECIMAL(14,3) NOT NULL,
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_trd_uuid (uuid),
  KEY idx_trd_traslado (traslado_id),
  KEY idx_trd_sync (updated_at, id),
  CONSTRAINT fk_trd_traslado FOREIGN KEY (traslado_id)
    REFERENCES traslados (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_trd_producto FOREIGN KEY (producto_id)
    REFERENCES productos (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_trd_cantidad CHECK (cantidad > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Historial: cada cambio de estado con su usuario y su hora.
CREATE TABLE IF NOT EXISTS traslado_eventos (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid         CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  traslado_id  BIGINT UNSIGNED NOT NULL,
  evento       ENUM('CREADO','APROBADO','RECHAZADO','CANCELADO') NOT NULL,
  usuario_id   BIGINT UNSIGNED NULL,
  fecha        DATETIME(3) NOT NULL,
  nota         VARCHAR(255) NULL,
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_tre_uuid (uuid),
  KEY idx_tre_traslado (traslado_id, fecha),
  KEY idx_tre_sync (updated_at, id),
  CONSTRAINT fk_tre_traslado FOREIGN KEY (traslado_id)
    REFERENCES traslados (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_tre_usuario FOREIGN KEY (usuario_id)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE movimientos_inventario
  ADD CONSTRAINT fk_mov_traslado FOREIGN KEY IF NOT EXISTS (traslado_id)
    REFERENCES traslados (id) ON DELETE SET NULL ON UPDATE CASCADE;


-- ═════════════════════════════════════════════════════════════════════════════
-- 6. SOLICITUDES DE AJUSTE (auxiliar de inventario)
--    El conteo, la merma o el ajuste que pide un auxiliar no toca el stock
--    hasta que un gerente de la sede o el director lo aprueba: es la vía con
--    la que se tapa un faltante, así que la ve otra persona.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS solicitudes_ajuste (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid             CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  sede_id          BIGINT UNSIGNED NOT NULL,
  producto_id      BIGINT UNSIGNED NOT NULL,
  tipo             ENUM('CONTEO','MERMA','AJUSTE') NOT NULL,
  -- AJUSTE: con signo. MERMA: positiva, se resta al aplicarla. CONTEO: NULL.
  cantidad         DECIMAL(14,3) NULL,
  -- CONTEO: lo que hay físicamente; la diferencia se calcula AL APROBAR, contra
  -- el stock de ese momento, no el de cuando se contó.
  stock_contado    DECIMAL(14,3) NULL,
  motivo           VARCHAR(255) NULL,
  estado           ENUM('PENDIENTE','APROBADA','RECHAZADA') NOT NULL DEFAULT 'PENDIENTE',
  solicitado_por   BIGINT UNSIGNED NULL,
  solicitado_en    DATETIME(3) NOT NULL,
  resuelto_por     BIGINT UNSIGNED NULL,
  resuelto_en      DATETIME(3) NULL,
  motivo_rechazo   VARCHAR(255) NULL,
  movimiento_id    BIGINT UNSIGNED NULL,
  dispositivo_uuid CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_sa_uuid (uuid),
  KEY idx_sa_estado (sede_id, estado),
  KEY idx_sa_sync (updated_at, id),
  CONSTRAINT fk_sa_sede FOREIGN KEY (sede_id) REFERENCES sedes (id) ON UPDATE CASCADE,
  CONSTRAINT fk_sa_producto FOREIGN KEY (producto_id)
    REFERENCES productos (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_sa_solicitado FOREIGN KEY (solicitado_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_sa_resuelto FOREIGN KEY (resuelto_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_sa_movimiento FOREIGN KEY (movimiento_id)
    REFERENCES movimientos_inventario (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ═════════════════════════════════════════════════════════════════════════════
-- 7. CIERRE DE CAJA POR TURNO
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS cierres_caja (
  id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid                 CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  sede_id              BIGINT UNSIGNED NOT NULL,
  usuario_id           BIGINT UNSIGNED NULL,
  dispositivo_uuid     CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NULL,
  estado               ENUM('ABIERTO','CERRADO') NOT NULL DEFAULT 'ABIERTO',
  abierto_en           DATETIME(3) NOT NULL,
  base_efectivo        DECIMAL(14,2) NOT NULL DEFAULT 0.00,
  cerrado_en           DATETIME(3) NULL,
  -- Se cerró después de que terminara el turno (al siguiente ingreso).
  cierre_tardio        TINYINT(1) NOT NULL DEFAULT 0,
  -- Lo que el SERVIDOR calcula que debía haber, con las ventas del turno.
  esperado_total       DECIMAL(14,2) NULL,
  contado_total        DECIMAL(14,2) NULL,
  -- La cifra que importa: efectivo contado − (base + efectivo vendido).
  -- Negativa = faltante.
  diferencia_efectivo  DECIMAL(14,2) NULL,
  -- Instantánea por medio de pago:
  --   [{"metodo_uuid","metodo_nombre","metodo_tipo","esperado","contado","diferencia"}]
  detalle              LONGTEXT NULL,
  notas                VARCHAR(500) NULL,
  revisado_por         BIGINT UNSIGNED NULL,
  revisado_en          DATETIME(3) NULL,
  created_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at           DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_cierres_uuid (uuid),
  KEY idx_cierres_usuario (usuario_id, estado),
  KEY idx_cierres_sede (sede_id, abierto_en),
  KEY idx_cierres_sync (updated_at, id),
  CONSTRAINT fk_cc_sede FOREIGN KEY (sede_id) REFERENCES sedes (id) ON UPDATE CASCADE,
  CONSTRAINT fk_cc_usuario FOREIGN KEY (usuario_id)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_cc_revisado FOREIGN KEY (revisado_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ═════════════════════════════════════════════════════════════════════════════
-- 8. MEDIOS DE PAGO POR SEDE Y CUENTAS POR COBRAR (entidades de crédito)
--    Un medio de tipo CREDITO es una entidad (Addi, Crediya…) que paga al
--    negocio después, normalmente descontando una comisión. La cuenta por
--    cobrar es contra la entidad, no contra el cliente.
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE metodos_pago
  -- NULL = disponible en todas las sedes. Una sede con su propio Nequi/QR
  -- tiene su propio medio.
  ADD COLUMN IF NOT EXISTS sede_id       BIGINT UNSIGNED NULL AFTER tipo,
  -- Sólo CREDITO: lo que la entidad retiene y en cuántos días suele pagar.
  ADD COLUMN IF NOT EXISTS comision_pct  DECIMAL(5,2) NULL AFTER instrucciones,
  ADD COLUMN IF NOT EXISTS dias_pago     SMALLINT UNSIGNED NULL AFTER comision_pct,
  ADD KEY IF NOT EXISTS idx_metodos_pago_sede (sede_id),
  ADD CONSTRAINT fk_metodos_pago_sede FOREIGN KEY IF NOT EXISTS (sede_id)
    REFERENCES sedes (id) ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE venta_pagos
  -- Cuánto de este pago ya pagó la entidad (bruto, incluida su comisión).
  ADD COLUMN IF NOT EXISTS cobrado DECIMAL(14,2) NOT NULL DEFAULT 0.00 AFTER referencia;

-- Un pago recibido de una entidad: «Addi consignó $480.000 el 12 de octubre».
CREATE TABLE IF NOT EXISTS recaudos (
  id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid             CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  metodo_pago_id   BIGINT UNSIGNED NOT NULL,
  sede_id          BIGINT UNSIGNED NULL,
  fecha            DATE NOT NULL,
  -- Neto que llegó a la cuenta del negocio.
  monto            DECIMAL(14,2) NOT NULL,
  -- Lo que la entidad retuvo. monto + comision = lo que se descuenta de la deuda.
  comision         DECIMAL(14,2) NOT NULL DEFAULT 0.00,
  referencia       VARCHAR(80) NULL,
  notas            VARCHAR(255) NULL,
  -- Instantánea de a qué pagos se aplicó: [{"venta_pago_uuid","monto"}]
  aplicaciones     LONGTEXT NULL,
  registrado_por   BIGINT UNSIGNED NULL,
  dispositivo_uuid CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NULL,
  created_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at       DATETIME(3) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_recaudos_uuid (uuid),
  KEY idx_recaudos_metodo (metodo_pago_id, fecha),
  KEY idx_recaudos_sync (updated_at, id),
  CONSTRAINT fk_rec_metodo FOREIGN KEY (metodo_pago_id) REFERENCES metodos_pago (id) ON UPDATE CASCADE,
  CONSTRAINT fk_rec_sede FOREIGN KEY (sede_id)
    REFERENCES sedes (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_rec_registrado FOREIGN KEY (registrado_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT ck_rec_monto CHECK (monto >= 0 AND comision >= 0 AND monto + comision > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Desglose relacional de cada recaudo: permite responder «¿qué ventas pagó esta
-- consignación?» con SQL, y sumar lo cobrado de cada pago.
CREATE TABLE IF NOT EXISTS recaudo_aplicaciones (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  recaudo_id     BIGINT UNSIGNED NOT NULL,
  venta_pago_id  BIGINT UNSIGNED NOT NULL,
  monto          DECIMAL(14,2) NOT NULL,
  created_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_rec_apl (recaudo_id, venta_pago_id),
  KEY idx_rec_apl_pago (venta_pago_id),
  CONSTRAINT fk_ra_recaudo FOREIGN KEY (recaudo_id)
    REFERENCES recaudos (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_ra_pago FOREIGN KEY (venta_pago_id)
    REFERENCES venta_pagos (id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT ck_ra_monto CHECK (monto > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ═════════════════════════════════════════════════════════════════════════════
-- 9. TRIGGERS
--    Reemplazan a los de schema.sql §15. La regla no cambia: ningún UPDATE de
--    aplicación toca el stock; se inserta el movimiento y el trigger mantiene
--    las proyecciones — ahora dos: la de la sede y el total del producto.
-- ═════════════════════════════════════════════════════════════════════════════

-- Sede de respaldo para filas que llegan sin ella (backend o app viejos): la
-- del dispositivo que las registró y, si no se conoce, la principal.
DROP FUNCTION IF EXISTS fn_sede_de_dispositivo;
DELIMITER $$
CREATE FUNCTION fn_sede_de_dispositivo(p_dispositivo CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci)
RETURNS BIGINT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  RETURN COALESCE(
    (SELECT sede_id FROM dispositivos WHERE uuid = p_dispositivo LIMIT 1),
    fn_sede_principal()
  );
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_ventas_before_insert;
DELIMITER $$
CREATE TRIGGER trg_ventas_before_insert
BEFORE INSERT ON ventas
FOR EACH ROW
BEGIN
  IF NEW.sede_id IS NULL THEN
    SET NEW.sede_id = fn_sede_de_dispositivo(NEW.dispositivo_uuid);
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_mov_before_insert;
DELIMITER $$
CREATE TRIGGER trg_mov_before_insert
BEFORE INSERT ON movimientos_inventario
FOR EACH ROW
BEGIN
  DECLARE v_stock DECIMAL(14,3);

  IF NEW.sede_id IS NULL THEN
    -- Un movimiento de venta pertenece a la sede de su venta.
    SET NEW.sede_id = COALESCE(
      (SELECT sede_id FROM ventas WHERE id = NEW.venta_id),
      fn_sede_de_dispositivo(NEW.dispositivo_uuid)
    );
  END IF;

  -- SET = (SELECT ...) y no SELECT ... INTO: sin fila devuelve NULL en vez de
  -- una advertencia «No data».
  SET v_stock = (SELECT stock_actual FROM stock_sedes
                  WHERE producto_id = NEW.producto_id AND sede_id = NEW.sede_id);
  SET NEW.stock_anterior   = IFNULL(v_stock, 0);
  SET NEW.stock_resultante = IFNULL(v_stock, 0) + NEW.cantidad;

  IF NEW.fecha_local IS NULL THEN
    SET NEW.fecha_local = DATE(NEW.fecha);
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_mov_after_insert;
DELIMITER $$
CREATE TRIGGER trg_mov_after_insert
AFTER INSERT ON movimientos_inventario
FOR EACH ROW
BEGIN
  INSERT INTO stock_sedes (producto_id, sede_id, stock_actual)
  VALUES (NEW.producto_id, NEW.sede_id, NEW.cantidad)
  ON DUPLICATE KEY UPDATE stock_actual = stock_actual + NEW.cantidad;

  UPDATE productos
     SET stock_actual = stock_actual + NEW.cantidad
   WHERE id = NEW.producto_id;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_alertas_before_insert;
DELIMITER $$
CREATE TRIGGER trg_alertas_before_insert
BEFORE INSERT ON alertas
FOR EACH ROW
BEGIN
  IF NEW.sede_id IS NULL AND NEW.producto_id IS NOT NULL THEN
    SET NEW.sede_id = COALESCE(
      (SELECT sede_id FROM ventas WHERE id = NEW.venta_id),
      fn_sede_principal()
    );
  END IF;
END$$
DELIMITER ;

-- Abre o cierra la alerta STOCK_BAJO de un producto en una sede.
--
-- Se dispara sobre `stock_sedes` y no sobre el movimiento, porque lo que
-- cambia la condición es la fila de stock: un movimiento (venta, traslado,
-- ajuste) y también un cambio del mínimo de la sede. Con el mínimo en 0 no hay
-- alerta: el producto no tiene mínimo configurado.
DROP PROCEDURE IF EXISTS sp_evaluar_stock_bajo;
DELIMITER $$
CREATE PROCEDURE sp_evaluar_stock_bajo(IN p_producto BIGINT UNSIGNED, IN p_sede BIGINT UNSIGNED)
BEGIN
  DECLARE v_stock  DECIMAL(14,3);
  DECLARE v_minimo DECIMAL(14,3);
  DECLARE v_nombre VARCHAR(180);
  DECLARE v_sede   VARCHAR(120);

  SET v_stock  = (SELECT stock_actual FROM stock_sedes WHERE producto_id = p_producto AND sede_id = p_sede);
  SET v_minimo = (SELECT COALESCE(ss.stock_minimo, p.stock_minimo)
                    FROM stock_sedes ss JOIN productos p ON p.id = ss.producto_id
                   WHERE ss.producto_id = p_producto AND ss.sede_id = p_sede);

  IF v_minimo IS NOT NULL AND v_minimo > 0 AND v_stock IS NOT NULL AND v_stock <= v_minimo THEN
    IF NOT EXISTS (SELECT 1 FROM alertas
                    WHERE tipo = 'STOCK_BAJO' AND producto_id = p_producto
                      AND sede_id = p_sede AND resuelta_en IS NULL) THEN
      SET v_nombre = (SELECT nombre FROM productos WHERE id = p_producto);
      SET v_sede   = (SELECT nombre FROM sedes WHERE id = p_sede);
      INSERT INTO alertas (uuid, tipo, severidad, producto_id, sede_id, mensaje, detalle)
      VALUES (UUID(), 'STOCK_BAJO',
              IF(v_stock <= 0, 'CRITICA', 'ADVERTENCIA'),
              p_producto, p_sede,
              CONCAT(IF(v_stock <= 0, 'Agotado: ', 'Stock bajo: '), v_nombre, ' en ', v_sede),
              JSON_OBJECT('stock', v_stock, 'minimo', v_minimo));
    END IF;
  ELSE
    UPDATE alertas
       SET resuelta_en = UTC_TIMESTAMP(3)
     WHERE tipo = 'STOCK_BAJO' AND producto_id = p_producto
       AND sede_id = p_sede AND resuelta_en IS NULL;
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_stock_sedes_after_insert;
DELIMITER $$
CREATE TRIGGER trg_stock_sedes_after_insert
AFTER INSERT ON stock_sedes
FOR EACH ROW
BEGIN
  CALL sp_evaluar_stock_bajo(NEW.producto_id, NEW.sede_id);
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_stock_sedes_after_update;
DELIMITER $$
CREATE TRIGGER trg_stock_sedes_after_update
AFTER UPDATE ON stock_sedes
FOR EACH ROW
BEGIN
  -- Sin condición: cualquier escritura en la fila (stock, mínimo, o un simple
  -- «toque» cuando cambia el mínimo general del producto) re-evalúa.
  CALL sp_evaluar_stock_bajo(NEW.producto_id, NEW.sede_id);
END$$
DELIMITER ;


-- ═════════════════════════════════════════════════════════════════════════════
-- 10. PROCEDIMIENTOS Y VISTAS
-- ═════════════════════════════════════════════════════════════════════════════

-- Reconstruye ambas proyecciones desde el libro. Misma firma que la versión
-- anterior, para que quien la llamaba siga funcionando.
DROP PROCEDURE IF EXISTS sp_recalcular_stock;
DELIMITER $$
CREATE PROCEDURE sp_recalcular_stock(IN p_producto_uuid CHAR(36))
BEGIN
  DECLARE v_producto BIGINT UNSIGNED DEFAULT NULL;
  IF p_producto_uuid IS NOT NULL AND p_producto_uuid <> '' THEN
    SET v_producto = (SELECT id FROM productos WHERE uuid = p_producto_uuid);
  END IF;

  INSERT INTO stock_sedes (producto_id, sede_id, stock_actual)
  SELECT m.producto_id, m.sede_id, SUM(m.cantidad)
    FROM movimientos_inventario m
   WHERE v_producto IS NULL OR m.producto_id = v_producto
   GROUP BY m.producto_id, m.sede_id
  ON DUPLICATE KEY UPDATE stock_actual = VALUES(stock_actual);

  -- Sedes que tenían stock y ya no tienen movimientos (no debería pasar en un
  -- libro append-only, pero la red de seguridad no presupone nada).
  UPDATE stock_sedes ss
     SET ss.stock_actual = 0
   WHERE (v_producto IS NULL OR ss.producto_id = v_producto)
     AND NOT EXISTS (SELECT 1 FROM movimientos_inventario m
                      WHERE m.producto_id = ss.producto_id AND m.sede_id = ss.sede_id);

  UPDATE productos p
     SET p.stock_actual = IFNULL(
           (SELECT SUM(m.cantidad) FROM movimientos_inventario m WHERE m.producto_id = p.id), 0)
   WHERE v_producto IS NULL OR p.id = v_producto;
END$$
DELIMITER ;

-- Stock bajo por sede, con el mínimo efectivo (el de la sede o el general).
CREATE OR REPLACE VIEW v_stock_bajo_sedes AS
SELECT s.id AS sede_id, s.uuid AS sede_uuid, s.nombre AS sede,
       p.id AS producto_id, p.uuid AS producto_uuid, p.sku, p.nombre,
       ss.stock_actual,
       COALESCE(ss.stock_minimo, p.stock_minimo) AS stock_minimo,
       COALESCE(ss.stock_minimo, p.stock_minimo) - ss.stock_actual AS faltante
  FROM stock_sedes ss
  JOIN productos p ON p.id = ss.producto_id
  JOIN sedes s     ON s.id = ss.sede_id
 WHERE p.deleted_at IS NULL AND p.activo = 1
   AND s.deleted_at IS NULL AND s.activo = 1
   AND COALESCE(ss.stock_minimo, p.stock_minimo) > 0
   AND ss.stock_actual <= COALESCE(ss.stock_minimo, p.stock_minimo);

-- Las alertas STOCK_BAJO de lo que ya está bajo hoy: sin esto sólo aparecerían
-- con el próximo movimiento de cada producto. Re-ejecutable: el procedimiento
-- no duplica alertas abiertas.
DROP PROCEDURE IF EXISTS sp_evaluar_todo_stock_bajo;
DELIMITER $$
CREATE PROCEDURE sp_evaluar_todo_stock_bajo()
BEGIN
  DECLARE v_fin INT DEFAULT 0;
  DECLARE v_producto BIGINT UNSIGNED;
  DECLARE v_sede BIGINT UNSIGNED;
  DECLARE cur CURSOR FOR SELECT producto_id, sede_id FROM stock_sedes;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;

  OPEN cur;
  bucle: LOOP
    FETCH cur INTO v_producto, v_sede;
    IF v_fin = 1 THEN LEAVE bucle; END IF;
    CALL sp_evaluar_stock_bajo(v_producto, v_sede);
  END LOOP;
  CLOSE cur;
END$$
DELIMITER ;

CALL sp_evaluar_todo_stock_bajo();
