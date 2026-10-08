/**
 * GET /auditoria — registro de acciones sensibles.
 *
 * Sólo en línea: no hace falta para operar, y llevarlo a cada teléfono
 * multiplicaría datos que sólo consultan el director y los gerentes.
 *
 * Alcance: el director ve todo; el gerente, lo de sus sedes.
 *
 * Filtros: desde/hasta (días del negocio 'YYYY-MM-DD'), sede, usuario, accion.
 * Paginación descendente con `antes_de` (id de la última fila recibida).
 */
import { Router } from 'express';
import { z } from 'zod';
import { query } from '../../db/pool.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { soloGestor } from '../../middleware/rbac.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { lista } from '../../utils/responder.js';
import { env } from '../../config/env.js';
import { filtroSede } from '../../domain/alcance.js';
import { desfaseTexto } from '../../utils/dates.js';
import { ACCIONES } from '../../utils/auditoria.js';

const DIA = /^\d{4}-\d{2}-\d{2}$/;

const filtrosSchema = z.object({
  desde: z.string().regex(DIA).optional(),
  hasta: z.string().regex(DIA).optional(),
  sede: z.string().uuid().optional(),
  usuario: z.string().uuid().optional(),
  accion: z.enum(Object.values(ACCIONES)).optional(),
  antes_de: z.coerce.number().int().positive().optional(),
  limite: z.coerce.number().int().min(1).max(500).default(100),
});

function parsear(texto) {
  if (texto == null) return null;
  try {
    return JSON.parse(texto);
  } catch {
    return texto;
  }
}

async function listar(f, alcance) {
  const condiciones = [];
  const params = [];

  const alc = filtroSede('a.sede_id', alcance);
  condiciones.push(alc.sql);
  params.push(...alc.params);

  if (f.desde || f.hasta) {
    // El día es el del negocio, no el UTC: una anulación a las 9 p. m. es de hoy.
    const desfase = desfaseTexto(env.BUSINESS_TIMEZONE);
    if (f.desde) {
      condiciones.push("DATE(CONVERT_TZ(a.created_at, '+00:00', ?)) >= ?");
      params.push(desfase, f.desde);
    }
    if (f.hasta) {
      condiciones.push("DATE(CONVERT_TZ(a.created_at, '+00:00', ?)) <= ?");
      params.push(desfase, f.hasta);
    }
  }
  if (f.sede) {
    condiciones.push('s.uuid = ?');
    params.push(f.sede);
  }
  if (f.usuario) {
    condiciones.push('u.uuid = ?');
    params.push(f.usuario);
  }
  if (f.accion) {
    condiciones.push('a.accion = ?');
    params.push(f.accion);
  }
  if (f.antes_de) {
    condiciones.push('a.id < ?');
    params.push(f.antes_de);
  }
  params.push(f.limite);

  const filas = await query(
    `SELECT a.id, a.accion, a.entidad, a.entidad_uuid, a.datos_antes, a.datos_despues,
            a.dispositivo_uuid, a.created_at,
            u.uuid AS usuario_uuid, u.nombre AS usuario_nombre, u.rol AS usuario_rol,
            s.uuid AS sede_uuid, s.nombre AS sede_nombre
       FROM auditoria a
       LEFT JOIN usuarios u ON u.id = a.usuario_id
       LEFT JOIN sedes s ON s.id = a.sede_id
      WHERE ${condiciones.join(' AND ')}
      ORDER BY a.id DESC
      LIMIT ?`,
    params,
  );

  return filas.map((a) => ({
    id: Number(a.id),
    accion: a.accion,
    entidad: a.entidad,
    entidad_uuid: a.entidad_uuid,
    antes: parsear(a.datos_antes),
    despues: parsear(a.datos_despues),
    dispositivo_uuid: a.dispositivo_uuid,
    fecha: a.created_at,
    usuario: a.usuario_uuid
      ? { uuid: a.usuario_uuid, nombre: a.usuario_nombre, rol: a.usuario_rol }
      : null,
    sede: a.sede_uuid ? { uuid: a.sede_uuid, nombre: a.sede_nombre } : null,
  }));
}

const router = Router();
router.use(autenticar, soloGestor);

router.get(
  '/',
  validar({ query: filtrosSchema }),
  asyncHandler(async (req, res) => {
    const f = req.validated.query;
    const items = await listar(f, req.alcance);
    lista(res, items, {
      limite: f.limite,
      // Para pedir la página siguiente: ?antes_de=<siguiente>
      siguiente: items.length === f.limite ? items.at(-1).id : null,
    });
  }),
);

export default router;
