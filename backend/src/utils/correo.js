/**
 * Correo saliente.
 *
 * Solo se usa para recuperar la contraseña. Con SMTP configurado se envía con
 * nodemailer; sin él, en desarrollo el mensaje va al log (para probar el flujo
 * completo sin un servidor de correo) y en producción se rechaza: decirle a
 * alguien «te enviamos un código» que nunca sale es peor que un error claro.
 */
import { env } from '../config/env.js';
import { logger } from './logger.js';
import { ApiError } from './ApiError.js';

let transporte = null;

async function obtenerTransporte() {
  if (transporte) return transporte;
  const { default: nodemailer } = await import('nodemailer');
  transporte = nodemailer.createTransport({
    host: env.SMTP_HOST,
    port: env.SMTP_PORT,
    secure: env.SMTP_SEGURO,
    auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASSWORD } : undefined,
  });
  return transporte;
}

export const correoConfigurado = () => !!env.SMTP_HOST;

export async function enviarCorreo({ para, asunto, texto }) {
  if (!correoConfigurado()) {
    if (env.isProd) {
      throw new ApiError(503, 'CORREO_NO_DISPONIBLE', 'El envío de correos no está configurado', null, {
        permanente: false,
      });
    }
    logger.warn({ para, asunto, texto }, 'Correo NO enviado (sin SMTP_HOST): se muestra solo en desarrollo');
    return;
  }
  const t = await obtenerTransporte();
  await t.sendMail({ from: env.CORREO_REMITENTE, to: para, subject: asunto, text: texto });
}
