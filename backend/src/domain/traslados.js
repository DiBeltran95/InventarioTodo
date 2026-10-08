/**
 * Reglas de los traslados entre sedes (flujo simple: el stock se mueve al
 * despachar, sin estado «en tránsito»).
 *
 * Quién hace qué:
 *
 *   · VER en qué sedes hay un producto: todos (no es una regla de traslados,
 *     es el pull de stock_sedes sin filtrar).
 *   · SOLICITAR unidades: el Gerente de Sede, siempre PARA una sede suya y
 *     DESDE otra.
 *   · DESPACHAR o RECHAZAR una solicitud: el Director General o el Auxiliar
 *     de Inventario de la sede de ORIGEN —quien tiene la mercancía en la mano—,
 *     con las unidades que decida (pueden ser menos de las pedidas).
 *   · MOVER directamente, sin solicitud: el Director General entre cualesquiera
 *     sedes; el Auxiliar de Inventario, desde su sede hacia otra.
 *   · CANCELAR una solicitud pendiente: quien la pidió o el director.
 *
 * Funciones puras: sin base de datos. La app tiene la misma tabla de reglas
 * (mobile/lib/core/negocio/traslados.dart) para mostrar sólo los botones que
 * van a funcionar.
 */
import { ROLES } from '../config/constants.js';
import { veSede } from './alcance.js';

export const ESTADOS_TRASLADO = Object.freeze(['PENDIENTE', 'APROBADO', 'RECHAZADO', 'CANCELADO']);
export const TIPOS_TRASLADO = Object.freeze(['SOLICITUD', 'DIRECTO']);

/** Roles que intervienen en algún paso de un traslado (para la barrera del push). */
export const ROLES_DE_TRASLADOS = Object.freeze([ROLES.ADMIN, ROLES.GERENTE, ROLES.AUXILIAR_INVENTARIO]);
/** Quién despacha o rechaza una solicitud (además, el auxiliar debe ser del origen). */
export const ROLES_QUE_DESPACHAN = Object.freeze([ROLES.ADMIN, ROLES.AUXILIAR_INVENTARIO]);

const esDirector = (u) => u.rol === ROLES.ADMIN;
const esAuxiliar = (u) => u.rol === ROLES.AUXILIAR_INVENTARIO;
const mismaSede = (a, b) => Number(a) === Number(b);

/**
 * ¿Puede `usuario` SOLICITAR unidades de `origenId` para `destinoId`?
 * Devuelve null si puede, o el motivo.
 */
export function puedeSolicitar(usuario, origenId, destinoId) {
  if (usuario.rol !== ROLES.GERENTE) {
    return esDirector(usuario) || esAuxiliar(usuario)
      ? 'Tú mueves las unidades directamente: no necesitas solicitarlas'
      : 'Sólo un gerente de sede solicita unidades a otra sede';
  }
  if (mismaSede(origenId, destinoId)) return 'La sede de origen y la de destino deben ser distintas';
  if (!veSede(usuario.alcance, destinoId)) return 'Sólo puedes solicitar unidades para una sede tuya';
  return null;
}

/** ¿Puede `usuario` MOVER unidades directamente de `origenId` a `destinoId`? */
export function puedeMover(usuario, origenId, destinoId) {
  if (mismaSede(origenId, destinoId)) return 'La sede de origen y la de destino deben ser distintas';
  if (esDirector(usuario)) return null;
  if (esAuxiliar(usuario)) {
    return veSede(usuario.alcance, origenId) ? null : 'Sólo puedes enviar unidades desde tu sede';
  }
  return 'Mueven unidades entre sedes el Director General o el auxiliar de inventario de la sede';
}

/**
 * ¿Puede `usuario` DESPACHAR o RECHAZAR esta solicitud?
 *
 * @param traslado { estado, sede_origen_id, solicitado_por }
 * @param usuario  { id, rol, alcance }
 */
export function puedeDespachar(traslado, usuario) {
  if (traslado.estado !== 'PENDIENTE') return 'El traslado ya fue resuelto';
  if (esDirector(usuario)) return null;
  if (esAuxiliar(usuario) && veSede(usuario.alcance, traslado.sede_origen_id)) return null;
  return 'Lo despacha el auxiliar de inventario de la sede de origen o el Director General';
}

/** Sólo quien lo pidió (o el director) lo cancela, y sólo mientras esté pendiente. */
export function puedeCancelar(traslado, usuario) {
  if (traslado.estado !== 'PENDIENTE') return 'El traslado ya fue resuelto';
  if (Number(traslado.solicitado_por) === Number(usuario.id) || esDirector(usuario)) return null;
  return 'Sólo quien lo pidió puede cancelarlo';
}

/**
 * Cuánto sale por línea al despachar.
 *
 * @param detalles  [{ uuid, cantidad }]          lo pedido, en milésimas (BigInt)
 * @param enviadas  Map<detalle_uuid, BigInt>     lo que decide quien despacha;
 *                                                una línea ausente sale completa
 * @returns { lineas: [{ uuid, pedida, enviada }], total } o { error }
 *
 * Se puede enviar menos de lo pedido —o nada de una línea—, pero no negativo,
 * y algo tiene que salir: despachar cero es un rechazo.
 */
export function repartoDeDespacho(detalles, enviadas) {
  const lineas = [];
  let total = 0n;
  for (const d of detalles) {
    const enviada = enviadas.has(d.uuid) ? enviadas.get(d.uuid) : d.cantidad;
    if (enviada < 0n) return { error: 'Una cantidad enviada no puede ser negativa' };
    lineas.push({ uuid: d.uuid, pedida: d.cantidad, enviada });
    total += enviada;
  }
  if (total <= 0n) return { error: 'No se envía ninguna unidad: si no se puede atender, recházalo' };
  return { lineas, total };
}
