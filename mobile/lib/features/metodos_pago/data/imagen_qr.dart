import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persistencia del QR de un medio de pago en el dispositivo.
///
/// Mismo motivo que con las fotos de producto: `image_picker` entrega rutas del
/// caché temporal del sistema, que desaparecen al reiniciar la app o al limpiar
/// caché. Se copia a Documents para que el QR siga estando aunque todavía no
/// haya red para subirlo.
///
/// Además de la subida, esta copia es lo que permite **mostrar el QR sin
/// conexión**: en el momento de cobrar es cuando menos se puede depender de la
/// red, y un código que tarda en cargar deja al cliente esperando.
class ImagenQr {
  const ImagenQr._();

  static Future<Directory> _directorio() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'metodos_pago'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copia [origen] a un archivo estable asociado a [clave].
  /// Devuelve la ruta permanente, o `null` si el origen no existe.
  static Future<String?> persistir(String? origen, String clave) async {
    if (origen == null || origen.isEmpty) return null;
    final fuente = File(origen);
    if (!await fuente.exists()) return null;

    final dir = await _directorio();
    final ext = p.extension(origen).toLowerCase();
    final sufijo = {'.jpg', '.jpeg', '.png', '.webp'}.contains(ext) ? ext : '.png';

    // La clave puede ser el nombre del medio cuando aún no hay uuid (alta), así
    // que se limpia: un nombre como «Nequi / Bre-B» rompería la ruta.
    final segura = clave.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final destino = File(p.join(dir.path, '$segura$sufijo'));

    if (p.equals(fuente.path, destino.path)) return destino.path;

    await fuente.copy(destino.path);
    return destino.path;
  }
}
