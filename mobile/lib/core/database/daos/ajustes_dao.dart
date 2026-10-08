import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../money/money.dart';
import '../app_database.dart';
import 'inventario_dao.dart';
import 'outbox_dao.dart';

class SolicitudConDatos {
  const SolicitudConDatos({required this.solicitud, this.producto, this.sede, this.solicitante});

  final SolicitudAjuste solicitud;
  final Producto? producto;
  final Sede? sede;
  final Usuario? solicitante;

  bool get pendiente => solicitud.estado == 'PENDIENTE';

  String get descripcion => switch (solicitud.tipo) {
        'CONTEO' => 'Conteo: hay ${Cantidad(solicitud.stockContado ?? 0).format()}',
        'MERMA' => 'Merma de ${Cantidad(solicitud.cantidad ?? 0).format()}',
        _ => 'Ajuste de ${_conSigno(Cantidad(solicitud.cantidad ?? 0))}',
      };

  static String _conSigno(Cantidad c) => c.milesimas > 0 ? '+${c.format()}' : c.format();
}

/// Solicitudes de ajuste del Auxiliar de Inventario.
///
/// Un conteo, una merma o un ajuste pedido por un auxiliar NO toca el stock:
/// queda pendiente hasta que el gerente de la sede (o el director) lo aprueba.
/// Es la vía con la que se tapa un faltante, así que la ve otra persona.
///
/// El conteo guarda lo que hay físicamente y la diferencia se calcula AL
/// APROBAR, contra el stock de ese momento: si entre el conteo y la aprobación
/// se vendió algo, una diferencia calculada antes ya estaría vieja.
class AjustesDao {
  AjustesDao(this.db, this.outbox, this.inventario);

  final AppDatabase db;
  final OutboxDao outbox;
  final InventarioDao inventario;
  static const _uuid = Uuid();

  Future<String> solicitar({
    required String productoUuid,
    required String tipo,
    Cantidad? cantidad,
    Cantidad? stockContado,
    String? motivo,
  }) async {
    final ctx = await inventario.contexto();
    if (ctx.sedeUuid == null) throw StateError('El teléfono no tiene una sede activa');
    if (tipo == 'CONTEO' && stockContado == null) throw ArgumentError('Indica cuánto hay');
    if (tipo != 'CONTEO' && (cantidad == null || cantidad.esCero)) throw ArgumentError('Indica la cantidad');

    final uuid = _uuid.v7();
    final ahora = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.into(db.solicitudesAjuste).insert(
            SolicitudesAjusteCompanion.insert(
              uuid: uuid,
              sedeUuid: ctx.sedeUuid!,
              productoUuid: productoUuid,
              tipo: tipo,
              cantidad: Value(tipo == 'CONTEO' ? null : cantidad!.milesimas),
              stockContado: Value(tipo == 'CONTEO' ? stockContado!.milesimas : null),
              motivo: Value(motivo),
              solicitadoPorUuid: Value(ctx.usuarioUuid),
              solicitadoEn: ahora,
              updatedAt: Value(ahora),
            ),
          );
      await outbox.encolar(
        'AJUSTE_SOLICITAR',
        entidad: 'solicitudes_ajuste',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'producto_uuid': productoUuid,
          'tipo': tipo,
          'cantidad': tipo == 'CONTEO' ? null : cantidad!.toApi(),
          'stock_contado': tipo == 'CONTEO' ? stockContado!.toApi() : null,
          'motivo': motivo,
          'fecha': ahora.toIso8601String(),
        },
      );
    });
    return uuid;
  }

  /// Aprueba y aplica el movimiento en el acto, a nombre de quien lo pidió.
  Future<void> aprobar(String solicitudUuid) async {
    final ctx = await inventario.contexto();
    await db.transaction(() async {
      final s =
          await (db.select(db.solicitudesAjuste)..where((t) => t.uuid.equals(solicitudUuid))).getSingle();
      if (s.estado != 'PENDIENTE') throw StateError('La solicitud ya fue resuelta');
      if (s.solicitadoPorUuid == ctx.usuarioUuid) {
        throw StateError('Un ajuste lo aprueba otra persona, no quien lo pidió');
      }

      // Diferencia contra el stock de la sede de la solicitud, ahora.
      final actual = s.sedeUuid == ctx.sedeUuid
          ? (await (db.select(db.productos)..where((t) => t.uuid.equals(s.productoUuid))).getSingle())
              .stockActual
          : await inventario.stockEnSede(s.productoUuid, s.sedeUuid);

      final (tipo, cantidad) = switch (s.tipo) {
        'CONTEO' => ('AJUSTE', Cantidad((s.stockContado ?? 0) - actual)),
        'MERMA' => ('MERMA', Cantidad(s.cantidad ?? 0)),
        _ => ('AJUSTE', Cantidad(s.cantidad ?? 0)),
      };

      String? movimientoUuid;
      if (!cantidad.esCero) {
        movimientoUuid = _uuid.v7();
        await inventario.aplicarMovimientoAprobado(
          productoUuid: s.productoUuid,
          sedeUuid: s.sedeUuid,
          tipo: tipo,
          cantidad: cantidad,
          uuid: movimientoUuid,
          usuarioUuid: s.solicitadoPorUuid,
          aprobadoPorUuid: ctx.usuarioUuid,
          motivo: s.motivo ??
              (s.tipo == 'CONTEO'
                  ? 'Conteo físico: ${Cantidad(actual).format()} → ${Cantidad(s.stockContado ?? 0).format()}'
                  : null),
        );
      }

      final ahora = DateTime.now().toUtc();
      await (db.update(db.solicitudesAjuste)..where((t) => t.uuid.equals(solicitudUuid))).write(
        SolicitudesAjusteCompanion(
          estado: const Value('APROBADA'),
          resueltoPorUuid: Value(ctx.usuarioUuid),
          resueltoEn: Value(ahora),
          updatedAt: Value(ahora),
        ),
      );
      await outbox.encolar(
        'AJUSTE_APROBAR',
        entidad: 'solicitudes_ajuste',
        entidadUuid: solicitudUuid,
        payload: {'uuid': solicitudUuid, 'movimiento_uuid': movimientoUuid},
      );
    });
  }

  Future<void> rechazar(String solicitudUuid, {String? motivo}) async {
    final ctx = await inventario.contexto();
    await db.transaction(() async {
      final s =
          await (db.select(db.solicitudesAjuste)..where((t) => t.uuid.equals(solicitudUuid))).getSingle();
      if (s.estado != 'PENDIENTE') throw StateError('La solicitud ya fue resuelta');
      final ahora = DateTime.now().toUtc();
      await (db.update(db.solicitudesAjuste)..where((t) => t.uuid.equals(solicitudUuid))).write(
        SolicitudesAjusteCompanion(
          estado: const Value('RECHAZADA'),
          resueltoPorUuid: Value(ctx.usuarioUuid),
          resueltoEn: Value(ahora),
          motivoRechazo: Value(motivo),
          updatedAt: Value(ahora),
        ),
      );
      await outbox.encolar(
        'AJUSTE_RECHAZAR',
        entidad: 'solicitudes_ajuste',
        entidadUuid: solicitudUuid,
        payload: {'uuid': solicitudUuid, 'motivo': motivo},
      );
    });
  }

  Stream<List<SolicitudConDatos>> observar({bool soloPendientes = false, String? solicitadoPor}) {
    final consulta = db.select(db.solicitudesAjuste).join([
      leftOuterJoin(db.productos, db.productos.uuid.equalsExp(db.solicitudesAjuste.productoUuid)),
      leftOuterJoin(db.sedes, db.sedes.uuid.equalsExp(db.solicitudesAjuste.sedeUuid)),
      leftOuterJoin(db.usuarios, db.usuarios.uuid.equalsExp(db.solicitudesAjuste.solicitadoPorUuid)),
    ]);
    if (soloPendientes) consulta.where(db.solicitudesAjuste.estado.equals('PENDIENTE'));
    if (solicitadoPor != null) consulta.where(db.solicitudesAjuste.solicitadoPorUuid.equals(solicitadoPor));
    consulta
      ..orderBy([OrderingTerm.desc(db.solicitudesAjuste.solicitadoEn)])
      ..limit(200);
    return consulta.watch().map(
          (filas) => filas
              .map((f) => SolicitudConDatos(
                    solicitud: f.readTable(db.solicitudesAjuste),
                    producto: f.readTableOrNull(db.productos),
                    sede: f.readTableOrNull(db.sedes),
                    solicitante: f.readTableOrNull(db.usuarios),
                  ))
              .toList(),
        );
  }
}
