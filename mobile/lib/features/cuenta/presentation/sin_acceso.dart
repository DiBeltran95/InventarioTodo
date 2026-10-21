import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Explica por qué una cuenta con la contraseña correcta no puede usar
/// Inventario (empresa sin la app, cuenta sin rol aquí, empresa suspendida…)
/// y qué hacer. No es un «error»: la persona no se equivocó, y presentarlo
/// como tal la haría reintentar en vano.
class PanelSinAcceso extends StatelessWidget {
  const PanelSinAcceso({super.key, required this.codigo, required this.alUsarOtraCuenta});

  final String? codigo;
  final VoidCallback alUsarOtraCuenta;

  ({IconData icono, String titulo, String texto}) get _contenido => switch (codigo) {
        'APP_NO_HABILITADA' => (
            icono: Icons.apps_outage_rounded,
            titulo: 'Tu empresa aún no usa Ventario',
            texto: 'Tu cuenta está bien, pero esta app no está habilitada para tu empresa. '
                'El director puede solicitar que la activen. Si tu empresa usa Presente, '
                'puedes seguir entrando allá con este mismo correo.',
          ),
        'SIN_ACCESO_APP' => (
            icono: Icons.person_off_outlined,
            titulo: 'Tu cuenta no tiene acceso a Ventario',
            texto: 'Tu empresa usa Ventario, pero a tu cuenta no le han dado un rol aquí. '
                'Pídele al director o a tu gerente que te lo asigne en «Usuarios».',
          ),
        'EMPRESA_SUSPENDIDA' => (
            icono: Icons.pause_circle_outline_rounded,
            titulo: 'Tu empresa está suspendida',
            texto: 'Mientras esté suspendida nadie de la empresa puede entrar. '
                'El director puede comunicarse con el equipo de la plataforma.',
          ),
        'CUENTA_DESACTIVADA' => (
            icono: Icons.lock_person_outlined,
            titulo: 'Tu cuenta está inhabilitada',
            texto: 'El director o tu gerente inhabilitaron esta cuenta. Si es un error, pídeles que la reactiven.',
          ),
        _ => (
            icono: Icons.domain_disabled_outlined,
            titulo: 'Tu empresa ya no está en la plataforma',
            texto: 'Esta cuenta pertenecía a una empresa que fue eliminada.',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final c = _contenido;
    final d = context.dominio;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: CircleAvatar(
              radius: 36,
              backgroundColor: d.advertenciaContenedor,
              child: Icon(c.icono, color: d.advertencia, size: 36),
            ),
          ),
          const SizedBox(height: 20),
          Text(c.titulo, textAlign: TextAlign.center, style: context.textos.titleLarge),
          const SizedBox(height: 8),
          Text(
            c.texto,
            textAlign: TextAlign.center,
            style: context.textos.bodyMedium?.copyWith(color: context.colores.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: alUsarOtraCuenta,
            icon: const Icon(Icons.switch_account_outlined),
            label: const Text('Usar otra cuenta'),
          ),
        ],
      ),
    );
  }
}
