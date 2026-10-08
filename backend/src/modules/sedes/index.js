/**
 * Sedes y solicitudes de cambio de sede.
 *
 *   GET    /sedes                 las de mi alcance (director: todas)
 *   GET    /sedes/todas           todas las activas, sólo nombre: para elegir el
 *                                 destino de un traslado o de un cambio de sede
 *   POST   /sedes                 crear            (director)
 *   PATCH  /sedes/:uuid           editar/desactivar (director)
 *
 *   GET    /sedes/cambios                 solicitudes que me tocan
 *   POST   /sedes/cambios                 el empleado pide pasar a otra sede
 *   POST   /sedes/cambios/:uuid/aceptar   gerente de la sede destino o director
 *   POST   /sedes/cambios/:uuid/rechazar
 *
 * La solicitud de cambio se BORRA al resolverse (decisión del negocio). Lo que
 * queda es la auditoría del cambio en sí.
 */
import { Router } from 'express';
import { z } from 'zod';
import { query, queryOne } from '../../db/pool.js';
import { withTransaction, txQueryOne, txExecute } from '../../db/tx.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { soloDirector } from '../../middleware/rbac.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { ok, creado } from '../../utils/responder.js';
import { badRequest, conflict, forbidden, notFound } from '../../utils/ApiError.js';
import { nuevoUuid } from '../../utils/ids.js';
import { ROLES_DE_UNA_SEDE } from '../../config/constants.js';
import { veSede, esDirector } from '../../domain/alcance.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';
import { sedesDeAlcance, sedePublica, exigirSedePorUuid } from './repo.js';

const CODIGO = /^[A-Z0-9]{2,10}$/;

const crearSchema = z.object({
  uuid: z.string().uuid().optional(),
  nombre: z.string().min(2).max(120).trim(),
  codigo: z.string().trim().toUpperCase().regex(CODIGO, 'De 2 a 10 letras o números'),
  direccion: z.string().max(200).trim().optional().nullable(),
  telefono: z.string().max(30).trim().optional().nullable(),
});

const actualizarSchema = crearSchema.omit({ uuid: true }).partial().extend({
  activo: z.boolean().optional(),
});

const solicitudSchema = z.object({
  sede_uuid: z.string().uuid(),
  motivo: z.string().max(255).trim().optional().nullable(),
});

const uuidParam = z.object({ uuid: z.string().uuid() });

// ── Sedes ───────────────────────────────────────────────────────────────────

async function crear(datos, req) {
  const uuid = datos.uuid ?? nuevoUuid();
  return withTransaction(async (conn) => {
    const repetida = await txQueryOne(conn, 'SELECT 1 x FROM sedes WHERE codigo = ?', [datos.codigo]);
    if (repetida) throw conflict('CODIGO_EN_USO', `Ya hay una sede con el código ${datos.codigo}`);
    await txExecute(
      conn,
      'INSERT INTO sedes (uuid, nombre, codigo, direccion, telefono) VALUES (?,?,?,?,?)',
      [uuid, datos.nombre, datos.codigo, datos.direccion ?? null, datos.telefono ?? null],
    );
    const sede = await exigirSedePorUuid(conn, uuid);
    await registrarAuditoria(conn, {
      usuarioId: req.usuario.id,
      sedeId: sede.id,
      dispositivoUuid: req.dispositivoUuid,
      accion: ACCIONES.SEDE_CREADA,
      entidad: 'sedes',
      entidadUuid: uuid,
      despues: { nombre: datos.nombre, codigo: datos.codigo },
    });
    return sedePublica(sede);
  });
}

async function actualizar(uuid, datos, req) {
  return withTransaction(async (conn) => {
    const sede = await txQueryOne(
      conn,
      'SELECT id, uuid, nombre, codigo, direccion, telefono, es_principal, activo FROM sedes WHERE uuid = ? AND deleted_at IS NULL',
      [uuid],
    );
    if (!sede) throw notFound('Sede');
    if (datos.activo === false && sede.es_principal) {
      throw conflict('SEDE_PRINCIPAL', 'La sede principal no se puede desactivar');
    }
    if (datos.codigo && datos.codigo !== sede.codigo) {
      const repetida = await txQueryOne(conn, 'SELECT 1 x FROM sedes WHERE codigo = ? AND id <> ?', [
        datos.codigo,
        sede.id,
      ]);
      if (repetida) throw conflict('CODIGO_EN_USO', `Ya hay una sede con el código ${datos.codigo}`);
    }

    const campos = [];
    const valores = [];
    for (const clave of ['nombre', 'codigo', 'direccion', 'telefono']) {
      if (datos[clave] !== undefined) {
        campos.push(`${clave} = ?`);
        valores.push(datos[clave]);
      }
    }
    if (datos.activo !== undefined) {
      campos.push('activo = ?');
      valores.push(datos.activo ? 1 : 0);
    }
    if (!campos.length) throw badRequest('SIN_CAMBIOS', 'No se envió ningún campo a modificar');
    valores.push(sede.id);
    await txExecute(conn, `UPDATE sedes SET ${campos.join(', ')} WHERE id = ?`, valores);

    await registrarAuditoria(conn, {
      usuarioId: req.usuario.id,
      sedeId: sede.id,
      dispositivoUuid: req.dispositivoUuid,
      accion: ACCIONES.SEDE_CAMBIADA,
      entidad: 'sedes',
      entidadUuid: uuid,
      antes: { nombre: sede.nombre, codigo: sede.codigo, activo: !!sede.activo },
      despues: datos,
    });
    return sedePublica(await exigirSedePorUuid(conn, uuid));
  });
}

// ── Solicitudes de cambio de sede ───────────────────────────────────────────

async function sedeActualDe(usuarioId) {
  return queryOne(
    `SELECT s.id, s.uuid, s.nombre FROM usuario_sedes us JOIN sedes s ON s.id = us.sede_id
      WHERE us.usuario_id = ? LIMIT 1`,
    [usuarioId],
  );
}

async function solicitar(req, datos) {
  if (!ROLES_DE_UNA_SEDE.includes(req.usuario.rol)) {
    throw forbidden(
      'Sólo vendedores y auxiliares solicitan cambio de sede; las sedes de un gerente las asigna el director',
      'SIN_PERMISO',
    );
  }
  const destino = await exigirSedePorUuid(null, datos.sede_uuid);
  if (!destino.activo) throw badRequest('SEDE_INACTIVA', 'Esa sede está desactivada');
  const actual = await sedeActualDe(req.usuario.id);
  if (actual && Number(actual.id) === Number(destino.id)) {
    throw badRequest('MISMA_SEDE', 'Ya trabajas en esa sede');
  }

  const uuid = nuevoUuid();
  try {
    await query(
      'INSERT INTO solicitudes_cambio_sede (uuid, usuario_id, sede_destino_id, motivo) VALUES (?,?,?,?)',
      [uuid, req.usuario.id, destino.id, datos.motivo ?? null],
    );
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') {
      throw conflict('SOLICITUD_ABIERTA', 'Ya tienes una solicitud de cambio de sede esperando respuesta');
    }
    throw err;
  }
  return { uuid, sede_destino: sedePublica(destino), motivo: datos.motivo ?? null };
}

async function listarSolicitudes(req) {
  const filas = await query(
    `SELECT sc.uuid, sc.motivo, sc.created_at, sc.sede_destino_id,
            u.uuid AS usuario_uuid, u.nombre AS usuario_nombre, u.rol AS usuario_rol, u.id AS usuario_id,
            d.uuid AS destino_uuid, d.nombre AS destino_nombre,
            o.uuid AS origen_uuid, o.nombre AS origen_nombre
       FROM solicitudes_cambio_sede sc
       JOIN usuarios u ON u.id = sc.usuario_id
       JOIN sedes d ON d.id = sc.sede_destino_id
       LEFT JOIN usuario_sedes us ON us.usuario_id = u.id
       LEFT JOIN sedes o ON o.id = us.sede_id
      ORDER BY sc.created_at`,
  );
  return filas
    .filter(
      (f) =>
        Number(f.usuario_id) === Number(req.usuario.id) ||
        veSede(req.alcance, f.sede_destino_id),
    )
    .map((f) => ({
      uuid: f.uuid,
      motivo: f.motivo,
      created_at: f.created_at,
      empleado: { uuid: f.usuario_uuid, nombre: f.usuario_nombre, rol: f.usuario_rol },
      sede_origen: f.origen_uuid ? { uuid: f.origen_uuid, nombre: f.origen_nombre } : null,
      sede_destino: { uuid: f.destino_uuid, nombre: f.destino_nombre },
      // ¿Puede quien consulta resolverla? Evita mostrar botones que fallarían.
      puedo_resolver:
        Number(f.usuario_id) !== Number(req.usuario.id) &&
        (esDirector(req.usuario.rol) || veSede(req.alcance, f.sede_destino_id)) &&
        ['ADMIN', 'GERENTE'].includes(req.usuario.rol),
    }));
}

async function resolver(req, uuid, aceptar) {
  return withTransaction(async (conn) => {
    const sol = await txQueryOne(
      conn,
      `SELECT sc.id, sc.usuario_id, sc.sede_destino_id, u.uuid AS usuario_uuid, u.nombre AS usuario_nombre
         FROM solicitudes_cambio_sede sc JOIN usuarios u ON u.id = sc.usuario_id
        WHERE sc.uuid = ? FOR UPDATE`,
      [uuid],
    );
    if (!sol) throw notFound('Solicitud');
    if (!['ADMIN', 'GERENTE'].includes(req.usuario.rol) || !veSede(req.alcance, sol.sede_destino_id)) {
      throw forbidden('La resuelve el gerente de la sede destino o el director', 'SIN_PERMISO');
    }

    if (aceptar) {
      const abierta = await txQueryOne(
        conn,
        "SELECT 1 x FROM cierres_caja WHERE usuario_id = ? AND estado = 'ABIERTO' LIMIT 1",
        [sol.usuario_id],
      );
      if (abierta) {
        throw conflict(
          'CAJA_ABIERTA',
          `${sol.usuario_nombre} tiene una caja abierta: debe cerrarla antes de cambiar de sede`,
        );
      }
      const anterior = await txQueryOne(
        conn,
        'SELECT s.nombre FROM usuario_sedes us JOIN sedes s ON s.id = us.sede_id WHERE us.usuario_id = ? LIMIT 1',
        [sol.usuario_id],
      );
      const destino = await txQueryOne(conn, 'SELECT nombre FROM sedes WHERE id = ?', [sol.sede_destino_id]);

      await txExecute(conn, 'DELETE FROM usuario_sedes WHERE usuario_id = ?', [sol.usuario_id]);
      await txExecute(conn, 'INSERT INTO usuario_sedes (usuario_id, sede_id) VALUES (?, ?)', [
        sol.usuario_id,
        sol.sede_destino_id,
      ]);
      await txExecute(conn, 'UPDATE usuarios SET updated_at = UTC_TIMESTAMP(3) WHERE id = ?', [sol.usuario_id]);

      await registrarAuditoria(conn, {
        usuarioId: req.usuario.id,
        sedeId: sol.sede_destino_id,
        dispositivoUuid: req.dispositivoUuid,
        accion: ACCIONES.SEDES_CAMBIADAS,
        entidad: 'usuarios',
        entidadUuid: sol.usuario_uuid,
        antes: { sede: anterior?.nombre ?? null },
        despues: { sede: destino?.nombre ?? null, por_solicitud: true },
      });
    }

    await txExecute(conn, 'DELETE FROM solicitudes_cambio_sede WHERE id = ?', [sol.id]);
    return { ok: true, aceptada: aceptar };
  });
}

// ── Rutas ───────────────────────────────────────────────────────────────────

const router = Router();
router.use(autenticar);

router.get(
  '/',
  asyncHandler(async (req, res) => ok(res, (await sedesDeAlcance(req.alcance)).map(sedePublica))),
);

router.get(
  '/todas',
  asyncHandler(async (_req, res) => {
    const filas = await query(
      'SELECT uuid, nombre, codigo FROM sedes WHERE deleted_at IS NULL AND activo = 1 ORDER BY es_principal DESC, nombre',
    );
    ok(res, filas);
  }),
);

router.post(
  '/',
  soloDirector,
  validar({ body: crearSchema }),
  asyncHandler(async (req, res) => creado(res, await crear(req.body, req))),
);

router.get(
  '/cambios',
  asyncHandler(async (req, res) => ok(res, await listarSolicitudes(req))),
);

router.post(
  '/cambios',
  validar({ body: solicitudSchema }),
  asyncHandler(async (req, res) => creado(res, await solicitar(req, req.body))),
);

router.post(
  '/cambios/:uuid/aceptar',
  validar({ params: uuidParam }),
  asyncHandler(async (req, res) => ok(res, await resolver(req, req.params.uuid, true))),
);

router.post(
  '/cambios/:uuid/rechazar',
  validar({ params: uuidParam }),
  asyncHandler(async (req, res) => ok(res, await resolver(req, req.params.uuid, false))),
);

router.patch(
  '/:uuid',
  soloDirector,
  validar({ params: uuidParam, body: actualizarSchema }),
  asyncHandler(async (req, res) => ok(res, await actualizar(req.params.uuid, req.body, req))),
);

export default router;
