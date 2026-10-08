/**
 * Acceso a sedes y a la pertenencia de usuarios a sedes.
 *
 * Todas las funciones aceptan una conexión de transacción opcional: dentro de
 * una operación se leen con la misma conexión (y ven lo que la transacción ya
 * escribió); fuera, con el pool.
 */
import { query } from '../../db/pool.js';
import { txQuery, txExecute } from '../../db/tx.js';
import { ROLES, ROLES_DE_UNA_SEDE } from '../../config/constants.js';
import { notFound } from '../../utils/ApiError.js';

const leer = (conn, sql, params) => (conn ? txQuery(conn, sql, params) : query(sql, params));
const leerUno = async (conn, sql, params) => (await leer(conn, sql, params))[0] ?? null;

/** Alcance del usuario: { esDirector, sedeIds }. */
export async function cargarAlcance(usuario, conn = null) {
  if (usuario.rol === ROLES.ADMIN) return { esDirector: true, sedeIds: [] };
  const filas = await leer(
    conn,
    `SELECT us.sede_id
       FROM usuario_sedes us
       JOIN sedes s ON s.id = us.sede_id AND s.deleted_at IS NULL
      WHERE us.usuario_id = ?`,
    [usuario.id],
  );
  const sedeIds = filas.map((f) => Number(f.sede_id));

  // Vendedor o auxiliar sin sede: sólo pasa con cuentas creadas por el backend
  // anterior a las sedes (entre aplicar la migración y desplegar este backend,
  // o tras volver atrás). Se le asigna la sede principal, igual que hizo la
  // migración con todos los demás, en vez de dejarlo fuera con SIN_SEDE. Es
  // idempotente y sólo ocurre una vez por cuenta.
  if (!sedeIds.length && ROLES_DE_UNA_SEDE.includes(usuario.rol)) {
    const principal = await leerUno(
      conn,
      'SELECT id FROM sedes WHERE es_principal = 1 AND deleted_at IS NULL ORDER BY id LIMIT 1',
      [],
    );
    if (principal) {
      const insertar = 'INSERT IGNORE INTO usuario_sedes (usuario_id, sede_id) VALUES (?, ?)';
      const tocar = 'UPDATE usuarios SET updated_at = UTC_TIMESTAMP(3) WHERE id = ?';
      if (conn) {
        await txExecute(conn, insertar, [usuario.id, principal.id]);
        await txExecute(conn, tocar, [usuario.id]);
      } else {
        await query(insertar, [usuario.id, principal.id]);
        await query(tocar, [usuario.id]);
      }
      sedeIds.push(Number(principal.id));
    }
  }
  return { esDirector: false, sedeIds };
}

export async function sedePorUuid(conn, uuid) {
  if (!uuid) return null;
  return leerUno(
    conn,
    'SELECT id, uuid, nombre, codigo, direccion, telefono, activo FROM sedes WHERE uuid = ? AND deleted_at IS NULL',
    [uuid],
  );
}

/** Como `sedePorUuid`, pero lanza 404 si no existe. */
export async function exigirSedePorUuid(conn, uuid) {
  const sede = await sedePorUuid(conn, uuid);
  if (!sede) throw notFound('Sede');
  return sede;
}

export async function sedePrincipal(conn = null) {
  return leerUno(
    conn,
    `SELECT id, uuid, nombre, codigo, direccion, telefono, activo
       FROM sedes WHERE es_principal = 1 AND deleted_at IS NULL ORDER BY id LIMIT 1`,
    [],
  );
}

/** Sedes visibles para un alcance, en orden: la principal primero. */
export async function sedesDeAlcance(alcance, conn = null) {
  if (alcance.esDirector) {
    return leer(
      conn,
      `SELECT id, uuid, nombre, codigo, direccion, telefono, es_principal, activo
         FROM sedes WHERE deleted_at IS NULL
        ORDER BY es_principal DESC, nombre`,
      [],
    );
  }
  if (!alcance.sedeIds.length) return [];
  return leer(
    conn,
    `SELECT id, uuid, nombre, codigo, direccion, telefono, es_principal, activo
       FROM sedes WHERE deleted_at IS NULL AND id IN (?)
      ORDER BY es_principal DESC, nombre`,
    [alcance.sedeIds],
  );
}

/** Sede asociada a un dispositivo (la que opera ahora). */
export async function sedeDeDispositivo(conn, dispositivoUuid) {
  if (!dispositivoUuid) return null;
  return leerUno(
    conn,
    `SELECT s.id, s.uuid, s.nombre
       FROM dispositivos d JOIN sedes s ON s.id = d.sede_id
      WHERE d.uuid = ?`,
    [dispositivoUuid],
  );
}

/** Forma pública de una sede, sin el id interno. */
export const sedePublica = (s) =>
  s && {
    uuid: s.uuid,
    nombre: s.nombre,
    codigo: s.codigo,
    direccion: s.direccion ?? null,
    telefono: s.telefono ?? null,
    es_principal: !!s.es_principal,
    activo: s.activo == null ? true : !!s.activo,
  };
