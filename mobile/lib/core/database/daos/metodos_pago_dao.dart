import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../money/money.dart';
import '../app_database.dart';
import 'outbox_dao.dart';

/// Medio de pago con cuánto se ha cobrado por él.
class MetodoPagoConUso {
  const MetodoPagoConUso({required this.metodo, required this.cobros});

  final MetodoPago metodo;

  /// Número de pagos registrados. Distingue el medio que se usa a diario del
  /// que quedó de una prueba, y es lo que justifica avisar antes de darlo de
  /// baja.
  final int cobros;

  String get uuid => metodo.uuid;
  String get nombre => metodo.nombre;
}

/// Cómo se comporta un medio al cobrar.
///
/// El NOMBRE lo pone el negocio («Nequi», «Llave Bre-B», «Datáfono»); el TIPO
/// es lo acotado, porque decide qué hace la pantalla de cobro.
extension ComportamientoMetodo on MetodoPago {
  /// Sólo el efectivo calcula vueltas: en los demás el importe es exacto.
  bool get esEfectivo => tipo == 'EFECTIVO';

  /// El fiado no ingresa dinero en el momento: deja un saldo pendiente.
  bool get esCredito => tipo == 'CREDITO';

  /// Puede mostrarle un QR al cliente para que pague desde su banco.
  bool get admiteQr => tipo == 'TRANSFERENCIA' || tipo == 'OTRO';

  bool get tieneQr => (qrLocal?.isNotEmpty ?? false) || (qrUrl?.isNotEmpty ?? false);
}

/// Medios de pago del negocio.
///
/// Escribe dominio y cola de salida en la MISMA transacción, como el resto del
/// catálogo: configurarlos **funciona sin conexión**.
class MetodosPagoDao {
  MetodosPagoDao(this.db, this.outbox);

  final AppDatabase db;
  final OutboxDao outbox;
  static const _uuid = Uuid();

  /// Tipos disponibles y qué significan para el cobro.
  static const tipos = <({String codigo, String etiqueta, String ayuda})>[
    (
      codigo: 'EFECTIVO',
      etiqueta: 'Efectivo',
      ayuda: 'Pide con cuánto paga y calcula las vueltas',
    ),
    (
      codigo: 'TRANSFERENCIA',
      etiqueta: 'Transferencia',
      ayuda: 'Nequi, Daviplata, llave Bre-B… puede mostrar un QR al cliente',
    ),
    (
      codigo: 'TARJETA',
      etiqueta: 'Tarjeta',
      ayuda: 'Datáfono. Puede pedir el número de aprobación',
    ),
    (
      codigo: 'CREDITO',
      etiqueta: 'Fiado',
      ayuda: 'No entra dinero ahora: queda como saldo pendiente del cliente',
    ),
    (codigo: 'OTRO', etiqueta: 'Otro', ayuda: 'Bonos, vales, cualquier otro medio'),
  ];

  static const paleta = <String>[
    '#11794F',
    '#1D4ED8',
    '#6750A4',
    '#9A5B00',
    '#B3261E',
    '#00696D',
    '#7D5260',
    '#4B5563',
  ];

  // ── Lecturas ──────────────────────────────────────────────────────────────

  /// Medios activos de la sede activa, en el orden configurado. Es lo que ve
  /// el vendedor al cobrar: los comunes a todas las sedes y los de la suya
  /// (su propio Nequi, su QR). Los de otras sedes no aparecen.
  Stream<List<MetodoPago>> observarActivos() {
    final estado = db.select(db.estadoApp)..where((t) => t.id.equals(1));
    return estado.watchSingleOrNull().asyncExpand((e) {
      final sede = e?.sedeActivaUuid;
      return (db.select(db.metodosPago)
            ..where((t) =>
                t.deletedAt.isNull() &
                t.activo.equals(true) &
                (t.sedeUuid.isNull() | (sede == null ? const Constant(false) : t.sedeUuid.equals(sede))))
            ..orderBy([
              (t) => OrderingTerm.asc(t.orden),
              (t) => OrderingTerm.asc(t.nombre),
            ]))
          .watch();
    });
  }

  /// Todos, incluidos los inactivos: es la vista de administración.
  Stream<List<MetodoPagoConUso>> observarTodos() {
    final consulta = db.select(db.metodosPago)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.orden),
        (t) => OrderingTerm.asc(t.nombre),
      ]);

    return consulta.watch().asyncMap((metodos) async {
      // Una sola consulta agregada: con 10 medios, una por fila serían 10
      // viajes a SQLite en cada repintado.
      final filas = await db.customSelect(
        'SELECT metodo_pago_uuid, COUNT(*) AS n FROM venta_pagos '
        'WHERE metodo_pago_uuid IS NOT NULL GROUP BY metodo_pago_uuid',
        readsFrom: {db.ventaPagos},
      ).get();

      final usos = {
        for (final f in filas) f.read<String>('metodo_pago_uuid'): f.read<int>('n'),
      };

      return [
        for (final m in metodos) MetodoPagoConUso(metodo: m, cobros: usos[m.uuid] ?? 0),
      ];
    });
  }

  Future<MetodoPago?> obtener(String uuid) =>
      (db.select(db.metodosPago)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  /// Dos «Nequi» en la lista de cobro son indistinguibles y parten el reporte
  /// de ingresos en dos filas.
  Future<MetodoPago?> porNombre(String nombre, {String? exceptoUuid}) async {
    final objetivo = nombre.trim().toLowerCase();
    final todos =
        await (db.select(db.metodosPago)..where((t) => t.deletedAt.isNull())).get();
    for (final m in todos) {
      if (m.nombre.trim().toLowerCase() == objetivo && m.uuid != exceptoUuid) return m;
    }
    return null;
  }

  /// QR ya elegidos pero aún sin subir. Los sube el motor de sincronización,
  /// igual que las fotos de producto.
  Future<List<MetodoPago>> conQrSinSubir() => (db.select(db.metodosPago)
        ..where((t) => t.qrLocal.isNotNull() & t.qrUrl.isNull() & t.deletedAt.isNull()))
      .get();

  // ── Mutaciones ────────────────────────────────────────────────────────────

  Future<String> crear({
    required String nombre,
    required String tipo,
    String color = '#0E6B5C',
    bool requiereReferencia = false,
    String? instrucciones,
    String? qrLocal,

    /// null = disponible en todas las sedes.
    String? sedeUuid,

    /// Sólo entidades de crédito: comisión en centésimas de punto (5 % = 500)
    /// y días en que suelen pagar.
    int? comisionPct,
    int? diasPago,
  }) async {
    final uuid = _uuid.v7();
    final ahora = DateTime.now().toUtc();
    final posicion = await _siguienteOrden();

    await db.transaction(() async {
      await db.into(db.metodosPago).insert(
            MetodosPagoCompanion.insert(
              uuid: uuid,
              nombre: nombre.trim(),
              tipo: Value(tipo),
              color: Value(color),
              requiereReferencia: Value(requiereReferencia),
              instrucciones: Value(_limpio(instrucciones)),
              qrLocal: Value(qrLocal),
              orden: Value(posicion),
              sedeUuid: Value(sedeUuid),
              comisionPct: Value(comisionPct),
              diasPago: Value(diasPago),
              updatedAt: Value(ahora),
            ),
          );

      // El QR no viaja aquí: primero hay que subir la imagen y obtener su URL.
      // De eso se encarga el motor de sincronización, que después encola un
      // METODO_PAGO_ACTUALIZAR con `qr_url`.
      await outbox.encolar(
        'METODO_PAGO_CREAR',
        entidad: 'metodos_pago',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'nombre': nombre.trim(),
          'tipo': tipo,
          'color': color,
          'requiere_referencia': requiereReferencia,
          'instrucciones': _limpio(instrucciones),
          'orden': posicion,
          'activo': true,
          'sede_uuid': sedeUuid,
          'comision_pct': comisionPct == null ? null : TasaIva(comisionPct).toApi(),
          'dias_pago': diasPago,
        },
      );
    });

    return uuid;
  }

  Future<void> actualizar(
    String uuid, {
    String? nombre,
    String? tipo,
    String? color,
    bool? requiereReferencia,
    String? instrucciones,
    String? qrLocal,
    String? qrUrl,
    bool? activo,
    int? orden,

    /// `Value.absent()` = no cambia; `Value(null)` = pasa a todas las sedes.
    Value<String?> sedeUuid = const Value.absent(),
    Value<int?> comisionPct = const Value.absent(),
    Value<int?> diasPago = const Value.absent(),
  }) async {
    final ahora = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.metodosPago)..where((t) => t.uuid.equals(uuid))).write(
        MetodosPagoCompanion(
          nombre: nombre == null ? const Value.absent() : Value(nombre.trim()),
          tipo: tipo == null ? const Value.absent() : Value(tipo),
          color: color == null ? const Value.absent() : Value(color),
          requiereReferencia: requiereReferencia == null
              ? const Value.absent()
              : Value(requiereReferencia),
          instrucciones: instrucciones == null
              ? const Value.absent()
              : Value(_limpio(instrucciones)),
          qrLocal: qrLocal == null ? const Value.absent() : Value(qrLocal),
          qrUrl: qrUrl == null ? const Value.absent() : Value(qrUrl),
          activo: activo == null ? const Value.absent() : Value(activo),
          orden: orden == null ? const Value.absent() : Value(orden),
          sedeUuid: sedeUuid,
          comisionPct: comisionPct,
          diasPago: diasPago,
          updatedAt: Value(ahora),
        ),
      );

      final payload = <String, dynamic>{'uuid': uuid};
      if (nombre != null) payload['nombre'] = nombre.trim();
      if (tipo != null) payload['tipo'] = tipo;
      if (color != null) payload['color'] = color;
      if (requiereReferencia != null) payload['requiere_referencia'] = requiereReferencia;
      if (instrucciones != null) payload['instrucciones'] = _limpio(instrucciones);
      if (qrUrl != null) payload['qr_url'] = qrUrl;
      if (activo != null) payload['activo'] = activo;
      if (orden != null) payload['orden'] = orden;
      if (sedeUuid.present) payload['sede_uuid'] = sedeUuid.value;
      if (comisionPct.present) {
        payload['comision_pct'] = comisionPct.value == null ? null : TasaIva(comisionPct.value!).toApi();
      }
      if (diasPago.present) payload['dias_pago'] = diasPago.value;

      // `qrLocal` es una ruta de ESTE teléfono: no significa nada en el
      // servidor ni en los demás dispositivos, así que nunca se envía.
      if (payload.length > 1) {
        await outbox.encolar(
          'METODO_PAGO_ACTUALIZAR',
          entidad: 'metodos_pago',
          entidadUuid: uuid,
          payload: payload,
        );
      }
    });
  }

  /// Baja lógica. Los pagos ya registrados conservan el nombre del medio, así
  /// que el histórico sigue diciendo por dónde entró el dinero.
  Future<void> eliminar(String uuid) async {
    final ahora = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.metodosPago)..where((t) => t.uuid.equals(uuid)))
          .write(MetodosPagoCompanion(deletedAt: Value(ahora), updatedAt: Value(ahora)));
      await outbox.encolar(
        'METODO_PAGO_ELIMINAR',
        entidad: 'metodos_pago',
        entidadUuid: uuid,
        payload: {'uuid': uuid},
      );
    });
  }

  Future<int> _siguienteOrden() async {
    final fila = await db.customSelect(
      'SELECT COALESCE(MAX(orden), 0) + 1 AS siguiente FROM metodos_pago '
      'WHERE deleted_at IS NULL',
      readsFrom: {db.metodosPago},
    ).getSingle();
    return fila.read<int>('siguiente');
  }

  static String? _limpio(String? valor) {
    final t = valor?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
