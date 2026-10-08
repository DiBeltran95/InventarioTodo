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
 * Verifica el access token y adjunta `req.usuario` y `req.alcance`.
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

    const usuario = await queryOne(
      `SELECT id, uuid, nombre, email, rol, activo, restringir_horario, horario, acceso_extra_hasta
         FROM usuarios WHERE uuid = ? AND deleted_at IS NULL`,
      [payload.sub],
    );

    if (!usuario) throw unauthorized('El usuario ya no existe', 'USUARIO_INEXISTENTE');
    if (!usuario.activo) throw forbidden('La cuenta está desactivada', 'CUENTA_DESACTIVADA');

    const ahora = new Date();
    const jornada = jornadaDe(usuario);
    const permitido = conGracia
      ? permitidoConGracia(jornada, ahora, env.BUSINESS_TIMEZONE, GRACIA_CIERRE_TURNO_MIN)
      : evaluarJornada(jornada, ahora, env.BUSINESS_TIMEZONE).permitido;
    if (!permitido) throw fueraDeHorario(evaluarJornada(jornada, ahora, env.BUSINESS_TIMEZONE));

    req.usuario = usuario;
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
