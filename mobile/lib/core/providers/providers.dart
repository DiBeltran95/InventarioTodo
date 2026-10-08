import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/datos_negocio.dart';
import '../database/app_database.dart';
import '../database/daos/ajustes_dao.dart';
import '../database/daos/categorias_dao.dart';
import '../database/daos/cierres_dao.dart';
import '../database/daos/inventario_dao.dart';
import '../database/daos/metodos_pago_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../database/daos/productos_dao.dart';
import '../database/daos/proveedores_dao.dart';
import '../database/daos/recaudos_dao.dart';
import '../database/daos/reportes_dao.dart';
import '../database/daos/sedes_dao.dart';
import '../database/daos/sync_dao.dart';
import '../database/daos/traslados_dao.dart';
import '../database/daos/ventas_dao.dart';
import '../network/api_client.dart';
import '../network/token_store.dart';
import '../sync/connectivity_service.dart';
import '../sync/estado_sync.dart';
import '../sync/sync_engine.dart';

/// Inyección de dependencias.
///
/// `appDatabaseProvider` y `apiClientProvider` se sobrescriben en `main()` con
/// las instancias ya inicializadas: abrir la base y leer el almacén seguro son
/// operaciones asíncronas y no pueden ocurrir dentro de un provider síncrono.

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('Sobrescribe appDatabaseProvider en main()');
});

final tokenStoreProvider = Provider<TokenStore>((ref) {
  throw UnimplementedError('Sobrescribe tokenStoreProvider en main()');
});

final apiClientProvider = Provider<ApiClient>((ref) {
  throw UnimplementedError('Sobrescribe apiClientProvider en main()');
});

// ── DAOs ─────────────────────────────────────────────────────────────────────

final outboxDaoProvider = Provider<OutboxDao>(
  (ref) => OutboxDao(ref.watch(appDatabaseProvider)),
);

final productosDaoProvider = Provider<ProductosDao>(
  (ref) => ProductosDao(ref.watch(appDatabaseProvider), ref.watch(outboxDaoProvider)),
);

final inventarioDaoProvider = Provider<InventarioDao>(
  (ref) => InventarioDao(ref.watch(appDatabaseProvider), ref.watch(outboxDaoProvider)),
);

final ventasDaoProvider = Provider<VentasDao>(
  (ref) => VentasDao(
    ref.watch(appDatabaseProvider),
    ref.watch(outboxDaoProvider),
    ref.watch(inventarioDaoProvider),
  ),
);

final categoriasDaoProvider = Provider<CategoriasDao>(
  (ref) => CategoriasDao(ref.watch(appDatabaseProvider), ref.watch(outboxDaoProvider)),
);

final metodosPagoDaoProvider = Provider<MetodosPagoDao>(
  (ref) => MetodosPagoDao(ref.watch(appDatabaseProvider), ref.watch(outboxDaoProvider)),
);

final proveedoresDaoProvider = Provider<ProveedoresDao>(
  (ref) => ProveedoresDao(ref.watch(appDatabaseProvider), ref.watch(outboxDaoProvider)),
);

final syncDaoProvider = Provider<SyncDao>(
  (ref) => SyncDao(ref.watch(appDatabaseProvider)),
);

final reportesDaoProvider = Provider<ReportesDao>(
  (ref) => ReportesDao(ref.watch(appDatabaseProvider)),
);

final sedesDaoProvider = Provider<SedesDao>(
  (ref) => SedesDao(ref.watch(appDatabaseProvider), ref.watch(syncDaoProvider)),
);

final trasladosDaoProvider = Provider<TrasladosDao>(
  (ref) => TrasladosDao(
    ref.watch(appDatabaseProvider),
    ref.watch(outboxDaoProvider),
    ref.watch(inventarioDaoProvider),
  ),
);

final ajustesDaoProvider = Provider<AjustesDao>(
  (ref) => AjustesDao(
    ref.watch(appDatabaseProvider),
    ref.watch(outboxDaoProvider),
    ref.watch(inventarioDaoProvider),
  ),
);

final cierresDaoProvider = Provider<CierresDao>(
  (ref) => CierresDao(ref.watch(appDatabaseProvider), ref.watch(outboxDaoProvider)),
);

final recaudosDaoProvider = Provider<RecaudosDao>(
  (ref) => RecaudosDao(ref.watch(appDatabaseProvider), ref.watch(outboxDaoProvider)),
);

// ── Sedes ────────────────────────────────────────────────────────────────────

/// Sede en la que opera este teléfono.
final sedeActivaProvider = StreamProvider<Sede?>(
  (ref) => ref.watch(sedesDaoProvider).observarSedeActiva(),
);

/// Todas las sedes activas del negocio (para elegir destino de un traslado o
/// pedir un cambio de sede).
final sedesActivasProvider = StreamProvider<List<Sede>>(
  (ref) => ref.watch(sedesDaoProvider).observarActivas(),
);

/// Índice uuid → sede, también inactivas, para mostrar nombres.
final indiceSedesProvider = StreamProvider<Map<String, Sede>>(
  (ref) => ref.watch(sedesDaoProvider).observarIndice(),
);

// ── Sincronización ───────────────────────────────────────────────────────────

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final servicio = ConnectivityService(ref.watch(apiClientProvider));
  ref.onDispose(servicio.dispose);
  return servicio;
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final motor = SyncEngine(
    db: ref.watch(appDatabaseProvider),
    api: ref.watch(apiClientProvider),
    outbox: ref.watch(outboxDaoProvider),
    sync: ref.watch(syncDaoProvider),
    ventas: ref.watch(ventasDaoProvider),
    productos: ref.watch(productosDaoProvider),
    metodosPago: ref.watch(metodosPagoDaoProvider),
    conectividad: ref.watch(connectivityServiceProvider),
  );
  ref.onDispose(motor.dispose);
  return motor;
});

/// Estado del chip de sincronización. Es un `ChangeNotifier`, así que se
/// escucha con un `StreamController` puente para exponerlo como provider.
final estadoSyncProvider = StreamProvider<EstadoSync>((ref) {
  final motor = ref.watch(syncEngineProvider);
  final controlador = StreamController<EstadoSync>();

  void emitir() {
    if (!controlador.isClosed) controlador.add(motor.estado);
  }

  motor.addListener(emitir);
  emitir();

  ref.onDispose(() {
    motor.removeListener(emitir);
    controlador.close();
  });

  return controlador.stream;
});

/// Operaciones que el servidor rechazó de forma definitiva.
final operacionesRechazadasProvider = StreamProvider(
  (ref) => ref.watch(outboxDaoProvider).observarRechazadas(),
);

// ── Configuración del negocio ────────────────────────────────────────────────

final configuracionProvider = StreamProvider<Map<String, String>>(
  (ref) => ref.watch(syncDaoProvider).observarConfiguracion(),
);

/// Identidad del negocio para el ticket: nombre, NIT, contacto y pie.
///
/// Sale de la configuración que baja en el pull, así que el comprobante se
/// imprime igual de completo en modo avión.
final datosNegocioProvider = Provider<DatosNegocio>((ref) {
  return ref.watch(configuracionProvider).maybeWhen(
        data: DatosNegocio.desdeConfig,
        orElse: () => const DatosNegocio(nombre: 'Mi Negocio'),
      );
});

/// Datos del ticket de una venta: los del negocio con la dirección y el
/// teléfono de la sede donde se vendió.
final datosTicketProvider = Provider.family<DatosNegocio, String?>((ref, sedeUuid) {
  final base = ref.watch(datosNegocioProvider);
  if (sedeUuid == null) return base;
  final sede = ref.watch(indiceSedesProvider).value?[sedeUuid];
  if (sede == null) return base;
  final varias = (ref.watch(sedesActivasProvider).value?.length ?? 0) > 1;
  return base.conSede(nombre: varias ? sede.nombre : null, direccion: sede.direccion, telefono: sede.telefono);
});

final nombreNegocioProvider = Provider<String>(
  (ref) => ref.watch(datosNegocioProvider).nombre,
);

/// Nombre de cada usuario, indexado por UUID.
///
/// Sale de SQLite —los usuarios llegan en el pull, igual que el catálogo—, así
/// que el historial sigue diciendo quién hizo cada venta aunque no haya red.
/// Es una tabla pequeña: se lee entera una vez y la lista de ventas la consulta
/// en memoria, en lugar de hacer un join por fila.
final nombresUsuariosProvider = StreamProvider<Map<String, String>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.usuarios).watch().map(
        (filas) => {for (final u in filas) u.uuid: u.nombre},
      );
});

/// Medios de pago activos, en el orden configurado.
///
/// Sale de SQLite, así que el vendedor puede cobrar **sin conexión** con los
/// medios que su negocio tenga registrados.
final metodosPagoActivosProvider = StreamProvider<List<MetodoPago>>(
  (ref) => ref.watch(metodosPagoDaoProvider).observarActivos(),
);

final metodosPagoTodosProvider = StreamProvider<List<MetodoPagoConUso>>(
  (ref) => ref.watch(metodosPagoDaoProvider).observarTodos(),
);

/// ¿Este negocio fía?
///
/// Viene apagado: el fiado obliga a llevar cuentas por cobrar, y una tienda que
/// no fía no debería ver esa opción al cobrar.
final permiteCreditoProvider = Provider<bool>((ref) {
  return ref.watch(configuracionProvider).maybeWhen(
        data: (c) => c['permite_credito'] == 'true',
        orElse: () => false,
      );
});

/// Estado del dispositivo: prefijo de folio, último sync, usuario activo.
final estadoAppProvider = StreamProvider<EstadoAppData?>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.estadoApp)..where((t) => t.id.equals(1))).watchSingleOrNull();
});
