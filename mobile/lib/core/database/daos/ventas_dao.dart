import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../money/money.dart';
import '../../utils/fechas.dart';
import '../app_database.dart';
import 'inventario_dao.dart';
import 'outbox_dao.dart';

/// Línea lista para cobrar, tal como sale del carrito.
class LineaParaVender {
  const LineaParaVender({
    required this.productoUuid,
    required this.descripcion,
    required this.sku,
    required this.cantidad,
    required this.precioUnitario,
    required this.costoUnitario,
    required this.tasaIva,
    this.descuento = const Money.cero(),
  });

  final String productoUuid;
  final String descripcion;
  final String sku;
  final Cantidad cantidad;
  final Money precioUnitario;
  final Money costoUnitario;
  final TasaIva tasaIva;
  final Money descuento;
}

/// Un pago del cobro: con qué medio y cuánto.
///
/// Guarda el NOMBRE del medio además de su uuid. Si mañana se renombra «Nequi»
/// o se da de baja, el ticket ya entregado no puede cambiar: es un requisito
/// contable, no una desnormalización perezosa.
class PagoDeVenta {
  const PagoDeVenta({
    required this.metodoUuid,
    required this.metodoNombre,
    required this.metodoTipo,
    required this.monto,
    this.montoRecibido,
    this.referencia,
  });

  final String? metodoUuid;
  final String metodoNombre;
  final String metodoTipo;
  final Money monto;

  /// Sólo en efectivo. Va por pago y no por venta porque en un cobro mixto
  /// únicamente una parte se paga en efectivo.
  final Money? montoRecibido;

  final String? referencia;

  bool get esEfectivo => metodoTipo == 'EFECTIVO';

  /// Vueltas de ESTE pago. Nunca negativas: si entregó de menos, no hay cambio.
  Money get cambio {
    final recibido = montoRecibido;
    if (!esEfectivo || recibido == null || recibido <= monto) return const Money.cero();
    return recibido - monto;
  }
}

class VentaCompleta {
  const VentaCompleta({
    required this.venta,
    required this.detalles,
    this.pagos = const [],
  });

  final Venta venta;
  final List<VentaDetalle> detalles;

  /// Con qué medios se cobró. Es la trazabilidad que responde «esta venta,
  /// ¿entró por Nequi o en efectivo?» un mes después.
  final List<VentaPago> pagos;

  bool get fueMixto => pagos.length > 1;

  /// Vueltas totales entregadas, sumando las de cada pago en efectivo.
  Money get cambioTotal =>
      Money.sumar(pagos.map((p) => Money(p.cambio ?? 0)));

  Money get total => Money(venta.total);
  Money get subtotal => Money(venta.subtotal);
  Money get impuesto => Money(venta.impuestoTotal);
  Money get cambio => Money(venta.cambio ?? 0);
  bool get pendienteDeSync => venta.sincronizadaEn == null;
  bool get anulada => venta.estado == 'ANULADA';
}

String _etiquetaLegado(String codigo) => switch (codigo) {
      'EFECTIVO' => 'Efectivo',
      'TARJETA' => 'Tarjeta',
      'TRANSFERENCIA' => 'Transferencia',
      'CREDITO' => 'Fiado',
      'MIXTO' => 'Mixto',
      _ => codigo,
    };

class VentasDao {
  VentasDao(this.db, this.outbox, this.inventario);

  final AppDatabase db;
  final OutboxDao outbox;
  final InventarioDao inventario;
  static const _uuid = Uuid();

  /// Registra una venta completa **sin tocar la red**.
  ///
  /// Todo ocurre en una sola transacción SQLite:
  ///   1. se reserva el consecutivo de folio del dispositivo,
  ///   2. se calcula el importe con aritmética exacta,
  ///   3. se insertan cabecera y detalle,
  ///   4. se descuenta el stock mediante movimientos,
  ///   5. se encola la operación con su `client_op_id`.
  ///
  /// Si algo falla —o la app muere— se revierte entero: nunca queda una venta
  /// sin encolar ni un encolado sin venta.
  /// Pagos de una venta, en el orden en que se cobraron.
  Future<List<VentaPago>> pagosDe(String ventaUuid) =>
      (db.select(db.ventaPagos)..where((t) => t.ventaUuid.equals(ventaUuid))).get();

  Future<VentaCompleta> registrarVenta({
    required List<LineaParaVender> lineas,
    String metodoPago = 'EFECTIVO',
    Money? montoRecibido,

    /// Desglose del cobro. Si viene vacío se deriva un pago único por el total,
    /// para que el histórico quede completo igualmente.
    List<PagoDeVenta> pagos = const [],
    String? clienteNombre,
    String? clienteDocumento,
    String? notas,
    String? usuarioUuid,
  }) async {
    if (lineas.isEmpty) {
      throw ArgumentError('La venta no tiene líneas');
    }

    final ventaUuid = _uuid.v7();
    final ahora = DateTime.now().toUtc();
    final fechaLocal = Fechas.diaHabil(ahora);

    return db.transaction(() async {
      // 1. Folio. El prefijo lo asigna el servidor al registrar el dispositivo,
      //    de modo que dos cajas sin conexión nunca generan el mismo número.
      final estado = await (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingle();
      final secuencia = estado.secuenciaFolio + 1;
      final prefijo = estado.prefijoFolio ?? 'LOC';
      final numero = '$prefijo-${secuencia.toString().padLeft(6, '0')}';
      await (db.update(db.estadoApp)..where((t) => t.id.equals(1)))
          .write(EstadoAppCompanion(secuenciaFolio: Value(secuencia)));

      // 2. Cálculo exacto, línea a línea.
      final calculadas = <({LineaParaVender linea, LineaCalculada calculo})>[];
      for (final l in lineas) {
        calculadas.add((
          linea: l,
          calculo: calcularLinea(
            precioUnitario: l.precioUnitario,
            cantidad: l.cantidad,
            descuento: l.descuento,
            tasaIva: l.tasaIva,
          ),
        ));
      }

      final subtotal = Money.sumar(calculadas.map((c) => c.calculo.base));
      final impuesto = Money.sumar(calculadas.map((c) => c.calculo.impuesto));
      final descuento = Money.sumar(calculadas.map((c) => c.calculo.descuento));
      final total = Money.sumar(calculadas.map((c) => c.calculo.total));
      final costo = Money.sumar(
        calculadas.map((c) => c.linea.costoUnitario.porCantidad(c.linea.cantidad)),
      );

      final cambio = montoRecibido == null
          ? null
          : (montoRecibido > total ? montoRecibido - total : const Money.cero());

      // 3. Cabecera.
      await db.into(db.ventas).insert(
            VentasCompanion.insert(
              uuid: ventaUuid,
              numero: numero,
              usuarioUuid: Value(usuarioUuid),
              dispositivoUuid: Value(estado.dispositivoUuid),
              clienteNombre: Value(clienteNombre),
              clienteDocumento: Value(clienteDocumento),
              subtotal: Value(subtotal.centavos),
              descuentoTotal: Value(descuento.centavos),
              impuestoTotal: Value(impuesto.centavos),
              total: Value(total.centavos),
              costoTotal: Value(costo.centavos),
              metodoPago: Value(metodoPago),
              montoRecibido: Value(montoRecibido?.centavos),
              cambio: Value(cambio?.centavos),
              notas: Value(notas),
              fecha: ahora,
              fechaLocal: fechaLocal,
              updatedAt: Value(ahora),
            ),
          );

      // 4. Detalle, con instantánea de nombre y costo.
      final lineasPayload = <Map<String, dynamic>>[];
      var indice = 1;
      for (final c in calculadas) {
        final detalleUuid = _uuid.v7();
        await db.into(db.ventaDetalles).insert(
              VentaDetallesCompanion.insert(
                uuid: detalleUuid,
                ventaUuid: ventaUuid,
                productoUuid: Value(c.linea.productoUuid),
                linea: Value(indice),
                descripcion: c.linea.descripcion,
                skuSnapshot: Value(c.linea.sku),
                cantidad: c.linea.cantidad.milesimas,
                precioUnitario: c.linea.precioUnitario.centavos,
                costoUnitario: Value(c.linea.costoUnitario.centavos),
                descuento: Value(c.calculo.descuento.centavos),
                tasaIva: Value(c.linea.tasaIva.escalada),
                baseGravable: Value(c.calculo.base.centavos),
                impuesto: Value(c.calculo.impuesto.centavos),
                total: Value(c.calculo.total.centavos),
              ),
            );

        // 5. Descuento de stock. Se permite quedar en negativo: la mercancía ya
        //    salió por la puerta y rechazar la venta descuadraría la caja. El
        //    servidor levantará una alerta de sobreventa al sincronizar.
        //
        // El uuid del movimiento VIAJA en el payload: si el servidor inventara
        // otro, el pull lo bajaría como fila nueva y el kardex mostraría la
        // venta duplicada (una local con nube + una del servidor).
        final movimientoUuid = await inventario.aplicarMovimientoDeVenta(
          productoUuid: c.linea.productoUuid,
          tipo: 'VENTA',
          cantidad: c.linea.cantidad,
          ventaUuid: ventaUuid,
          precioUnitario: c.linea.precioUnitario,
          costoUnitario: c.linea.costoUnitario,
          usuarioUuid: usuarioUuid,
          motivo: 'Venta $numero',
          fecha: ahora,
        );

        lineasPayload.add({
          'uuid': detalleUuid,
          'producto_uuid': c.linea.productoUuid,
          'cantidad': c.linea.cantidad.toApi(),
          'precio_unitario': c.linea.precioUnitario.toApi(),
          'costo_unitario': c.linea.costoUnitario.toApi(),
          'descuento': c.calculo.descuento.toApi(),
          'tasa_iva': c.linea.tasaIva.toApi(),
          'descripcion': c.linea.descripcion,
          'movimiento_uuid': movimientoUuid,
        });
        indice++;
      }

      // 6. Encolado — en esta misma transacción, no después.
      // 5.b) Desglose del cobro.
      //
      // Siempre se escribe al menos una fila, incluso con un solo medio: así
      // el reporte de ingresos por medio mira en un único sitio y no tiene que
      // tratar aparte el caso simple.
      //
      // Los montos ya vienen cuadrados desde la pantalla de cobro; aquí se
      // vuelve a comprobar porque esta función también se llama desde código y
      // una venta que no cuadra descuadra la caja del día.
      final desglose = pagos.isNotEmpty
          ? pagos
          : [
              PagoDeVenta(
                metodoUuid: null,
                metodoNombre: _etiquetaLegado(metodoPago),
                metodoTipo: metodoPago == 'MIXTO' ? 'OTRO' : metodoPago,
                monto: total,
                montoRecibido: montoRecibido,
              ),
            ];

      final sumaPagos = Money.sumar(desglose.map((p) => p.monto));
      if (sumaPagos != total) {
        throw ArgumentError(
          'Los pagos suman ${sumaPagos.format()} y la venta totaliza ${total.format()}',
        );
      }

      final pagosPayload = <Map<String, dynamic>>[];
      for (final pago in desglose) {
        final pagoUuid = _uuid.v7();
        await db.into(db.ventaPagos).insert(
              VentaPagosCompanion.insert(
                uuid: pagoUuid,
                ventaUuid: ventaUuid,
                metodoPagoUuid: Value(pago.metodoUuid),
                metodoNombre: pago.metodoNombre,
                metodoTipo: Value(pago.metodoTipo),
                monto: pago.monto.centavos,
                montoRecibido: Value(pago.montoRecibido?.centavos),
                cambio: Value(pago.esEfectivo ? pago.cambio.centavos : null),
                referencia: Value(pago.referencia),
              ),
            );

        pagosPayload.add({
          'uuid': pagoUuid,
          'metodo_pago_uuid': pago.metodoUuid,
          'metodo_nombre': pago.metodoNombre,
          'metodo_tipo': pago.metodoTipo,
          'monto': pago.monto.toApi(),
          'monto_recibido': pago.montoRecibido?.toApi(),
          'cambio': pago.esEfectivo ? pago.cambio.toApi() : null,
          'referencia': pago.referencia,
        });
      }

      // La columna `metodoPago` es heredada y sigue existiendo porque el ticket
      // y los reportes antiguos la leen. Con varios medios guarda 'MIXTO'; el
      // desglose real vive en `venta_pagos`.
      if (desglose.length > 1) {
        await (db.update(db.ventas)..where((t) => t.uuid.equals(ventaUuid)))
            .write(const VentasCompanion(metodoPago: Value('MIXTO')));
      } else if (pagos.isNotEmpty) {
        await (db.update(db.ventas)..where((t) => t.uuid.equals(ventaUuid)))
            .write(VentasCompanion(metodoPago: Value(desglose.first.metodoTipo)));
      }

      await outbox.encolar(
        'VENTA_CREAR',
        entidad: 'ventas',
        entidadUuid: ventaUuid,
        payload: {
          'uuid': ventaUuid,
          'numero': numero,
          'cliente_nombre': clienteNombre,
          'cliente_documento': clienteDocumento,
          'metodo_pago': metodoPago,
          'monto_recibido': montoRecibido?.toApi(),
          'notas': notas,
          'fecha': ahora.toIso8601String(),
          'fecha_local': fechaLocal,
          'creada_offline': true,
          'lineas': lineasPayload,
          'pagos': pagosPayload,
        },
      );

      final venta = await (db.select(db.ventas)..where((t) => t.uuid.equals(ventaUuid))).getSingle();
      final detalles = await (db.select(db.ventaDetalles)
            ..where((t) => t.ventaUuid.equals(ventaUuid))
            ..orderBy([(t) => OrderingTerm.asc(t.linea)]))
          .get();

      return VentaCompleta(
        venta: venta,
        detalles: detalles,
        pagos: await pagosDe(ventaUuid),
      );
    });
  }

  /// Anula una venta. La original no se borra ni se edita en su contenido:
  /// cambia de estado y se emite un documento de reversa que la referencia.
  Future<void> anular(String ventaUuid, String motivo, {String? usuarioUuid}) async {
    await db.transaction(() async {
      final venta = await (db.select(db.ventas)..where((t) => t.uuid.equals(ventaUuid)))
          .getSingleOrNull();
      if (venta == null) throw StateError('La venta no existe');
      if (venta.estado == 'ANULADA') return; // idempotente

      final detalles = await (db.select(db.ventaDetalles)
            ..where((t) => t.ventaUuid.equals(ventaUuid)))
          .get();

      final ahora = DateTime.now().toUtc();
      final reversaUuid = _uuid.v7();

      await db.into(db.ventas).insert(
            VentasCompanion.insert(
              uuid: reversaUuid,
              numero: '${venta.numero}-R',
              usuarioUuid: Value(usuarioUuid),
              dispositivoUuid: Value(venta.dispositivoUuid),
              subtotal: Value(-venta.subtotal),
              descuentoTotal: Value(-venta.descuentoTotal),
              impuestoTotal: Value(-venta.impuestoTotal),
              total: Value(-venta.total),
              costoTotal: Value(-venta.costoTotal),
              metodoPago: Value(venta.metodoPago),
              estado: const Value('ANULADA'),
              anulaAVentaUuid: Value(ventaUuid),
              motivoAnulacion: Value(motivo),
              fecha: ahora,
              fechaLocal: Fechas.diaHabil(ahora),
              updatedAt: Value(ahora),
            ),
          );

      final movimientosPayload = <Map<String, dynamic>>[];
      for (final d in detalles) {
        await db.into(db.ventaDetalles).insert(
              VentaDetallesCompanion.insert(
                uuid: _uuid.v7(),
                ventaUuid: reversaUuid,
                productoUuid: Value(d.productoUuid),
                linea: Value(d.linea),
                descripcion: d.descripcion,
                skuSnapshot: Value(d.skuSnapshot),
                cantidad: -d.cantidad,
                precioUnitario: d.precioUnitario,
                costoUnitario: Value(d.costoUnitario),
                descuento: Value(-d.descuento),
                tasaIva: Value(d.tasaIva),
                baseGravable: Value(-d.baseGravable),
                impuesto: Value(-d.impuesto),
                total: Value(-d.total),
              ),
            );

        if (d.productoUuid != null) {
          final movimientoUuid = await inventario.aplicarMovimientoDeVenta(
            productoUuid: d.productoUuid!,
            tipo: 'ANULACION_VENTA',
            cantidad: Cantidad(d.cantidad),
            ventaUuid: reversaUuid,
            usuarioUuid: usuarioUuid,
            motivo: 'Anulación de ${venta.numero}: $motivo',
            fecha: ahora,
          );
          movimientosPayload.add({
            'producto_uuid': d.productoUuid,
            'movimiento_uuid': movimientoUuid,
          });
        }
      }

      await (db.update(db.ventas)..where((t) => t.uuid.equals(ventaUuid))).write(
        VentasCompanion(
          estado: const Value('ANULADA'),
          motivoAnulacion: Value(motivo),
          updatedAt: Value(ahora),
        ),
      );

      await outbox.encolar(
        'VENTA_ANULAR',
        entidad: 'ventas',
        entidadUuid: ventaUuid,
        payload: {
          'venta_uuid': ventaUuid,
          'uuid_reversa': reversaUuid,
          'motivo': motivo,
          'fecha': ahora.toIso8601String(),
          'fecha_local': Fechas.diaHabil(ahora),
          'creada_offline': true,
          'movimientos': movimientosPayload,
        },
      );
    });
  }

  // ── Lecturas ──────────────────────────────────────────────────────────────

  Stream<List<Venta>> observarVentas({
    String? desde,
    String? hasta,
    String? estado = 'COMPLETADA',
    bool incluirReversas = false,
    String? busqueda,
    /// Filtra por empleado. Lo usa el control de cajas del administrador, y
    /// también restringe al vendedor a ver únicamente sus propias ventas.
    String? usuarioUuid,
    int limite = 200,
  }) {
    final consulta = db.select(db.ventas)..where((t) => t.deletedAt.isNull());

    if (usuarioUuid != null) {
      consulta.where((t) => t.usuarioUuid.equals(usuarioUuid));
    }

    if (estado != null) {
      consulta.where((t) => t.estado.equals(estado));
    }
    if (!incluirReversas) {
      consulta.where((t) => t.anulaAVentaUuid.isNull());
    }
    if (desde != null) consulta.where((t) => t.fechaLocal.isBiggerOrEqualValue(desde));
    if (hasta != null) consulta.where((t) => t.fechaLocal.isSmallerOrEqualValue(hasta));
    if (busqueda != null && busqueda.trim().isNotEmpty) {
      final t = busqueda.trim();
      consulta.where((v) => v.numero.like('%$t%') | v.clienteNombre.like('%$t%'));
    }

    consulta
      ..orderBy([(t) => OrderingTerm.desc(t.fecha)])
      ..limit(limite);

    return consulta.watch();
  }

  Stream<VentaCompleta?> observarVenta(String uuid) {
    return (db.select(db.ventas)..where((t) => t.uuid.equals(uuid)))
        .watchSingleOrNull()
        .asyncMap((venta) async {
      if (venta == null) return null;
      final detalles = await (db.select(db.ventaDetalles)
            ..where((t) => t.ventaUuid.equals(uuid))
            ..orderBy([(t) => OrderingTerm.asc(t.linea)]))
          .get();
      return VentaCompleta(
        venta: venta,
        detalles: detalles,
        pagos: await pagosDe(uuid),
      );
    });
  }

  Future<VentaCompleta?> obtenerVenta(String uuid) async {
    final venta =
        await (db.select(db.ventas)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();
    if (venta == null) return null;
    final detalles = await (db.select(db.ventaDetalles)
          ..where((t) => t.ventaUuid.equals(uuid))
          ..orderBy([(t) => OrderingTerm.asc(t.linea)]))
        .get();
    return VentaCompleta(venta: venta, detalles: detalles, pagos: await pagosDe(uuid));
  }

  Stream<int> contarPendientesDeSync() {
    final consulta = db.selectOnly(db.ventas)
      ..addColumns([db.ventas.uuid.count()])
      ..where(db.ventas.sincronizadaEn.isNull() & db.ventas.deletedAt.isNull());
    return consulta.map((f) => f.read(db.ventas.uuid.count()) ?? 0).watchSingle();
  }

  /// Marca ventas y movimientos como sincronizados tras un push exitoso.
  Future<void> marcarSincronizadas(Iterable<String> uuids) async {
    if (uuids.isEmpty) return;
    final ahora = DateTime.now().toUtc();
    await (db.update(db.ventas)..where((t) => t.uuid.isIn(uuids)))
        .write(VentasCompanion(sincronizadaEn: Value(ahora)));
  }

  Future<void> marcarMovimientosSincronizados(Iterable<String> uuids) async {
    if (uuids.isEmpty) return;
    final ahora = DateTime.now().toUtc();
    await (db.update(db.movimientos)..where((t) => t.uuid.isIn(uuids)))
        .write(MovimientosCompanion(sincronizadoEn: Value(ahora)));
  }

  /// Tras un `VENTA_CREAR` / `VENTA_ANULAR` exitoso, los movimientos de esa
  /// venta no viajan como operación aparte en la outbox: hay que marcarlos
  /// aquí o el kardex los muestra eternamente con la nube de sync.
  Future<void> marcarMovimientosDeVentasSincronizados(Iterable<String> ventasUuids) async {
    if (ventasUuids.isEmpty) return;
    final ahora = DateTime.now().toUtc();
    await (db.update(db.movimientos)..where((t) => t.ventaUuid.isIn(ventasUuids)))
        .write(MovimientosCompanion(sincronizadoEn: Value(ahora)));
  }
}
