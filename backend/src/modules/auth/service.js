import jwt from 'jsonwebtoken';
import * as argon2 from '@node-rs/argon2';
import { env } from '../../config/env.js';
import { query, queryOne } from '../../db/pool.js';
import { withTransaction, txQuery, txQueryOne, txExecute } from '../../db/tx.js';
import { nuevoUuid, sha256, tokenAleatorio, prefijoFolioAleatorio } from '../../utils/ids.js';
import { ApiError, unauthorized, notFound, badRequest, conflict, forbidden } from '../../utils/ApiError.js';
import { logger } from '../../utils/logger.js';
import { GRACIA_CIERRE_TURNO_MIN } from '../../config/constants.js';
import { evaluarJornada, permitidoConGracia, jornadaDe, leerHorario } from '../../domain/jornada.js';
import { veSede } from '../../domain/alcance.js';
import { fueraDeHorario } from '../../middleware/auth.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';
import {
  cargarAlcance,
  sedePorUuid,
  sedePrincipal,
  sedesDeAlcance,
  sedePublica,
} from '../sedes/repo.js';

/**
 * Parámetros de Argon2id.
 *
 * 19 MiB / 2 iteraciones / paralelismo 1 son los mínimos recomendados por OWASP
 * (2024) para argon2id. Se elige argon2id y no bcrypt porque resiste ataques
 * con GPU y ASIC gracias al coste en memoria, cosa que bcrypt no hace.
 */
const ARGON = { memoryCost: 19_456, timeCost: 2, parallelism: 1 };

export const hashearPassword = (plano) => argon2.hash(plano, ARGON);

export async function verificarPassword(hash, plano) {
  try {
    return await argon2.verify(hash, plano);
  } catch {
    return false;
  }
}

function firmarAccessToken(usuario, dispositivoUuid) {
  return jwt.sign(
    {
      sub: usuario.uuid,
      rol: usuario.rol,
      email: usuario.email,
      dispositivo: dispositivoUuid ?? undefined,
    },
    env.JWT_ACCESS_SECRET,
    { algorithm: 'HS256', expiresIn: env.JWT_ACCESS_TTL, issuer: 'inventario-api' },
  );
}

async function emitirRefreshToken(conn, usuarioId, familia, dispositivoUuid, userAgent) {
  const token = tokenAleatorio(48);
  const expira = new Date(Date.now() + env.JWT_REFRESH_TTL_DAYS * 86_400_000);
  await txExecute(
    conn,
    `INSERT INTO refresh_tokens (usuario_id, token_hash, familia, dispositivo_uuid, user_agent, expires_at)
     VALUES (?,?,?,?,?,?)`,
    [usuarioId, sha256(token), familia, dispositivoUuid ?? null, (userAgent ?? '').slice(0, 255), expira],
  );
  return { token, expira };
}

/**
 * Registra o actualiza el dispositivo y le garantiza un prefijo de folio único.
 *
 * El prefijo es lo que permite que dos cajas sin conexión numeren ventas
 * (A1-000001, B7-000001) sin colisionar al sincronizar.
 */
async function registrarDispositivo(conn, dispositivo, usuarioId, sedeId = null) {
  if (!dispositivo) return null;

  const existente = await txQueryOne(
    conn,
    'SELECT id, prefijo_folio FROM dispositivos WHERE uuid = ?',
    [dispositivo.uuid],
  );

  if (existente) {
    await txExecute(
      conn,
      `UPDATE dispositivos
          SET usuario_id = ?, sede_id = COALESCE(?, sede_id), nombre = ?, plataforma = ?,
              app_version = ?, activo = 1, deleted_at = NULL
        WHERE id = ?`,
      [
        usuarioId,
        sedeId,
        dispositivo.nombre,
        dispositivo.plataforma ?? null,
        dispositivo.app_version ?? null,
        existente.id,
      ],
    );
    return existente.prefijo_folio;
  }

  // Prefijo aleatorio con reintento; se alarga si el espacio de 2 caracteres
  // empieza a saturarse (más de ~500 dispositivos).
  for (let intento = 0; intento < 12; intento += 1) {
    const longitud = intento < 8 ? 2 : 3;
    const prefijo = prefijoFolioAleatorio(longitud);
    try {
      await txExecute(
        conn,
        `INSERT INTO dispositivos (uuid, usuario_id, sede_id, nombre, plataforma, app_version, prefijo_folio)
         VALUES (?,?,?,?,?,?,?)`,
        [
          dispositivo.uuid,
          usuarioId,
          sedeId,
          dispositivo.nombre,
          dispositivo.plataforma ?? null,
          dispositivo.app_version ?? null,
          prefijo,
        ],
      );
      return prefijo;
    } catch (err) {
      if (err.code !== 'ER_DUP_ENTRY') throw err;
      if (err.sqlMessage?.includes('uk_dispositivos_uuid')) {
        // Carrera con otro login del mismo dispositivo: relee y usa el suyo.
        const otro = await txQueryOne(
          conn,
          'SELECT prefijo_folio FROM dispositivos WHERE uuid = ?',
          [dispositivo.uuid],
        );
        if (otro) return otro.prefijo_folio;
      }
      // Prefijo ocupado: siguiente intento.
    }
  }
  throw conflict('SIN_PREFIJO', 'No se pudo asignar un prefijo de folio al dispositivo');
}

export function perfilPublico(u) {
  return {
    uuid: u.uuid,
    nombre: u.nombre,
    email: u.email,
    rol: u.rol,
    activo: !!u.activo,
    restringir_horario: !!u.restringir_horario,
    horario: leerHorario(u.horario),
    acceso_extra_hasta: u.acceso_extra_hasta ? new Date(u.acceso_extra_hasta).toISOString() : null,
  };
}

const COLUMNAS_USUARIO =
  'id, uuid, nombre, email, password_hash, rol, activo, restringir_horario, horario, acceso_extra_hasta';

/** Estado de la jornada tal como lo necesita la app para operar sin red. */
export function jornadaPublica(usuario, ahora = new Date()) {
  const e = evaluarJornada(jornadaDe(usuario), ahora, env.BUSINESS_TIMEZONE);
  return {
    permitido: e.permitido,
    motivo: e.motivo,
    hasta: e.hasta ? e.hasta.toISOString() : null,
    proximo_inicio: e.proximoInicio ? e.proximoInicio.toISOString() : null,
  };
}

/**
 * Sede en la que va a operar este dispositivo.
 *
 * Vendedor y auxiliar no eligen: la suya. Gerente y director pueden pedir una
 * de su alcance; si no piden ninguna, la primera de las suyas (gerente) o la
 * principal (director).
 */
async function resolverSedeActiva(alcance, sedeUuid, conn = null) {
  if (sedeUuid) {
    const sede = await sedePorUuid(conn, sedeUuid);
    if (!sede || !sede.activo) throw notFound('Sede');
    if (!veSede(alcance, sede.id)) {
      throw forbidden('No puedes operar en esa sede', 'SEDE_FUERA_DE_ALCANCE');
    }
    return sede;
  }
  if (alcance.esDirector) return sedePrincipal(conn);
  const sedes = await sedesDeAlcance(alcance, conn);
  return sedes.find((s) => s.activo) ?? null;
}

export async function login({ email, password, dispositivo, sede_uuid: sedeUuid }, userAgent) {
  const usuario = await queryOne(
    `SELECT ${COLUMNAS_USUARIO} FROM usuarios WHERE email = ? AND deleted_at IS NULL`,
    [email],
  );

  // Se verifica siempre contra un hash (real o señuelo) para que el tiempo de
  // respuesta no revele si el correo existe.
  const hashSenuelo = '$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHRzYWx0c2E$0000000000000000000000000000000000000000000';
  const valida = await verificarPassword(usuario?.password_hash ?? hashSenuelo, password);

  if (!usuario || !valida) throw unauthorized('Correo o contraseña incorrectos', 'CREDENCIALES_INVALIDAS');
  if (!usuario.activo) throw unauthorized('La cuenta está desactivada', 'CUENTA_DESACTIVADA');

  const alcance = await cargarAlcance(usuario);

  // El intento fuera de turno se registra: es justo lo que un gerente quiere
  // saber («¿quién intentó entrar el domingo a las 11 de la noche?»).
  const evaluacion = evaluarJornada(jornadaDe(usuario), new Date(), env.BUSINESS_TIMEZONE);
  if (!evaluacion.permitido) {
    await registrarAuditoria(null, {
      usuarioId: usuario.id,
      sedeId: alcance.sedeIds[0] ?? null,
      dispositivoUuid: dispositivo?.uuid,
      accion: ACCIONES.INGRESO_FUERA_DE_HORARIO,
      entidad: 'usuarios',
      entidadUuid: usuario.uuid,
    });
    throw fueraDeHorario(evaluacion);
  }

  const sedeActiva = await resolverSedeActiva(alcance, sedeUuid);
  if (!sedeActiva) {
    throw new ApiError(
      403,
      'SIN_SEDE',
      'Tu cuenta no tiene una sede asignada. Pide a tu gerente que te asigne una.',
    );
  }

  return withTransaction(async (conn) => {
    const prefijoFolio = await registrarDispositivo(conn, dispositivo, usuario.id, sedeActiva.id);
    const familia = nuevoUuid();
    const { token: refreshToken, expira } = await emitirRefreshToken(
      conn,
      usuario.id,
      familia,
      dispositivo?.uuid,
      userAgent,
    );

    await txExecute(conn, 'UPDATE usuarios SET ultimo_acceso = UTC_TIMESTAMP(3) WHERE id = ?', [
      usuario.id,
    ]);

    return {
      access_token: firmarAccessToken(usuario, dispositivo?.uuid),
      refresh_token: refreshToken,
      refresh_expira: expira.toISOString(),
      usuario: perfilPublico(usuario),
      dispositivo: dispositivo ? { uuid: dispositivo.uuid, prefijo_folio: prefijoFolio } : null,
      sedes: (await sedesDeAlcance(alcance, conn)).map(sedePublica),
      sede_activa: sedeActiva.uuid,
      jornada: jornadaPublica(usuario),
      // El cliente usa esto para saber cuántos días puede operar sin volver a
      // ver al servidor antes de exigir una reconexión.
      offline_grace_days: env.OFFLINE_GRACE_DAYS,
      zona_negocio: env.BUSINESS_TIMEZONE,
      servidor_utc: new Date().toISOString(),
    };
  });
}

/**
 * Cambia la sede en la que opera este dispositivo (gerente con varias sedes o
 * director). Lo que se venda desde aquí en adelante es de esa sede.
 */
export async function cambiarSedeActiva(alcance, dispositivoUuid, sedeUuid) {
  if (!dispositivoUuid) throw badRequest('SIN_DISPOSITIVO', 'Falta el encabezado X-Dispositivo');
  const sede = await resolverSedeActiva(alcance, sedeUuid);
  await query('UPDATE dispositivos SET sede_id = ? WHERE uuid = ?', [sede.id, dispositivoUuid]);
  return { sede_activa: sede.uuid, sede: sedePublica(sede) };
}

/** Perfil, sedes y jornada del usuario autenticado. */
export async function perfil(usuario, alcance, dispositivoUuid) {
  const sedeDispositivo = dispositivoUuid
    ? await queryOne(
        'SELECT s.uuid FROM dispositivos d JOIN sedes s ON s.id = d.sede_id WHERE d.uuid = ?',
        [dispositivoUuid],
      )
    : null;
  return {
    usuario: perfilPublico(usuario),
    sedes: (await sedesDeAlcance(alcance)).map(sedePublica),
    sede_activa: sedeDispositivo?.uuid ?? null,
    jornada: jornadaPublica(usuario),
    servidor_utc: new Date().toISOString(),
  };
}

/**
 * Rotación de refresh tokens con detección de reutilización.
 *
 * Cada refresh invalida el token usado y emite uno nuevo de la misma familia.
 * Si llega un token ya revocado, significa que alguien clonó la cadena: se
 * revoca la familia entera y ambos (legítimo y atacante) quedan fuera.
 */
export async function refrescar({ refresh_token: recibido, dispositivo }, userAgent) {
  const hash = sha256(recibido);

  /**
   * La revocación de la familia NO puede ir dentro de la transacción.
   *
   * Al detectar el reúso hay que lanzar 401, y `withTransaction` hace rollback
   * ante cualquier excepción: la revocación se desharía junto con el error y la
   * cadena robada seguiría viva. Se anota la familia, se deja que la
   * transacción se revierta —liberando el bloqueo de la fila— y sólo entonces
   * se revoca, ya fuera de ella.
   */
  let familiaComprometida = null;

  try {
    return await withTransaction(async (conn) => {
      const fila = await txQueryOne(
        conn,
        `SELECT rt.id, rt.usuario_id, rt.familia, rt.expires_at, rt.revoked_at,
                u.uuid, u.nombre, u.email, u.rol, u.activo,
                u.restringir_horario, u.horario, u.acceso_extra_hasta
           FROM refresh_tokens rt
           JOIN usuarios u ON u.id = rt.usuario_id
          WHERE rt.token_hash = ?
          FOR UPDATE`,
        [hash],
      );

      if (!fila) throw unauthorized('Refresh token inválido', 'REFRESH_INVALIDO');

      if (fila.revoked_at) {
        familiaComprometida = { familia: fila.familia, usuario: fila.uuid };
        throw unauthorized('Sesión comprometida; inicia sesión de nuevo', 'REFRESH_REUTILIZADO');
      }

      if (new Date(fila.expires_at).getTime() < Date.now()) {
        throw unauthorized('El refresh token expiró', 'REFRESH_EXPIRADO');
      }
      if (!fila.activo) throw unauthorized('La cuenta está desactivada', 'CUENTA_DESACTIVADA');

      // Con gracia: el último envío tras el fin del turno puede necesitar un
      // token nuevo. Pasado ese margen, la sesión no se renueva.
      const ahora = new Date();
      if (!permitidoConGracia(jornadaDe(fila), ahora, env.BUSINESS_TIMEZONE, GRACIA_CIERRE_TURNO_MIN)) {
        throw fueraDeHorario(evaluarJornada(jornadaDe(fila), ahora, env.BUSINESS_TIMEZONE));
      }

      await txExecute(conn, 'UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3) WHERE id = ?', [
        fila.id,
      ]);

      const { token, expira } = await emitirRefreshToken(
        conn,
        fila.usuario_id,
        fila.familia,
        dispositivo?.uuid ?? null,
        userAgent,
      );

      return {
        access_token: firmarAccessToken(fila, dispositivo?.uuid),
        refresh_token: token,
        refresh_expira: expira.toISOString(),
        usuario: perfilPublico(fila),
        servidor_utc: new Date().toISOString(),
      };
    });
  } finally {
    if (familiaComprometida) {
      await query(
        'UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3) WHERE familia = ? AND revoked_at IS NULL',
        [familiaComprometida.familia],
      );
      logger.warn(familiaComprometida, 'Reutilización de refresh token: se revocó la familia completa');
    }
  }
}

export async function logout({ refresh_token: recibido, todos_los_dispositivos }, usuarioId) {
  if (todos_los_dispositivos) {
    await query(
      'UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3) WHERE usuario_id = ? AND revoked_at IS NULL',
      [usuarioId],
    );
    return { cerradas: 'todas' };
  }
  if (!recibido) throw badRequest('FALTA_TOKEN', 'Envía refresh_token o todos_los_dispositivos=true');
  await query(
    'UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3) WHERE token_hash = ? AND usuario_id = ?',
    [sha256(recibido), usuarioId],
  );
  return { cerradas: 1 };
}

export async function cambiarPassword(usuarioId, { password_actual, password_nueva }) {
  const usuario = await queryOne('SELECT id, password_hash FROM usuarios WHERE id = ?', [usuarioId]);
  if (!usuario) throw notFound('Usuario');
  if (!(await verificarPassword(usuario.password_hash, password_actual))) {
    throw unauthorized('La contraseña actual no es correcta', 'PASSWORD_INCORRECTA');
  }

  return withTransaction(async (conn) => {
    await txExecute(conn, 'UPDATE usuarios SET password_hash = ? WHERE id = ?', [
      await hashearPassword(password_nueva),
      usuarioId,
    ]);
    // Cambiar la contraseña cierra todas las sesiones: es el gesto que hace un
    // usuario cuando cree que le robaron la cuenta.
    await txExecute(
      conn,
      'UPDATE refresh_tokens SET revoked_at = UTC_TIMESTAMP(3) WHERE usuario_id = ? AND revoked_at IS NULL',
      [usuarioId],
    );
    return { ok: true };
  });
}

// La gestión de cuentas (crear, editar, habilitar, horarios, sedes) vive en
// src/modules/empleados.
