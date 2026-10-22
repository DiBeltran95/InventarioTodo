/**
 * Alcance: qué sedes puede ver y operar un usuario.
 *
 *   · Director General (ADMIN) → todas las de SU empresa.
 *   · Gerente de Sede          → las suyas (una o varias).
 *   · Vendedor / Auxiliar      → exactamente una.
 *
 * Forma: { empresaId, esDirector, sedeIds }. Con varias empresas en la misma
 * base, el director ya NO tiene un pase libre: `sedeIds` trae todas las sedes
 * de su empresa (lo carga `cargarAlcance`), y todo filtro es `IN (sedeIds)`.
 * Un pase libre dejaría al director de una empresa ver las ventas de otra.
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
  return sedeId != null && alcance.sedeIds.includes(Number(sedeId));
}

/**
 * Fragmento SQL que restringe una columna de sede al alcance.
 *
 *   (? OR v.sede_id IN (?))   con params [0, [ids…]]
 *
 * El primer `?` era el pase libre del director; con varias empresas vale
 * siempre 0 (se conserva para no alterar el orden de los parámetros de las
 * consultas que ya lo usan). Una lista vacía se sustituye por [0]: `IN ()` es
 * un error de sintaxis, e `IN (0)` no coincide con ninguna sede, que es lo
 * correcto para quien no tiene sedes.
 */
export function filtroSede(columna, alcance) {
  return {
    sql: `(? OR ${columna} IN (?))`,
    params: [0, alcance.sedeIds.length ? alcance.sedeIds : [0]],
  };
}

/**
 * Huella del alcance. La app la guarda tras cada bajada: si cambia (al
 * empleado lo pasaron a otra sede, un gerente ganó o perdió una, o el teléfono
 * pasó a otra EMPRESA), descarta lo que ya no le corresponde y vuelve a bajar
 * desde cero lo que sí. La del director no cambia al crear una sede: verla
 * no exige volver a bajar todo.
 */
export function huellaAlcance(rol, alcance) {
  const sedes = alcance.esDirector ? '*' : [...alcance.sedeIds].sort((a, b) => a - b).join(',');
  return crypto
    .createHash('sha256')
    .update(`${alcance.empresaId ?? ''}|${rol}|${sedes}`)
    .digest('hex')
    .slice(0, 16);
}

/**
 * ¿Puede `gestor` administrar la cuenta `objetivo`?
 *
 *   · El director, a cualquiera salvo para desactivarse a sí mismo (eso lo
 *     comprueba el servicio).
 *   · El gerente, sólo a vendedores y auxiliares de alguna de sus sedes. No
 *     toca a otros gerentes ni al director: sería escalar privilegios.
 *
 * La cuenta es UNA para las dos apps: un gerente tampoco toca a quien es
 * administrador o gerente en Control de Personal (`rol_asistencia`), aunque en
 * Inventario no tenga rol.
 *
 * @param objetivo  { rol, rol_asistencia, sedeIds }
 */
export function puedeAdministrar(gestor, objetivo) {
  if (esDirector(gestor.rol)) return true;
  if (gestor.rol !== ROLES.GERENTE) return false;
  if (esGestor(objetivo.rol) || ROLES_GESTORES.includes(objetivo.rol_asistencia)) return false;
  // Talento humano de Presente lo gestiona solo el administrador.
  if (objetivo.rol_asistencia === 'TALENTO_HUMANO') return false;
  return objetivo.sedeIds.some((id) => gestor.alcance.sedeIds.includes(Number(id)));
}

/** Roles de la cuenta en Presente (Control de Personal). */
export const ROLES_ASISTENCIA = Object.freeze(['ADMIN', 'GERENTE', 'TALENTO_HUMANO', 'OPERARIO']);


/**
 * Roles por app (migración 007): el empleado es uno solo, pero la cuenta tiene
 * un rol en cada app por separado. Desde Ventario solo se decide el rol de
 * Ventario; el de Presente se conserva. La única regla común: el
 * administrador (dueño de la empresa) lo es en las dos apps (la base lo exige
 * con ck_usuarios_roles), así que hacerlo director lo hace administrador de
 * Presente y quitárselo le quita también ese rol allá.
 */
export function normalizarRoles(rol, rolAsistenciaActual = null) {
  if (rol === ROLES.ADMIN) return { rol, rolAsistencia: 'ADMIN' };
  return { rol, rolAsistencia: rolAsistenciaActual === 'ADMIN' ? null : (rolAsistenciaActual ?? null) };
}

/**
 * Valida el rol de Ventario con sus sedes. Devuelve un mensaje de error o null.
 *   · El director ve todas las sedes: no se le asignan.
 *   · Vendedor y auxiliar trabajan en exactamente una sede.
 *   · El gerente gestiona una o varias.
 */
export function validarSedesDeRol(rol, sedeIds) {
  if (!rol) return 'Elige un rol de Ventario para la cuenta';
  if (rol === ROLES.ADMIN) {
    return sedeIds.length ? 'El director ve todas las sedes: no se le asignan sedes' : null;
  }
  if (rol === ROLES.VENDEDOR || rol === ROLES.AUXILIAR_INVENTARIO) {
    return sedeIds.length === 1 ? null : 'Vendedores y auxiliares pertenecen a exactamente una sede';
  }
  if (rol === ROLES.GERENTE) {
    return sedeIds.length ? null : 'Un gerente necesita al menos una sede';
  }
  return null;
}
