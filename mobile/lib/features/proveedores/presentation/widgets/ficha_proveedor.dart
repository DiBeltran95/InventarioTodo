import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/database/daos/proveedores_dao.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/estados.dart';

/// Ficha del proveedor.
///
/// Se abre en una hoja y no en una pantalla completa porque casi siempre se
/// consulta para una sola cosa: llamar. Las acciones van arriba, grandes, antes
/// que los datos: el teléfono como texto obliga a memorizarlo y salir a marcar.
class FichaProveedor extends ConsumerWidget {
  const FichaProveedor({super.key, required this.item, required this.onEditar});

  final ProveedorConUso item;
  final VoidCallback onEditar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = item.proveedor;
    final telefono = _valor(p.telefono);
    final email = _valor(p.email);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: context.colores.secondaryContainer,
                  child: Text(
                    item.iniciales,
                    style: context.textos.titleMedium?.copyWith(
                      color: context.colores.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.nombre, style: context.textos.titleLarge),
                      Text(
                        item.entradas == 0
                            ? 'Sin entradas registradas'
                            : '${item.entradas} entrada'
                                '${item.entradas == 1 ? '' : 's'} de mercancía',
                        style: context.textos.bodySmall?.copyWith(
                          color: context.colores.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () {
                    Navigator.pop(context);
                    onEditar();
                  },
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Editar',
                ),
              ],
            ),

            if (telefono != null || email != null) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  if (telefono != null)
                    Expanded(
                      child: _Accion(
                        icono: Icons.call_rounded,
                        etiqueta: 'Llamar',
                        onTap: () => _abrir(context, Uri(scheme: 'tel', path: telefono)),
                      ),
                    ),
                  if (telefono != null) const SizedBox(width: 10),
                  if (telefono != null)
                    Expanded(
                      child: _Accion(
                        icono: Icons.chat_rounded,
                        etiqueta: 'WhatsApp',
                        onTap: () => _abrir(
                          context,
                          Uri.parse('https://wa.me/${_soloDigitos(telefono)}'),
                        ),
                      ),
                    ),
                  if (email != null) ...[
                    if (telefono != null) const SizedBox(width: 10),
                    Expanded(
                      child: _Accion(
                        icono: Icons.mail_outline_rounded,
                        etiqueta: 'Correo',
                        onTap: () => _abrir(context, Uri(scheme: 'mailto', path: email)),
                      ),
                    ),
                  ],
                ],
              ),
            ],

            const SizedBox(height: 20),
            _Dato(icono: Icons.badge_outlined, etiqueta: 'NIT', valor: p.nit),
            _Dato(icono: Icons.person_outline_rounded, etiqueta: 'Contacto', valor: p.contacto),
            _Dato(
              icono: Icons.phone_outlined,
              etiqueta: 'Teléfono',
              valor: p.telefono,
              copiable: true,
            ),
            _Dato(
              icono: Icons.alternate_email_rounded,
              etiqueta: 'Correo',
              valor: p.email,
              copiable: true,
            ),
            _Dato(icono: Icons.place_outlined, etiqueta: 'Dirección', valor: p.direccion),
            _Dato(icono: Icons.notes_rounded, etiqueta: 'Notas', valor: p.notas),

            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => _confirmarEliminar(context, ref),
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Dar de baja'),
              style: OutlinedButton.styleFrom(
                foregroundColor: context.dominio.peligro,
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _abrir(BuildContext context, Uri destino) async {
    try {
      final abierto = await launchUrl(destino, mode: LaunchMode.externalApplication);
      if (!abierto && context.mounted) {
        mostrarMensaje(context, 'No hay ninguna app para abrir esto', esError: true);
      }
    } catch (e) {
      if (context.mounted) {
        mostrarMensaje(context, 'No se pudo abrir: $e', esError: true);
      }
    }
  }

  Future<void> _confirmarEliminar(BuildContext context, WidgetRef ref) async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('¿Dar de baja al proveedor?'),
        content: Text(
          item.entradas == 0
              ? 'Dejará de aparecer al registrar entradas de mercancía.'
              // Se dice el número: dar de baja a quien tiene 40 entradas es
              // una decisión distinta a borrar uno creado por error.
              : 'Dejará de aparecer al registrar entradas, pero las '
                  '${item.entradas} ya registradas se conservan intactas y '
                  'seguirán mostrando su nombre.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogo, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.dominio.peligro),
            onPressed: () => Navigator.pop(dialogo, true),
            child: const Text('Dar de baja'),
          ),
        ],
      ),
    );

    if (confirmado != true) return;

    await ref.read(proveedoresDaoProvider).eliminar(item.uuid);
    ref.read(syncEngineProvider).solicitar();

    if (context.mounted) {
      Navigator.pop(context);
      mostrarMensaje(context, 'Proveedor dado de baja');
    }
  }

  static String? _valor(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// WhatsApp exige el número sin espacios ni signos.
  static String _soloDigitos(String telefono) =>
      telefono.replaceAll(RegExp(r'[^0-9]'), '');
}

class _Accion extends StatelessWidget {
  const _Accion({required this.icono, required this.etiqueta, required this.onTap});

  final IconData icono;
  final String etiqueta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colores.primaryContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Icon(icono, color: context.colores.onPrimaryContainer),
              const SizedBox(height: 6),
              Text(
                etiqueta,
                style: context.textos.labelMedium?.copyWith(
                  color: context.colores.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dato extends StatelessWidget {
  const _Dato({
    required this.icono,
    required this.etiqueta,
    required this.valor,
    this.copiable = false,
  });

  final IconData icono;
  final String etiqueta;
  final String? valor;
  final bool copiable;

  @override
  Widget build(BuildContext context) {
    final texto = valor?.trim();
    // Un campo vacío no se pinta: una ficha llena de «—» sólo añade ruido.
    if (texto == null || texto.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 18, color: context.colores.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  etiqueta,
                  style: context.textos.labelSmall?.copyWith(
                    color: context.colores.onSurfaceVariant,
                  ),
                ),
                Text(texto, style: context.textos.bodyMedium),
              ],
            ),
          ),
          if (copiable)
            IconButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: texto));
                mostrarMensaje(context, '$etiqueta copiado');
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              tooltip: 'Copiar',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
