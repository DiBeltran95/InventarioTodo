import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/presentation/auth_providers.dart';
import 'registro_empresa_page.dart' show FortalezaClave;

/// Recuperar la contraseña en dos pasos: pedir un código al correo y luego
/// escribirlo junto con la contraseña nueva.
///
/// El servidor responde igual exista o no la cuenta (no revela qué correos
/// están registrados), así que el texto dice «si existe una cuenta…».
class RecuperarClavePage extends ConsumerStatefulWidget {
  const RecuperarClavePage({super.key, this.email});
  final String? email;

  @override
  ConsumerState<RecuperarClavePage> createState() => _RecuperarClavePageState();
}

class _RecuperarClavePageState extends ConsumerState<RecuperarClavePage> {
  final _formulario = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email ?? '');
  final _codigo = TextEditingController();
  final _clave = TextEditingController();

  bool _codigoEnviado = false;
  bool _ocultar = true;
  bool _enviando = false;
  int _vigencia = 15;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _codigo.dispose();
    _clave.dispose();
    super.dispose();
  }

  String _texto(Object e) => e is ApiException ? e.mensajeUsuario : '$e';

  Future<void> _ejecutar(Future<void> Function() accion) async {
    if (!(_formulario.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _enviando = true;
      _error = null;
    });
    try {
      await accion();
    } catch (e) {
      if (mounted) setState(() => _error = _texto(e));
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Future<void> _pedirCodigo() => _ejecutar(() async {
        final minutos = await ref.read(authRepositoryProvider).recuperarClave(_email.text);
        if (!mounted) return;
        setState(() {
          _vigencia = minutos;
          _codigoEnviado = true;
        });
      });

  Future<void> _restablecer() => _ejecutar(() async {
        await ref.read(authRepositoryProvider).restablecerClave(
              email: _email.text,
              codigo: _codigo.text.trim(),
              password: _clave.text,
            );
        if (!mounted) return;
        mostrarMensaje(context, 'Listo: ya puedes entrar con tu contraseña nueva', esExito: true);
        _volver();
      });

  void _volver() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(Rutas.login);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Volver',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: _enviando ? null : _volver,
        ),
        title: const Text('Recuperar contraseña'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formulario,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _codigoEnviado ? 'Revisa tu correo' : '¿Olvidaste tu contraseña?',
                      style: context.textos.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _codigoEnviado
                          ? 'Si existe una cuenta con ${_email.text.trim()}, te enviamos un código de 6 dígitos. '
                              'Vence en $_vigencia minutos. Revisa también la carpeta de spam.'
                          : 'Escribe el correo con el que entras y te enviaremos un código para crear una contraseña nueva.',
                      style: context.textos.bodyMedium?.copyWith(color: context.colores.onSurfaceVariant),
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _email,
                      enabled: !_codigoEnviado && !_enviando,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Correo', prefixIcon: Icon(Icons.alternate_email_rounded)),
                      validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : 'Escribe un correo válido',
                      onFieldSubmitted: (_) => _codigoEnviado ? null : _pedirCodigo(),
                    ),
                    if (_codigoEnviado) ...[
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _codigo,
                        enabled: !_enviando,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        maxLength: 6,
                        decoration: const InputDecoration(
                          labelText: 'Código',
                          counterText: '',
                          prefixIcon: Icon(Icons.pin_outlined),
                        ),
                        validator: (v) => RegExp(r'^\d{6}$').hasMatch((v ?? '').trim()) ? null : 'El código tiene 6 dígitos',
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _clave,
                        enabled: !_enviando,
                        obscureText: _ocultar,
                        autofillHints: const [AutofillHints.newPassword],
                        onChanged: (_) => setState(() {}),
                        onFieldSubmitted: (_) => _restablecer(),
                        decoration: InputDecoration(
                          labelText: 'Contraseña nueva',
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
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        liveRegion: true,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: context.dominio.peligroContenedor,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.error_outline_rounded, size: 20, color: context.dominio.peligro),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(_error!, style: context.textos.bodySmall?.copyWith(color: context.dominio.peligro)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _enviando ? null : (_codigoEnviado ? _restablecer : _pedirCodigo),
                      child: _enviando
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                          : Text(_codigoEnviado ? 'Guardar contraseña' : 'Enviar código'),
                    ),
                    if (_codigoEnviado) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _enviando
                            ? null
                            : () => setState(() {
                                  _codigoEnviado = false;
                                  _codigo.clear();
                                  _error = null;
                                }),
                        child: const Text('No me llegó: cambiar correo o pedir otro código'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
