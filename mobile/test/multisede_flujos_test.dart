import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/database/app_database.dart';
import 'package:inventario_pos/core/database/daos/ajustes_dao.dart';
import 'package:inventario_pos/core/database/daos/cierres_dao.dart';
import 'package:inventario_pos/core/database/daos/inventario_dao.dart';
import 'package:inventario_pos/core/database/daos/outbox_dao.dart';
import 'package:inventario_pos/core/database/daos/recaudos_dao.dart';
import 'package:inventario_pos/core/database/daos/sync_dao.dart';
import 'package:inventario_pos/core/database/daos/traslados_dao.dart';
import 'package:inventario_pos/core/database/daos/ventas_dao.dart';
import 'package:inventario_pos/core/money/money.dart';

/// Flujos multisede de punta a punta contra SQLite en memoria: lo que el
/// teléfono escribe —stock por sede, cola de salida, autor— cuando se traslada,
/// se ajusta, se vende o se cobra a una entidad.
///
/// Sede A = la activa del teléfono; sede B = otra que el gerente también ve.
void main() {
  late AppDatabase db;
  late OutboxDao outbox;
  late InventarioDao inventario;

  const a = 'sede-a';
  const b = 'sede-b';
  const gerente = 'u-gerente';
  const vendedor = 'u-vendedor';
  const auxiliar = 'u-auxiliar';

  Future<void> comoUsuario(String uuid) => (db.update(db.estadoApp)..where((t) => t.id.equals(1)))
      .write(EstadoAppCompanion(usuarioUuid: Value(uuid)));

  Future<int> stock(String sede) => inventario.stockEnSede('p1', sede);
  Future<int> stockProyectado() async =>
      (await (db.select(db.productos)..where((t) => t.uuid.equals('p1'))).getSingle()).stockActual;

  Future<List<({String tipo, Map<String, dynamic> payload})>> cola() async => [
        for (final o in await (db.select(db.syncOutbox)..orderBy([(t) => OrderingTerm.asc(t.id)])).get())
          (tipo: o.tipo, payload: jsonDecode(o.payload) as Map<String, dynamic>),
      ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    outbox = OutboxDao(db);
    inventario = InventarioDao(db, outbox);

    await db.batch((x) {
      x.insertAll(db.sedes, [
        SedesCompanion.insert(uuid: a, nombre: 'Centro', codigo: 'CEN', esPrincipal: const Value(true)),
        SedesCompanion.insert(uuid: b, nombre: 'Norte', codigo: 'NOR'),
      ]);
      x.insertAll(db.usuarios, [
        UsuariosCompanion.insert(
            uuid: gerente, nombre: 'Gina Gerente', email: 'g@x.co', rol: const Value('GERENTE'), sedes: const Value('$a,$b')),
        UsuariosCompanion.insert(
            uuid: vendedor, nombre: 'Vico Vendedor', email: 'v@x.co', rol: const Value('VENDEDOR'), sedes: const Value(a)),
        UsuariosCompanion.insert(
            uuid: auxiliar,
            nombre: 'Ana Auxiliar',
            email: 'a@x.co',
            rol: const Value('AUXILIAR_INVENTARIO'),
            sedes: const Value(a)),
      ]);
      // 10 unidades en A (la activa, también en productos.stockActual) y 5 en B.
      x.insert(
        db.productos,
        ProductosCompanion.insert(
          uuid: 'p1',
          sku: 'P1',
          nombre: 'Arroz',
          stockActual: const Value(10000),
          precioVenta: const Value(500000),
          precioCompra: const Value(300000),
        ),
      );
      x.insertAll(db.stockSedes, [
        StockSedesCompanion.insert(productoUuid: 'p1', sedeUuid: a, stockActual: const Value(10000)),
        StockSedesCompanion.insert(productoUuid: 'p1', sedeUuid: b, stockActual: const Value(5000)),
      ]);
    });
    await (db.update(db.estadoApp)..where((t) => t.id.equals(1))).write(
      const EstadoAppCompanion(sedeActivaUuid: Value(a), prefijoFolio: Value('T1')),
    );
  });

  tearDown(() => db.close());

  group('Traslados', () {
    late TrasladosDao traslados;
    setUp(() => traslados = TrasladosDao(db, outbox, inventario));

    test('lo pide un vendedor, lo aprueba el gerente y el stock se mueve en las dos sedes', () async {
      await comoUsuario(vendedor);
      final uuid = await traslados.crear(
        sedeOrigenUuid: b,
        sedeDestinoUuid: a,
        lineas: [LineaTraslado(productoUuid: 'p1', descripcion: 'Arroz', cantidad: Cantidad.unidades(3))],
      );
      expect(await stock(a), 10000, reason: 'pedirlo no mueve nada');

      // Quien lo pidió no puede aprobarlo.
      await expectLater(traslados.aprobar(uuid), throwsStateError);

      await comoUsuario(gerente);
      await traslados.aprobar(uuid);

      expect(await stock(b), 2000);
      expect(await stock(a), 13000);
      expect(await stockProyectado(), 13000, reason: 'A es la sede activa: el catálogo lo refleja');

      final ops = await cola();
      expect(ops.map((o) => o.tipo), ['TRASLADO_CREAR', 'TRASLADO_APROBAR']);
      expect(ops.first.payload['usuario_uuid'], vendedor);
      expect(ops.last.payload['usuario_uuid'], gerente);
      expect((ops.last.payload['movimientos'] as List).single, containsPair('detalle_uuid', isA<String>()));

      final t = await (db.select(db.traslados)..where((x) => x.uuid.equals(uuid))).getSingle();
      expect(t.estado, 'APROBADO');
      expect(t.confirma, 'GESTOR');
      final eventos = await (db.select(db.trasladoEventos)..where((x) => x.trasladoUuid.equals(uuid))).get();
      expect(eventos.map((e) => (e.evento, e.usuarioUuid)), [('CREADO', vendedor), ('APROBADO', gerente)]);
    });

    test('no se aprueba si la sede de origen no tiene suficiente', () async {
      await comoUsuario(vendedor);
      final uuid = await traslados.crear(
        sedeOrigenUuid: b,
        sedeDestinoUuid: a,
        lineas: [LineaTraslado(productoUuid: 'p1', descripcion: 'Arroz', cantidad: Cantidad.unidades(8))],
      );
      await comoUsuario(gerente);

      await expectLater(traslados.aprobar(uuid), throwsA(isA<StateError>()));
      expect(await stock(b), 5000);
      expect(await stock(a), 10000);
      expect((await cola()).map((o) => o.tipo), ['TRASLADO_CREAR'], reason: 'nada a medias en la cola');
    });

    test('el auxiliar no puede pedir traslados', () async {
      await comoUsuario(auxiliar);
      await expectLater(
        traslados.crear(
          sedeOrigenUuid: b,
          sedeDestinoUuid: a,
          lineas: [LineaTraslado(productoUuid: 'p1', descripcion: 'Arroz', cantidad: Cantidad.unidades(1))],
        ),
        throwsStateError,
      );
    });
  });

  group('Solicitudes de ajuste', () {
    late AjustesDao ajustes;
    setUp(() => ajustes = AjustesDao(db, outbox, inventario));

    test('el conteo del auxiliar no toca el stock hasta que el gerente lo aprueba', () async {
      await comoUsuario(auxiliar);
      final uuid = await ajustes.solicitar(productoUuid: 'p1', tipo: 'CONTEO', stockContado: Cantidad.unidades(7));
      expect(await stock(a), 10000);
      expect(await stockProyectado(), 10000);

      await comoUsuario(gerente);
      await ajustes.aprobar(uuid);

      expect(await stock(a), 7000);
      expect(await stockProyectado(), 7000);

      final mov = await (db.select(db.movimientos)..where((m) => m.productoUuid.equals('p1'))).getSingle();
      expect(mov.tipo, 'AJUSTE');
      expect(mov.cantidad, -3000);
      expect(mov.usuarioUuid, auxiliar, reason: 'el movimiento es de quien contó');
      expect(mov.aprobadoPorUuid, gerente);
      expect(mov.sedeUuid, a);

      final ops = await cola();
      expect(ops.first.tipo, 'AJUSTE_SOLICITAR');
      expect(ops.first.payload['sede_uuid'], a);
      expect(ops.last.tipo, 'AJUSTE_APROBAR');
    });

    test('quien pide el ajuste no puede aprobárselo', () async {
      await comoUsuario(gerente);
      final uuid = await ajustes.solicitar(productoUuid: 'p1', tipo: 'MERMA', cantidad: Cantidad.unidades(1));
      await expectLater(ajustes.aprobar(uuid), throwsStateError);
      expect(await stock(a), 10000);
    });
  });

  group('Venta con caja abierta', () {
    test('queda en la sede activa y en el turno de la caja; la otra sede no se toca', () async {
      await comoUsuario(vendedor);
      final cierres = CierresDao(db, outbox);
      final turno = await cierres.abrir(baseEfectivo: Money.parse('50000'));

      final ventas = VentasDao(db, outbox, inventario);
      final venta = await ventas.registrarVenta(
        lineas: [
          LineaParaVender(
            productoUuid: 'p1',
            descripcion: 'Arroz',
            sku: 'P1',
            cantidad: Cantidad.unidades(2),
            precioUnitario: Money.parse('5000'),
            costoUnitario: Money.parse('3000'),
            tasaIva: const TasaIva.cero(),
          ),
        ],
        usuarioUuid: vendedor,
      );

      expect(venta.venta.sedeUuid, a);
      expect(venta.venta.turnoUuid, turno);
      expect(await stock(a), 8000);
      expect(await stockProyectado(), 8000);
      expect(await stock(b), 5000);

      final op = (await cola()).firstWhere((o) => o.tipo == 'VENTA_CREAR');
      expect(op.payload['sede_uuid'], a);
      expect(op.payload['turno_uuid'], turno);
      expect(op.payload['usuario_uuid'], vendedor);
    });
  });

  group('Cuentas por cobrar', () {
    test('el pago de la entidad salda primero las ventas más antiguas', () async {
      await comoUsuario(gerente);
      await db.batch((x) {
        x.insert(db.metodosPago, MetodosPagoCompanion.insert(uuid: 'addi', nombre: 'Addi', tipo: const Value('CREDITO')));
        for (final (i, monto) in [(1, 100000), (2, 50000)]) {
          x.insert(
            db.ventas,
            VentasCompanion.insert(
              uuid: 'v$i',
              numero: 'V-$i',
              sedeUuid: const Value(a),
              fecha: DateTime.utc(2026, 10, i),
              fechaLocal: '2026-10-0$i',
              total: Value(monto),
            ),
          );
          x.insert(
            db.ventaPagos,
            VentaPagosCompanion.insert(
              uuid: 'pago$i',
              ventaUuid: 'v$i',
              metodoPagoUuid: const Value('addi'),
              metodoNombre: 'Addi',
              metodoTipo: const Value('CREDITO'),
              monto: monto,
            ),
          );
        }
      });

      final recaudos = RecaudosDao(db, outbox);
      final cuenta = (await recaudos.observarCuentas().first).single;
      expect(cuenta.total.centavos, 150000);

      // Llegan $1.200 netos más $100 de comisión: saldan la primera ($1.000)
      // y $300 de la segunda.
      final r = await recaudos.registrar(cuenta: cuenta, monto: Money(120000), comision: Money(10000));
      expect(r.aplicadas, 2);

      final pagos = {for (final p in await db.select(db.ventaPagos).get()) p.uuid: p.cobrado};
      expect(pagos, {'pago1': 100000, 'pago2': 30000});
      expect((await recaudos.observarCuentas().first).single.total.centavos, 20000);

      final op = (await cola()).single;
      expect(op.tipo, 'RECAUDO_CREAR');
      expect(op.payload['aplicaciones'], hasLength(2));

      // Más de lo que se debe: se rechaza sin tocar nada.
      final resto = (await recaudos.observarCuentas().first).single;
      await expectLater(
        recaudos.registrar(cuenta: resto, monto: Money(50000), comision: const Money.cero()),
        throwsStateError,
      );
    });
  });

  group('Cambio de sede de un empleado', () {
    test('al cambiar el alcance se descarta lo sincronizado y se conserva lo pendiente', () async {
      await comoUsuario(vendedor);
      await db.batch((x) {
        x.insertAll(db.ventas, [
          VentasCompanion.insert(
            uuid: 'subida',
            numero: 'V-1',
            sedeUuid: const Value(a),
            fecha: DateTime.utc(2026, 10, 1),
            fechaLocal: '2026-10-01',
            sincronizadaEn: Value(DateTime.utc(2026, 10, 1, 1)),
          ),
          VentasCompanion.insert(
            uuid: 'sin-subir',
            numero: 'V-2',
            sedeUuid: const Value(a),
            fecha: DateTime.utc(2026, 10, 2),
            fechaLocal: '2026-10-02',
          ),
        ]);
      });

      final sync = SyncDao(db);
      expect(await sync.alcanceCambio('nuevo'), isTrue);
      await sync.reiniciarPorAlcance('nuevo');

      final quedan = (await db.select(db.ventas).get()).map((v) => v.uuid);
      expect(quedan, ['sin-subir'], reason: 'una venta sin subir es el único ejemplar de ese dinero');
      expect(await sync.alcanceCambio('nuevo'), isFalse, reason: 'la huella queda guardada: sin bucle');
    });

    test('si su usuario baja con otra sede, el teléfono pasa a operar en ella', () async {
      await comoUsuario(vendedor);
      final sync = SyncDao(db);
      expect(await sync.asegurarSedeActiva(), isNull, reason: 'sigue en su sede');

      // El gerente de Norte aceptó su cambio: la fila de usuario baja así.
      await (db.update(db.usuarios)..where((u) => u.uuid.equals(vendedor)))
          .write(const UsuariosCompanion(sedes: Value(b)));

      expect(await sync.asegurarSedeActiva(), b);
      final estado = await (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingle();
      expect(estado.sedeActivaUuid, b);
      expect(await stockProyectado(), 5000, reason: 'el catálogo muestra el stock de Norte');
    });
  });
}
