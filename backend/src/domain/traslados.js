/**
 * Reglas de los traslados entre sedes (flujo simple: el stock se mueve al
 * aprobar).
 *
 * Siempre confirma «la otra parte», nunca quien lo pidió:
 *
 *   · Lo pide un EMPLEADO (vendedor) → lo aprueba un gestor —gerente de la
 *     sede origen o el director—: es mercancía que sale de su sede.
 *   · Lo pide un GESTOR («solicitarlo a los empleados de esa sede») → lo
 *     confirma alguien de la sede origen, que es quien la despacha.
 *
 * Funciones puras: sin base de datos.
 */
import { ROLES, ROLES_GESTORES } from '../config/constants.js';
import { veSede } from './alcance.js';

export const ESTADOS_TRASLADO = Object.freeze(['PENDIENTE', 'APROBADO', 'RECHAZADO', 'CANCELADO']);

/** Quién puede pedir un traslado. El auxiliar de inventario no. */
export const ROLES_QUE_PIDEN_TRASLADOS = Object.freeze([ROLES.ADMIN, ROLES.GERENTE, ROLES.VENDEDOR]);

/** 'GESTOR' o 'ORIGEN' según el rol de quien lo crea. */
export const quienConfirma = (rolCreador) => (ROLES_GESTORES.includes(rolCreador) ? 'ORIGEN' : 'GESTOR');

/**
 * ¿Puede `usuario` crear un traslado entre estas sedes?
 * Tiene que estar en alguna de las dos: enviar desde la suya o pedir para la suya.
 */
export function puedeCrear(usuario, origenId, destinoId) {
  if (!ROLES_QUE_PIDEN_TRASLADOS.includes(usuario.rol)) {
    return 'Tu rol no puede pedir traslados';
  }
  if (Number(origenId) === Number(destinoId)) return 'La sede de origen y la de destino deben ser distintas';
  if (!veSede(usuario.alcance, origenId) && !veSede(usuario.alcance, destinoId)) {
    return 'Sólo puedes pedir traslados desde o hacia una sede tuya';
  }
  return null;
}

/**
 * ¿Puede `usuario` aprobar o rechazar este traslado?
 * Devuelve null si puede, o el motivo por el que no.
 *
 * @param traslado { estado, confirma, sede_origen_id, solicitado_por }
 * @param usuario  { id, rol, alcance }
 */
export function puedeResolver(traslado, usuario) {
  if (traslado.estado !== 'PENDIENTE') return 'El traslado ya fue resuelto';
  if (Number(traslado.solicitado_por) === Number(usuario.id)) {
    return 'Un traslado lo confirma otra persona, no quien lo pidió';
  }
  if (!veSede(usuario.alcance, traslado.sede_origen_id)) {
    return 'Lo confirma alguien de la sede de origen';
  }
  if (traslado.confirma === 'GESTOR' && !ROLES_GESTORES.includes(usuario.rol)) {
    return 'Este traslado lo pidió un empleado: lo aprueba el gerente de la sede o el director';
  }
  if (traslado.confirma === 'ORIGEN' && !ROLES_QUE_PIDEN_TRASLADOS.includes(usuario.rol)) {
    return 'Tu rol no puede confirmar traslados';
  }
  return null;
}

/** Sólo quien lo pidió (o el director) lo cancela, y sólo mientras esté pendiente. */
export function puedeCancelar(traslado, usuario) {
  if (traslado.estado !== 'PENDIENTE') return 'El traslado ya fue resuelto';
  if (Number(traslado.solicitado_por) === Number(usuario.id) || usuario.rol === ROLES.ADMIN) return null;
  return 'Sólo quien lo pidió puede cancelarlo';
}
