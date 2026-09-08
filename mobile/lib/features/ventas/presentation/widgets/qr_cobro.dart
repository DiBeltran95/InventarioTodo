import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/money/money.dart';
import '../../../../core/theme/app_theme.dart';

/// QR que el vendedor le muestra al cliente para que pague.
///
/// Se enseña **girando el teléfono hacia el cliente**, así que todo va grande y
/// con el mínimo de texto: el importe arriba para que el cliente confirme
/// cuánto va a transferir, y el código lo más grande que quepa.
///
/// Prioriza la copia local sobre la URL: en el momento de cobrar es cuando
/// menos se puede depender de la red, y un QR que tarda en cargar deja al
/// cliente esperando con el teléfono en la mano.
class QrCobro extends StatelessWidget {
  const QrCobro({super.key, required this.metodo, required this.monto});

  final MetodoPago metodo;
  final Money monto;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(metodo.nombre, style: context.textos.titleLarge),
            const SizedBox(height: 2),
            Text(
              monto.format(),
              style: context.textos.headlineMedium?.copyWith(
                color: context.colores.primary,
              ),
            ),
            const SizedBox(height: 16),

            // Fondo blanco fijo: un QR sobre superficie oscura no lo lee
            // ningún teléfono, y el tema del vendedor puede estar en oscuro.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: _Imagen(metodo: metodo),
            ),

            if ((metodo.instrucciones ?? '').isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                metodo.instrucciones!,
                textAlign: TextAlign.center,
                style: context.textos.titleSmall,
              ),
            ],

            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              child: const Text('Listo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Imagen extends StatelessWidget {
  const _Imagen({required this.metodo});

  final MetodoPago metodo;

  @override
  Widget build(BuildContext context) {
    const lado = 260.0;
    final local = metodo.qrLocal;
    final remota = metodo.qrUrl;

    Widget noDisponible() => SizedBox(
          width: lado,
          height: lado,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.qr_code_2_rounded, size: 48, color: Colors.black38),
                  const SizedBox(height: 10),
                  Text(
                    'El QR aún no se ha descargado a este dispositivo. '
                    'Sincroniza con conexión para poder mostrarlo.',
                    textAlign: TextAlign.center,
                    style: context.textos.bodySmall?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
        );

    if (local != null && local.isNotEmpty && File(local).existsSync()) {
      return Image.file(
        File(local),
        width: lado,
        height: lado,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => noDisponible(),
      );
    }

    if (remota != null && remota.isNotEmpty) {
      return Image.network(
        remota,
        width: lado,
        height: lado,
        fit: BoxFit.contain,
        // Sin red la imagen falla: se explica en vez de dejar un hueco roto.
        errorBuilder: (_, _, _) => noDisponible(),
        loadingBuilder: (context, hijo, progreso) => progreso == null
            ? hijo
            : const SizedBox(
                width: lado,
                height: lado,
                child: Center(child: CircularProgressIndicator()),
              ),
      );
    }

    return noDisponible();
  }
}
