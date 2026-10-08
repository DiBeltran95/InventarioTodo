import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/sedes_dao.dart';
import '../../../core/database/daos/traslados_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/negocio/traslados.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../disponibilidad/presentation/disponibilidad_widgets.dart';
import '../../sedes/presentation/sedes_providers.dart';
import 'traslados_page.dart';

final _detalleProvider = StreamProvider.autoDispose.family<TrasladoCompleto?, String>(
  (ref, uuid) => ref.watch(trasladosDaoProvider).observarDetalle(uuid),
);

/// Un traslado: qué se pide o se movió, entre qué sedes, y su historial
/// completo —quién lo pidió, quién lo despachó o rechazó, y cuándo—.
///
/// A quien despacha (el auxiliar de la sede origen o el director) le deja
/// elegir cuántas unidades salen de cada producto: lo pedido por defecto, o
/// menos si no hay o no conviene. Las acciones sólo aparecen para quien puede
/// usarlas.
class TrasladoDetallePage extends ConsumerStatefulWidget {
  const TrasladoDetallePage({super.key, required this.uuid});

  final String uuid;

  @override
  ConsumerState<TrasladoDetallePage> createState() => _TrasladoDetallePageState();
}

class _TrasladoDetallePageState extends ConsumerState<TrasladoDetallePage> {
  /// Lo que quien despacha decidió enviar por línea (uuid → cantidad). Una
  /// línea sin tocar sale con lo pedido, tope en lo que haya en el origen.
  final _enviar = <String, Cantidad>{};
  bool _enviando = false;

  @override
  Widget build(BuildContext context) {
    final detalle = ref.watch(_detalleProvider(widget.uuid));
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
          final (color, fondo, icono, texto) = estiloEstado(context, t.estado, directo: d.resumen.directo);
          final puedeDespachar = actor != null &&
              motivoNoPuedeDespachar(estado: t.estado, sedeOrigen: t.sedeOrigenUuid, actor: actor) == null;
          final puedeCancelar = actor != null &&
              motivoNoPuedeCancelar(estado: t.estado, solicitadoPor: t.solicitadoPorUuid, actor: actor) == null;
          final origen = d.resumen.origen?.nombre ?? 'la sede de origen';

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
                        if (d.parcial) ...[
                          const SizedBox(width: 8),
                          Text('· parcial', style: context.textos.labelLarge?.copyWith(color: color)),
                        ],
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
                  puedeDespachar
                      ? 'Elige cuántas unidades salen de cada producto. Puedes enviar menos de lo pedido.'
                      : 'Lo despacha el auxiliar de inventario de $origen o el Director General. '
                          'Pueden enviar menos de lo pedido.',
                  style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 20),
              Text('Productos', style: context.textos.titleMedium),
              const SizedBox(height: 6),
              for (final l in d.detalles)
                puedeDespachar
                    ? _LineaDespacho(
                        linea: l,
                        sedeOrigen: t.sedeOrigenUuid,
                        valor: _enviar[l.uuid],
                        onCambio: (c) => setState(() => _enviar[l.uuid] = c),
                      )
                    : _LineaResumen(linea: l),
              const SizedBox(height: 20),
              Text('Historial', style: context.textos.titleMedium),
              const SizedBox(height: 8),
              for (final e in d.eventos)
                _Evento(
                  evento: e.evento.evento,
                  directo: d.resumen.directo,
                  quien: e.usuario?.nombre,
                  fecha: e.evento.fecha,
                  nota: e.evento.nota,
                ),
              if (puedeDespachar || puedeCancelar) ...[
                const SizedBox(height: 24),
                if (puedeDespachar) _BotonDespachar(detalle: d, enviar: _enviar, enviando: _enviando, onDespachar: _despachar),
                if (puedeDespachar) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _enviando ? null : _rechazar,
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Rechazar'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  ),
                ],
                if (puedeCancelar && !puedeDespachar)
                  OutlinedButton.icon(
                    onPressed: _enviando ? null : _cancelar,
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('Cancelar solicitud'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _despachar(Map<String, Cantidad> enviadas, Cantidad total) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('¿Despachar ${total.format()} unidades?'),
        content: const Text('Salen de la sede de origen y entran en la de destino ahora mismo.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Volver')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sí, despachar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _ejecutar(
      () => ref.read(trasladosDaoProvider).despachar(widget.uuid, enviadas: enviadas),
      'Traslado despachado',
    );
  }

  Future<void> _rechazar() async {
    final motivo = await _pedirMotivo(context, '¿Por qué lo rechazas?');
    if (motivo == null || !mounted) return;
    await _ejecutar(
      () => ref.read(trasladosDaoProvider).rechazar(widget.uuid, motivo: motivo),
      'Solicitud rechazada',
    );
  }

  Future<void> _cancelar() =>
      _ejecutar(() => ref.read(trasladosDaoProvider).cancelar(widget.uuid), 'Solicitud cancelada');

  Future<void> _ejecutar(Future<void> Function() accion, String ok) async {
    setState(() => _enviando = true);
    try {
      await accion();
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (mounted) mostrarMensaje(context, ok, esExito: true);
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }
}

/// Cuánto hay de un producto en una sede, según el teléfono.
Cantidad _hayEn(List<StockEnSede> filas, String sede) =>
    filas.where((f) => f.sede.uuid == sede).firstOrNull?.stock ?? const Cantidad(0);

/// Lo que sale de una línea si quien despacha no la toca: lo pedido, con tope
/// en lo que hay.
Cantidad _porDefecto(TrasladoDetalle l, Cantidad hay) {
  final pedida = Cantidad(l.cantidad);
  if (hay.esNegativa) return const Cantidad(0);
  return pedida > hay ? hay : pedida;
}

class _LineaDespacho extends ConsumerWidget {
  const _LineaDespacho({required this.linea, required this.sedeOrigen, required this.valor, required this.onCambio});

  final TrasladoDetalle linea;
  final String sedeOrigen;
  final Cantidad? valor;
  final ValueChanged<Cantidad> onCambio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filas = linea.productoUuid == null
        ? const <StockEnSede>[]
        : ref.watch(disponibilidadProvider(linea.productoUuid!)).value ?? const <StockEnSede>[];
    final hay = _hayEn(filas, sedeOrigen);
    final enviar = valor ?? _porDefecto(linea, hay);
    final pedida = Cantidad(linea.cantidad);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(linea.descripcion, style: context.textos.titleSmall),
            Text(
              'Pidieron ${pedida.format()} · hay ${hay.format()} en el origen',
              style: context.textos.bodySmall?.copyWith(
                color: hay < pedida ? context.dominio.advertencia : context.colores.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SelectorCantidad(
              valor: enviar,
              maximo: hay.esNegativa ? const Cantidad(0) : hay,
              onCambio: onCambio,
            ),
          ],
        ),
      ),
    );
  }
}

class _LineaResumen extends StatelessWidget {
  const _LineaResumen({required this.linea});

  final TrasladoDetalle linea;

  @override
  Widget build(BuildContext context) {
    final pedida = Cantidad(linea.cantidad);
    final enviada = linea.cantidadEnviada == null ? null : Cantidad(linea.cantidadEnviada!);
    final parcial = enviada != null && enviada != pedida;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(linea.descripcion),
      subtitle: parcial ? Text('Pidieron ${pedida.format()}') : null,
      trailing: Text(
        parcial ? 'Salieron ${enviada.format()}' : (enviada ?? pedida).format(),
        style: context.textos.titleMedium?.copyWith(color: parcial ? context.dominio.advertencia : null),
      ),
    );
  }
}

/// «Despachar N unidades»: suma lo elegido en cada línea (o lo que sale por
/// defecto) y no deja despachar cero.
class _BotonDespachar extends ConsumerWidget {
  const _BotonDespachar({required this.detalle, required this.enviar, required this.enviando, required this.onDespachar});

  final TrasladoCompleto detalle;
  final Map<String, Cantidad> enviar;
  final bool enviando;
  final Future<void> Function(Map<String, Cantidad> enviadas, Cantidad total) onDespachar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final origen = detalle.resumen.traslado.sedeOrigenUuid;
    final enviadas = <String, Cantidad>{};
    for (final l in detalle.detalles) {
      final filas = l.productoUuid == null
          ? const <StockEnSede>[]
          : ref.watch(disponibilidadProvider(l.productoUuid!)).value ?? const <StockEnSede>[];
      enviadas[l.uuid] = enviar[l.uuid] ?? _porDefecto(l, _hayEn(filas, origen));
    }
    final total = Cantidad.sumar(enviadas.values);
    final completo = detalle.detalles.every((l) => enviadas[l.uuid]!.milesimas == l.cantidad);

    return FilledButton.icon(
      onPressed: enviando || total.milesimas <= 0 ? null : () => onDespachar(enviadas, total),
      icon: const Icon(Icons.local_shipping_outlined),
      label: Text(
        total.milesimas <= 0
            ? 'No hay nada para enviar'
            : completo
                ? 'Despachar todo (${total.format()})'
                : 'Despachar ${total.format()} unidades',
      ),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
    );
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
  const _Evento({required this.evento, required this.directo, required this.quien, required this.fecha, this.nota});

  final String evento;
  final bool directo;
  final String? quien;
  final DateTime fecha;
  final String? nota;

  @override
  Widget build(BuildContext context) {
    final (icono, texto) = switch (evento) {
      'APROBADO' => (Icons.local_shipping_outlined, directo ? 'Movido' : 'Despachado'),
      'RECHAZADO' => (Icons.cancel_outlined, 'Rechazado'),
      'CANCELADO' => (Icons.block_rounded, 'Cancelado'),
      _ => (Icons.add_circle_outline_rounded, directo ? 'Registrado' : 'Solicitado'),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icono, color: context.colores.primary),
      title: Text('$texto por ${quien ?? 'alguien'}'),
      subtitle: Text([Fechas.formatFechaHoraDocumento(fecha), ?nota].join(' · ')),
    );
  }
}
