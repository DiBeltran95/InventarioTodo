import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/gestion_api.dart';
import 'sedes_providers.dart';

final _datosProvider = FutureProvider.autoDispose<({List<SolicitudCambioSede> mias, List<SedeAdmin> sedes})>(
  (ref) async {
    final api = ref.watch(gestionApiProvider);
    final yo = ref.watch(sesionProvider).value?.usuarioUuid;
    final cambios = await api.cambiosDeSede();
    final sedes = await api.todasLasSedes();
    return (mias: cambios.where((c) => c.empleadoUuid == yo).toList(), sedes: sedes);
  },
);

String _textoError(Object e) => e is ApiException ? e.mensajeUsuario : '$e';

/// El vendedor o auxiliar pide pasar a otra sede.
///
/// Lo acepta o rechaza el gerente de la sede a la que quiere ir (o el
/// director). Al resolverse, la solicitud se borra: si se aceptó, lo que queda
/// es el cambio mismo, registrado en la auditoría. Hay una sola solicitud
/// abierta por persona.
class CambioSedePage extends ConsumerStatefulWidget {
  const CambioSedePage({super.key});

  @override
  ConsumerState<CambioSedePage> createState() => _CambioSedePageState();
}

class _CambioSedePageState extends ConsumerState<CambioSedePage> {
  String? _destino;
  final _motivo = TextEditingController();
  bool _enviando = false;

  @override
  void dispose() {
    _motivo.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    final destino = _destino;
    if (destino == null) return;
    setState(() => _enviando = true);
    try {
      await ref.read(gestionApiProvider).solicitarCambioSede(destino, motivo: _motivo.text.trim());
      if (!mounted) return;
      mostrarMensaje(context, 'Solicitud enviada al gerente de esa sede', esExito: true);
      setState(() => _enviando = false);
      ref.invalidate(_datosProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enviando = false);
      mostrarMensaje(context, _textoError(e), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final datos = ref.watch(_datosProvider);
    final actuales = ref.watch(misSedesProvider).value ?? const [];
    final actual = actuales.isEmpty ? null : actuales.first;

    return Scaffold(
      appBar: AppBar(title: const Text('Cambio de sede')),
      body: datos.when(
        loading: () => const SkeletonLista(filas: 3),
        error: (e, _) => EstadoVacio(
          icono: e is ApiException && e.esDeRed ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
          titulo: e is ApiException && e.esDeRed ? 'Sin conexión' : 'No se pudo cargar',
          descripcion: e is ApiException && e.esDeRed
              ? 'Pedir un cambio de sede necesita conexión.'
              : _textoError(e),
          textoAccion: 'Reintentar',
          onAccion: () => ref.invalidate(_datosProvider),
        ),
        data: (d) {
          final abierta = d.mias.isEmpty ? null : d.mias.first;
          final opciones = d.sedes.where((s) => s.uuid != actual?.uuid).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.storefront_outlined),
                  title: const Text('Trabajas en'),
                  subtitle: Text(actual?.nombre ?? 'Sin sede', style: context.textos.titleMedium),
                ),
              ),
              const SizedBox(height: 16),
              if (abierta != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: context.dominio.advertenciaContenedor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.hourglass_top_rounded, color: context.dominio.advertencia),
                          const SizedBox(width: 8),
                          Text(
                            'Esperando respuesta',
                            style: context.textos.titleMedium?.copyWith(color: context.dominio.advertencia),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('Pediste pasar a ${abierta.destino.nombre} ${Fechas.relativo(abierta.creada)}.'),
                      if (abierta.motivo != null) Text('«${abierta.motivo}»', style: context.textos.bodySmall),
                      const SizedBox(height: 6),
                      Text(
                        'La resuelve el gerente de ${abierta.destino.nombre}. Cuando la acepte, tu teléfono '
                        'pasa a esa sede en la siguiente sincronización.',
                        style: context.textos.bodySmall,
                      ),
                    ],
                  ),
                )
              else if (opciones.isEmpty)
                const EstadoVacio(
                  icono: Icons.store_mall_directory_outlined,
                  titulo: 'No hay otras sedes',
                  descripcion: 'Cuando el negocio abra otra sede, podrás pedir el cambio aquí.',
                )
              else ...[
                Text('¿A qué sede quieres pasar?', style: context.textos.titleMedium),
                const SizedBox(height: 8),
                RadioGroup<String>(
                  groupValue: _destino,
                  onChanged: (v) => setState(() => _destino = v),
                  child: Column(
                    children: [
                      for (final s in opciones)
                        RadioListTile<String>(value: s.uuid, title: Text(s.nombre), contentPadding: EdgeInsets.zero),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _motivo,
                  maxLength: 200,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Motivo', hintText: 'Ej.: me queda más cerca de casa'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _enviando || _destino == null ? null : _enviar,
                  icon: const Icon(Icons.send_rounded),
                  label: const Text('Enviar solicitud'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
