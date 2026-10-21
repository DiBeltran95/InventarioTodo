import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/widgets/encabezado_hoja.dart';
import '../../../core/widgets/estados.dart';
import '../../cuenta/domain/plan.dart';
import '../../cuenta/presentation/plan_ui.dart';
import '../data/gestion_api.dart';

final _sedesAdminProvider = FutureProvider.autoDispose<List<SedeAdmin>>(
  (ref) => ref.watch(gestionApiProvider).sedesParaAdministrar(),
);

String _textoError(Object e) => e is ApiException ? e.mensajeUsuario : '$e';

/// Sedes del negocio (Director General). Requiere conexión: el código de la
/// sede es único y prefija la numeración de traslados, así que lo tiene que
/// validar el servidor.
///
/// Una sede nueva llega a los teléfonos con la siguiente sincronización. La
/// principal no se puede desactivar: es a donde va todo lo que llega sin sede
/// (la app vieja, por ejemplo).
///
/// Las sedes son de la empresa (compartidas con Presente), pero Ventario solo
/// trabaja en las que se eligen para él, hasta el límite de SU plan. Elegir una
/// no se puede deshacer. Crear una sede aquí la elige para Ventario.
class SedesPage extends ConsumerWidget {
  const SedesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sedes = ref.watch(_sedesAdminProvider);
    final plan = ref.watch(planProvider);

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
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Las sedes se comparten con Presente, pero cada app usa solo las que eliges para ella, '
                        'hasta el límite de su plan.',
                        style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
                      ),
                      if (plan != null && !plan.sedes.ilimitado) ...[
                        const SizedBox(height: 12),
                        MedidorUso(recurso: RecursoLimitado.sedes, uso: plan.sedes),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
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
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            [
                              if (!s.activo) 'Desactivada',
                              ?s.direccion,
                              ?s.telefono,
                            ].join(' · ').ifEmpty('Sin dirección'),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if (s.elegida)
                                _Uso(texto: 'En Ventario', color: context.dominio.exito, fondo: context.dominio.exitoContenedor),
                              if (s.elegidaPresente ?? false)
                                _Uso(
                                  texto: 'En Presente',
                                  color: context.colores.onSurfaceVariant,
                                  fondo: context.colores.surfaceContainerHighest,
                                ),
                            ],
                          ),
                        ],
                      ),
                      isThreeLine: true,
                      trailing: !s.elegida && s.activo
                          ? TextButton(onPressed: () => _elegir(context, ref, s, plan), child: const Text('Usar en Ventario'))
                          : const Icon(Icons.chevron_right_rounded),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          if (await hayCupo(context, ref, RecursoLimitado.sedes) && context.mounted) {
            await _formulario(context, ref);
          }
        },
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('Nueva sede'),
      ),
    );
  }

  /// Confirma (es irrevocable) y elige la sede para Ventario.
  Future<void> _elegir(BuildContext context, WidgetRef ref, SedeAdmin sede, PlanEmpresa? plan) async {
    final sedes = plan?.sedes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: Icon(Icons.storefront_outlined, color: d.colores.primary),
        title: Text('¿Usar ${sede.nombre} en Ventario?'),
        content: Text(
          [
            'Ventario empezará a trabajar en esta sede: ventas, stock, traslados y personal.',
            'Esta elección no se puede deshacer.',
            if (sedes != null && sedes.maximo != null)
              'Tu plan de Ventario permite ${sedes.maximo} sede${sedes.maximo == 1 ? '' : 's'} y ya usas ${sedes.usados}.',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sí, usarla')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(gestionApiProvider).elegirSede(sede.uuid);
      ref.invalidate(_sedesAdminProvider);
      ref.invalidate(empresaProvider);
      ref.read(syncEngineProvider).solicitar();
      if (context.mounted) mostrarMensaje(context, '${sede.nombre} ya está en Ventario', esExito: true);
    } catch (e) {
      if (!context.mounted) return;
      if (await manejarLimite(context, e)) return;
      if (context.mounted) mostrarMensaje(context, _textoError(e), esError: true);
    }
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

class _Uso extends StatelessWidget {
  const _Uso({required this.texto, required this.color, required this.fondo});
  final String texto;
  final Color color;
  final Color fondo;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(999)),
        child: Text(texto, style: context.textos.labelSmall?.copyWith(color: color)),
      );
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
      if (await manejarLimite(context, e)) return;
      if (!mounted) return;
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
