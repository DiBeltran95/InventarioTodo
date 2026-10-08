import { Router } from 'express';
import * as servicio from './service.js';
import * as esquemas from './schemas.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { limitadorLogin } from '../../middleware/rateLimit.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { ok, creado } from '../../utils/responder.js';

const router = Router();

/**
 * POST /auth/login
 * Devuelve tokens, perfil, y —si se envía `dispositivo`— el prefijo de folio
 * que ese dispositivo usará para numerar ventas sin conexión.
 */
router.post(
  '/login',
  limitadorLogin,
  validar({ body: esquemas.loginSchema }),
  asyncHandler(async (req, res) => {
    ok(res, await servicio.login(req.body, req.headers['user-agent']));
  }),
);

/** POST /auth/refresh — rotación con detección de reutilización. */
router.post(
  '/refresh',
  validar({ body: esquemas.refreshSchema }),
  asyncHandler(async (req, res) => {
    ok(res, await servicio.refrescar(req.body, req.headers['user-agent']));
  }),
);

router.post(
  '/logout',
  autenticar,
  validar({ body: esquemas.logoutSchema }),
  asyncHandler(async (req, res) => {
    ok(res, await servicio.logout(req.body, req.usuario.id));
  }),
);

/** GET /auth/me — perfil, sedes y jornada. La app lo usa al volver a tener red. */
router.get(
  '/me',
  autenticar,
  asyncHandler(async (req, res) => {
    ok(res, await servicio.perfil(req.usuario, req.alcance, req.dispositivoUuid));
  }),
);

/**
 * POST /auth/sede-activa — el gerente con varias sedes (o el director) cambia
 * la sede en la que opera este teléfono.
 */
router.post(
  '/sede-activa',
  autenticar,
  validar({ body: esquemas.sedeActivaSchema }),
  asyncHandler(async (req, res) => {
    ok(res, await servicio.cambiarSedeActiva(req.alcance, req.dispositivoUuid, req.body.sede_uuid));
  }),
);

router.post(
  '/password',
  autenticar,
  validar({ body: esquemas.cambiarPasswordSchema }),
  asyncHandler(async (req, res) => {
    ok(res, await servicio.cambiarPassword(req.usuario.id, req.body));
  }),
);

// Las cuentas de empleados se gestionan en src/modules/empleados, montado en
// /auth/usuarios para que la app vieja siga encontrándolas.

export default router;
