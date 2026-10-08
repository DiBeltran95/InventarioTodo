/**
 * Alcance: qué sedes puede ver y operar un usuario.
 *
 *   · Director General (ADMIN) → todas. `sedeIds` vacío y `esDirector` true.
 *   · Gerente de Sede          → las suyas (una o varias).
 *   · Vendedor / Auxiliar      → exactamente una.
 *
 * Funciones PURAS: la carga desde la base vive en `src/modules/sedes/repo.js`.
 * Así esto se prueba sin base de datos y sin variables de entorno.
 */
import crypto from 'node:crypto';
import { ROLES, ROLES_GESTORES } from '../config/constants.js';

export const esDirector = (rol) => rol === ROLES.ADMIN;
export const esGestor = (rol) => ROLES_GESTORES.includes(rol);

/** ¿Puede ver/operar la sede `sedeId`? */
export function veSede(alcance, sedeId) {
  if (!alcance) return false;
  if (alcance.esDirector) return true;
  return sedeId != null && alcance.sedeIds.includes(Number(sedeId));
}

/**
 * Fragmento SQL que restringe una columna de sede al alcance.
 *
 *   (? OR v.sede_id IN (?))   con params [1|0, [ids…]]
 *
 * El primer `?` vale 1 para el director y corta el filtro. Una lista vacía se
 * sustituye por [0]: `IN ()` es un error de sintaxis, e `IN (0)` no coincide
 * con ninguna sede, que es lo correcto para quien no tiene sedes.
 */
export function filtroSede(columna, alcance) {
  return {
    sql: `(? OR ${columna} IN (?))`,
    params: [alcance.esDirector ? 1 : 0, alcance.sedeIds.length ? alcance.sedeIds : [0]],
  };
}

/**
 * Huella del alcance. La app la guarda tras cada bajada: si cambia (al
 * empleado lo pasaron a otra sede, o un gerente ganó o perdió una), descarta lo
 * que ya no le corresponde y vuelve a bajar desde cero lo que sí.
 */
export function huellaAlcance(rol, alcance) {
  const sedes = alcance.esDirector ? '*' : [...alcance.sedeIds].sort((a, b) => a - b).join(',');
  return crypto.createHash('sha256').update(`${rol}|${sedes}`).digest('hex').slice(0, 16);
}

/**
 * ¿Puede `gestor` administrar la cuenta `objetivo`?
 *
 *   · El director, a cualquiera salvo para desactivarse a sí mismo (eso lo
 *     comprueba el servicio).
 *   · El gerente, sólo a vendedores y auxiliares de alguna de sus sedes. No
 *     toca a otros gerentes ni al director: sería escalar privilegios.
 *
 * @param objetivo  { rol, sedeIds }
 */
export function puedeAdministrar(gestor, objetivo) {
  if (esDirector(gestor.rol)) return true;
  if (gestor.rol !== ROLES.GERENTE) return false;
  if (esGestor(objetivo.rol)) return false;
  return objetivo.sedeIds.some((id) => gestor.alcance.sedeIds.includes(Number(id)));
}

/**
 * Valida la combinación rol + sedes de una cuenta.
 * Devuelve un mensaje de error o null.
 */
export function validarSedesDeRol(rol, sedeIds) {
  if (rol === ROLES.ADMIN) {
    return sedeIds.length ? 'El Director General ve todas las sedes: no se le asignan sedes' : null;
  }
  if (rol === ROLES.GERENTE) {
    return sedeIds.length ? null : 'Un gerente necesita al menos una sede';
  }
  return sedeIds.length === 1 ? null : 'Vendedores y auxiliares pertenecen a exactamente una sede';
}
