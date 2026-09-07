-- ─────────────────────────────────────────────────────────────────────────────
-- 001 · Medios de pago configurables y pago dividido
--
-- Antes el medio de pago era un ENUM fijo en `ventas` con un único valor. Eso
-- impedía dos cosas que un mostrador necesita a diario:
--
--   1. Cobrar una venta con VARIOS medios («$30.000 en efectivo y el resto por
--      Nequi»). El ENUM tenía el valor 'MIXTO', pero no había dónde guardar
--      cuánto entró por cada uno: la información se perdía.
--   2. Que cada negocio use SUS medios. Nequi, Daviplata, una llave Bre-B o un
--      datáfono concreto no caben en un ENUM cerrado del esquema.
--
-- Esta migración es ADITIVA: no altera ni borra nada de lo existente. La
-- columna `ventas.metodo_pago` se conserva y se sigue rellenando ('MIXTO'
-- cuando hay más de un pago), de modo que los tickets y reportes que ya la
-- leían siguen funcionando sin cambios.
-- ─────────────────────────────────────────────────────────────────────────────

-- Medios de pago del negocio.
CREATE TABLE IF NOT EXISTS metodos_pago (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid          CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  nombre        VARCHAR(60) NOT NULL COMMENT 'Nequi, Daviplata, Datáfono…',

  -- El tipo NO es el nombre: gobierna el comportamiento del cobro.
  --   EFECTIVO      → calcula vueltas y pide con cuánto paga
  --   TRANSFERENCIA → puede mostrar un QR y pedir referencia
  --   CREDITO       → fiado; sólo disponible si el negocio lo habilita
  tipo          ENUM('EFECTIVO','TARJETA','TRANSFERENCIA','CREDITO','OTRO')
                NOT NULL DEFAULT 'OTRO',

  -- Número de aprobación del datáfono o de la transferencia. Es lo que permite
  -- cuadrar la caja contra el extracto al cierre del día.
  requiere_referencia TINYINT(1) NOT NULL DEFAULT 0,

  -- QR que el vendedor le muestra al cliente para que pague. Se sube por
  -- /api/v1/uploads/imagen y aquí se guarda la URL pública: tiene que verse
  -- desde CUALQUIER dispositivo, porque lo configura el administrador y lo
  -- enseña el vendedor.
  qr_url        VARCHAR(500) NULL,

  -- Texto de apoyo bajo el QR: «Nequi 300 123 4567», «Llave Bre-B @mitienda».
  instrucciones VARCHAR(200) NULL,

  color         CHAR(7) CHARACTER SET ascii COLLATE ascii_general_ci
                NOT NULL DEFAULT '#0E6B5C',
  orden         SMALLINT UNSIGNED NOT NULL DEFAULT 0,
  activo        TINYINT(1) NOT NULL DEFAULT 1,

  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at    DATETIME(3) NULL,

  PRIMARY KEY (id),
  UNIQUE KEY uk_metodos_pago_uuid (uuid),
  KEY idx_metodos_pago_orden (activo, orden, nombre),
  KEY idx_metodos_pago_sync  (updated_at, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- Desglose del cobro de una venta.
--
-- Una venta tiene 1..N pagos y la suma de sus montos es igual a `ventas.total`.
-- Con un solo medio hay una sola fila: el caso simple no se trata aparte, así
-- que los reportes por medio de pago no tienen que mirar en dos sitios.
CREATE TABLE IF NOT EXISTS venta_pagos (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid            CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  venta_id        BIGINT UNSIGNED NOT NULL,
  metodo_pago_id  BIGINT UNSIGNED NULL,

  -- Instantánea del nombre, igual que `venta_detalles.descripcion`. Si mañana
  -- se renombra «Nequi» o se da de baja, el histórico y su ticket NO deben
  -- cambiar: es un requisito contable, no una desnormalización perezosa.
  metodo_nombre   VARCHAR(60) NOT NULL,
  metodo_tipo     ENUM('EFECTIVO','TARJETA','TRANSFERENCIA','CREDITO','OTRO')
                  NOT NULL DEFAULT 'OTRO',

  monto           DECIMAL(14,2) NOT NULL,

  -- Sólo en efectivo: con cuánto pagó y cuánto se le devolvió. Va por pago y no
  -- por venta porque en un cobro mixto sólo una parte se paga en efectivo.
  monto_recibido  DECIMAL(14,2) NULL,
  cambio          DECIMAL(14,2) NULL,

  referencia      VARCHAR(80) NULL COMMENT 'Aprobación del datáfono, # de transferencia',

  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  -- Lo exige el cursor keyset de la bajada delta, que ordena por
  -- (updated_at, id). Un pago no se modifica, pero sin esta columna no habría
  -- forma de paginarlos hacia el dispositivo.
  updated_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
                  ON UPDATE CURRENT_TIMESTAMP(3),

  PRIMARY KEY (id),
  UNIQUE KEY uk_venta_pagos_uuid (uuid),
  KEY idx_venta_pagos_sync (updated_at, id),
  KEY idx_venta_pagos_venta  (venta_id),
  KEY idx_venta_pagos_metodo (metodo_pago_id),

  CONSTRAINT fk_venta_pagos_venta
    FOREIGN KEY (venta_id) REFERENCES ventas (id) ON DELETE CASCADE,
  -- El medio NO se borra en cascada: dar de baja «Nequi» no puede llevarse por
  -- delante el historial de lo que se cobró por ahí.
  CONSTRAINT fk_venta_pagos_metodo
    FOREIGN KEY (metodo_pago_id) REFERENCES metodos_pago (id) ON DELETE SET NULL,

  CONSTRAINT ck_venta_pagos_monto CHECK (monto <> 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- Medios iniciales. Cubren el caso de una tienda que abre hoy; el resto los
-- registra cada negocio desde la app.
INSERT INTO metodos_pago (uuid, nombre, tipo, orden, color)
SELECT * FROM (
  SELECT UUID() AS uuid, 'Efectivo'      AS nombre, 'EFECTIVO'      AS tipo, 1 AS orden, '#11794F' AS color UNION ALL
  SELECT UUID(),         'Tarjeta',              'TARJETA',              2,        '#1D4ED8' UNION ALL
  SELECT UUID(),         'Transferencia',        'TRANSFERENCIA',        3,        '#6750A4'
) AS nuevos
WHERE NOT EXISTS (SELECT 1 FROM metodos_pago WHERE deleted_at IS NULL);


-- ¿Este negocio fía?
--
-- Apagado por defecto: el fiado obliga a llevar cuentas por cobrar, y una
-- tienda que no fía no debería ver esa opción al cobrar.
INSERT INTO configuracion (clave, valor, tipo, descripcion)
VALUES ('permite_credito', 'false', 'BOOL', 'Habilita el cobro a crédito (fiado)')
ON DUPLICATE KEY UPDATE clave = clave;
