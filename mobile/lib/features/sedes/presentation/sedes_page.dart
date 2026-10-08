import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/widgets/encabezado_hoja.dart';
import '../../../core/widgets/estados.dart';
import '../data/gestion_api.dart';

final _sedesAdminProvider = FutureProvider.autoDispose<List<SedeAdmin>>(
  (ref) => ref.watch(gestionApiProvider).sedes(),
);

String _textoError(Object e) => e is ApiException ? e.mensajeUsuario : '$e';

/// Sedes del negocio (Director General). Requiere conexión: el código de la
/// sede es único y prefija la numeración de traslados, así que lo tiene que
/// validar el servidor.
///
/// Una sede nueva llega a los teléfonos con la siguiente sincronización. La
/// principal no se puede desactivar: es a donde va todo lo que llega sin sede
/// (la app vieja, por ejemplo).
class SedesPage extends ConsumerWidget {
  const SedesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sedes = ref.watch(_sedesAdminProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sedes')),
      body: sedes.when(
        loading: () => const SkeletonLista(filas: 3),
        error: (e, _) => EstadoVacio(
          icono: e is ApiException && e.esDeRed ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
          titulo: e is ApiException && e.esDeRed ? 'Sin conexión' : 'No se pudieron cargar las sedes',
          descripcion: _textoError(e),
          textoAccion: 'Reintentar',
          onAccion: () => ref.invalidate(_sedesAdminProvider),
        ),
        data: (lista) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(_sedesAdminProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              for (final (i, s) in lista.indexed)
                EntradaEscalonada(
                  indice: i,
                  child: Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      onTap: () => _formulario(context, ref, sede: s),
                      leading: CircleAvatar(
                        backgroundColor:
                            s.activo ? context.colores.primaryContainer : context.colores.surfaceContainerHighest,
                        child: Text(
                          s.codigo.isEmpty ? '?' : s.codigo.substring(0, s.codigo.length.clamp(1, 3)),
                          style: context.textos.labelMedium,
                        ),
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text(s.nombre, overflow: TextOverflow.ellipsis)),
                          if (s.esPrincipal) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.star_rounded, size: 16, color: context.dominio.advertencia),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        [
                          if (!s.activo) 'Desactivada',
                          ?s.direccion,
                          ?s.telefono,
                        ].join(' · ').ifEmpty('Sin dirección'),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _formulario(context, ref),
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('Nueva sede'),
      ),
    );
  }

  Future<void> _formulario(BuildContext context, WidgetRef ref, {SedeAdmin? sede}) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FormularioSede(sede: sede),
    );
    if (ok == true) {
      ref.invalidate(_sedesAdminProvider);
      ref.read(syncEngineProvider).solicitar();
    }
  }
}

extension on String {
  String ifEmpty(String otro) => isEmpty ? otro : this;
}

class _FormularioSede extends ConsumerStatefulWidget {
  const _FormularioSede({this.sede});

  final SedeAdmin? sede;

  @override
  ConsumerState<_FormularioSede> createState() => _FormularioSedeState();
}

class _FormularioSedeState extends ConsumerState<_FormularioSede> {
  final _form = GlobalKey<FormState>();
  late final _nombre = TextEditingController(text: widget.sede?.nombre ?? '');
  late final _codigo = TextEditingController(text: widget.sede?.codigo ?? '');
  late final _direccion = TextEditingController(text: widget.sede?.direccion ?? '');
  late final _telefono = TextEditingController(text: widget.sede?.telefono ?? '');
  late bool _activo = widget.sede?.activo ?? true;
  bool _guardando = false;

  @override
  void dispose() {
    _nombre.dispose();
    _codigo.dispose();
    _direccion.dispose();
    _telefono.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _guardando = true);
    final api = ref.read(gestionApiProvider);
    try {
      final s = widget.sede;
      if (s == null) {
        await api.crearSede(
          nombre: _nombre.text.trim(),
          codigo: _codigo.text.trim().toUpperCase(),
          direccion: _direccion.text.trim(),
          telefono: _telefono.text.trim(),
        );
      } else {
        await api.actualizarSede(
          s.uuid,
          nombre: _nombre.text.trim() == s.nombre ? null : _nombre.text.trim(),
          codigo: _codigo.text.trim().toUpperCase() == s.codigo ? null : _codigo.text.trim().toUpperCase(),
          direccion: _direccion.text.trim() == (s.direccion ?? '') ? null : _direccion.text.trim(),
          telefono: _telefono.text.trim() == (s.telefono ?? '') ? null : _telefono.text.trim(),
          activo: _activo == s.activo ? null : _activo,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      // Editar sin cambiar nada: no es un error para quien lo hace.
      if (e.codigo == 'SIN_CAMBIOS') {
        Navigator.pop(context, false);
        return;
      }
      mostrarMensaje(context, e.mensajeUsuario, esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final edicion = widget.sede != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                EncabezadoHoja(titulo: edicion ? 'Editar sede' : 'Nueva sede'),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _nombre,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Nombre *', hintText: 'Ej.: Sede Centro'),
                  validator: (v) => (v?.trim().length ?? 0) < 2 ? 'Escribe el nombre' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _codigo,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 10,
                  decoration: const InputDecoration(
                    labelText: 'Código *',
                    hintText: 'Ej.: CEN',
                    helperText: 'De 2 a 10 letras o números. Aparece en los traslados.',
                  ),
                  validator: (v) =>
                      RegExp(r'^[A-Za-z0-9]{2,10}$').hasMatch(v?.trim() ?? '') ? null : 'De 2 a 10 letras o números',
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _direccion,
                  decoration: const InputDecoration(labelText: 'Dirección', helperText: 'Sale en el ticket de esta sede'),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _telefono,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Teléfono'),
                ),
                if (edicion && !widget.sede!.esPrincipal) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _activo,
                    onChanged: (v) => setState(() => _activo = v),
                    title: const Text('Sede activa'),
                    subtitle: Text(
                      _activo ? 'Se puede vender y trasladar' : 'No aparece para vender ni para traslados',
                      style: context.textos.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _guardando ? null : _guardar,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(edicion ? 'Guardar cambios' : 'Crear sede'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
