import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/sedes_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/providers/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../auth/presentation/usuarios_page.dart' show cambiosSedeProvider;
import '../../sedes/presentation/sedes_providers.dart' as sedes;

/// Piezas del inicio que dependen del rol y de las sedes. Todo sale de SQLite
/// salvo los cambios de sede, que se consultan en línea y, sin red, sólo dejan
/// de aparecer.

final ventasPorSedeProvider = StreamProvider<List<VentasSede>>((ref) {
  final hoy = Fechas.hoy();
  return ref.watch(sedesDaoProvider).observarVentasPorSede(hoy: hoy, ayer: Fechas.sumarDias(hoy, -1));
});

final cambiosInventarioHoyProvider = StreamProvider<List<CambioInventario>>(
  (ref) => ref.watch(sedesDaoProvider).observarCambiosInventario(desde: Fechas.hoy()),
);

// ─── Sede activa ────────────────────────────────────────────────────────────

/// Dónde está operando el teléfono. Quien tiene varias sedes la cambia aquí:
/// lo que venda o reciba después queda en la sede elegida.
class SelectorSedeActiva extends ConsumerWidget {
  const SelectorSedeActiva({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activa = ref.watch(sedeActivaProvider).value;
    final mias = ref.watch(sedes.misSedesProvider).value ?? const <Sede>[];
    if (activa == null) return const SizedBox.shrink();
    final puedeCambiar = mias.length > 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ActionChip(
          avatar: Icon(Icons.storefront_outlined, size: 18, color: context.colores.primary),
          label: Text(puedeCambiar ? '${activa.nombre}  ▾' : activa.nombre),
          onPressed: puedeCambiar ? () => _elegir(context, ref, mias, activa) : null,
          tooltip: puedeCambiar ? 'Cambiar de sede' : 'Tu sede',
        ),
      ),
    );
  }

  Future<void> _elegir(BuildContext context, WidgetRef ref, List<Sede> mias, Sede activa) async {
    final elegida = await showModalBottomSheet<Sede>(
      context: context,
      showDragHandle: true,
      builder: (hoja) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('¿En qué sede estás trabajando?', style: hoja.textos.titleMedium),
            ),
            for (final s in mias)
              ListTile(
                leading: Icon(s.uuid == activa.uuid ? Icons.radio_button_checked : Icons.radio_button_off),
                title: Text(s.nombre),
                subtitle: s.direccion == null ? null : Text(s.direccion!),
                onTap: () => Navigator.pop(hoja, s),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (elegida == null || elegida.uuid == activa.uuid || !context.mounted) return;

    // El turno de caja pertenece a la sede donde se abrió: cambiar de sede con
    // la caja abierta mezclaría ventas de dos sedes en el mismo cierre.
    final caja = ref.read(sedes.cajaAbiertaProvider).value;
    if (caja != null) {
      mostrarMensaje(context, 'Cierra tu caja antes de cambiar de sede', esError: true);
      return;
    }
    await ref.read(authRepositoryProvider).cambiarSedeActiva(elegida.uuid);
    if (context.mounted) mostrarMensaje(context, 'Ahora trabajas en ${elegida.nombre}', esExito: true);
  }
}

// ─── Aviso de fin de turno ──────────────────────────────────────────────────

class AvisoFinTurno extends ConsumerWidget {
  const AvisoFinTurno({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasta = ref.watch(avisoTurnoProvider);
    if (hasta == null) return const SizedBox.shrink();
    final vende = ref.watch(rolProvider).puedeVender;
    final caja = ref.watch(sedes.cajaAbiertaProvider).value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: context.dominio.advertenciaContenedor,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: vende && caja != null ? () => context.push(Rutas.caja) : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.alarm_rounded, color: context.dominio.advertencia, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Tu turno termina a las ${Fechas.formatHora(hasta)}. '
                    '${vende && caja != null ? 'Haz tu cierre de caja antes de salir.' : 'Al llegar la hora se cerrará la sesión.'}',
                    style: context.textos.bodySmall?.copyWith(color: context.dominio.advertencia),
                  ),
                ),
                if (vende && caja != null) Icon(Icons.chevron_right_rounded, color: context.dominio.advertencia),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Caja ───────────────────────────────────────────────────────────────────

/// Estado de la caja de quien tiene la sesión. Sólo para quien vende.
class TarjetaCaja extends ConsumerWidget {
  const TarjetaCaja({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(rolProvider).puedeVender) return const SizedBox.shrink();
    final caja = ref.watch(sedes.cajaAbiertaProvider);
    if (caja.isLoading) return const SizedBox.shrink();
    final abierta = caja.value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        child: ListTile(
          onTap: () => context.push(Rutas.caja),
          leading: CircleAvatar(
            backgroundColor: abierta == null ? context.dominio.advertenciaContenedor : context.dominio.exitoContenedor,
            child: Icon(
              abierta == null ? Icons.lock_outline_rounded : Icons.point_of_sale_rounded,
              color: abierta == null ? context.dominio.advertencia : context.dominio.exito,
              size: 20,
            ),
          ),
          title: Text(abierta == null ? 'Caja cerrada' : 'Caja abierta'),
          subtitle: Text(
            abierta == null
                ? 'Ábrela con la base de efectivo para que tus ventas cuenten en tu cierre'
                : 'Desde las ${Fechas.formatHora(abierta.abiertoEn)} · base ${Money(abierta.baseEfectivo).format()}',
          ),
          trailing: Text(abierta == null ? 'Abrir' : 'Cerrar', style: context.textos.labelLarge),
        ),
      ),
    );
  }
}

// ─── Por resolver ───────────────────────────────────────────────────────────

/// Lo que espera una decisión de quien mira: traslados que le toca confirmar,
/// ajustes de auxiliares, empleados que piden venir a su sede.
class TarjetaPorResolver extends ConsumerWidget {
  const TarjetaPorResolver({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rol = ref.watch(rolProvider);
    final traslados = rol.mueveEntreSedes ? ref.watch(sedes.trasladosPorResolverProvider) : const [];
    final ajustes = ref.watch(sedes.ajustesPorAprobarProvider);
    // En línea: sin red simplemente no aparece.
    final cambios = rol.esGestor
        ? (ref.watch(cambiosSedeProvider).value ?? const []).where((c) => c.puedoResolver).length
        : 0;

    final filas = <Widget>[
      if (traslados.isNotEmpty)
        _Fila(
          icono: Icons.local_shipping_outlined,
          texto: '${traslados.length} solicitud${traslados.length == 1 ? '' : 'es'} de traslado por despachar',
          onTap: () => context.push(
            traslados.length == 1 ? Rutas.trasladoDetalle(traslados.first.traslado.uuid) : Rutas.traslados,
          ),
        ),
      if (ajustes.isNotEmpty)
        _Fila(
          icono: Icons.fact_check_outlined,
          texto: '${ajustes.length} ajuste${ajustes.length == 1 ? '' : 's'} de inventario por aprobar',
          onTap: () => context.push(Rutas.solicitudesAjuste),
        ),
      if (cambios > 0)
        _Fila(
          icono: Icons.swap_horiz_rounded,
          texto: '$cambios empleado${cambios == 1 ? ' pide' : 's piden'} cambiar a tu sede',
          onTap: () => context.push(Rutas.usuarios),
        ),
    ];
    if (filas.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pending_actions_rounded, size: 20, color: context.colores.primary),
              const SizedBox(width: 8),
              Text('Por resolver', style: context.textos.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Card(child: Column(children: _conDivisores(filas))),
        ],
      ),
    );
  }
}

List<Widget> _conDivisores(List<Widget> filas) => [
      for (var i = 0; i < filas.length; i++) ...[
        if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
        filas[i],
      ],
    ];

class _Fila extends StatelessWidget {
  const _Fila({required this.icono, required this.texto, required this.onTap, this.detalle});

  final IconData icono;
  final String texto;
  final String? detalle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        onTap: onTap,
        leading: Icon(icono, color: context.colores.primary),
        title: Text(texto),
        subtitle: detalle == null ? null : Text(detalle!),
        trailing: const Icon(Icons.chevron_right_rounded),
      );
}

// ─── Stock bajo en las sedes ────────────────────────────────────────────────

/// Resumen de stock bajo por sede para gestores y auxiliares. El detalle, con
/// las acciones para resolverlo, está en la pantalla de stock bajo.
class TarjetaStockBajoSedes extends ConsumerWidget {
  const TarjetaStockBajoSedes({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(sedes.stockBajoProvider).value ?? const <StockBajo>[];
    if (items.isEmpty) return const SizedBox.shrink();
    final porSede = <String, (Sede, int, int)>{};
    for (final i in items) {
      final previo = porSede[i.sede.uuid];
      porSede[i.sede.uuid] = (i.sede, (previo?.$2 ?? 0) + 1, (previo?.$3 ?? 0) + (i.agotado ? 1 : 0));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Card(
        child: Column(
          children: _conDivisores([
            for (final (sede, total, agotados) in porSede.values)
              _Fila(
                icono: Icons.warning_amber_rounded,
                texto: '$total producto${total == 1 ? '' : 's'} en su mínimo · ${sede.nombre}',
                detalle: agotados == 0 ? null : '$agotados agotado${agotados == 1 ? '' : 's'}',
                onTap: () => context.push(Rutas.stockBajo),
              ),
          ]),
        ),
      ),
    );
  }
}

// ─── Ventas por sede (director y gerentes con varias sedes) ─────────────────

class TarjetaVentasPorSede extends ConsumerWidget {
  const TarjetaVentasPorSede({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lista = ref.watch(ventasPorSedeProvider).value ?? const <VentasSede>[];
    if (lista.length < 2) return const SizedBox.shrink();
    final total = Money.sumar(lista.map((v) => v.hoy));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.store_mall_directory_outlined, size: 20, color: context.colores.primary),
              const SizedBox(width: 8),
              Text('Hoy por sede', style: context.textos.titleMedium),
              const Spacer(),
              Text(total.format(), style: context.textos.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: _conDivisores([
                for (final v in lista)
                  ListTile(
                    title: Text(v.sede.nombre),
                    subtitle: Text('${v.numHoy} venta${v.numHoy == 1 ? '' : 's'} · ayer ${v.ayer.format()}'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(v.hoy.format(), style: context.textos.titleSmall),
                        if (v.variacion != null)
                          Text(
                            '${v.variacion! >= 0 ? '▲' : '▼'} ${v.variacion!.abs().toStringAsFixed(0)} %',
                            style: context.textos.labelSmall?.copyWith(
                              color: v.variacion! >= 0 ? context.dominio.exito : context.dominio.peligro,
                            ),
                          ),
                      ],
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Cambios de inventario (director) ───────────────────────────────────────

const _tiposMovimiento = {
  'ENTRADA': ('Entrada', Icons.add_box_outlined),
  'INICIAL': ('Stock inicial', Icons.flag_outlined),
  'DEVOLUCION': ('Devolución', Icons.undo_rounded),
  'MERMA': ('Merma', Icons.broken_image_outlined),
  'AJUSTE': ('Ajuste', Icons.tune_rounded),
  'SALIDA': ('Salida', Icons.outbox_outlined),
  'TRASLADO': ('Traslado', Icons.local_shipping_outlined),
};

/// Todo cambio de stock que no es una venta, con quién y cuándo. El Director
/// General lo pidió así: ver lo que hacen gerentes y auxiliares en el
/// inventario sin tener que buscarlo.
class TarjetaCambiosInventario extends ConsumerWidget {
  const TarjetaCambiosInventario({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cambios = ref.watch(cambiosInventarioHoyProvider).value ?? const <CambioInventario>[];
    if (cambios.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.manage_history_rounded, size: 20, color: context.colores.primary),
              const SizedBox(width: 8),
              Text('Cambios de inventario hoy', style: context.textos.titleMedium),
              const Spacer(),
              TextButton(onPressed: () => context.push(Rutas.movimientos), child: const Text('Ver todo')),
            ],
          ),
          Card(
            child: Column(
              children: _conDivisores([
                for (final c in cambios.take(6))
                  ListTile(
                    dense: true,
                    onTap: () => context.push('${Rutas.movimientos}?producto=${c.producto.uuid}'),
                    leading: Icon(_tiposMovimiento[c.movimiento.tipo]?.$2 ?? Icons.swap_vert_rounded),
                    title: Text(
                      '${_tiposMovimiento[c.movimiento.tipo]?.$1 ?? c.movimiento.tipo} · ${c.producto.nombre}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        c.usuario?.nombre ?? 'Sin usuario',
                        ?c.sede?.nombre,
                        Fechas.formatHora(c.movimiento.fecha),
                        if (c.movimiento.aprobadoPorUuid != null) 'aprobado',
                      ].join(' · '),
                    ),
                    trailing: Text(
                      _cantidad(c.movimiento),
                      style: context.textos.titleSmall?.copyWith(
                        color: _resta(c.movimiento) ? context.dominio.peligro : context.dominio.exito,
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  static bool _resta(Movimiento m) =>
      m.tipo == 'MERMA' ||
      m.tipo == 'SALIDA' ||
      (m.stockAnterior != null && m.stockResultante != null && m.stockResultante! < m.stockAnterior!);

  static String _cantidad(Movimiento m) => '${_resta(m) ? '−' : '+'}${Cantidad(m.cantidad.abs()).format()}';
}
