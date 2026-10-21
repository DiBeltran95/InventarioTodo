-- ═════════════════════════════════════════════════════════════════════════════
-- 005 · Eliminación de cuentas con borrado REAL de datos personales
--
-- Google Play exige que eliminar la cuenta borre los datos, no que solo los
-- oculte. Hasta ahora eliminar marcaba `deleted_at` y desactivaba: el nombre,
-- el correo y el documento seguían ahí. Estos procedimientos los anonimizan en
-- el acto; las ventas, movimientos y marcaciones se conservan (son registros
-- del negocio) pero ya no apuntan a una persona identificable.
--
-- Los usan los dos backends (Ventario y Presente), para que borren lo mismo.
-- Control de Personal los redefine (003) para anonimizar también su ficha.
-- ═════════════════════════════════════════════════════════════════════════════

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

DROP PROCEDURE IF EXISTS sp_anonimizar_usuario;
DROP PROCEDURE IF EXISTS sp_anonimizar_empresa;

DELIMITER $$

-- Una persona: sin nombre, correo, documento ni contraseña utilizables. El
-- correo pasa a uno imposible (dominio .invalid) para liberar el original:
-- la persona podría volver a registrarse con él.
CREATE PROCEDURE sp_anonimizar_usuario(IN p_usuario BIGINT UNSIGNED)
BEGIN
  UPDATE usuarios
     SET nombre             = 'Cuenta eliminada',
         email              = CONCAT('eliminado-', uuid, '@eliminado.invalid'),
         documento          = NULL,
         telefono           = NULL,
         password_hash      = '!',
         horario            = NULL,
         restringir_horario = 0,
         acceso_extra_hasta = NULL,
         activo             = 0,
         deleted_at         = COALESCE(deleted_at, UTC_TIMESTAMP(3))
   WHERE id = p_usuario;

  UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3)
   WHERE usuario_id = p_usuario AND revoked_at IS NULL;
  DELETE FROM codigos_verificacion WHERE usuario_id = p_usuario;
END$$

-- Una empresa entera: se archiva, se borran sus datos de contacto y se
-- anonimizan todas sus cuentas. Productos y ventas (sin datos personales)
-- quedan archivados hasta que se pida su borrado definitivo.
CREATE PROCEDURE sp_anonimizar_empresa(IN p_empresa BIGINT UNSIGNED)
BEGIN
  DECLARE v_fin TINYINT DEFAULT 0;
  DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE c_usuarios CURSOR FOR SELECT id FROM usuarios WHERE empresa_id = p_empresa;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;

  UPDATE empresas
     SET nombre         = 'Empresa eliminada',
         nit            = NULL,
         telefono       = NULL,
         email_contacto = NULL,
         estado         = 'SUSPENDIDA',
         deleted_at     = COALESCE(deleted_at, UTC_TIMESTAMP(3))
   WHERE id = p_empresa;
  -- Ticket, dirección, NIT…: pueden identificar al dueño.
  DELETE FROM empresa_configuracion WHERE empresa_id = p_empresa;

  OPEN c_usuarios;
  leer: LOOP
    FETCH c_usuarios INTO v_usuario;
    IF v_fin THEN LEAVE leer; END IF;
    CALL sp_anonimizar_usuario(v_usuario);
  END LOOP;
  CLOSE c_usuarios;
END$$

DELIMITER ;
