/**
 * Registro de auditoría.
 *
 * La tabla `auditoria` existía desde el principio pero nadie la escribía. Aquí
 * se escribe, y **dentro de la misma transacción que la acción** cuando la hay:
 * si la acción se revierte, su rastro también; si se confirma, el rastro existe
 * seguro. Un registro escrito «después» se pierde justo cuando más importa —
 * cuando algo falla a medias.
 *
 * Qué se audita: lo que permite tapar un faltante o abusar de un permiso —
 * anulaciones, ajustes, mermas, cambios de precio, altas y bajas de personal,
 * cambios de sede y de horario, accesos fuera de turno, traslados, cierres con
 * diferencia— y no cada venta, que ya tiene su propio registro.
 */
import { query } from '../db/pool.js';
import { txExecute } from '../db/tx.js';

const SQL = `INSERT INTO auditoria
  (usuario_id, sede_id, dispositivo_uuid, accion, entidad, entidad_uuid, datos_antes, datos_despues, ip)
  VALUES (?,?,?,?,?,?,?,?,?)`;

const json = (v) => (v == null ? null : JSON.stringify(v));

/**
 * @param conn  conexión de la transacción en curso, o null para escribir suelto
 * @param a     { usuarioId, sedeId, dispositivoUuid, accion, entidad,
 *                entidadUuid, antes, despues, ip }
 */
export async function registrarAuditoria(conn, a) {
  const params = [
    a.usuarioId ?? null,
    a.sedeId ?? null,
    a.dispositivoUuid ?? null,
    a.accion,
    a.entidad,
    a.entidadUuid ?? null,
    json(a.antes),
    json(a.despues),
    a.ip ?? null,
  ];
  if (conn) await txExecute(conn, SQL, params);
  else await query(SQL, params);
}

/** Acciones auditadas. Un catálogo cerrado permite filtrar por acción. */
export const ACCIONES = Object.freeze({
  VENTA_ANULADA: 'VENTA_ANULADA',
  STOCK_AJUSTADO: 'STOCK_AJUSTADO',
  MERMA_REGISTRADA: 'MERMA_REGISTRADA',
  ENTRADA_REGISTRADA: 'ENTRADA_REGISTRADA',
  AJUSTE_SOLICITADO: 'AJUSTE_SOLICITADO',
  AJUSTE_APROBADO: 'AJUSTE_APROBADO',
  AJUSTE_RECHAZADO: 'AJUSTE_RECHAZADO',
  PRECIO_CAMBIADO: 'PRECIO_CAMBIADO',
  PRODUCTO_ELIMINADO: 'PRODUCTO_ELIMINADO',
  USUARIO_CREADO: 'USUARIO_CREADO',
  USUARIO_ACTIVADO: 'USUARIO_ACTIVADO',
  USUARIO_DESACTIVADO: 'USUARIO_DESACTIVADO',
  USUARIO_ELIMINADO: 'USUARIO_ELIMINADO',
  ROL_CAMBIADO: 'ROL_CAMBIADO',
  SEDES_CAMBIADAS: 'SEDES_CAMBIADAS',
  HORARIO_CAMBIADO: 'HORARIO_CAMBIADO',
  ACCESO_EXTRA_OTORGADO: 'ACCESO_EXTRA_OTORGADO',
  ACCESO_EXTRA_REVOCADO: 'ACCESO_EXTRA_REVOCADO',
  INGRESO_FUERA_DE_HORARIO: 'INGRESO_FUERA_DE_HORARIO',
  TRASLADO_APROBADO: 'TRASLADO_APROBADO',
  TRASLADO_RECHAZADO: 'TRASLADO_RECHAZADO',
  CIERRE_CON_DIFERENCIA: 'CIERRE_CON_DIFERENCIA',
  CIERRE_REVISADO: 'CIERRE_REVISADO',
  RECAUDO_REGISTRADO: 'RECAUDO_REGISTRADO',
  MEDIO_PAGO_CAMBIADO: 'MEDIO_PAGO_CAMBIADO',
  SEDE_CREADA: 'SEDE_CREADA',
  SEDE_CAMBIADA: 'SEDE_CAMBIADA',
  NEGOCIO_CAMBIADO: 'NEGOCIO_CAMBIADO',
});
