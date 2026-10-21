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
export async function planDeEmpresa(empresaId, conn = null) {
  const sql = 'SELECT * FROM v_empresa_uso WHERE empresa_id = ?';
  const fila = conn ? await txQueryOne(conn, sql, [empresaId]) : await queryOne(sql, [empresaId]);
  if (!fila) return null;
  return {
    codigo: fila.plan_codigo,
    nombre: fila.plan_nombre,
    vence: fila.plan_vence ?? null,
    vencido: !!fila.plan_vencido,
    sedes: recurso(fila.sedes_usadas, fila.max_sedes),
    personas: recurso(fila.personas_usadas, fila.max_personas),
    productos: recurso(fila.productos_usados, fila.max_productos),
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
