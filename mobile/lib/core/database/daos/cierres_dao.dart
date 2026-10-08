import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../money/money.dart';
import '../../negocio/caja.dart';
import '../app_database.dart';
import 'outbox_dao.dart';

/// Lo que se contó de un medio al cerrar. `contado` null = no se verificó.
class ConteoMedio {
  const ConteoMedio({required this.medio, this.contado});

  final EsperadoPorMedio medio;
  final Money? contado;

  Money? get diferencia => contado == null ? null : contado! - medio.esperado;
}

class CierreConDatos {
  const CierreConDatos({required this.cierre, this.usuario, this.sede});

  final CierreCaja cierre;
  final Usuario? usuario;
  final Sede? sede;

  bool get abierto => cierre.estado == 'ABIERTO';
  Money? get diferencia => cierre.diferenciaEfectivo == null ? null : Money(cierre.diferenciaEfectivo!);
  bool get conDiferencia => (cierre.diferenciaEfectivo ?? 0) != 0;
  bool get revisado => cierre.revisadoEn != null;

  /// Detalle por medio tal como lo guardó el servidor (o la app, mientras no
  /// llega su cálculo).
  List<Map<String, dynamic>> get detalle {
    final texto = cierre.detalle;
    if (texto == null) return const [];
    try {
      return (jsonDecode(texto) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }
}

/// Cierre de caja por turno.
///
/// Al empezar se declara la base de efectivo; cada venta guarda el turno en el
/// que se cobró; al terminar se cuenta. La app calcula lo esperado con sus
/// ventas locales para mostrarlo al instante, y el servidor lo recalcula con
/// las ventas ya sincronizadas: la cifra que queda es la del servidor.
class CierresDao {
  CierresDao(this.db, this.outbox);

  final AppDatabase db;
  final OutboxDao outbox;
  static const _uuid = Uuid();

  Future<EstadoAppData> _estado() =>
      (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingle();

  /// Caja abierta del usuario, si la tiene.
  Stream<CierreCaja?> observarAbierta(String usuarioUuid) => (db.select(db.cierresCaja)
        ..where((t) => t.usuarioUuid.equals(usuarioUuid) & t.estado.equals('ABIERTO'))
        ..limit(1))
      .watchSingleOrNull();

  Future<CierreCaja?> abierta(String usuarioUuid) => (db.select(db.cierresCaja)
        ..where((t) => t.usuarioUuid.equals(usuarioUuid) & t.estado.equals('ABIERTO'))
        ..limit(1))
      .getSingleOrNull();

  Future<String> abrir({required Money baseEfectivo}) async {
    final estado = await _estado();
    final usuario = estado.usuarioUuid;
    final sede = estado.sedeActivaUuid;
    if (usuario == null || sede == null) throw StateError('No hay sesión o sede activa');
    if (await abierta(usuario) != null) throw StateError('Ya tienes una caja abierta');

    final uuid = _uuid.v7();
    final ahora = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.into(db.cierresCaja).insert(
            CierresCajaCompanion.insert(
              uuid: uuid,
              sedeUuid: sede,
              usuarioUuid: Value(usuario),
              dispositivoUuid: Value(estado.dispositivoUuid),
              abiertoEn: ahora,
              baseEfectivo: Value(baseEfectivo.centavos),
              updatedAt: Value(ahora),
            ),
          );
      await outbox.encolar(
        'CIERRE_ABRIR',
        entidad: 'cierres_caja',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'base_efectivo': baseEfectivo.toApi(),
          'abierto_en': ahora.toIso8601String(),
        },
      );
    });
    return uuid;
  }

  /// Lo esperado por medio, con las ventas locales del turno.
  Future<List<EsperadoPorMedio>> esperado(String turnoUuid) async {
    final cierre = await (db.select(db.cierresCaja)..where((t) => t.uuid.equals(turnoUuid))).getSingle();
    final filas = await db.customSelect(
      'SELECT vp.metodo_pago_uuid AS uuid, vp.metodo_nombre AS nombre, vp.metodo_tipo AS tipo, '
      '       SUM(vp.monto) AS monto '
      '  FROM venta_pagos vp JOIN ventas v ON v.uuid = vp.venta_uuid '
      ' WHERE v.turno_uuid = ? AND v.estado = ? AND v.deleted_at IS NULL '
      ' GROUP BY vp.metodo_pago_uuid, vp.metodo_nombre, vp.metodo_tipo',
      variables: [Variable<String>(turnoUuid), const Variable<String>('COMPLETADA')],
      readsFrom: {db.ventaPagos, db.ventas},
    ).get();
    return calcularEsperado(
      Money(cierre.baseEfectivo),
      filas
          .map((f) => CobroPorMedio(
                metodoUuid: f.readNullable<String>('uuid'),
                metodoNombre: f.read<String>('nombre'),
                metodoTipo: f.read<String>('tipo'),
                monto: Money(f.read<int>('monto')),
              ))
          .toList(),
    );
  }

  Future<void> cerrar({
    required String turnoUuid,
    required List<ConteoMedio> conteos,
    String? notas,
    bool tardio = false,
  }) async {
    final ahora = DateTime.now().toUtc();
    final efectivo = conteos.where((c) => c.medio.esEfectivo).firstOrNull;
    final detalle = conteos
        .map((c) => {
              'metodo_uuid': c.medio.metodoUuid,
              'metodo_nombre': c.medio.metodoNombre,
              'metodo_tipo': c.medio.metodoTipo,
              'esperado': c.medio.esperado.toApi(),
              'contado': c.contado?.toApi(),
              'diferencia': c.diferencia?.toApi(),
            })
        .toList();

    await db.transaction(() async {
      final cierre = await (db.select(db.cierresCaja)..where((t) => t.uuid.equals(turnoUuid))).getSingle();
      if (cierre.estado != 'ABIERTO') throw StateError('La caja ya está cerrada');

      await (db.update(db.cierresCaja)..where((t) => t.uuid.equals(turnoUuid))).write(
        CierresCajaCompanion(
          estado: const Value('CERRADO'),
          cerradoEn: Value(ahora),
          cierreTardio: Value(tardio),
          esperadoTotal: Value(conteos.fold<int>(0, (s, c) => s + c.medio.esperado.centavos)),
          contadoTotal: Value(conteos.fold<int>(0, (s, c) => s + (c.contado?.centavos ?? 0))),
          diferenciaEfectivo: Value(efectivo?.diferencia?.centavos),
          detalle: Value(jsonEncode(detalle)),
          notas: Value(notas),
          updatedAt: Value(ahora),
        ),
      );
      await outbox.encolar(
        'CIERRE_CERRAR',
        entidad: 'cierres_caja',
        entidadUuid: turnoUuid,
        payload: {
          'uuid': turnoUuid,
          'cerrado_en': ahora.toIso8601String(),
          'cierre_tardio': tardio,
          'notas': notas,
          'contado': conteos
              .where((c) => c.contado != null)
              .map((c) => {
                    'metodo_uuid': c.medio.metodoUuid,
                    'metodo_tipo': c.medio.metodoTipo,
                    'contado': c.contado!.toApi(),
                  })
              .toList(),
        },
      );
    });
  }

  Future<void> marcarRevisado(String turnoUuid) async {
    final estado = await _estado();
    final ahora = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.cierresCaja)..where((t) => t.uuid.equals(turnoUuid))).write(
        CierresCajaCompanion(
          revisadoPorUuid: Value(estado.usuarioUuid),
          revisadoEn: Value(ahora),
          updatedAt: Value(ahora),
        ),
      );
      await outbox.encolar(
        'CIERRE_REVISAR',
        entidad: 'cierres_caja',
        entidadUuid: turnoUuid,
        payload: {'uuid': turnoUuid},
      );
    });
  }

  /// Cierres de las sedes visibles (el vendedor sólo recibe los suyos).
  Stream<List<CierreConDatos>> observar({String? desde, String? usuarioUuid, List<String>? sedes}) {
    final consulta = db.select(db.cierresCaja).join([
      leftOuterJoin(db.usuarios, db.usuarios.uuid.equalsExp(db.cierresCaja.usuarioUuid)),
      leftOuterJoin(db.sedes, db.sedes.uuid.equalsExp(db.cierresCaja.sedeUuid)),
    ]);
    if (desde != null) {
      consulta.where(db.cierresCaja.abiertoEn.isBiggerOrEqualValue(DateTime.parse('${desde}T00:00:00Z')));
    }
    if (usuarioUuid != null) consulta.where(db.cierresCaja.usuarioUuid.equals(usuarioUuid));
    if (sedes != null) consulta.where(db.cierresCaja.sedeUuid.isIn(sedes));
    consulta
      ..orderBy([OrderingTerm.desc(db.cierresCaja.abiertoEn)])
      ..limit(200);
    return consulta.watch().map(
          (filas) => filas
              .map((f) => CierreConDatos(
                    cierre: f.readTable(db.cierresCaja),
                    usuario: f.readTableOrNull(db.usuarios),
                    sede: f.readTableOrNull(db.sedes),
                  ))
              .toList(),
        );
  }
}
