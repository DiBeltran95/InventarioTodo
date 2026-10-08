/**
 * Consultas de bajada delta, una por entidad.
 *
 * Todas comparten la misma forma de paginación: cursor KEYSET sobre
 * `(updated_at, id)`.
 *
 *   WHERE updated_at > :t OR (updated_at = :t AND id > :i)
 *   ORDER BY updated_at, id
 *
 * Por qué keyset y no `WHERE updated_at > :t` a secas: varias filas pueden
 * compartir el mismo milisegundo. Con un cursor de sólo tiempo, al paginar se
 * saltan filas (si usas `>`) o se repiten para siempre (si usas `>=`). El par
 * (updated_at, id) es un orden total. Por lo mismo no se usa OFFSET: con datos
 * que cambian entre páginas, OFFSET pierde y duplica filas.
 *
 * Todas las claves foráneas se exponen como UUID, nunca como id interno: el
 * cliente no conoce —ni debe conocer— los AUTO_INCREMENT del servidor.
 *
 * Los borrados viajan como filas con `deleted_at` no nulo. Por eso el borrado
 * lógico es obligatorio: un DELETE físico no dejaría nada que sincronizar y el
 * dispositivo desconectado nunca se enteraría.
 *
 * ── Alcance ──────────────────────────────────────────────────────────────────
 * Lo que pertenece a una sede (ventas, movimientos, traslados, cierres,
 * alertas) sólo baja a quien la ve: el vendedor, su sede; el gerente, las
 * suyas; el director, todas. El catálogo es común y baja entero.
 *
 * La EXCEPCIÓN es stock_sedes: baja el de todas las sedes a todos. Cualquier
 * empleado tiene que poder decirle a un cliente «aquí no queda, pero en Norte
 * hay 3», también sin red. Es sólo cantidad por producto y sede: sin costos.
 *
 * Orden de los parámetros de cada consulta, que es el que arma `pull()`:
 *   [t, t, i] (keyset) · [horizonte] si `horizonte` · ...extra(ctx) · límite
 * Cada SQL escribe sus `?` en ese mismo orden.
 */

const KEYSET = (alias) =>
  `(${alias}.updated_at > ? OR (${alias}.updated_at = ? AND ${alias}.id > ?))`;

/** (? OR col IN (?)) — el primer ? vale 1 para el director. */
const SEDE = (columna) => `(? OR ${columna} IN (?))`;
const alcance = (ctx) => [ctx.alcance.esDirector ? 1 : 0, ctx.alcance.sedeIds.length ? ctx.alcance.sedeIds : [0]];
const esGestor = (ctx) => (['ADMIN', 'GERENTE'].includes(ctx.rol) ? 1 : 0);

export const CONSULTAS = {
  // Todas las sedes, también las inactivas: hacen falta para mostrar el nombre
  // de la sede de un traslado o de una venta antigua.
  sedes: {
    horizonte: false,
    sql: `
      SELECT s.id AS _id, s.uuid, s.nombre, s.codigo, s.direccion, s.telefono,
             s.es_principal, s.activo, s.updated_at, s.deleted_at
        FROM sedes s
       WHERE ${KEYSET('s')}
       ORDER BY s.updated_at, s.id LIMIT ?`,
  },

  // Los compañeros de sede (para el login sin red en un teléfono compartido y
  // para mostrar «vendido por»), y los directores. Con su horario: la app
  // también cierra la sesión al terminar el turno aunque no haya red.
  usuarios: {
    horizonte: false,
    extra: (ctx) => [ctx.alcance.esDirector ? 1 : 0, ctx.usuarioId, ...alcance(ctx).slice(1)],
    sql: `
      SELECT u.id AS _id, u.uuid, u.nombre, u.email, u.rol, u.activo,
             u.restringir_horario, u.horario, u.acceso_extra_hasta,
             (SELECT GROUP_CONCAT(s.uuid ORDER BY s.uuid)
                FROM usuario_sedes us2 JOIN sedes s ON s.id = us2.sede_id
               WHERE us2.usuario_id = u.id) AS sedes,
             u.updated_at, u.deleted_at
        FROM usuarios u
       WHERE ${KEYSET('u')}
         AND (? OR u.id = ? OR u.rol = 'ADMIN'
              OR EXISTS (SELECT 1 FROM usuario_sedes us
                          WHERE us.usuario_id = u.id AND us.sede_id IN (?)))
       ORDER BY u.updated_at, u.id LIMIT ?`,
  },

  categorias: {
    horizonte: false,
    sql: `
      SELECT c.id AS _id, c.uuid, c.nombre, c.descripcion, c.color, c.icono, c.orden,
             c.updated_at, c.deleted_at
        FROM categorias c
       WHERE ${KEYSET('c')}
       ORDER BY c.updated_at, c.id LIMIT ?`,
  },

  proveedores: {
    horizonte: false,
    sql: `
      SELECT pr.id AS _id, pr.uuid, pr.nombre, pr.nit, pr.contacto, pr.telefono,
             pr.email, pr.direccion, pr.notas, pr.updated_at, pr.deleted_at
        FROM proveedores pr
       WHERE ${KEYSET('pr')}
       ORDER BY pr.updated_at, pr.id LIMIT ?`,
  },

  // Todos, con su sede: la app filtra los de la sede activa. Filtrar aquí
  // dejaría en el teléfono un medio que se movió a otra sede, porque una fila
  // que deja de coincidir con el filtro ya no vuelve a bajar.
  metodos_pago: {
    horizonte: false,
    sql: `
      SELECT mp.id AS _id, mp.uuid, mp.nombre, mp.tipo, mp.requiere_referencia,
             mp.qr_url, mp.instrucciones, mp.color, mp.orden, mp.activo,
             s.uuid AS sede_uuid, mp.comision_pct, mp.dias_pago,
             mp.updated_at, mp.deleted_at
        FROM metodos_pago mp
        LEFT JOIN sedes s ON s.id = mp.sede_id
       WHERE ${KEYSET('mp')}
       ORDER BY mp.updated_at, mp.id LIMIT ?`,
  },

  // `stock_actual` es el TOTAL de todas las sedes. Lo sigue leyendo la app
  // vieja; la nueva toma el stock de `stock_sedes`.
  productos: {
    horizonte: false,
    sql: `
      SELECT p.id AS _id, p.uuid, p.sku, p.nombre, p.descripcion,
             c.uuid AS categoria_uuid, p.unidad_medida,
             p.precio_compra, p.precio_venta, p.tasa_iva,
             p.stock_actual, p.stock_minimo, p.stock_maximo,
             p.imagen_url, p.ubicacion, p.activo,
             p.updated_at, p.deleted_at
        FROM productos p
        LEFT JOIN categorias c ON c.id = p.categoria_id
       WHERE ${KEYSET('p')}
       ORDER BY p.updated_at, p.id LIMIT ?`,
  },

  producto_codigos: {
    horizonte: false,
    sql: `
      SELECT pc.id AS _id, pc.uuid, p.uuid AS producto_uuid, pc.codigo, pc.tipo,
             pc.es_principal, pc.factor, pc.updated_at, pc.deleted_at
        FROM producto_codigos pc
        JOIN productos p ON p.id = pc.producto_id
       WHERE ${KEYSET('pc')}
       ORDER BY pc.updated_at, pc.id LIMIT ?`,
  },

  stock_sedes: {
    horizonte: false,
    sql: `
      SELECT ss.id AS _id, p.uuid AS producto_uuid, s.uuid AS sede_uuid,
             ss.stock_actual, ss.stock_minimo, ss.updated_at
        FROM stock_sedes ss
        JOIN productos p ON p.id = ss.producto_id
        JOIN sedes s ON s.id = ss.sede_id
       WHERE ${KEYSET('ss')}
       ORDER BY ss.updated_at, ss.id LIMIT ?`,
  },

  ventas: {
    horizonte: true,
    extra: alcance,
    sql: `
      SELECT v.id AS _id, v.uuid, v.numero, u.uuid AS usuario_uuid, v.dispositivo_uuid,
             s.uuid AS sede_uuid, v.turno_uuid,
             v.cliente_nombre, v.cliente_documento,
             v.subtotal, v.descuento_total, v.impuesto_total, v.total, v.costo_total,
             v.metodo_pago, v.monto_recibido, v.cambio, v.estado,
             vo.uuid AS anula_a_venta_uuid, v.motivo_anulacion, v.notas,
             v.fecha, v.fecha_local, v.creada_offline,
             v.updated_at, v.deleted_at
        FROM ventas v
        LEFT JOIN usuarios u ON u.id = v.usuario_id
        LEFT JOIN ventas vo ON vo.id = v.anula_a_venta_id
        LEFT JOIN sedes s ON s.id = v.sede_id
       WHERE ${KEYSET('v')} AND v.fecha_local >= ? AND ${SEDE('v.sede_id')}
       ORDER BY v.updated_at, v.id LIMIT ?`,
  },

  venta_detalles: {
    horizonte: true,
    extra: alcance,
    sql: `
      SELECT d.id AS _id, d.uuid, v.uuid AS venta_uuid, p.uuid AS producto_uuid,
             d.linea, d.descripcion, d.sku_snapshot, d.cantidad,
             d.precio_unitario, d.costo_unitario, d.descuento, d.tasa_iva,
             d.base_gravable, d.impuesto, d.total, d.updated_at
        FROM venta_detalles d
        JOIN ventas v ON v.id = d.venta_id
        LEFT JOIN productos p ON p.id = d.producto_id
       WHERE ${KEYSET('d')} AND v.fecha_local >= ? AND ${SEDE('v.sede_id')}
       ORDER BY d.updated_at, d.id LIMIT ?`,
  },

  venta_pagos: {
    horizonte: true,
    extra: alcance,
    sql: `
      SELECT vp.id AS _id, vp.uuid, v.uuid AS venta_uuid,
             mp.uuid AS metodo_pago_uuid, vp.metodo_nombre, vp.metodo_tipo,
             vp.monto, vp.monto_recibido, vp.cambio, vp.referencia, vp.cobrado, vp.updated_at
        FROM venta_pagos vp
        JOIN ventas v ON v.id = vp.venta_id
        LEFT JOIN metodos_pago mp ON mp.id = vp.metodo_pago_id
       WHERE ${KEYSET('vp')} AND v.fecha_local >= ? AND ${SEDE('v.sede_id')}
       ORDER BY vp.updated_at, vp.id LIMIT ?`,
  },

  movimientos_inventario: {
    horizonte: true,
    extra: alcance,
    sql: `
      SELECT m.id AS _id, m.uuid, p.uuid AS producto_uuid, s.uuid AS sede_uuid, m.tipo, m.cantidad,
             m.costo_unitario, m.precio_unitario, m.stock_anterior, m.stock_resultante,
             v.uuid AS venta_uuid, t.uuid AS traslado_uuid, pr.uuid AS proveedor_uuid,
             u.uuid AS usuario_uuid, ap.uuid AS aprobado_por_uuid,
             m.dispositivo_uuid, m.lote, m.vence_el, m.documento_ref, m.motivo,
             m.fecha, m.fecha_local, m.creado_offline, m.updated_at
        FROM movimientos_inventario m
        JOIN productos p ON p.id = m.producto_id
        LEFT JOIN sedes s ON s.id = m.sede_id
        LEFT JOIN ventas v ON v.id = m.venta_id
        LEFT JOIN traslados t ON t.id = m.traslado_id
        LEFT JOIN proveedores pr ON pr.id = m.proveedor_id
        LEFT JOIN usuarios u ON u.id = m.usuario_id
        LEFT JOIN usuarios ap ON ap.id = m.aprobado_por
       WHERE ${KEYSET('m')} AND m.fecha_local >= ? AND ${SEDE('m.sede_id')}
       ORDER BY m.updated_at, m.id LIMIT ?`,
  },

  alertas: {
    horizonte: false,
    extra: alcance,
    sql: `
      SELECT a.id AS _id, a.uuid, a.tipo, a.severidad, p.uuid AS producto_uuid,
             s.uuid AS sede_uuid, v.uuid AS venta_uuid, a.mensaje, a.detalle,
             a.resuelta_en, a.updated_at
        FROM alertas a
        LEFT JOIN productos p ON p.id = a.producto_id
        LEFT JOIN sedes s ON s.id = a.sede_id
        LEFT JOIN ventas v ON v.id = a.venta_id
       WHERE ${KEYSET('a')} AND ${SEDE('a.sede_id')}
       ORDER BY a.updated_at, a.id LIMIT ?`,
  },

  // Un traslado lo ven las dos sedes: la que envía y la que recibe.
  traslados: {
    horizonte: false,
    extra: (ctx) => [...alcance(ctx), ...alcance(ctx)],
    sql: `
      SELECT t.id AS _id, t.uuid, t.numero, so.uuid AS sede_origen_uuid, sd.uuid AS sede_destino_uuid,
             t.estado, t.tipo, t.confirma, t.notas,
             us.uuid AS solicitado_por_uuid, t.solicitado_en,
             ur.uuid AS resuelto_por_uuid, t.resuelto_en, t.motivo_rechazo,
             t.updated_at, t.deleted_at
        FROM traslados t
        JOIN sedes so ON so.id = t.sede_origen_id
        JOIN sedes sd ON sd.id = t.sede_destino_id
        LEFT JOIN usuarios us ON us.id = t.solicitado_por
        LEFT JOIN usuarios ur ON ur.id = t.resuelto_por
       WHERE ${KEYSET('t')} AND (${SEDE('t.sede_origen_id')} OR ${SEDE('t.sede_destino_id')})
       ORDER BY t.updated_at, t.id LIMIT ?`,
  },

  traslado_detalles: {
    horizonte: false,
    extra: (ctx) => [...alcance(ctx), ...alcance(ctx)],
    sql: `
      SELECT d.id AS _id, d.uuid, t.uuid AS traslado_uuid, p.uuid AS producto_uuid,
             d.descripcion, d.cantidad, d.cantidad_enviada, d.updated_at
        FROM traslado_detalles d
        JOIN traslados t ON t.id = d.traslado_id
        LEFT JOIN productos p ON p.id = d.producto_id
       WHERE ${KEYSET('d')} AND (${SEDE('t.sede_origen_id')} OR ${SEDE('t.sede_destino_id')})
       ORDER BY d.updated_at, d.id LIMIT ?`,
  },

  traslado_eventos: {
    horizonte: false,
    extra: (ctx) => [...alcance(ctx), ...alcance(ctx)],
    sql: `
      SELECT e.id AS _id, e.uuid, t.uuid AS traslado_uuid, e.evento,
             u.uuid AS usuario_uuid, e.fecha, e.nota, e.updated_at
        FROM traslado_eventos e
        JOIN traslados t ON t.id = e.traslado_id
        LEFT JOIN usuarios u ON u.id = e.usuario_id
       WHERE ${KEYSET('e')} AND (${SEDE('t.sede_origen_id')} OR ${SEDE('t.sede_destino_id')})
       ORDER BY e.updated_at, e.id LIMIT ?`,
  },

  solicitudes_ajuste: {
    horizonte: false,
    extra: alcance,
    sql: `
      SELECT sa.id AS _id, sa.uuid, s.uuid AS sede_uuid, p.uuid AS producto_uuid,
             sa.tipo, sa.cantidad, sa.stock_contado, sa.motivo, sa.estado,
             us.uuid AS solicitado_por_uuid, sa.solicitado_en,
             ur.uuid AS resuelto_por_uuid, sa.resuelto_en, sa.motivo_rechazo,
             m.uuid AS movimiento_uuid, sa.updated_at
        FROM solicitudes_ajuste sa
        JOIN sedes s ON s.id = sa.sede_id
        JOIN productos p ON p.id = sa.producto_id
        LEFT JOIN usuarios us ON us.id = sa.solicitado_por
        LEFT JOIN usuarios ur ON ur.id = sa.resuelto_por
        LEFT JOIN movimientos_inventario m ON m.id = sa.movimiento_id
       WHERE ${KEYSET('sa')} AND ${SEDE('sa.sede_id')}
       ORDER BY sa.updated_at, sa.id LIMIT ?`,
  },

  // El vendedor ve sólo sus propios cierres; gerente y director, los de sus
  // sedes. Comparar cajas entre compañeros no le corresponde a un vendedor.
  cierres_caja: {
    horizonte: true,
    extra: (ctx) => [...alcance(ctx), esGestor(ctx), ctx.usuarioId],
    sql: `
      SELECT c.id AS _id, c.uuid, s.uuid AS sede_uuid, u.uuid AS usuario_uuid, c.dispositivo_uuid,
             c.estado, c.abierto_en, c.base_efectivo, c.cerrado_en, c.cierre_tardio,
             c.esperado_total, c.contado_total, c.diferencia_efectivo, c.detalle, c.notas,
             ur.uuid AS revisado_por_uuid, c.revisado_en, c.updated_at
        FROM cierres_caja c
        JOIN sedes s ON s.id = c.sede_id
        LEFT JOIN usuarios u ON u.id = c.usuario_id
        LEFT JOIN usuarios ur ON ur.id = c.revisado_por
       WHERE ${KEYSET('c')} AND DATE(c.abierto_en) >= ? AND ${SEDE('c.sede_id')}
         AND (? OR c.usuario_id = ?)
       ORDER BY c.updated_at, c.id LIMIT ?`,
  },

  // Sólo gestores. Un recaudo sin sede (abarca varias) sólo lo ve el director.
  recaudos: {
    horizonte: false,
    extra: (ctx) => [esGestor(ctx), ...alcance(ctx)],
    sql: `
      SELECT r.id AS _id, r.uuid, mp.uuid AS metodo_pago_uuid, s.uuid AS sede_uuid,
             r.fecha, r.monto, r.comision, r.referencia, r.notas, r.aplicaciones,
             u.uuid AS registrado_por_uuid, r.updated_at, r.deleted_at
        FROM recaudos r
        JOIN metodos_pago mp ON mp.id = r.metodo_pago_id
        LEFT JOIN sedes s ON s.id = r.sede_id
        LEFT JOIN usuarios u ON u.id = r.registrado_por
       WHERE ${KEYSET('r')} AND ? AND ${SEDE('r.sede_id')}
       ORDER BY r.updated_at, r.id LIMIT ?`,
  },
};

export const ENTIDADES = Object.keys(CONSULTAS);
