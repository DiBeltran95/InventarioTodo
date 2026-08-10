import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/proveedores_dao.dart';
import '../../../core/providers/providers.dart';

/// Texto del buscador. Vive en un provider y no en el `State` de la página para
/// que abrir una ficha y volver no borre lo que costó teclear.
class BusquedaProveedoresNotifier extends Notifier<String> {
  @override
  String build() => '';

  void buscar(String texto) => state = texto;
  void limpiar() => state = '';
}

final busquedaProveedoresProvider =
    NotifierProvider<BusquedaProveedoresNotifier, String>(
  BusquedaProveedoresNotifier.new,
);

/// Lista de proveedores. Es un stream de Drift: al crear uno o al sincronizar,
/// la lista se repinta sola. Y funciona sin conexión, como todo el catálogo.
final proveedoresListaProvider = StreamProvider<List<ProveedorConUso>>((ref) {
  final busqueda = ref.watch(busquedaProveedoresProvider);
  return ref.watch(proveedoresDaoProvider).observar(busqueda: busqueda);
});

final proveedorProvider = FutureProvider.family<Proveedor?, String>(
  (ref, uuid) => ref.watch(proveedoresDaoProvider).obtener(uuid),
);
