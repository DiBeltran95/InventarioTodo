/**
 * Acceso a sedes y a la pertenencia de usuarios a sedes.
 *
 * Todas las funciones aceptan una conexión de transacción opcional: dentro de
 * una operación se leen con la misma conexión (y ven lo que la transacción ya
 * escribió); fuera, con el pool.
 *
 * Plataforma multiempresa: toda búsqueda de sede recibe la empresa y nunca
 * devuelve una sede de otra. Un UUID es global, así que sin ese filtro bastaría
 * con mandar el `sede_uuid` de otra empresa para operar en ella.
 */
import { query } from '../../db/pool.js';
import { txQuery, txExecute } from '../../db/tx.js';
import { ROLES, ROLES_DE_UNA_SEDE } from '../../config/constants.js';
import { notFound } from '../../utils/ApiError.js';

const leer = (conn, sql, params) => (conn ? txQuery(conn, sql, params) : query(sql, params));
const leerUno = async (conn, sql, params) => (await leer(conn, sql, params))[0] ?? null;

/** Falla en voz alta si alguien olvida pasar la empresa: es un hueco de aislamiento. */
export function exigirEmpresa(empresaId) {
  if (!empresaId) throw new Error('Consulta sin empresa: falta empresaId');
  return Number(empresaId);
}

/**
 * Alcance del usuario: { empresaId, esDirector, sedeIds }.
 *
 * El director ve TODAS las sedes de SU empresa: `sedeIds` las trae todas
 * (también las archivadas, para el historial). Así cualquier filtro por
 * `sede_id IN (sedeIds)` es seguro entre empresas sin un caso especial.
 */
export async function cargarAlcance(usuario, conn = null) {
  const empresaId = exigirEmpresa(usuario.empresa_id);
  // Solo las sedes ELEGIDAS para Ventario (sede_aplicativos): cada app
  // trabaja en las suyas, hasta el límite de su plan.
  if (usuario.rol === ROLES.ADMIN) {
    const todas = await leer(
      conn,
      `SELECT s.id FROM sedes s
         JOIN sede_aplicativos sa ON sa.sede_id = s.id AND sa.aplicativo = 'INVENTARIO'
        WHERE s.empresa_id = ?`,
      [empresaId],
    );
    return { empresaId, esDirector: true, sedeIds: todas.map((f) => Number(f.id)) };
  }
  const filas = await leer(
    conn,
    `SELECT us.sede_id
       FROM usuario_sedes us
       JOIN sedes s ON s.id = us.sede_id AND s.deleted_at IS NULL AND s.empresa_id = ?
       JOIN sede_aplicativos sa ON sa.sede_id = s.id AND sa.aplicativo = 'INVENTARIO'
      WHERE us.usuario_id = ?`,
    [empresaId, usuario.id],
  );
  const sedeIds = filas.map((f) => Number(f.sede_id));

  // Vendedor o auxiliar sin sede: sólo pasa con cuentas creadas por el backend
  // anterior a las sedes. Se le asigna la sede principal de SU empresa, en vez
  // de dejarlo fuera con SIN_SEDE. Es idempotente y sólo ocurre una vez.
  if (!sedeIds.length && ROLES_DE_UNA_SEDE.includes(usuario.rol)) {
    const principal = await sedePrincipal(conn, empresaId);
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
  return { empresaId, esDirector: false, sedeIds };
}

export async function sedePorUuid(conn, uuid, empresaId) {
  if (!uuid) return null;
  return leerUno(
    conn,
    `SELECT id, uuid, nombre, codigo, direccion, telefono, activo
       FROM sedes WHERE uuid = ? AND empresa_id = ? AND deleted_at IS NULL`,
    [uuid, exigirEmpresa(empresaId)],
  );
}

/** Como `sedePorUuid`, pero lanza 404 si no existe (o es de otra empresa). */
export async function exigirSedePorUuid(conn, uuid, empresaId) {
  const sede = await sedePorUuid(conn, uuid, empresaId);
  if (!sede) throw notFound('Sede');
  return sede;
}

export async function sedePrincipal(conn, empresaId) {
  return leerUno(
    conn,
    `SELECT id, uuid, nombre, codigo, direccion, telefono, activo
       FROM sedes WHERE empresa_id = ? AND es_principal = 1 AND deleted_at IS NULL
      ORDER BY id LIMIT 1`,
    [exigirEmpresa(empresaId)],
  );
}

/** Sedes visibles para un alcance, en orden: la principal primero. */
export async function sedesDeAlcance(alcance, conn = null) {
  const empresaId = exigirEmpresa(alcance.empresaId);
  if (!alcance.sedeIds.length) return [];
  return leer(
    conn,
    `SELECT id, uuid, nombre, codigo, direccion, telefono, es_principal, activo
       FROM sedes WHERE empresa_id = ? AND deleted_at IS NULL AND id IN (?)
      ORDER BY es_principal DESC, nombre`,
    [empresaId, alcance.sedeIds],
  );
}

/** Sede asociada a un dispositivo (la que opera ahora), dentro de la empresa. */
export async function sedeDeDispositivo(conn, dispositivoUuid, empresaId) {
  if (!dispositivoUuid) return null;
  return leerUno(
    conn,
    `SELECT s.id, s.uuid, s.nombre
       FROM dispositivos d JOIN sedes s ON s.id = d.sede_id
      WHERE d.uuid = ? AND s.empresa_id = ?`,
    [dispositivoUuid, exigirEmpresa(empresaId)],
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
