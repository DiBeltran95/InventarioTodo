import '../../../core/negocio/jornada.dart';

/// Rol del usuario. Determina qué puede hacer y qué información ve.
///
/// En la base, el Director General sigue llamándose 'ADMIN': así la app vieja
/// lo reconoce mientras se actualizan los teléfonos. Un rol desconocido se lee
/// como vendedor, que es lo más restrictivo para la información sensible
/// (costos, márgenes, personal).
enum RolUsuario {
  director,
  gerente,
  auxiliarInventario,
  vendedor;

  static RolUsuario desde(String? valor) => switch (valor) {
        'ADMIN' => RolUsuario.director,
        'GERENTE' => RolUsuario.gerente,
        'AUXILIAR_INVENTARIO' => RolUsuario.auxiliarInventario,
        _ => RolUsuario.vendedor,
      };

  String get api => switch (this) {
        RolUsuario.director => 'ADMIN',
        RolUsuario.gerente => 'GERENTE',
        RolUsuario.auxiliarInventario => 'AUXILIAR_INVENTARIO',
        RolUsuario.vendedor => 'VENDEDOR',
      };

  String get etiqueta => switch (this) {
        RolUsuario.director => 'Director General',
        RolUsuario.gerente => 'Gerente de Sede',
        RolUsuario.auxiliarInventario => 'Auxiliar de Inventario',
        RolUsuario.vendedor => 'Vendedor',
      };

  bool get esDirector => this == RolUsuario.director;

  /// Director o gerente: gestionan catálogo, stock, personal y reportes (el
  /// gerente, de sus sedes).
  bool get esGestor => this == RolUsuario.director || this == RolUsuario.gerente;

  /// Pertenece a exactamente una sede.
  bool get esDeUnaSede => this == RolUsuario.vendedor || this == RolUsuario.auxiliarInventario;

  /// El auxiliar de inventario no vende.
  bool get puedeVender => this != RolUsuario.auxiliarInventario;

  /// Cargar mercancía que llega del proveedor.
  bool get puedeRegistrarEntradas => esGestor || this == RolUsuario.auxiliarInventario;

  /// Conteo, merma o ajuste aplicados al instante. El auxiliar los solicita y
  /// esperan la aprobación de un gerente.
  bool get ajustaDirecto => esGestor;
  bool get solicitaAjustes => this == RolUsuario.auxiliarInventario;

  bool get puedeEditarCatalogo => esGestor;
  bool get puedeAnularVentas => esGestor;
  bool get puedeGestionarUsuarios => esGestor;
  bool get pideTraslados => this != RolUsuario.auxiliarInventario;

  /// Vendedores y auxiliares no ven costos ni márgenes: es información
  /// sensible del negocio.
  bool get veCostos => esGestor;
}

/// Usuario tal como lo devuelve la API en la pantalla de administración.
///
/// No se guarda en SQLite: la gestión de cuentas es una operación en línea y
/// sus datos no hacen falta para vender. La tabla local `usuarios` sólo guarda
/// a quien ha iniciado sesión en este dispositivo, para el desbloqueo offline.
class UsuarioAdmin {
  const UsuarioAdmin({
    required this.uuid,
    required this.nombre,
    required this.email,
    required this.rol,
    required this.activo,
    this.telefono,
    this.ultimoAcceso,
    this.sedes = const [],
    this.restringirHorario = false,
    this.horario = const [],
    this.accesoExtraHasta,
    this.jornada,
  });

  factory UsuarioAdmin.desdeJson(Map<String, dynamic> json) {
    final j = json['jornada'];
    return UsuarioAdmin(
      uuid: json['uuid'] as String,
      nombre: json['nombre'] as String,
      email: json['email'] as String,
      rol: RolUsuario.desde(json['rol'] as String?),
      // MariaDB devuelve los TINYINT(1) como 0/1, no como booleanos.
      activo: json['activo'] == true || json['activo'] == 1,
      telefono: json['telefono'] as String?,
      ultimoAcceso: DateTime.tryParse(json['ultimo_acceso'] as String? ?? ''),
      sedes: [
        for (final s in (json['sedes'] as List<dynamic>? ?? const []))
          (uuid: (s as Map)['uuid'] as String, nombre: s['nombre'] as String),
      ],
      restringirHorario: json['restringir_horario'] == true || json['restringir_horario'] == 1,
      horario: [
        for (final t in (json['horario'] as List<dynamic>? ?? const []))
          TramoHorario.desdeJson(t as Map<String, dynamic>),
      ],
      accesoExtraHasta: DateTime.tryParse(json['acceso_extra_hasta'] as String? ?? ''),
      jornada: j is Map
          ? (
              permitido: j['permitido'] == true,
              motivo: j['motivo'] as String? ?? '',
              hasta: DateTime.tryParse(j['hasta'] as String? ?? ''),
              proximoInicio: DateTime.tryParse(j['proximo_inicio'] as String? ?? ''),
            )
          : null,
    );
  }

  final String uuid;
  final String nombre;
  final String email;
  final RolUsuario rol;
  final bool activo;
  final String? telefono;
  final DateTime? ultimoAcceso;
  final List<({String uuid, String nombre})> sedes;
  final bool restringirHorario;
  final List<TramoHorario> horario;
  final DateTime? accesoExtraHasta;

  /// Cómo está su jornada según el servidor en el momento de listar.
  final ({bool permitido, String motivo, DateTime? hasta, DateTime? proximoInicio})? jornada;

  bool get conAccesoExtra => accesoExtraHasta != null && accesoExtraHasta!.isAfter(DateTime.now().toUtc());

  String get iniciales {
    final partes = nombre.trim().split(RegExp(r'\s+'));
    if (partes.isEmpty || partes.first.isEmpty) return '?';
    if (partes.length == 1) return partes.first.substring(0, 1).toUpperCase();
    return (partes.first.substring(0, 1) + partes.last.substring(0, 1)).toUpperCase();
  }
}

class Sesion {
  const Sesion({
    required this.usuarioUuid,
    required this.nombre,
    required this.email,
    required this.rol,
    required this.enLinea,
    this.validaHasta,
  });

  final String usuarioUuid;
  final String nombre;
  final String email;
  final RolUsuario rol;

  /// `true` si la sesión se abrió contra el servidor; `false` si se validó
  /// contra el derivado local de la contraseña.
  final bool enLinea;

  /// Hasta cuándo se puede seguir operando sin volver a ver el servidor.
  final DateTime? validaHasta;

  /// Director o gerente. Antes era `esAdmin`; con sedes, lo que de verdad
  /// importa casi siempre es si gestiona, no si es el dueño.
  bool get esGestor => rol.esGestor;

  /// Días que quedan de operación offline. Se avisa al usuario cuando bajan de
  /// dos: quedarse fuera a mitad de un turno sería inaceptable.
  int? get diasRestantes => diasDeGraciaRestantes(validaHasta);

  bool get avisarCaducidad => debeAvisarCaducidad(validaHasta);

  String get iniciales {
    final partes = nombre.trim().split(RegExp(r'\s+'));
    if (partes.isEmpty || partes.first.isEmpty) return '?';
    if (partes.length == 1) return partes.first.substring(0, 1).toUpperCase();
    return (partes.first.substring(0, 1) + partes.last.substring(0, 1)).toUpperCase();
  }
}

/// Días que quedan para operar sin ver al servidor. Nunca negativo.
///
/// [ahora] se inyecta para poder probarlo sin depender del reloj.
int? diasDeGraciaRestantes(DateTime? limite, {DateTime? ahora}) {
  if (limite == null) return null;
  final dias = limite.toUtc().difference((ahora ?? DateTime.now()).toUtc()).inDays;
  return dias < 0 ? 0 : dias;
}

/// Se avisa cuando quedan dos días o menos: quedarse fuera a mitad de un turno
/// sería inaceptable.
bool debeAvisarCaducidad(DateTime? limite, {DateTime? ahora}) {
  final d = diasDeGraciaRestantes(limite, ahora: ahora);
  return d != null && d <= 2;
}

class ResultadoLogin {
  const ResultadoLogin._({
    this.sesion,
    this.mensajeError,
    this.necesitaDescargaInicial = false,
  });

  factory ResultadoLogin.ok(Sesion sesion, {bool necesitaDescargaInicial = false}) =>
      ResultadoLogin._(sesion: sesion, necesitaDescargaInicial: necesitaDescargaInicial);

  factory ResultadoLogin.error(String mensaje) => ResultadoLogin._(mensajeError: mensaje);

  final Sesion? sesion;
  final String? mensajeError;
  final bool necesitaDescargaInicial;

  bool get exito => sesion != null;
}
