import { pool, query, queryOne } from '../../db/pool.js';
import { withTransaction, txQueryOne, txExecute } from '../../db/tx.js';
import { ApiError } from '../../utils/ApiError.js';
import { logger } from '../../utils/logger.js';
import { env } from '../../config/env.js';
import {
  ROLES,
  ROLES_GESTORES,
  ROLES_QUE_VENDEN,
  ROLES_QUE_REGISTRAN_ENTRADAS,
} from '../../config/constants.js';
import { CONSULTAS, ENTIDADES } from './pullQueries.js';
import { sumarDias, diaHabil } from '../../utils/dates.js';
import { veSede, huellaAlcance } from '../../domain/alcance.js';
import { ROLES_DE_TRASLADOS, ROLES_QUE_DESPACHAN } from '../../domain/traslados.js';
import { cargarAlcance, sedePorUuid, sedeDeDispositivo, sedePrincipal } from '../sedes/repo.js';

import * as productos from '../productos/service.js';
import * as inventario from '../inventario/service.js';
import * as ventas from '../ventas/service.js';
import * as traslados from '../traslados/service.js';
import * as ajustes from '../ajustes/service.js';
import * as cierres from '../cierres/service.js';
import * as recaudos from '../recaudos/service.js';
import { repoCategorias } from '../categorias/index.js';
import { repoProveedores } from '../proveedores/index.js';
import { guardarMetodo, actualizarMetodo, eliminarMetodo } from '../metodosPago/index.js';

/**
 * Manejadores de operaciones de subida.
 *
 * Cada uno recibe la conexión de una transacción abierta y debe dejar el
 * sistema en el estado final de la operación. Son EXACTAMENTE los mismos
 * servicios que usan las rutas REST: no hay una "vía de sincronización" con
 * reglas distintas que pueda divergir de la vía normal.
 */
const MANEJADORES = {
  PRODUCTO_CREAR: (conn, p, ctx) => productos.crearProducto(conn, p, ctx),
  PRODUCTO_ACTUALIZAR: (conn, p, ctx) => productos.actualizarProducto(conn, p.uuid, p, ctx),
  PRODUCTO_ELIMINAR: (conn, p, ctx) => productos.eliminarProducto(conn, p.uuid, ctx),
  CODIGO_CREAR: (conn, p, ctx) => productos.agregarCodigo(conn, p.producto_uuid, p, ctx),
  CODIGO_ELIMINAR: (conn, p, ctx) => productos.eliminarCodigo(conn, p.uuid, ctx),
  STOCK_MINIMO_FIJAR: (conn, p, ctx) => productos.fijarStockMinimo(conn, p, ctx),

  CATEGORIA_CREAR: (conn, p) => repoCategorias.crearOActualizar(conn, p),
  CATEGORIA_ACTUALIZAR: (conn, p) => repoCategorias.actualizar(conn, p.uuid, p),
  CATEGORIA_ELIMINAR: (conn, p) => repoCategorias.eliminar(conn, p.uuid),

  PROVEEDOR_CREAR: (conn, p) => repoProveedores.crearOActualizar(conn, p),
  PROVEEDOR_ACTUALIZAR: (conn, p) => repoProveedores.actualizar(conn, p.uuid, p),
  PROVEEDOR_ELIMINAR: (conn, p) => repoProveedores.eliminar(conn, p.uuid),

  METODO_PAGO_CREAR: (conn, p, ctx) => guardarMetodo(conn, p, ctx),
  METODO_PAGO_ACTUALIZAR: (conn, p, ctx) => actualizarMetodo(conn, p.uuid, p, ctx),
  METODO_PAGO_ELIMINAR: (conn, p, ctx) => eliminarMetodo(conn, p.uuid, ctx),

  MOVIMIENTO_CREAR: (conn, p, ctx) => inventario.crearMovimiento(conn, p, ctx),
  CONTEO_AJUSTAR: (conn, p, ctx) => inventario.ajustarPorConteo(conn, p, ctx),

  VENTA_CREAR: (conn, p, ctx) => ventas.crearVenta(conn, p, ctx),
  VENTA_ANULAR: (conn, p, ctx) => ventas.anularVenta(conn, p, ctx),

  TRASLADO_CREAR: (conn, p, ctx) => traslados.crearTraslado(conn, p, ctx),
  TRASLADO_APROBAR: (conn, p, ctx) => traslados.aprobarTraslado(conn, p, ctx),
  TRASLADO_RECHAZAR: (conn, p, ctx) => traslados.rechazarTraslado(conn, p, ctx),
  TRASLADO_CANCELAR: (conn, p, ctx) => traslados.cancelarTraslado(conn, p, ctx),

  AJUSTE_SOLICITAR: (conn, p, ctx) => ajustes.solicitarAjuste(conn, p, ctx),
  AJUSTE_APROBAR: (conn, p, ctx) => ajustes.aprobarAjuste(conn, p, ctx),
  AJUSTE_RECHAZAR: (conn, p, ctx) => ajustes.rechazarAjuste(conn, p, ctx),

  CIERRE_ABRIR: (conn, p, ctx) => cierres.abrirCaja(conn, p, ctx),
  CIERRE_CERRAR: (conn, p, ctx) => cierres.cerrarCaja(conn, p, ctx),
  CIERRE_REVISAR: (conn, p, ctx) => cierres.revisarCierre(conn, p, ctx),

  RECAUDO_CREAR: (conn, p, ctx) => recaudos.crearRecaudo(conn, p, ctx),
};

/**
 * Quién puede ejecutar cada operación. **Es la barrera antifraude del sistema.**
 *
 * Sin esto, `/sync/push` sería un túnel que sortea toda la autorización: la app
 * es offline-first y todo lo real viaja por aquí. Lo que además depende de la
 * sede o de quién pidió algo (aprobar un traslado, un ajuste) lo comprueba el
 * servicio con `ctx.alcance`.
 *
 * Reglas de negocio:
 *   · El catálogo y los precios: director y gerentes.
 *   · Entradas de mercancía: también el auxiliar de inventario.
 *   · Conteos, mermas y ajustes directos: sólo gestores. El auxiliar los
 *     SOLICITA (AJUSTE_SOLICITAR) y no cambian el stock hasta que un gerente
 *     los aprueba: son la vía con la que se tapa un faltante.
 *   · Vender: todos menos el auxiliar.
 *   · Anular una venta: gestores —es como se esconde el efectivo de una venta
 *     cobrada—.
 */
const PERMISOS = Object.freeze({
  PRODUCTO_CREAR: ROLES_GESTORES,
  PRODUCTO_ACTUALIZAR: ROLES_GESTORES,
  PRODUCTO_ELIMINAR: ROLES_GESTORES,
  CODIGO_CREAR: ROLES_GESTORES,
  CODIGO_ELIMINAR: ROLES_GESTORES,
  STOCK_MINIMO_FIJAR: ROLES_GESTORES,
  CATEGORIA_CREAR: ROLES_GESTORES,
  CATEGORIA_ACTUALIZAR: ROLES_GESTORES,
  CATEGORIA_ELIMINAR: ROLES_GESTORES,
  PROVEEDOR_CREAR: ROLES_GESTORES,
  PROVEEDOR_ACTUALIZAR: ROLES_GESTORES,
  PROVEEDOR_ELIMINAR: ROLES_GESTORES,
  METODO_PAGO_CREAR: ROLES_GESTORES,
  METODO_PAGO_ACTUALIZAR: ROLES_GESTORES,
  METODO_PAGO_ELIMINAR: ROLES_GESTORES,
  CONTEO_AJUSTAR: ROLES_GESTORES,
  VENTA_CREAR: ROLES_QUE_VENDEN,
  VENTA_ANULAR: ROLES_GESTORES,
  // Crear: el gerente solicita; el director o el auxiliar mueven directamente.
  // La regla fina (para qué sede, desde cuál) está en domain/traslados.js.
  TRASLADO_CREAR: ROLES_DE_TRASLADOS,
  TRASLADO_APROBAR: ROLES_QUE_DESPACHAN,
  TRASLADO_RECHAZAR: ROLES_QUE_DESPACHAN,
  TRASLADO_CANCELAR: ROLES_DE_TRASLADOS,
  AJUSTE_SOLICITAR: [ROLES.AUXILIAR_INVENTARIO],
  AJUSTE_APROBAR: ROLES_GESTORES,
  AJUSTE_RECHAZAR: ROLES_GESTORES,
  CIERRE_ABRIR: ROLES_QUE_VENDEN,
  CIERRE_CERRAR: ROLES_QUE_VENDEN,
  CIERRE_REVISAR: ROLES_GESTORES,
  RECAUDO_CREAR: ROLES_GESTORES,
});

const esEntrada = (op) =>
  op.tipo === 'MOVIMIENTO_CREAR' && ['ENTRADA', 'INICIAL'].includes(op.payload?.tipo);

/** Roles que pueden ejecutar `op`, o undefined si el tipo no tiene regla. */
export function rolesPermitidos(op) {
  // Un movimiento es una entrada (también el auxiliar) o una alteración del
  // stock (sólo gestores): el mismo tipo de operación, dos reglas.
  if (op.tipo === 'MOVIMIENTO_CREAR') return esEntrada(op) ? ROLES_QUE_REGISTRAN_ENTRADAS : ROLES_GESTORES;
  return PERMISOS[op.tipo];
}

/**
 * Operaciones que se pueden subir con la sesión de OTRA persona del mismo
 * teléfono, conservando a su autor.
 *
 * Caso real: el turno de Ana termina sin red, la app la saca, y entra Luis en
 * el mismo teléfono. La cola de Ana sube con la sesión de Luis, pero las ventas
 * son de Ana. Para registrar hechos —una venta cobrada, una caja que se abrió,
 * una entrada que llegó— basta con que Ana se haya autenticado alguna vez en
 * ese teléfono.
 *
 * Lo demás (anular, ajustar, aprobar, tocar el catálogo) espera a que su autor
 * vuelva a entrar: de lo contrario, cualquiera con acceso al teléfono podría
 * firmar en nombre de su gerente.
 */
const AUTOR_DIFERIDO = new Set([
  'VENTA_CREAR',
  'CIERRE_ABRIR',
  'CIERRE_CERRAR',
  'TRASLADO_CREAR',
  'AJUSTE_SOLICITAR',
]);
// Una solicitud de traslado registra un pedido; un movimiento directo mueve
// stock entre sedes y por eso espera a su autor, como cualquier otro cambio de
// inventario.
const esMovimientoDirecto = (op) => op.tipo === 'TRASLADO_CREAR' && op.payload?.directo === true;
const admiteAutorDiferido = (op) =>
  (AUTOR_DIFERIDO.has(op.tipo) && !esMovimientoDirecto(op)) || esEntrada(op);

/**
 * Operaciones cuya sede se valida contra el alcance del autor. Las que
 * registran hechos (una venta, una caja) NO: si a un vendedor lo cambiaron de
 * sede con ventas aún sin subir, esas ventas son de la sede donde se hicieron y
 * rechazarlas perdería dinero cobrado.
 */
const VALIDAN_SEDE = new Set(['MOVIMIENTO_CREAR', 'CONTEO_AJUSTAR', 'STOCK_MINIMO_FIJAR']);

const ENTIDAD_DE = {
  PRODUCTO_CREAR: 'productos', PRODUCTO_ACTUALIZAR: 'productos', PRODUCTO_ELIMINAR: 'productos',
  CODIGO_CREAR: 'producto_codigos', CODIGO_ELIMINAR: 'producto_codigos',
  STOCK_MINIMO_FIJAR: 'stock_sedes',
  CATEGORIA_CREAR: 'categorias', CATEGORIA_ACTUALIZAR: 'categorias', CATEGORIA_ELIMINAR: 'categorias',
  PROVEEDOR_CREAR: 'proveedores', PROVEEDOR_ACTUALIZAR: 'proveedores', PROVEEDOR_ELIMINAR: 'proveedores',
  METODO_PAGO_CREAR: 'metodos_pago', METODO_PAGO_ACTUALIZAR: 'metodos_pago', METODO_PAGO_ELIMINAR: 'metodos_pago',
  MOVIMIENTO_CREAR: 'movimientos_inventario', CONTEO_AJUSTAR: 'movimientos_inventario',
  VENTA_CREAR: 'ventas', VENTA_ANULAR: 'ventas',
  TRASLADO_CREAR: 'traslados', TRASLADO_APROBAR: 'traslados', TRASLADO_RECHAZAR: 'traslados',
  TRASLADO_CANCELAR: 'traslados',
  AJUSTE_SOLICITAR: 'solicitudes_ajuste', AJUSTE_APROBAR: 'solicitudes_ajuste', AJUSTE_RECHAZAR: 'solicitudes_ajuste',
  CIERRE_ABRIR: 'cierres_caja', CIERRE_CERRAR: 'cierres_caja', CIERRE_REVISAR: 'cierres_caja',
  RECAUDO_CREAR: 'recaudos',
};

/**
 * Contexto de UNA operación: su autor real y su sede.
 *
 * Lanza ApiError si el autor no es aceptable. AUTOR_DEBE_SINCRONIZAR es
 * transitorio a propósito: la operación sigue en la cola y sube cuando su autor
 * vuelva a entrar en ese teléfono.
 */
async function contextoDeOperacion(op, ctxBase) {
  let ctx = ctxBase;
  const autorUuid = op.payload?.usuario_uuid;

  if (autorUuid && autorUuid !== ctxBase.usuarioUuid) {
    const autor = await queryOne(
      'SELECT id, uuid, rol, activo FROM usuarios WHERE uuid = ? AND deleted_at IS NULL',
      [autorUuid],
    );
    if (!autor) throw new ApiError(422, 'AUTOR_DESCONOCIDO', 'La operación es de un usuario que ya no existe');

    const estuvo = ctxBase.dispositivoUuid
      ? await queryOne(
          'SELECT 1 x FROM refresh_tokens WHERE usuario_id = ? AND dispositivo_uuid = ? LIMIT 1',
          [autor.id, ctxBase.dispositivoUuid],
        )
      : null;
    if (!estuvo) {
      throw new ApiError(
        403,
        'AUTOR_NO_AUTENTICADO',
        'La operación está a nombre de alguien que nunca inició sesión en este teléfono',
      );
    }
    if (!admiteAutorDiferido(op)) {
      throw new ApiError(
        409,
        'AUTOR_DEBE_SINCRONIZAR',
        'Esta operación la subirá su autor la próxima vez que entre en este teléfono',
        null,
        { permanente: false },
      );
    }
    ctx = {
      ...ctxBase,
      usuarioId: autor.id,
      usuarioUuid: autor.uuid,
      rol: autor.rol,
      alcance: await cargarAlcance(autor),
      sincronizadoPor: ctxBase.usuarioId,
    };
  }

  // Sede: la que trae la operación; si no trae (cliente viejo), la del
  // dispositivo; y si tampoco, la principal.
  let sedeId = null;
  if (op.payload?.sede_uuid) {
    const sede = await sedePorUuid(null, op.payload.sede_uuid);
    if (!sede) throw new ApiError(422, 'SEDE_INEXISTENTE', 'La sede de la operación no existe');
    sedeId = Number(sede.id);
  } else {
    sedeId = Number(
      (await sedeDeDispositivo(null, ctx.dispositivoUuid))?.id ?? (await sedePrincipal())?.id ?? 0,
    ) || null;
  }

  return { ...ctx, sedeId };
}

/**
 * Procesa un lote de operaciones de subida.
 *
 * Se procesan SECUENCIALMENTE, cada una en su propia transacción. Secuencial
 * porque el orden importa: crear un producto y venderlo en el mismo lote sólo
 * funciona si el alta se aplica antes. Transacción por operación —y no una
 * para todo el lote— porque una operación rechazada no debe tumbar las 49
 * válidas que van detrás.
 *
 * @returns un resultado por operación, en el mismo orden que llegaron.
 */
export async function procesarPush(operaciones, ctx) {
  const resultados = [];

  for (const op of operaciones) {
    resultados.push(await procesarOperacion(op, ctx));
  }

  if (ctx.dispositivoUuid) {
    await query('UPDATE dispositivos SET ultimo_sync_at = UTC_TIMESTAMP(3) WHERE uuid = ?', [
      ctx.dispositivoUuid,
    ]);
  }

  return resultados;
}

async function procesarOperacion(op, ctxBase) {
  const { client_op_id: opId, tipo, payload } = op;

  // ── 1. ¿Ya se procesó? ────────────────────────────────────────────────────
  // Esta consulta es la que impide cobrar dos veces cuando la respuesta al
  // primer intento se perdió por un corte de señal.
  const previa = await queryOne(
    'SELECT estado, http_status, respuesta FROM sync_operaciones WHERE client_op_id = ?',
    [opId],
  );
  if (previa) {
    return {
      client_op_id: opId,
      estado: previa.estado,
      http_status: previa.http_status,
      resultado: previa.respuesta ? JSON.parse(previa.respuesta) : null,
      reprocesada: false,
      idempotente: true,
    };
  }

  const manejador = MANEJADORES[tipo];
  if (!manejador) {
    return registrarRechazo(op, ctxBase, new ApiError(400, 'TIPO_DESCONOCIDO', `Operación no soportada: ${tipo}`));
  }

  // ── 2. ¿Quién es el autor y en qué sede? ──────────────────────────────────
  let ctx;
  try {
    ctx = await contextoDeOperacion(op, ctxBase);
  } catch (err) {
    return registrarRechazo(op, ctxBase, err);
  }

  // ── 3. ¿Su rol puede hacer esto, en esa sede? ─────────────────────────────
  // Se comprueba ANTES de abrir la transacción. El rechazo es permanente a
  // propósito: la operación sale de la cola del dispositivo y aparece en
  // «Elementos con problema», de modo que queda rastro de que alguien intentó
  // una operación que no le corresponde.
  const roles = rolesPermitidos(op);
  if (!roles || !roles.includes(ctx.rol)) {
    logger.warn(
      { usuario: ctx.usuarioUuid, dispositivo: ctx.dispositivoUuid, tipo },
      'Operación de sincronización rechazada por rol insuficiente',
    );
    return registrarRechazo(
      op,
      ctx,
      new ApiError(
        403,
        'SIN_PERMISO',
        `Tu rol (${ctx.rol}) no puede ejecutar ${tipo}. Pídelo a tu gerente.`,
      ),
    );
  }
  if (VALIDAN_SEDE.has(tipo) && !veSede(ctx.alcance, ctx.sedeId)) {
    return registrarRechazo(
      op,
      ctx,
      new ApiError(403, 'SEDE_FUERA_DE_ALCANCE', 'No puedes alterar el inventario de una sede que no es tuya'),
    );
  }

  // ── 4. Aplicar el efecto y memorizar el resultado EN LA MISMA TRANSACCIÓN ──
  // Si el efecto se confirmara y el registro de idempotencia no, un reintento
  // volvería a aplicarlo. Van juntos o no van.
  try {
    const resultado = await withTransaction(async (conn) => {
      const salida = await manejador(conn, payload, ctx);

      await txExecute(
        conn,
        `INSERT INTO sync_operaciones
           (client_op_id, tipo, entidad, entidad_uuid, usuario_id, dispositivo_uuid,
            estado, http_status, respuesta)
         VALUES (?,?,?,?,?,?, 'OK', 200, ?)`,
        [
          opId,
          tipo,
          ENTIDAD_DE[tipo] ?? 'desconocida',
          salida?.uuid ?? payload?.uuid ?? null,
          ctx.usuarioId ?? null,
          ctx.dispositivoUuid ?? null,
          JSON.stringify(salida ?? null),
        ],
      );

      return salida;
    });

    return {
      client_op_id: opId,
      estado: 'OK',
      http_status: 200,
      resultado,
      reprocesada: true,
      idempotente: false,
    };
  } catch (err) {
    // Carrera: dos envíos simultáneos del mismo op_id. El segundo choca contra
    // la PK y debe devolver lo que guardó el primero.
    if (err.code === 'ER_DUP_ENTRY' && err.sqlMessage?.includes('PRIMARY')) {
      const guardada = await queryOne(
        'SELECT estado, http_status, respuesta FROM sync_operaciones WHERE client_op_id = ?',
        [opId],
      );
      if (guardada) {
        return {
          client_op_id: opId,
          estado: guardada.estado,
          http_status: guardada.http_status,
          resultado: guardada.respuesta ? JSON.parse(guardada.respuesta) : null,
          reprocesada: false,
          idempotente: true,
        };
      }
    }
    return registrarRechazo(op, ctx, err);
  }
}

/**
 * Un error PERMANENTE (validación, referencia inexistente) se memoriza para que
 * el cliente lo saque de la cola: reintentarlo nunca va a funcionar y
 * bloquearía todo lo que viene detrás.
 *
 * Un error TRANSITORIO (base caída, deadlock) NO se memoriza: se devuelve tal
 * cual para que el cliente reintente con backoff.
 */
async function registrarRechazo(op, ctx, err) {
  const apiError =
    err instanceof ApiError
      ? err
      : new ApiError(500, 'ERROR_INTERNO', err.message ?? 'Error desconocido', null, { permanente: false });

  const cuerpo = {
    codigo: apiError.codigo,
    mensaje: apiError.message,
    detalles: apiError.detalles,
    permanente: apiError.permanente,
  };

  if (apiError.permanente) {
    try {
      await query(
        `INSERT INTO sync_operaciones
           (client_op_id, tipo, entidad, entidad_uuid, usuario_id, dispositivo_uuid,
            estado, http_status, respuesta)
         VALUES (?,?,?,?,?,?, 'ERROR', ?, ?)
         ON DUPLICATE KEY UPDATE respuesta = VALUES(respuesta)`,
        [
          op.client_op_id,
          op.tipo,
          ENTIDAD_DE[op.tipo] ?? 'desconocida',
          op.payload?.uuid ?? null,
          ctx.usuarioId ?? null,
          ctx.dispositivoUuid ?? null,
          apiError.status,
          JSON.stringify(cuerpo),
        ],
      );
    } catch (e) {
      logger.error({ err: e, opId: op.client_op_id }, 'No se pudo registrar el rechazo de sincronización');
    }
  } else {
    logger.warn({ opId: op.client_op_id, tipo: op.tipo, err: apiError.message }, 'Operación de sync fallida (transitoria)');
  }

  return {
    client_op_id: op.client_op_id,
    estado: 'ERROR',
    http_status: apiError.status,
    error: cuerpo,
    reprocesada: false,
    idempotente: false,
  };
}

// ── Bajada ──────────────────────────────────────────────────────────────────

const CURSOR_CERO = { t: '1970-01-01T00:00:00.000Z', i: 0 };

function normalizarCursor(c) {
  if (!c || typeof c !== 'object') return CURSOR_CERO;
  const t = typeof c.t === 'string' ? c.t : CURSOR_CERO.t;
  const fecha = new Date(t);
  return {
    t: Number.isNaN(fecha.getTime()) ? CURSOR_CERO.t : fecha.toISOString(),
    i: Number.isInteger(c.i) && c.i >= 0 ? c.i : 0,
  };
}

/**
 * Bajada delta.
 *
 * @param cursores  { productos: {t, i}, ventas: {t, i}, ... }
 * @param opciones  { limite, diasHistorial, entidades }
 */
export async function pull(cursores = {}, { limite, diasHistorial = 90, entidades } = {}, ctx = {}) {
  const tope = Math.min(limite ?? env.SYNC_PULL_MAX_ROWS, env.SYNC_PULL_MAX_ROWS);
  const horizonte = sumarDias(diaHabil(), -Math.abs(diasHistorial));
  const objetivo = entidades?.length ? ENTIDADES.filter((e) => entidades.includes(e)) : ENTIDADES;

  const salida = {};
  let hayMas = false;

  // Se lanzan en paralelo: son SELECT independientes y el pool tiene holgura.
  await Promise.all(
    objetivo.map(async (entidad) => {
      const def = CONSULTAS[entidad];
      const cursor = normalizarCursor(cursores[entidad]);
      const fechaCursor = new Date(cursor.t);

      // Mismo orden en que cada SQL escribe sus `?` (ver pullQueries.js).
      const params = [
        fechaCursor,
        fechaCursor,
        cursor.i,
        ...(def.horizonte ? [horizonte] : []),
        ...(def.extra ? def.extra(ctx) : []),
        tope,
      ];

      const [filas] = await pool.query(def.sql, params);

      const ultimo = filas.at(-1);
      const nuevoCursor = ultimo
        ? { t: new Date(ultimo.updated_at).toISOString(), i: Number(ultimo._id) }
        : cursor;

      for (const f of filas) delete f._id;

      if (filas.length >= tope) hayMas = true;

      salida[entidad] = {
        items: filas,
        cursor: nuevoCursor,
        hay_mas: filas.length >= tope,
      };
    }),
  );

  // La configuración es una decena de filas: se manda entera siempre. Paginarla
  // costaría más de lo que ahorra.
  salida.configuracion = {
    items: await query('SELECT clave, valor, tipo, updated_at FROM configuracion'),
    cursor: null,
    hay_mas: false,
  };

  if (ctx.dispositivoUuid) {
    await query('UPDATE dispositivos SET ultimo_sync_at = UTC_TIMESTAMP(3) WHERE uuid = ?', [
      ctx.dispositivoUuid,
    ]);
  }

  return {
    entidades: salida,
    hay_mas: hayMas,
    horizonte,
    // Si cambia (cambio de sede o de rol), la app descarta lo que ya no le
    // corresponde y vuelve a bajar desde cero lo que sí.
    alcance: huellaAlcance(ctx.rol, ctx.alcance),
    servidor_utc: new Date().toISOString(),
    zona_negocio: env.BUSINESS_TIMEZONE,
  };
}

/** Diagnóstico: qué sabe el servidor de este dispositivo. */
export async function estado(ctx) {
  const dispositivo = ctx.dispositivoUuid
    ? await queryOne(
        'SELECT uuid, nombre, prefijo_folio, ultimo_sync_at, app_version FROM dispositivos WHERE uuid = ?',
        [ctx.dispositivoUuid],
      )
    : null;

  const [conteos] = await pool.query(`
    SELECT
      (SELECT COUNT(*) FROM productos WHERE deleted_at IS NULL) AS productos,
      (SELECT COUNT(*) FROM ventas WHERE deleted_at IS NULL) AS ventas,
      (SELECT COUNT(*) FROM movimientos_inventario) AS movimientos,
      (SELECT COUNT(*) FROM alertas WHERE resuelta_en IS NULL) AS alertas_abiertas`);

  const recientes = ctx.dispositivoUuid
    ? await query(
        `SELECT client_op_id, tipo, estado, http_status, created_at
           FROM sync_operaciones WHERE dispositivo_uuid = ?
          ORDER BY created_at DESC LIMIT 20`,
        [ctx.dispositivoUuid],
      )
    : [];

  return {
    dispositivo,
    conteos: conteos[0],
    operaciones_recientes: recientes,
    servidor_utc: new Date().toISOString(),
    zona_negocio: env.BUSINESS_TIMEZONE,
    limite_push: env.SYNC_PUSH_MAX_OPS,
    limite_pull: env.SYNC_PULL_MAX_ROWS,
  };
}

/**
 * Purga registros de idempotencia antiguos.
 *
 * Se conservan 30 días: mucho más que cualquier ventana realista de reintento,
 * y suficiente para investigar una duplicación reportada por el usuario.
 */
export async function purgarOperaciones(dias = 30) {
  const r = await pool.query(
    'DELETE FROM sync_operaciones WHERE created_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL ? DAY)',
    [dias],
  );
  return { eliminadas: r[0].affectedRows };
}

/** Elimina refresh tokens caducados o revocados hace mucho. */
export async function purgarTokens() {
  const r = await pool.query(
    'DELETE FROM refresh_tokens WHERE expires_at < UTC_TIMESTAMP(3) OR revoked_at < DATE_SUB(UTC_TIMESTAMP(3), INTERVAL 7 DAY)',
  );
  return { eliminados: r[0].affectedRows };
}
