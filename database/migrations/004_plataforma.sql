-- ─────────────────────────────────────────────────────────────────────────────
-- 004 · Plataforma multiempresa
--
-- La base deja de ser de UN negocio: aloja muchas empresas que se registran
-- solas desde la app de Inventario o desde la de Control de Personal. Las dos
-- apps comparten esta base, la tabla `usuarios` y las sedes.
--
--   empresas ─┬─ sedes ─── (ventas, movimientos, stock, traslados, cierres,
--             │             dispositivos, marcaciones…: heredan la empresa
--             │             por su sede)
--             ├─ usuarios (uno por persona, con un rol en cada app)
--             ├─ catálogo (categorías, proveedores, productos, códigos,
--             │            medios de pago)
--             ├─ empresa_configuracion
--             └─ empresa_aplicativos (qué apps puede usar)
--
-- Reglas:
--   1. Los LÍMITES DEL PLAN se imponen aquí, con triggers. Dos backends (Node y
--      PHP) escriben en estas tablas: si el límite viviera en el código, bastaría
--      con que uno lo olvidara. El error es SQLSTATE 45000 con el mensaje
--      `LIMITE_PLAN:<recurso>`, y cada backend lo traduce a HTTP 409.
--   2. El REGISTRO de una empresa también vive aquí (sp_registrar_empresa): las
--      dos apps registran exactamente igual.
--   3. Si la base ya tenía datos (el negocio que existía antes de la
--      plataforma), todo pasa a una «empresa fundadora» con plan ILIMITADO y
--      las dos apps activas. En una base nueva no se crea ninguna empresa.
--
-- Se ejecuta UNA vez (scripts/migrate.mjs la anota en `schema_migraciones`),
-- pero cada sentencia tolera haberse aplicado ya.
-- ─────────────────────────────────────────────────────────────────────────────

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
-- La base hereda su collation a las funciones y procedimientos (sus parámetros
-- VARCHAR). Los hostings la crean con utf8mb4_general_ci y las tablas son
-- utf8mb4_unicode_ci: comparar ambas falla con «Illegal mix of collations».
ALTER DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';


-- ═════════════════════════════════════════════════════════════════════════════
-- 1. PLANES
--    NULL en un máximo = sin límite.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS planes (
  id             SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  codigo         VARCHAR(20) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  nombre         VARCHAR(60)  NOT NULL,
  descripcion    VARCHAR(255) NULL,
  max_sedes      SMALLINT UNSIGNED NULL,
  -- Personas distintas de la empresa: cuentas activas (gerentes incluidos) y
  -- empleados que solo marcan asistencia. El dueño cuenta.
  max_personas   SMALLINT UNSIGNED NULL,
  max_productos  INT UNSIGNED NULL,
  activo         TINYINT(1) NOT NULL DEFAULT 1,
  orden          SMALLINT NOT NULL DEFAULT 0,
  created_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  UNIQUE KEY uk_planes_codigo (codigo)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Planes de la plataforma y sus límites';

-- GRATIS es el plan con el que nace toda empresa registrada desde una app, y
-- al que vuelve cuando vence un plan pagado. ILIMITADO es el de las empresas
-- fundadoras. Los demás los crea el superadministrador desde el panel.
INSERT IGNORE INTO planes (codigo, nombre, descripcion, max_sedes, max_personas, max_productos, orden) VALUES
  ('GRATIS',    'Gratis',    'Para empezar: 1 sede, 3 personas y 3 productos', 1, 3, 3, 0),
  ('ILIMITADO', 'Ilimitado', 'Sin límites',                                   NULL, NULL, NULL, 99);


-- ═════════════════════════════════════════════════════════════════════════════
-- 2. EMPRESAS Y SUS PERMISOS SOBRE CADA APP
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS empresas (
  id                     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  uuid                   CHAR(36) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  nombre                 VARCHAR(120) NOT NULL,
  nit                    VARCHAR(30)  NULL,
  telefono               VARCHAR(30)  NULL,
  email_contacto         VARCHAR(191) NULL,
  plan_id                SMALLINT UNSIGNED NOT NULL,
  -- NULL = no vence. Vencido, la empresa opera con los límites de GRATIS
  -- (fn_plan_empresa) sin perder datos: lo que ya tenía sigue ahí, solo no
  -- puede crear más por encima del cupo gratuito.
  plan_vence             DATE NULL,
  estado                 ENUM('ACTIVA','SUSPENDIDA') NOT NULL DEFAULT 'ACTIVA',
  zona_horaria           VARCHAR(40) NOT NULL DEFAULT 'America/Bogota',
  -- Prefijo de los folios de las ventas hechas sin dispositivo (canal WEB).
  -- NULL = 'W' + id en base 36 (5 caracteres: nunca choca con los de 2-3 de
  -- los dispositivos). La empresa fundadora conserva 'WEB'.
  prefijo_web            VARCHAR(6) CHARACTER SET ascii COLLATE ascii_general_ci NULL,
  terminos_aceptados_en  DATETIME(3) NULL,
  notas_plataforma       VARCHAR(500) NULL COMMENT 'Solo las ve el superadministrador',
  created_at             DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at             DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  deleted_at             DATETIME(3) NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_empresas_uuid (uuid),
  UNIQUE KEY uk_empresas_prefijo_web (prefijo_web),
  KEY idx_empresas_plan (plan_id),
  KEY idx_empresas_sync (updated_at, id),
  CONSTRAINT fk_empresas_plan FOREIGN KEY (plan_id)
    REFERENCES planes (id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Empresas (clientes) de la plataforma';

-- Una fila por app habilitada. Sin fila, o con activo = 0, nadie de la empresa
-- entra a esa app aunque tenga rol en ella.
CREATE TABLE IF NOT EXISTS empresa_aplicativos (
  empresa_id  BIGINT UNSIGNED NOT NULL,
  aplicativo  ENUM('INVENTARIO','ASISTENCIA') NOT NULL,
  activo      TINYINT(1) NOT NULL DEFAULT 1,
  desde       DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (empresa_id, aplicativo),
  CONSTRAINT fk_ea_empresa FOREIGN KEY (empresa_id)
    REFERENCES empresas (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Apps que cada empresa tiene habilitadas';

-- Reemplaza a `configuracion` (que era del único negocio). `configuracion`
-- queda como respaldo de la empresa fundadora y ya no se lee.
CREATE TABLE IF NOT EXISTS empresa_configuracion (
  empresa_id   BIGINT UNSIGNED NOT NULL,
  clave        VARCHAR(64)  NOT NULL,
  valor        TEXT         NOT NULL,
  tipo         ENUM('STRING','INT','DECIMAL','BOOL','JSON') NOT NULL DEFAULT 'STRING',
  descripcion  VARCHAR(255) NULL,
  updated_at   DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  PRIMARY KEY (empresa_id, clave),
  CONSTRAINT fk_ec_empresa FOREIGN KEY (empresa_id)
    REFERENCES empresas (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Configuración del negocio, por empresa';


-- ═════════════════════════════════════════════════════════════════════════════
-- 3. USUARIOS: UNA CUENTA POR PERSONA, UN ROL POR APP
--
--   rol             → rol en Inventario (ADMIN = Director General). NULL = no
--                     entra a Inventario.
--   rol_asistencia  → rol en Control de Personal. NULL = no entra.
--                       ADMIN    todo dentro de la empresa
--                       GERENTE  sus sedes (las mismas de usuario_sedes)
--                       OPERADOR vincula y atiende kioscos
--   activo          → uno solo: inactivar a alguien lo saca de las dos apps.
--   es_superadmin   → administra la plataforma (no pertenece a ninguna empresa).
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE usuarios
  ADD COLUMN IF NOT EXISTS empresa_id     BIGINT UNSIGNED NULL AFTER uuid,
  ADD COLUMN IF NOT EXISTS documento      VARCHAR(20) CHARACTER SET ascii COLLATE ascii_general_ci NULL AFTER nombre,
  ADD COLUMN IF NOT EXISTS rol_asistencia ENUM('ADMIN','GERENTE','OPERADOR') NULL AFTER rol,
  ADD COLUMN IF NOT EXISTS es_superadmin  TINYINT(1) NOT NULL DEFAULT 0 AFTER rol_asistencia,
  ADD KEY IF NOT EXISTS idx_usuarios_empresa (empresa_id, activo),
  ADD UNIQUE KEY IF NOT EXISTS uk_usuarios_empresa_documento (empresa_id, documento);

-- ON UPDATE RESTRICT y no CASCADE: MariaDB no admite un CHECK sobre una columna
-- cuya llave foránea actualiza en cascada (ck_usuarios_empresa, más abajo), y
-- el id de una empresa nunca cambia. Se borra y se vuelve a crear para que una
-- corrida anterior que la dejó en CASCADE quede corregida.
ALTER TABLE usuarios DROP FOREIGN KEY IF EXISTS fk_usuarios_empresa;
ALTER TABLE usuarios
  ADD CONSTRAINT fk_usuarios_empresa FOREIGN KEY (empresa_id)
    REFERENCES empresas (id) ON DELETE RESTRICT ON UPDATE RESTRICT;

-- Sin valor por defecto: quien crea una cuenta dice explícitamente a qué apps
-- entra. Un default «VENDEDOR» le daría Inventario a quien solo debía marcar
-- asistencia.
ALTER TABLE usuarios
  MODIFY COLUMN rol ENUM('ADMIN','GERENTE','AUXILIAR_INVENTARIO','VENDEDOR') NULL DEFAULT NULL;

-- Códigos de un solo uso enviados por correo (recuperar la contraseña).
-- Solo el SHA-256 del código; vencen a los 15 minutos y admiten 5 intentos.
CREATE TABLE IF NOT EXISTS codigos_verificacion (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  usuario_id   BIGINT UNSIGNED NOT NULL,
  proposito    ENUM('RECUPERAR_CLAVE') NOT NULL,
  codigo_hash  CHAR(64) CHARACTER SET ascii COLLATE ascii_general_ci NOT NULL,
  intentos     TINYINT UNSIGNED NOT NULL DEFAULT 0,
  expira_en    DATETIME(3) NOT NULL,
  usado_en     DATETIME(3) NULL,
  created_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  PRIMARY KEY (id),
  KEY idx_cv_usuario (usuario_id, proposito, created_at),
  CONSTRAINT fk_cv_usuario FOREIGN KEY (usuario_id)
    REFERENCES usuarios (id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ═════════════════════════════════════════════════════════════════════════════
-- 4. EMPRESA EN SEDES Y CATÁLOGO
--    Lo que cuelga de una sede no la necesita: la hereda por `sede_id`.
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE sedes
  ADD COLUMN IF NOT EXISTS empresa_id BIGINT UNSIGNED NULL AFTER uuid;
ALTER TABLE categorias
  ADD COLUMN IF NOT EXISTS empresa_id BIGINT UNSIGNED NULL AFTER uuid;
ALTER TABLE proveedores
  ADD COLUMN IF NOT EXISTS empresa_id BIGINT UNSIGNED NULL AFTER uuid;
ALTER TABLE productos
  ADD COLUMN IF NOT EXISTS empresa_id BIGINT UNSIGNED NULL AFTER uuid;
ALTER TABLE producto_codigos
  ADD COLUMN IF NOT EXISTS empresa_id BIGINT UNSIGNED NULL AFTER uuid;
ALTER TABLE metodos_pago
  ADD COLUMN IF NOT EXISTS empresa_id BIGINT UNSIGNED NULL AFTER uuid;


-- ═════════════════════════════════════════════════════════════════════════════
-- 5. EMPRESA FUNDADORA (solo si la base ya tenía un negocio)
--
-- Hay negocio previo si existe alguna cuenta sin empresa. En una base recién
-- creada no hay ninguna (el seed corre después), y lo que crean las
-- migraciones 001 y 002 por su cuenta —tres medios de pago y una «Sede
-- principal» huérfanos— se descarta: cada empresa nueva trae los suyos.
-- ═════════════════════════════════════════════════════════════════════════════

SET @hay_negocio = (SELECT COUNT(*) > 0 FROM usuarios WHERE empresa_id IS NULL AND es_superadmin = 0);

INSERT INTO empresas (uuid, nombre, nit, telefono, plan_id, prefijo_web, terminos_aceptados_en)
SELECT UUID(),
       COALESCE(NULLIF((SELECT valor FROM configuracion WHERE clave = 'nombre_negocio'), ''), 'Mi negocio'),
       NULLIF((SELECT valor FROM configuracion WHERE clave = 'nit'), ''),
       NULLIF((SELECT valor FROM configuracion WHERE clave = 'telefono'), ''),
       (SELECT id FROM planes WHERE codigo = 'ILIMITADO'),
       'WEB',
       NULL
  FROM DUAL
 WHERE @hay_negocio
   AND NOT EXISTS (SELECT 1 FROM empresas WHERE prefijo_web = 'WEB');

SET @fundadora = (SELECT id FROM empresas WHERE prefijo_web = 'WEB' LIMIT 1);

UPDATE usuarios         SET empresa_id = @fundadora WHERE empresa_id IS NULL AND es_superadmin = 0 AND @fundadora IS NOT NULL;
UPDATE sedes            SET empresa_id = @fundadora WHERE empresa_id IS NULL AND @fundadora IS NOT NULL;
UPDATE categorias       SET empresa_id = @fundadora WHERE empresa_id IS NULL AND @fundadora IS NOT NULL;
UPDATE proveedores      SET empresa_id = @fundadora WHERE empresa_id IS NULL AND @fundadora IS NOT NULL;
UPDATE productos        SET empresa_id = @fundadora WHERE empresa_id IS NULL AND @fundadora IS NOT NULL;
UPDATE producto_codigos SET empresa_id = @fundadora WHERE empresa_id IS NULL AND @fundadora IS NOT NULL;
UPDATE metodos_pago     SET empresa_id = @fundadora WHERE empresa_id IS NULL AND @fundadora IS NOT NULL;

-- Base nueva: fuera los huérfanos de 001/002 (no los referencia nada: sin
-- cuentas no hubo ventas, ni stock, ni dispositivos).
DELETE FROM metodos_pago WHERE empresa_id IS NULL AND @fundadora IS NULL;
DELETE FROM usuario_sedes WHERE @fundadora IS NULL
   AND sede_id IN (SELECT id FROM sedes WHERE empresa_id IS NULL);
DELETE FROM stock_sedes WHERE @fundadora IS NULL
   AND sede_id IN (SELECT id FROM sedes WHERE empresa_id IS NULL);
DELETE FROM sedes WHERE empresa_id IS NULL AND @fundadora IS NULL;

INSERT IGNORE INTO empresa_aplicativos (empresa_id, aplicativo)
SELECT @fundadora, 'INVENTARIO' FROM DUAL WHERE @fundadora IS NOT NULL
UNION ALL
SELECT @fundadora, 'ASISTENCIA' FROM DUAL WHERE @fundadora IS NOT NULL;

INSERT IGNORE INTO empresa_configuracion (empresa_id, clave, valor, tipo, descripcion)
SELECT @fundadora, clave, valor, tipo, descripcion
  FROM configuracion
 WHERE @fundadora IS NOT NULL;

-- Hasta hoy los ADMIN y GERENTE de Inventario ya entraban a Control de
-- Personal como administrativos (el GERENTE limitado a sus sedes): conservan
-- ese acceso con el rol equivalente.
UPDATE usuarios
   SET rol_asistencia = IF(rol = 'ADMIN', 'ADMIN', 'GERENTE')
 WHERE rol IN ('ADMIN','GERENTE')
   AND rol_asistencia IS NULL
   AND empresa_id = @fundadora;


-- ═════════════════════════════════════════════════════════════════════════════
-- 6. EMPRESA OBLIGATORIA Y UNICIDAD POR EMPRESA
--    Dos empresas pueden tener la sede «CEN», el SKU «BEB-001» o el mismo
-- código de barras (el mismo producto de fábrica en dos tiendas distintas).
-- ═════════════════════════════════════════════════════════════════════════════

ALTER TABLE sedes
  MODIFY COLUMN empresa_id BIGINT UNSIGNED NOT NULL,
  DROP INDEX IF EXISTS uk_sedes_codigo,
  ADD UNIQUE KEY IF NOT EXISTS uk_sedes_empresa_codigo (empresa_id, codigo),
  ADD KEY IF NOT EXISTS idx_sedes_empresa (empresa_id, activo),
  ADD CONSTRAINT fk_sedes_empresa FOREIGN KEY IF NOT EXISTS (empresa_id)
    REFERENCES empresas (id) ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE categorias
  MODIFY COLUMN empresa_id BIGINT UNSIGNED NOT NULL,
  ADD KEY IF NOT EXISTS idx_categorias_empresa (empresa_id),
  ADD CONSTRAINT fk_categorias_empresa FOREIGN KEY IF NOT EXISTS (empresa_id)
    REFERENCES empresas (id) ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE proveedores
  MODIFY COLUMN empresa_id BIGINT UNSIGNED NOT NULL,
  ADD KEY IF NOT EXISTS idx_proveedores_empresa (empresa_id),
  ADD CONSTRAINT fk_proveedores_empresa FOREIGN KEY IF NOT EXISTS (empresa_id)
    REFERENCES empresas (id) ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE productos
  MODIFY COLUMN empresa_id BIGINT UNSIGNED NOT NULL,
  DROP INDEX IF EXISTS uk_productos_sku,
  ADD UNIQUE KEY IF NOT EXISTS uk_productos_empresa_sku (empresa_id, sku),
  ADD KEY IF NOT EXISTS idx_productos_empresa (empresa_id, activo, deleted_at),
  ADD CONSTRAINT fk_productos_empresa FOREIGN KEY IF NOT EXISTS (empresa_id)
    REFERENCES empresas (id) ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE producto_codigos
  MODIFY COLUMN empresa_id BIGINT UNSIGNED NOT NULL,
  DROP INDEX IF EXISTS uk_prodcod_codigo,
  ADD UNIQUE KEY IF NOT EXISTS uk_prodcod_empresa_codigo (empresa_id, codigo),
  ADD CONSTRAINT fk_prodcod_empresa FOREIGN KEY IF NOT EXISTS (empresa_id)
    REFERENCES empresas (id) ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE metodos_pago
  MODIFY COLUMN empresa_id BIGINT UNSIGNED NOT NULL,
  ADD KEY IF NOT EXISTS idx_metodos_pago_empresa (empresa_id),
  ADD CONSTRAINT fk_metodos_pago_empresa FOREIGN KEY IF NOT EXISTS (empresa_id)
    REFERENCES empresas (id) ON DELETE RESTRICT ON UPDATE CASCADE;

-- Toda cuenta es de una empresa, salvo la del superadministrador.
ALTER TABLE usuarios
  ADD CONSTRAINT IF NOT EXISTS ck_usuarios_empresa CHECK (es_superadmin = 1 OR empresa_id IS NOT NULL);

-- Un código de barras es de la empresa de su producto: el backend no tiene
-- que mandarla (ni puede equivocarse al hacerlo).
DROP TRIGGER IF EXISTS trg_prodcod_before_insert;
DELIMITER $$
CREATE TRIGGER trg_prodcod_before_insert
BEFORE INSERT ON producto_codigos
FOR EACH ROW
BEGIN
  SET NEW.empresa_id = (SELECT empresa_id FROM productos WHERE id = NEW.producto_id);
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_prodcod_before_update;
DELIMITER $$
CREATE TRIGGER trg_prodcod_before_update
BEFORE UPDATE ON producto_codigos
FOR EACH ROW
BEGIN
  IF NEW.producto_id <> OLD.producto_id THEN
    SET NEW.empresa_id = (SELECT empresa_id FROM productos WHERE id = NEW.producto_id);
  END IF;
END$$
DELIMITER ;


-- ═════════════════════════════════════════════════════════════════════════════
-- 7. SEDE DE RESPALDO, POR EMPRESA
--    Antes había UNA sede principal; ahora una por empresa. Una fila que llega
--    sin sede y sin dispositivo conocido ya no puede caer en «la» principal: con
--    varias empresas sería la de otra. Solo queda ese respaldo mientras la base
--    tenga una única empresa (la fundadora, durante la transición).
-- ═════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS fn_sede_principal;
DELIMITER $$
CREATE FUNCTION fn_sede_principal()
RETURNS BIGINT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  IF (SELECT COUNT(*) FROM empresas WHERE deleted_at IS NULL) <> 1 THEN
    RETURN NULL;
  END IF;
  RETURN (SELECT id FROM sedes
           WHERE es_principal = 1 AND deleted_at IS NULL
           ORDER BY id LIMIT 1);
END$$
DELIMITER ;


-- ═════════════════════════════════════════════════════════════════════════════
-- 8. LÍMITES DEL PLAN
-- ═════════════════════════════════════════════════════════════════════════════

-- Plan con el que opera hoy la empresa: el suyo, o GRATIS si ya venció.
DROP FUNCTION IF EXISTS fn_plan_empresa;
DELIMITER $$
CREATE FUNCTION fn_plan_empresa(p_empresa BIGINT UNSIGNED)
RETURNS SMALLINT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  RETURN (SELECT IF(e.plan_vence IS NULL OR e.plan_vence >= UTC_DATE(),
                    e.plan_id,
                    (SELECT id FROM planes WHERE codigo = 'GRATIS'))
            FROM empresas e WHERE e.id = p_empresa);
END$$
DELIMITER ;

-- Personas activas de la empresa. Aquí solo las cuentas: la migración de
-- Control de Personal (database/002_plataforma.sql de ese repositorio) la
-- REEMPLAZA para sumar los empleados que solo marcan asistencia. Si una
-- migración futura de este repositorio la vuelve a definir, debe incluirlos.
DROP FUNCTION IF EXISTS fn_personas_empresa;
DELIMITER $$
CREATE FUNCTION fn_personas_empresa(p_empresa BIGINT UNSIGNED)
RETURNS INT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  RETURN (SELECT COUNT(*) FROM usuarios
           WHERE empresa_id = p_empresa AND activo = 1
             AND deleted_at IS NULL AND es_superadmin = 0);
END$$
DELIMITER ;

-- Uso actual de un recurso: 'sedes', 'personas' o 'productos'.
DROP FUNCTION IF EXISTS fn_uso_empresa;
DELIMITER $$
CREATE FUNCTION fn_uso_empresa(p_empresa BIGINT UNSIGNED, p_recurso VARCHAR(20))
RETURNS INT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  CASE p_recurso
    WHEN 'sedes' THEN
      RETURN (SELECT COUNT(*) FROM sedes
               WHERE empresa_id = p_empresa AND activo = 1 AND deleted_at IS NULL);
    WHEN 'productos' THEN
      RETURN (SELECT COUNT(*) FROM productos
               WHERE empresa_id = p_empresa AND activo = 1 AND deleted_at IS NULL);
    WHEN 'personas' THEN
      RETURN fn_personas_empresa(p_empresa);
    ELSE
      RETURN 0;
  END CASE;
END$$
DELIMITER ;

-- Máximo del plan vigente. NULL = ilimitado.
DROP FUNCTION IF EXISTS fn_limite_empresa;
DELIMITER $$
CREATE FUNCTION fn_limite_empresa(p_empresa BIGINT UNSIGNED, p_recurso VARCHAR(20))
RETURNS INT UNSIGNED
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  RETURN (SELECT CASE p_recurso
                   WHEN 'sedes'     THEN p.max_sedes
                   WHEN 'personas'  THEN p.max_personas
                   WHEN 'productos' THEN p.max_productos
                 END
            FROM planes p WHERE p.id = fn_plan_empresa(p_empresa));
END$$
DELIMITER ;

-- Lanza LIMITE_PLAN si agregar UNO más del recurso excede el plan.
DROP PROCEDURE IF EXISTS sp_exigir_cupo;
DELIMITER $$
CREATE PROCEDURE sp_exigir_cupo(IN p_empresa BIGINT UNSIGNED, IN p_recurso VARCHAR(20))
BEGIN
  DECLARE v_limite INT UNSIGNED;
  DECLARE v_mensaje VARCHAR(128);
  SET v_limite = fn_limite_empresa(p_empresa, p_recurso);
  IF v_limite IS NOT NULL AND fn_uso_empresa(p_empresa, p_recurso) >= v_limite THEN
    SET v_mensaje = CONCAT('LIMITE_PLAN:', p_recurso);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_mensaje;
  END IF;
END$$
DELIMITER ;

-- Sedes: al crear una activa, o al reactivar / restaurar una.
DROP TRIGGER IF EXISTS trg_sedes_cupo_insert;
DELIMITER $$
CREATE TRIGGER trg_sedes_cupo_insert
BEFORE INSERT ON sedes
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL THEN
    CALL sp_exigir_cupo(NEW.empresa_id, 'sedes');
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_sedes_cupo_update;
DELIMITER $$
CREATE TRIGGER trg_sedes_cupo_update
BEFORE UPDATE ON sedes
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL
     AND NOT (OLD.activo = 1 AND OLD.deleted_at IS NULL) THEN
    CALL sp_exigir_cupo(NEW.empresa_id, 'sedes');
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_productos_cupo_insert;
DELIMITER $$
CREATE TRIGGER trg_productos_cupo_insert
BEFORE INSERT ON productos
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL THEN
    CALL sp_exigir_cupo(NEW.empresa_id, 'productos');
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_productos_cupo_update;
DELIMITER $$
CREATE TRIGGER trg_productos_cupo_update
BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL
     AND NOT (OLD.activo = 1 AND OLD.deleted_at IS NULL) THEN
    CALL sp_exigir_cupo(NEW.empresa_id, 'productos');
  END IF;
END$$
DELIMITER ;

-- Personas (cuentas). Excepción: convertir en cuenta a un empleado de
-- asistencia que ya contaba. Quien lo hace fija antes, en la misma conexión,
--   SET @cupo_vincula_empleado = <id del asis_empleado>;
-- y el empleado debe estar activo, sin cuenta y en la misma empresa: la
-- persona ya ocupaba su cupo, así que no se cuenta dos veces.
-- Aquí no hay empleados de asistencia: siempre 0. La migración 002 de Control
-- de Personal la REEMPLAZA con la comprobación real.
DROP FUNCTION IF EXISTS fn_vinculo_ya_contado;
DELIMITER $$
CREATE FUNCTION fn_vinculo_ya_contado(p_empresa BIGINT UNSIGNED)
RETURNS TINYINT
NOT DETERMINISTIC
READS SQL DATA
BEGIN
  RETURN 0;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_usuarios_cupo_insert;
DELIMITER $$
CREATE TRIGGER trg_usuarios_cupo_insert
BEFORE INSERT ON usuarios
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL AND NEW.es_superadmin = 0
     AND NOT fn_vinculo_ya_contado(NEW.empresa_id) THEN
    CALL sp_exigir_cupo(NEW.empresa_id, 'personas');
  END IF;
END$$
DELIMITER ;

DROP TRIGGER IF EXISTS trg_usuarios_cupo_update;
DELIMITER $$
CREATE TRIGGER trg_usuarios_cupo_update
BEFORE UPDATE ON usuarios
FOR EACH ROW
BEGIN
  IF NEW.activo = 1 AND NEW.deleted_at IS NULL AND NEW.es_superadmin = 0
     AND NOT (OLD.activo = 1 AND OLD.deleted_at IS NULL) THEN
    CALL sp_exigir_cupo(NEW.empresa_id, 'personas');
  END IF;
END$$
DELIMITER ;

-- Uso frente a límites, para las apps («Productos 3 de 3») y el panel.
CREATE OR REPLACE VIEW v_empresa_uso AS
SELECT e.id                               AS empresa_id,
       e.uuid                             AS empresa_uuid,
       e.estado,
       p.codigo                           AS plan_codigo,
       p.nombre                           AS plan_nombre,
       e.plan_vence,
       (e.plan_id <> p.id)                AS plan_vencido,
       fn_uso_empresa(e.id, 'sedes')      AS sedes_usadas,
       p.max_sedes,
       fn_uso_empresa(e.id, 'personas')   AS personas_usadas,
       p.max_personas,
       fn_uso_empresa(e.id, 'productos')  AS productos_usados,
       p.max_productos
  FROM empresas e
  JOIN planes p ON p.id = fn_plan_empresa(e.id)
 WHERE e.deleted_at IS NULL;


-- ═════════════════════════════════════════════════════════════════════════════
-- 9. REGISTRO DE UNA EMPRESA
--
-- Lo llaman los dos backends dentro de su propia transacción, con la
-- contraseña ya cifrada (argon2id) y los UUID generados por ellos. Crea la
-- empresa en plan GRATIS, habilita la app desde la que se registró, su
-- configuración inicial, los medios de pago básicos, la sede principal y al
-- dueño como ADMIN en las DOS apps (si luego habilitan la otra, ya tiene rol).
--
-- Errores (SQLSTATE 45000): EMAIL_EN_USO, APLICATIVO_INVALIDO.
-- Devuelve una fila: empresa_id, sede_id, usuario_id.
-- ═════════════════════════════════════════════════════════════════════════════

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

  IF p_aplicativo NOT IN ('INVENTARIO','ASISTENCIA') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'APLICATIVO_INVALIDO';
  END IF;
  IF EXISTS (SELECT 1 FROM usuarios WHERE email = p_email) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'EMAIL_EN_USO';
  END IF;

  INSERT INTO empresas (uuid, nombre, nit, telefono, email_contacto, plan_id, terminos_aceptados_en)
  VALUES (p_empresa_uuid, p_empresa_nombre, NULLIF(p_nit, ''), NULLIF(p_telefono, ''), p_email,
          (SELECT id FROM planes WHERE codigo = 'GRATIS'), UTC_TIMESTAMP(3));
  SET v_empresa = LAST_INSERT_ID();

  INSERT INTO empresa_aplicativos (empresa_id, aplicativo) VALUES (v_empresa, p_aplicativo);

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

  SELECT v_empresa AS empresa_id, v_sede AS sede_id, v_usuario AS usuario_id;
END$$
DELIMITER ;
