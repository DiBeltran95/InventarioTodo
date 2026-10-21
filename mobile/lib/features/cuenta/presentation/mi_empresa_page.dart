import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/plan.dart';
import 'plan_ui.dart';
import 'terminos.dart';

/// «Mi empresa»: plan y uso, apps habilitadas, datos de la empresa y la
/// eliminación de la cuenta (la exige Google Play dentro de la app).
///
/// Sin red muestra el último plan conocido: los medidores siguen siendo útiles
/// para saber si cabe otro producto antes de intentarlo.
class MiEmpresaPage extends ConsumerWidget {
  const MiEmpresaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empresa = ref.watch(empresaProvider);
    final planGuardado = ref.watch(planProvider);
    final esDirector = ref.watch(esDirectorProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mi empresa')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(empresaProvider.future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            ...empresa.when(
              data: (e) => [
                _Encabezado(empresa: e, editable: esDirector),
                const SizedBox(height: 16),
                if (e.plan != null) TarjetaPlan(plan: e.plan!),
                const SizedBox(height: 16),
                _Aplicativos(aplicativos: e.aplicativos),
              ],
              loading: () => const [SkeletonBloque(alto: 120), SizedBox(height: 16), SkeletonBloque(alto: 280)],
              error: (error, _) => [
                if (planGuardado != null) ...[
                  _AvisoSinRed(error: error, alReintentar: () => ref.invalidate(empresaProvider)),
                  const SizedBox(height: 16),
                  TarjetaPlan(plan: planGuardado),
                ] else
                  EstadoError(
                    mensaje: error is ApiException ? error.mensajeUsuario : 'No se pudo cargar la empresa',
                    onReintentar: () => ref.invalidate(empresaProvider),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.policy_outlined),
                    title: const Text('Términos y tratamiento de datos'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => mostrarTerminos(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.delete_forever_outlined, color: context.dominio.peligro),
                    title: Text(
                      esDirector ? 'Eliminar empresa' : 'Eliminar mi cuenta',
                      style: TextStyle(color: context.dominio.peligro),
                    ),
                    subtitle: Text(
                      esDirector
                          ? 'Borra la empresa, sus sedes, productos y cuentas en todas las apps'
                          : 'Tu cuenta deja de existir en todas las apps de la empresa',
                    ),
                    onTap: () => _eliminar(context, ref, esDirector, empresa.value?.nombre),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _eliminar(BuildContext context, WidgetRef ref, bool esDirector, String? nombreEmpresa) async {
    if (esDirector && nombreEmpresa == null) {
      mostrarMensaje(context, 'Necesitas conexión para eliminar la empresa', esError: true);
      return;
    }
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (_) => _DialogoEliminar(esDirector: esDirector, nombreEmpresa: nombreEmpresa),
    );
    if (confirmado == true) {
      await PlanLocal.olvidar();
      await ref.read(sesionProvider.notifier).cerrarSesion(borrarDatos: true);
    }
  }
}

class _Encabezado extends ConsumerWidget {
  const _Encabezado({required this.empresa, required this.editable});
  final EmpresaInfo empresa;
  final bool editable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colores;
    final detalles = [
      if ((empresa.nit ?? '').isNotEmpty) 'NIT ${empresa.nit}',
      if ((empresa.telefono ?? '').isNotEmpty) empresa.telefono!,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: c.primaryContainer,
              child: Icon(Icons.storefront_rounded, color: c.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(empresa.nombre, style: context.textos.titleLarge),
                  if (detalles.isNotEmpty)
                    Text(detalles.join(' · '), style: context.textos.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
                ],
              ),
            ),
            if (editable)
              IconButton(
                tooltip: 'Editar datos de la empresa',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _editar(context, ref),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editar(BuildContext context, WidgetRef ref) async {
    final guardado = await showDialog<bool>(
      context: context,
      builder: (_) => _DialogoEditar(empresa: empresa),
    );
    if (guardado == true) {
      ref.invalidate(empresaProvider);
      if (context.mounted) mostrarMensaje(context, 'Datos de la empresa guardados', esExito: true);
    }
  }
}

class _Aplicativos extends StatelessWidget {
  const _Aplicativos({required this.aplicativos});
  final List<String> aplicativos;

  static const _todos = [
    ('INVENTARIO', 'Ventario', Icons.inventory_2_outlined),
    ('ASISTENCIA', 'Presente', Icons.face_retouching_natural_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text('Apps de la empresa', style: context.textos.titleMedium),
            ),
            for (final (codigo, nombre, icono) in _todos)
              ListTile(
                leading: Icon(icono),
                title: Text(nombre),
                subtitle: Text(
                  aplicativos.contains(codigo)
                      ? 'Habilitada: tu equipo entra con el mismo correo'
                      : 'No habilitada. El director puede solicitarla al equipo de la plataforma',
                ),
                trailing: Chip(
                  label: Text(aplicativos.contains(codigo) ? 'Activa' : 'Inactiva'),
                  backgroundColor: aplicativos.contains(codigo) ? d.exitoContenedor : context.colores.surfaceContainerHighest,
                  labelStyle: TextStyle(
                    color: aplicativos.contains(codigo) ? d.exito : context.colores.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                  side: BorderSide.none,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AvisoSinRed extends StatelessWidget {
  const _AvisoSinRed({required this.error, required this.alReintentar});
  final Object error;
  final VoidCallback alReintentar;

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: d.advertenciaContenedor, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 20, color: d.advertencia),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Sin conexión: este es el último plan conocido.',
              style: context.textos.bodySmall?.copyWith(color: d.advertencia),
            ),
          ),
          TextButton(onPressed: alReintentar, child: const Text('Reintentar')),
        ],
      ),
    );
  }
}

class _DialogoEditar extends ConsumerStatefulWidget {
  const _DialogoEditar({required this.empresa});
  final EmpresaInfo empresa;

  @override
  ConsumerState<_DialogoEditar> createState() => _DialogoEditarState();
}

class _DialogoEditarState extends ConsumerState<_DialogoEditar> {
  final _formulario = GlobalKey<FormState>();
  late final _nombre = TextEditingController(text: widget.empresa.nombre);
  late final _nit = TextEditingController(text: widget.empresa.nit ?? '');
  late final _telefono = TextEditingController(text: widget.empresa.telefono ?? '');
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombre.dispose();
    _nit.dispose();
    _telefono.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!_formulario.currentState!.validate()) return;
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).editarEmpresa(
            nombre: _nombre.text.trim(),
            nit: _nit.text.trim(),
            telefono: _telefono.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.mensajeUsuario : '$e');
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Datos de la empresa'),
      content: Form(
        key: _formulario,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nombre,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre'),
                validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe el nombre' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(controller: _nit, decoration: const InputDecoration(labelText: 'NIT o documento')),
              const SizedBox(height: 12),
              TextFormField(
                controller: _telefono,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Teléfono'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: context.dominio.peligro)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _guardando ? null : () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _guardando ? null : _guardar, child: const Text('Guardar')),
      ],
    );
  }
}

/// Confirmación fuerte: contraseña y, para la empresa, escribir su nombre.
/// Lo irreversible no debe poder hacerse con un toque accidental.
class _DialogoEliminar extends ConsumerStatefulWidget {
  const _DialogoEliminar({required this.esDirector, this.nombreEmpresa});
  final bool esDirector;
  final String? nombreEmpresa;

  @override
  ConsumerState<_DialogoEliminar> createState() => _DialogoEliminarState();
}

class _DialogoEliminarState extends ConsumerState<_DialogoEliminar> {
  final _formulario = GlobalKey<FormState>();
  final _clave = TextEditingController();
  final _confirmacion = TextEditingController();
  bool _eliminando = false;
  String? _error;

  @override
  void dispose() {
    _clave.dispose();
    _confirmacion.dispose();
    super.dispose();
  }

  Future<void> _eliminar() async {
    if (!_formulario.currentState!.validate()) return;
    setState(() {
      _eliminando = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).eliminarCuenta(
            password: _clave.text,
            confirmacion: widget.esDirector ? _confirmacion.text.trim() : null,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.mensajeUsuario : '$e');
    } finally {
      if (mounted) setState(() => _eliminando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: d.peligro),
      title: Text(widget.esDirector ? '¿Eliminar la empresa?' : '¿Eliminar tu cuenta?'),
      content: Form(
        key: _formulario,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.esDirector
                    ? 'Se borrarán «${widget.nombreEmpresa}», sus sedes, productos, ventas y todas las cuentas, '
                        'en Ventario y en Presente. No se puede deshacer.'
                    : 'Ya no podrás entrar a ninguna app de la empresa. Las ventas que registraste se conservan '
                        'para la empresa. No se puede deshacer.',
              ),
              const SizedBox(height: 16),
              if (widget.esDirector) ...[
                TextFormField(
                  controller: _confirmacion,
                  decoration: const InputDecoration(labelText: 'Escribe el nombre de la empresa'),
                  validator: (v) => (v ?? '').trim() == widget.nombreEmpresa ? null : 'El nombre no coincide',
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _clave,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'Tu contraseña'),
                validator: (v) => (v ?? '').isEmpty ? 'Escribe tu contraseña' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: d.peligro)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _eliminando ? null : () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: d.peligro, foregroundColor: Colors.white),
          onPressed: _eliminando ? null : _eliminar,
          child: _eliminando
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
              : const Text('Eliminar'),
        ),
      ],
    );
  }
}
