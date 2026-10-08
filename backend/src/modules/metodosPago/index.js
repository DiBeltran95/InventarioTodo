import { Router } from 'express';
import { z } from 'zod';
import { crearRepositorioSimple } from '../../db/simpleCrud.js';
import { withTransaction, txQueryOne } from '../../db/tx.js';
import { forbidden, notFound } from '../../utils/ApiError.js';
import { ROLES } from '../../config/constants.js';
import { veSede } from '../../domain/alcance.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { soloGestor } from '../../middleware/rbac.js';
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
    // NULL = todas las sedes. Una sede con su propio Nequi/QR tiene su medio.
    'sede_id',
    // Sólo CREDITO (Addi, Crediya…): comisión que retiene y días en que paga.
    'comision_pct',
    'dias_pago',
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
  // null = todas las sedes.
  sede_uuid: z.string().uuid().nullish(),
  comision_pct: z.coerce.number().min(0).max(100).nullish(),
  dias_pago: z.coerce.number().int().min(0).max(365).nullish(),
});

/**
 * Traduce `sede_uuid` a `sede_id` y comprueba que quien edita pueda tocar ese
 * medio:
 *   · Director: cualquiera, también los comunes a todas las sedes.
 *   · Gerente: sólo los de sus sedes. Un medio común lo afecta en sedes que no
 *     gestiona, así que no lo crea ni lo cambia.
 */
async function prepararMetodo(conn, datos, ctx, actual = null) {
  const salida = { ...datos };
  if (datos.sede_uuid !== undefined) {
    if (datos.sede_uuid === null || datos.sede_uuid === '') {
      salida.sede_id = null;
    } else {
      const sede = await txQueryOne(conn, 'SELECT id FROM sedes WHERE uuid = ? AND deleted_at IS NULL', [
        datos.sede_uuid,
      ]);
      if (!sede) throw notFound('Sede');
      salida.sede_id = sede.id;
    }
  }
  delete salida.sede_uuid;

  if (ctx?.rol !== ROLES.ADMIN) {
    const sedeFinal = salida.sede_id !== undefined ? salida.sede_id : actual?.sede_id ?? null;
    const sedeAntes = actual ? actual.sede_id : sedeFinal;
    if (sedeFinal == null || sedeAntes == null) {
      throw forbidden('Los medios comunes a todas las sedes los gestiona el Director General', 'SIN_PERMISO');
    }
    if (!veSede(ctx.alcance, sedeFinal) || !veSede(ctx.alcance, sedeAntes)) {
      throw forbidden('Ese medio de pago es de una sede que no gestionas', 'SEDE_FUERA_DE_ALCANCE');
    }
  }
  return salida;
}

const metodoActual = (conn, uuid) =>
  txQueryOne(conn, 'SELECT id, uuid, nombre, sede_id FROM metodos_pago WHERE uuid = ?', [uuid]);

async function auditar(conn, ctx, uuid, accion, despues) {
  await registrarAuditoria(conn, {
    usuarioId: ctx?.usuarioId,
    sedeId: despues?.sede_id ?? null,
    dispositivoUuid: ctx?.dispositivoUuid,
    accion: ACCIONES.MEDIO_PAGO_CAMBIADO,
    entidad: 'metodos_pago',
    entidadUuid: uuid,
    despues: { operacion: accion, ...despues },
  });
}

export async function guardarMetodo(conn, datos, ctx) {
  const actual = datos.uuid ? await metodoActual(conn, datos.uuid) : null;
  const preparado = await prepararMetodo(conn, datos, ctx, actual);
  const fila = await repoMetodosPago.crearOActualizar(conn, preparado);
  await auditar(conn, ctx, fila.uuid, actual ? 'editar' : 'crear', preparado);
  return fila;
}

export async function actualizarMetodo(conn, uuid, datos, ctx) {
  const actual = await metodoActual(conn, uuid);
  if (!actual) throw notFound('Medio de pago');
  const preparado = await prepararMetodo(conn, datos, ctx, actual);
  const fila = await repoMetodosPago.actualizar(conn, uuid, preparado);
  await auditar(conn, ctx, uuid, 'editar', preparado);
  return fila;
}

export async function eliminarMetodo(conn, uuid, ctx) {
  const actual = await metodoActual(conn, uuid);
  if (!actual) throw notFound('Medio de pago');
  await prepararMetodo(conn, {}, ctx, actual);
  const r = await repoMetodosPago.eliminar(conn, uuid);
  await auditar(conn, ctx, uuid, 'eliminar', { nombre: actual.nombre });
  return r;
}

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

const ctxDe = (req) => ({
  usuarioId: req.usuario.id,
  rol: req.usuario.rol,
  alcance: req.alcance,
  dispositivoUuid: req.dispositivoUuid,
});

router.post(
  '/',
  soloGestor,
  validar({ body: cuerpoCrear }),
  asyncHandler(async (req, res) =>
    creado(res, await withTransaction((c) => guardarMetodo(c, req.body, ctxDe(req)))),
  ),
);

router.patch(
  '/:uuid',
  soloGestor,
  validar({ params: paramUuid, body: cuerpoActualizar }),
  asyncHandler(async (req, res) =>
    ok(res, await withTransaction((c) => actualizarMetodo(c, req.params.uuid, req.body, ctxDe(req)))),
  ),
);

router.delete(
  '/:uuid',
  soloGestor,
  validar({ params: paramUuid }),
  asyncHandler(async (req, res) =>
    ok(res, await withTransaction((c) => eliminarMetodo(c, req.params.uuid, ctxDe(req)))),
  ),
);

export default router;
