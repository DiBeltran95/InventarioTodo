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
  const gerenteA = 'u-gerente-a';
  const auxiliarB = 'u-auxiliar-b';
  const director = 'u-director';

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
        UsuariosCompanion.insert(
            uuid: gerenteA, nombre: 'Gabo Gerente', email: 'ga@x.co', rol: const Value('GERENTE'), sedes: const Value(a)),
        UsuariosCompanion.insert(
            uuid: auxiliarB,
            nombre: 'Beto Auxiliar',
            email: 'ab@x.co',
            rol: const Value('AUXILIAR_INVENTARIO'),
            sedes: const Value(b)),
        UsuariosCompanion.insert(uuid: director, nombre: 'Dora Directora', email: 'd@x.co', rol: const Value('ADMIN')),
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

    LineaTraslado arroz(int unidades) =>
        LineaTraslado(productoUuid: 'p1', descripcion: 'Arroz', cantidad: Cantidad.unidades(unidades));

    Future<TrasladoDetalle> linea(String trasladoUuid) =>
        (db.select(db.trasladoDetalles)..where((d) => d.trasladoUuid.equals(trasladoUuid))).getSingle();

    test('el gerente solicita y el auxiliar del origen despacha menos de lo pedido', () async {
      await comoUsuario(gerenteA);
      final uuid = await traslados.solicitar(sedeOrigenUuid: b, sedeDestinoUuid: a, lineas: [arroz(4)]);
      expect(await stock(b), 5000, reason: 'solicitar no mueve nada');

      // Ni el propio gerente ni el auxiliar de OTRA sede lo despachan.
      await expectLater(traslados.despachar(uuid), throwsStateError);
      await comoUsuario(auxiliar);
      await expectLater(traslados.despachar(uuid), throwsStateError);

      await comoUsuario(auxiliarB);
      final l = await linea(uuid);
      await traslados.despachar(uuid, enviadas: {l.uuid: Cantidad.unidades(3)});

      expect(await stock(b), 2000, reason: 'salen 3, no 4');
      expect((await linea(uuid)).cantidadEnviada, 3000);

      final ops = await cola();
      expect(ops.map((o) => o.tipo), ['TRASLADO_CREAR', 'TRASLADO_APROBAR']);
      expect(ops.first.payload['usuario_uuid'], gerenteA);
      expect(ops.first.payload.containsKey('directo'), isFalse);
      expect(ops.last.payload['usuario_uuid'], auxiliarB);
      expect((ops.last.payload['movimientos'] as List).single, containsPair('cantidad', '3.000'));

      final eventos = await (db.select(db.trasladoEventos)..where((x) => x.trasladoUuid.equals(uuid))).get();
      expect(eventos.map((e) => (e.evento, e.usuarioUuid, e.nota)), [
        ('CREADO', gerenteA, null),
        ('APROBADO', auxiliarB, 'Despacho parcial'),
      ]);
    });

    test('el director despacha y el stock se mueve en las dos sedes', () async {
      await comoUsuario(gerenteA);
      final uuid = await traslados.solicitar(sedeOrigenUuid: b, sedeDestinoUuid: a, lineas: [arroz(3)]);
      await comoUsuario(director);
      await traslados.despachar(uuid);

      expect(await stock(b), 2000);
      expect(await stock(a), 13000);
      expect(await stockProyectado(), 13000, reason: 'A es la sede activa: el catálogo lo refleja');
      final t = await (db.select(db.traslados)..where((x) => x.uuid.equals(uuid))).getSingle();
      expect((t.estado, t.tipo), ('APROBADO', 'SOLICITUD'));
    });

    test('el vendedor sólo consulta: no solicita ni mueve', () async {
      await comoUsuario(vendedor);
      await expectLater(
        traslados.solicitar(sedeOrigenUuid: b, sedeDestinoUuid: a, lineas: [arroz(1)]),
        throwsStateError,
      );
      await expectLater(
        traslados.mover(sedeOrigenUuid: a, sedeDestinoUuid: b, lineas: [arroz(1)]),
        throwsStateError,
      );
      expect(await cola(), isEmpty);
    });

    test('el gerente sólo solicita para una sede suya', () async {
      await comoUsuario(gerenteA);
      await expectLater(
        traslados.solicitar(sedeOrigenUuid: a, sedeDestinoUuid: b, lineas: [arroz(1)]),
        throwsStateError,
      );
      await expectLater(
        traslados.mover(sedeOrigenUuid: b, sedeDestinoUuid: a, lineas: [arroz(1)]),
        throwsStateError,
        reason: 'el gerente solicita, no mueve',
      );
    });

    test('no se despacha más de lo que hay en el origen', () async {
      await comoUsuario(gerenteA);
      final uuid = await traslados.solicitar(sedeOrigenUuid: b, sedeDestinoUuid: a, lineas: [arroz(8)]);
      await comoUsuario(director);

      await expectLater(traslados.despachar(uuid), throwsStateError, reason: 'B tiene 5 y se piden 8');
      final l = await linea(uuid);
      await expectLater(traslados.despachar(uuid, enviadas: {l.uuid: const Cantidad(0)}), throwsStateError,
          reason: 'despachar cero es rechazar');
      expect(await stock(b), 5000);
      expect((await cola()).map((o) => o.tipo), ['TRASLADO_CREAR'], reason: 'nada a medias en la cola');

      // Lo que sí hay, se puede enviar.
      await traslados.despachar(uuid, enviadas: {l.uuid: Cantidad.unidades(5)});
      expect(await stock(b), 0);
    });

    test('el director mueve unidades directamente, sin solicitud', () async {
      await comoUsuario(director);
      final uuid = await traslados.mover(sedeOrigenUuid: a, sedeDestinoUuid: b, lineas: [arroz(2)]);

      expect(await stock(a), 8000);
      expect(await stock(b), 7000);
      final t = await (db.select(db.traslados)..where((x) => x.uuid.equals(uuid))).getSingle();
      expect((t.estado, t.tipo, t.resueltoPorUuid), ('APROBADO', 'DIRECTO', director));

      final op = (await cola()).single;
      expect(op.tipo, 'TRASLADO_CREAR');
      expect(op.payload['directo'], isTrue);
      expect((op.payload['movimientos'] as List).single, containsPair('cantidad', '2.000'));
      expect(
        (op.payload['movimientos'] as List).single['detalle_uuid'],
        (op.payload['detalles'] as List).single['uuid'],
        reason: 'el servidor casa cada movimiento con su línea',
      );
    });

    test('el auxiliar mueve desde su sede, no desde otra', () async {
      await comoUsuario(auxiliar);
      await traslados.mover(sedeOrigenUuid: a, sedeDestinoUuid: b, lineas: [arroz(1)]);
      expect(await stock(a), 9000);
      // La entrada en B la crea el servidor y llega con la siguiente bajada:
      // el auxiliar de A no lleva el kardex de B.
      expect(await stock(b), 5000);

      await expectLater(
        traslados.mover(sedeOrigenUuid: b, sedeDestinoUuid: a, lineas: [arroz(1)]),
        throwsStateError,
      );
      await expectLater(
        traslados.mover(sedeOrigenUuid: a, sedeDestinoUuid: b, lineas: [arroz(50)]),
        throwsStateError,
        reason: 'no envía más de lo que hay',
      );
    });

    test('cancela la solicitud quien la pidió', () async {
      await comoUsuario(gerenteA);
      final uuid = await traslados.solicitar(sedeOrigenUuid: b, sedeDestinoUuid: a, lineas: [arroz(1)]);
      await comoUsuario(auxiliarB);
      await expectLater(traslados.cancelar(uuid), throwsStateError);
      await comoUsuario(gerenteA);
      await traslados.cancelar(uuid);
      final t = await (db.select(db.traslados)..where((x) => x.uuid.equals(uuid))).getSingle();
      expect(t.estado, 'CANCELADO');
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
