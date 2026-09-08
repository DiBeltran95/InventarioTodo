import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Encabezado de una hoja inferior, con salida siempre visible.
///
/// El asa de arrastre **no basta como única salida**. En una hoja alta con
/// scroll dentro, el gesto de bajar se lo come el scroll; y con el teclado
/// abierto el asa queda fuera de la pantalla. El resultado es una hoja de la
/// que no se puede salir salvo completando el formulario, aunque se haya
/// entrado por error.
///
/// Por eso todas las hojas de formulario llevan esta cabecera: un botón de
/// cerrar que funciona siempre, en el mismo sitio.
class EncabezadoHoja extends StatelessWidget {
  const EncabezadoHoja({
    super.key,
    required this.titulo,
    this.subtitulo,
    this.alCerrar,
    this.accion,
  });

  final String titulo;
  final String? subtitulo;

  /// Qué hacer al cerrar. Por defecto, un `pop` simple.
  final VoidCallback? alCerrar;

  /// Acción opcional a la derecha (p. ej. eliminar).
  final Widget? accion;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconButton(
          onPressed: alCerrar ?? () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Cerrar',
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(titulo, style: context.textos.titleLarge),
              if (subtitulo != null)
                Text(
                  subtitulo!,
                  style: context.textos.bodySmall?.copyWith(
                    color: context.colores.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        // Reserva el ancho del botón de cerrar cuando no hay acción, para que
        // el título no baile entre hojas con y sin acción.
        accion ?? const SizedBox(width: 48),
      ],
    );
  }
}
