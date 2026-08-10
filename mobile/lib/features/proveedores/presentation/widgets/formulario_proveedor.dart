import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/estados.dart';

/// Alta y edición de proveedor.
///
/// **Sólo el nombre es obligatorio.** El resto son datos que uno va completando
/// con el tiempo: exigir NIT, dirección y correo para registrar a «Don Jorge,
/// el de las gaseosas» consigue que nadie registre proveedores y que las
/// entradas se queden sin asociar, que es justo lo contrario de lo que se busca.
class FormularioProveedor extends ConsumerStatefulWidget {
  const FormularioProveedor({super.key, this.proveedor});

  final Proveedor? proveedor;

  @override
  ConsumerState<FormularioProveedor> createState() => _FormularioProveedorState();
}

class _FormularioProveedorState extends ConsumerState<FormularioProveedor> {
  final _formulario = GlobalKey<FormState>();

  late final _nombre = TextEditingController(text: widget.proveedor?.nombre ?? '');
  late final _nit = TextEditingController(text: widget.proveedor?.nit ?? '');
  late final _contacto = TextEditingController(text: widget.proveedor?.contacto ?? '');
  late final _telefono = TextEditingController(text: widget.proveedor?.telefono ?? '');
  late final _email = TextEditingController(text: widget.proveedor?.email ?? '');
  late final _direccion = TextEditingController(text: widget.proveedor?.direccion ?? '');
  late final _notas = TextEditingController(text: widget.proveedor?.notas ?? '');

  /// Los campos opcionales empiezan plegados. Un formulario de siete campos
  /// intimida; uno de dos con «Añadir más datos» se rellena.
  late bool _masDatos = _tieneDatosOpcionales;
  bool _guardando = false;

  bool get _esEdicion => widget.proveedor != null;

  bool get _tieneDatosOpcionales {
    final p = widget.proveedor;
    if (p == null) return false;
    return [p.nit, p.contacto, p.email, p.direccion, p.notas]
        .any((v) => v != null && v.trim().isNotEmpty);
  }

  @override
  void dispose() {
    _nombre.dispose();
    _nit.dispose();
    _contacto.dispose();
    _telefono.dispose();
    _email.dispose();
    _direccion.dispose();
    _notas.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!(_formulario.currentState?.validate() ?? false)) return;

    final dao = ref.read(proveedoresDaoProvider);
    final nombre = _nombre.text.trim();

    // Se avisa del duplicado antes de guardar. Dos «Distribuidora ABC» se
    // descubren semanas después, con las compras repartidas entre ambos y sin
    // forma cómoda de unirlas.
    final repetido = await dao.porNombre(nombre, exceptoUuid: widget.proveedor?.uuid);
    if (repetido != null) {
      if (!mounted) return;
      final continuar = await showDialog<bool>(
        context: context,
        builder: (dialogo) => AlertDialog(
          title: const Text('Ya existe uno con ese nombre'),
          content: Text(
            '«${repetido.nombre}» ya está registrado. Tener dos proveedores '
            'iguales reparte las compras entre ambos y descuadra lo que le '
            'llevas comprado a cada uno.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogo, false),
              child: const Text('Revisar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogo, true),
              child: const Text('Guardar igual'),
            ),
          ],
        ),
      );
      if (continuar != true) return;
    }

    if (!mounted) return;
    setState(() => _guardando = true);

    try {
      if (_esEdicion) {
        await dao.actualizar(
          widget.proveedor!.uuid,
          nombre: nombre,
          nit: _nit.text,
          contacto: _contacto.text,
          telefono: _telefono.text,
          email: _email.text,
          direccion: _direccion.text,
          notas: _notas.text,
        );
      } else {
        await dao.crear(
          nombre: nombre,
          nit: _nit.text,
          contacto: _contacto.text,
          telefono: _telefono.text,
          email: _email.text,
          direccion: _direccion.text,
          notas: _notas.text,
        );
      }

      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        mostrarMensaje(context, 'No se pudo guardar: $e', esError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Form(
            key: _formulario,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _esEdicion ? 'Editar proveedor' : 'Nuevo proveedor',
                  style: context.textos.headlineSmall,
                ),
                const SizedBox(height: 20),

                TextFormField(
                  controller: _nombre,
                  autofocus: !_esEdicion,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Nombre *',
                    hintText: 'Distribuidora ABC',
                    prefixIcon: Icon(Icons.storefront_outlined),
                  ),
                  validator: (v) =>
                      (v?.trim().length ?? 0) < 2 ? 'Escribe el nombre' : null,
                ),
                const SizedBox(height: 14),

                TextFormField(
                  controller: _telefono,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Teléfono',
                    helperText: 'Para llamar o escribir por WhatsApp desde la ficha',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),

                if (!_masDatos) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => setState(() => _masDatos = true),
                    icon: const Icon(Icons.expand_more_rounded, size: 18),
                    label: const Text('Añadir más datos'),
                  ),
                ] else ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _contacto,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Persona de contacto',
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _nit,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'NIT',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Correo',
                      prefixIcon: Icon(Icons.alternate_email_rounded),
                    ),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return null;
                      // El servidor rechaza un correo mal formado y la
                      // operación acabaría en «Elementos con problema», media
                      // hora después y sin que nadie relacione una cosa con la
                      // otra. Mejor avisar aquí.
                      return (t.contains('@') && t.contains('.'))
                          ? null
                          : 'Correo no válido';
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _direccion,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Dirección',
                      prefixIcon: Icon(Icons.place_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _notas,
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Notas',
                      hintText: 'Días de entrega, condiciones de pago…',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],

                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _guardando ? null : _guardar,
                  icon: _guardando
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_esEdicion ? 'Guardar cambios' : 'Añadir proveedor'),
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
