import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Base local SQLite — **fuente de verdad del dispositivo**.
///
/// La UI nunca hace una petición HTTP para pintarse: lee de aquí. La red sólo
/// alimenta estas tablas. Ése es todo el secreto del modo offline.
///
/// Convenciones que replican el servidor:
///  · `uuid` (v7, generado en el cliente) es la clave primaria de negocio.
///  · El dinero se guarda como INTEGER de centavos; las cantidades, como
///    INTEGER de milésimas. Nunca REAL: ver core/money/money.dart.
///  · `fechaLocal` es TEXT 'AAAA-MM-DD' en la zona de la tienda, para que los
///    reportes por día no se partan a medianoche UTC.
///  · Borrado lógico (`deletedAt`) en todo lo sincronizable.

// ─── Catálogo ────────────────────────────────────────────────────────────────

class Usuarios extends Table {
  TextColumn get uuid => text()();
  TextColumn get nombre => text()();
  TextColumn get email => text()();
  TextColumn get rol => text().withDefault(const Constant('VENDEDOR'))();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();

  /// Hash PBKDF2 de la contraseña, calculado **en el dispositivo** con su
  /// propia sal. Permite iniciar sesión sin red. El hash del servidor jamás
  /// viaja hasta aquí: si robaran el teléfono, no obtendrían la credencial del
  /// servidor, sólo un derivado local.
  TextColumn get passwordHashLocal => text().nullable()();
  TextColumn get saltLocal => text().nullable()();

  /// Jornada: con la restricción activa, sólo se puede trabajar dentro de los
  /// tramos de `horario` (JSON) o con un acceso extra vigente. Baja con el
  /// usuario para que el teléfono cierre la sesión al final del turno aunque
  /// no haya red.
  BoolColumn get restringirHorario => boolean().withDefault(const Constant(false))();
  TextColumn get horario => text().nullable()();
  DateTimeColumn get accesoExtraHasta => dateTime().nullable()();

  /// UUID de sus sedes, separados por coma. Vacío para el Director General.
  TextColumn get sedes => text().withDefault(const Constant(''))();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

class Categorias extends Table {
  TextColumn get uuid => text()();
  TextColumn get nombre => text()();
  TextColumn get descripcion => text().nullable()();
  TextColumn get color => text().withDefault(const Constant('#6750A4'))();
  TextColumn get icono => text().nullable()();
  IntColumn get orden => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

// Sin esto Drift generaría `Proveedore`: su singularización quita la «s» final
// sin saber español.
@DataClassName('Proveedor')
class Proveedores extends Table {
  TextColumn get uuid => text()();
  TextColumn get nombre => text()();
  TextColumn get nit => text().nullable()();
  TextColumn get contacto => text().nullable()();
  TextColumn get telefono => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get direccion => text().nullable()();
  TextColumn get notas => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

@TableIndex(name: 'idx_productos_nombre', columns: {#nombre})
@TableIndex(name: 'idx_productos_sku', columns: {#sku})
@TableIndex(name: 'idx_productos_stock', columns: {#stockActual})
class Productos extends Table {
  TextColumn get uuid => text()();
  TextColumn get sku => text()();
  TextColumn get nombre => text()();

  /// Copia en minúsculas y sin tildes de `nombre`, para que la búsqueda
  /// «gaseosa» encuentre «Gaseosa» y «cafe» encuentre «Café» sin recorrer
  /// 10.000 filas en Dart. SQLite no normaliza Unicode por su cuenta.
  TextColumn get nombreBusqueda => text().withDefault(const Constant(''))();

  TextColumn get descripcion => text().nullable()();
  TextColumn get categoriaUuid => text().nullable()();
  TextColumn get unidadMedida => text().withDefault(const Constant('UND'))();

  IntColumn get precioCompra => integer().withDefault(const Constant(0))();
  IntColumn get precioVenta => integer().withDefault(const Constant(0))();
  IntColumn get tasaIva => integer().withDefault(const Constant(1900))();

  /// Proyección local. Sólo la escribe `InventarioDao._aplicarMovimiento`.
  ///
  /// Desde la versión multisede es el stock de la **sede activa** del
  /// dispositivo, no el total: la venta, el escáner y las alertas del catálogo
  /// siguen leyendo esta columna sin saber de sedes. El de cada sede está en
  /// `StockSedes`.
  IntColumn get stockActual => integer().withDefault(const Constant(0))();

  /// Mínimo efectivo en la sede activa: el propio de la sede o, si no tiene,
  /// el general.
  IntColumn get stockMinimo => integer().withDefault(const Constant(0))();

  /// Mínimo general del producto, tal como lo define el catálogo.
  IntColumn get stockMinimoGeneral => integer().withDefault(const Constant(0))();
  IntColumn get stockMaximo => integer().nullable()();

  TextColumn get imagenUrl => text().nullable()();

  /// Ruta en el almacenamiento del dispositivo mientras la foto no se ha
  /// subido. La app muestra ésta hasta que la sincronización devuelve la URL.
  TextColumn get imagenLocal => text().nullable()();

  TextColumn get ubicacion => text().nullable()();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

@TableIndex(name: 'idx_codigos_codigo', columns: {#codigo}, unique: true)
class ProductoCodigos extends Table {
  TextColumn get uuid => text()();
  TextColumn get productoUuid => text()();
  TextColumn get codigo => text()();
  TextColumn get tipo => text().withDefault(const Constant('INTERNO'))();
  BoolColumn get esPrincipal => boolean().withDefault(const Constant(false))();

  /// Unidades que representa el código: la caja de 12 lleva `12000` (12,000).
  IntColumn get factor => integer().withDefault(const Constant(1000))();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

// ─── Operación ───────────────────────────────────────────────────────────────

@TableIndex(name: 'idx_ventas_fecha', columns: {#fechaLocal})
@TableIndex(name: 'idx_ventas_pendiente', columns: {#sincronizadaEn})
class Ventas extends Table {
  TextColumn get uuid => text()();
  TextColumn get numero => text()();
  TextColumn get usuarioUuid => text().nullable()();
  TextColumn get dispositivoUuid => text().nullable()();
  TextColumn get sedeUuid => text().nullable()();

  /// Caja (cierres_caja.uuid) en la que se cobró.
  TextColumn get turnoUuid => text().nullable()();
  TextColumn get clienteNombre => text().nullable()();
  TextColumn get clienteDocumento => text().nullable()();

  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  IntColumn get descuentoTotal => integer().withDefault(const Constant(0))();
  IntColumn get impuestoTotal => integer().withDefault(const Constant(0))();
  IntColumn get total => integer().withDefault(const Constant(0))();
  IntColumn get costoTotal => integer().withDefault(const Constant(0))();

  TextColumn get metodoPago => text().withDefault(const Constant('EFECTIVO'))();
  IntColumn get montoRecibido => integer().nullable()();
  IntColumn get cambio => integer().nullable()();

  TextColumn get estado => text().withDefault(const Constant('COMPLETADA'))();
  TextColumn get anulaAVentaUuid => text().nullable()();
  TextColumn get motivoAnulacion => text().nullable()();
  TextColumn get notas => text().nullable()();

  DateTimeColumn get fecha => dateTime()();
  TextColumn get fechaLocal => text()();
  BoolColumn get creadaOffline => boolean().withDefault(const Constant(true))();

  /// `null` mientras la venta no haya llegado al servidor. Es lo que cuenta el
  /// chip «N pendientes».
  DateTimeColumn get sincronizadaEn => dateTime().nullable()();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

@TableIndex(name: 'idx_detalles_venta', columns: {#ventaUuid})
class VentaDetalles extends Table {
  TextColumn get uuid => text()();
  TextColumn get ventaUuid => text()();
  TextColumn get productoUuid => text().nullable()();
  IntColumn get linea => integer().withDefault(const Constant(1))();

  /// Instantánea del nombre al momento de vender: si mañana renombran el
  /// producto, el ticket histórico no debe cambiar.
  TextColumn get descripcion => text()();
  TextColumn get skuSnapshot => text().nullable()();

  IntColumn get cantidad => integer()();
  IntColumn get precioUnitario => integer()();
  IntColumn get costoUnitario => integer().withDefault(const Constant(0))();
  IntColumn get descuento => integer().withDefault(const Constant(0))();
  IntColumn get tasaIva => integer().withDefault(const Constant(0))();
  IntColumn get baseGravable => integer().withDefault(const Constant(0))();
  IntColumn get impuesto => integer().withDefault(const Constant(0))();
  IntColumn get total => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {uuid};
}

@TableIndex(name: 'idx_mov_producto', columns: {#productoUuid})
@TableIndex(name: 'idx_mov_fecha', columns: {#fechaLocal})
class Movimientos extends Table {
  TextColumn get uuid => text()();
  TextColumn get productoUuid => text()();
  TextColumn get tipo => text()();

  /// Con signo: positivo suma stock, negativo lo resta.
  IntColumn get cantidad => integer()();

  IntColumn get costoUnitario => integer().nullable()();
  IntColumn get precioUnitario => integer().nullable()();
  IntColumn get stockAnterior => integer().nullable()();
  IntColumn get stockResultante => integer().nullable()();

  TextColumn get ventaUuid => text().nullable()();
  TextColumn get sedeUuid => text().nullable()();
  TextColumn get trasladoUuid => text().nullable()();
  TextColumn get proveedorUuid => text().nullable()();
  TextColumn get usuarioUuid => text().nullable()();

  /// Quién aprobó el ajuste cuando lo solicitó un auxiliar de inventario.
  TextColumn get aprobadoPorUuid => text().nullable()();
  TextColumn get lote => text().nullable()();
  TextColumn get venceEl => text().nullable()();
  TextColumn get documentoRef => text().nullable()();
  TextColumn get motivo => text().nullable()();

  DateTimeColumn get fecha => dateTime()();
  TextColumn get fechaLocal => text()();
  BoolColumn get creadoOffline => boolean().withDefault(const Constant(true))();
  DateTimeColumn get sincronizadoEn => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

class Alertas extends Table {
  TextColumn get uuid => text()();
  TextColumn get tipo => text()();
  TextColumn get severidad => text().withDefault(const Constant('ADVERTENCIA'))();
  TextColumn get productoUuid => text().nullable()();
  TextColumn get sedeUuid => text().nullable()();
  TextColumn get ventaUuid => text().nullable()();
  TextColumn get mensaje => text()();
  DateTimeColumn get resueltaEn => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {uuid};
}

/// Medios de pago del negocio.
///
/// Bajan del servidor como el resto del catálogo, así que el vendedor puede
/// cobrar **sin conexión** con los medios que su negocio tenga configurados.
@DataClassName('MetodoPago')
class MetodosPago extends Table {
  TextColumn get uuid => text()();
  TextColumn get nombre => text()();

  /// EFECTIVO · TARJETA · TRANSFERENCIA · CREDITO · OTRO
  ///
  /// El nombre es libre («Nequi», «Llave Bre-B»); el tipo es lo acotado, porque
  /// gobierna el comportamiento del cobro: sólo EFECTIVO calcula vueltas, sólo
  /// CREDITO deja saldo pendiente.
  TextColumn get tipo => text().withDefault(const Constant('OTRO'))();

  BoolColumn get requiereReferencia => boolean().withDefault(const Constant(false))();

  /// URL del QR que el vendedor le muestra al cliente. Es del servidor y no una
  /// ruta local a propósito: lo configura el administrador desde su teléfono y
  /// tiene que verse en el del vendedor.
  TextColumn get qrUrl => text().nullable()();

  /// Copia del QR ya descargada. Sin ella, mostrarlo exigiría red justo en el
  /// momento de cobrar, que es cuando menos se puede depender de ella.
  TextColumn get qrLocal => text().nullable()();

  TextColumn get instrucciones => text().nullable()();

  /// Sede a la que pertenece; null = todas. Una sede con su propio Nequi tiene
  /// su propio medio, con su QR.
  TextColumn get sedeUuid => text().nullable()();

  /// Sólo entidades de crédito (Addi, Crediya…): comisión que retienen, en
  /// centésimas de punto (5 % = 500), y días en que suelen pagar.
  IntColumn get comisionPct => integer().nullable()();
  IntColumn get diasPago => integer().nullable()();
  TextColumn get color => text().withDefault(const Constant('#0E6B5C'))();
  IntColumn get orden => integer().withDefault(const Constant(0))();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

/// Desglose del cobro de una venta: con qué medios se pagó y cuánto por cada
/// uno. La suma de los montos es igual a `ventas.total`.
@DataClassName('VentaPago')
@TableIndex(name: 'idx_pagos_venta', columns: {#ventaUuid})
class VentaPagos extends Table {
  TextColumn get uuid => text()();
  TextColumn get ventaUuid => text()();
  TextColumn get metodoPagoUuid => text().nullable()();

  /// Instantánea del nombre, igual que `venta_detalles.descripcion`. Si mañana
  /// se renombra «Nequi» o se da de baja, el ticket histórico NO debe cambiar.
  TextColumn get metodoNombre => text()();
  TextColumn get metodoTipo => text().withDefault(const Constant('OTRO'))();

  IntColumn get monto => integer()();

  /// Sólo en efectivo. Van por pago y no por venta porque en un cobro mixto
  /// únicamente una parte se paga en efectivo.
  IntColumn get montoRecibido => integer().nullable()();
  IntColumn get cambio => integer().nullable()();

  TextColumn get referencia => text().nullable()();

  /// Cuánto pagó ya la entidad de crédito (bruto, con su comisión).
  IntColumn get cobrado => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {uuid};
}

// ─── Multisede ───────────────────────────────────────────────────────────────

class Sedes extends Table {
  TextColumn get uuid => text()();
  TextColumn get nombre => text()();
  TextColumn get codigo => text()();
  TextColumn get direccion => text().nullable()();
  TextColumn get telefono => text().nullable()();
  BoolColumn get esPrincipal => boolean().withDefault(const Constant(false))();
  BoolColumn get activo => boolean().withDefault(const Constant(true))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

/// Stock de cada producto en cada sede visible para el usuario.
///
/// La sede activa se proyecta además en `productos.stockActual`; esta tabla es
/// la que leen las vistas multisede (stock bajo por sede, traslados, inicio
/// del director).
@DataClassName('StockSede')
class StockSedes extends Table {
  TextColumn get productoUuid => text()();
  TextColumn get sedeUuid => text()();
  IntColumn get stockActual => integer().withDefault(const Constant(0))();

  /// Mínimo propio de la sede; null = usa el general del producto.
  IntColumn get stockMinimo => integer().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {productoUuid, sedeUuid};
}

class Traslados extends Table {
  TextColumn get uuid => text()();
  TextColumn get numero => text()();
  TextColumn get sedeOrigenUuid => text()();
  TextColumn get sedeDestinoUuid => text()();

  /// PENDIENTE · APROBADO · RECHAZADO · CANCELADO
  TextColumn get estado => text().withDefault(const Constant('PENDIENTE'))();

  /// GESTOR: lo aprueba un gerente de la sede origen o el director.
  /// ORIGEN: lo confirma alguien de la sede origen.
  TextColumn get confirma => text().withDefault(const Constant('GESTOR'))();
  TextColumn get notas => text().nullable()();
  TextColumn get solicitadoPorUuid => text().nullable()();
  DateTimeColumn get solicitadoEn => dateTime()();
  TextColumn get resueltoPorUuid => text().nullable()();
  DateTimeColumn get resueltoEn => dateTime().nullable()();
  TextColumn get motivoRechazo => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

@DataClassName('TrasladoDetalle')
class TrasladoDetalles extends Table {
  TextColumn get uuid => text()();
  TextColumn get trasladoUuid => text()();
  TextColumn get productoUuid => text().nullable()();
  TextColumn get descripcion => text()();
  IntColumn get cantidad => integer()();

  @override
  Set<Column> get primaryKey => {uuid};
}

@DataClassName('TrasladoEvento')
class TrasladoEventos extends Table {
  TextColumn get uuid => text()();
  TextColumn get trasladoUuid => text()();

  /// CREADO · APROBADO · RECHAZADO · CANCELADO
  TextColumn get evento => text()();
  TextColumn get usuarioUuid => text().nullable()();
  DateTimeColumn get fecha => dateTime()();
  TextColumn get nota => text().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}

/// Conteo, merma o ajuste que pide un auxiliar de inventario. No toca el
/// stock hasta que un gerente lo aprueba.
@DataClassName('SolicitudAjuste')
class SolicitudesAjuste extends Table {
  TextColumn get uuid => text()();
  TextColumn get sedeUuid => text()();
  TextColumn get productoUuid => text()();

  /// CONTEO · MERMA · AJUSTE
  TextColumn get tipo => text()();
  IntColumn get cantidad => integer().nullable()();
  IntColumn get stockContado => integer().nullable()();
  TextColumn get motivo => text().nullable()();

  /// PENDIENTE · APROBADA · RECHAZADA
  TextColumn get estado => text().withDefault(const Constant('PENDIENTE'))();
  TextColumn get solicitadoPorUuid => text().nullable()();
  DateTimeColumn get solicitadoEn => dateTime()();
  TextColumn get resueltoPorUuid => text().nullable()();
  DateTimeColumn get resueltoEn => dateTime().nullable()();
  TextColumn get motivoRechazo => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {uuid};
}

/// Turno de caja: se abre con una base de efectivo y se cierra contando.
@DataClassName('CierreCaja')
class CierresCaja extends Table {
  TextColumn get uuid => text()();
  TextColumn get sedeUuid => text()();
  TextColumn get usuarioUuid => text().nullable()();
  TextColumn get dispositivoUuid => text().nullable()();

  /// ABIERTO · CERRADO
  TextColumn get estado => text().withDefault(const Constant('ABIERTO'))();
  DateTimeColumn get abiertoEn => dateTime()();
  IntColumn get baseEfectivo => integer().withDefault(const Constant(0))();
  DateTimeColumn get cerradoEn => dateTime().nullable()();
  BoolColumn get cierreTardio => boolean().withDefault(const Constant(false))();

  /// Las cifras del servidor, que recalcula lo esperado con las ventas del
  /// turno. Mientras no llegan, la app muestra su propio cálculo.
  IntColumn get esperadoTotal => integer().nullable()();
  IntColumn get contadoTotal => integer().nullable()();
  IntColumn get diferenciaEfectivo => integer().nullable()();

  /// JSON por medio de pago: esperado, contado y diferencia.
  TextColumn get detalle => text().nullable()();
  TextColumn get notas => text().nullable()();
  TextColumn get revisadoPorUuid => text().nullable()();
  DateTimeColumn get revisadoEn => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {uuid};
}

/// Pago recibido de una entidad de crédito (Addi, Crediya…).
class Recaudos extends Table {
  TextColumn get uuid => text()();
  TextColumn get metodoPagoUuid => text()();
  TextColumn get sedeUuid => text().nullable()();
  TextColumn get fecha => text()();
  IntColumn get monto => integer()();
  IntColumn get comision => integer().withDefault(const Constant(0))();
  TextColumn get referencia => text().nullable()();
  TextColumn get notas => text().nullable()();

  /// JSON: a qué pagos se aplicó y cuánto.
  TextColumn get aplicaciones => text().nullable()();
  TextColumn get registradoPorUuid => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {uuid};
}


// ─── Sincronización ──────────────────────────────────────────────────────────

/// Cola de salida.
///
/// Cada mutación local escribe su fila de dominio **y** una fila aquí, dentro
/// de la MISMA transacción. Si la app muere en medio, o se guardan las dos o no
/// se guarda ninguna: nunca queda una venta sin encolar ni un encolado sin venta.
@TableIndex(name: 'idx_outbox_pendientes', columns: {#estado, #proximoIntento})
class SyncOutbox extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Clave de idempotencia. El servidor la usa para no aplicar dos veces el
  /// mismo efecto cuando se pierde la respuesta y el cliente reintenta.
  TextColumn get clientOpId => text().unique()();

  TextColumn get tipo => text()();
  TextColumn get entidad => text()();
  TextColumn get entidadUuid => text().nullable()();
  TextColumn get payload => text()();

  IntColumn get intentos => integer().withDefault(const Constant(0))();
  TextColumn get ultimoError => text().nullable()();
  TextColumn get codigoError => text().nullable()();

  /// PENDIENTE · ENVIANDO · RECHAZADA
  TextColumn get estado => text().withDefault(const Constant('PENDIENTE'))();

  DateTimeColumn get proximoIntento => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get creadoEn => dateTime().withDefault(currentDateAndTime)();
}

/// Cursor keyset por entidad para la bajada delta.
@DataClassName('SyncCursor')
class SyncCursores extends Table {
  TextColumn get entidad => text()();
  DateTimeColumn get cursorT => dateTime()();
  IntColumn get cursorI => integer().withDefault(const Constant(0))();
  DateTimeColumn get ultimoSync => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {entidad};
}

class Configuracion extends Table {
  TextColumn get clave => text()();
  TextColumn get valor => text()();
  TextColumn get tipo => text().withDefault(const Constant('STRING'))();

  @override
  Set<Column> get primaryKey => {clave};
}

/// Estado del dispositivo. Una única fila (id = 1).
class EstadoApp extends Table {
  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get usuarioUuid => text().nullable()();
  TextColumn get dispositivoUuid => text().nullable()();

  /// Prefijo asignado por el servidor para numerar ventas sin colisionar con
  /// otras cajas: `A1-000042`.
  TextColumn get prefijoFolio => text().nullable()();
  IntColumn get secuenciaFolio => integer().withDefault(const Constant(0))();

  /// Hasta cuándo se puede operar sin volver a ver el servidor.
  DateTimeColumn get offlineValidoHasta => dateTime().nullable()();
  DateTimeColumn get ultimoSyncExitoso => dateTime().nullable()();

  /// Sede en la que opera este dispositivo. Lo que se venda o se mueva aquí
  /// es de esa sede.
  TextColumn get sedeActivaUuid => text().nullable()();

  /// Huella del alcance (rol + sedes) con la que se bajaron los datos. Si el
  /// servidor responde con otra, lo que ya no corresponde se descarta.
  TextColumn get alcance => text().nullable()();

  /// Última hora del servidor vista y el desfase del reloj del teléfono
  /// respecto a ella. Sirven para no confiar en un reloj atrasado a propósito
  /// para trabajar fuera de turno.
  DateTimeColumn get horaServidor => dateTime().nullable()();
  IntColumn get desfaseServidorMs => integer().withDefault(const Constant(0))();

  /// Por qué se cerró la sesión a la fuerza (cuenta inhabilitada, fin de
  /// turno). La pantalla de inicio lo muestra una vez.
  TextColumn get motivoCierreSesion => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// ─────────────────────────────────────────────────────────────────────────────

@DriftDatabase(
  tables: [
    Usuarios,
    Categorias,
    Proveedores,
    Productos,
    ProductoCodigos,
    Ventas,
    VentaDetalles,
    VentaPagos,
    MetodosPago,
    Movimientos,
    Alertas,
    Sedes,
    StockSedes,
    Traslados,
    TrasladoDetalles,
    TrasladoEventos,
    SolicitudesAjuste,
    CierresCaja,
    Recaudos,
    SyncOutbox,
    SyncCursores,
    Configuracion,
    EstadoApp,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'inventario_pos'));

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await into(estadoApp).insert(
            const EstadoAppCompanion(id: Value(1)),
            mode: InsertMode.insertOrIgnore,
          );
        },

        /// Actualización del esquema local.
        ///
        /// **Sólo se AÑADE.** En este dispositivo puede haber ventas que aún no
        /// han llegado al servidor: son el único ejemplar que existe de ese
        /// dinero. Borrar y recrear la base para «empezar limpio» las
        /// destruiría sin posibilidad de recuperarlas.
        ///
        /// Sin este bloque, subir `schemaVersion` lanzaría al abrir la app en
        /// cualquier instalación ya existente.
        onUpgrade: (m, desde, hasta) async {
          // v2 · Medios de pago configurables y cobro repartido entre varios.
          if (desde < 2) {
            await m.createTable(metodosPago);
            await m.createTable(ventaPagos);
          }

          // v3 · Multisede: sedes, stock por sede, traslados, horarios,
          // ajustes por aprobación, cierres de caja y cuentas por cobrar.
          if (desde < 3) {
            for (final tabla in <TableInfo>[
              sedes,
              stockSedes,
              traslados,
              trasladoDetalles,
              trasladoEventos,
              solicitudesAjuste,
              cierresCaja,
              recaudos,
            ]) {
              await m.createTable(tabla);
            }
            // Si se viene de v1, las tablas de v2 se acaban de crear con todas
            // sus columnas; si se viene de v2, hay que añadírselas.
            if (desde >= 2) {
              await m.addColumn(metodosPago, metodosPago.sedeUuid);
              await m.addColumn(metodosPago, metodosPago.comisionPct);
              await m.addColumn(metodosPago, metodosPago.diasPago);
              await m.addColumn(ventaPagos, ventaPagos.cobrado);
            }
            await m.addColumn(usuarios, usuarios.restringirHorario);
            await m.addColumn(usuarios, usuarios.horario);
            await m.addColumn(usuarios, usuarios.accesoExtraHasta);
            await m.addColumn(usuarios, usuarios.sedes);
            await m.addColumn(productos, productos.stockMinimoGeneral);
            await m.addColumn(ventas, ventas.sedeUuid);
            await m.addColumn(ventas, ventas.turnoUuid);
            await m.addColumn(movimientos, movimientos.sedeUuid);
            await m.addColumn(movimientos, movimientos.trasladoUuid);
            await m.addColumn(movimientos, movimientos.aprobadoPorUuid);
            await m.addColumn(alertas, alertas.sedeUuid);
            await m.addColumn(estadoApp, estadoApp.sedeActivaUuid);
            await m.addColumn(estadoApp, estadoApp.alcance);
            await m.addColumn(estadoApp, estadoApp.horaServidor);
            await m.addColumn(estadoApp, estadoApp.desfaseServidorMs);
            await m.addColumn(estadoApp, estadoApp.motivoCierreSesion);

            // El mínimo que había era el general.
            await customStatement('UPDATE productos SET stock_minimo_general = stock_minimo');
          }
        },
        beforeOpen: (details) async {
          // Las claves foráneas no están declaradas entre tablas a propósito
          // (la sincronización puede traer un detalle antes que su venta), pero
          // WAL sí importa: permite leer mientras el motor de sincronización
          // escribe, así la lista de productos no se congela durante un pull.
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA synchronous = NORMAL');
          if (details.wasCreated) {
            await into(estadoApp).insert(
              const EstadoAppCompanion(id: Value(1)),
              mode: InsertMode.insertOrIgnore,
            );
          }
        },
      );

  /// Borra todo salvo el estado del dispositivo. Se usa al cerrar sesión de
  /// forma definitiva o al cambiar de servidor.
  Future<void> limpiarDatos() async {
    await transaction(() async {
      // Todas las tablas de datos. Antes faltaban `venta_pagos` y
      // `metodos_pago`: tras «borrar datos» el teléfono seguía mostrando los
      // medios de pago de la base anterior.
      final tablas = <TableInfo<Table, dynamic>>[
        ventaDetalles, ventaPagos, ventas, movimientos, alertas, productoCodigos,
        productos, categorias, proveedores, metodosPago, usuarios, syncOutbox,
        syncCursores, configuracion, sedes, stockSedes, traslados,
        trasladoDetalles, trasladoEventos, solicitudesAjuste, cierresCaja, recaudos,
      ];
      for (final tabla in tablas) {
        await delete(tabla).go();
      }
    });
  }
}

/// Normaliza texto para búsqueda: minúsculas y sin tildes.
///
/// SQLite compara «Café» y «cafe» como distintos, y `LIKE` sin normalizar
/// obligaría al usuario a escribir los acentos exactos. Se guarda una columna
/// ya normalizada en lugar de normalizar en cada consulta.
String normalizarBusqueda(String texto) {
  const conAcento = 'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
  const sinAcento = 'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC';
  final buffer = StringBuffer();
  for (final rune in texto.runes) {
    final ch = String.fromCharCode(rune);
    final i = conAcento.indexOf(ch);
    buffer.write(i >= 0 ? sinAcento[i] : ch);
  }
  return buffer.toString().toLowerCase().trim();
}
