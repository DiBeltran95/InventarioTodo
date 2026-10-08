import { pool, query } from '../../db/pool.js';
import { rangoPeriodo, diaHabil, sumarDias } from '../../utils/dates.js';
import { filtroSede } from '../../domain/alcance.js';

/**
 * Todos los agregados agrupan por `fecha_local` (el día hábil de la tienda), no
 * por la fecha UTC de la fila. El servidor corre en UTC y la tienda en
 * America/Bogota: agrupar por UTC partiría el día a las 7:00 p. m. y las ventas
 * de la noche se contarían en el día siguiente.
 *
 * `ONLY_FULL_GROUP_BY` está activo, así que cada columna no agregada aparece
 * explícitamente en el GROUP BY.
 *
 * ── Sedes ────────────────────────────────────────────────────────────────────
 * Cada función recibe `ambito`: { alcance, sedeId }. Sin `sedeId` abarca todas
 * las sedes del alcance (el director, el negocio entero; el gerente, las suyas);
 * con `sedeId`, sólo esa —la ruta ya comprobó que está en el alcance—.
 */

/** Fragmento SQL + parámetros que restringen `columna` al ámbito. */
export function filtroAmbito(columna, ambito) {
  if (ambito?.sedeId) return { sql: `${columna} = ?`, params: [ambito.sedeId] };
  if (ambito?.alcance) return filtroSede(columna, ambito.alcance);
  return { sql: '1 = 1', params: [] };
}

const EXPR_AGRUPACION = {
  dia: 'v.fecha_local',
  semana: "DATE_FORMAT(v.fecha_local, '%x-W%v')",
  mes: "DATE_FORMAT(v.fecha_local, '%Y-%m')",
};

export async function ventasPorPeriodo({ desde, hasta, agrupar = 'dia' }, ambito) {
  const expr = EXPR_AGRUPACION[agrupar] ?? EXPR_AGRUPACION.dia;
  const f = filtroAmbito('v.sede_id', ambito);
  return query(
    `SELECT ${expr} AS periodo,
            COUNT(*)                     AS num_ventas,
            SUM(v.total)                 AS total,
            SUM(v.subtotal)              AS base,
            SUM(v.impuesto_total)        AS impuesto,
            SUM(v.descuento_total)       AS descuento,
            SUM(v.costo_total)           AS costo,
            SUM(v.total - v.costo_total) AS margen,
            ROUND(AVG(v.total), 2)       AS ticket_promedio,
            MIN(v.fecha_local)           AS primer_dia,
            MAX(v.fecha_local)           AS ultimo_dia
       FROM ventas v
      WHERE v.estado = 'COMPLETADA' AND v.deleted_at IS NULL
        AND v.fecha_local BETWEEN ? AND ? AND ${f.sql}
      GROUP BY ${expr}
      ORDER BY periodo ASC`,
    [desde, hasta, ...f.params],
  );
}

/**
 * Ventas por sede: lo primero que mira el Director General.
 * Incluye las sedes sin ventas en el periodo (LEFT JOIN): una sede en cero es
 * justo lo que hay que ver.
 */
export async function ventasPorSede({ desde, hasta }, ambito) {
  const f = filtroAmbito('s.id', ambito);
  return query(
    `SELECT s.uuid, s.nombre, s.codigo,
            COUNT(v.id)                                AS num_ventas,
            COALESCE(SUM(v.total), 0)                  AS total,
            COALESCE(SUM(v.total - v.costo_total), 0)  AS margen,
            COALESCE(ROUND(AVG(v.total), 2), 0)        AS ticket_promedio
       FROM sedes s
       LEFT JOIN ventas v
              ON v.sede_id = s.id
             AND v.estado = 'COMPLETADA'
             AND v.deleted_at IS NULL
             AND v.fecha_local BETWEEN ? AND ?
      WHERE s.deleted_at IS NULL AND ${f.sql}
      GROUP BY s.id, s.uuid, s.nombre, s.codigo
      ORDER BY total DESC, s.nombre`,
    [desde, hasta, ...f.params],
  );
}

export async function topProductos({ desde, hasta, limite = 10, por = 'unidades' }, ambito) {
  const orden = por === 'ingreso' ? 'ingreso DESC' : por === 'margen' ? 'margen DESC' : 'unidades DESC';
  const f = filtroAmbito('v.sede_id', ambito);
  return query(
    `SELECT p.uuid, p.sku, MAX(d.descripcion) AS nombre,
            SUM(d.cantidad)                                  AS unidades,
            SUM(d.total)                                     AS ingreso,
            SUM(d.costo_unitario * d.cantidad)               AS costo,
            SUM(d.total - (d.costo_unitario * d.cantidad))   AS margen,
            COUNT(DISTINCT d.venta_id)                       AS num_ventas
       FROM venta_detalles d
       JOIN ventas v    ON v.id = d.venta_id
       JOIN productos p ON p.id = d.producto_id
      WHERE v.estado = 'COMPLETADA' AND v.deleted_at IS NULL
        AND v.fecha_local BETWEEN ? AND ? AND ${f.sql}
      GROUP BY p.uuid, p.sku
      ORDER BY ${orden}
      LIMIT ?`,
    [desde, hasta, ...f.params, limite],
  );
}

/**
 * Ventas por empleado. Es la vista de control cuando hay varias cajas.
 *
 * Se incluyen los empleados SIN ventas (LEFT JOIN) a propósito: un vendedor que
 * estuvo en turno y no registró nada es justo lo que hay que ver.
 *
 * `anuladas` no es decorativo: anular una venta ya cobrada y quedarse el
 * efectivo es el fraude clásico en caja.
 */
export async function ventasPorEmpleado({ desde, hasta }, ambito) {
  const fv = filtroAmbito('v.sede_id', ambito);
  const fa = filtroAmbito('a.sede_id', ambito);
  const fu = filtroAmbito('us.sede_id', ambito);
  return query(
    `SELECT u.uuid, u.nombre, u.email, u.rol, u.activo, u.ultimo_acceso,
            COUNT(v.id)                                  AS num_ventas,
            COALESCE(SUM(v.total), 0)                    AS total,
            COALESCE(ROUND(AVG(v.total), 2), 0)          AS ticket_promedio,
            COALESCE(SUM(v.total - v.costo_total), 0)    AS margen,
            COALESCE(SUM(v.creada_offline), 0)           AS creadas_offline,
            MAX(v.fecha)                                 AS ultima_venta,
            (SELECT COUNT(*) FROM ventas a
              WHERE a.usuario_id = u.id
                AND a.estado = 'ANULADA'
                AND a.anula_a_venta_id IS NULL
                AND a.deleted_at IS NULL
                AND a.fecha_local BETWEEN ? AND ? AND ${fa.sql}) AS anuladas
       FROM usuarios u
       LEFT JOIN ventas v
              ON v.usuario_id = u.id
             AND v.estado = 'COMPLETADA'
             AND v.deleted_at IS NULL
             AND v.anula_a_venta_id IS NULL
             AND v.fecha_local BETWEEN ? AND ?
             AND ${fv.sql}
      WHERE u.deleted_at IS NULL
        AND (u.rol = 'ADMIN' OR EXISTS (SELECT 1 FROM usuario_sedes us
                                         WHERE us.usuario_id = u.id AND ${fu.sql}))
      GROUP BY u.id, u.uuid, u.nombre, u.email, u.rol, u.activo, u.ultimo_acceso
      ORDER BY total DESC, u.nombre ASC`,
    [desde, hasta, ...fa.params, desde, hasta, ...fv.params, ...fu.params],
  );
}

/**
 * Cuánto entró por cada medio de pago.
 *
 * Sale de `venta_pagos` y no de `ventas.metodo_pago`: en un cobro mixto esa
 * columna sólo dice 'MIXTO'. Las anuladas quedan fuera: ese dinero se devolvió.
 */
export async function ingresosPorMetodoPago({ desde, hasta }, ambito) {
  const f = filtroAmbito('v.sede_id', ambito);
  return query(
    `SELECT vp.metodo_nombre                         AS metodo,
            vp.metodo_tipo                           AS tipo,
            mp.uuid                                  AS metodo_pago_uuid,
            mp.color                                 AS color,
            COUNT(*)                                 AS num_pagos,
            COUNT(DISTINCT vp.venta_id)              AS num_ventas,
            COALESCE(SUM(vp.monto), 0)               AS total
       FROM venta_pagos vp
       JOIN ventas v ON v.id = vp.venta_id
       LEFT JOIN metodos_pago mp ON mp.id = vp.metodo_pago_id
      WHERE v.estado = 'COMPLETADA'
        AND v.deleted_at IS NULL
        AND v.anula_a_venta_id IS NULL
        AND v.fecha_local BETWEEN ? AND ? AND ${f.sql}
      GROUP BY vp.metodo_nombre, vp.metodo_tipo, mp.uuid, mp.color
      ORDER BY total DESC`,
    [desde, hasta, ...f.params],
  );
}

/** Productos en o bajo su mínimo, por sede (el mínimo propio de la sede o el general). */
export async function stockBajo({ limite = 50 } = {}, ambito) {
  const f = filtroAmbito('sede_id', ambito);
  return query(
    `SELECT * FROM v_stock_bajo_sedes WHERE ${f.sql} ORDER BY (stock_actual - stock_minimo) ASC LIMIT ?`,
    [...f.params, limite],
  );
}

/** Valor del inventario: total, por categoría y por sede. */
export async function valorizacion(ambito) {
  const f = filtroAmbito('ss.sede_id', ambito);
  const [[resumen]] = await pool.query(
    `SELECT COUNT(DISTINCT p.id)                                   AS productos,
            SUM(ss.stock_actual)                                   AS unidades,
            ROUND(SUM(ss.stock_actual * p.precio_compra), 2)       AS valor_costo,
            ROUND(SUM(ss.stock_actual * p.precio_venta), 2)        AS valor_venta,
            ROUND(SUM(ss.stock_actual * (p.precio_venta - p.precio_compra)), 2) AS margen_potencial
       FROM stock_sedes ss
       JOIN productos p ON p.id = ss.producto_id
      WHERE p.deleted_at IS NULL AND p.activo = 1 AND ${f.sql}`,
    f.params,
  );
  const porCategoria = await query(
    `SELECT COALESCE(c.nombre, 'Sin categoría') AS categoria, c.uuid AS categoria_uuid,
            COUNT(DISTINCT p.id)                              AS productos,
            SUM(ss.stock_actual)                              AS unidades,
            ROUND(SUM(ss.stock_actual * p.precio_compra), 2)  AS valor_costo,
            ROUND(SUM(ss.stock_actual * p.precio_venta), 2)   AS valor_venta
       FROM stock_sedes ss
       JOIN productos p ON p.id = ss.producto_id
       LEFT JOIN categorias c ON c.id = p.categoria_id
      WHERE p.deleted_at IS NULL AND p.activo = 1 AND ${f.sql}
      GROUP BY c.uuid, c.nombre
      ORDER BY valor_costo DESC`,
    f.params,
  );
  const porSede = await query(
    `SELECT s.uuid, s.nombre,
            SUM(ss.stock_actual)                              AS unidades,
            ROUND(SUM(ss.stock_actual * p.precio_compra), 2)  AS valor_costo,
            ROUND(SUM(ss.stock_actual * p.precio_venta), 2)   AS valor_venta
       FROM stock_sedes ss
       JOIN productos p ON p.id = ss.producto_id
       JOIN sedes s ON s.id = ss.sede_id
      WHERE p.deleted_at IS NULL AND p.activo = 1 AND s.deleted_at IS NULL AND ${f.sql}
      GROUP BY s.id, s.uuid, s.nombre
      ORDER BY valor_costo DESC`,
    f.params,
  );
  return { resumen, por_categoria: porCategoria, por_sede: porSede };
}

export async function movimientosResumen({ desde, hasta }, ambito) {
  const f = filtroAmbito('m.sede_id', ambito);
  return query(
    `SELECT m.tipo,
            COUNT(*)                                       AS num_movimientos,
            SUM(m.cantidad)                                AS cantidad_neta,
            SUM(ABS(m.cantidad))                           AS cantidad_absoluta,
            SUM(ABS(m.cantidad) * COALESCE(m.costo_unitario, 0)) AS valor
       FROM movimientos_inventario m
      WHERE m.fecha_local BETWEEN ? AND ? AND ${f.sql}
      GROUP BY m.tipo
      ORDER BY num_movimientos DESC`,
    [desde, hasta, ...f.params],
  );
}

/**
 * Resumen para la pantalla principal.
 *
 * Una sola ida a la base con varias subconsultas en lugar de una petición por
 * cifra: el dashboard es lo primero que se pinta y la latencia se nota.
 */
export async function dashboard(ambito) {
  const hoy = diaHabil();
  const ayer = sumarDias(hoy, -1);
  const semana = rangoPeriodo('semana');
  const mes = rangoPeriodo('mes');
  const fv = filtroAmbito('sede_id', ambito);
  const fs = filtroAmbito('ss.sede_id', ambito);
  const fa = filtroAmbito('sede_id', ambito);

  const ventasEn = (cond) =>
    `FROM ventas WHERE estado='COMPLETADA' AND deleted_at IS NULL AND ${cond} AND ${fv.sql}`;

  const [[fila]] = await pool.query(
    `SELECT
       (SELECT COALESCE(SUM(total),0) ${ventasEn('fecha_local = ?')})               AS ventas_hoy,
       (SELECT COUNT(*) ${ventasEn('fecha_local = ?')})                             AS num_ventas_hoy,
       (SELECT COALESCE(SUM(total),0) ${ventasEn('fecha_local = ?')})               AS ventas_ayer,
       (SELECT COALESCE(SUM(total),0) ${ventasEn('fecha_local BETWEEN ? AND ?')})   AS ventas_semana,
       (SELECT COALESCE(SUM(total),0) ${ventasEn('fecha_local BETWEEN ? AND ?')})   AS ventas_mes,
       (SELECT COALESCE(SUM(total - costo_total),0) ${ventasEn('fecha_local BETWEEN ? AND ?')}) AS margen_mes,
       (SELECT COUNT(*) FROM productos WHERE deleted_at IS NULL AND activo = 1)     AS productos_activos,
       (SELECT COUNT(*) FROM v_stock_bajo_sedes WHERE ${fv.sql})                    AS productos_stock_bajo,
       (SELECT COUNT(*) FROM stock_sedes ss JOIN productos p ON p.id = ss.producto_id
         WHERE p.deleted_at IS NULL AND p.activo = 1 AND ss.stock_actual <= 0 AND ${fs.sql}) AS productos_agotados,
       (SELECT COALESCE(SUM(ss.stock_actual * p.precio_compra),0)
          FROM stock_sedes ss JOIN productos p ON p.id = ss.producto_id
         WHERE p.deleted_at IS NULL AND p.activo = 1 AND ${fs.sql})                 AS valor_inventario,
       (SELECT COUNT(*) FROM alertas WHERE resuelta_en IS NULL AND ${fa.sql})       AS alertas_abiertas,
       (SELECT COUNT(*) FROM traslados WHERE estado = 'PENDIENTE' AND ${filtroAmbito('sede_origen_id', ambito).sql}) AS traslados_pendientes`,
    [
      hoy, ...fv.params,
      hoy, ...fv.params,
      ayer, ...fv.params,
      semana.desde, semana.hasta, ...fv.params,
      mes.desde, mes.hasta, ...fv.params,
      mes.desde, mes.hasta, ...fv.params,
      ...fv.params,
      ...fs.params,
      ...fs.params,
      ...fa.params,
      ...filtroAmbito('sede_origen_id', ambito).params,
    ],
  );

  const [serie, top, bajos, porSede] = await Promise.all([
    ventasPorPeriodo({ desde: sumarDias(hoy, -13), hasta: hoy, agrupar: 'dia' }, ambito),
    topProductos({ desde: mes.desde, hasta: mes.hasta, limite: 5 }, ambito),
    stockBajo({ limite: 10 }, ambito),
    ventasPorSede({ desde: hoy, hasta: hoy }, ambito),
  ]);

  return {
    fecha: hoy,
    resumen: fila,
    serie_14_dias: serie,
    top_productos_mes: top,
    stock_bajo: bajos,
    ventas_hoy_por_sede: porSede,
  };
}
