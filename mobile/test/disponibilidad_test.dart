import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/database/app_database.dart';
import 'package:inventario_pos/core/database/daos/outbox_dao.dart';
import 'package:inventario_pos/core/database/daos/productos_dao.dart';
import 'package:inventario_pos/core/database/daos/sedes_dao.dart';
import 'package:inventario_pos/core/database/daos/sync_dao.dart';
import 'package:inventario_pos/core/money/money.dart';
import 'package:inventario_pos/core/negocio/traslados.dart';
import 'package:inventario_pos/features/auth/domain/sesion.dart';
import 'package:inventario_pos/features/disponibilidad/presentation/disponibilidad_widgets.dart';

/// «¿Dónde hay?»: búsqueda de un producto y sus existencias en todas las sedes.
void main() {
  late AppDatabase db;
  late SedesDao sedes;
  late ProductosDao productos;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sedes = SedesDao(db, SyncDao(db));
    productos = ProductosDao(db, OutboxDao(db));

    Insertable<Producto> producto(String uuid, String nombre, String sku) => ProductosCompanion.insert(
          uuid: uuid,
          sku: sku,
          nombre: nombre,
          nombreBusqueda: Value(normalizarBusqueda(nombre)),
          precioVenta: const Value(89900000),
        );

    await db.batch((b) {
      b.insertAll(db.sedes, [
        SedesCompanion.insert(uuid: 'centro', nombre: 'Centro', codigo: 'CEN', esPrincipal: const Value(true)),
        SedesCompanion.insert(uuid: 'norte', nombre: 'Norte', codigo: 'NOR'),
        SedesCompanion.insert(uuid: 'sur', nombre: 'Sur', codigo: 'SUR'),
        SedesCompanion.insert(uuid: 'cerrada', nombre: 'Cerrada', codigo: 'CER', activo: const Value(false)),
      ]);
      b.insertAll(db.productos, [
        producto('a17', 'Celular Samsung Galaxy A17 128 GB', 'SAM-A17'),
        producto('a25', 'Celular Samsung Galaxy A25', 'SAM-A25'),
        producto('moto', 'Celular Motorola G24', 'MOT-G24'),
      ]);
      b.insertAll(db.stockSedes, [
        StockSedesCompanion.insert(productoUuid: 'a17', sedeUuid: 'centro'),
        StockSedesCompanion.insert(productoUuid: 'a17', sedeUuid: 'norte', stockActual: const Value(3000)),
        StockSedesCompanion.insert(
          productoUuid: 'a17',
          sedeUuid: 'sur',
          stockActual: const Value(1000),
          stockMinimo: const Value(2000),
        ),
        StockSedesCompanion.insert(productoUuid: 'a17', sedeUuid: 'cerrada', stockActual: const Value(9000)),
        StockSedesCompanion.insert(
          productoUuid: 'a25',
          sedeUuid: 'centro',
          stockActual: const Value(1000),
          stockMinimo: const Value(2000),
        ),
      ]);
    });
  });

  tearDown(() => db.close());

  test('la búsqueda acepta las palabras en cualquier orden', () async {
    final porNombre = await productos.observar(busqueda: 'samsung a17').first;
    expect(porNombre.map((p) => p.uuid), ['a17']);
    expect((await productos.observar(busqueda: 'a17 samsung').first).map((p) => p.uuid), ['a17']);
    expect((await productos.observar(busqueda: 'galaxy').first).map((p) => p.uuid).toSet(), {'a17', 'a25'});
    expect((await productos.observar(busqueda: 'samsung moto').first), isEmpty);
  });

  test('existencias por sede: sólo sedes activas, la principal primero', () async {
    final mapa = await sedes.observarDisponibilidad(['a17', 'a25', 'moto']).first;

    expect(mapa['a17']!.map((f) => (f.sede.uuid, f.stock.milesimas)), [
      ('centro', 0),
      ('norte', 3000),
      ('sur', 1000),
    ], reason: 'la sede desactivada no se ofrece');
    expect(mapa['a25']!.single.sede.uuid, 'centro');
    expect(mapa.containsKey('moto'), isFalse, reason: 'sin fila en ninguna sede');
  });

  test('el stock bajo se limita a las sedes de quien mira', () async {
    final todas = await sedes.observarStockBajo().first;
    expect(todas.map((s) => (s.producto.uuid, s.sede.uuid)).toSet(), {('a17', 'sur'), ('a25', 'centro')});

    final soloCentro = await sedes.observarStockBajo(sedes: ['centro']).first;
    expect(soloCentro.map((s) => s.sede.uuid), ['centro']);
  });

  group('acción que se ofrece sobre cada sede', () {
    StockEnSede fila(String sede, int unidades) => StockEnSede(
          sede: Sede(uuid: sede, nombre: sede, codigo: sede, esPrincipal: false, activo: true, updatedAt: DateTime(2026)),
          stock: Cantidad.unidades(unidades),
        );

    AccionSede? accion(RolUsuario rol, Set<String>? suyas, StockEnSede f) => accionSobreSede(
          actor: Actor(uuid: 'u', rol: rol, sedes: suyas),
          fila: f,
          misSedes: suyas ?? const {},
        );

    test('el vendedor sólo consulta', () {
      expect(accion(RolUsuario.vendedor, {'centro'}, fila('norte', 3)), isNull);
    });

    test('el gerente solicita desde otra sede, nunca desde la suya ni sin unidades', () {
      expect(accion(RolUsuario.gerente, {'centro'}, fila('norte', 3)), AccionSede.solicitar);
      expect(accion(RolUsuario.gerente, {'centro'}, fila('centro', 3)), isNull);
      expect(accion(RolUsuario.gerente, {'centro'}, fila('norte', 0)), isNull);
    });

    test('el director mueve desde cualquier sede; el auxiliar, desde la suya', () {
      expect(accion(RolUsuario.director, null, fila('norte', 3)), AccionSede.mover);
      expect(accion(RolUsuario.auxiliarInventario, {'centro'}, fila('centro', 3)), AccionSede.mover);
      expect(accion(RolUsuario.auxiliarInventario, {'centro'}, fila('norte', 3)), isNull);
    });
  });
}
