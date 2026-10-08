import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/daos/ajustes_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/encabezado_hoja.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../sedes/presentation/sedes_providers.dart';

/// Solicitudes de ajuste.
///
/// El auxiliar ve las suyas y en qué quedaron. El gerente ve las de sus sedes
/// y las aprueba o rechaza: el stock no cambia hasta que él lo decide.
class SolicitudesAjustePage extends ConsumerWidget {
  const SolicitudesAjustePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final solicitudes = ref.watch(solicitudesAjusteProvider);
    final sesion = ref.watch(sesionProvider).value;
    final esGestor = sesion?.rol.esGestor ?? false;

    return Scaffold(
      appBar: AppBar(title: Text(esGestor ? 'Ajustes por aprobar' : 'Mis solicitudes de ajuste')),
      body: solicitudes.when(
        loading: () => const SkeletonLista(),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (lista) {
          if (lista.isEmpty) {
            return EstadoVacio(
              icono: Icons.fact_check_outlined,
              titulo: esGestor ? 'Nada por aprobar' : 'Sin solicitudes',
              descripcion: esGestor
                  ? 'Cuando un auxiliar pida un conteo, una merma o un ajuste, aparece aquí.'
                  : 'Desde la ficha de un producto puedes pedir un conteo, una merma o un ajuste.',
            );
          }
          final pendientes = lista.where((s) => s.pendiente).toList();
          final resueltas = lista.where((s) => !s.pendiente).toList();
          var i = 0;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (pendientes.isNotEmpty) _Titulo('Pendientes (${pendientes.length})'),
              for (final s in pendientes)
                EntradaEscalonada(
                  indice: i++,
                  child: _Tarjeta(
                    item: s,
                    puedeResolver: esGestor && s.solicitud.solicitadoPorUuid != sesion?.usuarioUuid,
                  ),
                ),
              if (resueltas.isNotEmpty) _Titulo('Resueltas'),
              for (final s in resueltas) EntradaEscalonada(indice: i++, child: _Tarjeta(item: s, puedeResolver: false)),
            ],
          );
        },
      ),
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Text(texto, style: context.textos.titleMedium),
      );
}

class _Tarjeta extends ConsumerWidget {
  const _Tarjeta({required this.item, required this.puedeResolver});

  final SolicitudConDatos item;
  final bool puedeResolver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = item.solicitud;
    final d = context.dominio;
    final (color, texto) = switch (s.estado) {
      'APROBADA' => (d.exito, 'Aprobada'),
      'RECHAZADA' => (d.peligro, 'Rechazada'),
      _ => (d.advertencia, 'Pendiente'),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(item.producto?.nombre ?? 'Producto', style: context.textos.titleSmall)),
                Text(texto, style: context.textos.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 4),
            Text(item.descripcion, style: context.textos.bodyMedium),
            if (s.motivo != null) Text('«${s.motivo}»', style: context.textos.bodySmall),
            const SizedBox(height: 4),
            Text(
              '${item.solicitante?.nombre ?? 'Auxiliar'} · ${item.sede?.nombre ?? ''} · ${Fechas.relativo(s.solicitadoEn)}',
              style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
            ),
            if (s.estado == 'RECHAZADA' && s.motivoRechazo != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Motivo: ${s.motivoRechazo}', style: context.textos.bodySmall?.copyWith(color: d.peligro)),
              ),
            if (puedeResolver)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => _rechazar(context, ref), child: const Text('Rechazar')),
                  const SizedBox(width: 4),
                  FilledButton.tonal(onPressed: () => _aprobar(context, ref), child: const Text('Aprobar')),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _aprobar(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(ajustesDaoProvider).aprobar(item.solicitud.uuid);
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (context.mounted) mostrarMensaje(context, 'Ajuste aprobado: el stock ya cambió', esExito: true);
    } catch (e) {
      if (context.mounted) mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }

  Future<void> _rechazar(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final motivo = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('¿Por qué lo rechazas?'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Lo verá el auxiliar'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Volver')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('Rechazar')),
        ],
      ),
    );
    if (motivo == null) return;
    try {
      await ref.read(ajustesDaoProvider).rechazar(item.solicitud.uuid, motivo: motivo.isEmpty ? null : motivo);
      ref.read(syncEngineProvider).solicitar();
      if (context.mounted) mostrarMensaje(context, 'Solicitud rechazada');
    } catch (e) {
      if (context.mounted) mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }
}

/// Hoja para que el auxiliar pida un ajuste sobre un producto.
///
/// Tres casos, con el lenguaje del almacén: «conté y hay tanto», «se dañó
/// tanto», «corregir en tanto». El conteo pide lo que HAY, no la diferencia:
/// pedir la diferencia es una invitación a equivocarse.
class HojaSolicitudAjuste extends ConsumerStatefulWidget {
  const HojaSolicitudAjuste({super.key, required this.productoUuid, required this.nombre, required this.stock});

  final String productoUuid;
  final String nombre;
  final Cantidad stock;

  @override
  ConsumerState<HojaSolicitudAjuste> createState() => _HojaSolicitudAjusteState();
}

class _HojaSolicitudAjusteState extends ConsumerState<HojaSolicitudAjuste> {
  String _tipo = 'CONTEO';
  final _cantidad = TextEditingController();
  final _motivo = TextEditingController();
  bool _guardando = false;

  @override
  void dispose() {
    _cantidad.dispose();
    _motivo.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final valor = Cantidad.tryParse(_cantidad.text.replaceAll(',', '.'));
    if (_tipo != 'AJUSTE' && valor.esNegativa) {
      mostrarMensaje(context, 'La cantidad no puede ser negativa', esError: true);
      return;
    }
    if (_tipo != 'CONTEO' && valor.esCero) {
      mostrarMensaje(context, 'Indica la cantidad', esError: true);
      return;
    }
    setState(() => _guardando = true);
    try {
      await ref.read(ajustesDaoProvider).solicitar(
            productoUuid: widget.productoUuid,
            tipo: _tipo,
            cantidad: _tipo == 'CONTEO' ? null : valor,
            stockContado: _tipo == 'CONTEO' ? valor : null,
            motivo: _motivo.text.trim().isEmpty ? null : _motivo.text.trim(),
          );
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (etiqueta, ayuda) = switch (_tipo) {
      'CONTEO' => ('¿Cuántos hay en el estante?', 'Ahora el sistema dice ${widget.stock.format()}'),
      'MERMA' => ('¿Cuántos se perdieron o dañaron?', 'Vencidos, rotos, robados…'),
      _ => ('Corrección (+ suma, − resta)', 'Ej.: -2 si sobran dos en el sistema'),
    };
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              EncabezadoHoja(titulo: 'Pedir ajuste', subtitulo: widget.nombre),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'CONTEO', label: Text('Conteo'), icon: Icon(Icons.fact_check_outlined)),
                  ButtonSegment(value: 'MERMA', label: Text('Merma'), icon: Icon(Icons.broken_image_outlined)),
                  ButtonSegment(value: 'AJUSTE', label: Text('Ajuste'), icon: Icon(Icons.tune_rounded)),
                ],
                selected: {_tipo},
                onSelectionChanged: (s) => setState(() => _tipo = s.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _cantidad,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(labelText: etiqueta, helperText: ayuda),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _motivo,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Motivo', hintText: 'Lo verá tu gerente al aprobarlo'),
              ),
              const SizedBox(height: 12),
              Text(
                'No cambia el stock todavía: queda pendiente hasta que tu gerente lo apruebe.',
                style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _guardando ? null : _guardar,
                icon: const Icon(Icons.send_rounded),
                label: const Text('Enviar solicitud'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
