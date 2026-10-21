import jwt from 'jsonwebtoken';
import { env } from '../config/env.js';
import { GRACIA_CIERRE_TURNO_MIN } from '../config/constants.js';
import { queryOne } from '../db/pool.js';
import { ApiError, unauthorized, forbidden } from '../utils/ApiError.js';
import { asyncHandler } from '../utils/asyncHandler.js';
import {
  evaluarJornada,
  permitidoConGracia,
  jornadaDe,
  describirInstante,
} from '../domain/jornada.js';
import { cargarAlcance } from '../modules/sedes/repo.js';

/**
 * Error de «fuera de turno». La app lo reconoce por el código y cierra la
 * sesión mostrando cuándo puede volver a entrar.
 */
export function fueraDeHorario(evaluacion) {
  const proximo = evaluacion.proximoInicio;
  return new ApiError(
    403,
    'FUERA_DE_HORARIO',
    proximo
      ? `Estás fuera de tu horario de trabajo. Puedes volver a entrar el ${describirInstante(proximo, env.BUSINESS_TIMEZONE)}.`
      : 'Estás fuera de tu horario de trabajo. Pide a tu gerente que te dé acceso.',
    { proximo_inicio: proximo ? proximo.toISOString() : null },
  );
}

/**
 * Cuenta con su empresa y el permiso de la empresa sobre Inventario. La usan
 * el middleware (en cada petición), el login y la renovación del token.
 */
export function cargarUsuarioDeSesion(uuid) {
  return queryOne(
    `SELECT u.id, u.uuid, u.empresa_id, u.nombre, u.email, u.rol, u.activo, u.pausa_inventario,
            u.restringir_horario, u.horario, u.acceso_extra_hasta,
            e.estado AS empresa_estado, e.deleted_at AS empresa_borrada,
            ea.activo AS app_habilitada
       FROM usuarios u
       LEFT JOIN empresas e ON e.id = u.empresa_id
       LEFT JOIN empresa_aplicativos ea ON ea.empresa_id = u.empresa_id AND ea.aplicativo = 'INVENTARIO'
      WHERE u.uuid = ? AND u.deleted_at IS NULL AND u.es_superadmin = 0`,
    [uuid],
  );
}

/**
 * Las puertas, en el orden en que conviene explicarlas: cuenta, empresa, app
 * de la empresa y rol de la persona en esta app. Cada una con su código, para
 * que la app muestre una pantalla clara y no un error genérico.
 */
export function exigirAccesoInventario(usuario) {
  if (!usuario.activo) throw forbidden('La cuenta está desactivada', 'CUENTA_DESACTIVADA');
  if (!usuario.empresa_id || usuario.empresa_borrada) {
    throw forbidden('Tu empresa ya no está registrada en la plataforma', 'EMPRESA_INEXISTENTE');
  }
  if (usuario.empresa_estado !== 'ACTIVA') {
    throw forbidden(
      'Tu empresa está suspendida. Comunícate con el equipo de la plataforma.',
      'EMPRESA_SUSPENDIDA',
    );
  }
  if (!usuario.app_habilitada) {
    throw forbidden('Tu empresa no tiene habilitada la app de Inventario', 'APP_NO_HABILITADA');
  }
  if (!usuario.rol) {
    throw forbidden(
      'Tu cuenta no tiene acceso a Inventario. Pídeselo al administrador de tu empresa.',
      'SIN_ACCESO_APP',
    );
  }
  if (usuario.pausa_inventario) {
    throw forbidden(
      'Tu cuenta está en pausa en Ventario porque el plan de tu empresa no alcanza para todos. Pídele al administrador que te active.',
      'SIN_ACCESO_APP',
    );
  }
}

/**
 * Verifica el access token y adjunta `req.usuario`, `req.empresaId` y `req.alcance`.
 *
 * Se consulta el usuario en cada petición en lugar de confiar sólo en el
 * payload del JWT: un usuario desactivado, eliminado o que terminó su turno
 * debe perder el acceso de inmediato, no cuando caduque su token 15 minutos
 * después.
 *
 * @param conGracia  admite unos minutos tras el fin del turno. Lo usa la
 *                   sincronización, para el último envío antes de salir.
 */
const crearAutenticador = (conGracia) =>
  asyncHandler(async (req, _res, next) => {
    const cabecera = req.headers.authorization || '';
    const [esquema, token] = cabecera.split(' ');

    if (esquema !== 'Bearer' || !token) {
      throw unauthorized('Falta el encabezado Authorization: Bearer <token>');
    }

    let payload;
    try {
      payload = jwt.verify(token, env.JWT_ACCESS_SECRET, { algorithms: ['HS256'] });
    } catch (err) {
      if (err.name === 'TokenExpiredError') {
        throw unauthorized('El token expiró', 'TOKEN_EXPIRADO');
      }
      throw unauthorized('Token inválido', 'TOKEN_INVALIDO');
    }

    const usuario = await cargarUsuarioDeSesion(payload.sub);

    if (!usuario) throw unauthorized('El usuario ya no existe', 'USUARIO_INEXISTENTE');
    exigirAccesoInventario(usuario);

    const ahora = new Date();
    const jornada = jornadaDe(usuario);
    const permitido = conGracia
      ? permitidoConGracia(jornada, ahora, env.BUSINESS_TIMEZONE, GRACIA_CIERRE_TURNO_MIN)
      : evaluarJornada(jornada, ahora, env.BUSINESS_TIMEZONE).permitido;
    if (!permitido) throw fueraDeHorario(evaluarJornada(jornada, ahora, env.BUSINESS_TIMEZONE));

    req.usuario = usuario;
    req.empresaId = Number(usuario.empresa_id);
    req.alcance = await cargarAlcance(usuario);
    req.dispositivoUuid = req.headers['x-dispositivo'] || payload.dispositivo || null;
    next();
  });

export const autenticar = crearAutenticador(false);
export const autenticarConGracia = crearAutenticador(true);

/** Igual que `autenticar`, pero no falla si no hay token (rutas mixtas). */
export const autenticarOpcional = asyncHandler(async (req, _res, next) => {
  if (!req.headers.authorization) return next();
  return autenticar(req, _res, next);
});
