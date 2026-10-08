/**
 * Cierre de caja por turno.
 *
 * ABRIR: quien vende declara con cuánto efectivo empieza (la base). Cada venta
 * del turno lleva su `turno_uuid`.
 *
 * CERRAR: cuenta lo que hay por medio de pago. Lo esperado lo calcula el
 * SERVIDOR con las ventas del turno ya sincronizadas —la cola sube en orden,
 * así que llegan antes que el cierre— y guarda la diferencia. La app muestra su
 * propio cálculo mientras tanto, pero la cifra que vale es ésta.
 *
 * REVISAR: el gerente o el director marcan el cierre como visto.
 */
import { txQuery, txQueryOne, txExecute } from '../../db/tx.js';
import { badRequest, conflict, forbidden, notFound } from '../../utils/ApiError.js';
import { toCents, fromCents } from '../../utils/money.js';
import { ROLES_QUE_VENDEN, ROLES_GESTORES } from '../../config/constants.js';
import { veSede } from '../../domain/alcance.js';
import { calcularEsperado, compararConteo } from '../../domain/caja.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';

export async function abrirCaja(conn, p, ctx) {
  if (!ROLES_QUE_VENDEN.includes(ctx.rol)) {
    throw forbidden('Tu rol no maneja caja', 'SIN_PERMISO');
  }
  const existente = await txQueryOne(conn, 'SELECT uuid, estado FROM cierres_caja WHERE uuid = ?', [p.uuid]);
  if (existente) return { uuid: p.uuid, estado: existente.estado, duplicado: true };

  // Una sola caja abierta por persona: dos cajas a la vez harían imposible
  // saber a cuál pertenece cada venta.
  const abierta = await txQueryOne(
    conn,
    "SELECT uuid FROM cierres_caja WHERE usuario_id = ? AND estado = 'ABIERTO' LIMIT 1",
    [ctx.usuarioId],
  );
  if (abierta) {
    throw conflict('CAJA_YA_ABIERTA', 'Ya tienes una caja abierta: ciérrala antes de abrir otra', {
      turno_uuid: abierta.uuid,
    });
  }
  if (!ctx.sedeId) throw badRequest('SIN_SEDE', 'Falta la sede de la caja');

  const base = toCents(p.base_efectivo ?? '0');
  if (base < 0n) throw badRequest('BASE_NEGATIVA', 'La base de efectivo no puede ser negativa');

  await txExecute(
    conn,
    `INSERT INTO cierres_caja (uuid, sede_id, usuario_id, dispositivo_uuid, estado, abierto_en, base_efectivo)
     VALUES (?,?,?,?, 'ABIERTO', ?, ?)`,
    [p.uuid, ctx.sedeId, ctx.usuarioId, ctx.dispositivoUuid ?? null, new Date(p.abierto_en ?? Date.now()), fromCents(base)],
  );
  return { uuid: p.uuid, estado: 'ABIERTO' };
}

export async function cerrarCaja(conn, p, ctx) {
  const c = await txQueryOne(
    conn,
    'SELECT id, uuid, sede_id, usuario_id, estado, base_efectivo FROM cierres_caja WHERE uuid = ? FOR UPDATE',
    [p.uuid],
  );
  if (!c) throw notFound('Caja');
  if (c.estado === 'CERRADO') return { uuid: c.uuid, estado: 'CERRADO', duplicado: true };
  if (Number(c.usuario_id) !== Number(ctx.usuarioId) && !ROLES_GESTORES.includes(ctx.rol)) {
    throw forbidden('Sólo quien abrió la caja (o un gerente) la cierra', 'SIN_PERMISO');
  }

  const cobros = await txQuery(
    conn,
    `SELECT mp.uuid AS metodo_uuid, vp.metodo_nombre, vp.metodo_tipo, SUM(vp.monto) AS monto
       FROM venta_pagos vp
       JOIN ventas v ON v.id = vp.venta_id
       LEFT JOIN metodos_pago mp ON mp.id = vp.metodo_pago_id
      WHERE v.turno_uuid = ? AND v.estado = 'COMPLETADA' AND v.deleted_at IS NULL
      GROUP BY mp.uuid, vp.metodo_nombre, vp.metodo_tipo`,
    [c.uuid],
  );

  const esperados = calcularEsperado(
    toCents(c.base_efectivo),
    cobros.map((x) => ({ ...x, monto: toCents(x.monto) })),
  );
  const resultado = compararConteo(
    esperados,
    (p.contado ?? []).map((x) => ({
      metodo_uuid: x.metodo_uuid ?? null,
      metodo_tipo: x.metodo_tipo,
      contado: x.contado == null ? null : toCents(x.contado),
    })),
  );

  const detalle = resultado.detalle.map((d) => ({
    metodo_uuid: d.metodo_uuid,
    metodo_nombre: d.metodo_nombre,
    metodo_tipo: d.metodo_tipo,
    esperado: fromCents(d.esperado),
    contado: d.contado == null ? null : fromCents(d.contado),
    diferencia: d.diferencia == null ? null : fromCents(d.diferencia),
  }));

  await txExecute(
    conn,
    `UPDATE cierres_caja
        SET estado = 'CERRADO', cerrado_en = ?, cierre_tardio = ?,
            esperado_total = ?, contado_total = ?, diferencia_efectivo = ?, detalle = ?, notas = ?
      WHERE id = ?`,
    [
      new Date(p.cerrado_en ?? Date.now()),
      p.cierre_tardio ? 1 : 0,
      fromCents(resultado.esperadoTotal),
      fromCents(resultado.contadoTotal),
      resultado.diferenciaEfectivo == null ? null : fromCents(resultado.diferenciaEfectivo),
      JSON.stringify(detalle),
      p.notas ?? null,
      c.id,
    ],
  );

  // Un faltante o sobrante queda en la auditoría: es lo que el gerente revisa.
  if (resultado.diferenciaEfectivo != null && resultado.diferenciaEfectivo !== 0n) {
    await registrarAuditoria(conn, {
      usuarioId: ctx.usuarioId,
      sedeId: c.sede_id,
      dispositivoUuid: ctx.dispositivoUuid,
      accion: ACCIONES.CIERRE_CON_DIFERENCIA,
      entidad: 'cierres_caja',
      entidadUuid: c.uuid,
      despues: {
        diferencia_efectivo: fromCents(resultado.diferenciaEfectivo),
        notas: p.notas ?? null,
        tardio: !!p.cierre_tardio,
      },
    });
  }

  return {
    uuid: c.uuid,
    estado: 'CERRADO',
    diferencia_efectivo: resultado.diferenciaEfectivo == null ? null : fromCents(resultado.diferenciaEfectivo),
    detalle,
  };
}

export async function revisarCierre(conn, p, ctx) {
  const c = await txQueryOne(
    conn,
    'SELECT id, uuid, sede_id, estado, revisado_por FROM cierres_caja WHERE uuid = ? FOR UPDATE',
    [p.uuid],
  );
  if (!c) throw notFound('Caja');
  if (!ROLES_GESTORES.includes(ctx.rol) || !veSede(ctx.alcance, c.sede_id)) {
    throw forbidden('Revisa el gerente de la sede o el director', 'SIN_PERMISO');
  }
  if (c.estado !== 'CERRADO') throw conflict('CAJA_ABIERTA', 'La caja todavía no se ha cerrado');
  if (c.revisado_por) return { uuid: c.uuid, duplicado: true };

  await txExecute(
    conn,
    'UPDATE cierres_caja SET revisado_por = ?, revisado_en = UTC_TIMESTAMP(3) WHERE id = ?',
    [ctx.usuarioId, c.id],
  );
  await registrarAuditoria(conn, {
    usuarioId: ctx.usuarioId,
    sedeId: c.sede_id,
    dispositivoUuid: ctx.dispositivoUuid,
    accion: ACCIONES.CIERRE_REVISADO,
    entidad: 'cierres_caja',
    entidadUuid: c.uuid,
  });
  return { uuid: c.uuid, revisado: true };
}
