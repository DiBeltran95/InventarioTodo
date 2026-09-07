import { Router } from 'express';
import { z } from 'zod';
import { crearRepositorioSimple } from '../../db/simpleCrud.js';
import { withTransaction } from '../../db/tx.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { soloAdmin } from '../../middleware/rbac.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { ok, creado, lista } from '../../utils/responder.js';

/**
 * Medios de pago del negocio.
 *
 * Son configurables porque no caben en un ENUM: cada tienda cobra por lo suyo
 * —Nequi, Daviplata, una llave Bre-B, un datáfono concreto— y el esquema no
 * puede enumerarlos de antemano.
 *
 * Los **lee cualquiera** (el vendedor los necesita para cobrar) pero sólo el
 * administrador los crea y modifica.
 */
export const repoMetodosPago = crearRepositorioSimple({
  tabla: 'metodos_pago',
  campos: [
    'nombre',
    'tipo',
    'requiere_referencia',
    'qr_url',
    'instrucciones',
    'color',
    'orden',
    'activo',
  ],
  camposBusqueda: ['nombre'],
  orden: 'orden ASC, nombre ASC',
});

export const TIPOS_METODO = ['EFECTIVO', 'TARJETA', 'TRANSFERENCIA', 'CREDITO', 'OTRO'];

const cuerpoCrear = z.object({
  uuid: z.string().uuid().optional(),
  nombre: z.string().min(1).max(60).trim(),

  // El tipo gobierna el COMPORTAMIENTO del cobro, no la etiqueta: EFECTIVO
  // calcula vueltas, TRANSFERENCIA puede mostrar QR, CREDITO deja saldo
  // pendiente. Por eso está acotado aunque el nombre sea libre.
  tipo: z.enum(TIPOS_METODO).default('OTRO'),

  requiere_referencia: z.coerce.boolean().default(false),

  // La sube /uploads/imagen y aquí se guarda su URL pública: el QR lo
  // configura el administrador y lo muestra el vendedor, así que tiene que
  // verse desde cualquier dispositivo.
  qr_url: z.string().url().max(500).nullish().or(z.literal('')),

  instrucciones: z.string().max(200).nullish(),
  color: z
    .string()
    .regex(/^#[0-9A-Fa-f]{6}$/, 'Debe ser un color hexadecimal como #0E6B5C')
    .default('#0E6B5C'),
  orden: z.coerce.number().int().min(0).default(0),
  activo: z.coerce.boolean().default(true),
});

const cuerpoActualizar = cuerpoCrear.partial().omit({ uuid: true });
const paramUuid = z.object({ uuid: z.string().uuid() });

const router = Router();
router.use(autenticar);

router.get(
  '/',
  validar({ query: z.object({ buscar: z.string().max(100).optional() }) }),
  asyncHandler(async (req, res) => {
    const items = await repoMetodosPago.listar({ buscar: req.validated.query.buscar });
    lista(res, items, { total: items.length });
  }),
);

router.get(
  '/:uuid',
  validar({ params: paramUuid }),
  asyncHandler(async (req, res) => ok(res, await repoMetodosPago.obtener(req.params.uuid))),
);

router.post(
  '/',
  soloAdmin,
  validar({ body: cuerpoCrear }),
  asyncHandler(async (req, res) =>
    creado(res, await withTransaction((c) => repoMetodosPago.crear(c, req.body))),
  ),
);

router.patch(
  '/:uuid',
  soloAdmin,
  validar({ params: paramUuid, body: cuerpoActualizar }),
  asyncHandler(async (req, res) =>
    ok(
      res,
      await withTransaction((c) => repoMetodosPago.actualizar(c, req.params.uuid, req.body)),
    ),
  ),
);

router.delete(
  '/:uuid',
  soloAdmin,
  validar({ params: paramUuid }),
  asyncHandler(async (req, res) =>
    ok(res, await withTransaction((c) => repoMetodosPago.eliminar(c, req.params.uuid))),
  ),
);

export default router;
