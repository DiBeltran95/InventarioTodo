import { Router } from 'express';
import { z } from 'zod';
import * as servicio from './service.js';
import { validar } from '../../middleware/validate.js';
import { autenticar } from '../../middleware/auth.js';
import { ocultarCostos, soloGestor } from '../../middleware/rbac.js';
import { asyncHandler } from '../../utils/asyncHandler.js';
import { ok, lista } from '../../utils/responder.js';
import { rangoPeriodo } from '../../utils/dates.js';
import { forbidden, notFound } from '../../utils/ApiError.js';
import { veSede } from '../../domain/alcance.js';
import { sedePorUuid } from '../sedes/repo.js';

const router = Router();
router.use(autenticar);

/**
 * Ámbito de un reporte: todas las sedes del alcance, o una concreta con
 * `?sede=<uuid>`. Pedir una sede ajena es un 403, no un reporte vacío: un
 * vacío haría creer al gerente que esa sede no vendió nada.
 */
router.use(
  asyncHandler(async (req, _res, next) => {
    const uuid = req.query?.sede;
    let sedeId = null;
    if (uuid) {
      const sede = await sedePorUuid(null, uuid);
      if (!sede) throw notFound('Sede');
      if (!veSede(req.alcance, sede.id)) {
        throw forbidden('Esa sede no está en tu alcance', 'SEDE_FUERA_DE_ALCANCE');
      }
      sedeId = Number(sede.id);
    }
    req.ambito = { alcance: req.alcance, sedeId };
    next();
  }),
);

const fecha = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Formato AAAA-MM-DD');
const periodo = z.enum(['hoy', 'ayer', 'semana', 'mes', 'trimestre', 'anio']).optional();
const sede = z.string().uuid().optional();

/**
 * Acepta o bien un periodo con nombre (`hoy`, `semana`, `mes`...) o bien un
 * rango explícito. El periodo se resuelve en la zona del negocio.
 */
const rangoSchema = z
  .object({ periodo, desde: fecha.optional(), hasta: fecha.optional() })
  .transform((v) => {
    if (v.desde && v.hasta) return { desde: v.desde, hasta: v.hasta };
    return rangoPeriodo(v.periodo ?? 'mes');
  })
  .refine((v) => v.desde <= v.hasta, { message: '`desde` no puede ser posterior a `hasta`' });

const consultaRango = z.object({ periodo, desde: fecha.optional(), hasta: fecha.optional(), sede });

const rangoDe = (q) => rangoSchema.parse({ periodo: q.periodo, desde: q.desde, hasta: q.hasta });

router.get(
  '/dashboard',
  validar({ query: z.object({ sede }) }),
  asyncHandler(async (req, res) => {
    ok(res, ocultarCostos(await servicio.dashboard(req.ambito), req.usuario.rol));
  }),
);

router.get(
  '/ventas',
  validar({ query: consultaRango.extend({ agrupar: z.enum(['dia', 'semana', 'mes']).default('dia') }) }),
  asyncHandler(async (req, res) => {
    const rango = rangoDe(req.validated.query);
    const { agrupar } = req.validated.query;
    const items = await servicio.ventasPorPeriodo({ ...rango, agrupar }, req.ambito);
    lista(res, ocultarCostos(items, req.usuario.rol), { ...rango, agrupar });
  }),
);

/** GET /reportes/por-sede — ventas de cada sede del alcance en el periodo. */
router.get(
  '/por-sede',
  soloGestor,
  validar({ query: consultaRango }),
  asyncHandler(async (req, res) => {
    const rango = rangoDe(req.validated.query);
    lista(res, await servicio.ventasPorSede(rango, req.ambito), rango);
  }),
);

router.get(
  '/metodos-pago',
  validar({ query: consultaRango }),
  asyncHandler(async (req, res) => {
    // Antes llamaba a una función `rango` que no existía: la ruta respondía
    // 500 en cada petición.
    const rango = rangoDe(req.validated.query);
    lista(res, await servicio.ingresosPorMetodoPago(rango, req.ambito), rango);
  }),
);

router.get(
  '/top-productos',
  validar({
    query: consultaRango.extend({
      limite: z.coerce.number().int().min(1).max(100).default(10),
      por: z.enum(['unidades', 'ingreso', 'margen']).default('unidades'),
    }),
  }),
  asyncHandler(async (req, res) => {
    const { limite, por } = req.validated.query;
    const rango = rangoDe(req.validated.query);
    const items = await servicio.topProductos({ ...rango, limite, por }, req.ambito);
    lista(res, ocultarCostos(items, req.usuario.rol), { ...rango, por });
  }),
);

/**
 * GET /reportes/por-empleado — control de cajas. Sólo gestores.
 *
 * Un vendedor no debe poder comparar su rendimiento con el de sus compañeros ni
 * ver los márgenes del negocio, así que la ruta entera queda cerrada en lugar de
 * filtrar columnas.
 */
router.get(
  '/por-empleado',
  soloGestor,
  validar({ query: consultaRango }),
  asyncHandler(async (req, res) => {
    const rango = rangoDe(req.validated.query);
    lista(res, await servicio.ventasPorEmpleado(rango, req.ambito), rango);
  }),
);

router.get(
  '/stock-bajo',
  validar({ query: z.object({ limite: z.coerce.number().int().min(1).max(500).default(50), sede }) }),
  asyncHandler(async (req, res) => {
    const items = await servicio.stockBajo({ limite: req.validated.query.limite }, req.ambito);
    lista(res, ocultarCostos(items, req.usuario.rol), { total: items.length });
  }),
);

router.get(
  '/valorizacion',
  validar({ query: z.object({ sede }) }),
  asyncHandler(async (req, res) => {
    ok(res, ocultarCostos(await servicio.valorizacion(req.ambito), req.usuario.rol));
  }),
);

router.get(
  '/movimientos',
  validar({ query: consultaRango }),
  asyncHandler(async (req, res) => {
    const rango = rangoDe(req.validated.query);
    const items = await servicio.movimientosResumen(rango, req.ambito);
    lista(res, ocultarCostos(items, req.usuario.rol), rango);
  }),
);

export default router;
