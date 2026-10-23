/**
 * Cuenta de la empresa en la plataforma.
 *
 *   POST   /cuenta/registro      crea empresa + sede principal + dueño (público)
 *   GET    /cuenta/empresa       datos, plan, uso y apps habilitadas
 *   PUT    /cuenta/empresa       edita nombre, NIT y teléfono (director)
 *   POST   /cuenta/recuperar     envía un código para cambiar la contraseña (público)
 *   POST   /cuenta/restablecer   cambia la contraseña con ese código (público)
 *   DELETE /cuenta               elimina la empresa (dueño) o la propia cuenta
 *
 * El registro lo hace la base (sp_registrar_empresa), igual que desde Control
 * de Personal: las dos apps crean empresas exactamente de la misma forma. El
 * contrato está en docs/PLATAFORMA.md.
 */
import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../../db/pool.js';
import { withTransaction, txQuery, txQueryOne, txExecute } from '../../db/tx.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { soloDirector } from '../../middleware/rbac.js';
import { limitadorLogin } from '../../middleware/rateLimit.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { ok, creado } from '../../utils/responder.js';
import { badRequest, conflict, unauthorized } from '../../utils/ApiError.js';
import { nuevoUuid, sha256 } from '../../utils/ids.js';
import { ROLES } from '../../config/constants.js';
import { enviarCorreo } from '../../utils/correo.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';
import { SQL_CUENTA_POR_CORREO } from '../auth/service.js';
import { hashearPassword, verificarPassword, login } from '../auth/service.js';
import { passwordSchema, dispositivoSchema } from '../auth/schemas.js';
import { traducirErrorSql } from '../../middleware/errorHandler.js';
import { planDeEmpresa, planesDeEmpresa, aplicativosDeEmpresa } from './repo.js';

const texto = (min, max) => z.string().trim().min(min).max(max);
const opcional = (max) => z.string().trim().max(max).optional().nullable().transform((v) => v || null);

const registroSchema = z.object({
  empresa: z.object({
    nombre: texto(2, 120),
    nit: opcional(30),
    telefono: opcional(30),
  }),
  sede: z.object({
    nombre: texto(2, 120),
    codigo: z
      .string()
      .trim()
      .toUpperCase()
      .regex(/^[A-Z0-9]{2,10}$/, 'De 2 a 10 letras o números')
      .optional(),
  }),
  usuario: z.object({
    nombre: texto(2, 120),
    email: z.string().email('Correo no válido').max(191).toLowerCase().trim(),
    password: passwordSchema,
  }),
  // Términos y tratamiento de datos (Ley 1581): sin aceptarlos no hay cuenta.
  acepta_terminos: z.literal(true, { errorMap: () => ({ message: 'Debes aceptar los términos' }) }),
  dispositivo: dispositivoSchema.optional(),
});

const empresaSchema = z
  .object({ nombre: texto(2, 120).optional(), nit: opcional(30), telefono: opcional(30) })
  .refine((d) => Object.values(d).some((v) => v !== undefined), 'No se envió ningún cambio');

const recuperarSchema = z.object({ email: z.string().email().max(191).toLowerCase().trim() });

const restablecerSchema = z.object({
  email: z.string().email().max(191).toLowerCase().trim(),
  codigo: z.string().trim().regex(/^\d{6}$/, 'El código tiene 6 números'),
  password: passwordSchema,
});

const eliminarSchema = z.object({
  password: z.string().min(1).max(200),
  // El dueño escribe el nombre de la empresa: borrarla no puede ser un toque
  // accidental.
  confirmacion: z.string().trim().max(120).optional(),
});

/** Código de sede sugerido a partir del nombre: «Sede Norte» → «NOR». */
export function codigoSugerido(nombre) {
  const limpio = nombre
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toUpperCase()
    .replace(/\bSEDE\b/g, '')
    .replace(/[^A-Z0-9]/g, '');
  return (limpio.slice(0, 3) || 'PRI').padEnd(2, '0');
}

// ── Registro ────────────────────────────────────────────────────────────────

async function registrar(d, userAgent) {
  const hash = await hashearPassword(d.usuario.password);
  try {
    await withTransaction(async (conn) => {
      await txQuery(conn, 'CALL sp_registrar_empresa(?,?,?,?,?,?,?,?,?,?,?,?)', [
        nuevoUuid(),
        d.empresa.nombre,
        d.empresa.nit,
        d.empresa.telefono,
        nuevoUuid(),
        d.sede.nombre,
        d.sede.codigo ?? codigoSugerido(d.sede.nombre),
        nuevoUuid(),
        d.usuario.nombre,
        d.usuario.email,
        hash,
        'INVENTARIO',
      ]);
    });
  } catch (err) {
    throw traducirErrorSql(err) ?? err;
  }
  // Recién creada, la sesión se abre de una vez: nada de «ahora inicia sesión».
  return login({ email: d.usuario.email, password: d.usuario.password, dispositivo: d.dispositivo }, userAgent);
}

// ── Empresa ─────────────────────────────────────────────────────────────────

async function verEmpresa(empresaId) {
  const empresa = await queryOne(
    'SELECT uuid, nombre, nit, telefono, email_contacto, created_at FROM empresas WHERE id = ?',
    [empresaId],
  );
  return {
    empresa,
    plan: await planDeEmpresa(empresaId),
    planes: await planesDeEmpresa(empresaId),
    aplicativos: await aplicativosDeEmpresa(empresaId),
  };
}

/** Los mismos datos viven en la configuración del ticket: se cambian juntos. */
const CLAVE_CONFIG = { nombre: 'nombre_negocio', nit: 'nit', telefono: 'telefono' };

async function editarEmpresa(empresaId, datos) {
  await withTransaction(async (conn) => {
    for (const [campo, valor] of Object.entries(datos)) {
      if (valor === undefined) continue;
      await txExecute(conn, `UPDATE empresas SET ${campo} = ? WHERE id = ?`, [valor, empresaId]);
      await txExecute(
        conn,
        `INSERT INTO empresa_configuracion (empresa_id, clave, valor, tipo) VALUES (?,?,?, 'STRING')
         ON DUPLICATE KEY UPDATE valor = VALUES(valor)`,
        [empresaId, CLAVE_CONFIG[campo], valor ?? ''],
      );
    }
  });
  return verEmpresa(empresaId);
}

// ── Recuperar la contraseña ─────────────────────────────────────────────────

const VIGENCIA_CODIGO_MIN = 15;
const INTENTOS_CODIGO = 5;
const hashCodigo = (usuarioId, codigo) => sha256(`${usuarioId}:${codigo}`);

/**
 * Siempre responde lo mismo, exista o no el correo: la respuesta no puede
 * servir para averiguar quién tiene cuenta.
 */
async function recuperar({ email }) {
  // aislamiento: el correo es la identidad global para entrar a la plataforma
  const u = await queryOne(
    `SELECT id, nombre FROM v_usuarios
      WHERE id IN (${SQL_CUENTA_POR_CORREO}) AND activo = 1 AND deleted_at IS NULL
        AND COALESCE(empleado_activo, 1) = 1`,
    [email, email],
  );
  if (u) {
    const codigo = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
    await query(
      `INSERT INTO codigos_verificacion (usuario_id, proposito, codigo_hash, expira_en)
       VALUES (?, 'RECUPERAR_CLAVE', ?, DATE_ADD(UTC_TIMESTAMP(3), INTERVAL ? MINUTE))`,
      [u.id, hashCodigo(u.id, codigo), VIGENCIA_CODIGO_MIN],
    );
    await enviarCorreo({
      para: email,
      asunto: `Tu código para cambiar la contraseña: ${codigo}`,
      texto:
        `Hola, ${u.nombre}.\n\n` +
        `Tu código es ${codigo}. Escríbelo en la app para crear una contraseña nueva.\n` +
        `Vence en ${VIGENCIA_CODIGO_MIN} minutos.\n\n` +
        'Si no lo pediste, ignora este correo: tu contraseña sigue igual.\n',
    });
  }
  return { enviado: true, vigencia_minutos: VIGENCIA_CODIGO_MIN };
}

async function restablecer({ email, codigo, password }) {
  const invalido = () =>
    badRequest('CODIGO_INVALIDO', 'El código no es válido o ya venció. Pide uno nuevo.');
  // aislamiento: el correo es la identidad global para entrar a la plataforma
  const u = await queryOne(
    `SELECT id FROM usuarios WHERE id IN (${SQL_CUENTA_POR_CORREO}) AND activo = 1 AND deleted_at IS NULL`,
    [email, email],
  );
  if (!u) throw invalido();

  // Solo el último código vale: pedir otro invalida los anteriores.
  const ultimo = () =>
    `SELECT id, codigo_hash, intentos, expira_en, usado_en FROM codigos_verificacion
      WHERE usuario_id = ? AND proposito = 'RECUPERAR_CLAVE' ORDER BY id DESC LIMIT 1`;
  const vigente = (c) =>
    c && !c.usado_en && new Date(c.expira_en).getTime() >= Date.now() && c.intentos < INTENTOS_CODIGO;

  const c = await queryOne(ultimo(), [u.id]);
  if (!vigente(c)) throw invalido();
  if (c.codigo_hash !== hashCodigo(u.id, codigo)) {
    // Fuera de transacción a propósito: el intento fallido queda contado
    // aunque la petición termine en error. Con 5, el código muere.
    await query('UPDATE codigos_verificacion SET intentos = intentos + 1 WHERE id = ?', [c.id]);
    throw invalido();
  }

  return withTransaction(async (conn) => {
    // Se relee bloqueado: dos usos simultáneos del mismo código no pasan ambos.
    const actual = await txQueryOne(conn, `${ultimo()} FOR UPDATE`, [u.id]);
    if (!vigente(actual) || actual.id !== c.id) throw invalido();
    await txExecute(conn, 'UPDATE codigos_verificacion SET usado_en = UTC_TIMESTAMP(3) WHERE id = ?', [c.id]);
    await txExecute(conn, 'UPDATE usuarios SET password_hash = ? WHERE id = ?', [
      await hashearPassword(password),
      u.id,
    ]);
    // Como al cambiarla a mano: se cierran todas las sesiones abiertas.
    await txExecute(
      conn,
      'UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3) WHERE usuario_id = ? AND revoked_at IS NULL',
      [u.id],
    );
    return { ok: true };
  });
}

// ── Eliminar ────────────────────────────────────────────────────────────────

/**
 * Play exige que quien crea una cuenta pueda borrarla desde la app.
 *
 *   · El dueño (director) elimina la EMPRESA: nadie de ella vuelve a entrar y
 *     se anonimizan en el acto todas sus cuentas y fichas de asistencia
 *     (sp_anonimizar_empresa). Ventas y movimientos se conservan sin persona
 *     identificable.
 *   · Cualquier otra persona elimina SU cuenta (sp_anonimizar_usuario).
 *
 * Las fotos del rostro viven en el servidor de Presente: las borra su tarea
 * diaria (bin/limpiar_fotos.php).
 */
async function eliminar(req, { password, confirmacion }) {
  const u = await queryOne('SELECT id, password_hash FROM usuarios WHERE id = ?', [req.usuario.id]);
  if (!(await verificarPassword(u.password_hash, password))) {
    throw unauthorized('La contraseña no es correcta', 'PASSWORD_INCORRECTA');
  }
  const empresaId = req.empresaId;
  const esDueno = req.usuario.rol === ROLES.ADMIN;

  return withTransaction(async (conn) => {
    if (esDueno) {
      const e = await txQueryOne(conn, 'SELECT nombre FROM empresas WHERE id = ?', [empresaId]);
      if ((confirmacion ?? '').toLowerCase() !== e.nombre.trim().toLowerCase()) {
        throw conflict('CONFIRMACION_INVALIDA', 'Escribe el nombre de la empresa tal como aparece para confirmar');
      }
      await txExecute(conn, 'CALL sp_anonimizar_empresa(?)', [empresaId]);
      return { eliminada: 'empresa' };
    }
    await txExecute(conn, 'CALL sp_anonimizar_usuario(?)', [req.usuario.id]);
    await registrarAuditoria(conn, {
      usuarioId: req.usuario.id,
      sedeId: req.alcance.sedeIds[0] ?? null,
      dispositivoUuid: req.dispositivoUuid,
      accion: ACCIONES.USUARIO_ELIMINADO,
      entidad: 'usuarios',
      entidadUuid: req.usuario.uuid,
      antes: { por: 'el propio usuario' },
    });
    return { eliminada: 'cuenta' };
  });
}

// ── Rutas ───────────────────────────────────────────────────────────────────

const router = Router();

router.post(
  '/registro',
  limitadorLogin,
  validar({ body: registroSchema }),
  asyncHandler(async (req, res) => creado(res, await registrar(req.body, req.headers['user-agent']))),
);

router.post(
  '/recuperar',
  limitadorLogin,
  validar({ body: recuperarSchema }),
  asyncHandler(async (req, res) => ok(res, await recuperar(req.body))),
);

router.post(
  '/restablecer',
  limitadorLogin,
  validar({ body: restablecerSchema }),
  asyncHandler(async (req, res) => ok(res, await restablecer(req.body))),
);

router.get(
  '/empresa',
  autenticar,
  asyncHandler(async (req, res) => ok(res, await verEmpresa(req.empresaId))),
);

router.put(
  '/empresa',
  autenticar,
  soloDirector,
  validar({ body: empresaSchema }),
  asyncHandler(async (req, res) => ok(res, await editarEmpresa(req.empresaId, req.body))),
);

router.delete(
  '/',
  autenticar,
  validar({ body: eliminarSchema }),
  asyncHandler(async (req, res) => ok(res, await eliminar(req, req.body))),
);

export default router;
