import { Router } from 'express';
import multer from 'multer';
import path from 'node:path';
import fs from 'node:fs';
import { randomUUID } from 'node:crypto';
import { env } from '../../config/env.js';
import { autenticar } from '../../middleware/auth.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { badRequest } from '../../utils/ApiError.js';
import { creado } from '../../utils/responder.js';

const DIRECTORIO = path.resolve(env.UPLOAD_DIR);
fs.mkdirSync(DIRECTORIO, { recursive: true });

const EXTENSIONES = new Map([
  ['image/jpeg', '.jpg'],
  ['image/png', '.png'],
  ['image/webp', '.webp'],
]);

const almacenamiento = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, DIRECTORIO),
  /**
   * Nombre aleatorio con extensión derivada del MIME declarado.
   * Nunca se usa `file.originalname`: viene del cliente y podría contener
   * `../` o una doble extensión como `foto.jpg.html`.
   */
  filename: (_req, file, cb) => cb(null, `${randomUUID()}${EXTENSIONES.get(file.mimetype) ?? '.bin'}`),
});

const subida = multer({
  storage: almacenamiento,
  limits: { fileSize: env.MAX_UPLOAD_MB * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (!EXTENSIONES.has(file.mimetype)) {
      return cb(badRequest('FORMATO_NO_SOPORTADO', 'Sólo se aceptan imágenes JPEG, PNG o WebP'));
    }
    return cb(null, true);
  },
});

const router = Router();
router.use(autenticar);

/**
 * POST /uploads/imagen
 *
 * La app sube la foto del producto cuando recupera la red; mientras tanto la
 * conserva en el almacenamiento local y muestra esa copia. Por eso la respuesta
 * incluye la URL definitiva: el cliente la guarda en `productos.imagen_url` y
 * la sincroniza como cualquier otro campo.
 */
router.post(
  '/imagen',
  subida.single('imagen'),
  asyncHandler(async (req, res) => {
    if (!req.file) throw badRequest('SIN_ARCHIVO', 'Envía el archivo en el campo "imagen"');
    const url = `${env.PUBLIC_BASE_URL.replace(/\/$/, '')}/uploads/${req.file.filename}`;
    creado(res, {
      url,
      nombre: req.file.filename,
      tamano: req.file.size,
      tipo: req.file.mimetype,
    });
  }),
);

export default router;
export { DIRECTORIO as directorioUploads };
