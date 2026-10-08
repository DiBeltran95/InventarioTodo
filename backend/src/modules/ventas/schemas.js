import { z } from 'zod';
import { METODOS_PAGO } from '../../config/constants.js';
import { dinero, cantidad } from '../productos/schemas.js';

export const lineaVentaSchema = z.object({
  uuid: z.string().uuid().optional(),
  producto_uuid: z.string().uuid(),
  cantidad,
  /**
   * UUID del movimiento de inventario que el dispositivo ya escribió en local.
   * Sin esto el servidor inventa otro uuid, el pull lo baja como fila nueva y
   * la app muestra la venta duplicada en el kardex (con nube de sync en la
   * copia local).
   */
  movimiento_uuid: z.string().uuid().optional(),
  /**
   * Opcionales: si no vienen, se toman del producto en el servidor.
   * Una venta creada sin conexión SÍ debe enviarlos: son el precio y el costo
   * que estaban vigentes en el dispositivo al momento de cobrar, y el ticket ya
   * impreso los usó.
   */
  precio_unitario: dinero.optional(),
  costo_unitario: dinero.optional(),
  descuento: dinero.default('0.00'),
  tasa_iva: z.union([z.string(), z.number()]).optional(),
  descripcion: z.string().max(200).optional(),
});

export const crearVentaSchema = z.object({
  uuid: z.string().uuid().optional(),
  /** Folio generado por el dispositivo cuando la venta se hizo sin conexión. */
  numero: z
    .string()
    .max(30)
    .regex(/^[A-Z0-9]{1,6}-\d{1,10}$/, 'Formato de folio esperado: PREFIJO-000001')
    .optional(),
  cliente_nombre: z.string().max(150).nullish(),
  cliente_documento: z.string().max(40).nullish(),
  /** Caja (turno) abierta de quien cobra: la usa el cierre de caja. */
  turno_uuid: z.string().uuid().nullish(),
  metodo_pago: z.enum(METODOS_PAGO).default('EFECTIVO'),
  monto_recibido: dinero.nullish(),

  /**
   * Desglose del cobro: con qué medios se pagó y cuánto por cada uno.
   *
   * Es **opcional a propósito**. Una app anterior a esta funcionalidad manda
   * sólo `metodo_pago`, y esas ventas deben seguir entrando igual: en ese caso
   * el servidor deriva un único pago por el total. Rechazarlas dejaría ventas
   * atrapadas en la cola de dispositivos que aún no se han actualizado.
   */
  pagos: z
    .array(
      z.object({
        uuid: z.string().uuid().optional(),
        metodo_pago_uuid: z.string().uuid().nullish(),
        metodo_nombre: z.string().min(1).max(60),
        metodo_tipo: z
          .enum(['EFECTIVO', 'TARJETA', 'TRANSFERENCIA', 'CREDITO', 'OTRO'])
          .default('OTRO'),
        monto: dinero,
        monto_recibido: dinero.nullish(),
        cambio: dinero.nullish(),
        referencia: z.string().max(80).nullish(),
      }),
    )
    .min(1)
    .max(10)
    .optional(),
  notas: z.string().max(500).nullish(),
  fecha: z.string().datetime({ offset: true }).optional(),
  fecha_local: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  creada_offline: z.boolean().default(false),
  lineas: z.array(lineaVentaSchema).min(1, 'La venta debe tener al menos una línea').max(300),
});

export const anularVentaSchema = z.object({
  motivo: z.string().min(3).max(255),
  uuid_reversa: z.string().uuid().optional(),
  /** UUID del movimiento ANULACION_VENTA por producto, generados en el cliente. */
  movimientos: z
    .array(
      z.object({
        producto_uuid: z.string().uuid(),
        movimiento_uuid: z.string().uuid(),
      }),
    )
    .optional(),
  fecha: z.string().datetime({ offset: true }).optional(),
  fecha_local: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  creada_offline: z.boolean().default(false),
});

export const filtrosVentaSchema = z.object({
  estado: z.enum(['COMPLETADA', 'ANULADA', 'todas']).default('COMPLETADA'),
  incluir_reversas: z
    .enum(['true', 'false'])
    .default('false')
    .transform((v) => v === 'true'),
  desde: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  hasta: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  usuario: z.string().uuid().optional(),
  buscar: z.string().max(60).optional(),
  pagina: z.coerce.number().int().min(1).default(1),
  limite: z.coerce.number().int().min(1).max(200).default(50),
});

export const paramUuid = z.object({ uuid: z.string().uuid() });
