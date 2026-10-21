/**
 * Empresa, plan y uso.
 *
 * Los límites los impone la base (triggers de 004_plataforma.sql); aquí solo
 * se LEEN para mostrarlos y para avisar antes de que el usuario llene un
 * formulario que la base va a rechazar.
 */
import { queryOne } from '../../db/pool.js';
import { txQueryOne } from '../../db/tx.js';

const numero = (v) => (v == null ? null : Number(v));

/** Recurso del plan tal como lo ve la app: usado, máximo y si ya no cabe uno más. */
function recurso(usados, maximo) {
  const u = Number(usados ?? 0);
  const m = numero(maximo);
  return { usados: u, maximo: m, lleno: m != null && u >= m };
}

/**
 * Plan vigente y uso de la empresa.
 *
 *   { codigo, nombre, vence, vencido,
 *     sedes: {usados, maximo, lleno}, personas: {…}, productos: {…} }
 *
 * `maximo` null = sin límite. Un plan vencido opera con los límites de GRATIS
 * (`vencido` true): la app lo explica en vez de mostrar solo «límite alcanzado».
 */
export async function planDeEmpresa(empresaId, conn = null, aplicativo = 'INVENTARIO') {
  // Cada app tiene su plan (006_planes_y_roles_por_app.sql). Ventario lee el suyo.
  const sql = 'SELECT * FROM v_empresa_uso_app WHERE empresa_id = ? AND aplicativo = ?';
  const p = [empresaId, aplicativo];
  const fila = conn ? await txQueryOne(conn, sql, p) : await queryOne(sql, p);
  if (!fila) return null;
  return {
    aplicativo: fila.aplicativo,
    codigo: fila.plan_codigo,
    nombre: fila.plan_nombre,
    vence: fila.plan_vence ?? null,
    vencido: !!fila.plan_vencido,
    sedes: recurso(fila.sedes_usadas, fila.max_sedes),
    personas: recurso(fila.personas_usadas, fila.max_personas),
    productos: recurso(fila.productos_usados, fila.max_productos),
    // Sedes de la empresa (compartidas) y cuántas puede tener: el mayor de
    // los dos planes. Cada app usa solo las que elige.
    sedes_empresa: recurso(fila.sedes_empresa, fila.tope_sedes_empresa),
  };
}

/** Plan de cada app: { INVENTARIO: {...}, ASISTENCIA: {...} }. */
export async function planesDeEmpresa(empresaId) {
  return {
    INVENTARIO: await planDeEmpresa(empresaId, null, 'INVENTARIO'),
    ASISTENCIA: await planDeEmpresa(empresaId, null, 'ASISTENCIA'),
  };
}

/**
 * Prefijo de folios para lo que se numera sin dispositivo (ventas en línea,
 * traslados del servidor). Cada empresa tiene el suyo: 'W' + id en base 36
 * (5 caracteres, nunca choca con los de 2-3 de los dispositivos), o el que fije
 * la columna `prefijo_web` (la empresa fundadora conserva 'WEB').
 */
export async function prefijoWeb(conn, empresaId) {
  const sql = `SELECT COALESCE(prefijo_web, CONCAT('W', LPAD(UPPER(CONV(id, 10, 36)), 4, '0'))) AS p
                 FROM empresas WHERE id = ?`;
  const fila = conn ? await txQueryOne(conn, sql, [empresaId]) : await queryOne(sql, [empresaId]);
  if (!fila) throw new Error(`Empresa ${empresaId} inexistente`);
  return fila.p;
}

/** Apps habilitadas para la empresa: ['INVENTARIO', 'ASISTENCIA']. */
export async function aplicativosDeEmpresa(empresaId) {
  const fila = await queryOne(
    `SELECT GROUP_CONCAT(aplicativo ORDER BY aplicativo) AS apps
       FROM empresa_aplicativos WHERE empresa_id = ? AND activo = 1`,
    [empresaId],
  );
  return fila?.apps ? fila.apps.split(',') : [];
}
