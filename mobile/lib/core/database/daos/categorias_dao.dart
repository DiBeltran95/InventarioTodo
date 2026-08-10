import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../app_database.dart';
import 'outbox_dao.dart';

/// Categoría con cuántos productos la usan.
class CategoriaConUso {
  const CategoriaConUso({required this.categoria, required this.productos});

  final Categoria categoria;

  /// Productos activos que la tienen asignada. Es lo que decide si borrarla es
  /// inocuo o deja huérfanos a veinte artículos.
  final int productos;

  String get uuid => categoria.uuid;
  String get nombre => categoria.nombre;
}

/// Categorías del catálogo.
///
/// Escribe dominio y cola de salida en la MISMA transacción, como el resto del
/// catálogo: crear una categoría **funciona sin conexión** y se envía sola al
/// volver la red.
class CategoriasDao {
  CategoriasDao(this.db, this.outbox);

  final AppDatabase db;
  final OutboxDao outbox;
  static const _uuid = Uuid();

  /// Paleta por defecto.
  ///
  /// Son colores con suficiente contraste entre sí para distinguirse de un
  /// vistazo en la lista de productos, que es donde se usan. Dejar elegir un
  /// hexadecimal libre acaba en dos categorías con el mismo tono y en avatares
  /// ilegibles sobre fondo claro.
  static const paleta = <String>[
    '#0E6B5C', // verde del tema
    '#1D4ED8', // azul
    '#9A5B00', // ámbar
    '#B3261E', // rojo
    '#6750A4', // morado
    '#00696D', // turquesa
    '#7D5260', // vino
    '#3F6212', // oliva
    '#8B5CF6', // lavanda
    '#0F766E', // esmeralda
    '#C2410C', // naranja
    '#4B5563', // gris
  ];

  // ── Lecturas ──────────────────────────────────────────────────────────────

  Stream<List<CategoriaConUso>> observar() {
    final consulta = db.select(db.categorias)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.asc(t.orden),
        (t) => OrderingTerm.asc(t.nombre),
      ]);

    // Una sola consulta agregada, no una por fila: con 30 categorías, lo
    // segundo son 30 viajes a SQLite en cada repintado.
    return consulta.watch().asyncMap((categorias) async {
      final filas = await db.customSelect(
        'SELECT categoria_uuid, COUNT(*) AS n FROM productos '
        'WHERE categoria_uuid IS NOT NULL AND deleted_at IS NULL AND activo = 1 '
        'GROUP BY categoria_uuid',
        readsFrom: {db.productos},
      ).get();

      final usos = {
        for (final f in filas) f.read<String>('categoria_uuid'): f.read<int>('n'),
      };

      return [
        for (final c in categorias)
          CategoriaConUso(categoria: c, productos: usos[c.uuid] ?? 0),
      ];
    });
  }

  Future<Categoria?> obtener(String uuid) =>
      (db.select(db.categorias)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  /// ¿Ya hay una con ese nombre? Dos «Bebidas» reparten el catálogo en dos
  /// filtros que se ven idénticos, y nadie entiende por qué falta la mitad.
  Future<Categoria?> porNombre(String nombre, {String? exceptoUuid}) async {
    final objetivo = nombre.trim().toLowerCase();
    final todas =
        await (db.select(db.categorias)..where((t) => t.deletedAt.isNull())).get();
    for (final c in todas) {
      if (c.nombre.trim().toLowerCase() == objetivo && c.uuid != exceptoUuid) return c;
    }
    return null;
  }

  /// Color siguiente de la paleta que aún no esté en uso, para que dos
  /// categorías creadas seguidas no salgan del mismo tono.
  Future<String> colorSugerido() async {
    final usados = (await (db.select(db.categorias)
              ..where((t) => t.deletedAt.isNull()))
            .get())
        .map((c) => c.color.toUpperCase())
        .toSet();

    for (final color in paleta) {
      if (!usados.contains(color.toUpperCase())) return color;
    }
    return paleta.first;
  }

  // ── Mutaciones ────────────────────────────────────────────────────────────

  Future<String> crear({
    required String nombre,
    required String color,
    String? descripcion,
    int? orden,
  }) async {
    final uuid = _uuid.v7();
    final ahora = DateTime.now().toUtc();

    // Se coloca al final salvo que se indique otro orden: una categoría nueva
    // no debería reordenar la lista que el usuario ya tiene aprendida.
    final posicion = orden ?? await _siguienteOrden();

    await db.transaction(() async {
      await db.into(db.categorias).insert(
            CategoriasCompanion.insert(
              uuid: uuid,
              nombre: nombre.trim(),
              descripcion: Value(_limpio(descripcion)),
              color: Value(color),
              orden: Value(posicion),
              updatedAt: Value(ahora),
            ),
          );

      await outbox.encolar(
        'CATEGORIA_CREAR',
        entidad: 'categorias',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'nombre': nombre.trim(),
          'descripcion': _limpio(descripcion),
          'color': color,
          'orden': posicion,
        },
      );
    });

    return uuid;
  }

  Future<void> actualizar(
    String uuid, {
    String? nombre,
    String? color,
    String? descripcion,
    int? orden,
  }) async {
    final ahora = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.categorias)..where((t) => t.uuid.equals(uuid))).write(
        CategoriasCompanion(
          nombre: nombre == null ? const Value.absent() : Value(nombre.trim()),
          color: color == null ? const Value.absent() : Value(color),
          descripcion:
              descripcion == null ? const Value.absent() : Value(_limpio(descripcion)),
          orden: orden == null ? const Value.absent() : Value(orden),
          updatedAt: Value(ahora),
        ),
      );

      // Sólo viajan los campos tocados: el servidor rechaza un PATCH vacío y
      // mandar nulos borraría datos que nadie pidió borrar.
      final payload = <String, dynamic>{'uuid': uuid};
      if (nombre != null) payload['nombre'] = nombre.trim();
      if (color != null) payload['color'] = color;
      if (descripcion != null) payload['descripcion'] = _limpio(descripcion);
      if (orden != null) payload['orden'] = orden;

      await outbox.encolar(
        'CATEGORIA_ACTUALIZAR',
        entidad: 'categorias',
        entidadUuid: uuid,
        payload: payload,
      );
    });
  }

  /// Baja lógica. Los productos que la usaban quedan **sin categoría**, no
  /// borrados: se desasignan en local para que la lista no muestre un filtro
  /// fantasma mientras la operación viaja al servidor.
  Future<void> eliminar(String uuid) async {
    final ahora = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.categorias)..where((t) => t.uuid.equals(uuid)))
          .write(CategoriasCompanion(deletedAt: Value(ahora), updatedAt: Value(ahora)));

      await (db.update(db.productos)..where((t) => t.categoriaUuid.equals(uuid)))
          .write(const ProductosCompanion(categoriaUuid: Value(null)));

      await outbox.encolar(
        'CATEGORIA_ELIMINAR',
        entidad: 'categorias',
        entidadUuid: uuid,
        payload: {'uuid': uuid},
      );
    });
  }

  Future<int> _siguienteOrden() async {
    final fila = await db.customSelect(
      'SELECT COALESCE(MAX(orden), -1) + 1 AS siguiente FROM categorias '
      'WHERE deleted_at IS NULL',
      readsFrom: {db.categorias},
    ).getSingle();
    return fila.read<int>('siguiente');
  }

  static String? _limpio(String? valor) {
    final t = valor?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
