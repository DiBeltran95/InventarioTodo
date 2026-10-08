import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/daos/sedes_dao.dart';
import '../../../core/providers/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../sedes/presentation/sedes_providers.dart';

/// Productos en o bajo su mínimo, por sede.
///
/// No es un informe: cada fila trae la acción que lo resuelve. Pedir un
/// traslado desde una sede que tiene de sobra, o registrar la entrada de lo que
/// llegó del proveedor. Se calcula en el teléfono, así que el aviso aparece en
/// cuanto una venta deja el producto en su mínimo, también sin red.
class StockBajoPage extends ConsumerWidget {
  const StockBajoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lista = ref.watch(stockBajoProvider);
    final activa = ref.watch(sedeActivaProvider).value;
    final rol = ref.watch(rolProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Stock bajo')),
      body: lista.when(
        loading: () => const SkeletonLista(),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (items) {
          if (items.isEmpty) {
            return const EstadoVacio(
              icono: Icons.verified_rounded,
              titulo: 'Todo por encima del mínimo',
              descripcion: 'Cuando un producto llegue a su mínimo en alguna de tus sedes, aparece aquí.',
            );
          }
          final porSede = <String, List<StockBajo>>{};
          for (final i in items) {
            porSede.putIfAbsent(i.sede.uuid, () => []).add(i);
          }
          var indice = 0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              for (final grupo in porSede.values) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                  child: Row(
                    children: [
                      Icon(Icons.storefront_outlined, size: 18, color: context.colores.primary),
                      const SizedBox(width: 6),
                      Text(grupo.first.sede.nombre, style: context.textos.titleMedium),
                      const SizedBox(width: 8),
                      Text(
                        '${grupo.length} producto${grupo.length == 1 ? '' : 's'}',
                        style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                for (final item in grupo)
                  EntradaEscalonada(
                    indice: indice++,
                    child: _Fila(
                      item: item,
                      esSedeActiva: item.sede.uuid == activa?.uuid,
                      puedeEntrada: rol.puedeRegistrarEntradas,
                      // El gerente lo solicita a otra sede; el director lo trae
                      // él mismo. El auxiliar no pide: registra la entrada.
                      textoTraslado: rol.solicitaTraslados
                          ? 'Solicitar'
                          : (rol.esDirector ? 'Traer de otra sede' : null),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  const _Fila({
    required this.item,
    required this.esSedeActiva,
    required this.puedeEntrada,
    required this.textoTraslado,
  });

  final StockBajo item;
  final bool esSedeActiva;
  final bool puedeEntrada;

  /// null = quien mira no solicita ni mueve unidades.
  final String? textoTraslado;

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    final (color, fondo) = item.agotado ? (d.peligro, d.peligroContenedor) : (d.advertencia, d.advertenciaContenedor);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(item.producto.nombre, style: context.textos.titleSmall, maxLines: 2),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icono además del color: el estado no puede depender
                      // sólo del color.
                      Icon(item.agotado ? Icons.error_rounded : Icons.warning_amber_rounded, size: 14, color: color),
                      const SizedBox(width: 4),
                      Text(
                        item.agotado ? 'Agotado' : '${item.stock.format()} / ${item.minimo.format()}',
                        style: context.textos.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Faltan ${item.faltante.format()} para el mínimo',
              style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (textoTraslado != null)
                  TextButton.icon(
                    onPressed: () => context.push(
                      '${Rutas.trasladoNuevo}?producto=${item.producto.uuid}&destino=${item.sede.uuid}',
                    ),
                    icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                    label: Text(textoTraslado!),
                  ),
                // La entrada se registra en la sede activa del teléfono: sólo
                // tiene sentido ofrecerla para esa sede.
                if (puedeEntrada && esSedeActiva)
                  TextButton.icon(
                    onPressed: () => context.push('${Rutas.entrada}?producto=${item.producto.uuid}'),
                    icon: const Icon(Icons.add_box_outlined, size: 18),
                    label: const Text('Registrar entrada'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
