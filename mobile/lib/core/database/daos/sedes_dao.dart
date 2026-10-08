import 'package:drift/drift.dart';

import '../../money/money.dart';
import '../app_database.dart';
import 'sync_dao.dart';

/// Un producto en o bajo su mínimo en una sede.
class StockBajo {
  const StockBajo({
    required this.producto,
    required this.sede,
    required this.stock,
    required this.minimo,
  });

  final Producto producto;
  final Sede sede;
  final Cantidad stock;
  final Cantidad minimo;

  bool get agotado => stock.milesimas <= 0;

  /// Lo que falta para volver al mínimo.
  Cantidad get faltante => minimo - stock;
}

/// Stock de un producto en una sede, para la ficha del producto.
class StockEnSede {
  const StockEnSede({required this.sede, required this.stock, this.minimo});

  final Sede sede;
  final Cantidad stock;
  final Cantidad? minimo;
}

/// Ventas de una sede hoy y ayer, para las tarjetas del director.
class VentasSede {
  const VentasSede({required this.sede, required this.hoy, required this.numHoy, required this.ayer});

  final Sede sede;
  final Money hoy;
  final int numHoy;
  final Money ayer;

  /// Variación porcentual frente a ayer; null si ayer no hubo ventas.
  double? get variacion => ayer.esCero ? null : (hoy.centavos - ayer.centavos) / ayer.centavos * 100;
}

/// Un cambio de stock que no es una venta: entrada, ajuste, merma, traslado…
/// Es lo que el Director General revisa de gerentes y auxiliares.
class CambioInventario {
  const CambioInventario({required this.movimiento, required this.producto, this.sede, this.usuario});

  final Movimiento movimiento;
  final Producto producto;
  final Sede? sede;
  final Usuario? usuario;
}

class SedesDao {
  SedesDao(this.db, this.sync);

  /// Ventas completadas de hoy y ayer por sede. Las sedes sin ventas aparecen
  /// igual, en cero: que una sede no venda nada también es noticia.
  Stream<List<VentasSede>> observarVentasPorSede({required String hoy, required String ayer}) {
    return db
        .customSelect(
          '''
          SELECT s.uuid AS sede_uuid,
                 COALESCE(SUM(CASE WHEN v.fecha_local = ? THEN v.total END), 0) AS hoy,
                 COUNT(CASE WHEN v.fecha_local = ? THEN 1 END)                  AS num_hoy,
                 COALESCE(SUM(CASE WHEN v.fecha_local = ? THEN v.total END), 0) AS ayer
            FROM sedes s
            LEFT JOIN ventas v
              ON v.sede_uuid = s.uuid AND v.estado = 'COMPLETADA' AND v.deleted_at IS NULL
                 AND v.fecha_local >= ?
           WHERE s.deleted_at IS NULL AND s.activo = 1
           GROUP BY s.uuid
          ''',
          variables: [Variable(hoy), Variable(hoy), Variable(ayer), Variable(ayer)],
          readsFrom: {db.sedes, db.ventas},
        )
        .watch()
        .asyncMap((filas) async {
      final sedes = {for (final s in await db.select(db.sedes).get()) s.uuid: s};
      final lista = [
        for (final f in filas)
          if (sedes[f.read<String>('sede_uuid')] != null)
            VentasSede(
              sede: sedes[f.read<String>('sede_uuid')]!,
              hoy: Money(f.read<int>('hoy')),
              numHoy: f.read<int>('num_hoy'),
              ayer: Money(f.read<int>('ayer')),
            ),
      ]..sort((a, b) => b.hoy.centavos.compareTo(a.hoy.centavos));
      return lista;
    });
  }

  /// Ventas completadas desde [desde] por sede, con su margen. Para la sección
  /// «Ventas por sede» de Reportes.
  Stream<List<({Sede sede, Money total, int numero, Money margen})>> observarTotalesPorSede({
    required String desde,
  }) {
    return db
        .customSelect(
          '''
          SELECT sede_uuid, COALESCE(SUM(total), 0) AS total, COUNT(*) AS numero,
                 COALESCE(SUM(total - costo_total), 0) AS margen
            FROM ventas
           WHERE estado = 'COMPLETADA' AND deleted_at IS NULL AND fecha_local >= ? AND sede_uuid IS NOT NULL
           GROUP BY sede_uuid
           ORDER BY total DESC
          ''',
          variables: [Variable(desde)],
          readsFrom: {db.ventas},
        )
        .watch()
        .asyncMap((filas) async {
      final sedes = {for (final s in await db.select(db.sedes).get()) s.uuid: s};
      return [
        for (final f in filas)
          if (sedes[f.read<String>('sede_uuid')] != null)
            (
              sede: sedes[f.read<String>('sede_uuid')]!,
              total: Money(f.read<int>('total')),
              numero: f.read<int>('numero'),
              margen: Money(f.read<int>('margen')),
            ),
      ];
    });
  }

  /// Cambios de stock desde [desde] (día del negocio) que no son ventas ni
  /// anulaciones, del más reciente al más antiguo.
  Stream<List<CambioInventario>> observarCambiosInventario({required String desde, int limite = 30}) {
    final consulta = db.select(db.movimientos).join([
      innerJoin(db.productos, db.productos.uuid.equalsExp(db.movimientos.productoUuid)),
      leftOuterJoin(db.sedes, db.sedes.uuid.equalsExp(db.movimientos.sedeUuid)),
      leftOuterJoin(db.usuarios, db.usuarios.uuid.equalsExp(db.movimientos.usuarioUuid)),
    ])
      ..where(db.movimientos.fechaLocal.isBiggerOrEqualValue(desde) &
          db.movimientos.tipo.isNotIn(const ['VENTA', 'ANULACION_VENTA']))
      ..orderBy([OrderingTerm.desc(db.movimientos.fecha)])
      ..limit(limite);
    return consulta.watch().map((filas) => [
          for (final f in filas)
            CambioInventario(
              movimiento: f.readTable(db.movimientos),
              producto: f.readTable(db.productos),
              sede: f.readTableOrNull(db.sedes),
              usuario: f.readTableOrNull(db.usuarios),
            ),
        ]);
  }

  final AppDatabase db;
  final SyncDao sync;

  /// Sedes activas, la principal primero.
  Stream<List<Sede>> observarActivas() => (db.select(db.sedes)
        ..where((t) => t.deletedAt.isNull() & t.activo.equals(true))
        ..orderBy([
          (t) => OrderingTerm.desc(t.esPrincipal),
          (t) => OrderingTerm.asc(t.nombre),
        ]))
      .watch();

  /// Todas, también las inactivas: para mostrar el nombre de la sede de un
  /// traslado o una venta antiguos.
  Stream<Map<String, Sede>> observarIndice() =>
      db.select(db.sedes).watch().map((filas) => {for (final s in filas) s.uuid: s});

  Future<Sede?> porUuid(String uuid) =>
      (db.select(db.sedes)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  Stream<Sede?> observarSedeActiva() {
    final estado = db.select(db.estadoApp)..where((t) => t.id.equals(1));
    return estado.watchSingleOrNull().asyncMap((e) async {
      final uuid = e?.sedeActivaUuid;
      return uuid == null ? null : porUuid(uuid);
    });
  }

  /// Sedes del alcance del usuario con sesión.
  ///
  /// El director ve todas; el resto, las de su fila de usuario (que bajan con
  /// él en la sincronización). Así funciona igual sin red.
  Stream<List<Sede>> observarDeUsuario(String usuarioUuid) {
    final consulta = db.select(db.usuarios)..where((t) => t.uuid.equals(usuarioUuid));
    return consulta.watchSingleOrNull().asyncExpand((u) {
      if (u == null) return Stream.value(const <Sede>[]);
      if (u.rol == 'ADMIN') return observarActivas();
      final uuids = u.sedes.split(',').where((x) => x.isNotEmpty).toList();
      return observarActivas().map((s) => s.where((x) => uuids.contains(x.uuid)).toList());
    });
  }

  /// Cambia la sede en la que opera este teléfono y rehace la proyección del
  /// stock: el catálogo, el escáner y la venta pasan a mostrar el de esa sede.
  Future<void> cambiarSedeActiva(String sedeUuid) async {
    await (db.update(db.estadoApp)..where((t) => t.id.equals(1)))
        .write(EstadoAppCompanion(sedeActivaUuid: Value(sedeUuid)));
    await sync.proyectarSedeActiva(sedeUuid);
  }

  /// Stock de un producto en cada sede visible.
  Stream<List<StockEnSede>> observarStockPorSede(String productoUuid) {
    final consulta = db.select(db.stockSedes).join([
      innerJoin(db.sedes, db.sedes.uuid.equalsExp(db.stockSedes.sedeUuid)),
    ])
      ..where(db.stockSedes.productoUuid.equals(productoUuid) & db.sedes.deletedAt.isNull())
      ..orderBy([OrderingTerm.desc(db.sedes.esPrincipal), OrderingTerm.asc(db.sedes.nombre)]);
    return consulta.watch().map(
          (filas) => filas.map((f) {
            final ss = f.readTable(db.stockSedes);
            return StockEnSede(
              sede: f.readTable(db.sedes),
              stock: Cantidad(ss.stockActual),
              minimo: ss.stockMinimo == null ? null : Cantidad(ss.stockMinimo!),
            );
          }).toList(),
        );
  }

  /// Productos en o bajo su mínimo, por sede.
  ///
  /// Se calcula sobre `stock_sedes` local (no sobre las alertas del servidor)
  /// para que el aviso aparezca al instante, también sin red, en cuanto una
  /// venta deja el producto en su mínimo. El mínimo es el de la sede o, si no
  /// tiene, el general; un mínimo de 0 significa «sin mínimo» y no avisa.
  Stream<List<StockBajo>> observarStockBajo({List<String>? sedes}) {
    final minimo = coalesce([db.stockSedes.stockMinimo, db.productos.stockMinimoGeneral]);
    final consulta = db.select(db.stockSedes).join([
      innerJoin(db.productos, db.productos.uuid.equalsExp(db.stockSedes.productoUuid)),
      innerJoin(db.sedes, db.sedes.uuid.equalsExp(db.stockSedes.sedeUuid)),
    ])
      ..addColumns([minimo])
      ..where(db.productos.deletedAt.isNull() &
          db.productos.activo.equals(true) &
          db.sedes.deletedAt.isNull() &
          db.sedes.activo.equals(true) &
          minimo.isBiggerThanValue(0) &
          db.stockSedes.stockActual.isSmallerOrEqual(minimo));
    if (sedes != null) consulta.where(db.stockSedes.sedeUuid.isIn(sedes));
    consulta.orderBy([
      OrderingTerm.asc(db.sedes.nombre),
      OrderingTerm.asc(db.stockSedes.stockActual),
    ]);

    return consulta.watch().map(
          (filas) => filas
              .map((f) => StockBajo(
                    producto: f.readTable(db.productos),
                    sede: f.readTable(db.sedes),
                    stock: Cantidad(f.readTable(db.stockSedes).stockActual),
                    minimo: Cantidad(f.read(minimo) ?? 0),
                  ))
              .toList(),
        );
  }
}
