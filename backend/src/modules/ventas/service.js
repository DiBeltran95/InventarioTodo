import { query, queryOne } from '../../db/pool.js';
import { txQuery, txQueryOne, txExecute } from '../../db/tx.js';
import { nuevoUuid } from '../../utils/ids.js';
import { notFound, badRequest, conflict } from '../../utils/ApiError.js';
import { diaHabil } from '../../utils/dates.js';
import {
  calcularLinea,
  totalizarVenta,
  toCents,
  fromCents,
  toQty,
  fromQty,
  multiplicarPorCantidad,
  sumar,
} from '../../utils/money.js';
import { bloquearProductos, insertarMovimiento, registrarAlerta } from '../inventario/service.js';

/**
 * Numeración de folios.
 *
 * Una venta creada sin conexión trae su propio `numero`, generado por el
 * dispositivo con su prefijo único (A1-000042). Una venta creada en línea lo
 * pide al servidor. La carrera entre dos ventas simultáneas se resuelve
 * reintentando ante clave duplicada: es más simple y barato que un contador
 * bloqueado, y ocurre rarísimas veces.
 */
async function prefijoDelDispositivo(conn, dispositivoUuid) {
  if (!dispositivoUuid) return 'WEB';
  const d = await txQueryOne(conn, 'SELECT prefijo_folio FROM dispositivos WHERE uuid = ?', [dispositivoUuid]);
  return d?.prefijo_folio ?? 'WEB';
}

/**
 * Escribe el desglose del cobro y deja `ventas.metodo_pago` coherente.
 *
 * Dos invariantes que se comprueban aquí y no más arriba:
 *
 *  · **La suma de los pagos es exactamente el total.** Se compara en centavos
 *    enteros, nunca en coma flotante: aceptar un cobro que no cuadra por un
 *    peso descuadra la caja del día y nadie sabe dónde buscarlo.
 *  · **Cada pago guarda el NOMBRE del medio**, no sólo su id. Si mañana se
 *    renombra «Nequi» o se da de baja, el ticket histórico debe seguir
 *    diciendo por dónde entró el dinero.
 *
 * La columna `ventas.metodo_pago` se conserva para no romper los tickets y
 * reportes que ya la leían: con un solo medio guarda su tipo, con varios,
 * 'MIXTO'.
 */
async function registrarPagos(conn, { ventaId, total, numero, pagos, metodoLegado, montoRecibido, cambio }) {
  // Sin desglose (app anterior a esta funcionalidad): se deriva un pago único
  // por el total, para que el histórico quede completo igualmente.
  const lista =
    pagos && pagos.length
      ? pagos
      : [
          {
            metodo_nombre: etiquetaMetodo(metodoLegado),
            metodo_tipo: metodoLegado === 'MIXTO' ? 'OTRO' : metodoLegado,
            monto: fromCents(total),
            monto_recibido: montoRecibido,
            cambio,
          },
        ];

  if (pagos && pagos.length) {
    const suma = sumar(lista.map((p) => toCents(p.monto)));
    if (suma !== total) {
      throw badRequest(
        'PAGOS_NO_CUADRAN',
        `Los pagos suman ${fromCents(suma)} y la venta ${numero} totaliza ${fromCents(total)}`,
      );
    }
  }

  // Los uuid de los medios se resuelven de una vez: un SELECT por pago sería
  // una consulta extra en el camino crítico del cobro.
  const uuids = [...new Set(lista.map((p) => p.metodo_pago_uuid).filter(Boolean))];
  const idsPorUuid = new Map();
  if (uuids.length) {
    const filas = await txQuery(
      conn,
      `SELECT id, uuid FROM metodos_pago WHERE uuid IN (${uuids.map(() => '?').join(',')})`,
      uuids,
    );
    for (const f of filas) idsPorUuid.set(f.uuid, f.id);
  }

  for (const pago of lista) {
    await txExecute(
      conn,
      `INSERT INTO venta_pagos
         (uuid, venta_id, metodo_pago_id, metodo_nombre, metodo_tipo,
          monto, monto_recibido, cambio, referencia)
       VALUES (?,?,?,?,?,?,?,?,?)`,
      [
        pago.uuid ?? nuevoUuid(),
        ventaId,
        idsPorUuid.get(pago.metodo_pago_uuid) ?? null,
        pago.metodo_nombre,
        pago.metodo_tipo ?? 'OTRO',
        pago.monto,
        pago.monto_recibido ?? null,
        pago.cambio ?? null,
        pago.referencia ?? null,
      ],
    );
  }

  // `metodo_pago` es un ENUM heredado y sólo admite sus cinco valores; el tipo
  // del medio encaja porque se definió con el mismo vocabulario.
  const resumen =
    lista.length > 1 ? 'MIXTO' : normalizarEnumLegado(lista[0].metodo_tipo);
  await txExecute(conn, 'UPDATE ventas SET metodo_pago = ? WHERE id = ?', [resumen, ventaId]);
}

const ETIQUETAS_LEGADO = {
  EFECTIVO: 'Efectivo',
  TARJETA: 'Tarjeta',
  TRANSFERENCIA: 'Transferencia',
  CREDITO: 'Crédito',
  MIXTO: 'Mixto',
};

function etiquetaMetodo(codigo) {
  return ETIQUETAS_LEGADO[codigo] ?? codigo;
}

/** 'OTRO' no existe en el ENUM heredado; se guarda como 'EFECTIVO'. */
function normalizarEnumLegado(tipo) {
  return ['EFECTIVO', 'TARJETA', 'TRANSFERENCIA', 'CREDITO'].includes(tipo) ? tipo : 'EFECTIVO';
}

async function siguienteFolio(conn, prefijo) {
  const fila = await txQueryOne(conn, 'SELECT fn_siguiente_folio(?) AS folio', [prefijo]);
  return fila.folio;
}

const SELECT_VENTA = `
  v.uuid, v.numero, v.cliente_nombre, v.cliente_documento,
  v.subtotal, v.descuento_total, v.impuesto_total, v.total, v.costo_total,
  v.metodo_pago, v.monto_recibido, v.cambio, v.estado, v.motivo_anulacion,
  v.notas, v.fecha, v.fecha_local, v.creada_offline, v.sincronizada_en,
  v.created_at, v.updated_at,
  u.uuid AS usuario_uuid, u.nombre AS usuario_nombre,
  vo.uuid AS anula_a_venta_uuid`;

const SELECT_DETALLE = `
  d.uuid, d.linea, d.descripcion, d.sku_snapshot, d.cantidad,
  d.precio_unitario, d.costo_unitario, d.descuento, d.tasa_iva,
  d.base_gravable, d.impuesto, d.total,
  p.uuid AS producto_uuid`;

// ── Creación ────────────────────────────────────────────────────────────────

/**
 * Crea una venta completa: cabecera, detalle y movimientos de inventario, todo
 * en la transacción que recibe.
 *
 * Idempotencia en dos niveles:
 *   · a nivel de operación, en /sync/push, por `client_op_id`
 *   · a nivel de entidad, aquí, por `uuid` de la venta
 * El segundo protege incluso si la primera capa se saltara.
 */
export async function crearVenta(conn, datos, ctx) {
  const uuid = datos.uuid ?? nuevoUuid();

  const yaExiste = await txQueryOne(conn, 'SELECT id FROM ventas WHERE uuid = ?', [uuid]);
  if (yaExiste) return { ...(await obtenerVentaTx(conn, uuid)), duplicada: true };

  if (!datos.lineas?.length) throw badRequest('VENTA_VACIA', 'La venta no tiene líneas');

  // Bloqueo en orden de id: evita interbloqueos entre ventas concurrentes que
  // comparten productos.
  const productos = await bloquearProductos(
    conn,
    datos.lineas.map((l) => l.producto_uuid),
  );

  // 1) Cálculo monetario exacto, con snapshot de nombre y costo.
  const lineas = datos.lineas.map((l, i) => {
    const p = productos.get(l.producto_uuid);
    const calculo = calcularLinea({
      precioUnitario: l.precio_unitario ?? p.precio_venta,
      cantidad: l.cantidad,
      descuento: l.descuento ?? '0',
      tasaIva: l.tasa_iva ?? p.tasa_iva,
    });
    return {
      ...calculo,
      uuid: l.uuid ?? nuevoUuid(),
      movimiento_uuid: l.movimiento_uuid ?? null,
      linea: i + 1,
      productoId: p.id,
      productoUuid: p.uuid,
      // Snapshots: si mañana cambia el producto, este ticket no debe mutar.
      descripcion: l.descripcion ?? p.nombre,
      sku: p.sku,
      costoUnitario: l.costo_unitario ?? p.precio_compra,
    };
  });

  const totales = totalizarVenta(lineas);
  const costoTotal = sumar(
    lineas.map((l) => multiplicarPorCantidad(toCents(l.costoUnitario), toQty(l.cantidad))),
  );

  // 2) Cobro en efectivo: vueltas.
  const total = totales._centavos.total;
  let montoRecibido = null;
  let cambio = null;
  if (datos.monto_recibido !== undefined && datos.monto_recibido !== null) {
    const recibido = toCents(datos.monto_recibido);
    if (datos.metodo_pago === 'EFECTIVO' && recibido < total) {
      throw badRequest(
        'PAGO_INSUFICIENTE',
        `El monto recibido (${fromCents(recibido)}) es menor que el total (${fromCents(total)})`,
      );
    }
    montoRecibido = fromCents(recibido);
    cambio = fromCents(recibido > total ? recibido - total : 0n);
  }

  const fecha = datos.fecha ? new Date(datos.fecha) : new Date();
  if (Number.isNaN(fecha.getTime())) throw badRequest('FECHA_INVALIDA', 'La fecha de la venta no es válida');
  const fechaLocal = datos.fecha_local ?? diaHabil(fecha);

  // 3) Cabecera, con reintento de folio ante colisión.
  const prefijo = await prefijoDelDispositivo(conn, ctx?.dispositivoUuid);
  let ventaId = null;
  let numero = datos.numero ?? null;

  for (let intento = 0; intento < 5; intento += 1) {
    const folio = numero ?? (await siguienteFolio(conn, prefijo));
    try {
      const r = await txExecute(
        conn,
        `INSERT INTO ventas
           (uuid, numero, usuario_id, dispositivo_uuid, cliente_nombre, cliente_documento,
            subtotal, descuento_total, impuesto_total, total, costo_total,
            metodo_pago, monto_recibido, cambio, estado, notas,
            fecha, fecha_local, creada_offline, sincronizada_en)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'COMPLETADA',?,?,?,?, UTC_TIMESTAMP(3))`,
        [
          uuid,
          folio,
          ctx?.usuarioId ?? null,
          ctx?.dispositivoUuid ?? null,
          datos.cliente_nombre ?? null,
          datos.cliente_documento ?? null,
          totales.subtotal,
          totales.descuento_total,
          totales.impuesto_total,
          totales.total,
          fromCents(costoTotal),
          datos.metodo_pago ?? 'EFECTIVO',
          montoRecibido,
          cambio,
          datos.notas ?? null,
          fecha,
          fechaLocal,
          datos.creada_offline ? 1 : 0,
        ],
      );
      ventaId = r.insertId;
      numero = folio;
      break;
    } catch (err) {
      const chocaFolio = err.code === 'ER_DUP_ENTRY' && err.sqlMessage?.includes('uk_ventas_numero');
      if (!chocaFolio) throw err;
      if (datos.numero) {
        // El folio venía del dispositivo y ya está tomado: dos dispositivos con
        // el mismo prefijo. Se conserva la venta con un folio derivado en lugar
        // de perderla, y se avisa.
        numero = `${datos.numero}+${nuevoUuid().slice(0, 4)}`;
      } else {
        numero = null; // recalcular con fn_siguiente_folio
      }
      if (intento === 4) throw conflict('FOLIO_AGOTADO', 'No se pudo asignar un número de venta único');
    }
  }

  // 4) Detalle.
  for (const l of lineas) {
    await txExecute(
      conn,
      `INSERT INTO venta_detalles
         (uuid, venta_id, producto_id, linea, descripcion, sku_snapshot, cantidad,
          precio_unitario, costo_unitario, descuento, tasa_iva, base_gravable, impuesto, total)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [
        l.uuid, ventaId, l.productoId, l.linea, l.descripcion, l.sku, l.cantidad,
        l.precio_unitario, l.costoUnitario, l.descuento, l.tasa_iva,
        l.base_gravable, l.impuesto, l.total,
      ],
    );
  }

  // 4.b) Desglose del cobro.
  //
  // Siempre se escribe al menos una fila, incluso con un solo medio: así los
  // reportes por medio de pago miran en un único sitio y no tienen que tratar
  // aparte el caso simple.
  await registrarPagos(conn, {
    ventaId,
    total,
    numero,
    pagos: datos.pagos,
    metodoLegado: datos.metodo_pago ?? 'EFECTIVO',
    montoRecibido,
    cambio,
  });

  // 5) Movimientos de inventario. Los triggers descuentan el stock.
  //    Se reutiliza el uuid que mandó el dispositivo: si el servidor inventara
  //    uno nuevo, el pull lo bajaría como fila distinta y el kardex local
  //    mostraría la venta dos veces.
  for (const l of lineas) {
    await insertarMovimiento(
      conn,
      productos.get(l.productoUuid),
      {
        uuid: l.movimiento_uuid,
        tipo: 'VENTA',
        cantidad: l.cantidad,
        precio_unitario: l.precio_unitario,
        costo_unitario: l.costoUnitario,
        venta_id: ventaId,
        motivo: `Venta ${numero}`,
        fecha,
        fecha_local: fechaLocal,
        creado_offline: datos.creada_offline,
      },
      ctx,
    );
  }

  // 6) Sobreventa: se acepta y se avisa. No se puede "des-vender" mercancía ya
  //    entregada, así que rechazarla descuadraría la caja.
  if (datos.creada_offline) {
    const negativos = [...productos.values()].filter((p) => toQty(p.stock_actual) < 0n);
    if (negativos.length) {
      await registrarAlerta(conn, {
        tipo: 'SOBREVENTA',
        severidad: 'CRITICA',
        productoId: negativos[0].id,
        ventaId,
        mensaje: `La venta offline ${numero} dejó ${negativos.length} producto(s) en negativo`,
        detalle: negativos.map((p) => ({ uuid: p.uuid, nombre: p.nombre, stock: p.stock_actual })),
      });
    }
  }

  return obtenerVentaTx(conn, uuid);
}

// ── Anulación ───────────────────────────────────────────────────────────────

/**
 * Anula una venta emitiendo un DOCUMENTO DE REVERSA.
 *
 * La venta original no se borra ni se edita en su contenido: sólo cambia de
 * estado. La reversa es una segunda venta con importes y cantidades negativas
 * que referencia a la original, y unos movimientos ANULACION_VENTA que
 * devuelven el stock. Así el rastro contable queda completo y los reportes
 * (que filtran estado='COMPLETADA') excluyen ambas.
 */
export async function anularVenta(conn, datos, ctx) {
  const original = await txQueryOne(
    conn,
    'SELECT id, uuid, numero, estado, fecha_local FROM ventas WHERE uuid = ? FOR UPDATE',
    [datos.venta_uuid],
  );
  if (!original) throw notFound('Venta');

  if (original.estado === 'ANULADA') {
    const reversa = await txQueryOne(conn, 'SELECT uuid FROM ventas WHERE anula_a_venta_id = ?', [original.id]);
    return { anulada: true, duplicada: true, venta_uuid: original.uuid, reversa_uuid: reversa?.uuid ?? null };
  }

  const detalles = await txQuery(
    conn,
    `SELECT d.*, p.uuid AS producto_uuid
       FROM venta_detalles d
       LEFT JOIN productos p ON p.id = d.producto_id
      WHERE d.venta_id = ? ORDER BY d.linea`,
    [original.id],
  );
  if (!detalles.length) throw badRequest('VENTA_SIN_DETALLE', 'La venta no tiene líneas que revertir');

  const conProducto = detalles.filter((d) => d.producto_uuid);
  const productos = await bloquearProductos(conn, conProducto.map((d) => d.producto_uuid));

  const fecha = datos.fecha ? new Date(datos.fecha) : new Date();
  const fechaLocal = datos.fecha_local ?? diaHabil(fecha);
  const uuidReversa = datos.uuid_reversa ?? nuevoUuid();

  const neg = (v) => fromCents(-toCents(v));
  const totalesOriginal = await txQueryOne(
    conn,
    'SELECT subtotal, descuento_total, impuesto_total, total, costo_total, metodo_pago FROM ventas WHERE id = ?',
    [original.id],
  );

  const r = await txExecute(
    conn,
    `INSERT INTO ventas
       (uuid, numero, usuario_id, dispositivo_uuid, subtotal, descuento_total, impuesto_total,
        total, costo_total, metodo_pago, estado, anula_a_venta_id, motivo_anulacion,
        fecha, fecha_local, creada_offline, sincronizada_en)
     VALUES (?,?,?,?,?,?,?,?,?,?, 'ANULADA', ?,?,?,?,?, UTC_TIMESTAMP(3))`,
    [
      uuidReversa,
      `${original.numero}-R`,
      ctx?.usuarioId ?? null,
      ctx?.dispositivoUuid ?? null,
      neg(totalesOriginal.subtotal),
      neg(totalesOriginal.descuento_total),
      neg(totalesOriginal.impuesto_total),
      neg(totalesOriginal.total),
      neg(totalesOriginal.costo_total),
      totalesOriginal.metodo_pago,
      original.id,
      datos.motivo ?? 'Anulación',
      fecha,
      fechaLocal,
      datos.creada_offline ? 1 : 0,
    ],
  );
  const reversaId = r.insertId;

  for (const d of detalles) {
    await txExecute(
      conn,
      `INSERT INTO venta_detalles
         (uuid, venta_id, producto_id, linea, descripcion, sku_snapshot, cantidad,
          precio_unitario, costo_unitario, descuento, tasa_iva, base_gravable, impuesto, total)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
      [
        nuevoUuid(), reversaId, d.producto_id, d.linea, d.descripcion, d.sku_snapshot,
        fromQty(-toQty(d.cantidad)), d.precio_unitario, d.costo_unitario,
        neg(d.descuento), d.tasa_iva, neg(d.base_gravable), neg(d.impuesto), neg(d.total),
      ],
    );
  }

  // Devolución del stock.
  const movimientosCliente = new Map(
    (datos.movimientos ?? []).map((m) => [m.producto_uuid, m.movimiento_uuid]),
  );
  for (const d of conProducto) {
    await insertarMovimiento(
      conn,
      productos.get(d.producto_uuid),
      {
        uuid: movimientosCliente.get(d.producto_uuid) ?? undefined,
        tipo: 'ANULACION_VENTA',
        cantidad: d.cantidad, // el signo lo impone el tipo (+)
        venta_id: reversaId,
        motivo: `Anulación de ${original.numero}: ${datos.motivo ?? 'sin motivo'}`,
        fecha,
        fecha_local: fechaLocal,
        creado_offline: datos.creada_offline,
      },
      ctx,
    );
  }

  await txExecute(
    conn,
    "UPDATE ventas SET estado = 'ANULADA', motivo_anulacion = ? WHERE id = ?",
    [datos.motivo ?? 'Anulación', original.id],
  );

  return {
    anulada: true,
    venta_uuid: original.uuid,
    venta_numero: original.numero,
    reversa_uuid: uuidReversa,
    reversa_numero: `${original.numero}-R`,
  };
}

// ── Lecturas ────────────────────────────────────────────────────────────────

export async function listarVentas(filtros) {
  const where = ['v.deleted_at IS NULL'];
  const params = [];

  if (filtros.estado && filtros.estado !== 'todas') {
    where.push('v.estado = ?');
    params.push(filtros.estado);
  } else if (!filtros.incluir_reversas) {
    where.push('v.anula_a_venta_id IS NULL');
  }
  if (filtros.desde) {
    where.push('v.fecha_local >= ?');
    params.push(filtros.desde);
  }
  if (filtros.hasta) {
    where.push('v.fecha_local <= ?');
    params.push(filtros.hasta);
  }
  if (filtros.usuario) {
    where.push('u.uuid = ?');
    params.push(filtros.usuario);
  }
  if (filtros.buscar) {
    where.push('(v.numero LIKE ? OR v.cliente_nombre LIKE ?)');
    params.push(`%${filtros.buscar}%`, `%${filtros.buscar}%`);
  }

  const sqlWhere = `WHERE ${where.join(' AND ')}`;
  const offset = (filtros.pagina - 1) * filtros.limite;

  const [items, [conteo]] = await Promise.all([
    query(
      `SELECT ${SELECT_VENTA},
              (SELECT COUNT(*) FROM venta_detalles d WHERE d.venta_id = v.id) AS num_lineas
         FROM ventas v
         LEFT JOIN usuarios u ON u.id = v.usuario_id
         LEFT JOIN ventas vo ON vo.id = v.anula_a_venta_id
         ${sqlWhere}
        ORDER BY v.fecha DESC, v.id DESC
        LIMIT ? OFFSET ?`,
      [...params, filtros.limite, offset],
    ),
    query(
      `SELECT COUNT(*) total FROM ventas v LEFT JOIN usuarios u ON u.id = v.usuario_id ${sqlWhere}`,
      params,
    ),
  ]);

  return { items, total: Number(conteo.total) };
}

export async function obtenerVenta(uuid) {
  const venta = await queryOne(
    `SELECT ${SELECT_VENTA}, v.id AS _id
       FROM ventas v
       LEFT JOIN usuarios u ON u.id = v.usuario_id
       LEFT JOIN ventas vo ON vo.id = v.anula_a_venta_id
      WHERE v.uuid = ? AND v.deleted_at IS NULL`,
    [uuid],
  );
  if (!venta) throw notFound('Venta');
  const detalles = await query(
    `SELECT ${SELECT_DETALLE} FROM venta_detalles d
       LEFT JOIN productos p ON p.id = d.producto_id
      WHERE d.venta_id = ? ORDER BY d.linea`,
    [venta._id],
  );
  delete venta._id;
  return { ...venta, detalles };
}

async function obtenerVentaTx(conn, uuid) {
  const venta = await txQueryOne(
    conn,
    `SELECT ${SELECT_VENTA}, v.id AS _id
       FROM ventas v
       LEFT JOIN usuarios u ON u.id = v.usuario_id
       LEFT JOIN ventas vo ON vo.id = v.anula_a_venta_id
      WHERE v.uuid = ?`,
    [uuid],
  );
  if (!venta) throw notFound('Venta');
  const detalles = await txQuery(
    conn,
    `SELECT ${SELECT_DETALLE} FROM venta_detalles d
       LEFT JOIN productos p ON p.id = d.producto_id
      WHERE d.venta_id = ? ORDER BY d.linea`,
    [venta._id],
  );
  // Con qué medios se cobró. Es la trazabilidad que permite responder «esta
  // venta, ¿entró por Nequi o en efectivo?» un mes después.
  const pagos = await txQuery(
    conn,
    `SELECT vp.uuid, mp.uuid AS metodo_pago_uuid, vp.metodo_nombre, vp.metodo_tipo,
            vp.monto, vp.monto_recibido, vp.cambio, vp.referencia
       FROM venta_pagos vp
       LEFT JOIN metodos_pago mp ON mp.id = vp.metodo_pago_id
      WHERE vp.venta_id = ? ORDER BY vp.id`,
    [venta._id],
  );
  delete venta._id;
  return { ...venta, detalles, pagos };
}
