-- ═════════════════════════════════════════════════════════════════════════════
-- 006 · Un plan por app, sedes elegidas por app, pausas y roles por app
--
-- Hasta la 005 había UN plan por empresa y sus límites valían para todo. Desde
-- aquí cada app (INVENTARIO = Ventario, ASISTENCIA = Presente) tiene su plan:
--
--   · empresa_planes: plan y vencimiento de cada app. Vencido → GRATIS.
--   · Las dos apps quedan activas para toda empresa (registrarse en una basta
--     para entrar a la otra). empresa_aplicativos solo sirve para suspender.
--   · sede_aplicativos: las sedes son de la empresa, pero cada app trabaja
--     solo en las ELEGIDAS para ella, hasta su límite. Elegir es irrevocable
--     para el cliente (no hay endpoint que borre); solo sp_ajustar_cupos quita
--     las sobrantes cuando el plan baja.
--   · Pausas (usuarios.pausa_inventario / pausa_asistencia): si una app tiene
--     más personas que su plan, las sobrantes quedan en pausa en ESA app.
--   · Roles por app: ADMIN y GERENTE en las dos (mismo rol), AUXILIAR y
--     VENDEDOR solo Ventario, TALENTO_HUMANO y OPERARIO solo Presente.
--
-- Control de Personal (004_planes_y_roles_por_app.sql de ese repositorio)
-- redefine fn_personas_app y sp_ajustar_cupos para sumar sus fichas.
-- Cada sentencia tolera haberse aplicado ya.
-- ═════════════════════════════════════════════════════════════════════════════

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- ─── 1. Planes por app ──────────────────────────────────────────────────────

-- NULL = el plan sirve para cualquier app (GRATIS, ILIMITADO).
ALTER TABLE planes
  ADD COLUMN IF NOT EXISTS aplicativo ENUM('INVENTARIO','ASISTENCIA') NULL AFTER codigo;

CREATE TABLE IF NOT EXISTS empresa_planes (
  empresa_id  BIGINT UNSIGNED NOT NULL,
  aplicativo  ENUM('INVENTARIO','ASISTENCIA') NOT NULL,
  plan_id     SMALLINT UNSIGNED NOT NULL,
  -- NULL = no vence. Vencido, esa app opera con GRATIS (fn_plan_app).
  plan_vence  DATE NULL,
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (empresa_id, aplicativo),
  KEY idx_ep_plan (plan_id),
  CONSTRAINT fk_ep_empresa FOREIGN KEY (empresa_id)
    REFERENCES empresas (id) ON DELETE CASCADE ON UPDATE RESTRICT,
  CONSTRAINT fk_ep_plan FOREIGN KEY (plan_id)
    REFERENCES planes (id) ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Plan de cada empresa en cada app';

-- Cada app arranca con el plan que la empresa tenía (empresas.plan_id queda
-- como respaldo, sin uso).
INSERT IGNORE INTO empresa_planes (empresa_id, aplicativo, plan_id, plan_vence)
SELECT e.id, a.app, e.plan_id, e.plan_vence
  FROM empresas e
 CROSS JOIN (SELECT 'INVENTARIO' AS app UNION ALL SELECT 'ASISTENCIA') a;

-- Las dos apps activas para todas las empresas.
INSERT INTO empresa_aplicativos (empresa_id, aplicativo, activo)
SELECT e.id, a.app, 1
  FROM empresas e
 CROSS JOIN (SELECT 'INVENTARIO' AS app UNION ALL SELECT 'ASISTENCIA') a
 WHERE e.deleted_at IS NULL
ON DUPLICATE KEY UPDATE activo = 1;

-- ─── 2. Sedes elegidas por app ──────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sede_aplicativos (
  sede_id      BIGINT UNSIGNED NOT NULL,
  aplicativo   ENUM('INVENTARIO','ASISTENCIA') NOT NULL,
  elegida_en   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  elegida_por  BIGINT UNSIGNED NULL,
  PRIMARY KEY (sede_id, aplicativo),
  KEY idx_sa_app (aplicativo, sede_id),
  CONSTRAINT fk_sedeapp_sede FOREIGN KEY (sede_id)
    REFERENCES sedes (id) ON DELETE CASCADE ON UPDATE RESTRICT,
  CONSTRAINT fk_sedeapp_usuario FOREIGN KEY (elegida_por)
    REFERENCES usuarios (id) ON DELETE SET NULL ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Sedes en las que trabaja cada app';

-- ─── 3. Pausas por plan ─────────────────────────────────────────────────────

ALTER TABLE usuarios
  ADD COLUMN IF NOT EXISTS pausa_inventario TINYINT(1) NOT NULL DEFAULT 0 AFTER activo,
  ADD COLUMN IF NOT EXISTS pausa_asistencia TINYINT(1) NOT NULL DEFAULT 0 AFTER pausa_inventario;

-- ─── 4. Roles por app ───────────────────────────────────────────────────────

-- OPERADOR (el kiosco) pasa a OPERARIO; aparece TALENTO_HUMANO.
ALTER TABLE usuarios
  MODIFY COLUMN rol_asistencia ENUM('ADMIN','GERENTE','OPERADOR','TALENTO_HUMANO','OPERARIO') NULL;
UPDATE usuarios SET rol_asistencia = 'OPERARIO' WHERE rol_asistencia = 'OPERADOR';
ALTER TABLE usuarios
  MODIFY COLUMN rol_asistencia ENUM('ADMIN','GERENTE','TALENTO_HUMANO','OPERARIO') NULL;

-- Coherencia: ADMIN y GERENTE son el mismo rol en las dos apps (gana el más
-- alto si estaban distintos); los roles de una sola app dejan vacía la otra.
UPDATE usuarios
   SET rol = 'ADMIN', rol_asistencia = 'ADMIN'
 WHERE (rol = 'ADMIN' OR rol_asistencia = 'ADMIN')
   AND NOT (rol <=> 'ADMIN' AND rol_asistencia <=> 'ADMIN');
UPDATE usuarios
   SET rol = 'GERENTE', rol_asistencia = 'GERENTE'
 WHERE (rol = 'GERENTE' OR rol_asistencia = 'GERENTE')
   AND NOT (rol <=> 'GERENTE' AND rol_asistencia <=> 'GERENTE');
UPDATE usuarios
   SET rol_asistencia = NULL
 WHERE rol IN ('AUXILIAR_INVENTARIO','VENDEDOR') AND rol_asistencia IS NOT NULL;

ALTER TABLE usuarios
  ADD CONSTRAINT IF NOT EXISTS ck_usuarios_roles CHECK (
       (rol IN ('ADMIN','GERENTE') AND rol_asistencia = rol)
    OR (rol IN ('AUXILIAR_INVENTARIO','VENDEDOR') AND rol_asistencia IS NULL)
    OR (rol IS NULL AND (rol_asistencia IS NULL OR rol_asistencia IN ('TALENTO_HUMANO','OPERARIO')))
  );

-- ─── 5. Límites por app ─────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS fn_plan_app;
DROP FUNCTION IF EXISTS fn_limite_app;
DROP FUNCTION IF EXISTS fn_personas_app;
DROP FUNCTION IF EXISTS fn_uso_app;
DROP FUNCTION IF EXISTS fn_tope_sedes_empresa;
DROP PROCEDURE IF EXISTS sp_exigir_cupo_app;
DROP PROCEDURE IF EXISTS sp_ajustar_cupos;

DELIMITER $$

-- Plan con el que opera hoy esa app: el suyo, o GRATIS si venció o no hay fila.
CREATE FUNCTION fn_plan_app(p_empresa BIGINT UNSIGNED, p_app VARCHAR(12))
RETURNS SMALLINT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  -- Asignación con subconsulta y no SELECT … INTO: sin filas, INTO lanza
  -- NOT FOUND y cortaría el cursor de quien llame (p. ej. un procedimiento).
  RETURN COALESCE(
    (SELECT IF(ep.plan_vence IS NULL OR ep.plan_vence >= UTC_DATE(), ep.plan_id, NULL)
       FROM empresa_planes ep
      WHERE ep.empresa_id = p_empresa AND ep.aplicativo = p_app
      LIMIT 1),
    (SELECT id FROM planes WHERE codigo = 'GRATIS'));
END$$

-- Máximo del plan vigente de la app. NULL = sin límite. Los productos solo
-- existen en Ventario: en Presente no aplican (NULL).
CREATE FUNCTION fn_limite_app(p_empresa BIGINT UNSIGNED, p_app VARCHAR(12), p_recurso VARCHAR(20))
RETURNS INT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  IF p_recurso = 'productos' AND p_app <> 'INVENTARIO' THEN
    RETURN NULL;
  END IF;
  RETURN (SELECT CASE p_recurso
                   WHEN 'sedes'     THEN p.max_sedes
                   WHEN 'personas'  THEN p.max_personas
                   WHEN 'productos' THEN p.max_productos
                 END
            FROM planes p WHERE p.id = fn_plan_app(p_empresa, p_app));
END$$

-- Personas que ocupan cupo en la app. Aquí solo cuentas; Control de Personal
-- la REEMPLAZA para sumar sus fichas en ASISTENCIA. El OPERARIO es una cuenta
-- técnica (el teléfono de marcación), no una persona: no cuenta.
CREATE FUNCTION fn_personas_app(p_empresa BIGINT UNSIGNED, p_app VARCHAR(12))
RETURNS INT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  IF p_app = 'INVENTARIO' THEN
    RETURN (SELECT COUNT(*) FROM usuarios
             WHERE empresa_id = p_empresa AND activo = 1 AND deleted_at IS NULL
               AND es_superadmin = 0 AND rol IS NOT NULL AND pausa_inventario = 0);
  END IF;
  RETURN (SELECT COUNT(*) FROM usuarios
           WHERE empresa_id = p_empresa AND activo = 1 AND deleted_at IS NULL
             AND es_superadmin = 0 AND rol_asistencia IS NOT NULL
             AND rol_asistencia <> 'OPERARIO' AND pausa_asistencia = 0);
END$$

-- Uso actual de un recurso en la app.
CREATE FUNCTION fn_uso_app(p_empresa BIGINT UNSIGNED, p_app VARCHAR(12), p_recurso VARCHAR(20))
RETURNS INT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  CASE p_recurso
    WHEN 'sedes' THEN
      RETURN (SELECT COUNT(*) FROM sede_aplicativos sa
                JOIN sedes s ON s.id = sa.sede_id
               WHERE s.empresa_id = p_empresa AND sa.aplicativo = p_app
                 AND s.activo = 1 AND s.deleted_at IS NULL);
    WHEN 'productos' THEN
      IF p_app <> 'INVENTARIO' THEN RETURN 0; END IF;
      RETURN (SELECT COUNT(*) FROM productos
               WHERE empresa_id = p_empresa AND activo = 1 AND deleted_at IS NULL);
    WHEN 'personas' THEN
      RETURN fn_personas_app(p_empresa, p_app);
    ELSE
      RETURN 0;
  END CASE;
END$$

-- Sedes que puede TENER la empresa: el mayor de sus dos planes (NULL si alguno
-- es ilimitado). Cada app solo usa las que elige, hasta su propio límite.
CREATE FUNCTION fn_tope_sedes_empresa(p_empresa BIGINT UNSIGNED)
RETURNS INT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  DECLARE v_inv INT UNSIGNED;
  DECLARE v_asi INT UNSIGNED;
  SET v_inv = fn_limite_app(p_empresa, 'INVENTARIO', 'sedes');
  SET v_asi = fn_limite_app(p_empresa, 'ASISTENCIA', 'sedes');
  IF v_inv IS NULL OR v_asi IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN GREATEST(v_inv, v_asi);
END$$

-- Lanza LIMITE_PLAN:<recurso> si agregar UNO más excede el plan de la app.
CREATE PROCEDURE sp_exigir_cupo_app(IN p_empresa BIGINT UNSIGNED, IN p_app VARCHAR(12), IN p_recurso VARCHAR(20))
BEGIN
  DECLARE v_limite INT UNSIGNED;
  DECLARE v_mensaje VARCHAR(128);
  SET v_limite = fn_limite_app(p_empresa, p_app, p_recurso);
  IF v_limite IS NOT NULL AND fn_uso_app(p_empresa, p_app, p_recurso) >= v_limite THEN
    SET v_mensaje = CONCAT('LIMITE_PLAN:', p_recurso);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_mensaje;
  END IF;
END$$

-- Deja la app dentro de su plan (al bajar o vencer un plan): pausa a las
-- personas más recientes —nunca a un ADMIN— y quita las sedes elegidas más
-- recientes. No borra nada: subir el plan o cambiar la selección lo revierte.
-- Control de Personal la REEMPLAZA para pausar también sus fichas.
CREATE PROCEDURE sp_ajustar_cupos(IN p_empresa BIGINT UNSIGNED, IN p_app VARCHAR(12))
BEGIN
  DECLARE v_limite INT UNSIGNED;
  DECLARE v_exceso INT;

  SET v_limite = fn_limite_app(p_empresa, p_app, 'personas');
  IF v_limite IS NOT NULL THEN
    SET v_exceso = CAST(fn_uso_app(p_empresa, p_app, 'personas') AS SIGNED) - CAST(v_limite AS SIGNED);
    IF v_exceso > 0 AND p_app = 'INVENTARIO' THEN
      UPDATE usuarios SET pausa_inventario = 1
       WHERE empresa_id = p_empresa AND activo = 1 AND deleted_at IS NULL
         AND rol IS NOT NULL AND rol <> 'ADMIN' AND pausa_inventario = 0
       ORDER BY id DESC
       LIMIT v_exceso;
    ELSEIF v_exceso > 0 THEN
      UPDATE usuarios SET pausa_asistencia = 1
       WHERE empresa_id = p_empresa AND activo = 1 AND deleted_at IS NULL
         AND rol_asistencia IS NOT NULL AND rol_asistencia NOT IN ('ADMIN','OPERARIO')
         AND pausa_asistencia = 0
       ORDER BY id DESC
       LIMIT v_exceso;
    END IF;
  END IF;

  SET v_limite = fn_limite_app(p_empresa, p_app, 'sedes');
  IF v_limite IS NOT NULL THEN
    SET v_exceso = CAST(fn_uso_app(p_empresa, p_app, 'sedes') AS SIGNED) - CAST(v_limite AS SIGNED);
    IF v_exceso > 0 THEN
      DELETE sa FROM sede_aplicativos sa
        JOIN (SELECT sa2.sede_id
                FROM sede_aplicativos sa2
                JOIN sedes s ON s.id = sa2.sede_id
               WHERE s.empresa_id = p_empresa AND sa2.aplicativo = p_app
                 AND s.activo = 1 AND s.deleted_at IS NULL
               ORDER BY s.es_principal ASC, sa2.elegida_en DESC, sa2.sede_id DESC
               LIMIT v_exceso) x ON x.sede_id = sa.sede_id
       WHERE sa.aplicativo = p_app;
    END IF;
  END IF;
END$$

DELIMITER ;

-- Sedes de cada app al migrar: todas las activas, hasta el límite de la app
-- (primero la principal, luego las más antiguas).
INSERT IGNORE INTO sede_aplicativos (sede_id, aplicativo, elegida_en)
SELECT x.id, x.app, UTC_TIMESTAMP(3)
  FROM (SELECT s.id, a.app, s.empresa_id,
               ROW_NUMBER() OVER (PARTITION BY s.empresa_id, a.app ORDER BY s.es_principal DESC, s.id) AS n
          FROM sedes s
         CROSS JOIN (SELECT 'INVENTARIO' AS app UNION ALL SELECT 'ASISTENCIA') a
         WHERE s.activo = 1 AND s.deleted_at IS NULL) x
 WHERE x.n <= COALESCE(fn_limite_app(x.empresa_id, x.app, 'sedes'), 4294967295);

-- ─── 6. Triggers de cupo por app ────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_sedes_cupo_insert;
DROP TRIGGER IF EXISTS trg_sedes_cupo_update;
DROP TRIGGER IF EXISTS trg_sa_cupo_insert;
DROP TRIGGER IF EXISTS trg_productos_cupo_insert;
DROP TRIGGER IF EXISTS trg_productos_cupo_update;
DROP TRIGGER IF EXISTS trg_usuarios_cupo_insert;
DROP TRIGGER IF EXISTS trg_usuarios_cupo_update;

DELIMITER $$

-- Sedes de la empresa: tope = el mayor de sus planes.
CREATE TRIGGER trg_sedes_cupo_insert
BEFORE INSERT ON sedes
FOR EACH ROW
BEGIN
  DECLARE v_tope INT UNSIGNED;
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL THEN
    SET v_tope = fn_tope_sedes_empresa(NEW.empresa_id);
    IF v_tope IS NOT NULL AND (SELECT COUNT(*) FROM sedes
                                 WHERE empresa_id = NEW.empresa_id AND activo = 1
                                   AND deleted_at IS NULL) >= v_tope THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'LIMITE_PLAN:sedes';
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_sedes_cupo_update
BEFORE UPDATE ON sedes
FOR EACH ROW
BEGIN
  DECLARE v_tope INT UNSIGNED;
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL
     AND NOT (OLD.activo = 1 AND OLD.deleted_at IS NULL) THEN
    SET v_tope = fn_tope_sedes_empresa(NEW.empresa_id);
    IF v_tope IS NOT NULL AND (SELECT COUNT(*) FROM sedes
                                 WHERE empresa_id = NEW.empresa_id AND activo = 1
                                   AND deleted_at IS NULL) >= v_tope THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'LIMITE_PLAN:sedes';
    END IF;
  END IF;
END$$

-- Elegir una sede para una app: cupo de sedes de ESA app.
CREATE TRIGGER trg_sa_cupo_insert
BEFORE INSERT ON sede_aplicativos
FOR EACH ROW
BEGIN
  CALL sp_exigir_cupo_app((SELECT empresa_id FROM sedes WHERE id = NEW.sede_id), NEW.aplicativo, 'sedes');
END$$

CREATE TRIGGER trg_productos_cupo_insert
BEFORE INSERT ON productos
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL THEN
    CALL sp_exigir_cupo_app(NEW.empresa_id, 'INVENTARIO', 'productos');
  END IF;
END$$

CREATE TRIGGER trg_productos_cupo_update
BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL
     AND NOT (OLD.activo = 1 AND OLD.deleted_at IS NULL) THEN
    CALL sp_exigir_cupo_app(NEW.empresa_id, 'INVENTARIO', 'productos');
  END IF;
END$$

-- Una cuenta ocupa cupo en cada app donde tiene rol y no está en pausa.
-- En ASISTENCIA, crear la cuenta de alguien que ya marcaba (ficha sin cuenta)
-- no ocupa un cupo nuevo: el backend fija @cupo_vincula_empleado antes.
CREATE TRIGGER trg_usuarios_cupo_insert
BEFORE INSERT ON usuarios
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL AND NEW.es_superadmin = 0 THEN
    IF NEW.rol IS NOT NULL AND NEW.pausa_inventario = 0 THEN
      CALL sp_exigir_cupo_app(NEW.empresa_id, 'INVENTARIO', 'personas');
    END IF;
    IF NEW.rol_asistencia IS NOT NULL AND NEW.rol_asistencia <> 'OPERARIO'
       AND NEW.pausa_asistencia = 0 AND NOT fn_vinculo_ya_contado(NEW.empresa_id) THEN
      CALL sp_exigir_cupo_app(NEW.empresa_id, 'ASISTENCIA', 'personas');
    END IF;
  END IF;
END$$

CREATE TRIGGER trg_usuarios_cupo_update
BEFORE UPDATE ON usuarios
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL AND NEW.es_superadmin = 0 THEN
    -- Pasa a contar en Ventario (reactivada, con rol nuevo o sin pausa).
    IF NEW.rol IS NOT NULL AND NEW.pausa_inventario = 0
       AND NOT (OLD.activo = 1 AND OLD.deleted_at IS NULL AND OLD.rol IS NOT NULL
                AND OLD.pausa_inventario = 0) THEN
      CALL sp_exigir_cupo_app(NEW.empresa_id, 'INVENTARIO', 'personas');
    END IF;
    -- Pasa a contar en Presente.
    IF NEW.rol_asistencia IS NOT NULL AND NEW.rol_asistencia <> 'OPERARIO' AND NEW.pausa_asistencia = 0
       AND NOT (OLD.activo = 1 AND OLD.deleted_at IS NULL AND OLD.rol_asistencia IS NOT NULL
                AND OLD.rol_asistencia <> 'OPERARIO' AND OLD.pausa_asistencia = 0) THEN
      CALL sp_exigir_cupo_app(NEW.empresa_id, 'ASISTENCIA', 'personas');
    END IF;
  END IF;
END$$

DELIMITER ;

-- ─── 7. Uso frente a límites, por app ───────────────────────────────────────

CREATE OR REPLACE VIEW v_empresa_uso_app AS
SELECT e.id                                         AS empresa_id,
       e.uuid                                       AS empresa_uuid,
       e.estado,
       ep.aplicativo,
       COALESCE(ea.activo, 0)                       AS app_activa,
       p.id                                         AS plan_id,
       p.codigo                                     AS plan_codigo,
       p.nombre                                     AS plan_nombre,
       ep.plan_vence,
       (ep.plan_id <> p.id)                         AS plan_vencido,
       ep.plan_id                                   AS plan_contratado_id,
       fn_uso_app(e.id, ep.aplicativo, 'sedes')     AS sedes_usadas,
       p.max_sedes,
       fn_uso_app(e.id, ep.aplicativo, 'personas')  AS personas_usadas,
       p.max_personas,
       fn_uso_app(e.id, ep.aplicativo, 'productos') AS productos_usados,
       IF(ep.aplicativo = 'INVENTARIO', p.max_productos, NULL) AS max_productos,
       (SELECT COUNT(*) FROM sedes s
         WHERE s.empresa_id = e.id AND s.activo = 1 AND s.deleted_at IS NULL) AS sedes_empresa,
       fn_tope_sedes_empresa(e.id)                  AS tope_sedes_empresa
  FROM empresas e
  JOIN empresa_planes ep ON ep.empresa_id = e.id
  JOIN planes p ON p.id = fn_plan_app(e.id, ep.aplicativo)
  LEFT JOIN empresa_aplicativos ea ON ea.empresa_id = e.id AND ea.aplicativo = ep.aplicativo
 WHERE e.deleted_at IS NULL;

-- ─── 8. Registro de una empresa: las dos apps, Gratis en cada una ───────────

DROP PROCEDURE IF EXISTS sp_registrar_empresa;
DELIMITER $$
CREATE PROCEDURE sp_registrar_empresa(
  IN p_empresa_uuid    CHAR(36),
  IN p_empresa_nombre  VARCHAR(120),
  IN p_nit             VARCHAR(30),
  IN p_telefono        VARCHAR(30),
  IN p_sede_uuid       CHAR(36),
  IN p_sede_nombre     VARCHAR(120),
  IN p_sede_codigo     VARCHAR(10),
  IN p_usuario_uuid    CHAR(36),
  IN p_usuario_nombre  VARCHAR(120),
  IN p_email           VARCHAR(191),
  IN p_password_hash   VARCHAR(255),
  IN p_aplicativo      VARCHAR(12)
)
BEGIN
  DECLARE v_empresa BIGINT UNSIGNED;
  DECLARE v_sede    BIGINT UNSIGNED;
  DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE v_gratis  SMALLINT UNSIGNED;

  -- p_aplicativo se conserva por compatibilidad: ambas apps nacen activas.
  IF p_aplicativo NOT IN ('INVENTARIO','ASISTENCIA') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'APLICATIVO_INVALIDO';
  END IF;
  IF EXISTS (SELECT 1 FROM usuarios WHERE email = p_email) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'EMAIL_EN_USO';
  END IF;
  SET v_gratis = (SELECT id FROM planes WHERE codigo = 'GRATIS');

  INSERT INTO empresas (uuid, nombre, nit, telefono, email_contacto, plan_id, terminos_aceptados_en)
  VALUES (p_empresa_uuid, p_empresa_nombre, NULLIF(p_nit, ''), NULLIF(p_telefono, ''), p_email,
          v_gratis, UTC_TIMESTAMP(3));
  SET v_empresa = LAST_INSERT_ID();

  INSERT INTO empresa_aplicativos (empresa_id, aplicativo) VALUES
    (v_empresa, 'INVENTARIO'), (v_empresa, 'ASISTENCIA');
  INSERT INTO empresa_planes (empresa_id, aplicativo, plan_id) VALUES
    (v_empresa, 'INVENTARIO', v_gratis), (v_empresa, 'ASISTENCIA', v_gratis);

  INSERT INTO empresa_configuracion (empresa_id, clave, valor, tipo, descripcion) VALUES
    (v_empresa, 'nombre_negocio',          p_empresa_nombre,          'STRING',  'Nombre que aparece en el ticket'),
    (v_empresa, 'nit',                     COALESCE(p_nit, ''),       'STRING',  'NIT o identificación fiscal'),
    (v_empresa, 'direccion',               '',                        'STRING',  NULL),
    (v_empresa, 'telefono',                COALESCE(p_telefono, ''),  'STRING',  NULL),
    (v_empresa, 'moneda',                  'COP',                     'STRING',  NULL),
    (v_empresa, 'zona_horaria',            'America/Bogota',          'STRING',  NULL),
    (v_empresa, 'iva_por_defecto',         '19.00',                   'DECIMAL', 'Tasa aplicada a productos nuevos'),
    (v_empresa, 'permitir_stock_negativo', 'true',                    'BOOL',    'Acepta sobreventa offline y genera alerta'),
    (v_empresa, 'permite_credito',         'false',                   'BOOL',    'Habilita el cobro a crédito (fiado)'),
    (v_empresa, 'ticket_pie',              '¡Gracias por su compra!', 'STRING',  NULL),
    (v_empresa, 'offline_grace_days',      '7',                       'INT',     'Días que la app opera sin ver el servidor');

  INSERT INTO metodos_pago (uuid, empresa_id, nombre, tipo, orden, color) VALUES
    (UUID(), v_empresa, 'Efectivo',      'EFECTIVO',      1, '#11794F'),
    (UUID(), v_empresa, 'Tarjeta',       'TARJETA',       2, '#1D4ED8'),
    (UUID(), v_empresa, 'Transferencia', 'TRANSFERENCIA', 3, '#6750A4');

  INSERT INTO sedes (uuid, empresa_id, nombre, codigo, telefono, es_principal)
  VALUES (p_sede_uuid, v_empresa, p_sede_nombre, p_sede_codigo, NULLIF(p_telefono, ''), 1);
  SET v_sede = LAST_INSERT_ID();

  INSERT INTO usuarios (uuid, empresa_id, nombre, email, password_hash, rol, rol_asistencia)
  VALUES (p_usuario_uuid, v_empresa, p_usuario_nombre, p_email, p_password_hash, 'ADMIN', 'ADMIN');
  SET v_usuario = LAST_INSERT_ID();

  INSERT INTO sede_aplicativos (sede_id, aplicativo, elegida_por) VALUES
    (v_sede, 'INVENTARIO', v_usuario), (v_sede, 'ASISTENCIA', v_usuario);

  SELECT v_empresa AS empresa_id, v_sede AS sede_id, v_usuario AS usuario_id;
END$$
DELIMITER ;
