import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/database/app_database.dart';
import 'package:inventario_pos/core/database/daos/sedes_dao.dart';
import 'package:inventario_pos/core/database/daos/sync_dao.dart';

/// Consultas multisede de SQLite que alimentan el inicio y los reportes.
///
/// Son SQL a mano (`customSelect`): un error de sintaxis o de columna no lo ve
/// el analizador, sólo aparece al ejecutarlas. Por eso se ejecutan aquí contra
/// una base en memoria.
void main() {
  late AppDatabase db;
  late SedesDao dao;

  const hoy = '2026-10-08';
  const ayer = '2026-10-07';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    dao = SedesDao(db, SyncDao(db));

    await db.batch((b) {
      b.insertAll(db.sedes, [
        SedesCompanion.insert(uuid: 's-centro', nombre: 'Centro', codigo: 'CEN', esPrincipal: const Value(true)),
        SedesCompanion.insert(uuid: 's-norte', nombre: 'Norte', codigo: 'NOR'),
        SedesCompanion.insert(uuid: 's-cerrada', nombre: 'Cerrada', codigo: 'CER', activo: const Value(false)),
      ]);
      b.insert(db.productos, ProductosCompanion.insert(uuid: 'p1', sku: 'P1', nombre: 'Arroz'));
      b.insert(db.usuarios, UsuariosCompanion.insert(uuid: 'u1', nombre: 'Ana Auxiliar', email: 'ana@x.co'));

      Insertable<Venta> venta(String uuid, String sede, String dia, int total, {String estado = 'COMPLETADA'}) =>
          VentasCompanion.insert(
            uuid: uuid,
            numero: uuid,
            sedeUuid: Value(sede),
            fecha: DateTime.utc(2026, 10, int.parse(dia.substring(8))),
            fechaLocal: dia,
            total: Value(total),
            costoTotal: Value(total ~/ 2),
            estado: Value(estado),
          );
      b.insertAll(db.ventas, [
        venta('v1', 's-centro', hoy, 10000),
        venta('v2', 's-centro', hoy, 5000),
        venta('v3', 's-centro', ayer, 20000),
        venta('v4', 's-norte', ayer, 8000),
        venta('v5', 's-norte', hoy, 99999, estado: 'ANULADA'),
      ]);

      Insertable<Movimiento> mov(String uuid, String tipo, int cantidad, int minuto) => MovimientosCompanion.insert(
            uuid: uuid,
            productoUuid: 'p1',
            tipo: tipo,
            cantidad: cantidad,
            sedeUuid: const Value('s-norte'),
            usuarioUuid: const Value('u1'),
            fecha: DateTime.utc(2026, 10, 8, 15, minuto),
            fechaLocal: hoy,
          );
      b.insertAll(db.movimientos, [
        mov('m1', 'ENTRADA', 5000, 1),
        mov('m2', 'VENTA', 1000, 2),
        mov('m3', 'MERMA', 1000, 3),
        mov('m4', 'ANULACION_VENTA', 1000, 4),
      ]);
    });
  });

  tearDown(() => db.close());

  test('ventas por sede: hoy y ayer, sin anuladas y con las sedes sin ventas', () async {
    final lista = await dao.observarVentasPorSede(hoy: hoy, ayer: ayer).first;

    expect(lista.map((v) => v.sede.uuid), ['s-centro', 's-norte'], reason: 'la desactivada no aparece');
    final centro = lista.first;
    expect(centro.hoy.centavos, 15000);
    expect(centro.numHoy, 2);
    expect(centro.ayer.centavos, 20000);
    expect(centro.variacion, closeTo(-25, 0.001));

    final norte = lista.last;
    expect(norte.hoy.centavos, 0, reason: 'la venta anulada no cuenta');
    expect(norte.ayer.centavos, 8000);
  });

  test('totales por sede del periodo, con margen', () async {
    final lista = await dao.observarTotalesPorSede(desde: ayer).first;

    expect(lista.map((f) => f.sede.uuid), ['s-centro', 's-norte']);
    expect(lista.first.total.centavos, 35000);
    expect(lista.first.numero, 3);
    expect(lista.first.margen.centavos, 17500);
    expect(lista.last.total.centavos, 8000);
  });

  test('cambios de inventario: todo menos ventas y anulaciones, el más reciente primero', () async {
    final cambios = await dao.observarCambiosInventario(desde: hoy).first;

    expect(cambios.map((c) => c.movimiento.tipo), ['MERMA', 'ENTRADA']);
    expect(cambios.first.usuario?.nombre, 'Ana Auxiliar');
    expect(cambios.first.sede?.nombre, 'Norte');
  });
}
