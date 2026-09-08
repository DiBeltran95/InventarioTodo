
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/daos/productos_dao.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/foto_producto.dart';
import '../../../auth/presentation/auth_providers.dart';

/// Fila de producto en la lista del catálogo.
///
/// El stock va a la derecha y con color, porque es el dato que se consulta de
/// un vistazo; el precio queda subordinado. En una app de inventario, «¿cuánto
/// queda?» se pregunta diez veces más que «¿cuánto vale?».
class TarjetaProducto extends ConsumerWidget {
  const TarjetaProducto({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
  });

  final ProductoConCategoria item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dominio = context.dominio;

    // El rol lo consulta la tarjeta, no quien la coloca.
    //
    // Antes esto era un parámetro `mostrarCosto` que cada pantalla debía
    // acordarse de pasar. El costo de compra es dato privado del negocio: basta
    // que alguien reutilice esta tarjeta un día y olvide el parámetro para
    // filtrarlo. Preguntando aquí, ese descuido no puede ocurrir.
    final mostrarCosto = ref.watch(esAdminProvider);
    final (colorStock, fondoStock) = item.agotado
        ? (dominio.peligro, dominio.peligroContenedor)
        : item.bajoStock
            ? (dominio.advertencia, dominio.advertenciaContenedor)
            : (dominio.exito, dominio.exitoContenedor);

    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // La transición Hero comparte la miniatura con la ficha del
              // producto: el elemento se «expande» en vez de aparecer de golpe.
              Hero(
                tag: 'producto-${item.uuid}',
                child: FotoProducto(producto: item),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textos.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.sku +
                          (item.categoria != null ? ' · ${item.categoria!.nombre}' : ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textos.bodySmall?.copyWith(
                        color: context.colores.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          item.precioVenta.format(),
                          style: context.textos.titleSmall
                              ?.copyWith(color: context.colores.primary),
                        ),
                        if (mostrarCosto && item.precioCompra.esPositivo) ...[
                          const SizedBox(width: 8),
                          Text(
                            'costo ${item.precioCompra.format()}',
                            style: context.textos.labelSmall?.copyWith(
                              color: context.colores.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: fondoStock,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.stock.format(),
                      style: context.textos.titleMedium?.copyWith(color: colorStock),
                    ),
                    Text(
                      item.producto.unidadMedida.toLowerCase(),
                      style: context.textos.labelSmall?.copyWith(color: colorStock),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

