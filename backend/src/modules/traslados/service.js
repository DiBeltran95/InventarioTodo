/**
 * Traslados entre sedes.
 *
 * Flujo simple: PENDIENTE → APROBADO («despachado») mueve el stock en el acto
 * (sale de la sede origen, entra en la destino) dentro de la MISMA transacción
 * que cambia el estado. Las reglas de quién puede qué están en
 * src/domain/traslados.js.
 *
 * Dos formas de nacer:
 *   · SOLICITUD: la pide un gerente y queda PENDIENTE hasta que el auxiliar de
 *     la sede origen o el director la despachan —con las unidades que decidan—
 *     o la rechazan.
 *   · DIRECTO: el director o un auxiliar mueven unidades sin solicitud; nace y
 *     se despacha en la misma operación.
 *
 * Todo cambio de estado deja un evento con su usuario y su hora: el historial
 * del traslado es la trazabilidad que pide el negocio.
 *
 * Llegan por /sync/push (TRASLADO_CREAR, _APROBAR, _RECHAZAR, _CANCELAR), así
 * que funcionan sin conexión. Si dos personas resuelven el mismo traslado sin
 * red, la segunda recibe TRASLADO_YA_RESUELTO, que es permanente: su operación
 * sale de la cola y aparece en «Elementos con problema».
 */
import { txQuery, txQueryOne, txExecute } from '../../db/tx.js';
import { nuevoUuid } from '../../utils/ids.js';
import { badRequest, conflict, forbidden, notFound } from '../../utils/ApiError.js';
import { toQty, fromQty } from '../../utils/money.js';
import {
  puedeSolicitar,
  puedeMover,
  puedeDespachar,
  puedeCancelar,
  repartoDeDespacho,
} from '../../domain/traslados.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';
import { bloquearProductos, insertarMovimiento, stockEnSede } from '../inventario/service.js';
import { sedePorUuid } from '../sedes/repo.js';

const usuarioDe = (ctx) => ({ id: ctx.usuarioId, rol: ctx.rol, alcance: ctx.alcance });

async function evento(conn, trasladoId, tipo, ctx, nota = null) {
  await txExecute(
    conn,
    'INSERT INTO traslado_eventos (uuid, traslado_id, evento, usuario_id, fecha, nota) VALUES (?,?,?,?, UTC_TIMESTAMP(3), ?)',
    [nuevoUuid(), trasladoId, tipo, ctx.usuarioId ?? null, nota],
  );
}

async function bloquearTraslado(conn, uuid) {
  const t = await txQueryOne(
    conn,
    `SELECT t.id, t.uuid, t.numero, t.estado, t.confirma, t.sede_origen_id, t.sede_destino_id,
            t.solicitado_por, t.resuelto_por, so.nombre AS origen, sd.nombre AS destino
       FROM traslados t
       JOIN sedes so ON so.id = t.sede_origen_id
       JOIN sedes sd ON sd.id = t.sede_destino_id
      WHERE t.uuid = ? AND t.deleted_at IS NULL
      FOR UPDATE`,
    [uuid],
  );
  if (!t) throw notFound('Traslado');
  return t;
}

/** Número legible. El dispositivo lo trae ya asignado (TR-A1-000001). */
async function asignarNumero(conn, numero, ctx) {
  if (numero) return numero;
  const prefijo = ctx.dispositivoUuid
    ? (await txQueryOne(conn, 'SELECT prefijo_folio FROM dispositivos WHERE uuid = ?', [ctx.dispositivoUuid]))
        ?.prefijo_folio
    : null;
  const base = `TR-${prefijo ?? 'SRV'}-`;
  const fila = await txQueryOne(
    conn,
    `SELECT IFNULL(MAX(CAST(SUBSTRING_INDEX(numero, '-', -1) AS UNSIGNED)), 0) n
       FROM traslados WHERE numero LIKE CONCAT(?, '%')`,
    [base],
  );
  return `${base}${String(Number(fila.n) + 1).padStart(6, '0')}`;
}

export async function crearTraslado(conn, p, ctx) {
  const uuid = p.uuid ?? nuevoUuid();
  const existente = await txQueryOne(conn, 'SELECT uuid FROM traslados WHERE uuid = ?', [uuid]);
  if (existente) return { uuid, duplicado: true };

  if (!p.detalles?.length) throw badRequest('TRASLADO_VACIO', 'El traslado no tiene productos');

  const origen = await sedePorUuid(conn, p.sede_origen_uuid);
  const destino = await sedePorUuid(conn, p.sede_destino_uuid);
  if (!origen || !destino) throw notFound('Sede');
  if (!origen.activo || !destino.activo) throw badRequest('SEDE_INACTIVA', 'Una de las sedes está desactivada');

  const directo = p.directo === true;
  const motivo = directo
    ? puedeMover(usuarioDe(ctx), origen.id, destino.id)
    : puedeSolicitar(usuarioDe(ctx), origen.id, destino.id);
  if (motivo) throw forbidden(motivo, 'SIN_PERMISO');

  const productos = await txQuery(
    conn,
    'SELECT id, uuid, nombre FROM productos WHERE uuid IN (?) AND deleted_at IS NULL',
    [p.detalles.map((d) => d.producto_uuid)],
  );
  const porUuid = new Map(productos.map((x) => [x.uuid, x]));

  const fecha = p.fecha ? new Date(p.fecha) : new Date();
  let numero = await asignarNumero(conn, p.numero, ctx);
  let trasladoId;
  for (let intento = 0; intento < 3; intento += 1) {
    try {
      const r = await txExecute(
        conn,
        `INSERT INTO traslados
           (uuid, numero, sede_origen_id, sede_destino_id, estado, tipo, confirma, notas,
            solicitado_por, solicitado_en, dispositivo_uuid)
         VALUES (?,?,?,?, 'PENDIENTE', ?, 'ORIGEN', ?,?,?,?)`,
        [
          uuid,
          numero,
          origen.id,
          destino.id,
          directo ? 'DIRECTO' : 'SOLICITUD',
          p.notas ?? null,
          ctx.usuarioId ?? null,
          fecha,
          ctx.dispositivoUuid ?? null,
        ],
      );
      trasladoId = r.insertId;
      break;
    } catch (err) {
      const choca = err.code === 'ER_DUP_ENTRY' && err.sqlMessage?.includes('uk_traslados_numero');
      if (!choca || intento === 2) throw err;
      // Dos dispositivos con el mismo número: se conserva el traslado.
      numero = `${numero}+${nuevoUuid().slice(0, 4)}`;
    }
  }

  for (const d of p.detalles) {
    const producto = porUuid.get(d.producto_uuid);
    if (!producto) throw badRequest('PRODUCTO_INEXISTENTE', `El producto ${d.producto_uuid} no existe`);
    const cantidad = toQty(d.cantidad);
    if (cantidad <= 0n) throw badRequest('CANTIDAD_INVALIDA', 'Cada cantidad debe ser mayor que cero');
    await txExecute(
      conn,
      'INSERT INTO traslado_detalles (uuid, traslado_id, producto_id, descripcion, cantidad) VALUES (?,?,?,?,?)',
      [d.uuid ?? nuevoUuid(), trasladoId, producto.id, producto.nombre, fromQty(cantidad)],
    );
  }

  await evento(conn, trasladoId, 'CREADO', ctx, p.notas ?? null);

  if (directo) {
    // Nace despachado: misma transacción, mismas comprobaciones de stock.
    const t = await bloquearTraslado(conn, uuid);
    const r = await despachar(conn, t, p, ctx, 'Movimiento directo');
    return { ...r, tipo: 'DIRECTO' };
  }
  return { uuid, numero, estado: 'PENDIENTE', tipo: 'SOLICITUD' };
}

export async function aprobarTraslado(conn, p, ctx) {
  const t = await bloquearTraslado(conn, p.uuid);
  // Reenvío del mismo despacho: idempotente.
  if (t.estado === 'APROBADO' && Number(t.resuelto_por) === Number(ctx.usuarioId)) {
    return { uuid: t.uuid, estado: t.estado, duplicado: true };
  }
  const motivo = puedeDespachar(t, usuarioDe(ctx));
  if (motivo) {
    throw t.estado !== 'PENDIENTE'
      ? conflict('TRASLADO_YA_RESUELTO', `El traslado ${t.numero} ya está ${t.estado.toLowerCase()}`)
      : forbidden(motivo, 'SIN_PERMISO');
  }
  return despachar(conn, t, p, ctx, null);
}

/**
 * Mueve el stock de un traslado bloqueado y lo marca despachado.
 *
 * `p.movimientos` trae, por línea, los uuid de los dos movimientos (los genera
 * el teléfono para que su copia y la del servidor sean la MISMA fila) y,
 * opcionalmente, `cantidad`: lo que de verdad sale. Sin cantidad sale lo
 * pedido, que es como despachan los teléfonos anteriores a esta versión.
 */
async function despachar(conn, t, p, ctx, nota) {
  const detalles = await txQuery(
    conn,
    `SELECT d.id, d.uuid, d.cantidad, d.descripcion, p.uuid AS producto_uuid
       FROM traslado_detalles d JOIN productos p ON p.id = d.producto_id
      WHERE d.traslado_id = ?`,
    [t.id],
  );
  const delCliente = new Map((p.movimientos ?? []).map((m) => [m.detalle_uuid, m]));
  const enviadas = new Map();
  for (const [detalleUuid, m] of delCliente) {
    if (m.cantidad != null) enviadas.set(detalleUuid, toQty(m.cantidad));
  }
  const reparto = repartoDeDespacho(
    detalles.map((d) => ({ uuid: d.uuid, cantidad: toQty(d.cantidad) })),
    enviadas,
  );
  if (reparto.error) throw badRequest('TRASLADO_SIN_UNIDADES', reparto.error);
  const enviadaDe = new Map(reparto.lineas.map((l) => [l.uuid, l.enviada]));

  const productos = await bloquearProductos(conn, detalles.map((d) => d.producto_uuid));

  // Con los productos bloqueados, el stock de origen no puede cambiar mientras
  // se comprueba. No se envía lo que no hay: a diferencia de una venta sin
  // conexión, esto se puede rechazar sin descuadrar nada.
  const faltantes = [];
  const porProducto = new Map();
  for (const d of detalles) {
    porProducto.set(d.producto_uuid, (porProducto.get(d.producto_uuid) ?? 0n) + enviadaDe.get(d.uuid));
  }
  for (const [productoUuid, enviar] of porProducto) {
    if (enviar <= 0n) continue;
    const producto = productos.get(productoUuid);
    const disponible = toQty(await stockEnSede(conn, producto.id, t.sede_origen_id));
    if (disponible < enviar) {
      faltantes.push(`${producto.nombre}: hay ${fromQty(disponible)}, se envían ${fromQty(enviar)}`);
    }
  }
  if (faltantes.length) {
    throw conflict(
      'TRASLADO_SIN_STOCK',
      `${t.origen} no tiene suficiente para el traslado ${t.numero}. ${faltantes.join('; ')}`,
    );
  }

  const fecha = p.fecha ? new Date(p.fecha) : new Date();
  for (const d of detalles) {
    const enviada = enviadaDe.get(d.uuid);
    await txExecute(conn, 'UPDATE traslado_detalles SET cantidad_enviada = ? WHERE id = ?', [
      fromQty(enviada),
      d.id,
    ]);
    if (enviada <= 0n) continue;
    const producto = productos.get(d.producto_uuid);
    const uuids = delCliente.get(d.uuid) ?? {};
    await insertarMovimiento(
      conn,
      producto,
      {
        uuid: uuids.salida_uuid,
        tipo: 'TRASLADO',
        cantidad: fromQty(-enviada),
        sede_id: t.sede_origen_id,
        traslado_id: t.id,
        motivo: `Traslado ${t.numero} a ${t.destino}`,
        fecha,
        creado_offline: p.creado_offline,
      },
      ctx,
    );
    await insertarMovimiento(
      conn,
      producto,
      {
        uuid: uuids.entrada_uuid,
        tipo: 'TRASLADO',
        cantidad: fromQty(enviada),
        sede_id: t.sede_destino_id,
        traslado_id: t.id,
        motivo: `Traslado ${t.numero} desde ${t.origen}`,
        fecha,
        creado_offline: p.creado_offline,
      },
      ctx,
    );
  }

  await txExecute(
    conn,
    "UPDATE traslados SET estado = 'APROBADO', resuelto_por = ?, resuelto_en = ? WHERE id = ?",
    [ctx.usuarioId, fecha, t.id],
  );
  const parcial = reparto.lineas.some((l) => l.enviada !== l.pedida);
  await evento(conn, t.id, 'APROBADO', ctx, nota ?? (parcial ? 'Despacho parcial' : null));
  await registrarAuditoria(conn, {
    usuarioId: ctx.usuarioId,
    sedeId: t.sede_origen_id,
    dispositivoUuid: ctx.dispositivoUuid,
    accion: ACCIONES.TRASLADO_APROBADO,
    entidad: 'traslados',
    entidadUuid: t.uuid,
    despues: {
      numero: t.numero,
      origen: t.origen,
      destino: t.destino,
      directo: nota === 'Movimiento directo',
      productos: detalles.map((d) => ({
        producto: d.descripcion,
        pedida: d.cantidad,
        enviada: fromQty(enviadaDe.get(d.uuid)),
      })),
    },
  });
  return { uuid: t.uuid, numero: t.numero, estado: 'APROBADO', parcial };
}

export async function rechazarTraslado(conn, p, ctx) {
  const t = await bloquearTraslado(conn, p.uuid);
  if (t.estado === 'RECHAZADO' && Number(t.resuelto_por) === Number(ctx.usuarioId)) {
    return { uuid: t.uuid, estado: t.estado, duplicado: true };
  }
  const motivo = puedeDespachar(t, usuarioDe(ctx));
  if (motivo) {
    throw t.estado !== 'PENDIENTE'
      ? conflict('TRASLADO_YA_RESUELTO', `El traslado ${t.numero} ya está ${t.estado.toLowerCase()}`)
      : forbidden(motivo, 'SIN_PERMISO');
  }
  await txExecute(
    conn,
    "UPDATE traslados SET estado = 'RECHAZADO', resuelto_por = ?, resuelto_en = UTC_TIMESTAMP(3), motivo_rechazo = ? WHERE id = ?",
    [ctx.usuarioId, p.motivo ?? null, t.id],
  );
  await evento(conn, t.id, 'RECHAZADO', ctx, p.motivo ?? null);
  await registrarAuditoria(conn, {
    usuarioId: ctx.usuarioId,
    sedeId: t.sede_origen_id,
    dispositivoUuid: ctx.dispositivoUuid,
    accion: ACCIONES.TRASLADO_RECHAZADO,
    entidad: 'traslados',
    entidadUuid: t.uuid,
    despues: { numero: t.numero, motivo: p.motivo ?? null },
  });
  return { uuid: t.uuid, estado: 'RECHAZADO' };
}

export async function cancelarTraslado(conn, p, ctx) {
  const t = await bloquearTraslado(conn, p.uuid);
  if (t.estado === 'CANCELADO') return { uuid: t.uuid, estado: t.estado, duplicado: true };
  const motivo = puedeCancelar(t, usuarioDe(ctx));
  if (motivo) {
    throw t.estado !== 'PENDIENTE'
      ? conflict('TRASLADO_YA_RESUELTO', `El traslado ${t.numero} ya está ${t.estado.toLowerCase()}`)
      : forbidden(motivo, 'SIN_PERMISO');
  }
  await txExecute(
    conn,
    "UPDATE traslados SET estado = 'CANCELADO', resuelto_por = ?, resuelto_en = UTC_TIMESTAMP(3) WHERE id = ?",
    [ctx.usuarioId, t.id],
  );
  await evento(conn, t.id, 'CANCELADO', ctx, p.motivo ?? null);
  return { uuid: t.uuid, estado: 'CANCELADO' };
}
