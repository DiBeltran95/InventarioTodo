import { asyncHandler } from '../utils/asyncHandler.js';
import { forbidden, notFound } from '../utils/ApiError.js';
import { veSede } from '../domain/alcance.js';
import { sedePorUuid, sedeDeDispositivo, sedePrincipal } from '../modules/sedes/repo.js';

/**
 * Resuelve la sede en la que opera una petición REST y la deja en `req.sedeId`.
 *
 * Orden: `sede_uuid` del cuerpo o de la query → la sede del dispositivo
 * (X-Dispositivo) → la principal. Es el mismo criterio que usa /sync/push con
 * cada operación, para que las dos vías no puedan discrepar.
 *
 * @param exigirAlcance  rechaza si la sede no es del usuario. Para lo que
 *                       altera el inventario de una sede; no para registrar
 *                       hechos ya ocurridos.
 */
export const resolverSede = (exigirAlcance = false) =>
  asyncHandler(async (req, _res, next) => {
    const uuid = req.body?.sede_uuid ?? req.query?.sede_uuid;
    let sede = null;
    if (uuid) {
      sede = await sedePorUuid(null, uuid);
      if (!sede) throw notFound('Sede');
    } else {
      sede = (await sedeDeDispositivo(null, req.dispositivoUuid)) ?? (await sedePrincipal());
    }
    req.sedeId = sede ? Number(sede.id) : null;

    if (exigirAlcance && !veSede(req.alcance, req.sedeId)) {
      throw forbidden('No puedes operar en una sede que no es tuya', 'SEDE_FUERA_DE_ALCANCE');
    }
    next();
  });
