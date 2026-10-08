import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/daos/traslados_dao.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../sedes/presentation/sedes_providers.dart';

/// Traslados entre sedes.
///
/// Arriba, lo que espera una respuesta de quien mira —«Por resolver»—; después
/// el resto. Funciona sin conexión: pedir, aprobar y rechazar van por la cola.
class TrasladosPage extends ConsumerWidget {
  const TrasladosPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traslados = ref.watch(trasladosProvider);
    final porResolver = ref.watch(trasladosPorResolverProvider);
    final puedePedir = ref.watch(rolProvider).pideTraslados;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Traslados'),
          bottom: TabBar(
            tabs: [
              Tab(text: porResolver.isEmpty ? 'Pendientes' : 'Pendientes (${porResolver.length})'),
              const Tab(text: 'Historial'),
            ],
          ),
        ),
        body: traslados.when(
          loading: () => const SkeletonLista(),
          error: (e, _) => EstadoError(mensaje: '$e'),
          data: (lista) {
            final pendientes = lista.where((t) => t.pendiente).toList()
              ..sort((a, b) {
                // Lo que me toca resolver, primero.
                final ma = porResolver.contains(a) ? 0 : 1;
                final mb = porResolver.contains(b) ? 0 : 1;
                return ma != mb ? ma - mb : b.traslado.solicitadoEn.compareTo(a.traslado.solicitadoEn);
              });
            final historial = lista.where((t) => !t.pendiente).toList();
            return TabBarView(
              children: [
                _Lista(
                  items: pendientes,
                  porResolver: porResolver.map((r) => r.traslado.uuid).toSet(),
                  vacio: const EstadoVacio(
                    icono: Icons.swap_horiz_rounded,
                    titulo: 'Nada pendiente',
                    descripcion: 'Los traslados que pidas o que tengas que aprobar aparecen aquí.',
                  ),
                ),
                _Lista(
                  items: historial,
                  porResolver: const {},
                  vacio: const EstadoVacio(
                    icono: Icons.history_rounded,
                    titulo: 'Sin traslados todavía',
                    descripcion: 'Cuando se aprueben o rechacen, quedan aquí con todo su historial.',
                  ),
                ),
              ],
            );
          },
        ),
        floatingActionButton: puedePedir
            ? FloatingActionButton.extended(
                onPressed: () => context.push(Rutas.trasladoNuevo),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Pedir traslado'),
              )
            : null,
      ),
    );
  }
}

class _Lista extends StatelessWidget {
  const _Lista({required this.items, required this.porResolver, required this.vacio});

  final List<TrasladoResumen> items;
  final Set<String> porResolver;
  final Widget vacio;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return vacio;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) => EntradaEscalonada(
        indice: i,
        child: TarjetaTraslado(
          item: items[i],
          meToca: porResolver.contains(items[i].traslado.uuid),
        ),
      ),
    );
  }
}

/// Tarjeta de un traslado: de dónde a dónde, qué y en qué estado.
class TarjetaTraslado extends StatelessWidget {
  const TarjetaTraslado({super.key, required this.item, this.meToca = false});

  final TrasladoResumen item;
  final bool meToca;

  @override
  Widget build(BuildContext context) {
    final t = item.traslado;
    final (color, fondo, icono, texto) = estiloEstado(context, t.estado);

    return Card(
      shape: meToca
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: context.dominio.advertencia, width: 1.5),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push(Rutas.trasladoDetalle(t.uuid)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(t.numero, style: context.textos.labelLarge),
                  const Spacer(),
                  _Estado(color: color, fondo: fondo, icono: icono, texto: texto),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.origen?.nombre ?? 'Sede',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textos.titleSmall,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.arrow_forward_rounded, size: 18, color: context.colores.primary),
                  ),
                  Expanded(
                    child: Text(
                      item.destino?.nombre ?? 'Sede',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: context.textos.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${item.productos} producto${item.productos == 1 ? '' : 's'} · '
                '${item.unidades.format()} unidades · '
                '${item.solicitante?.nombre ?? 'alguien'} · ${Fechas.relativo(t.solicitadoEn)}',
                style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
              ),
              if (meToca) ...[
                const SizedBox(height: 8),
                Text(
                  t.confirma == 'GESTOR' ? 'Espera tu aprobación' : 'Espera tu confirmación de despacho',
                  style: context.textos.labelMedium?.copyWith(color: context.dominio.advertencia),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

(Color, Color, IconData, String) estiloEstado(BuildContext context, String estado) {
  final d = context.dominio;
  return switch (estado) {
    'APROBADO' => (d.exito, d.exitoContenedor, Icons.check_circle_rounded, 'Aprobado'),
    'RECHAZADO' => (d.peligro, d.peligroContenedor, Icons.cancel_rounded, 'Rechazado'),
    'CANCELADO' => (
        context.colores.onSurfaceVariant,
        context.colores.surfaceContainerHighest,
        Icons.block_rounded,
        'Cancelado',
      ),
    _ => (d.advertencia, d.advertenciaContenedor, Icons.schedule_rounded, 'Pendiente'),
  };
}

class _Estado extends StatelessWidget {
  const _Estado({required this.color, required this.fondo, required this.icono, required this.texto});

  final Color color;
  final Color fondo;
  final IconData icono;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 14, color: color),
          const SizedBox(width: 4),
          Text(texto, style: context.textos.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
