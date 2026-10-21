import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

/// Dirección pública de la política completa (la exige Google Play). Se fija
/// al compilar: `--dart-define=URL_PRIVACIDAD=https://…`.
const urlPrivacidad = String.fromEnvironment(
  'URL_PRIVACIDAD',
  defaultValue: 'https://agendaservi.com/privacidad/',
);

/// Resumen de los términos y del tratamiento de datos en lenguaje claro, con
/// enlace a la versión completa.
Future<void> mostrarTerminos(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          Text('Términos y tratamiento de datos', style: ctx.textos.headlineSmall),
          const SizedBox(height: 16),
          for (final (titulo, texto) in _puntos) ...[
            Text(titulo, style: ctx.textos.titleMedium),
            const SizedBox(height: 4),
            Text(texto, style: ctx.textos.bodyMedium?.copyWith(color: ctx.colores.onSurfaceVariant)),
            const SizedBox(height: 16),
          ],
          OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.parse(urlPrivacidad), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Leer la versión completa'),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cerrar')),
        ],
      ),
    ),
  );
}

const _puntos = [
  (
    'Qué datos guardamos',
    'De la empresa: nombre, NIT y teléfono. De cada persona: nombre, correo, rol y sedes. '
        'Del negocio: productos, existencias, ventas, cierres de caja y quién hizo cada operación.',
  ),
  (
    'Para qué',
    'Solo para que tu empresa opere su inventario y sus ventas, y para mantener sincronizados los '
        'teléfonos de tu equipo. No vendemos ni compartimos tus datos con terceros.',
  ),
  (
    'Quién es responsable',
    'Tu empresa es la responsable de los datos de su personal y de sus clientes (Ley 1581 de 2012). '
        'La plataforma los trata solo por cuenta de tu empresa.',
  ),
  (
    'Tus derechos',
    'Puedes conocer, actualizar, rectificar y suprimir los datos. El director de la empresa puede '
        'eliminar la empresa y todas sus cuentas desde Ajustes → Mi empresa.',
  ),
  (
    'Planes',
    'El plan Gratis no tiene costo. Los planes con más capacidad se contratan directamente con el equipo '
        'de la plataforma, fuera de la app.',
  ),
];
