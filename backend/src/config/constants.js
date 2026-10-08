/** Constantes de dominio compartidas por todos los módulos. */

/**
 * Roles.
 *
 * `ADMIN` es el **Director General**: ve y gestiona todas las sedes. Se conserva
 * el valor 'ADMIN' en la base para no migrar filas y para que la app vieja lo
 * siga reconociendo como administrador.
 */
export const ROLES = Object.freeze({
  ADMIN: 'ADMIN',
  GERENTE: 'GERENTE',
  AUXILIAR_INVENTARIO: 'AUXILIAR_INVENTARIO',
  VENDEDOR: 'VENDEDOR',
});

export const TODOS_LOS_ROLES = Object.freeze(Object.values(ROLES));

/** Director o gerente: gestionan catálogo, stock y personal (en su alcance). */
export const ROLES_GESTORES = Object.freeze([ROLES.ADMIN, ROLES.GERENTE]);

/** Quién puede cobrar. El auxiliar de inventario no vende. */
export const ROLES_QUE_VENDEN = Object.freeze([ROLES.ADMIN, ROLES.GERENTE, ROLES.VENDEDOR]);

/** Quién carga mercancía que llega del proveedor. */
export const ROLES_QUE_REGISTRAN_ENTRADAS = Object.freeze([
  ROLES.ADMIN,
  ROLES.GERENTE,
  ROLES.AUXILIAR_INVENTARIO,
]);

/** Roles que pertenecen a exactamente una sede. */
export const ROLES_DE_UNA_SEDE = Object.freeze([ROLES.VENDEDOR, ROLES.AUXILIAR_INVENTARIO]);

/**
 * Minutos tras el fin del turno durante los que todavía se acepta subir la cola.
 * Al terminar el turno la app intenta un último envío antes de cerrar sesión;
 * sin este margen, una venta cobrada a las 5:59 se quedaría en el teléfono
 * hasta el día siguiente.
 */
export const GRACIA_CIERRE_TURNO_MIN = 15;

/** Tipos de movimiento y el signo que la aplicación debe imponer a `cantidad`. */
export const TIPOS_MOVIMIENTO = Object.freeze({
  INICIAL: 1,
  ENTRADA: 1,
  DEVOLUCION: 1,
  ANULACION_VENTA: 1,
  SALIDA: -1,
  VENTA: -1,
  MERMA: -1,
  TRASLADO: 0, // el signo lo pone el servidor: − en la sede origen, + en la destino
  AJUSTE: 0, // el signo lo decide el usuario
});

export const METODOS_PAGO = Object.freeze([
  'EFECTIVO',
  'TARJETA',
  'TRANSFERENCIA',
  'MIXTO',
  'CREDITO',
]);

export const TIPOS_CODIGO = Object.freeze([
  'QR',
  'EAN13',
  'EAN8',
  'UPCA',
  'UPCE',
  'CODE128',
  'CODE39',
  'ITF',
  'INTERNO',
]);

export const UNIDADES_MEDIDA = Object.freeze([
  'UND',
  'KG',
  'G',
  'L',
  'ML',
  'M',
  'CAJA',
  'PAQ',
  'DOC',
]);

/**
 * Entidades que participan en la sincronización delta, en el ORDEN en que deben
 * aplicarse en el cliente para no violar claves foráneas.
 */
export const ENTIDADES_SYNC = Object.freeze([
  'configuracion',
  'usuarios',
  'categorias',
  'proveedores',
  'productos',
  'producto_codigos',
  'ventas',
  'venta_detalles',
  'movimientos_inventario',
  'alertas',
]);

/** Operaciones que el cliente puede empujar por `/sync/push`. */
export const OPERACIONES_PUSH = Object.freeze([
  'PRODUCTO_CREAR',
  'PRODUCTO_ACTUALIZAR',
  'PRODUCTO_ELIMINAR',
  'CODIGO_CREAR',
  'CODIGO_ELIMINAR',
  'CATEGORIA_CREAR',
  'CATEGORIA_ACTUALIZAR',
  'CATEGORIA_ELIMINAR',
  'PROVEEDOR_CREAR',
  'PROVEEDOR_ACTUALIZAR',
  'PROVEEDOR_ELIMINAR',
  'METODO_PAGO_CREAR',
  'METODO_PAGO_ACTUALIZAR',
  'METODO_PAGO_ELIMINAR',
  'MOVIMIENTO_CREAR',
  'CONTEO_AJUSTAR',
  'VENTA_CREAR',
  'VENTA_ANULAR',
  'TRASLADO_CREAR',
  'TRASLADO_APROBAR',
  'TRASLADO_RECHAZAR',
  'TRASLADO_CANCELAR',
  'AJUSTE_SOLICITAR',
  'AJUSTE_APROBAR',
  'AJUSTE_RECHAZAR',
  'CIERRE_ABRIR',
  'CIERRE_CERRAR',
  'CIERRE_REVISAR',
  'RECAUDO_CREAR',
  'STOCK_MINIMO_FIJAR',
]);

/** El prefijo `inv://p/{uuid}` identifica un QR emitido por esta app. */
export const QR_PREFIX = 'inv://p/';

export const CONFIG_DEFAULTS = Object.freeze({
  nombre_negocio: 'Mi Negocio',
  nit: '',
  direccion: '',
  telefono: '',
  moneda: 'COP',
  zona_horaria: 'America/Bogota',
  iva_por_defecto: '19.00',
  permitir_stock_negativo: 'true',
  ticket_pie: 'Gracias por su compra',
  offline_grace_days: '7',
});
