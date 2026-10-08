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
 */
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
import { puedeAdministrar, validarSedesDeRol, veSede, esDirector } from '../../domain/alcance.js';
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
  password: passwordSchema,
  rol: z.enum(TODOS_LOS_ROLES).default(ROLES.VENDEDOR),
  telefono: z.string().max(30).optional().nullable(),
  sedes: z.array(z.string().uuid()).max(50).default([]),
  restringir_horario: z.boolean().default(false),
  horario: z.array(tramoSchema).max(28).default([]),
});

const actualizarSchema = z.object({
  nombre: z.string().min(2).max(120).trim().optional(),
  email: z.string().email().max(191).toLowerCase().trim().optional(),
  rol: z.enum(TODOS_LOS_ROLES).optional(),
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

// ── Lectura ─────────────────────────────────────────────────────────────────

/** Usuario con sus sedes. `conn` opcional (dentro de transacción). */
async function cargarEmpleado(uuid, conn = null) {
  const leer = (sql, p) => (conn ? txQueryOne(conn, sql, p) : queryOne(sql, p));
  const u = await leer(
    `SELECT id, uuid, nombre, email, rol, activo, telefono, restringir_horario, horario,
            acceso_extra_hasta, ultimo_acceso, created_at, updated_at
       FROM usuarios WHERE uuid = ? AND deleted_at IS NULL`,
    [uuid],
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
    rol: u.rol,
    activo: !!u.activo,
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
    `SELECT u.id, u.uuid, u.nombre, u.email, u.rol, u.activo, u.telefono, u.restringir_horario,
            u.horario, u.acceso_extra_hasta, u.ultimo_acceso, u.created_at, u.updated_at,
            GROUP_CONCAT(CONCAT(s.id, '|', s.uuid, '|', s.nombre) ORDER BY s.nombre SEPARATOR '\\n') AS sedes_txt
       FROM usuarios u
       LEFT JOIN usuario_sedes us ON us.usuario_id = u.id
       LEFT JOIN sedes s ON s.id = us.sede_id AND s.deleted_at IS NULL
      WHERE u.deleted_at IS NULL
      GROUP BY u.id, u.uuid, u.nombre, u.email, u.rol, u.activo, u.telefono, u.restringir_horario,
               u.horario, u.acceso_extra_hasta, u.ultimo_acceso, u.created_at, u.updated_at
      ORDER BY u.nombre`,
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
    'SELECT id, uuid FROM sedes WHERE uuid IN (?) AND deleted_at IS NULL',
    [uuids],
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

/** El gerente no puede crear ni convertir a nadie en gerente o director. */
function exigirRolAsignable(gestor, rol) {
  if (esDirector(gestor.usuario.rol)) return;
  if (rol !== ROLES.VENDEDOR && rol !== ROLES.AUXILIAR_INVENTARIO) {
    throw forbidden('Un gerente sólo crea vendedores y auxiliares de inventario', 'ROL_NO_ASIGNABLE');
  }
}

async function contarDirectoresActivos(conn) {
  const fila = await txQueryOne(
    conn,
    "SELECT COUNT(*) n FROM usuarios WHERE rol = 'ADMIN' AND activo = 1 AND deleted_at IS NULL",
    [],
  );
  return Number(fila.n);
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

export async function crear(datos, gestor, ctx) {
  exigirRolAsignable(gestor, datos.rol);
  const tramos = validarHorario(datos.restringir_horario, datos.horario, datos.rol);
  const uuid = datos.uuid ?? nuevoUuid();
  const hash = await hashearPassword(datos.password);

  return withTransaction(async (conn) => {
    let sedeIds = await resolverSedes(conn, datos.sedes, gestor);

    // Sin sedes indicadas (la app vieja no las envía): el vendedor o auxiliar
    // va a la sede de quien lo crea, o a la principal si lo crea el director.
    // Rechazarlo dejaría a los teléfonos sin actualizar sin poder dar de alta
    // personal durante la transición.
    if (!sedeIds.length && ROLES_DE_UNA_SEDE.includes(datos.rol)) {
      if (esDirector(gestor.usuario.rol)) {
        const principal = await txQueryOne(
          conn,
          'SELECT id FROM sedes WHERE es_principal = 1 AND deleted_at IS NULL ORDER BY id LIMIT 1',
          [],
        );
        if (principal) sedeIds = [Number(principal.id)];
      } else if (gestor.alcance.sedeIds.length === 1) {
        sedeIds = [...gestor.alcance.sedeIds];
      }
    }

    const error = validarSedesDeRol(datos.rol, sedeIds);
    if (error) throw badRequest('SEDES_INVALIDAS', error);

    const existe = await txQueryOne(conn, 'SELECT 1 x FROM usuarios WHERE email = ?', [datos.email]);
    if (existe) throw conflict('EMAIL_EN_USO', 'Ya hay una cuenta con ese correo');

    const r = await txExecute(
      conn,
      `INSERT INTO usuarios (uuid, nombre, email, password_hash, rol, telefono, restringir_horario, horario)
       VALUES (?,?,?,?,?,?,?,?)`,
      [
        uuid,
        datos.nombre,
        datos.email,
        hash,
        datos.rol,
        datos.telefono ?? null,
        datos.restringir_horario ? 1 : 0,
        tramos.length ? JSON.stringify(tramos) : null,
      ],
    );
    await fijarSedes(conn, r.insertId, sedeIds);

    await registrarAuditoria(conn, {
      usuarioId: gestor.usuario.id,
      sedeId: sedeIds[0] ?? null,
      dispositivoUuid: ctx.dispositivoUuid,
      accion: ACCIONES.USUARIO_CREADO,
      entidad: 'usuarios',
      entidadUuid: uuid,
      despues: { nombre: datos.nombre, email: datos.email, rol: datos.rol, sedes: datos.sedes },
    });

    return publico(await cargarEmpleado(uuid, conn));
  });
}

export async function actualizar(uuid, datos, gestor, ctx) {
  return withTransaction(async (conn) => {
    const antes = await cargarEmpleado(uuid, conn);
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

    const rol = datos.rol ?? antes.rol;
    if (datos.rol !== undefined && datos.rol !== antes.rol) exigirRolAsignable(gestor, datos.rol);

    // No dejar el negocio sin Director General activo.
    const dejaDeSerDirectorActivo =
      antes.rol === ROLES.ADMIN && !!antes.activo && (rol !== ROLES.ADMIN || datos.activo === false);
    if (dejaDeSerDirectorActivo && (await contarDirectoresActivos(conn)) <= 1) {
      throw conflict('ULTIMO_DIRECTOR', 'Debe quedar al menos un Director General activo');
    }

    const campos = [];
    const valores = [];
    for (const clave of ['nombre', 'email', 'rol', 'telefono']) {
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
    const errorSedes = validarSedesDeRol(rol, sedeIds);
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

    return publico(await cargarEmpleado(uuid, conn));
  });
}

export async function eliminar(uuid, gestor, ctx) {
  return withTransaction(async (conn) => {
    const u = await cargarEmpleado(uuid, conn);
    if (u.id === gestor.usuario.id) {
      throw badRequest('AUTO_ELIMINACION', 'No puedes eliminar tu propia cuenta');
    }
    if (!puedeAdministrar(gestor, u)) throw forbidden('No puedes administrar esta cuenta', 'SIN_PERMISO');
    if (u.rol === ROLES.ADMIN && u.activo && (await contarDirectoresActivos(conn)) <= 1) {
      throw conflict('ULTIMO_DIRECTOR', 'Debe quedar al menos un Director General activo');
    }

    // Borrado lógico: las ventas y movimientos históricos deben seguir
    // apuntando a quién los hizo.
    await txExecute(
      conn,
      'UPDATE usuarios SET deleted_at = UTC_TIMESTAMP(3), activo = 0 WHERE id = ?',
      [u.id],
    );
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
  return withTransaction(async (conn) => {
    const u = await cargarEmpleado(uuid, conn);
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
    return publico(await cargarEmpleado(uuid, conn));
  });
}

export async function revocarAccesoExtra(uuid, gestor, ctx) {
  return withTransaction(async (conn) => {
    const u = await cargarEmpleado(uuid, conn);
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
    return publico(await cargarEmpleado(uuid, conn));
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
