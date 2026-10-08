import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../money/money.dart';
import '../../negocio/caja.dart';
import '../../utils/fechas.dart';
import '../app_database.dart';
import 'outbox_dao.dart';

/// Un pago con entidad de crédito que la entidad todavía no ha saldado.
class PagoPendiente {
  const PagoPendiente({required this.pago, required this.venta, this.sede});

  final VentaPago pago;
  final Venta venta;
  final Sede? sede;

  Money get pendiente => Money(pago.monto - pago.cobrado);

  /// Días desde la venta.
  int get dias => DateTime.now().toUtc().difference(venta.fecha.toUtc()).inDays;
}

/// Lo que debe una entidad (Addi, Crediya…).
class CuentaEntidad {
  const CuentaEntidad({required this.metodo, required this.pendientes});

  final MetodoPago metodo;
  final List<PagoPendiente> pendientes;

  Money get total => Money.sumar(pendientes.map((p) => p.pendiente));

  /// Pagos que pasaron del plazo en que la entidad suele pagar.
  List<PagoPendiente> get vencidos {
    final plazo = metodo.diasPago;
    if (plazo == null) return const [];
    return pendientes.where((p) => p.dias > plazo).toList();
  }

  Money get totalVencido => Money.sumar(vencidos.map((p) => p.pendiente));
}

/// Cuentas por cobrar a entidades de crédito y sus recaudos.
///
/// La venta se cobró con un medio de tipo CREDITO: el cliente se llevó la
/// mercancía y la entidad paga al negocio después, descontando su comisión.
/// Registrar el pago de la entidad lo reparte entre las ventas pendientes, de
/// la más antigua a la más nueva —como liquidan en la práctica—.
class RecaudosDao {
  RecaudosDao(this.db, this.outbox);

  final AppDatabase db;
  final OutboxDao outbox;
  static const _uuid = Uuid();

  Stream<List<CuentaEntidad>> observarCuentas({List<String>? sedes}) {
    final consulta = db.select(db.ventaPagos).join([
      innerJoin(db.ventas, db.ventas.uuid.equalsExp(db.ventaPagos.ventaUuid)),
      leftOuterJoin(db.sedes, db.sedes.uuid.equalsExp(db.ventas.sedeUuid)),
    ])
      ..where(db.ventaPagos.metodoTipo.equals('CREDITO') &
          db.ventas.estado.equals('COMPLETADA') &
          db.ventas.deletedAt.isNull() &
          db.ventaPagos.cobrado.isSmallerThan(db.ventaPagos.monto));
    if (sedes != null) consulta.where(db.ventas.sedeUuid.isIn(sedes));
    consulta.orderBy([OrderingTerm.asc(db.ventas.fecha)]);

    return consulta.watch().asyncMap((filas) async {
      final metodos = {
        for (final m in await (db.select(db.metodosPago)..where((t) => t.tipo.equals('CREDITO'))).get()) m.uuid: m,
      };
      final porEntidad = <String, List<PagoPendiente>>{};
      for (final f in filas) {
        final pago = f.readTable(db.ventaPagos);
        final clave = pago.metodoPagoUuid ?? pago.metodoNombre;
        porEntidad.putIfAbsent(clave, () => []).add(
              PagoPendiente(pago: pago, venta: f.readTable(db.ventas), sede: f.readTableOrNull(db.sedes)),
            );
      }
      return porEntidad.entries
          .map((e) => CuentaEntidad(
                metodo: metodos[e.key] ??
                    MetodoPago(
                      uuid: e.key,
                      nombre: e.value.first.pago.metodoNombre,
                      tipo: 'CREDITO',
                      requiereReferencia: false,
                      color: '#6750A4',
                      orden: 0,
                      activo: true,
                      updatedAt: DateTime.now(),
                    ),
                pendientes: e.value,
              ))
          .toList()
        ..sort((a, b) => b.total.compareTo(a.total));
    });
  }

  /// Registra lo que pagó una entidad y lo aplica a las ventas pendientes.
  ///
  /// La aplicación se calcula AQUÍ y viaja explícita al servidor: así lo que
  /// se ve en el teléfono es exactamente lo que queda registrado, sin que el
  /// servidor tenga que volver a decidir a qué ventas se aplicó.
  Future<({int aplicadas, Money sobrante})> registrar({
    required CuentaEntidad cuenta,
    required Money monto,
    required Money comision,
    String? referencia,
    String? notas,
  }) async {
    final total = monto + comision;
    final r = aplicarRecaudo(
      cuenta.pendientes.map((p) => (id: p.pago.uuid, pendiente: p.pendiente)).toList(),
      total,
    );
    if (r.sobrante.esPositivo) {
      throw StateError(
        '${cuenta.metodo.nombre} pagó ${r.sobrante.format()} más de lo que tiene pendiente. '
        'Revisa el monto o la comisión.',
      );
    }

    final uuid = _uuid.v7();
    final hoy = Fechas.hoy();
    await db.transaction(() async {
      for (final a in r.aplicaciones) {
        final pago = cuenta.pendientes.firstWhere((p) => p.pago.uuid == a.id).pago;
        await (db.update(db.ventaPagos)..where((t) => t.uuid.equals(a.id)))
            .write(VentaPagosCompanion(cobrado: Value(pago.cobrado + a.monto.centavos)));
      }
      final aplicaciones = r.aplicaciones.map((a) => {'venta_pago_uuid': a.id, 'monto': a.monto.toApi()}).toList();
      await db.into(db.recaudos).insert(
            RecaudosCompanion.insert(
              uuid: uuid,
              metodoPagoUuid: cuenta.metodo.uuid,
              fecha: hoy,
              monto: monto.centavos,
              comision: Value(comision.centavos),
              referencia: Value(referencia),
              notas: Value(notas),
              aplicaciones: Value(jsonEncode(aplicaciones)),
            ),
          );
      await outbox.encolar(
        'RECAUDO_CREAR',
        entidad: 'recaudos',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'metodo_pago_uuid': cuenta.metodo.uuid,
          'fecha': hoy,
          'monto': monto.toApi(),
          'comision': comision.toApi(),
          'referencia': referencia,
          'notas': notas,
          'aplicaciones': aplicaciones,
        },
      );
    });
    return (aplicadas: r.aplicaciones.length, sobrante: r.sobrante);
  }

  Stream<List<Recaudo>> observarRecaudos(String metodoUuid) => (db.select(db.recaudos)
        ..where((t) => t.metodoPagoUuid.equals(metodoUuid) & t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.fecha)])
        ..limit(100))
      .watch();
}
