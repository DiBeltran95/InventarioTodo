import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../money/money.dart';
import '../../utils/fechas.dart';
import '../app_database.dart';
import 'outbox_dao.dart';

/// Signo que impone cada tipo de movimiento.
/// El cliente no puede convertir una VENTA en entrada mandando cantidad
/// positiva: el tipo manda. `AJUSTE` es el único que respeta el signo enviado.
const Map<String, int> signoMovimiento = {
  'INICIAL': 1,
  'ENTRADA': 1,
  'DEVOLUCION': 1,
  'ANULACION_VENTA': 1,
  'SALIDA': -1,
  'VENTA': -1,
  'MERMA': -1,
  // El signo de un traslado lo pone quien lo aplica: − en la sede origen, +
  // en la destino.
  'TRASLADO': 0,
  'AJUSTE': 0,
};

class MovimientoConProducto {
  const MovimientoConProducto({required this.movimiento, this.producto, this.proveedor});

  final Movimiento movimiento;
  final Producto? producto;
  final Proveedor? proveedor;

  Cantidad get cantidad => Cantidad(movimiento.cantidad);
  bool get esEntrada => movimiento.cantidad > 0;
  bool get pendienteDeSync => movimiento.sincronizadoEn == null;
}

/// Sede activa del dispositivo y usuario con sesión: lo que firma cada
/// movimiento local.
class ContextoLocal {
  const ContextoLocal({this.sedeUuid, this.usuarioUuid});
  final String? sedeUuid;
  final String? usuarioUuid;
}

class InventarioDao {
  InventarioDao(this.db, this.outbox);

  final AppDatabase db;
  final OutboxDao outbox;
  static const _uuid = Uuid();

  // ── Escritura del libro ───────────────────────────────────────────────────

  Future<ContextoLocal> contexto() async {
    final e = await (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull();
    return ContextoLocal(sedeUuid: e?.sedeActivaUuid, usuarioUuid: e?.usuarioUuid);
  }

  /// Stock de un producto en una sede según este dispositivo.
  Future<int> stockEnSede(String productoUuid, String sedeUuid) async {
    final fila = await (db.select(db.stockSedes)
          ..where((t) => t.productoUuid.equals(productoUuid) & t.sedeUuid.equals(sedeUuid)))
        .getSingleOrNull();
    return fila?.stockActual ?? 0;
  }

  /// Inserta un movimiento y actualiza las proyecciones de stock.
  ///
  /// **Éste es el único punto de la app que escribe el stock**: la fila de la
  /// sede en `stock_sedes` y, si es la sede activa, `productos.stockActual`,
  /// que es lo que leen la venta y el escáner. En el servidor ese papel lo
  /// cumplen los triggers; aquí no hay triggers, así que la disciplina la
  /// impone tener un solo escritor. Si el stock se escribiera también desde
  /// otro sitio, se descontaría el doble.
  ///
  /// Debe llamarse DENTRO de una transacción.
  Future<String> _aplicarMovimiento({
    required String productoUuid,
    required String tipo,
    required Cantidad cantidad,
    String? uuidExplicito,
    String? sedeUuid,
    Money? costoUnitario,
    Money? precioUnitario,
    String? ventaUuid,
    String? trasladoUuid,
    String? proveedorUuid,
    String? usuarioUuid,
    String? aprobadoPorUuid,
    String? lote,
    String? venceEl,
    String? documentoRef,
    String? motivo,
    DateTime? fecha,
  }) async {
    final signo = signoMovimiento[tipo];
    if (signo == null) {
      throw ArgumentError('Tipo de movimiento desconocido: $tipo');
    }
    if (cantidad.esCero) {
      throw ArgumentError('La cantidad no puede ser cero');
    }

    final magnitud = cantidad.milesimas.abs();
    final conSigno = signo == 0 ? cantidad.milesimas : signo * magnitud;

    final producto = await (db.select(db.productos)..where((t) => t.uuid.equals(productoUuid)))
        .getSingleOrNull();
    if (producto == null) {
      throw StateError('El producto $productoUuid no existe en la base local');
    }

    final ctx = await contexto();
    final sede = sedeUuid ?? ctx.sedeUuid;
    final esSedeActiva = sede == null || sede == ctx.sedeUuid;

    // Sin sede todavía (instalación recién actualizada antes de su primera
    // sincronización) se usa la proyección del producto, como antes.
    final stockAnterior = sede == null
        ? producto.stockActual
        : (esSedeActiva ? producto.stockActual : await stockEnSede(productoUuid, sede));
    final stockResultante = stockAnterior + conSigno;
    final uuid = uuidExplicito ?? _uuid.v7();
    final instante = (fecha ?? DateTime.now()).toUtc();

    await db.into(db.movimientos).insert(
          MovimientosCompanion.insert(
            uuid: uuid,
            productoUuid: productoUuid,
            tipo: tipo,
            cantidad: conSigno,
            costoUnitario: Value(costoUnitario?.centavos),
            precioUnitario: Value(precioUnitario?.centavos),
            stockAnterior: Value(stockAnterior),
            stockResultante: Value(stockResultante),
            ventaUuid: Value(ventaUuid),
            sedeUuid: Value(sede),
            trasladoUuid: Value(trasladoUuid),
            proveedorUuid: Value(proveedorUuid),
            usuarioUuid: Value(usuarioUuid ?? ctx.usuarioUuid),
            aprobadoPorUuid: Value(aprobadoPorUuid),
            lote: Value(lote),
            venceEl: Value(venceEl),
            documentoRef: Value(documentoRef),
            motivo: Value(motivo),
            fecha: instante,
            fechaLocal: Fechas.diaHabil(instante),
          ),
          mode: InsertMode.insertOrReplace,
        );

    if (sede != null) {
      final previa = await (db.select(db.stockSedes)
            ..where((t) => t.productoUuid.equals(productoUuid) & t.sedeUuid.equals(sede)))
          .getSingleOrNull();
      await db.into(db.stockSedes).insertOnConflictUpdate(
            StockSedesCompanion.insert(
              productoUuid: productoUuid,
              sedeUuid: sede,
              stockActual: Value(stockResultante),
              stockMinimo: Value(previa?.stockMinimo),
            ),
          );
    }

    if (esSedeActiva) {
      await (db.update(db.productos)..where((t) => t.uuid.equals(productoUuid))).write(
        ProductosCompanion(
          stockActual: Value(stockResultante),
          // No se toca `updatedAt`: el stock es derivado y su verdad la fija el
          // servidor en el pull. Marcarlo como modificado provocaría un
          // ida y vuelta innecesario en la sincronización del catálogo.
        ),
      );
    }

    return uuid;
  }

  /// Entrada de mercancía, merma, devolución… (todo lo que no es una venta).
  Future<String> registrarMovimiento({
    required String productoUuid,
    required String tipo,
    required Cantidad cantidad,
    Money? costoUnitario,

    /// Precio de venta nuevo, si la reposición llega con otro costo y hay que
    /// repercutirlo. `null` deja el precio como estaba.
    ///
    /// Va aquí y no en una llamada aparte para que el movimiento y el cambio de
    /// precio compartan transacción: o entran los dos o no entra ninguno. Si
    /// fueran dos operaciones sueltas y la app muriera en medio, quedaría el
    /// stock cargado al costo nuevo pero vendiéndose al precio viejo.
    Money? precioVenta,

    String? proveedorUuid,
    String? usuarioUuid,
    String? lote,
    String? venceEl,
    String? documentoRef,
    String? motivo,
  }) async {
    late String uuid;

    await db.transaction(() async {
      uuid = await _aplicarMovimiento(
        productoUuid: productoUuid,
        tipo: tipo,
        cantidad: cantidad,
        costoUnitario: costoUnitario,
        proveedorUuid: proveedorUuid,
        usuarioUuid: usuarioUuid,
        lote: lote,
        venceEl: venceEl,
        documentoRef: documentoRef,
        motivo: motivo,
      );

      // Igual que en el servidor: la última entrada fija el costo de compra.
      if (tipo == 'ENTRADA' && costoUnitario != null) {
        await (db.update(db.productos)..where((t) => t.uuid.equals(productoUuid)))
            .write(ProductosCompanion(precioCompra: Value(costoUnitario.centavos)));
      }

      // Precio de venta.
      //
      // El servidor NO lo deduce del movimiento —`MOVIMIENTO_CREAR` sólo lleva
      // el costo—, así que se encola además un `PRODUCTO_ACTUALIZAR`, que es
      // una operación que el backend ya sabe aplicar. Cambiar el precio es una
      // modificación del catálogo, de modo que sí toca `updatedAt`: es lo que
      // usa la resolución de conflictos para saber cuál gana.
      if (precioVenta != null) {
        final ahora = DateTime.now().toUtc();
        await (db.update(db.productos)..where((t) => t.uuid.equals(productoUuid))).write(
          ProductosCompanion(
            precioVenta: Value(precioVenta.centavos),
            updatedAt: Value(ahora),
          ),
        );

        await outbox.encolar(
          'PRODUCTO_ACTUALIZAR',
          entidad: 'productos',
          entidadUuid: productoUuid,
          payload: {'uuid': productoUuid, 'precio_venta': precioVenta.toApi()},
        );
      }

      await outbox.encolar(
        'MOVIMIENTO_CREAR',
        entidad: 'movimientos_inventario',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'producto_uuid': productoUuid,
          'tipo': tipo,
          'cantidad': cantidad.toApi(),
          'costo_unitario': costoUnitario?.toApi(),
          'proveedor_uuid': proveedorUuid,
          'lote': lote,
          'vence_el': venceEl,
          'documento_ref': documentoRef,
          'motivo': motivo,
          'fecha': DateTime.now().toUtc().toIso8601String(),
          'fecha_local': Fechas.hoy(),
          'creado_offline': true,
        },
      );
    });

    return uuid;
  }

  /// Ajuste por conteo físico: el usuario indica cuánto HAY, no la diferencia.
  /// Pedir la diferencia es una invitación a equivocarse.
  Future<String?> ajustarPorConteo({
    required String productoUuid,
    required Cantidad stockContado,
    String? motivo,
    String? usuarioUuid,
  }) async {
    String? uuid;

    await db.transaction(() async {
      final producto = await (db.select(db.productos)..where((t) => t.uuid.equals(productoUuid)))
          .getSingleOrNull();
      if (producto == null) throw StateError('Producto no encontrado');

      final diferencia = stockContado.milesimas - producto.stockActual;
      if (diferencia == 0) return;

      final anterior = Cantidad(producto.stockActual);
      uuid = await _aplicarMovimiento(
        productoUuid: productoUuid,
        tipo: 'AJUSTE',
        cantidad: Cantidad(diferencia),
        usuarioUuid: usuarioUuid,
        motivo: motivo ?? 'Conteo físico: ${anterior.format()} → ${stockContado.format()}',
      );

      await outbox.encolar(
        'CONTEO_AJUSTAR',
        entidad: 'movimientos_inventario',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'producto_uuid': productoUuid,
          'stock_contado': stockContado.toApi(),
          'motivo': motivo,
          'fecha': DateTime.now().toUtc().toIso8601String(),
          'creado_offline': true,
        },
      );
    });

    return uuid;
  }

  /// Usado por TrasladosDao dentro de su propia transacción: el traslado
  /// mueve stock de DOS sedes, así que la sede se indica explícitamente.
  Future<String> aplicarMovimientoDeTraslado({
    required String productoUuid,
    required String sedeUuid,
    required Cantidad cantidadConSigno,
    required String trasladoUuid,
    required String uuid,
    required String motivo,
  }) =>
      _aplicarMovimiento(
        productoUuid: productoUuid,
        tipo: 'TRASLADO',
        cantidad: cantidadConSigno,
        uuidExplicito: uuid,
        sedeUuid: sedeUuid,
        trasladoUuid: trasladoUuid,
        motivo: motivo,
      );

  /// Usado por AjustesDao al aprobar la solicitud de un auxiliar: el
  /// movimiento es del solicitante, con el aprobador registrado.
  Future<String> aplicarMovimientoAprobado({
    required String productoUuid,
    required String sedeUuid,
    required String tipo,
    required Cantidad cantidad,
    required String uuid,
    String? usuarioUuid,
    String? aprobadoPorUuid,
    String? motivo,
  }) =>
      _aplicarMovimiento(
        productoUuid: productoUuid,
        tipo: tipo,
        cantidad: cantidad,
        uuidExplicito: uuid,
        sedeUuid: sedeUuid,
        usuarioUuid: usuarioUuid,
        aprobadoPorUuid: aprobadoPorUuid,
        motivo: motivo,
      );

  /// Usado por VentasDao dentro de su propia transacción. `sedeUuid` sólo
  /// para anular: el stock vuelve a la sede de la venta original, que puede no
  /// ser la activa.
  Future<String> aplicarMovimientoDeVenta({
    required String productoUuid,
    required String tipo,
    required Cantidad cantidad,
    required String ventaUuid,
    String? sedeUuid,
    Money? precioUnitario,
    Money? costoUnitario,
    String? usuarioUuid,
    String? motivo,
    DateTime? fecha,
  }) =>
      _aplicarMovimiento(
        productoUuid: productoUuid,
        tipo: tipo,
        cantidad: cantidad,
        ventaUuid: ventaUuid,
        sedeUuid: sedeUuid,
        precioUnitario: precioUnitario,
        costoUnitario: costoUnitario,
        usuarioUuid: usuarioUuid,
        motivo: motivo,
        fecha: fecha,
      );

  // ── Lecturas ──────────────────────────────────────────────────────────────

  Stream<List<MovimientoConProducto>> observarMovimientos({
    String? productoUuid,
    String? tipo,
    String? desde,
    String? hasta,
    String? sedeUuid,
    int limite = 200,
  }) {
    final consulta = db.select(db.movimientos).join([
      leftOuterJoin(db.productos, db.productos.uuid.equalsExp(db.movimientos.productoUuid)),
      leftOuterJoin(db.proveedores, db.proveedores.uuid.equalsExp(db.movimientos.proveedorUuid)),
    ]);

    if (productoUuid != null) {
      consulta.where(db.movimientos.productoUuid.equals(productoUuid));
    }
    if (tipo != null) consulta.where(db.movimientos.tipo.equals(tipo));
    if (sedeUuid != null) consulta.where(db.movimientos.sedeUuid.equals(sedeUuid));
    if (desde != null) {
      consulta.where(db.movimientos.fechaLocal.isBiggerOrEqualValue(desde));
    }
    if (hasta != null) {
      consulta.where(db.movimientos.fechaLocal.isSmallerOrEqualValue(hasta));
    }

    consulta
      ..orderBy([OrderingTerm.desc(db.movimientos.fecha)])
      ..limit(limite);

    return consulta.watch().map(
          (filas) => filas
              .map((f) => MovimientoConProducto(
                    movimiento: f.readTable(db.movimientos),
                    producto: f.readTableOrNull(db.productos),
                    proveedor: f.readTableOrNull(db.proveedores),
                  ))
              .toList(),
        );
  }

  Stream<List<Alerta>> observarAlertas() => (db.select(db.alertas)
        ..where((t) => t.resueltaEn.isNull())
        ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
        ..limit(50))
      .watch();

  /// Reconstruye el stock desde el libro local. Red de seguridad equivalente a
  /// `sp_recalcular_stock` del servidor: por sede y la proyección de la activa.
  Future<void> recalcularStock() async {
    await db.transaction(() async {
      final ctx = await contexto();
      final sumas = await db
          .customSelect(
            'SELECT producto_uuid, sede_uuid, COALESCE(SUM(cantidad),0) AS total '
            'FROM movimientos WHERE sede_uuid IS NOT NULL GROUP BY producto_uuid, sede_uuid',
            readsFrom: {db.movimientos},
          )
          .get();

      for (final fila in sumas) {
        final producto = fila.read<String>('producto_uuid');
        final sede = fila.read<String>('sede_uuid');
        final total = fila.read<int>('total');
        await (db.update(db.stockSedes)
              ..where((t) => t.productoUuid.equals(producto) & t.sedeUuid.equals(sede)))
            .write(StockSedesCompanion(stockActual: Value(total)));
        if (sede == ctx.sedeUuid) {
          await (db.update(db.productos)..where((t) => t.uuid.equals(producto)))
              .write(ProductosCompanion(stockActual: Value(total)));
        }
      }
    });
  }
}
