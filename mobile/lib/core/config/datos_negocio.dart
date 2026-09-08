/// Identidad del negocio: lo que encabeza cada ticket.
///
/// Vive en la tabla `configuracion`, que baja entera en cada sincronización.
/// Por eso el comprobante sale con los datos correctos **sin conexión**: para
/// cuando hay que imprimir, ya están en SQLite.
class DatosNegocio {
  const DatosNegocio({
    required this.nombre,
    this.nit,
    this.direccion,
    this.telefono,
    this.pieTicket,
  });

  /// Lee los datos de un mapa de configuración.
  ///
  /// Los campos vacíos se normalizan a `null`: el ticket omite la línea entera
  /// en vez de imprimir un «NIT» sin número al lado.
  factory DatosNegocio.desdeConfig(Map<String, String> config) {
    String? opcional(String clave) {
      final valor = config[clave]?.trim();
      return (valor == null || valor.isEmpty) ? null : valor;
    }

    return DatosNegocio(
      nombre: opcional(ClavesNegocio.nombre) ?? 'Mi Negocio',
      nit: opcional(ClavesNegocio.nit),
      direccion: opcional(ClavesNegocio.direccion),
      telefono: opcional(ClavesNegocio.telefono),
      pieTicket: opcional(ClavesNegocio.pieTicket),
    );
  }

  final String nombre;
  final String? nit;
  final String? direccion;
  final String? telefono;
  final String? pieTicket;
}

/// Claves de `configuracion` que describen al negocio.
///
/// Coinciden con las que el servidor trae por defecto (`CONFIG_DEFAULTS`), así
/// que lo que guarda la app es lo mismo que leería cualquier otro consumidor
/// de la API.
class ClavesNegocio {
  const ClavesNegocio._();

  static const nombre = 'nombre_negocio';
  static const nit = 'nit';
  static const direccion = 'direccion';
  static const telefono = 'telefono';
  static const pieTicket = 'ticket_pie';
}
