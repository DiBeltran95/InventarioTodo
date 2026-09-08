import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/datos_negocio.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/estados.dart';

/// Datos de la empresa.
///
/// Es lo que encabeza cada ticket: sin esto el comprobante sale a nombre de
/// «Mi Negocio», que es el valor con el que arranca el servidor, y no sirve
/// como soporte de una compra.
///
/// **Se guarda contra la API, no por la cola de salida.** La identidad del
/// negocio es una sola para todos los dispositivos: si dos teléfonos la
/// editaran sin conexión, la cola aplicaría la última en llegar y el otro
/// perdería el cambio sin enterarse. Por eso esta pantalla pide conexión —una
/// vez, para un dato que se toca una vez— y luego baja sola a los demás
/// dispositivos en la sincronización.
class NegocioPage extends ConsumerStatefulWidget {
  const NegocioPage({super.key});

  @override
  ConsumerState<NegocioPage> createState() => _NegocioPageState();
}

class _NegocioPageState extends ConsumerState<NegocioPage> {
  final _formulario = GlobalKey<FormState>();

  final _nombre = TextEditingController();
  final _nit = TextEditingController();
  final _direccion = TextEditingController();
  final _telefono = TextEditingController();
  final _pie = TextEditingController();

  /// Lo que había al abrir, para no reescribir claves que nadie tocó.
  Map<String, String> _original = const {};
  bool _cargado = false;
  bool _guardando = false;

  @override
  void dispose() {
    _nombre.dispose();
    _nit.dispose();
    _direccion.dispose();
    _telefono.dispose();
    _pie.dispose();
    super.dispose();
  }

  /// Rellena los campos la primera vez que llega la configuración.
  ///
  /// Sólo la primera: si el pull trajera cambios mientras se escribe, volver a
  /// rellenar borraría lo tecleado a media frase.
  void _sembrar(Map<String, String> config) {
    if (_cargado) return;
    _cargado = true;
    _original = config;
    _nombre.text = config[ClavesNegocio.nombre] ?? '';
    _nit.text = config[ClavesNegocio.nit] ?? '';
    _direccion.text = config[ClavesNegocio.direccion] ?? '';
    _telefono.text = config[ClavesNegocio.telefono] ?? '';
    _pie.text = config[ClavesNegocio.pieTicket] ?? '';
  }

  Map<String, String> get _actual => {
        ClavesNegocio.nombre: _nombre.text.trim(),
        ClavesNegocio.nit: _nit.text.trim(),
        ClavesNegocio.direccion: _direccion.text.trim(),
        ClavesNegocio.telefono: _telefono.text.trim(),
        ClavesNegocio.pieTicket: _pie.text.trim(),
      };

  Map<String, String> get _cambios => {
        for (final e in _actual.entries)
          if ((_original[e.key] ?? '') != e.value) e.key: e.value,
      };

  Future<void> _guardar() async {
    if (!(_formulario.currentState?.validate() ?? false)) return;

    final cambios = _cambios;
    if (cambios.isEmpty) {
      mostrarMensaje(context, 'No hay nada que cambiar');
      return;
    }

    setState(() => _guardando = true);
    FocusScope.of(context).unfocus();

    try {
      await ref.read(apiClientProvider).put(
            '/configuracion',
            cuerpo: {'valores': cambios},
          );

      // Se adelanta el efecto en ESTE teléfono para que el ticket salga bien
      // ya mismo, sin esperar a la siguiente sincronización.
      final dao = ref.read(syncDaoProvider);
      for (final e in cambios.entries) {
        await dao.guardarConfigLocal(e.key, e.value);
      }

      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();

      if (!mounted) return;
      setState(() {
        _original = _actual;
        _guardando = false;
      });
      mostrarMensaje(context, 'Datos del negocio actualizados', esExito: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(
        context,
        'No se pudo guardar. Estos datos necesitan conexión: $e',
        esError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configuracionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Datos del negocio')),
      body: config.when(
        loading: () => const SkeletonLista(filas: 5, alturaFila: 72),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (valores) {
          _sembrar(valores);

          return Form(
            key: _formulario,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _VistaPreviaTicket(
                  nombre: _nombre.text.trim(),
                  nit: _nit.text.trim(),
                  direccion: _direccion.text.trim(),
                  telefono: _telefono.text.trim(),
                  pie: _pie.text.trim(),
                ),
                const SizedBox(height: 20),

                TextFormField(
                  controller: _nombre,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Nombre del negocio *',
                    helperText: 'Encabeza el ticket, en grande',
                    prefixIcon: Icon(Icons.storefront_outlined),
                  ),
                  validator: (v) =>
                      (v?.trim().length ?? 0) < 2 ? 'Escribe el nombre' : null,
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: _nit,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'NIT o identificación',
                    helperText: 'Va bajo el nombre. Déjalo vacío si no aplica',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: _direccion,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Dirección',
                    prefixIcon: Icon(Icons.place_outlined),
                  ),
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: _telefono,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Teléfono',
                    helperText: 'Por donde te reclaman una garantía',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: _pie,
                  maxLines: 2,
                  maxLength: 120,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Mensaje final del ticket',
                    hintText: '¡Gracias por su compra!',
                    helperText: 'Horarios, redes, política de cambios…',
                    alignLabelWithHint: true,
                  ),
                ),

                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _guardando ? null : _guardar,
                  icon: _guardando
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: const Text('Guardar'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                ),
                const SizedBox(height: 12),
                Text(
                  'Estos datos son del negocio, no de este teléfono: al '
                  'guardarlos bajan al resto de dispositivos en la siguiente '
                  'sincronización. Por eso hace falta conexión para cambiarlos.',
                  textAlign: TextAlign.center,
                  style: context.textos.bodySmall?.copyWith(
                    color: context.colores.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Cómo quedará el encabezado del ticket.
///
/// Se ve mientras se escribe porque el resultado es un papel de 80 mm: nadie
/// tiene claro cuánto cabe en esa anchura hasta que lo ve, y descubrirlo tras
/// imprimir cien tickets torcidos es caro.
class _VistaPreviaTicket extends StatelessWidget {
  const _VistaPreviaTicket({
    required this.nombre,
    required this.nit,
    required this.direccion,
    required this.telefono,
    required this.pie,
  });

  final String nombre;
  final String nit;
  final String direccion;
  final String telefono;
  final String pie;

  @override
  Widget build(BuildContext context) {
    // Monoespaciada y estrecha: es lo más parecido a una térmica que se puede
    // enseñar en pantalla sin generar el PDF.
    const fuente = TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4);
    final separador = '- ' * 16;

    return Center(
      child: Container(
        width: 220,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: context.colores.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.colores.outlineVariant),
        ),
        child: DefaultTextStyle(
          style: fuente.copyWith(color: context.colores.onSurface),
          textAlign: TextAlign.center,
          child: Column(
            children: [
              Text(
                nombre.isEmpty ? 'MI NEGOCIO' : nombre.toUpperCase(),
                style: fuente.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: context.colores.onSurface,
                ),
              ),
              if (nit.isNotEmpty) Text('NIT $nit'),
              if (direccion.isNotEmpty) Text(direccion),
              if (telefono.isNotEmpty) Text(telefono),
              const SizedBox(height: 6),
              Text(separador, maxLines: 1),
              const SizedBox(height: 6),
              const Text('Ticket 0001'),
              const Text(r'TOTAL        $ 0'),
              const SizedBox(height: 6),
              Text(separador, maxLines: 1),
              const SizedBox(height: 6),
              Text(pie.isEmpty ? '¡Gracias por su compra!' : pie),
            ],
          ),
        ),
      ),
    );
  }
}
