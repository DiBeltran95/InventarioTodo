import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/categorias_dao.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/widgets/estados.dart';
import 'widgets/formulario_categoria.dart';

final categoriasListaProvider = StreamProvider<List<CategoriaConUso>>(
  (ref) => ref.watch(categoriasDaoProvider).observar(),
);

/// Categorías del catálogo.
///
/// Sirven para filtrar la lista de productos y para dar color a sus tarjetas.
/// Se editan aquí, pero **también se pueden crear sin salir del alta de un
/// producto**: ése es el momento en que uno descubre que le falta una, y
/// obligar a abandonar el formulario a medias para venir aquí es lo que hacía
/// que la gente acabara metiendo todo en «Sin categoría».
class CategoriasPage extends ConsumerWidget {
  const CategoriasPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categorias = ref.watch(categoriasListaProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Categorías')),
      body: categorias.when(
        loading: () => const SkeletonLista(),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (lista) {
          if (lista.isEmpty) {
            return EstadoVacio(
              icono: Icons.category_outlined,
              titulo: 'Aún no hay categorías',
              descripcion:
                  'Agrupan los productos para encontrarlos rápido y les dan '
                  'color en el catálogo.',
              textoAccion: 'Crear categoría',
              onAccion: () => abrirFormularioCategoria(context),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: lista.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) => EntradaEscalonada(
              indice: i,
              child: _FilaCategoria(
                item: lista[i],
                onEditar: () =>
                    abrirFormularioCategoria(context, categoria: lista[i].categoria),
                onEliminar: () => _confirmarEliminar(context, ref, lista[i]),
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => abrirFormularioCategoria(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Añadir'),
      ),
    );
  }

  Future<void> _confirmarEliminar(
    BuildContext context,
    WidgetRef ref,
    CategoriaConUso item,
  ) async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('¿Eliminar la categoría?'),
        content: Text(
          item.productos == 0
              ? 'No la usa ningún producto.'
              // Se dice el número y qué les pasa: nadie borra a ciegas algo
              // que toca veinte artículos.
              : '${item.productos} producto${item.productos == 1 ? '' : 's'} '
                  'la usa${item.productos == 1 ? '' : 'n'}. No se '
                  'eliminará${item.productos == 1 ? '' : 'n'}: '
                  'quedará${item.productos == 1 ? '' : 'n'} sin categoría y '
                  'podrás reasignarlo${item.productos == 1 ? '' : 's'} después.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogo, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.dominio.peligro),
            onPressed: () => Navigator.pop(dialogo, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmado != true) return;

    await ref.read(categoriasDaoProvider).eliminar(item.uuid);
    ref.read(syncEngineProvider).solicitar();
    if (context.mounted) mostrarMensaje(context, 'Categoría eliminada');
  }
}

/// Abre el formulario y devuelve el UUID de la categoría guardada.
///
/// Se expone como función suelta para poder llamarla también desde el alta de
/// producto, que necesita el UUID para dejarla seleccionada.
Future<String?> abrirFormularioCategoria(
  BuildContext context, {
  Categoria? categoria,
  String? nombreInicial,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FormularioCategoria(
      categoria: categoria,
      nombreInicial: nombreInicial,
    ),
  );
}

class _FilaCategoria extends StatelessWidget {
  const _FilaCategoria({
    required this.item,
    required this.onEditar,
    required this.onEliminar,
  });

  final CategoriaConUso item;
  final VoidCallback onEditar;
  final VoidCallback onEliminar;

  @override
  Widget build(BuildContext context) {
    final color = colorDesdeHex(item.categoria.color) ?? context.colores.primary;

    return Card(
      child: ListTile(
        onTap: onEditar,
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        title: Text(item.nombre, style: context.textos.titleSmall),
        subtitle: Text(
          item.productos == 0
              ? 'Sin productos'
              : '${item.productos} producto${item.productos == 1 ? '' : 's'}',
          style: context.textos.bodySmall,
        ),
        trailing: IconButton(
          onPressed: onEliminar,
          icon: const Icon(Icons.delete_outline_rounded),
          tooltip: 'Eliminar',
        ),
      ),
    );
  }
}
