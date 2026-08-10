import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../app_database.dart';
import 'outbox_dao.dart';

/// Proveedor con lo que se necesita para pintarlo sin consultar nada más.
class ProveedorConUso {
  const ProveedorConUso({required this.proveedor, required this.entradas});

  final Proveedor proveedor;

  /// Cuántas entradas de mercancía se le han registrado. Es el dato que
  /// distingue un proveedor real de uno creado por error, y el que justifica
  /// avisar antes de darlo de baja.
  final int entradas;

  String get uuid => proveedor.uuid;
  String get nombre => proveedor.nombre;

  String get iniciales {
    final partes = nombre.trim().split(RegExp(r'\s+'));
    if (partes.isEmpty || partes.first.isEmpty) return '?';
    if (partes.length == 1) {
      return partes.first.substring(0, partes.first.length.clamp(0, 2)).toUpperCase();
    }
    return (partes[0][0] + partes[1][0]).toUpperCase();
  }

  /// Línea secundaria de la ficha: lo primero que hay, sin repetir etiquetas.
  String? get subtitulo {
    final p = proveedor;
    for (final valor in [p.contacto, p.telefono, p.nit, p.email]) {
      if (valor != null && valor.trim().isNotEmpty) return valor.trim();
    }
    return null;
  }
}

/// Proveedores.
///
/// Escribe dominio y cola de salida en la MISMA transacción, igual que el resto
/// del catálogo: si la app muere en medio, o se guardan las dos cosas o
/// ninguna. El servidor aplica `PROVEEDOR_CREAR/ACTUALIZAR/ELIMINAR` desde la
/// cola, así que dar de alta un proveedor **funciona sin conexión**.
class ProveedoresDao {
  ProveedoresDao(this.db, this.outbox);

  final AppDatabase db;
  final OutboxDao outbox;
  static const _uuid = Uuid();

  // ── Lecturas ──────────────────────────────────────────────────────────────

  Stream<List<ProveedorConUso>> observar({String? busqueda}) {
    final consulta = db.select(db.proveedores)..where((t) => t.deletedAt.isNull());

    if (busqueda != null && busqueda.trim().isNotEmpty) {
      final t = busqueda.trim().toLowerCase();
      consulta.where(
        (p) =>
            p.nombre.lower().like('%$t%') |
            p.nit.lower().like('%$t%') |
            p.contacto.lower().like('%$t%') |
            p.telefono.like('%$t%'),
      );
    }

    consulta.orderBy([(t) => OrderingTerm.asc(t.nombre)]);

    // El recuento de entradas se resuelve con UNA consulta agregada y no con
    // una por fila: con 40 proveedores, lo segundo son 40 viajes a SQLite en
    // cada repintado de la lista.
    return consulta.watch().asyncMap((proveedores) async {
      final filas = await db.customSelect(
        'SELECT proveedor_uuid, COUNT(*) AS n FROM movimientos '
        'WHERE proveedor_uuid IS NOT NULL GROUP BY proveedor_uuid',
        readsFrom: {db.movimientos},
      ).get();

      final usos = {
        for (final f in filas) f.read<String>('proveedor_uuid'): f.read<int>('n'),
      };

      return [
        for (final p in proveedores)
          ProveedorConUso(proveedor: p, entradas: usos[p.uuid] ?? 0),
      ];
    });
  }

  Future<Proveedor?> obtener(String uuid) =>
      (db.select(db.proveedores)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();

  /// ¿Ya hay un proveedor con ese nombre? Se comprueba antes de guardar para
  /// evitar el duplicado silencioso —«Distribuidora ABC» dos veces— que sólo se
  /// descubre semanas después, con las compras repartidas entre ambos.
  Future<Proveedor?> porNombre(String nombre, {String? exceptoUuid}) async {
    final objetivo = nombre.trim().toLowerCase();
    final todos = await (db.select(db.proveedores)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    for (final p in todos) {
      if (p.nombre.trim().toLowerCase() == objetivo && p.uuid != exceptoUuid) return p;
    }
    return null;
  }

  // ── Mutaciones ────────────────────────────────────────────────────────────

  Future<String> crear({
    required String nombre,
    String? nit,
    String? contacto,
    String? telefono,
    String? email,
    String? direccion,
    String? notas,
  }) async {
    final uuid = _uuid.v7();
    final ahora = DateTime.now().toUtc();

    await db.transaction(() async {
      await db.into(db.proveedores).insert(
            ProveedoresCompanion.insert(
              uuid: uuid,
              nombre: nombre.trim(),
              nit: Value(_limpio(nit)),
              contacto: Value(_limpio(contacto)),
              telefono: Value(_limpio(telefono)),
              email: Value(_limpio(email)),
              direccion: Value(_limpio(direccion)),
              notas: Value(_limpio(notas)),
              updatedAt: Value(ahora),
            ),
          );

      await outbox.encolar(
        'PROVEEDOR_CREAR',
        entidad: 'proveedores',
        entidadUuid: uuid,
        payload: {
          'uuid': uuid,
          'nombre': nombre.trim(),
          'nit': _limpio(nit),
          'contacto': _limpio(contacto),
          'telefono': _limpio(telefono),
          'email': _limpio(email),
          'direccion': _limpio(direccion),
          'notas': _limpio(notas),
        },
      );
    });

    return uuid;
  }

  Future<void> actualizar(
    String uuid, {
    String? nombre,
    String? nit,
    String? contacto,
    String? telefono,
    String? email,
    String? direccion,
    String? notas,
  }) async {
    final ahora = DateTime.now().toUtc();

    await db.transaction(() async {
      await (db.update(db.proveedores)..where((t) => t.uuid.equals(uuid))).write(
        ProveedoresCompanion(
          nombre: nombre == null ? const Value.absent() : Value(nombre.trim()),
          nit: nit == null ? const Value.absent() : Value(_limpio(nit)),
          contacto: contacto == null ? const Value.absent() : Value(_limpio(contacto)),
          telefono: telefono == null ? const Value.absent() : Value(_limpio(telefono)),
          email: email == null ? const Value.absent() : Value(_limpio(email)),
          direccion: direccion == null ? const Value.absent() : Value(_limpio(direccion)),
          notas: notas == null ? const Value.absent() : Value(_limpio(notas)),
          updatedAt: Value(ahora),
        ),
      );

      // Sólo viajan los campos tocados: el servidor rechaza un PATCH vacío y
      // enviar nulos borraría datos que nadie pidió borrar.
      final payload = <String, dynamic>{'uuid': uuid};
      if (nombre != null) payload['nombre'] = nombre.trim();
      if (nit != null) payload['nit'] = _limpio(nit);
      if (contacto != null) payload['contacto'] = _limpio(contacto);
      if (telefono != null) payload['telefono'] = _limpio(telefono);
      if (email != null) payload['email'] = _limpio(email);
      if (direccion != null) payload['direccion'] = _limpio(direccion);
      if (notas != null) payload['notas'] = _limpio(notas);

      await outbox.encolar(
        'PROVEEDOR_ACTUALIZAR',
        entidad: 'proveedores',
        entidadUuid: uuid,
        payload: payload,
      );
    });
  }

  /// Baja lógica. Un borrado físico no llegaría nunca al otro dispositivo y
  /// dejaría huérfanos los movimientos que ya lo referencian.
  Future<void> eliminar(String uuid) async {
    final ahora = DateTime.now().toUtc();
    await db.transaction(() async {
      await (db.update(db.proveedores)..where((t) => t.uuid.equals(uuid)))
          .write(ProveedoresCompanion(deletedAt: Value(ahora), updatedAt: Value(ahora)));
      await outbox.encolar(
        'PROVEEDOR_ELIMINAR',
        entidad: 'proveedores',
        entidadUuid: uuid,
        payload: {'uuid': uuid},
      );
    });
  }

  /// Un campo vacío es «no hay dato», no una cadena vacía: así el servidor
  /// guarda NULL y la ficha no muestra líneas en blanco.
  static String? _limpio(String? valor) {
    final t = valor?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
