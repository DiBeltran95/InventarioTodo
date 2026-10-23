/**
 * Empleados: cuentas, sedes, horario, habilitación y acceso extra.
 *
 * Montado en /auth/usuarios para que la app vieja siga encontrando sus rutas.
 *
 * Quién gestiona a quién (`puedeAdministrar`):
 *   · Director General → a todos.
 *   · Gerente de Sede  → sólo a vendedores y auxiliares de sus sedes. No crea ni
 *     edita gerentes ni directores: sería escalar sus propios privilegios.
 *
 * Inhabilitar a alguien revoca TODAS sus sesiones, y el middleware de
 * autenticación rechaza su siguiente petición. La app, al recibir
 * CUENTA_DESACTIVADA, cierra la sesión en el teléfono.
 *
 * Plataforma multiempresa: la PERSONA vive una sola vez, en `empleados`
 * (documento, nombre, correo, teléfono, cargo, sede), para las dos apps. La
 * cuenta (`usuarios`) solo guarda a qué empleado pertenece (`empleado_id`),
 * la contraseña, los roles, las pausas y el horario; se lee con la vista
 * `v_usuarios`, que une las dos. Aquí se le da acceso a Ventario (`rol`); su
 * rol en Presente (`rol_asistencia`) lo decide Presente y no se toca, salvo
 * el director, que es administrador en las dos. Todo empleado creado aquí
 * aparece en Presente (solo le falta el rostro). La contraseña se genera al
 * azar y la persona crea la suya con «¿Olvidaste tu contraseña?», escribiendo
 * el correo DEL EMPLEADO. Todo se acota a la empresa del gestor, y el cupo de
 * personas del plan lo exige la base (LIMITE_PLAN → 409).
 *
 * Ojo: un UPDATE de `empleados` no puede cruzarse (JOIN o subconsulta) con
 * `usuarios`: su trigger marca la cuenta como modificada.
 */
import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../../db/pool.js';
import { withTransaction, txQuery, txQueryOne, txExecute } from '../../db/tx.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { soloGestor } from '../../middleware/rbac.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { ok, creado } from '../../utils/responder.js';
import { badRequest, conflict, forbidden, notFound } from '../../utils/ApiError.js';
import { nuevoUuid } from '../../utils/ids.js';
import { env } from '../../config/env.js';
import { ROLES, TODOS_LOS_ROLES, ROLES_DE_UNA_SEDE } from '../../config/constants.js';
import { normalizarHorario, leerHorario, evaluarJornada, jornadaDe } from '../../domain/jornada.js';
import {
  puedeAdministrar,
  validarSedesDeRol,
  veSede,
  esDirector,
  normalizarRoles,
} from '../../domain/alcance.js';
import { enviarCorreo } from '../../utils/correo.js';
import { logger } from '../../utils/logger.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';
import { hashearPassword } from '../auth/service.js';
import { passwordSchema } from '../auth/schemas.js';

// ── Esquemas ────────────────────────────────────────────────────────────────

const HHMM = /^([01]\d|2[0-3]):([0-5]\d)$/;

const tramoSchema = z.object({
  dia: z.number().int().min(1).max(7),
  inicio: z.string().regex(HHMM, 'Formato HH:MM'),
  fin: z.string().regex(HHMM, 'Formato HH:MM'),
});

const crearSchema = z.object({
  uuid: z.string().uuid().optional(),
  nombre: z.string().min(2).max(120).trim(),
  email: z.string().email().max(191).toLowerCase().trim(),
  // Sin contraseña (lo normal): se genera al azar y se le avisa por correo
  // que cree la suya con «¿Olvidaste tu contraseña?».
  password: passwordSchema.optional(),
  rol: z.enum(TODOS_LOS_ROLES).default(ROLES.VENDEDOR),
  // El empleado es el mismo en Presente: el documento lo identifica en las dos apps.
  documento: z.string().trim().regex(/^[A-Za-z0-9.-]{3,20}$/, 'Documento de 3 a 20 letras o números'),
  telefono: z.string().max(30).optional().nullable(),
  sedes: z.array(z.string().uuid()).max(50).default([]),
  restringir_horario: z.boolean().default(false),
  horario: z.array(tramoSchema).max(28).default([]),
});

const actualizarSchema = z.object({
  nombre: z.string().min(2).max(120).trim().optional(),
  email: z.string().email().max(191).toLowerCase().trim().optional(),
  rol: z.enum(TODOS_LOS_ROLES).optional(),
  documento: z.string().trim().regex(/^[A-Za-z0-9.-]{3,20}$/, 'Documento de 3 a 20 letras o números').optional().nullable(),
  telefono: z.string().max(30).optional().nullable(),
  activo: z.boolean().optional(),
  password: passwordSchema.optional(),
  sedes: z.array(z.string().uuid()).max(50).optional(),
  restringir_horario: z.boolean().optional(),
  horario: z.array(tramoSchema).max(28).optional(),
});

const accesoExtraSchema = z
  .object({
    minutos: z.number().int().min(5).max(24 * 60).optional(),
    hasta: z.string().datetime({ offset: true }).optional(),
    motivo: z.string().max(255).optional().nullable(),
  })
  .refine((d) => d.minutos != null || d.hasta != null, {
    message: 'Indica cuántos minutos o hasta cuándo',
  });

const uuidParam = z.object({ uuid: z.string().uuid() });

const pausaSchema = z.object({
  aplicativo: z.enum(['INVENTARIO', 'ASISTENCIA']),
  pausada: z.boolean(),
});

const personasQuery = z.object({
  sede: z.string().uuid().optional(),
  q: z.string().trim().max(60).optional(),
});

// ── Lectura ─────────────────────────────────────────────────────────────────

/** Cuenta + sus datos de empleado + sus sedes. `conn` opcional (dentro de transacción). */
async function cargarEmpleado(uuid, empresaId, conn = null) {
  const leer = (sql, p) => (conn ? txQueryOne(conn, sql, p) : queryOne(sql, p));
  const u = await leer(
    `SELECT id, uuid, empleado_id, nombre, documento, email, rol, rol_asistencia, activo, pausa_inventario,
            pausa_asistencia, telefono, restringir_horario, horario, acceso_extra_hasta, ultimo_acceso,
            created_at, updated_at
       FROM v_usuarios WHERE uuid = ? AND empresa_id = ? AND deleted_at IS NULL`,
    [uuid, empresaId],
  );
  if (!u) throw notFound('Usuario');
  const sedes = conn
    ? await txQuery(
        conn,
        'SELECT s.id, s.uuid, s.nombre FROM usuario_sedes us JOIN sedes s ON s.id = us.sede_id WHERE us.usuario_id = ?',
        [u.id],
      )
    : await query(
        'SELECT s.id, s.uuid, s.nombre FROM usuario_sedes us JOIN sedes s ON s.id = us.sede_id WHERE us.usuario_id = ?',
        [u.id],
      );
  return { ...u, sedes, sedeIds: sedes.map((s) => Number(s.id)) };
}

function publico(u, ahora = new Date()) {
  const j = evaluarJornada(jornadaDe(u), ahora, env.BUSINESS_TIMEZONE);
  return {
    uuid: u.uuid,
    nombre: u.nombre,
    email: u.email,
    documento: u.documento ?? null,
    rol: u.rol ?? null,
    rol_asistencia: u.rol_asistencia ?? null,
    activo: !!u.activo,
    // En pausa por el plan en esa app (la cuenta sigue activa en la otra).
    pausa_inventario: !!u.pausa_inventario,
    pausa_asistencia: !!u.pausa_asistencia,
    telefono: u.telefono ?? null,
    sedes: u.sedes.map((s) => ({ uuid: s.uuid, nombre: s.nombre })),
    restringir_horario: !!u.restringir_horario,
    horario: leerHorario(u.horario),
    acceso_extra_hasta: u.acceso_extra_hasta ? new Date(u.acceso_extra_hasta).toISOString() : null,
    jornada: {
      permitido: j.permitido,
      motivo: j.motivo,
      hasta: j.hasta?.toISOString() ?? null,
      proximo_inicio: j.proximoInicio?.toISOString() ?? null,
    },
    ultimo_acceso: u.ultimo_acceso ?? null,
    created_at: u.created_at,
    updated_at: u.updated_at,
  };
}

export async function listar(gestor) {
  const filas = await query(
    `SELECT u.id, u.uuid, u.nombre, u.documento, u.email, u.rol, u.rol_asistencia, u.activo,
            u.pausa_inventario, u.pausa_asistencia, u.telefono, u.restringir_horario,
            u.horario, u.acceso_extra_hasta, u.ultimo_acceso, u.created_at, u.updated_at,
            GROUP_CONCAT(CONCAT(s.id, '|', s.uuid, '|', s.nombre) ORDER BY s.nombre SEPARATOR '\\n') AS sedes_txt
       FROM v_usuarios u
       LEFT JOIN usuario_sedes us ON us.usuario_id = u.id
       LEFT JOIN sedes s ON s.id = us.sede_id AND s.deleted_at IS NULL
      WHERE u.deleted_at IS NULL AND u.empresa_id = ? AND (u.rol IS NOT NULL OR u.id = ?)
      GROUP BY u.id, u.uuid, u.nombre, u.documento, u.email, u.rol, u.rol_asistencia, u.activo,
               u.pausa_inventario, u.pausa_asistencia, u.telefono, u.restringir_horario,
               u.horario, u.acceso_extra_hasta, u.ultimo_acceso, u.created_at, u.updated_at
      ORDER BY u.nombre`,
    [gestor.alcance.empresaId, gestor.usuario.id],
  );
  const ahora = new Date();
  return filas
    .map((f) => {
      const sedes = (f.sedes_txt ?? '')
        .split('\n')
        .filter(Boolean)
        .map((t) => {
          const [id, uuid, ...nombre] = t.split('|');
          return { id: Number(id), uuid, nombre: nombre.join('|') };
        });
      return { ...f, sedes, sedeIds: sedes.map((s) => s.id) };
    })
    .filter((u) => u.id === gestor.usuario.id || puedeAdministrar(gestor, u))
    .map((u) => publico(u, ahora));
}

// ── Escritura ───────────────────────────────────────────────────────────────

/** Ids de sede a partir de uuids, comprobando que existen y están en alcance. */
async function resolverSedes(conn, uuids, gestor) {
  if (!uuids.length) return [];
  const filas = await txQuery(
    conn,
    'SELECT id, uuid FROM sedes WHERE uuid IN (?) AND empresa_id = ? AND deleted_at IS NULL',
    [uuids, gestor.alcance.empresaId],
  );
  if (filas.length !== new Set(uuids).size) throw notFound('Sede');
  for (const f of filas) {
    if (!veSede(gestor.alcance, f.id)) {
      throw forbidden('No puedes asignar personal a una sede que no gestionas', 'SEDE_FUERA_DE_ALCANCE');
    }
  }
  return filas.map((f) => Number(f.id));
}

function validarHorario(restringir, horario, rol) {
  let tramos;
  try {
    tramos = normalizarHorario(horario);
  } catch (e) {
    throw badRequest('HORARIO_INVALIDO', e.message);
  }
  if (restringir && rol === ROLES.ADMIN) {
    throw badRequest('HORARIO_DIRECTOR', 'El Director General no se restringe por horario');
  }
  if (restringir && !tramos.length) {
    throw badRequest(
      'HORARIO_VACIO',
      'Define al menos un tramo de horario antes de restringir el acceso: sin tramos, la persona no podría entrar nunca',
    );
  }
  return tramos;
}

/**
 * El gerente no puede crear ni convertir a nadie en gerente ni director: sería
 * escalar sus propios privilegios. Sí da acceso de vendedor y auxiliar.
 */
function exigirRolAsignable(gestor, rol) {
  if (esDirector(gestor.usuario.rol)) return;
  if (rol !== ROLES.VENDEDOR && rol !== ROLES.AUXILIAR_INVENTARIO) {
    throw forbidden('Un gerente sólo da acceso de vendedor o auxiliar de inventario', 'ROL_NO_ASIGNABLE');
  }
}

/** Contraseña inicial al azar: nadie la conoce; la persona crea la suya. */
const passwordAleatoria = () => crypto.randomBytes(24).toString('base64url');

/**
 * Le avisa a la persona que ya tiene acceso. No lleva contraseña: la crea ella
 * con «¿Olvidaste tu contraseña?». Si el correo falla, la cuenta queda igual
 * (puede pedir el código desde la app), por eso no se lanza el error.
 */
async function avisarAcceso({ email, nombre }) {
  try {
    // Un SMTP lento no debe dejar a la app esperando (y tentada a reenviar).
    const limite = new Promise((_, rechazar) => setTimeout(() => rechazar(new Error('Tiempo de envío agotado')), 8000));
    await Promise.race([limite, enviarCorreo({
      para: email,
      asunto: 'Ya tienes acceso a Ventario',
      texto:
        `Hola, ${nombre}.\n\n` +
        'Tu empresa te dio acceso a Ventario con este correo.\n\n' +
        'Para entrar por primera vez:\n' +
        '  1. Abre la app Ventario.\n' +
        '  2. Toca «¿Olvidaste tu contraseña?» y escribe este correo.\n' +
        '  3. Te llegará un código para crear tu contraseña.\n\n' +
        'Si no esperabas este correo, ignóralo.\n',
    })]);
    return true;
  } catch (e) {
    logger.warn({ err: e.message, email }, 'No se pudo enviar el aviso de acceso');
    return false;
  }
}

async function contarDirectoresActivos(conn, empresaId) {
  const fila = await txQueryOne(
    conn,
    "SELECT COUNT(*) n FROM usuarios WHERE empresa_id = ? AND rol = 'ADMIN' AND activo = 1 AND deleted_at IS NULL",
    [empresaId],
  );
  return Number(fila.n);
}

/**
 * El empleado nuevo (la persona). Es el mismo en Presente, donde solo le falta
 * el rostro. Si el plan de Presente ya está lleno se crea igual pero en pausa
 * allá: Ventario no se bloquea por el cupo de la otra app.
 */
async function crearEmpleado(conn, { empresaId, sedeId, nombre, documento, cargo, telefono, email }) {
  if (!sedeId) {
    throw badRequest('FALTA_SEDE', 'El empleado necesita una sede');
  }
  const cupo = await txQueryOne(
    conn,
    `SELECT fn_limite_app(?, 'ASISTENCIA', 'personas') AS maximo,
            fn_uso_app(?, 'ASISTENCIA', 'personas') AS usados`,
    [empresaId, empresaId],
  );
  const enPausa = cupo?.maximo != null && Number(cupo.usados) >= Number(cupo.maximo) ? 1 : 0;
  const r = await txExecute(
    conn,
    `INSERT INTO empleados (empresa_id, sede_id, documento, nombre, cargo, telefono, email, en_pausa)
     VALUES (?,?,?,?,?,?,?,?)`,
    [empresaId, sedeId, documento, nombre, cargo, telefono ?? null, email, enPausa],
  );
  return Number(r.insertId);
}

/**
 * El correo es con lo que se entra a la plataforma: no puede tenerlo otra
 * persona (de esta u otra empresa) ni una cuenta técnica. La base lo exige
 * igual (uk_empleados_email, EMAIL_EN_USO); aquí se explica mejor.
 */
async function exigirCorreoLibre(conn, email, empleadoId = null) {
  // aislamiento: el correo es único en toda la plataforma, no por empresa
  const otro = await txQueryOne(
    conn,
    `SELECT 1 x FROM empleados WHERE email = ? AND id <> COALESCE(?, 0)
     UNION ALL SELECT 1 FROM usuarios WHERE email = ? LIMIT 1`,
    [email, empleadoId, email],
  );
  if (otro) throw conflict('EMAIL_EN_USO', 'Ese correo ya lo usa otra persona');
}

async function cajaAbierta(conn, usuarioId) {
  return txQueryOne(
    conn,
    "SELECT uuid FROM cierres_caja WHERE usuario_id = ? AND estado = 'ABIERTO' LIMIT 1",
    [usuarioId],
  );
}

async function fijarSedes(conn, usuarioId, sedeIds) {
  await txExecute(conn, 'DELETE FROM usuario_sedes WHERE usuario_id = ?', [usuarioId]);
  for (const sedeId of sedeIds) {
    await txExecute(conn, 'INSERT INTO usuario_sedes (usuario_id, sede_id) VALUES (?, ?)', [usuarioId, sedeId]);
  }
  // Las sedes viajan con el usuario en la bajada: hay que marcarlo como
  // cambiado para que los teléfonos se enteren.
  await txExecute(conn, 'UPDATE usuarios SET updated_at = UTC_TIMESTAMP(3) WHERE id = ?', [usuarioId]);
}

const revocarSesiones = (conn, usuarioId) =>
  txExecute(
    conn,
    'UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3) WHERE usuario_id = ? AND revoked_at IS NULL',
    [usuarioId],
  );

/**
 * Da acceso a Ventario a un empleado.
 *
 *   · Si ya existe (mismo documento, registrado en Presente) se usan sus datos.
 *     Si ya tenía cuenta (de Presente), solo se le agrega el rol de Ventario:
 *     entra con el mismo correo y contraseña.
 *   · Si es nuevo, se crea su ficha de empleado (aparece en Presente; solo le
 *     falta el rostro) y su cuenta, con contraseña al azar.
 */
export async function crear(datosCliente, gestor, ctx) {
  const roles = normalizarRoles(datosCliente.rol, null);
  const datos = { ...datosCliente, rol: roles.rol };
  exigirRolAsignable(gestor, datos.rol);
  const tramos = validarHorario(datos.restringir_horario, datos.horario, datos.rol);
  const empresaId = gestor.alcance.empresaId;
  const generada = !datos.password;
  const hash = await hashearPassword(datos.password ?? passwordAleatoria());

  const resultado = await withTransaction(async (conn) => {
    // La misma alta reenviada (la respuesta se perdió, doble toque): se
    // devuelve la que ya existe en vez de fallar o crear otra.
    if (datos.uuid) {
      const ya = await txQueryOne(conn, 'SELECT uuid FROM usuarios WHERE uuid = ? AND empresa_id = ?', [
        datos.uuid,
        empresaId,
      ]);
      if (ya) return { uuid: ya.uuid, nueva: false, repetida: true };
    }

    let sedeIds = await resolverSedes(conn, datos.sedes, gestor);

    // Sin sedes indicadas (la app vieja no las envía): el vendedor o auxiliar
    // va a la sede de quien lo crea, o a la principal si lo crea el director.
    if (!sedeIds.length && ROLES_DE_UNA_SEDE.includes(datos.rol)) {
      if (esDirector(gestor.usuario.rol)) {
        const principal = await txQueryOne(
          conn,
          'SELECT id FROM sedes WHERE empresa_id = ? AND es_principal = 1 AND deleted_at IS NULL ORDER BY id LIMIT 1',
          [empresaId],
        );
        if (principal) sedeIds = [Number(principal.id)];
      } else if (gestor.alcance.sedeIds.length === 1) {
        sedeIds = [...gestor.alcance.sedeIds];
      }
    }

    const error = validarSedesDeRol(datos.rol, sedeIds);
    if (error) throw badRequest('SEDES_INVALIDAS', error);

    // ¿El empleado ya existe? (registrado en Presente, con o sin cuenta; la
    // cuenta puede estar dada de baja).
    const ficha = await txQueryOne(
      conn,
      `SELECT e.id, e.sede_id, e.email, e.activo, u.id AS usuario_id, u.uuid AS usuario_uuid,
              u.rol AS usuario_rol, u.rol_asistencia, u.deleted_at AS cuenta_borrada
         FROM empleados e
         LEFT JOIN usuarios u ON u.empleado_id = e.id
        WHERE e.empresa_id = ? AND e.documento = ?`,
      [empresaId, datos.documento],
    );
    const cuentaViva = ficha?.usuario_id && !ficha.cuenta_borrada;
    if (cuentaViva && ficha.usuario_rol) {
      throw conflict('YA_TIENE_ACCESO', 'Ese empleado ya tiene acceso a Ventario');
    }

    if (cuentaViva) {
      // Ya tenía cuenta de Presente: se le agrega Ventario, sin tocar su
      // contraseña ni su rol de allá (salvo hacerlo director: lo es en las dos).
      const r = normalizarRoles(datos.rol, ficha.rol_asistencia);
      await txExecute(
        conn,
        'UPDATE usuarios SET rol = ?, rol_asistencia = ?, restringir_horario = ?, horario = ? WHERE id = ?',
        [
          r.rol,
          r.rolAsistencia,
          datos.restringir_horario ? 1 : 0,
          tramos.length ? JSON.stringify(tramos) : null,
          ficha.usuario_id,
        ],
      );
      if (datos.telefono) {
        await txExecute(conn, 'UPDATE empleados SET telefono = COALESCE(telefono, ?) WHERE id = ? AND empresa_id = ?', [
          datos.telefono,
          ficha.id,
          empresaId,
        ]);
      }
      await fijarSedes(conn, Number(ficha.usuario_id), sedeIds);
      await registrarAuditoria(conn, {
        usuarioId: gestor.usuario.id,
        sedeId: sedeIds[0] ?? null,
        dispositivoUuid: ctx.dispositivoUuid,
        accion: ACCIONES.ROL_CAMBIADO,
        entidad: 'usuarios',
        entidadUuid: ficha.usuario_uuid,
        despues: { rol: r.rol, sedes: datos.sedes },
      });
      return { uuid: ficha.usuario_uuid, nueva: false };
    }

    // La persona: si ya existía se usan SUS datos (solo se completa lo que le
    // falte); si no, se crea. Su correo es con el que entrará.
    let empleadoId;
    if (ficha) {
      empleadoId = Number(ficha.id);
      const email = ficha.email ?? datos.email;
      await exigirCorreoLibre(conn, email, empleadoId);
      await txExecute(
        conn,
        'UPDATE empleados SET email = ?, telefono = COALESCE(telefono, ?), activo = 1 WHERE id = ? AND empresa_id = ?',
        [email, datos.telefono ?? null, empleadoId, empresaId],
      );
    } else {
      await exigirCorreoLibre(conn, datos.email);
      let sedeEmpleado = sedeIds[0] ?? null;
      if (!sedeEmpleado) {
        const principal = await txQueryOne(
          conn,
          'SELECT id FROM sedes WHERE empresa_id = ? AND es_principal = 1 AND deleted_at IS NULL ORDER BY id LIMIT 1',
          [empresaId],
        );
        sedeEmpleado = principal ? Number(principal.id) : null;
      }
      empleadoId = await crearEmpleado(conn, {
        empresaId,
        sedeId: sedeEmpleado,
        nombre: datos.nombre,
        documento: datos.documento,
        cargo: etiquetaRol(datos.rol),
        telefono: datos.telefono,
        email: datos.email,
      });
    }

    // La cuenta. Si tuvo una y se dio de baja, se reactiva la MISMA: sus
    // ventas y movimientos de antes siguen a su nombre.
    const horario = tramos.length ? JSON.stringify(tramos) : null;
    let uuid;
    let usuarioId;
    if (ficha?.usuario_id) {
      uuid = ficha.usuario_uuid;
      usuarioId = Number(ficha.usuario_id);
      await txExecute(
        conn,
        `UPDATE usuarios SET password_hash = ?, rol = ?, rol_asistencia = ?, activo = 1, deleted_at = NULL,
                pausa_inventario = 0, restringir_horario = ?, horario = ?, acceso_extra_hasta = NULL
          WHERE id = ?`,
        [hash, roles.rol, roles.rolAsistencia, datos.restringir_horario ? 1 : 0, horario, usuarioId],
      );
    } else {
      uuid = datos.uuid ?? nuevoUuid();
      const r = await txExecute(
        conn,
        `INSERT INTO usuarios (uuid, empresa_id, empleado_id, password_hash, rol, rol_asistencia,
                               restringir_horario, horario)
         VALUES (?,?,?,?,?,?,?,?)`,
        [uuid, empresaId, empleadoId, hash, roles.rol, roles.rolAsistencia, datos.restringir_horario ? 1 : 0, horario],
      );
      usuarioId = Number(r.insertId);
    }
    await fijarSedes(conn, usuarioId, sedeIds);

    await registrarAuditoria(conn, {
      usuarioId: gestor.usuario.id,
      sedeId: sedeIds[0] ?? null,
      dispositivoUuid: ctx.dispositivoUuid,
      accion: ACCIONES.USUARIO_CREADO,
      entidad: 'usuarios',
      entidadUuid: uuid,
      despues: { nombre: datos.nombre, email: datos.email, rol: roles.rol, sedes: datos.sedes },
    });
    return { uuid, nueva: true };
  });

  const usuario = await cargarEmpleado(resultado.uuid, empresaId);
  // Fuera de la transacción: un correo que tarda no bloquea la base.
  const avisoEnviado = resultado.nueva && generada ? await avisarAcceso(usuario) : false;
  return {
    ...publico(usuario),
    cuenta_existente: !resultado.nueva && !resultado.repetida,
    ya_creada: !!resultado.repetida,
    aviso_enviado: avisoEnviado,
  };
}

/** Cargo con el que aparece en Control de Personal quien se crea desde aquí. */
function etiquetaRol(rol) {
  return (
    {
      ADMIN: 'Director',
      GERENTE: 'Gerente',
      AUXILIAR_INVENTARIO: 'Auxiliar de inventario',
      VENDEDOR: 'Vendedor',
    }[rol] ?? null
  );
}

export async function actualizar(uuid, datosCliente, gestor, ctx) {
  let datos = datosCliente;
  const empresaId = gestor.alcance.empresaId;
  return withTransaction(async (conn) => {
    const antes = await cargarEmpleado(uuid, empresaId, conn);
    const esElMismo = antes.id === gestor.usuario.id;

    if (!esElMismo && !puedeAdministrar(gestor, antes)) {
      throw forbidden('No puedes administrar esta cuenta', 'SIN_PERMISO');
    }
    if (esElMismo && !esDirector(gestor.usuario.rol)) {
      // Un gerente puede editar sus datos básicos, no su rol, sedes, horario
      // ni habilitación: eso lo decide el director.
      for (const campo of ['rol', 'sedes', 'activo', 'restringir_horario', 'horario']) {
        if (datos[campo] !== undefined) {
          throw forbidden('Tu rol, sedes y horario los gestiona el Director General', 'SIN_PERMISO');
        }
      }
    }
    if (esElMismo && datos.activo === false) {
      throw badRequest('AUTO_DESACTIVACION', 'No puedes desactivar tu propia cuenta');
    }

    // Solo el rol de Ventario; el de Presente se conserva (salvo el director,
    // que es administrador en las dos apps).
    let rol = antes.rol;
    if (datos.rol !== undefined && datos.rol !== antes.rol) {
      exigirRolAsignable(gestor, datos.rol);
      const r = normalizarRoles(datos.rol, antes.rol_asistencia);
      rol = r.rol;
      datos = { ...datos, rol, rol_asistencia: r.rolAsistencia };
    } else {
      datos = { ...datos, rol: undefined };
    }

    // No dejar el negocio sin Director General activo.
    const dejaDeSerDirectorActivo =
      antes.rol === ROLES.ADMIN && !!antes.activo && (rol !== ROLES.ADMIN || datos.activo === false);
    if (dejaDeSerDirectorActivo && (await contarDirectoresActivos(conn, empresaId)) <= 1) {
      throw conflict('ULTIMO_DIRECTOR', 'Debe quedar al menos un Director General activo');
    }

    // Los datos de la persona viven SOLO en su empleado (los ve Presente
    // igual). Las cuentas técnicas sin empleado guardan nombre y correo propios.
    const personales = ['nombre', 'documento', 'email', 'telefono'].filter((c) => datos[c] !== undefined);
    if (personales.length) {
      if (datos.email !== undefined && datos.email !== antes.email) {
        await exigirCorreoLibre(conn, datos.email, antes.empleado_id);
      }
      if (antes.empleado_id) {
        await txExecute(
          conn,
          `UPDATE empleados SET ${personales.map((c) => `${c} = ?`).join(', ')} WHERE id = ? AND empresa_id = ?`,
          [...personales.map((c) => datos[c]), antes.empleado_id, empresaId],
        );
      } else {
        const propios = personales.filter((c) => c === 'nombre' || c === 'email');
        if (propios.length) {
          await txExecute(
            conn,
            `UPDATE usuarios SET ${propios.map((c) => `${c} = ?`).join(', ')} WHERE id = ?`,
            [...propios.map((c) => datos[c]), antes.id],
          );
        }
      }
    }

    const campos = [];
    const valores = [];
    for (const clave of ['rol', 'rol_asistencia']) {
      if (datos[clave] !== undefined) {
        campos.push(`${clave} = ?`);
        valores.push(datos[clave]);
      }
    }
    if (datos.activo !== undefined) {
      campos.push('activo = ?');
      valores.push(datos.activo ? 1 : 0);
    }
    if (datos.password !== undefined) {
      campos.push('password_hash = ?');
      valores.push(await hashearPassword(datos.password));
    }
    if (datos.restringir_horario !== undefined || datos.horario !== undefined || datos.rol !== undefined) {
      const restringir = datos.restringir_horario ?? !!antes.restringir_horario;
      const tramos = validarHorario(
        rol === ROLES.ADMIN ? false : restringir,
        datos.horario ?? leerHorario(antes.horario),
        rol,
      );
      campos.push('restringir_horario = ?', 'horario = ?');
      valores.push(rol === ROLES.ADMIN ? 0 : restringir ? 1 : 0, tramos.length ? JSON.stringify(tramos) : null);
    }

    if (campos.length) {
      valores.push(antes.id);
      await txExecute(conn, `UPDATE usuarios SET ${campos.join(', ')} WHERE id = ?`, valores);
    }

    // Sedes: se validan contra el rol FINAL (cambiar a gerente exige ≥ 1).
    let sedeIds = antes.sedeIds;
    if (datos.sedes !== undefined) {
      sedeIds = await resolverSedes(conn, datos.sedes, gestor);
    } else if (datos.rol === ROLES.ADMIN) {
      sedeIds = [];
    }
    const errorSedes = rol ? validarSedesDeRol(rol, sedeIds) : null;
    if (errorSedes) throw badRequest('SEDES_INVALIDAS', errorSedes);

    const cambianSedes =
      [...sedeIds].sort().join(',') !== [...antes.sedeIds].sort().join(',');
    if (cambianSedes) {
      if (await cajaAbierta(conn, antes.id)) {
        throw conflict(
          'CAJA_ABIERTA',
          'Tiene una caja abierta: debe cerrarla antes de cambiar de sede, porque el turno pertenece a la sede donde se abrió',
        );
      }
      await fijarSedes(conn, antes.id, sedeIds);
    }

    if (datos.activo === false || datos.password !== undefined) {
      await revocarSesiones(conn, antes.id);
    }

    // ── Auditoría: una entrada por cada cosa sensible que cambió ──────────────
    const base = {
      usuarioId: gestor.usuario.id,
      sedeId: sedeIds[0] ?? antes.sedeIds[0] ?? null,
      dispositivoUuid: ctx.dispositivoUuid,
      entidad: 'usuarios',
      entidadUuid: antes.uuid,
    };
    if (datos.activo !== undefined && !!datos.activo !== !!antes.activo) {
      await registrarAuditoria(conn, {
        ...base,
        accion: datos.activo ? ACCIONES.USUARIO_ACTIVADO : ACCIONES.USUARIO_DESACTIVADO,
      });
    }
    if (datos.rol !== undefined && datos.rol !== antes.rol) {
      await registrarAuditoria(conn, {
        ...base,
        accion: ACCIONES.ROL_CAMBIADO,
        antes: { rol: antes.rol },
        despues: { rol: datos.rol },
      });
    }
    if (cambianSedes) {
      await registrarAuditoria(conn, {
        ...base,
        accion: ACCIONES.SEDES_CAMBIADAS,
        antes: { sedes: antes.sedes.map((s) => s.nombre) },
        despues: { sedes: datos.sedes ?? [] },
      });
    }
    if (datos.restringir_horario !== undefined || datos.horario !== undefined) {
      await registrarAuditoria(conn, {
        ...base,
        accion: ACCIONES.HORARIO_CAMBIADO,
        antes: { restringir: !!antes.restringir_horario, horario: leerHorario(antes.horario) },
        despues: { restringir: datos.restringir_horario, horario: datos.horario },
      });
    }

    return publico(await cargarEmpleado(uuid, empresaId, conn));
  });
}

export async function eliminar(uuid, gestor, ctx) {
  const empresaId = gestor.alcance.empresaId;
  return withTransaction(async (conn) => {
    const u = await cargarEmpleado(uuid, empresaId, conn);
    if (u.id === gestor.usuario.id) {
      throw badRequest('AUTO_ELIMINACION', 'No puedes eliminar tu propia cuenta');
    }
    if (!puedeAdministrar(gestor, u)) throw forbidden('No puedes administrar esta cuenta', 'SIN_PERMISO');
    if (u.rol === ROLES.ADMIN && u.activo && (await contarDirectoresActivos(conn, empresaId)) <= 1) {
      throw conflict('ULTIMO_DIRECTOR', 'Debe quedar al menos un Director General activo');
    }

    if (u.rol_asistencia && u.rol !== ROLES.ADMIN) {
      // También tiene cuenta de Presente: solo pierde el acceso a Ventario.
      await txExecute(conn, 'UPDATE usuarios SET rol = NULL, pausa_inventario = 0 WHERE id = ?', [u.id]);
    } else {
      // Borrado lógico: las ventas y movimientos históricos deben seguir
      // apuntando a quién los hizo. El empleado sigue existiendo en Presente;
      // si se le vuelve a dar acceso, se reactiva esta misma cuenta.
      await txExecute(
        conn,
        'UPDATE usuarios SET deleted_at = UTC_TIMESTAMP(3), activo = 0 WHERE id = ?',
        [u.id],
      );
    }
    await revocarSesiones(conn, u.id);
    await registrarAuditoria(conn, {
      usuarioId: gestor.usuario.id,
      sedeId: u.sedeIds[0] ?? null,
      dispositivoUuid: ctx.dispositivoUuid,
      accion: ACCIONES.USUARIO_ELIMINADO,
      entidad: 'usuarios',
      entidadUuid: u.uuid,
      antes: { nombre: u.nombre, email: u.email, rol: u.rol },
    });
    return { ok: true };
  });
}

/**
 * Acceso fuera de horario, hasta un instante concreto.
 *
 * Sólo amplía: nunca acorta un acceso extra que ya estaba vigente más allá.
 * Para retirarlo está `revocarAccesoExtra`.
 */
export async function otorgarAccesoExtra(uuid, datos, gestor, ctx) {
  const empresaId = gestor.alcance.empresaId;
  return withTransaction(async (conn) => {
    const u = await cargarEmpleado(uuid, empresaId, conn);
    if (!puedeAdministrar(gestor, u)) throw forbidden('No puedes administrar esta cuenta', 'SIN_PERMISO');

    const ahora = Date.now();
    const hasta = datos.hasta ? new Date(datos.hasta) : new Date(ahora + datos.minutos * 60_000);
    if (hasta.getTime() <= ahora) throw badRequest('HASTA_PASADO', 'La hora límite ya pasó');
    if (hasta.getTime() - ahora > 24 * 3_600_000) {
      throw badRequest('ACCESO_DEMASIADO_LARGO', 'El acceso extra no puede pasar de 24 horas');
    }

    const vigente = u.acceso_extra_hasta ? new Date(u.acceso_extra_hasta).getTime() : 0;
    const final = new Date(Math.max(vigente, hasta.getTime()));

    await txExecute(conn, 'UPDATE usuarios SET acceso_extra_hasta = ? WHERE id = ?', [final, u.id]);
    await txExecute(
      conn,
      'INSERT INTO accesos_extra (uuid, usuario_id, otorgado_por, hasta, motivo) VALUES (?,?,?,?,?)',
      [nuevoUuid(), u.id, gestor.usuario.id, final, datos.motivo ?? null],
    );
    await registrarAuditoria(conn, {
      usuarioId: gestor.usuario.id,
      sedeId: u.sedeIds[0] ?? null,
      dispositivoUuid: ctx.dispositivoUuid,
      accion: ACCIONES.ACCESO_EXTRA_OTORGADO,
      entidad: 'usuarios',
      entidadUuid: u.uuid,
      despues: { hasta: final.toISOString(), motivo: datos.motivo ?? null },
    });
    return publico(await cargarEmpleado(uuid, empresaId, conn));
  });
}

export async function revocarAccesoExtra(uuid, gestor, ctx) {
  const empresaId = gestor.alcance.empresaId;
  return withTransaction(async (conn) => {
    const u = await cargarEmpleado(uuid, empresaId, conn);
    if (!puedeAdministrar(gestor, u)) throw forbidden('No puedes administrar esta cuenta', 'SIN_PERMISO');
    await txExecute(conn, 'UPDATE usuarios SET acceso_extra_hasta = NULL WHERE id = ?', [u.id]);
    await registrarAuditoria(conn, {
      usuarioId: gestor.usuario.id,
      sedeId: u.sedeIds[0] ?? null,
      dispositivoUuid: ctx.dispositivoUuid,
      accion: ACCIONES.ACCESO_EXTRA_REVOCADO,
      entidad: 'usuarios',
      entidadUuid: u.uuid,
    });
    return publico(await cargarEmpleado(uuid, empresaId, conn));
  });
}

/**
 * Empleados (registrados en cualquiera de las dos apps) que aún NO tienen
 * acceso a Ventario: para darles acceso sin volver a escribir sus datos.
 * Incluye a quien ya tiene cuenta de Presente (se le agrega Ventario).
 */
export async function personasSinCuenta({ sede, q }, gestor) {
  const empresaId = gestor.alcance.empresaId;
  const where = ['e.empresa_id = ?', 'e.activo = 1', '(u.id IS NULL OR u.deleted_at IS NOT NULL OR u.rol IS NULL)'];
  const params = [empresaId];
  if (sede) {
    const s = await queryOne('SELECT id FROM sedes WHERE uuid = ? AND empresa_id = ? AND deleted_at IS NULL', [
      sede,
      empresaId,
    ]);
    if (!s) throw notFound('Sede');
    where.push('e.sede_id = ?');
    params.push(s.id);
  }
  if (q) {
    where.push('(e.nombre LIKE ? OR e.documento LIKE ?)');
    params.push(`%${q}%`, `%${q}%`);
  }
  const filas = await query(
    `SELECT e.documento, e.nombre, e.cargo, e.telefono, e.email,
            e.sede_id, s.uuid AS sede_uuid, s.nombre AS sede_nombre,
            (u.id IS NOT NULL AND u.deleted_at IS NULL) AS con_cuenta
       FROM empleados e
       JOIN sedes s ON s.id = e.sede_id
       LEFT JOIN usuarios u ON u.empleado_id = e.id
      WHERE ${where.join(' AND ')}
      ORDER BY e.nombre
      LIMIT 200`,
    params,
  );
  return filas
    .filter((f) => veSede(gestor.alcance, Number(f.sede_id)))
    .map((f) => ({
      documento: f.documento,
      nombre: f.nombre,
      cargo: f.cargo ?? null,
      telefono: f.telefono ?? null,
      email: f.email ?? null,
      sede: { uuid: f.sede_uuid, nombre: f.sede_nombre },
      // Ya entra a Presente: con el mismo correo y contraseña entrará a Ventario.
      con_cuenta: !!f.con_cuenta,
    }));
}

/**
 * Pausa o reactiva a alguien en UNA app (cuando el plan no alcanza para todos).
 * Reactivar exige cupo: lo comprueba la base (LIMITE_PLAN → 409). Al director
 * no se le pausa: siempre debe poder entrar a administrar.
 */
export async function pausar(uuid, { aplicativo, pausada }, gestor, ctx) {
  const empresaId = gestor.alcance.empresaId;
  return withTransaction(async (conn) => {
    const u = await cargarEmpleado(uuid, empresaId, conn);
    if (u.id === gestor.usuario.id) throw badRequest('AUTO_PAUSA', 'No puedes pausarte a ti mismo');
    if (!puedeAdministrar(gestor, u)) throw forbidden('No puedes administrar esta cuenta', 'SIN_PERMISO');
    if (u.rol === ROLES.ADMIN && pausada) {
      throw badRequest('DIRECTOR_SIN_PAUSA', 'Al administrador no se le pausa');
    }
    if (aplicativo === 'INVENTARIO') {
      await txExecute(conn, 'UPDATE usuarios SET pausa_inventario = ? WHERE id = ?', [pausada ? 1 : 0, u.id]);
    } else if (u.empleado_id) {
      // En Presente la pausa es de la persona: no marca ni entra a Presente.
      await txExecute(conn, 'UPDATE empleados SET en_pausa = ? WHERE id = ? AND empresa_id = ?', [
        pausada ? 1 : 0,
        u.empleado_id,
        empresaId,
      ]);
    }
    if (pausada && aplicativo === 'INVENTARIO') await revocarSesiones(conn, u.id);
    await registrarAuditoria(conn, {
      usuarioId: gestor.usuario.id,
      sedeId: u.sedeIds[0] ?? null,
      dispositivoUuid: ctx.dispositivoUuid,
      accion: pausada ? ACCIONES.USUARIO_DESACTIVADO : ACCIONES.USUARIO_ACTIVADO,
      entidad: 'usuarios',
      entidadUuid: u.uuid,
      despues: { pausa: aplicativo, pausada },
    });
    return publico(await cargarEmpleado(uuid, empresaId, conn));
  });
}

// ── Rutas ───────────────────────────────────────────────────────────────────

const router = Router();
router.use(autenticar, soloGestor);

const gestorDe = (req) => ({ usuario: req.usuario, rol: req.usuario.rol, alcance: req.alcance });
const ctxDe = (req) => ({ dispositivoUuid: req.dispositivoUuid });

router.get(
  '/',
  asyncHandler(async (req, res) => ok(res, await listar(gestorDe(req)))),
);

// Antes de '/:uuid' para que «personas» no se tome por un uuid.
router.get(
  '/personas',
  validar({ query: personasQuery }),
  asyncHandler(async (req, res) => ok(res, await personasSinCuenta(req.query, gestorDe(req)))),
);

router.post(
  '/:uuid/pausa',
  validar({ params: uuidParam, body: pausaSchema }),
  asyncHandler(async (req, res) =>
    ok(res, await pausar(req.params.uuid, req.body, gestorDe(req), ctxDe(req))),
  ),
);

router.post(
  '/',
  validar({ body: crearSchema }),
  asyncHandler(async (req, res) => creado(res, await crear(req.body, gestorDe(req), ctxDe(req)))),
);

router.patch(
  '/:uuid',
  validar({ params: uuidParam, body: actualizarSchema }),
  asyncHandler(async (req, res) =>
    ok(res, await actualizar(req.params.uuid, req.body, gestorDe(req), ctxDe(req))),
  ),
);

router.delete(
  '/:uuid',
  validar({ params: uuidParam }),
  asyncHandler(async (req, res) => ok(res, await eliminar(req.params.uuid, gestorDe(req), ctxDe(req)))),
);

router.post(
  '/:uuid/acceso-extra',
  validar({ params: uuidParam, body: accesoExtraSchema }),
  asyncHandler(async (req, res) =>
    ok(res, await otorgarAccesoExtra(req.params.uuid, req.body, gestorDe(req), ctxDe(req))),
  ),
);

router.delete(
  '/:uuid/acceso-extra',
  validar({ params: uuidParam }),
  asyncHandler(async (req, res) =>
    ok(res, await revocarAccesoExtra(req.params.uuid, gestorDe(req), ctxDe(req))),
  ),
);

export default router;
