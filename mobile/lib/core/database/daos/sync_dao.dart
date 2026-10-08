import 'dart:convert';

import 'package:drift/drift.dart';

import '../../money/money.dart';
import '../app_database.dart';

/// Aplica en la base local lo que llega del servidor y custodia los cursores.
class SyncDao {
  SyncDao(this.db);

  final AppDatabase db;

  // ── Cursores ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> cursores() async {
    final filas = await db.select(db.syncCursores).get();
    return {
      for (final f in filas)
        f.entidad: {'t': f.cursorT.toUtc().toIso8601String(), 'i': f.cursorI},
    };
  }

  Future<void> guardarCursor(String entidad, String iso, int id) async {
    await db.into(db.syncCursores).insertOnConflictUpdate(
          SyncCursoresCompanion.insert(
            entidad: entidad,
            cursorT: DateTime.parse(iso).toUtc(),
            cursorI: Value(id),
            ultimoSync: Value(DateTime.now().toUtc()),
          ),
        );
  }

  Future<void> reiniciarCursores() => db.delete(db.syncCursores).go();

  /// Elimina movimientos locales huérfanos de ventas ya bajadas del servidor.
  ///
  /// Corrige dispositivos que sincronizaron con la versión anterior del bug
  /// (venta local + movimiento del servidor con otro uuid).
  Future<int> purgarMovimientosDuplicadosDeVenta() async {
    return db.customUpdate(
      '''
      DELETE FROM movimientos
      WHERE sincronizado_en IS NULL
        AND venta_uuid IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM movimientos AS m2
          WHERE m2.venta_uuid = movimientos.venta_uuid
            AND m2.producto_uuid = movimientos.producto_uuid
            AND m2.tipo = movimientos.tipo
            AND m2.uuid != movimientos.uuid
            AND m2.sincronizado_en IS NOT NULL
        )
      ''',
      updates: {db.movimientos},
      updateKind: UpdateKind.delete,
    );
  }

  // ── Aplicación de la bajada ───────────────────────────────────────────────

  /// Aplica un bloque de cambios del servidor.
  ///
  /// Dos reglas gobiernan los conflictos (ver docs/ARQUITECTURA.md §3.4):
  ///
  ///  1. **No se pisa lo que aún no se ha enviado.** Si una entidad tiene una
  ///     operación pendiente en la cola, la versión del servidor se descarta:
  ///     lo local es más nuevo por definición.
  ///
  ///  2. **El stock del servidor es autoritativo, pero se le suman los
  ///     movimientos locales aún sin enviar.** Si no, el pull "revertiría" en
  ///     pantalla las tres ventas que todavía están en la cola.
  Future<int> aplicarCambios(Map<String, dynamic> entidades) async {
    var total = 0;

    await db.transaction(() async {
      final bloqueados = await _uuidsConCambiosPendientes();

      total += await _aplicarSedes(entidades['sedes']);
      total += await _aplicarUsuarios(entidades['usuarios'], bloqueados);
      total += await _aplicarCategorias(entidades['categorias'], bloqueados);
      total += await _aplicarProveedores(entidades['proveedores'], bloqueados);
      total += await _aplicarMetodosPago(entidades['metodos_pago'], bloqueados);
      total += await _aplicarProductos(entidades['productos'], bloqueados);
      total += await _aplicarCodigos(entidades['producto_codigos'], bloqueados);
      total += await _aplicarVentas(entidades['ventas'], bloqueados);
      total += await _aplicarDetalles(entidades['venta_detalles']);
      total += await _aplicarPagos(entidades['venta_pagos']);
      total += await _aplicarMovimientos(entidades['movimientos_inventario']);
      // Después de los movimientos: el stock de cada sede suma los
      // movimientos locales que aún no han salido, y los que acaban de bajar
      // ya cuentan como sincronizados.
      total += await _aplicarStockSedes(entidades['stock_sedes']);
      total += await _aplicarAlertas(entidades['alertas']);
      total += await _aplicarTraslados(entidades['traslados'], bloqueados);
      total += await _aplicarTrasladoDetalles(entidades['traslado_detalles']);
      total += await _aplicarTrasladoEventos(entidades['traslado_eventos']);
      total += await _aplicarSolicitudesAjuste(entidades['solicitudes_ajuste'], bloqueados);
      total += await _aplicarCierres(entidades['cierres_caja'], bloqueados);
      total += await _aplicarRecaudos(entidades['recaudos'], bloqueados);
      total += await _aplicarConfiguracion(entidades['configuracion']);

      for (final entrada in entidades.entries) {
        final bloque = entrada.value;
        if (bloque is! Map) continue;
        final cursor = bloque['cursor'];
        if (cursor is Map && cursor['t'] != null) {
          await guardarCursor(entrada.key, cursor['t'] as String, (cursor['i'] as num).toInt());
        }
      }
    });

    return total;
  }

  Future<Set<String>> _uuidsConCambiosPendientes() async {
    final filas = await (db.select(db.syncOutbox)
          ..where((t) => t.estado.isIn(['PENDIENTE', 'ENVIANDO'])))
        .get();
    return filas.map((f) => f.entidadUuid).whereType<String>().toSet();
  }

  List<Map<String, dynamic>> _items(dynamic bloque) {
    if (bloque is! Map) return const [];
    final items = bloque['items'];
    if (items is! List) return const [];
    return items.cast<Map<String, dynamic>>();
  }

  DateTime _fecha(dynamic v) =>
      v == null ? DateTime.now().toUtc() : DateTime.parse(v as String).toUtc();

  DateTime? _fechaOpcional(dynamic v) =>
      v == null ? null : DateTime.tryParse(v as String)?.toUtc();

  int _centavos(dynamic v) => Money.tryParse(v as String?).centavos;
  int _milesimas(dynamic v) => Cantidad.tryParse(v as String?).milesimas;

  // ── Por entidad ───────────────────────────────────────────────────────────

  Future<int> _aplicarUsuarios(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque);
    for (final u in items) {
      // Se preservan el hash y la sal locales: el servidor no los conoce y
      // sobrescribirlos con null dejaría al usuario sin login offline.
      final existente = await (db.select(db.usuarios)
            ..where((t) => t.uuid.equals(u['uuid'] as String)))
          .getSingleOrNull();

      await db.into(db.usuarios).insertOnConflictUpdate(
            UsuariosCompanion.insert(
              uuid: u['uuid'] as String,
              nombre: u['nombre'] as String,
              email: u['email'] as String,
              rol: Value(u['rol'] as String? ?? 'VENDEDOR'),
              activo: Value(u['activo'] == true || u['activo'] == 1),
              passwordHashLocal: Value(existente?.passwordHashLocal),
              saltLocal: Value(existente?.saltLocal),
              restringirHorario: Value(_bool(u['restringir_horario'])),
              horario: Value(_textoJson(u['horario'])),
              accesoExtraHasta: Value(_fechaOpcional(u['acceso_extra_hasta'])),
              sedes: Value((u['sedes'] as String?) ?? ''),
              updatedAt: Value(_fecha(u['updated_at'])),
              deletedAt: Value(_fechaOpcional(u['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarCategorias(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((c) => !bloqueados.contains(c['uuid'])).toList();
    for (final c in items) {
      await db.into(db.categorias).insertOnConflictUpdate(
            CategoriasCompanion.insert(
              uuid: c['uuid'] as String,
              nombre: c['nombre'] as String,
              descripcion: Value(c['descripcion'] as String?),
              color: Value(c['color'] as String? ?? '#6750A4'),
              icono: Value(c['icono'] as String?),
              orden: Value((c['orden'] as num?)?.toInt() ?? 0),
              updatedAt: Value(_fecha(c['updated_at'])),
              deletedAt: Value(_fechaOpcional(c['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarProveedores(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((p) => !bloqueados.contains(p['uuid'])).toList();
    for (final p in items) {
      await db.into(db.proveedores).insertOnConflictUpdate(
            ProveedoresCompanion.insert(
              uuid: p['uuid'] as String,
              nombre: p['nombre'] as String,
              nit: Value(p['nit'] as String?),
              contacto: Value(p['contacto'] as String?),
              telefono: Value(p['telefono'] as String?),
              email: Value(p['email'] as String?),
              direccion: Value(p['direccion'] as String?),
              notas: Value(p['notas'] as String?),
              updatedAt: Value(_fecha(p['updated_at'])),
              deletedAt: Value(_fechaOpcional(p['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarMetodosPago(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((m) => !bloqueados.contains(m['uuid'])).toList();
    for (final m in items) {
      // `qrLocal` NO se toca: es la copia de este teléfono y el servidor no
      // sabe nada de ella. Sobrescribirla con `absent` la perdería en cada
      // bajada y el QR dejaría de verse sin conexión.
      await db.into(db.metodosPago).insertOnConflictUpdate(
            MetodosPagoCompanion.insert(
              uuid: m['uuid'] as String,
              nombre: m['nombre'] as String,
              tipo: Value((m['tipo'] as String?) ?? 'OTRO'),
              requiereReferencia: Value(_bool(m['requiere_referencia'])),
              qrUrl: Value(m['qr_url'] as String?),
              instrucciones: Value(m['instrucciones'] as String?),
              sedeUuid: Value(m['sede_uuid'] as String?),
              comisionPct: Value(
                m['comision_pct'] == null ? null : TasaIva.parse(m['comision_pct'].toString()).escalada,
              ),
              diasPago: Value((m['dias_pago'] as num?)?.toInt()),
              color: Value((m['color'] as String?) ?? '#0E6B5C'),
              orden: Value((m['orden'] as num?)?.toInt() ?? 0),
              activo: Value(_bool(m['activo'], porDefecto: true)),
              updatedAt: Value(_fecha(m['updated_at'])),
              deletedAt: Value(_fechaOpcional(m['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarPagos(dynamic bloque) async {
    final items = _items(bloque);
    for (final p in items) {
      await db.into(db.ventaPagos).insertOnConflictUpdate(
            VentaPagosCompanion.insert(
              uuid: p['uuid'] as String,
              ventaUuid: p['venta_uuid'] as String,
              metodoPagoUuid: Value(p['metodo_pago_uuid'] as String?),
              metodoNombre: p['metodo_nombre'] as String,
              metodoTipo: Value((p['metodo_tipo'] as String?) ?? 'OTRO'),
              monto: _centavos(p['monto']),
              montoRecibido: Value(
                p['monto_recibido'] == null ? null : _centavos(p['monto_recibido']),
              ),
              cambio: Value(p['cambio'] == null ? null : _centavos(p['cambio'])),
              referencia: Value(p['referencia'] as String?),
              cobrado: Value(p['cobrado'] == null ? 0 : _centavos(p['cobrado'])),
            ),
          );
    }
    return items.length;
  }

  /// MariaDB devuelve los TINYINT(1) como 0/1, no como booleanos.
  bool _bool(dynamic v, {bool porDefecto = false}) {
    if (v == null) return porDefecto;
    if (v is bool) return v;
    if (v is num) return v != 0;
    return v.toString() == 'true' || v.toString() == '1';
  }

  Future<int> _aplicarProductos(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((p) => !bloqueados.contains(p['uuid'])).toList();
    final sedeActiva = await _sedeActiva();

    for (final p in items) {
      final uuid = p['uuid'] as String;
      final existente =
          await (db.select(db.productos)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

      // El `stock_actual` que trae el producto es el TOTAL de todas las sedes
      // (lo lee la app vieja). Aquí el stock es el de la sede activa y lo fija
      // `stock_sedes`; el producto sólo aporta su mínimo general, que vale en
      // las sedes sin mínimo propio.
      final minimoGeneral = _milesimas(p['stock_minimo']);
      final minimoSede = sedeActiva == null
          ? null
          : (await (db.select(db.stockSedes)
                    ..where((t) => t.productoUuid.equals(uuid) & t.sedeUuid.equals(sedeActiva)))
                  .getSingleOrNull())
              ?.stockMinimo;

      await db.into(db.productos).insertOnConflictUpdate(
            ProductosCompanion.insert(
              uuid: uuid,
              sku: p['sku'] as String,
              nombre: p['nombre'] as String,
              nombreBusqueda: Value(normalizarBusqueda(p['nombre'] as String)),
              descripcion: Value(p['descripcion'] as String?),
              categoriaUuid: Value(p['categoria_uuid'] as String?),
              unidadMedida: Value(p['unidad_medida'] as String? ?? 'UND'),
              precioCompra: Value(_centavos(p['precio_compra'])),
              precioVenta: Value(_centavos(p['precio_venta'])),
              tasaIva: Value(TasaIva.parse((p['tasa_iva'] as String?) ?? '0.00').escalada),
              // Un producto nuevo empieza en 0 en esta sede hasta que llegue su
              // fila de stock; uno existente conserva la que ya tenía.
              stockActual: existente == null ? const Value(0) : const Value.absent(),
              stockMinimo: Value(minimoSede ?? minimoGeneral),
              stockMinimoGeneral: Value(minimoGeneral),
              stockMaximo: Value(
                p['stock_maximo'] == null ? null : _milesimas(p['stock_maximo']),
              ),
              imagenUrl: Value(p['imagen_url'] as String?),
              // La foto local sobrevive al pull hasta que se sube.
              imagenLocal: Value(existente?.imagenLocal),
              ubicacion: Value(p['ubicacion'] as String?),
              activo: Value(p['activo'] == true || p['activo'] == 1),
              updatedAt: Value(_fecha(p['updated_at'])),
              deletedAt: Value(_fechaOpcional(p['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  /// Stock por sede: el del servidor más lo que este teléfono movió en esa sede
  /// y todavía no ha subido. Sin esa suma, un pull haría «reaparecer» en
  /// pantalla el stock de las ventas que siguen en la cola.
  Future<int> _aplicarStockSedes(dynamic bloque) async {
    final items = _items(bloque);
    final sedeActiva = await _sedeActiva();

    for (final f in items) {
      final producto = f['producto_uuid'] as String;
      final sede = f['sede_uuid'] as String;
      final stock = _milesimas(f['stock_actual']) + await _movimientosNoSincronizados(producto, sede);
      final minimo = f['stock_minimo'] == null ? null : _milesimas(f['stock_minimo']);

      await db.into(db.stockSedes).insertOnConflictUpdate(
            StockSedesCompanion.insert(
              productoUuid: producto,
              sedeUuid: sede,
              stockActual: Value(stock),
              stockMinimo: Value(minimo),
              updatedAt: Value(_fecha(f['updated_at'])),
            ),
          );

      if (sede == sedeActiva) {
        final general = (await (db.select(db.productos)..where((t) => t.uuid.equals(producto)))
                .getSingleOrNull())
            ?.stockMinimoGeneral;
        await (db.update(db.productos)..where((t) => t.uuid.equals(producto))).write(
          ProductosCompanion(
            stockActual: Value(stock),
            stockMinimo: Value(minimo ?? general ?? 0),
          ),
        );
      }
    }
    return items.length;
  }

  Future<String?> _sedeActiva() async =>
      (await (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull())
          ?.sedeActivaUuid;

  Future<int> _movimientosNoSincronizados(String productoUuid, String sedeUuid) async {
    final fila = await db
        .customSelect(
          'SELECT COALESCE(SUM(cantidad),0) AS total FROM movimientos '
          'WHERE producto_uuid = ? AND sede_uuid = ? AND sincronizado_en IS NULL',
          variables: [Variable<String>(productoUuid), Variable<String>(sedeUuid)],
          readsFrom: {db.movimientos},
        )
        .getSingle();
    return fila.read<int>('total');
  }

  Future<int> _aplicarCodigos(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((c) => !bloqueados.contains(c['uuid'])).toList();
    for (final c in items) {
      await db.into(db.productoCodigos).insertOnConflictUpdate(
            ProductoCodigosCompanion.insert(
              uuid: c['uuid'] as String,
              productoUuid: c['producto_uuid'] as String,
              codigo: c['codigo'] as String,
              tipo: Value(c['tipo'] as String? ?? 'INTERNO'),
              esPrincipal: Value(c['es_principal'] == true || c['es_principal'] == 1),
              factor: Value(_milesimas(c['factor'] ?? '1.000')),
              updatedAt: Value(_fecha(c['updated_at'])),
              deletedAt: Value(_fechaOpcional(c['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarVentas(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((v) => !bloqueados.contains(v['uuid'])).toList();
    for (final v in items) {
      await db.into(db.ventas).insertOnConflictUpdate(
            VentasCompanion.insert(
              uuid: v['uuid'] as String,
              numero: v['numero'] as String,
              usuarioUuid: Value(v['usuario_uuid'] as String?),
              dispositivoUuid: Value(v['dispositivo_uuid'] as String?),
              sedeUuid: Value(v['sede_uuid'] as String?),
              turnoUuid: Value(v['turno_uuid'] as String?),
              clienteNombre: Value(v['cliente_nombre'] as String?),
              clienteDocumento: Value(v['cliente_documento'] as String?),
              subtotal: Value(_centavos(v['subtotal'])),
              descuentoTotal: Value(_centavos(v['descuento_total'])),
              impuestoTotal: Value(_centavos(v['impuesto_total'])),
              total: Value(_centavos(v['total'])),
              costoTotal: Value(_centavos(v['costo_total'])),
              metodoPago: Value(v['metodo_pago'] as String? ?? 'EFECTIVO'),
              montoRecibido: Value(
                v['monto_recibido'] == null ? null : _centavos(v['monto_recibido']),
              ),
              cambio: Value(v['cambio'] == null ? null : _centavos(v['cambio'])),
              estado: Value(v['estado'] as String? ?? 'COMPLETADA'),
              anulaAVentaUuid: Value(v['anula_a_venta_uuid'] as String?),
              motivoAnulacion: Value(v['motivo_anulacion'] as String?),
              notas: Value(v['notas'] as String?),
              fecha: _fecha(v['fecha']),
              fechaLocal: v['fecha_local'] as String,
              creadaOffline: Value(v['creada_offline'] == true || v['creada_offline'] == 1),
              // Si viene del servidor, por definición está sincronizada.
              sincronizadaEn: Value(_fecha(v['updated_at'])),
              updatedAt: Value(_fecha(v['updated_at'])),
              deletedAt: Value(_fechaOpcional(v['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarDetalles(dynamic bloque) async {
    final items = _items(bloque);
    for (final d in items) {
      await db.into(db.ventaDetalles).insertOnConflictUpdate(
            VentaDetallesCompanion.insert(
              uuid: d['uuid'] as String,
              ventaUuid: d['venta_uuid'] as String,
              productoUuid: Value(d['producto_uuid'] as String?),
              linea: Value((d['linea'] as num?)?.toInt() ?? 1),
              descripcion: d['descripcion'] as String,
              skuSnapshot: Value(d['sku_snapshot'] as String?),
              cantidad: _milesimas(d['cantidad']),
              precioUnitario: _centavos(d['precio_unitario']),
              costoUnitario: Value(_centavos(d['costo_unitario'])),
              descuento: Value(_centavos(d['descuento'])),
              tasaIva: Value(TasaIva.parse((d['tasa_iva'] as String?) ?? '0.00').escalada),
              baseGravable: Value(_centavos(d['base_gravable'])),
              impuesto: Value(_centavos(d['impuesto'])),
              total: Value(_centavos(d['total'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarMovimientos(dynamic bloque) async {
    final items = _items(bloque);
    for (final m in items) {
      final uuid = m['uuid'] as String;
      final ventaUuid = m['venta_uuid'] as String?;
      final productoUuid = m['producto_uuid'] as String;
      final tipo = m['tipo'] as String;

      // Limpieza de duplicados de ventas offline: el cliente escribió el
      // movimiento con uuid A; versiones viejas del servidor crearon uuid B.
      // Al bajar B, se borra la copia local A (aún sin sincronizar) para que
      // el kardex no muestre la misma venta dos veces.
      if (ventaUuid != null) {
        await (db.delete(db.movimientos)
              ..where(
                (t) =>
                    t.ventaUuid.equals(ventaUuid) &
                    t.productoUuid.equals(productoUuid) &
                    t.tipo.equals(tipo) &
                    t.uuid.isNotValue(uuid) &
                    t.sincronizadoEn.isNull(),
              ))
            .go();
      }

      await db.into(db.movimientos).insertOnConflictUpdate(
            MovimientosCompanion.insert(
              uuid: uuid,
              productoUuid: productoUuid,
              tipo: tipo,
              cantidad: _milesimas(m['cantidad']),
              costoUnitario: Value(
                m['costo_unitario'] == null ? null : _centavos(m['costo_unitario']),
              ),
              precioUnitario: Value(
                m['precio_unitario'] == null ? null : _centavos(m['precio_unitario']),
              ),
              stockAnterior: Value(
                m['stock_anterior'] == null ? null : _milesimas(m['stock_anterior']),
              ),
              stockResultante: Value(
                m['stock_resultante'] == null ? null : _milesimas(m['stock_resultante']),
              ),
              ventaUuid: Value(ventaUuid),
              sedeUuid: Value(m['sede_uuid'] as String?),
              trasladoUuid: Value(m['traslado_uuid'] as String?),
              proveedorUuid: Value(m['proveedor_uuid'] as String?),
              usuarioUuid: Value(m['usuario_uuid'] as String?),
              aprobadoPorUuid: Value(m['aprobado_por_uuid'] as String?),
              lote: Value(m['lote'] as String?),
              venceEl: Value(m['vence_el'] as String?),
              documentoRef: Value(m['documento_ref'] as String?),
              motivo: Value(m['motivo'] as String?),
              fecha: _fecha(m['fecha']),
              fechaLocal: m['fecha_local'] as String,
              creadoOffline: Value(m['creado_offline'] == true || m['creado_offline'] == 1),
              sincronizadoEn: Value(_fecha(m['updated_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarAlertas(dynamic bloque) async {
    final items = _items(bloque);
    for (final a in items) {
      await db.into(db.alertas).insertOnConflictUpdate(
            AlertasCompanion.insert(
              uuid: a['uuid'] as String,
              tipo: a['tipo'] as String,
              severidad: Value(a['severidad'] as String? ?? 'ADVERTENCIA'),
              productoUuid: Value(a['producto_uuid'] as String?),
              sedeUuid: Value(a['sede_uuid'] as String?),
              ventaUuid: Value(a['venta_uuid'] as String?),
              mensaje: a['mensaje'] as String,
              resueltaEn: Value(_fechaOpcional(a['resuelta_en'])),
              updatedAt: Value(_fecha(a['updated_at'])),
            ),
          );
    }
    return items.length;
  }

  /// El horario llega como texto JSON desde MariaDB o como lista ya decodificada.
  String? _textoJson(dynamic v) {
    if (v == null) return null;
    if (v is String) return v.isEmpty ? null : v;
    return jsonEncode(v);
  }

  int? _milesimasOpcional(dynamic v) => v == null ? null : _milesimas(v);
  int? _centavosOpcional(dynamic v) => v == null ? null : _centavos(v);

  Future<int> _aplicarSedes(dynamic bloque) async {
    final items = _items(bloque);
    for (final s in items) {
      await db.into(db.sedes).insertOnConflictUpdate(
            SedesCompanion.insert(
              uuid: s['uuid'] as String,
              nombre: s['nombre'] as String,
              codigo: s['codigo'] as String,
              direccion: Value(s['direccion'] as String?),
              telefono: Value(s['telefono'] as String?),
              esPrincipal: Value(_bool(s['es_principal'])),
              activo: Value(_bool(s['activo'], porDefecto: true)),
              updatedAt: Value(_fecha(s['updated_at'])),
              deletedAt: Value(_fechaOpcional(s['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarTraslados(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((t) => !bloqueados.contains(t['uuid'])).toList();
    for (final t in items) {
      await db.into(db.traslados).insertOnConflictUpdate(
            TrasladosCompanion.insert(
              uuid: t['uuid'] as String,
              numero: t['numero'] as String,
              sedeOrigenUuid: t['sede_origen_uuid'] as String,
              sedeDestinoUuid: t['sede_destino_uuid'] as String,
              estado: Value(t['estado'] as String? ?? 'PENDIENTE'),
              confirma: Value(t['confirma'] as String? ?? 'GESTOR'),
              notas: Value(t['notas'] as String?),
              solicitadoPorUuid: Value(t['solicitado_por_uuid'] as String?),
              solicitadoEn: _fecha(t['solicitado_en']),
              resueltoPorUuid: Value(t['resuelto_por_uuid'] as String?),
              resueltoEn: Value(_fechaOpcional(t['resuelto_en'])),
              motivoRechazo: Value(t['motivo_rechazo'] as String?),
              updatedAt: Value(_fecha(t['updated_at'])),
              deletedAt: Value(_fechaOpcional(t['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarTrasladoDetalles(dynamic bloque) async {
    final items = _items(bloque);
    for (final d in items) {
      await db.into(db.trasladoDetalles).insertOnConflictUpdate(
            TrasladoDetallesCompanion.insert(
              uuid: d['uuid'] as String,
              trasladoUuid: d['traslado_uuid'] as String,
              productoUuid: Value(d['producto_uuid'] as String?),
              descripcion: d['descripcion'] as String,
              cantidad: _milesimas(d['cantidad']),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarTrasladoEventos(dynamic bloque) async {
    final items = _items(bloque);
    for (final e in items) {
      await db.into(db.trasladoEventos).insertOnConflictUpdate(
            TrasladoEventosCompanion.insert(
              uuid: e['uuid'] as String,
              trasladoUuid: e['traslado_uuid'] as String,
              evento: e['evento'] as String,
              usuarioUuid: Value(e['usuario_uuid'] as String?),
              fecha: _fecha(e['fecha']),
              nota: Value(e['nota'] as String?),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarSolicitudesAjuste(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((a) => !bloqueados.contains(a['uuid'])).toList();
    for (final a in items) {
      await db.into(db.solicitudesAjuste).insertOnConflictUpdate(
            SolicitudesAjusteCompanion.insert(
              uuid: a['uuid'] as String,
              sedeUuid: a['sede_uuid'] as String,
              productoUuid: a['producto_uuid'] as String,
              tipo: a['tipo'] as String,
              cantidad: Value(_milesimasOpcional(a['cantidad'])),
              stockContado: Value(_milesimasOpcional(a['stock_contado'])),
              motivo: Value(a['motivo'] as String?),
              estado: Value(a['estado'] as String? ?? 'PENDIENTE'),
              solicitadoPorUuid: Value(a['solicitado_por_uuid'] as String?),
              solicitadoEn: _fecha(a['solicitado_en']),
              resueltoPorUuid: Value(a['resuelto_por_uuid'] as String?),
              resueltoEn: Value(_fechaOpcional(a['resuelto_en'])),
              motivoRechazo: Value(a['motivo_rechazo'] as String?),
              updatedAt: Value(_fecha(a['updated_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarCierres(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((c) => !bloqueados.contains(c['uuid'])).toList();
    for (final c in items) {
      await db.into(db.cierresCaja).insertOnConflictUpdate(
            CierresCajaCompanion.insert(
              uuid: c['uuid'] as String,
              sedeUuid: c['sede_uuid'] as String,
              usuarioUuid: Value(c['usuario_uuid'] as String?),
              dispositivoUuid: Value(c['dispositivo_uuid'] as String?),
              estado: Value(c['estado'] as String? ?? 'ABIERTO'),
              abiertoEn: _fecha(c['abierto_en']),
              baseEfectivo: Value(_centavos(c['base_efectivo'])),
              cerradoEn: Value(_fechaOpcional(c['cerrado_en'])),
              cierreTardio: Value(_bool(c['cierre_tardio'])),
              esperadoTotal: Value(_centavosOpcional(c['esperado_total'])),
              contadoTotal: Value(_centavosOpcional(c['contado_total'])),
              diferenciaEfectivo: Value(_centavosOpcional(c['diferencia_efectivo'])),
              detalle: Value(_textoJson(c['detalle'])),
              notas: Value(c['notas'] as String?),
              revisadoPorUuid: Value(c['revisado_por_uuid'] as String?),
              revisadoEn: Value(_fechaOpcional(c['revisado_en'])),
              updatedAt: Value(_fecha(c['updated_at'])),
            ),
          );
    }
    return items.length;
  }

  Future<int> _aplicarRecaudos(dynamic bloque, Set<String> bloqueados) async {
    final items = _items(bloque).where((r) => !bloqueados.contains(r['uuid'])).toList();
    for (final r in items) {
      await db.into(db.recaudos).insertOnConflictUpdate(
            RecaudosCompanion.insert(
              uuid: r['uuid'] as String,
              metodoPagoUuid: r['metodo_pago_uuid'] as String,
              sedeUuid: Value(r['sede_uuid'] as String?),
              fecha: r['fecha'] as String,
              monto: _centavos(r['monto']),
              comision: Value(_centavos(r['comision'])),
              referencia: Value(r['referencia'] as String?),
              notas: Value(r['notas'] as String?),
              aplicaciones: Value(_textoJson(r['aplicaciones'])),
              registradoPorUuid: Value(r['registrado_por_uuid'] as String?),
              updatedAt: Value(_fecha(r['updated_at'])),
              deletedAt: Value(_fechaOpcional(r['deleted_at'])),
            ),
          );
    }
    return items.length;
  }

  // ── Alcance ───────────────────────────────────────────────────────────────

  /// ¿El servidor bajó los datos con otro alcance del que tenemos?
  ///
  /// Pasa al actualizar la app (no había huella) y cuando al usuario le cambian
  /// las sedes o el rol. Lo que había se bajó con permisos que ya no aplican.
  Future<bool> alcanceCambio(String? alcance) async {
    if (alcance == null) return false;
    final estado = await (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull();
    return estado?.alcance != alcance;
  }

  /// Descarta lo que se bajó con el alcance anterior y reinicia los cursores
  /// para volver a bajar desde cero lo que sí corresponde.
  ///
  /// **Nunca toca lo que aún no ha salido del teléfono**: una venta pendiente es
  /// el único ejemplar de ese dinero. Por eso se borran sólo las filas ya
  /// sincronizadas (o que no tienen una operación en la cola).
  Future<void> reiniciarPorAlcance(String alcance) async {
    await db.transaction(() async {
      final pendientes = await _uuidsConCambiosPendientes();
      final lista = pendientes.isEmpty ? <String>[''] : pendientes.toList();

      await (db.delete(db.ventas)..where((t) => t.sincronizadaEn.isNotNull())).go();
      await db.customUpdate(
        'DELETE FROM venta_detalles WHERE venta_uuid NOT IN (SELECT uuid FROM ventas)',
        updates: {db.ventaDetalles},
        updateKind: UpdateKind.delete,
      );
      await db.customUpdate(
        'DELETE FROM venta_pagos WHERE venta_uuid NOT IN (SELECT uuid FROM ventas)',
        updates: {db.ventaPagos},
        updateKind: UpdateKind.delete,
      );
      await (db.delete(db.movimientos)..where((t) => t.sincronizadoEn.isNotNull())).go();
      await db.delete(db.alertas).go();
      await db.delete(db.stockSedes).go();
      await (db.delete(db.traslados)..where((t) => t.uuid.isNotIn(lista))).go();
      await db.customUpdate(
        'DELETE FROM traslado_detalles WHERE traslado_uuid NOT IN (SELECT uuid FROM traslados)',
        updates: {db.trasladoDetalles},
        updateKind: UpdateKind.delete,
      );
      await db.customUpdate(
        'DELETE FROM traslado_eventos WHERE traslado_uuid NOT IN (SELECT uuid FROM traslados)',
        updates: {db.trasladoEventos},
        updateKind: UpdateKind.delete,
      );
      await (db.delete(db.solicitudesAjuste)..where((t) => t.uuid.isNotIn(lista))).go();
      await (db.delete(db.cierresCaja)
            ..where((t) => t.uuid.isNotIn(lista) & t.estado.equals('CERRADO')))
          .go();
      await (db.delete(db.recaudos)..where((t) => t.uuid.isNotIn(lista))).go();
      await reiniciarCursores();
      await (db.update(db.estadoApp)..where((t) => t.id.equals(1)))
          .write(EstadoAppCompanion(alcance: Value(alcance)));
    });
  }

  /// Rehace la proyección del stock en `productos` para la sede activa, desde
  /// `stock_sedes`. Se usa al cambiar de sede activa.
  Future<void> proyectarSedeActiva(String sedeUuid) async {
    await db.transaction(() async {
      await db.customUpdate(
        'UPDATE productos SET '
        'stock_actual = COALESCE((SELECT ss.stock_actual FROM stock_sedes ss '
        '  WHERE ss.producto_uuid = productos.uuid AND ss.sede_uuid = ?), 0), '
        'stock_minimo = COALESCE((SELECT ss.stock_minimo FROM stock_sedes ss '
        '  WHERE ss.producto_uuid = productos.uuid AND ss.sede_uuid = ?), stock_minimo_general)',
        variables: [Variable<String>(sedeUuid), Variable<String>(sedeUuid)],
        updates: {db.productos},
      );
    });
  }

  /// Hora del servidor de la última respuesta: base del control de reloj.
  Future<void> registrarHoraServidor(String? iso) async {
    final servidor = iso == null ? null : DateTime.tryParse(iso)?.toUtc();
    if (servidor == null) return;
    final desfase = servidor.difference(DateTime.now().toUtc()).inMilliseconds;
    await (db.update(db.estadoApp)..where((t) => t.id.equals(1))).write(
      EstadoAppCompanion(horaServidor: Value(servidor), desfaseServidorMs: Value(desfase)),
    );
  }

  Future<int> _aplicarConfiguracion(dynamic bloque) async {
    final items = _items(bloque);
    for (final c in items) {
      await db.into(db.configuracion).insertOnConflictUpdate(
            ConfiguracionCompanion.insert(
              clave: c['clave'] as String,
              valor: c['valor'] as String,
              tipo: Value(c['tipo'] as String? ?? 'STRING'),
            ),
          );
    }
    return items.length;
  }

  // ── Configuración ─────────────────────────────────────────────────────────

  /// Guarda una clave de configuración **en local**.
  ///
  /// La configuración del negocio no viaja por la cola de salida: la escribe el
  /// administrador contra la API y baja a todos los dispositivos en el pull.
  /// Esto sólo adelanta el efecto en ESTE teléfono para que la interfaz
  /// responda al instante en vez de esperar la siguiente sincronización.
  Future<void> guardarConfigLocal(String clave, String valor) =>
      db.into(db.configuracion).insertOnConflictUpdate(
            ConfiguracionCompanion.insert(clave: clave, valor: valor),
          );

  Future<String?> config(String clave) async {
    final fila = await (db.select(db.configuracion)..where((t) => t.clave.equals(clave)))
        .getSingleOrNull();
    return fila?.valor;
  }

  Stream<Map<String, String>> observarConfiguracion() => db
      .select(db.configuracion)
      .watch()
      .map((filas) => {for (final f in filas) f.clave: f.valor});
}
