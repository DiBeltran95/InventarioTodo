import 'dart:io';

import 'package:flutter/material.dart';

import '../database/daos/productos_dao.dart';
import '../theme/app_theme.dart';

/// Foto de un producto, con respaldo cuando no hay ninguna.
///
/// Reconocer una foto es más rápido que leer un nombre, y en el mostrador esa
/// diferencia importa: al escanear, la imagen confirma de un vistazo que se
/// añadió *ese* artículo y no el de al lado, que muchas veces tiene un nombre
/// casi idéntico («Gaseosa 400» / «Gaseosa 400 zero»).
///
/// Tres niveles, en este orden:
///
/// 1. **La foto local**, si existe en disco. Tiene prioridad sobre la remota:
///    la que se acaba de tomar aún no se ha subido, así que la del servidor
///    todavía no existe.
/// 2. **La foto del servidor**, si la hay. Sin conexión falla, y por eso cae al
///    marcador en vez de dejar un hueco roto.
/// 3. **Las iniciales** sobre el color de su categoría. Nunca un icono
///    genérico: las iniciales y el color ya distinguen un producto de otro.
class FotoProducto extends StatelessWidget {
  const FotoProducto({
    super.key,
    required this.producto,
    this.tamano = 52,
    this.radio = 14,
  });

  final ProductoConCategoria producto;
  final double tamano;
  final double radio;

  @override
  Widget build(BuildContext context) {
    final local = producto.producto.imagenLocal;
    final remota = producto.producto.imagenUrl;

    if (local != null && File(local).existsSync()) {
      return _enmarcada(
        Image.file(
          File(local),
          width: tamano,
          height: tamano,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _Marcador(producto: producto, tamano: tamano, radio: radio),
        ),
      );
    }

    if (remota != null && remota.isNotEmpty) {
      return _enmarcada(
        Image.network(
          remota,
          width: tamano,
          height: tamano,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _Marcador(producto: producto, tamano: tamano, radio: radio),
        ),
      );
    }

    return _Marcador(producto: producto, tamano: tamano, radio: radio);
  }

  Widget _enmarcada(Widget imagen) =>
      ClipRRect(borderRadius: BorderRadius.circular(radio), child: imagen);
}

class _Marcador extends StatelessWidget {
  const _Marcador({required this.producto, required this.tamano, required this.radio});

  final ProductoConCategoria producto;
  final double tamano;
  final double radio;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: tamano,
      height: tamano,
      decoration: BoxDecoration(
        color: colorSuaveDeCategoria(context, producto.categoria?.color),
        borderRadius: BorderRadius.circular(radio),
      ),
      child: Center(
        child: Text(
          inicialesDe(producto.nombre),
          style: (tamano >= 64 ? context.textos.titleLarge : context.textos.titleMedium)
              ?.copyWith(color: context.colores.onSecondaryContainer),
        ),
      ),
    );
  }
}

/// Color de categoría atenuado sobre la superficie.
///
/// Se mezcla a propósito: un color chillón elegido en el catálogo arruinaría la
/// legibilidad de las iniciales encima.
Color colorSuaveDeCategoria(BuildContext context, String? hex) {
  if (hex == null || !hex.startsWith('#') || hex.length != 7) {
    return context.colores.secondaryContainer;
  }
  final valor = int.tryParse(hex.substring(1), radix: 16);
  if (valor == null) return context.colores.secondaryContainer;
  return Color(0xFF000000 | valor).withValues(alpha: 0.22);
}

/// Una o dos letras para representar un producto sin foto.
String inicialesDe(String nombre) {
  final partes = nombre.trim().split(RegExp(r'\s+'));
  if (partes.isEmpty || partes.first.isEmpty) return '?';
  if (partes.length == 1) {
    return partes.first.substring(0, partes.first.length.clamp(0, 2)).toUpperCase();
  }
  return (partes[0][0] + partes[1][0]).toUpperCase();
}
