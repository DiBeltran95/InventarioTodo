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

class SedesDao {
  SedesDao(this.db, this.sync);

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
