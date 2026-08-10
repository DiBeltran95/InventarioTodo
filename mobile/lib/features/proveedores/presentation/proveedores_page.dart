import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/daos/proveedores_dao.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/widgets/estados.dart';
import 'proveedores_providers.dart';
import 'widgets/ficha_proveedor.dart';
import 'widgets/formulario_proveedor.dart';

/// Proveedores.
///
/// A quién le compras. Es una agenda de trabajo, no un maestro de datos: por
/// eso lo único obligatorio es el nombre, y la ficha se abre en una hoja para
/// llamar en dos toques. Exigir NIT y dirección para dar de alta a «Don Jorge,
/// el de las gaseosas» sólo consigue que nadie registre proveedores.
///
/// Funciona **sin conexión**: se escribe en SQLite y la cola de salida lo envía
/// cuando haya red, igual que el resto del catálogo.
class ProveedoresPage extends ConsumerStatefulWidget {
  const ProveedoresPage({super.key});

  @override
  ConsumerState<ProveedoresPage> createState() => _ProveedoresPageState();
}

class _ProveedoresPageState extends ConsumerState<ProveedoresPage> {
  final _busqueda = TextEditingController();
  Timer? _rebote;

  @override
  void initState() {
    super.initState();
    _busqueda.text = ref.read(busquedaProveedoresProvider);
  }

  @override
  void dispose() {
    _rebote?.cancel();
    _busqueda.dispose();
    super.dispose();
  }

  void _buscar(String texto) {
    // Rebote corto: teclear «distribui» dispararía nueve consultas seguidas.
    _rebote?.cancel();
    _rebote = Timer(const Duration(milliseconds: 220), () {
      ref.read(busquedaProveedoresProvider.notifier).buscar(texto);
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final proveedores = ref.watch(proveedoresListaProvider);
    final buscando = ref.watch(busquedaProveedoresProvider).isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Proveedores')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _busqueda,
              onChanged: _buscar,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Buscar por nombre, NIT o contacto',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _busqueda.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _busqueda.clear();
                          ref.read(busquedaProveedoresProvider.notifier).limpiar();
                          FocusScope.of(context).unfocus();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Limpiar',
                      ),
              ),
            ),
          ),
          Expanded(
            child: proveedores.when(
              loading: () => const SkeletonLista(),
              error: (e, _) => EstadoError(mensaje: '$e'),
              data: (lista) {
                if (lista.isEmpty) {
                  return EstadoVacio(
                    icono: buscando
                        ? Icons.search_off_rounded
                        : Icons.local_shipping_outlined,
                    titulo: buscando
                        ? 'Ningún proveedor coincide'
                        : 'Aún no hay proveedores',
                    descripcion: buscando
                        ? 'Prueba con otro término.'
                        : 'Registra a quién le compras para poder asociarlo a '
                            'las entradas de mercancía y saber a quién pedirle.',
                    textoAccion: buscando ? null : 'Añadir proveedor',
                    onAccion: buscando ? null : () => _formulario(context),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                  itemCount: lista.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => EntradaEscalonada(
                    indice: i,
                    child: _FilaProveedor(
                      item: lista[i],
                      onTap: () => _abrirFicha(context, lista[i]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _formulario(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Añadir'),
      ),
    );
  }

  void _abrirFicha(BuildContext context, ProveedorConUso item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => FichaProveedor(
        item: item,
        onEditar: () => _formulario(context, proveedor: item),
      ),
    );
  }

  Future<void> _formulario(
    BuildContext context, {
    ProveedorConUso? proveedor,
  }) async {
    final guardado = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FormularioProveedor(proveedor: proveedor?.proveedor),
    );

    if (guardado == true && context.mounted) {
      mostrarMensaje(
        context,
        proveedor == null ? 'Proveedor añadido' : 'Proveedor actualizado',
        esExito: true,
      );
    }
  }
}

// ─── Fila de la lista ───────────────────────────────────────────────────────

class _FilaProveedor extends StatelessWidget {
  const _FilaProveedor({required this.item, required this.onTap});

  final ProveedorConUso item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: context.colores.secondaryContainer,
          child: Text(
            item.iniciales,
            style: context.textos.titleSmall?.copyWith(
              color: context.colores.onSecondaryContainer,
            ),
          ),
        ),
        title: Text(
          item.nombre,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textos.titleSmall,
        ),
        subtitle: item.subtitulo == null
            ? null
            : Text(
                item.subtitulo!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textos.bodySmall,
              ),
        trailing: item.entradas == 0
            ? const Icon(Icons.chevron_right_rounded)
            // El número de entradas dice de un vistazo con quién trabajas de
            // verdad y quién quedó ahí de una prueba.
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${item.entradas}',
                    style: context.textos.titleSmall
                        ?.copyWith(color: context.colores.primary),
                  ),
                  Text(
                    item.entradas == 1 ? 'entrada' : 'entradas',
                    style: context.textos.labelSmall?.copyWith(
                      color: context.colores.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
