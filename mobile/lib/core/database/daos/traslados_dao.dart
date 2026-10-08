import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../features/auth/domain/sesion.dart';
import '../../money/money.dart';
import '../../negocio/traslados.dart';
import '../app_database.dart';
import 'inventario_dao.dart';
import 'outbox_dao.dart';

/// Producto y cantidad que se pide trasladar.
class LineaTraslado {
  const LineaTraslado({required this.productoUuid, required this.descripcion, required this.cantidad});

  final String productoUuid;
  final String descripcion;
  final Cantidad cantidad;
}

class TrasladoResumen {
  const TrasladoResumen({
    required this.traslado,
    required this.origen,
    required this.destino,
    required this.productos,
    required this.unidades,
    this.solicitante,
  });

  final Traslado traslado;
  final Sede? origen;
  final Sede? destino;
  final int productos;
  final Cantidad unidades;
  final Usuario? solicitante;

  bool get pendiente => traslado.estado == 'PENDIENTE';
}

class TrasladoCompleto {
  const TrasladoCompleto({required this.resumen, required this.detalles, required this.eventos});

  final TrasladoResumen resumen;
  final List<TrasladoDetalle> detalles;
  final List<({TrasladoEvento evento, Usuario? usuario})> eventos;
}

/// Traslados entre sedes, sin red.
///
/// Flujo simple: se pide (PENDIENTE) y, al aprobarse, el stock sale de la sede
/// origen y entra en la destino en ese mismo momento. Cada paso deja un evento
/// con usuario y hora, y viaja por la cola de salida; si dos personas resuelven
/// el mismo traslado sin red, el servidor rechaza la segunda y aparece en
/// «Elementos con problema».
class TrasladosDao {
  TrasladosDao(this.db, this.outbox, this.inventario);

  final AppDatabase db;
  final OutboxDao outbox;
  final InventarioDao inventario;
  static const _uuid = Uuid();

  Future<({String? usuarioUuid, RolUsuario rol, Set<String>? sedes, String? prefijo})> _quien() async {
    final estado = await (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingle();
    final usuario = estado.usuarioUuid == null
        ? null
        : await (db.select(db.usuarios)..where((t) => t.uuid.equals(estado.usuarioUuid!))).getSingleOrNull();
    final rol = RolUsuario.desde(usuario?.rol);
    return (
      usuarioUuid: estado.usuarioUuid,
      rol: rol,
      sedes: rol.esDirector ? null : (usuario?.sedes ?? '').split(',').where((s) => s.isNotEmpty).toSet(),
      prefijo: estado.prefijoFolio,
    );
  }

  Future<Actor> actor() async {
    final q = await _quien();
    return Actor(uuid: q.usuarioUuid ?? '', rol: q.rol, sedes: q.sedes);
  }

  /// Número legible con el prefijo del dispositivo: TR-A1-000003.
  Future<String> _siguienteNumero(String? prefijo) async {
    final base = 'TR-${prefijo ?? 'LOC'}-';
    final filas = await (db.select(db.traslados)..where((t) => t.numero.like('$base%'))).get();
    var maximo = 0;
    for (final f in filas) {
      final n = int.tryParse(f.numero.substring(base.length).split('+').first) ?? 0;
      if (n > maximo) maximo = n;
    }
    return '$base${(maximo + 1).toString().padLeft(6, '0')}';
  }

  Future<void> _evento(String trasladoUuid, String evento, String? usuarioUuid, {String? nota}) =>
      db.into(db.trasladoEventos).insert(
            TrasladoEventosCompanion.insert(
              uuid: _uuid.v7(),
              trasladoUuid: trasladoUuid,
              evento: evento,
              usuarioUuid: Value(usuarioUuid),
              fecha: DateTime.now().toUtc(),
              nota: Value(nota),
            ),
          );

  Future<String> crear({
    required String sedeOrigenUuid,
    required String sedeDestinoUuid,
    required List<LineaTraslado> lineas,
    String? notas,
  }) async {
    if (lineas.isEmpty) throw ArgumentError('El traslado no tiene productos');
    final q = await _quien();
    final motivo = motivoNoPuedeCrear(
      Actor(uuid: q.usuarioUuid ?? '', rol: q.rol, sedes: q.sedes),
      sedeOrigenUuid,
      sedeDestinoUuid,
    );
    if (motivo != null) throw StateError(motivo);

    final uuid = _uuid.v7();
    final ahora = DateTime.now().toUtc();

    await db.transaction(() async {
      final numero = await _siguienteNumero(q.prefijo);
      await db.into(db.traslados).insert(
            TrasladosCompanion.insert(
              uuid: uuid,
              numero: numero,
              sedeOrigenUuid: sedeOrigenUuid,
              sedeDestinoUuid: sedeDestinoUuid,
              confirma: Value(quienConfirma(q.rol)),
              notas: Value(notas),
              solicitadoPorUuid: Value(q.usuarioUuid),
              solicitadoEn: ahora,
              updatedAt: Value(ahora),
            ),
          );

      final detalles = <Map<String, dynamic>>[];
      for (final l in lineas) {
        final detalleUuid = _uuid.v7();
        await db.into(db.trasladoDetalles).insert(
              TrasladoDetallesCompanion.insert(
                uuid: detalleUuid,
                trasladoUuid: uuid,
                productoUuid: Value(l.productoUuid),
                descripcion: l.descripcion,
                cantidad: l.cantidad.milesimas,
              ),
            );
        detalles.add({
          'uuid': detalleUuid,
          'producto_uuid': l.productoUuid,
          'cantidad': l.cantidad.toApi(),
        });
      }
      await _evento(uuid, 'CREADO', q.usuarioUuid, nota: notas);

      await outbox.encolar(
        'TRASLADO_CREAR',
        entidad: 'traslados',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'numero': numero,
          'sede_origen_uuid': sedeOrigenUuid,
          'sede_destino_uuid': sedeDestinoUuid,
          'notas': notas,
          'detalles': detalles,
          'fecha': ahora.toIso8601String(),
        },
      );
    });
    return uuid;
  }

  /// Aprueba y mueve el stock en el acto.
  ///
  /// Los uuid de los movimientos se generan aquí y viajan al servidor: así la
  /// copia local y la del servidor son la MISMA fila y el kardex no muestra el
  /// traslado dos veces. Localmente sólo se aplica el movimiento de las sedes
  /// que este teléfono ve; el de la otra lo crea el servidor y le llega a quien
  /// sí la ve.
  Future<void> aprobar(String trasladoUuid) async {
    final q = await _quien();
    await db.transaction(() async {
      final t = await (db.select(db.traslados)..where((x) => x.uuid.equals(trasladoUuid))).getSingle();
      final motivo = motivoNoPuedeResolver(
        estado: t.estado,
        confirma: t.confirma,
        sedeOrigen: t.sedeOrigenUuid,
        solicitadoPor: t.solicitadoPorUuid,
        actor: Actor(uuid: q.usuarioUuid ?? '', rol: q.rol, sedes: q.sedes),
      );
      if (motivo != null) throw StateError(motivo);

      final origen = await (db.select(db.sedes)..where((s) => s.uuid.equals(t.sedeOrigenUuid))).getSingleOrNull();
      final destino = await (db.select(db.sedes)..where((s) => s.uuid.equals(t.sedeDestinoUuid))).getSingleOrNull();
      final detalles =
          await (db.select(db.trasladoDetalles)..where((d) => d.trasladoUuid.equals(trasladoUuid))).get();

      bool ve(String s) => q.sedes == null || q.sedes!.contains(s);

      // La misma regla que el servidor (TRASLADO_SIN_STOCK): no se despacha lo
      // que no hay. Comprobarlo aquí evita aplicar en el teléfono un traslado
      // que el servidor va a rechazar y dejar el stock local descuadrado.
      if (ve(t.sedeOrigenUuid)) {
        for (final d in detalles.where((d) => d.productoUuid != null)) {
          final disponible = await inventario.stockEnSede(d.productoUuid!, t.sedeOrigenUuid);
          if (disponible < d.cantidad) {
            throw StateError(
              'No hay suficiente ${d.descripcion} en ${origen?.nombre ?? 'la sede de origen'}: '
              'hay ${Cantidad(disponible).format()} y el traslado pide ${Cantidad(d.cantidad).format()}',
            );
          }
        }
      }

      final movimientos = <Map<String, dynamic>>[];
      for (final d in detalles) {
        final salida = _uuid.v7();
        final entrada = _uuid.v7();
        movimientos.add({'detalle_uuid': d.uuid, 'salida_uuid': salida, 'entrada_uuid': entrada});
        if (d.productoUuid == null) continue;

        if (ve(t.sedeOrigenUuid)) {
          await inventario.aplicarMovimientoDeTraslado(
            productoUuid: d.productoUuid!,
            sedeUuid: t.sedeOrigenUuid,
            cantidadConSigno: Cantidad(-d.cantidad),
            trasladoUuid: t.uuid,
            uuid: salida,
            motivo: 'Traslado ${t.numero} a ${destino?.nombre ?? 'otra sede'}',
          );
        }
        if (ve(t.sedeDestinoUuid)) {
          await inventario.aplicarMovimientoDeTraslado(
            productoUuid: d.productoUuid!,
            sedeUuid: t.sedeDestinoUuid,
            cantidadConSigno: Cantidad(d.cantidad),
            trasladoUuid: t.uuid,
            uuid: entrada,
            motivo: 'Traslado ${t.numero} desde ${origen?.nombre ?? 'otra sede'}',
          );
        }
      }

      final ahora = DateTime.now().toUtc();
      await (db.update(db.traslados)..where((x) => x.uuid.equals(trasladoUuid))).write(
        TrasladosCompanion(
          estado: const Value('APROBADO'),
          resueltoPorUuid: Value(q.usuarioUuid),
          resueltoEn: Value(ahora),
          updatedAt: Value(ahora),
        ),
      );
      await _evento(trasladoUuid, 'APROBADO', q.usuarioUuid);

      await outbox.encolar(
        'TRASLADO_APROBAR',
        entidad: 'traslados',
        entidadUuid: trasladoUuid,
        payload: {
          'uuid': trasladoUuid,
          'movimientos': movimientos,
          'fecha': ahora.toIso8601String(),
          'creado_offline': true,
        },
      );
    });
  }

  Future<void> rechazar(String trasladoUuid, {String? motivo}) => _resolverSinStock(
        trasladoUuid,
        estado: 'RECHAZADO',
        operacion: 'TRASLADO_RECHAZAR',
        motivo: motivo,
        cancelar: false,
      );

  Future<void> cancelar(String trasladoUuid) => _resolverSinStock(
        trasladoUuid,
        estado: 'CANCELADO',
        operacion: 'TRASLADO_CANCELAR',
        cancelar: true,
      );

  Future<void> _resolverSinStock(
    String trasladoUuid, {
    required String estado,
    required String operacion,
    required bool cancelar,
    String? motivo,
  }) async {
    final q = await _quien();
    final actor = Actor(uuid: q.usuarioUuid ?? '', rol: q.rol, sedes: q.sedes);
    await db.transaction(() async {
      final t = await (db.select(db.traslados)..where((x) => x.uuid.equals(trasladoUuid))).getSingle();
      final impedimento = cancelar
          ? motivoNoPuedeCancelar(estado: t.estado, solicitadoPor: t.solicitadoPorUuid, actor: actor)
          : motivoNoPuedeResolver(
              estado: t.estado,
              confirma: t.confirma,
              sedeOrigen: t.sedeOrigenUuid,
              solicitadoPor: t.solicitadoPorUuid,
              actor: actor,
            );
      if (impedimento != null) throw StateError(impedimento);

      final ahora = DateTime.now().toUtc();
      await (db.update(db.traslados)..where((x) => x.uuid.equals(trasladoUuid))).write(
        TrasladosCompanion(
          estado: Value(estado),
          resueltoPorUuid: Value(q.usuarioUuid),
          resueltoEn: Value(ahora),
          motivoRechazo: Value(motivo),
          updatedAt: Value(ahora),
        ),
      );
      await _evento(trasladoUuid, estado, q.usuarioUuid, nota: motivo);
      await outbox.encolar(
        operacion,
        entidad: 'traslados',
        entidadUuid: trasladoUuid,
        payload: {'uuid': trasladoUuid, 'motivo': motivo},
      );
    });
  }

  // ── Lecturas ──────────────────────────────────────────────────────────────

  Stream<List<TrasladoResumen>> observar({bool soloPendientes = false, int limite = 200}) {
    final origen = db.alias(db.sedes, 'origen');
    final destino = db.alias(db.sedes, 'destino');
    final consulta = db.select(db.traslados).join([
      leftOuterJoin(origen, origen.uuid.equalsExp(db.traslados.sedeOrigenUuid)),
      leftOuterJoin(destino, destino.uuid.equalsExp(db.traslados.sedeDestinoUuid)),
      leftOuterJoin(db.usuarios, db.usuarios.uuid.equalsExp(db.traslados.solicitadoPorUuid)),
    ])
      ..where(db.traslados.deletedAt.isNull());
    if (soloPendientes) consulta.where(db.traslados.estado.equals('PENDIENTE'));
    consulta
      ..orderBy([OrderingTerm.desc(db.traslados.solicitadoEn)])
      ..limit(limite);

    return consulta.watch().asyncMap((filas) async {
      final resultado = <TrasladoResumen>[];
      for (final f in filas) {
        final t = f.readTable(db.traslados);
        final detalles =
            await (db.select(db.trasladoDetalles)..where((d) => d.trasladoUuid.equals(t.uuid))).get();
        resultado.add(TrasladoResumen(
          traslado: t,
          origen: f.readTableOrNull(origen),
          destino: f.readTableOrNull(destino),
          productos: detalles.length,
          unidades: Cantidad(detalles.fold(0, (s, d) => s + d.cantidad)),
          solicitante: f.readTableOrNull(db.usuarios),
        ));
      }
      return resultado;
    });
  }

  Stream<TrasladoCompleto?> observarDetalle(String uuid) {
    return observar().map((lista) => lista.where((r) => r.traslado.uuid == uuid).firstOrNull).asyncMap(
      (resumen) async {
        if (resumen == null) return null;
        final detalles =
            await (db.select(db.trasladoDetalles)..where((d) => d.trasladoUuid.equals(uuid))).get();
        final eventos = await (db.select(db.trasladoEventos).join([
          leftOuterJoin(db.usuarios, db.usuarios.uuid.equalsExp(db.trasladoEventos.usuarioUuid)),
        ])
              ..where(db.trasladoEventos.trasladoUuid.equals(uuid))
              ..orderBy([OrderingTerm.asc(db.trasladoEventos.fecha)]))
            .get();
        return TrasladoCompleto(
          resumen: resumen,
          detalles: detalles,
          eventos: eventos
              .map((e) => (evento: e.readTable(db.trasladoEventos), usuario: e.readTableOrNull(db.usuarios)))
              .toList(),
        );
      },
    );
  }
}
