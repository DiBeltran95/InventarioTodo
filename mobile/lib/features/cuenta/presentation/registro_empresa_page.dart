import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/presentation/auth_providers.dart';
import 'terminos.dart';

/// Registro de una empresa nueva en tres pasos: tú, tu empresa y tu primera
/// sede. Al terminar, la sesión queda abierta como director y la empresa en
/// el plan Gratis; el router lleva solo al inicio al ver la sesión (es una
/// ruta pública: con sesión abierta redirige).
class RegistroEmpresaPage extends ConsumerStatefulWidget {
  const RegistroEmpresaPage({super.key});

  @override
  ConsumerState<RegistroEmpresaPage> createState() => _RegistroEmpresaPageState();
}

class _RegistroEmpresaPageState extends ConsumerState<RegistroEmpresaPage> {
  static const _pasos = ['Tú', 'Tu empresa', 'Primera sede'];

  final _formularios = List.generate(3, (_) => GlobalKey<FormState>());
  final _nombre = TextEditingController();
  final _email = TextEditingController();
  final _clave = TextEditingController();
  final _empresa = TextEditingController();
  final _nit = TextEditingController();
  final _telefono = TextEditingController();
  final _sede = TextEditingController(text: 'Sede principal');

  int _paso = 0;
  bool _ocultar = true;
  bool _acepta = false;
  bool _enviando = false;
  String? _error;
  String? _errorEmail;

  @override
  void dispose() {
    for (final c in [_nombre, _email, _clave, _empresa, _nit, _telefono, _sede]) {
      c.dispose();
    }
    super.dispose();
  }

  void _siguiente() {
    setState(() => _error = null);
    if (!_formularios[_paso].currentState!.validate()) return;
    if (_paso < 2) {
      setState(() => _paso++);
    } else {
      _crear();
    }
  }

  void _atras() {
    if (_paso == 0) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(Rutas.login);
      }
    } else {
      setState(() {
        _paso--;
        _error = null;
      });
    }
  }

  Future<void> _crear() async {
    if (!_acepta) {
      setState(() => _error = 'Para crear la empresa acepta los términos y el tratamiento de datos.');
      return;
    }
    setState(() {
      _enviando = true;
      _error = null;
    });
    try {
      final r = await ref.read(sesionProvider.notifier).registrarEmpresa(
            empresa: _empresa.text.trim(),
            nit: _nit.text.trim().isEmpty ? null : _nit.text.trim(),
            telefono: _telefono.text.trim().isEmpty ? null : _telefono.text.trim(),
            sede: _sede.text.trim(),
            nombre: _nombre.text.trim(),
            email: _email.text.trim(),
            password: _clave.text,
          );
      if (!mounted) return;
      if (r.exito) {
        // La sesión ya existe: el router redirige al inicio.
        TextInput.finishAutofillContext();
        return;
      }
      // El correo repetido se corrige en el paso 1, junto al campo.
      if (r.codigo == 'EMAIL_EN_USO' || r.codigo == 'DUPLICADO') {
        setState(() {
          _paso = 0;
          _errorEmail = r.mensajeError;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _formularios[0].currentState?.validate());
      } else {
        setState(() => _error = r.mensajeError);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'No se pudo crear la empresa: $e');
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _paso == 0 && !_enviando,
      onPopInvokedWithResult: (salio, _) {
        if (!salio && !_enviando) _atras();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: _paso == 0 ? 'Cancelar' : 'Paso anterior',
            icon: Icon(_paso == 0 ? Icons.close_rounded : Icons.arrow_back_rounded),
            onPressed: _enviando ? null : _atras,
          ),
          title: const Text('Crear cuenta de empresa'),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Progreso(paso: _paso, nombres: _pasos),
                    const SizedBox(height: 24),
                    AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 260),
                      child: KeyedSubtree(key: ValueKey(_paso), child: _contenido()),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      _Aviso(texto: _error!),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _enviando ? null : _siguiente,
                      icon: _enviando
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                          : Icon(_paso < 2 ? Icons.arrow_forward_rounded : Icons.rocket_launch_outlined),
                      label: Text(_paso < 2 ? 'Continuar' : 'Crear empresa'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _contenido() => switch (_paso) {
        0 => _pasoTu(),
        1 => _pasoEmpresa(),
        _ => _pasoSede(),
      };

  Widget _encabezado(String titulo, String detalle) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(titulo, style: context.textos.headlineSmall),
          const SizedBox(height: 4),
          Text(detalle, style: context.textos.bodyMedium?.copyWith(color: context.colores.onSurfaceVariant)),
          const SizedBox(height: 20),
        ],
      );

  Widget _pasoTu() => Form(
        key: _formularios[0],
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _encabezado('Tus datos', 'Serás el director de la empresa en las apps de la plataforma.'),
              TextFormField(
                controller: _nombre,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Tu nombre completo', prefixIcon: Icon(Icons.badge_outlined)),
                validator: (v) => (v ?? '').trim().length < 3 ? 'Escribe tu nombre completo' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.email, AutofillHints.newUsername],
                textInputAction: TextInputAction.next,
                onChanged: (_) {
                  if (_errorEmail != null) setState(() => _errorEmail = null);
                },
                decoration: const InputDecoration(
                  labelText: 'Correo',
                  helperText: 'Con él entrarás a Ventario y a Presente',
                  prefixIcon: Icon(Icons.alternate_email_rounded),
                ),
                validator: (v) {
                  if (_errorEmail != null) return _errorEmail;
                  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Escribe un correo válido';
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _clave,
                obscureText: _ocultar,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onFieldSubmitted: (_) => _siguiente(),
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    tooltip: _ocultar ? 'Mostrar contraseña' : 'Ocultar contraseña',
                    onPressed: () => setState(() => _ocultar = !_ocultar),
                    icon: Icon(_ocultar ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  ),
                ),
                validator: (v) => (v ?? '').length < 8 ? 'Usa al menos 8 caracteres' : null,
              ),
              const SizedBox(height: 8),
              FortalezaClave(clave: _clave.text),
            ],
          ),
        ),
      );

  Widget _pasoEmpresa() => Form(
        key: _formularios[1],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _encabezado('Tu empresa', 'Así aparecerá en el ticket, en los reportes y en las dos apps.'),
            TextFormField(
              controller: _empresa,
              textCapitalization: TextCapitalization.words,
              autofillHints: const [AutofillHints.organizationName],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Nombre de la empresa', prefixIcon: Icon(Icons.storefront_outlined)),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Escribe el nombre de la empresa' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _nit,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'NIT o documento (opcional)', prefixIcon: Icon(Icons.numbers_rounded)),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _telefono,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _siguiente(),
              decoration: const InputDecoration(labelText: 'Teléfono (opcional)', prefixIcon: Icon(Icons.call_outlined)),
            ),
          ],
        ),
      );

  Widget _pasoSede() => Form(
        key: _formularios[2],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _encabezado('Tu primera sede', 'El local donde vendes. Después podrás agregar más según tu plan.'),
            TextFormField(
              controller: _sede,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nombre de la sede', prefixIcon: Icon(Icons.place_outlined)),
              validator: (v) => (v ?? '').trim().length < 2 ? 'Ponle un nombre a la sede' : null,
            ),
            const SizedBox(height: 20),
            const ResumenPlanGratis(),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _acepta,
              onChanged: _enviando ? null : (v) => setState(() => _acepta = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Acepto los términos de uso y el tratamiento de datos personales (Ley 1581 de 2012)'),
              subtitle: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 40)),
                  onPressed: () => mostrarTerminos(context),
                  child: const Text('Leer términos y política de datos'),
                ),
              ),
            ),
          ],
        ),
      );
}

/// Lo que incluye el plan Gratis, para decidir con información antes de crear.
class ResumenPlanGratis extends StatelessWidget {
  const ResumenPlanGratis({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colores;
    Widget item(IconData icono, String cifra, String texto) => Expanded(
          child: Semantics(
            label: '$cifra $texto',
            excludeSemantics: true,
            child: Column(
              children: [
                Icon(icono, color: c.primary),
                const SizedBox(height: 4),
                Text(cifra, style: context.textos.headlineSmall),
                Text(texto, style: context.textos.bodySmall?.copyWith(color: c.onSurfaceVariant)),
              ],
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Plan Gratis · sin costo', style: context.textos.titleSmall)),
              Icon(Icons.verified_outlined, size: 18, color: c.primary),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              item(Icons.place_outlined, '1', 'sede'),
              item(Icons.groups_outlined, '3', 'personas'),
              item(Icons.inventory_2_outlined, '3', 'productos'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Las personas incluyen al director y a los gerentes. Puedes usarlo sin límite de tiempo.',
            style: context.textos.bodySmall?.copyWith(color: c.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Indicador de fortaleza: orienta sin imponer reglas de símbolos. Texto y
/// barra, nunca solo color.
class FortalezaClave extends StatelessWidget {
  const FortalezaClave({super.key, required this.clave});
  final String clave;

  int get _puntos {
    if (clave.isEmpty) return 0;
    var p = 0;
    if (clave.length >= 8) p++;
    if (clave.length >= 12) p++;
    if (RegExp('[A-Z]').hasMatch(clave) && RegExp('[a-z]').hasMatch(clave)) p++;
    if (RegExp(r'\d').hasMatch(clave) && RegExp('[^A-Za-z0-9]').hasMatch(clave)) p++;
    return p;
  }

  @override
  Widget build(BuildContext context) {
    if (clave.isEmpty) return const SizedBox.shrink();
    final d = context.dominio;
    final p = _puntos;
    final (texto, color) = switch (p) {
      <= 1 => ('Débil: usa al menos 8 caracteres', d.peligro),
      2 => ('Aceptable', d.advertencia),
      3 => ('Buena', context.colores.primary),
      _ => ('Muy buena', d.exito),
    };
    return Semantics(
      label: 'Fortaleza de la contraseña: $texto',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: i < p ? color : context.colores.outlineVariant,
                ),
              ),
            ),
            if (i < 3) const SizedBox(width: 4),
          ],
          const SizedBox(width: 12),
          Text(texto, style: context.textos.bodySmall?.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _Progreso extends StatelessWidget {
  const _Progreso({required this.paso, required this.nombres});
  final int paso;
  final List<String> nombres;

  @override
  Widget build(BuildContext context) {
    final c = context.colores;
    return Semantics(
      label: 'Paso ${paso + 1} de ${nombres.length}: ${nombres[paso]}',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 0; i < nombres.length; i++) ...[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedContainer(
                    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 260),
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      color: i <= paso ? c.primary : c.outlineVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${i + 1}. ${nombres[i]}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textos.labelMedium?.copyWith(color: i <= paso ? c.primary : c.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (i < nombres.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso({required this.texto});
  final String texto;

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: d.peligroContenedor, borderRadius: BorderRadius.circular(14)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 20, color: d.peligro),
            const SizedBox(width: 10),
            Expanded(child: Text(texto, style: context.textos.bodySmall?.copyWith(color: d.peligro))),
          ],
        ),
      ),
    );
  }
}
