import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/daos/traslados_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/negocio/traslados.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../sedes/presentation/sedes_providers.dart';
import 'traslados_page.dart';

final _detalleProvider = StreamProvider.autoDispose.family<TrasladoCompleto?, String>(
  (ref, uuid) => ref.watch(trasladosDaoProvider).observarDetalle(uuid),
);

/// Un traslado: qué se mueve, entre qué sedes, y su historial completo —quién
/// lo pidió, quién lo aprobó o rechazó, y cuándo—. Las acciones sólo aparecen
/// para quien puede usarlas.
class TrasladoDetallePage extends ConsumerWidget {
  const TrasladoDetallePage({super.key, required this.uuid});

  final String uuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detalle = ref.watch(_detalleProvider(uuid));
    final actor = ref.watch(actorProvider);

    return Scaffold(
      appBar: AppBar(title: Text(detalle.value?.resumen.traslado.numero ?? 'Traslado')),
      body: detalle.when(
        loading: () => const SkeletonLista(filas: 4),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (d) {
          if (d == null) {
            return const EstadoVacio(icono: Icons.search_off_rounded, titulo: 'No se encontró el traslado');
          }
          final t = d.resumen.traslado;
          final (color, fondo, icono, texto) = estiloEstado(context, t.estado);
          final puedeResolver = actor != null &&
              motivoNoPuedeResolver(
                    estado: t.estado,
                    confirma: t.confirma,
                    sedeOrigen: t.sedeOrigenUuid,
                    solicitadoPor: t.solicitadoPorUuid,
                    actor: actor,
                  ) ==
                  null;
          final puedeCancelar = actor != null &&
              motivoNoPuedeCancelar(estado: t.estado, solicitadoPor: t.solicitadoPorUuid, actor: actor) == null;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(16)),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(icono, color: color),
                        const SizedBox(width: 8),
                        Text(texto, style: context.textos.titleMedium?.copyWith(color: color)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(child: _Sede(etiqueta: 'Sale de', nombre: d.resumen.origen?.nombre ?? '—')),
                        Icon(Icons.arrow_forward_rounded, color: color),
                        Expanded(
                          child: _Sede(etiqueta: 'Llega a', nombre: d.resumen.destino?.nombre ?? '—', alFinal: true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (t.notas != null) ...[
                const SizedBox(height: 12),
                Text('«${t.notas}»', style: context.textos.bodyMedium?.copyWith(fontStyle: FontStyle.italic)),
              ],
              if (t.estado == 'PENDIENTE') ...[
                const SizedBox(height: 12),
                Text(
                  t.confirma == 'GESTOR'
                      ? 'Lo pidió un empleado: lo aprueba el gerente de ${d.resumen.origen?.nombre ?? 'la sede de origen'} o el director.'
                      : 'Lo pidió un gerente: lo confirma alguien de ${d.resumen.origen?.nombre ?? 'la sede de origen'} al despacharlo.',
                  style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 20),
              Text('Productos', style: context.textos.titleMedium),
              const SizedBox(height: 6),
              for (final l in d.detalles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(l.descripcion),
                  trailing: Text(Cantidad(l.cantidad).format(), style: context.textos.titleMedium),
                ),
              const SizedBox(height: 20),
              Text('Historial', style: context.textos.titleMedium),
              const SizedBox(height: 8),
              for (final e in d.eventos) _Evento(evento: e.evento.evento, quien: e.usuario?.nombre, fecha: e.evento.fecha, nota: e.evento.nota),
              if (puedeResolver || puedeCancelar) ...[
                const SizedBox(height: 24),
                if (puedeResolver)
                  FilledButton.icon(
                    onPressed: () => _aprobar(context, ref, t.confirma),
                    icon: const Icon(Icons.check_rounded),
                    label: Text(t.confirma == 'GESTOR' ? 'Aprobar y mover el stock' : 'Confirmar despacho'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                  ),
                if (puedeResolver) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () => _rechazar(context, ref),
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Rechazar'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  ),
                ],
                if (puedeCancelar && !puedeResolver)
                  OutlinedButton.icon(
                    onPressed: () => _cancelar(context, ref),
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('Cancelar traslado'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _aprobar(BuildContext context, WidgetRef ref, String confirma) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(confirma == 'GESTOR' ? '¿Aprobar el traslado?' : '¿Confirmar el despacho?'),
        content: const Text('El stock sale de la sede de origen y entra en la de destino ahora mismo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Volver')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sí, mover')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _ejecutar(context, ref, () => ref.read(trasladosDaoProvider).aprobar(uuid), 'Traslado aprobado');
  }

  Future<void> _rechazar(BuildContext context, WidgetRef ref) async {
    final motivo = await _pedirMotivo(context, '¿Por qué lo rechazas?');
    if (motivo == null || !context.mounted) return;
    await _ejecutar(
      context,
      ref,
      () => ref.read(trasladosDaoProvider).rechazar(uuid, motivo: motivo),
      'Traslado rechazado',
    );
  }

  Future<void> _cancelar(BuildContext context, WidgetRef ref) =>
      _ejecutar(context, ref, () => ref.read(trasladosDaoProvider).cancelar(uuid), 'Traslado cancelado');

  Future<void> _ejecutar(BuildContext context, WidgetRef ref, Future<void> Function() accion, String ok) async {
    try {
      await accion();
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (context.mounted) mostrarMensaje(context, ok, esExito: true);
    } catch (e) {
      if (context.mounted) mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }
}

/// Pide un motivo en un diálogo. Devuelve null si se cancela.
Future<String?> _pedirMotivo(BuildContext context, String titulo) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(titulo),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLength: 200,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Motivo (lo verá quien lo pidió)'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Volver')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Rechazar')),
      ],
    ),
  );
}

class _Sede extends StatelessWidget {
  const _Sede({required this.etiqueta, required this.nombre, this.alFinal = false});

  final String etiqueta;
  final String nombre;
  final bool alFinal;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alFinal ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(etiqueta, style: context.textos.labelSmall),
        Text(nombre, style: context.textos.titleMedium, textAlign: alFinal ? TextAlign.end : TextAlign.start),
      ],
    );
  }
}

class _Evento extends StatelessWidget {
  const _Evento({required this.evento, required this.quien, required this.fecha, this.nota});

  final String evento;
  final String? quien;
  final DateTime fecha;
  final String? nota;

  @override
  Widget build(BuildContext context) {
    final (icono, texto) = switch (evento) {
      'APROBADO' => (Icons.check_circle_outline_rounded, 'Aprobado'),
      'RECHAZADO' => (Icons.cancel_outlined, 'Rechazado'),
      'CANCELADO' => (Icons.block_rounded, 'Cancelado'),
      _ => (Icons.add_circle_outline_rounded, 'Pedido'),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icono, color: context.colores.primary),
      title: Text('$texto por ${quien ?? 'alguien'}'),
      subtitle: Text([Fechas.formatFechaHoraDocumento(fecha), ?nota].join(' · ')),
    );
  }
}
