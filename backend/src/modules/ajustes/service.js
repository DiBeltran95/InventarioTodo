/**
 * Solicitudes de ajuste del Auxiliar de Inventario.
 *
 * El auxiliar registra entradas directamente, pero un conteo, una merma o un
 * ajuste —las vías con las que se tapa un faltante— sólo quedan PENDIENTES.
 * El stock no se toca hasta que un gerente de la sede o el director los
 * aprueba; entonces se crea el movimiento a nombre del solicitante y con el
 * aprobador registrado (`movimientos_inventario.aprobado_por`).
 *
 * Un CONTEO guarda lo que había físicamente, no la diferencia: la diferencia se
 * calcula AL APROBAR, contra el stock de ese momento. Si entre el conteo y la
 * aprobación se vendió algo, una diferencia calculada antes ya estaría vieja.
 */
import { txQueryOne, txExecute } from '../../db/tx.js';
import { nuevoUuid } from '../../utils/ids.js';
import { badRequest, conflict, forbidden, notFound } from '../../utils/ApiError.js';
import { toQty, fromQty } from '../../utils/money.js';
import { ROLES, ROLES_GESTORES } from '../../config/constants.js';
import { veSede } from '../../domain/alcance.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';
import { bloquearProducto, insertarMovimiento, ajustarPorConteo } from '../inventario/service.js';

const TIPOS = ['CONTEO', 'MERMA', 'AJUSTE'];

export async function solicitarAjuste(conn, p, ctx) {
  const uuid = p.uuid ?? nuevoUuid();
  const existente = await txQueryOne(conn, 'SELECT uuid, estado FROM solicitudes_ajuste WHERE uuid = ?', [uuid]);
  if (existente) return { uuid, estado: existente.estado, duplicado: true };

  if (!TIPOS.includes(p.tipo)) throw badRequest('TIPO_INVALIDO', 'Tipo de ajuste inválido');
  if (p.tipo === 'CONTEO' && p.stock_contado == null) {
    throw badRequest('FALTA_CONTEO', 'Indica cuánto hay físicamente');
  }
  if (p.tipo !== 'CONTEO' && (p.cantidad == null || toQty(p.cantidad) === 0n)) {
    throw badRequest('FALTA_CANTIDAD', 'Indica la cantidad');
  }
  if (p.tipo === 'MERMA' && toQty(p.cantidad) < 0n) {
    throw badRequest('MERMA_NEGATIVA', 'La merma se indica en positivo: es lo que se perdió');
  }
  if (!ctx.sedeId || !veSede(ctx.alcance, ctx.sedeId)) {
    throw forbidden('Sólo puedes pedir ajustes en tu sede', 'SEDE_FUERA_DE_ALCANCE');
  }

  const producto = await txQueryOne(conn, 'SELECT id, uuid, nombre FROM productos WHERE uuid = ? AND deleted_at IS NULL', [
    p.producto_uuid,
  ]);
  if (!producto) throw notFound('Producto');

  await txExecute(
    conn,
    `INSERT INTO solicitudes_ajuste
       (uuid, sede_id, producto_id, tipo, cantidad, stock_contado, motivo, estado,
        solicitado_por, solicitado_en, dispositivo_uuid)
     VALUES (?,?,?,?,?,?,?, 'PENDIENTE', ?,?,?)`,
    [
      uuid,
      ctx.sedeId,
      producto.id,
      p.tipo,
      p.tipo === 'CONTEO' ? null : p.cantidad,
      p.tipo === 'CONTEO' ? p.stock_contado : null,
      p.motivo ?? null,
      ctx.usuarioId,
      p.fecha ? new Date(p.fecha) : new Date(),
      ctx.dispositivoUuid ?? null,
    ],
  );
  await registrarAuditoria(conn, {
    usuarioId: ctx.usuarioId,
    sedeId: ctx.sedeId,
    dispositivoUuid: ctx.dispositivoUuid,
    accion: ACCIONES.AJUSTE_SOLICITADO,
    entidad: 'solicitudes_ajuste',
    entidadUuid: uuid,
    despues: {
      producto: producto.nombre,
      tipo: p.tipo,
      cantidad: p.cantidad ?? null,
      stock_contado: p.stock_contado ?? null,
      motivo: p.motivo ?? null,
    },
  });
  return { uuid, estado: 'PENDIENTE' };
}

async function bloquearSolicitud(conn, uuid) {
  const s = await txQueryOne(
    conn,
    `SELECT sa.id, sa.uuid, sa.sede_id, sa.tipo, sa.cantidad, sa.stock_contado, sa.motivo, sa.estado,
            sa.solicitado_por, sa.resuelto_por, p.uuid AS producto_uuid, p.nombre AS producto
       FROM solicitudes_ajuste sa JOIN productos p ON p.id = sa.producto_id
      WHERE sa.uuid = ? FOR UPDATE`,
    [uuid],
  );
  if (!s) throw notFound('Solicitud de ajuste');
  return s;
}

function exigirResolvible(s, ctx) {
  if (s.estado !== 'PENDIENTE') {
    throw conflict('AJUSTE_YA_RESUELTO', `La solicitud ya está ${s.estado.toLowerCase()}`);
  }
  if (!ROLES_GESTORES.includes(ctx.rol) || !veSede(ctx.alcance, s.sede_id)) {
    throw forbidden('La aprueba el gerente de la sede o el director', 'SIN_PERMISO');
  }
  if (Number(s.solicitado_por) === Number(ctx.usuarioId) && ctx.rol !== ROLES.ADMIN) {
    throw forbidden('Un ajuste lo aprueba otra persona, no quien lo pidió', 'SIN_PERMISO');
  }
}

export async function aprobarAjuste(conn, p, ctx) {
  const s = await bloquearSolicitud(conn, p.uuid);
  if (s.estado === 'APROBADA' && Number(s.resuelto_por) === Number(ctx.usuarioId)) {
    return { uuid: s.uuid, estado: s.estado, duplicado: true };
  }
  exigirResolvible(s, ctx);

  // El movimiento es del solicitante —él contó o vio la merma—, con el
  // aprobador registrado. Sede: la de la solicitud, no la del aprobador.
  const ctxMov = { ...ctx, sedeId: s.sede_id };
  const comun = {
    uuid: p.movimiento_uuid,
    sede_id: s.sede_id,
    usuario_id: s.solicitado_por,
    aprobado_por: ctx.usuarioId,
    motivo: s.motivo,
  };

  let movimiento;
  if (s.tipo === 'CONTEO') {
    movimiento = await ajustarPorConteo(
      conn,
      {
        ...comun,
        producto_uuid: s.producto_uuid,
        stock_contado: s.stock_contado,
        motivo: s.motivo ?? undefined,
      },
      ctxMov,
    );
  } else {
    const producto = await bloquearProducto(conn, s.producto_uuid);
    movimiento = await insertarMovimiento(
      conn,
      producto,
      { ...comun, tipo: s.tipo === 'MERMA' ? 'MERMA' : 'AJUSTE', cantidad: s.cantidad },
      ctxMov,
    );
  }

  const movimientoId = movimiento?.uuid
    ? (await txQueryOne(conn, 'SELECT id FROM movimientos_inventario WHERE uuid = ?', [movimiento.uuid]))?.id
    : null;

  await txExecute(
    conn,
    "UPDATE solicitudes_ajuste SET estado = 'APROBADA', resuelto_por = ?, resuelto_en = UTC_TIMESTAMP(3), movimiento_id = ? WHERE id = ?",
    [ctx.usuarioId, movimientoId ?? null, s.id],
  );
  await registrarAuditoria(conn, {
    usuarioId: ctx.usuarioId,
    sedeId: s.sede_id,
    dispositivoUuid: ctx.dispositivoUuid,
    accion: ACCIONES.AJUSTE_APROBADO,
    entidad: 'solicitudes_ajuste',
    entidadUuid: s.uuid,
    despues: {
      producto: s.producto,
      tipo: s.tipo,
      diferencia: movimiento?.diferencia ?? (s.cantidad != null ? fromQty(toQty(s.cantidad)) : null),
      sin_cambios: !!movimiento?.sin_cambios,
    },
  });
  return { uuid: s.uuid, estado: 'APROBADA', movimiento_uuid: movimiento?.uuid ?? null };
}

export async function rechazarAjuste(conn, p, ctx) {
  const s = await bloquearSolicitud(conn, p.uuid);
  if (s.estado === 'RECHAZADA' && Number(s.resuelto_por) === Number(ctx.usuarioId)) {
    return { uuid: s.uuid, estado: s.estado, duplicado: true };
  }
  exigirResolvible(s, ctx);
  await txExecute(
    conn,
    "UPDATE solicitudes_ajuste SET estado = 'RECHAZADA', resuelto_por = ?, resuelto_en = UTC_TIMESTAMP(3), motivo_rechazo = ? WHERE id = ?",
    [ctx.usuarioId, p.motivo ?? null, s.id],
  );
  await registrarAuditoria(conn, {
    usuarioId: ctx.usuarioId,
    sedeId: s.sede_id,
    dispositivoUuid: ctx.dispositivoUuid,
    accion: ACCIONES.AJUSTE_RECHAZADO,
    entidad: 'solicitudes_ajuste',
    entidadUuid: s.uuid,
    despues: { producto: s.producto, tipo: s.tipo, motivo: p.motivo ?? null },
  });
  return { uuid: s.uuid, estado: 'RECHAZADA' };
}
