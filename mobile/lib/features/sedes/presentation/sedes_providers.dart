import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/ajustes_dao.dart';
import '../../../core/database/daos/sedes_dao.dart';
import '../../../core/database/daos/traslados_dao.dart';
import '../../../core/negocio/traslados.dart';
import '../../../core/providers/providers.dart';
import '../../auth/presentation/auth_providers.dart';

/// Sedes del usuario con sesión: las suyas, o todas si es el director.
/// Sale de SQLite, así que funciona sin red.
final misSedesProvider = StreamProvider<List<Sede>>((ref) {
  final sesion = ref.watch(sesionProvider).value;
  if (sesion == null) return Stream.value(const []);
  return ref.watch(sedesDaoProvider).observarDeUsuario(sesion.usuarioUuid);
});

/// Quién está usando la app, con lo que hace falta para decidir qué puede
/// hacer en un traslado.
final actorProvider = Provider<Actor?>((ref) {
  final sesion = ref.watch(sesionProvider).value;
  if (sesion == null) return null;
  final sedes = ref.watch(misSedesProvider).value ?? const <Sede>[];
  return Actor(
    uuid: sesion.usuarioUuid,
    rol: sesion.rol,
    sedes: sesion.rol.esDirector ? null : sedes.map((s) => s.uuid).toSet(),
  );
});

/// Productos en o bajo su mínimo en las sedes visibles.
final stockBajoProvider = StreamProvider<List<StockBajo>>(
  (ref) => ref.watch(sedesDaoProvider).observarStockBajo(),
);

final trasladosProvider = StreamProvider<List<TrasladoResumen>>(
  (ref) => ref.watch(trasladosDaoProvider).observar(),
);

/// Traslados pendientes que ESTE usuario puede aprobar o confirmar.
final trasladosPorResolverProvider = Provider<List<TrasladoResumen>>((ref) {
  final actor = ref.watch(actorProvider);
  final lista = ref.watch(trasladosProvider).value ?? const [];
  if (actor == null) return const [];
  return lista
      .where((r) =>
          r.pendiente &&
          motivoNoPuedeResolver(
                estado: r.traslado.estado,
                confirma: r.traslado.confirma,
                sedeOrigen: r.traslado.sedeOrigenUuid,
                solicitadoPor: r.traslado.solicitadoPorUuid,
                actor: actor,
              ) ==
              null)
      .toList();
});

final solicitudesAjusteProvider = StreamProvider<List<SolicitudConDatos>>((ref) {
  final sesion = ref.watch(sesionProvider).value;
  final dao = ref.watch(ajustesDaoProvider);
  // El auxiliar ve las suyas; el gestor, todas las de sus sedes (las que hay
  // en el teléfono ya son sólo esas).
  if (sesion != null && sesion.rol.solicitaAjustes) {
    return dao.observar(solicitadoPor: sesion.usuarioUuid);
  }
  return dao.observar();
});

/// Solicitudes de ajuste que esperan la aprobación de este gestor.
final ajustesPorAprobarProvider = Provider<List<SolicitudConDatos>>((ref) {
  final sesion = ref.watch(sesionProvider).value;
  if (sesion == null || !sesion.rol.esGestor) return const [];
  return (ref.watch(solicitudesAjusteProvider).value ?? const [])
      .where((s) => s.pendiente && s.solicitud.solicitadoPorUuid != sesion.usuarioUuid)
      .toList();
});

/// Caja abierta de quien tiene la sesión.
final cajaAbiertaProvider = StreamProvider<CierreCaja?>((ref) {
  final sesion = ref.watch(sesionProvider).value;
  if (sesion == null) return Stream.value(null);
  return ref.watch(cierresDaoProvider).observarAbierta(sesion.usuarioUuid);
});

/// Índice de usuarios por uuid, para mostrar nombres en traslados, ajustes y
/// cierres.
final indiceUsuariosProvider = StreamProvider<Map<String, Usuario>>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return db.select(db.usuarios).watch().map((filas) => {for (final u in filas) u.uuid: u});
});
