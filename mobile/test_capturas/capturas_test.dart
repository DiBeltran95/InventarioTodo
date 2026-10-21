// Estudio de capturas para Play Store: renderiza la app REAL con una tienda de
// ejemplo en una base en memoria. No forma parte de `flutter test`.
//
//   flutter test test_capturas --update-goldens
//
// Las imágenes quedan en test_capturas/goldens/.
//
// Vive fuera de test/, así que el analizador no lo trata como prueba.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:inventario_pos/app.dart';
import 'package:inventario_pos/core/database/app_database.dart';
import 'package:inventario_pos/core/database/daos/inventario_dao.dart';
import 'package:inventario_pos/core/database/daos/outbox_dao.dart';
import 'package:inventario_pos/core/database/daos/productos_dao.dart';
import 'package:inventario_pos/core/database/daos/ventas_dao.dart';
import 'package:inventario_pos/core/money/money.dart';
import 'package:inventario_pos/core/network/api_client.dart';
import 'package:inventario_pos/core/network/token_store.dart';
import 'package:inventario_pos/core/providers/providers.dart';
import 'package:inventario_pos/core/router/app_router.dart';
import 'package:inventario_pos/core/sync/estado_sync.dart';
import 'package:inventario_pos/features/auth/domain/sesion.dart';
import 'package:inventario_pos/features/auth/presentation/auth_providers.dart';
import 'package:inventario_pos/features/cuenta/domain/plan.dart';
import 'package:inventario_pos/features/cuenta/presentation/plan_ui.dart';
import 'package:inventario_pos/features/ventas/presentation/carrito_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tam = Size(412, 915);
const _sede = 'sede-centro';
const _director = 'u-director';

Future<void> _cargarFuentes() async {
  final raiz = Platform.environment['FLUTTER_ROOT']!; // lo define `flutter test`
  final dir = '$raiz/bin/cache/artifacts/material_fonts';
  Future<void> registrar(String familia, List<String> archivos) async {
    final loader = FontLoader(familia);
    for (final a in archivos) {
      final bytes = File('$dir/$a').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await registrar('MaterialIcons', ['materialicons-regular.otf']);
  await registrar('Roboto', ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf', 'roboto-black.ttf', 'roboto-light.ttf']);
}

class _SesionFalsa extends SesionNotifier {
  @override
  Future<Sesion?> build() async => const Sesion(
        usuarioUuid: _director,
        nombre: 'Laura Gómez',
        email: 'laura@tiendalaesquina.co',
        rol: RolUsuario.director,
        enLinea: true,
      );
}

const _productos = [
  // uuid, sku, nombre, categoría, precio, costo, stock, mínimo
  ('p01', 'BEB-001', 'Gaseosa Cola 1.5 L', 'c-beb', 6500, 4300, 48, 12),
  ('p02', 'BEB-002', 'Agua sin gas 600 ml', 'c-beb', 2200, 1100, 96, 24),
  ('p03', 'BEB-003', 'Jugo de naranja 1 L', 'c-beb', 7900, 5200, 6, 10),
  ('p04', 'LAC-001', 'Leche entera 1 L', 'c-lac', 4800, 3600, 30, 12),
  ('p05', 'LAC-002', 'Yogur de fresa 200 g', 'c-lac', 2900, 1800, 4, 8),
  ('p06', 'SNA-001', 'Papas fritas 110 g', 'c-sna', 5200, 3100, 40, 10),
  ('p07', 'SNA-002', 'Galletas de chocolate', 'c-sna', 3500, 2100, 55, 15),
  ('p08', 'ASE-001', 'Jabón líquido 500 ml', 'c-ase', 9800, 6400, 18, 6),
  ('p09', 'ASE-002', 'Papel higiénico x4', 'c-ase', 8900, 6100, 25, 10),
  ('p10', 'DES-001', 'Café molido 250 g', 'c-des', 12500, 8700, 22, 8),
  ('p11', 'DES-002', 'Arroz blanco 1 kg', 'c-des', 4600, 3300, 70, 20),
  ('p12', 'DES-003', 'Huevos AA x12', 'c-des', 9500, 7200, 3, 6),
];

Future<AppDatabase> _tienda() async {
  final db = AppDatabase(NativeDatabase.memory());
  await db.batch((x) {
    x.insert(db.sedes, SedesCompanion.insert(uuid: _sede, nombre: 'Sede Centro', codigo: 'CEN', esPrincipal: const Value(true)));
    x.insert(db.usuarios, UsuariosCompanion.insert(uuid: _director, nombre: 'Laura Gómez', email: 'laura@tiendalaesquina.co', rol: const Value('ADMIN')));
    x.insertAll(db.categorias, [
      CategoriasCompanion.insert(uuid: 'c-beb', nombre: 'Bebidas', color: const Value('#1E88E5')),
      CategoriasCompanion.insert(uuid: 'c-lac', nombre: 'Lácteos', color: const Value('#8E24AA')),
      CategoriasCompanion.insert(uuid: 'c-sna', nombre: 'Snacks', color: const Value('#F4511E')),
      CategoriasCompanion.insert(uuid: 'c-ase', nombre: 'Aseo', color: const Value('#00897B')),
      CategoriasCompanion.insert(uuid: 'c-des', nombre: 'Despensa', color: const Value('#6D4C41')),
    ]);
    x.insertAll(db.metodosPago, [
      MetodosPagoCompanion.insert(uuid: 'm-efe', nombre: 'Efectivo', tipo: const Value('EFECTIVO')),
      MetodosPagoCompanion.insert(uuid: 'm-neq', nombre: 'Nequi', tipo: const Value('TRANSFERENCIA')),
    ]);
    for (final p in _productos) {
      x.insert(
        db.productos,
        ProductosCompanion.insert(
          uuid: p.$1,
          sku: p.$2,
          nombre: p.$3,
          nombreBusqueda: Value(p.$3.toLowerCase()),
          categoriaUuid: Value(p.$4),
          precioVenta: Value(p.$5 * 100),
          precioCompra: Value(p.$6 * 100),
          stockActual: Value(p.$7 * 1000),
          stockMinimo: Value(p.$8 * 1000),
          stockMinimoGeneral: Value(p.$8 * 1000),
        ),
      );
      x.insert(db.stockSedes, StockSedesCompanion.insert(productoUuid: p.$1, sedeUuid: _sede, stockActual: Value(p.$7 * 1000)));
    }
    x.insertAll(db.configuracion, [
      ConfiguracionCompanion.insert(clave: 'nombre_negocio', valor: 'Tienda La Esquina'),
      ConfiguracionCompanion.insert(clave: 'moneda', valor: 'COP'),
    ]);
  });
  await (db.update(db.estadoApp)..where((t) => t.id.equals(1))).write(EstadoAppCompanion(
        usuarioUuid: const Value(_director),
        sedeActivaUuid: const Value(_sede),
        prefijoFolio: const Value('T1'),
        ultimoSyncExitoso: Value(DateTime.now().toUtc()),
      ));

  // Ventas del día, por la vía real (folio, stock, movimientos y pagos).
  final outbox = OutboxDao(db);
  final ventas = VentasDao(db, outbox, InventarioDao(db, outbox));
  const canastas = [
    [('p01', 2), ('p06', 1)],
    [('p04', 2), ('p11', 1), ('p10', 1)],
    [('p02', 6)],
    [('p08', 1), ('p09', 2)],
    [('p07', 3), ('p01', 1), ('p05', 2)],
    [('p10', 2), ('p12', 1)],
    [('p03', 1), ('p06', 2), ('p02', 2)],
    [('p11', 3), ('p04', 1)],
  ];
  for (final (i, canasta) in canastas.indexed) {
    final lineas = [
      for (final (uuid, n) in canasta)
        () {
          final p = _productos.firstWhere((x) => x.$1 == uuid);
          return LineaParaVender(
            productoUuid: uuid,
            descripcion: p.$3,
            sku: p.$2,
            cantidad: Cantidad.unidades(n),
            precioUnitario: Money(p.$5 * 100),
            costoUnitario: Money(p.$6 * 100),
            tasaIva: const TasaIva(1900),
          );
        }(),
    ];
    // Sin `pagos`, la venta deriva un pago único por el total.
    await ventas.registrarVenta(
      lineas: lineas,
      metodoPago: i.isEven ? 'EFECTIVO' : 'TRANSFERENCIA',
      usuarioUuid: _director,
    );
  }
  // Como si ya se hubieran subido: sin el aviso de «ventas sin enviar».
  final todas = await db.select(db.ventas).get();
  await ventas.marcarSincronizadas(todas.map((v) => v.uuid));
  await ventas.marcarMovimientosDeVentasSincronizados(todas.map((v) => v.uuid));
  await db.delete(db.syncOutbox).go();
  return db;
}

final _plan = PlanEmpresa.desdeJson({
  'codigo': 'GRATIS',
  'nombre': 'Gratis',
  'sedes': {'usados': 1, 'maximo': 1},
  'personas': {'usados': 2, 'maximo': 3},
  'productos': {'usados': 3, 'maximo': 3},
})!;

void main() {
  late AppDatabase db;
  late ProviderContainer contenedor;

  setUpAll(() async {
    await _cargarFuentes();
    await initializeDateFormatting('es_CO', null);
    Money.locale = 'es_CO';
    Money.simbolo = r'$';
    Money.decimalesVisibles = 0;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    PlanLocal.actual.value = _plan;
    db = await _tienda();
  });

  tearDown(() async {
    contenedor.dispose();
    await db.close();
  });

  Future<void> capturar(WidgetTester t, String nombre, {String? ruta, void Function(ProviderContainer)? preparar}) async {
    t.view.physicalSize = _tam * 2.625;
    t.view.devicePixelRatio = 2.625;
    final tokens = TokenStore();
    contenedor = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      tokenStoreProvider.overrideWithValue(tokens),
      apiClientProvider.overrideWithValue(ApiClient(tokenStore: tokens, urlBase: 'http://127.0.0.1:9')),
      sesionProvider.overrideWith(_SesionFalsa.new),
      estadoSyncProvider.overrideWith((ref) => Stream.value(EstadoSync(fase: FaseSync.alDia, ultimoSync: DateTime.now()))),
      empresaProvider.overrideWith((ref) async => EmpresaInfo(
            uuid: 'e1',
            nombre: 'Tienda La Esquina',
            nit: '900.123.456-7',
            telefono: '300 555 0123',
            plan: _plan,
            aplicativos: const ['INVENTARIO', 'ASISTENCIA'],
          )),
    ]);
    await t.runAsync(() => contenedor.read(sesionProvider.future));
    preparar?.call(contenedor);
    await t.pumpWidget(UncontrolledProviderScope(container: contenedor, child: const InventarioApp()));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await t.pump(const Duration(milliseconds: 200));
    }
    if (ruta != null) {
      contenedor.read(routerProvider).go(ruta);
      for (var i = 0; i < 12; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await t.pump(const Duration(milliseconds: 200));
      }
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$nombre.png'));
  }

  testWidgets('01 inicio', (t) => capturar(t, '01_inicio'));
  testWidgets('02 productos', (t) => capturar(t, '02_productos', ruta: Rutas.productos));
  testWidgets('03 carrito', (t) async {
    final productos = <ProductoConCategoria>[];
    await t.runAsync(() async {
      for (final u in ['p01', 'p06', 'p10', 'p04']) {
        productos.add((await ProductosDao(db, OutboxDao(db)).obtener(u))!);
      }
    });
    await capturar(t, '03_venta', ruta: Rutas.carrito, preparar: (c) {
      final carrito = c.read(carritoProvider.notifier);
      for (final p in productos) {
        carrito.agregar(p);
      }
      carrito.incrementar('p01');
    });
  });
  testWidgets('04 reportes', (t) => capturar(t, '04_reportes', ruta: Rutas.reportes));
  testWidgets('05 mi empresa', (t) => capturar(t, '05_mi_empresa', ruta: Rutas.miEmpresa));
  testWidgets('06 stock bajo', (t) => capturar(t, '06_stock_bajo', ruta: Rutas.stockBajo));
}

// Evita el aviso de import sin uso cuando se comentan capturas.
// ignore: unused_element
GoRouter? _r;
