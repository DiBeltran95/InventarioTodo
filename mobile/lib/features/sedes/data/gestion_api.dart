import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/providers/providers.dart';

/// Sede tal como la devuelve el servidor en la pantalla de administración.
class SedeAdmin {
  const SedeAdmin({
    required this.uuid,
    required this.nombre,
    required this.codigo,
    this.direccion,
    this.telefono,
    this.esPrincipal = false,
    this.activo = true,
  });

  factory SedeAdmin.desdeJson(Map<String, dynamic> j) => SedeAdmin(
        uuid: j['uuid'] as String,
        nombre: j['nombre'] as String,
        codigo: (j['codigo'] as String?) ?? '',
        direccion: j['direccion'] as String?,
        telefono: j['telefono'] as String?,
        esPrincipal: j['es_principal'] == true || j['es_principal'] == 1,
        activo: j['activo'] == null || j['activo'] == true || j['activo'] == 1,
      );

  final String uuid;
  final String nombre;
  final String codigo;
  final String? direccion;
  final String? telefono;
  final bool esPrincipal;
  final bool activo;
}

/// Solicitud de un empleado para pasar a otra sede.
class SolicitudCambioSede {
  const SolicitudCambioSede({
    required this.uuid,
    required this.empleadoUuid,
    required this.empleadoNombre,
    required this.destino,
    required this.creada,
    required this.puedoResolver,
    this.origen,
    this.motivo,
  });

  factory SolicitudCambioSede.desdeJson(Map<String, dynamic> j) {
    final e = j['empleado'] as Map;
    final d = j['sede_destino'] as Map;
    final o = j['sede_origen'] as Map?;
    return SolicitudCambioSede(
      uuid: j['uuid'] as String,
      empleadoUuid: e['uuid'] as String,
      empleadoNombre: e['nombre'] as String,
      destino: (uuid: d['uuid'] as String, nombre: d['nombre'] as String),
      origen: o == null ? null : (uuid: o['uuid'] as String, nombre: o['nombre'] as String),
      motivo: j['motivo'] as String?,
      creada: DateTime.tryParse('${j['created_at']}') ?? DateTime.now().toUtc(),
      puedoResolver: j['puedo_resolver'] == true,
    );
  }

  final String uuid;
  final String empleadoUuid;
  final String empleadoNombre;
  final ({String uuid, String nombre}) destino;
  final ({String uuid, String nombre})? origen;
  final String? motivo;
  final DateTime creada;
  final bool puedoResolver;
}

/// Una fila del registro de auditoría.
class EntradaAuditoria {
  const EntradaAuditoria({
    required this.id,
    required this.accion,
    required this.fecha,
    this.entidad,
    this.entidadUuid,
    this.antes,
    this.despues,
    this.usuario,
    this.sede,
  });

  factory EntradaAuditoria.desdeJson(Map<String, dynamic> j) {
    final u = j['usuario'] as Map?;
    final s = j['sede'] as Map?;
    return EntradaAuditoria(
      id: (j['id'] as num).toInt(),
      accion: j['accion'] as String,
      fecha: DateTime.tryParse('${j['fecha']}') ?? DateTime.now().toUtc(),
      entidad: j['entidad'] as String?,
      entidadUuid: j['entidad_uuid'] as String?,
      antes: j['antes'],
      despues: j['despues'],
      usuario: u == null ? null : (uuid: u['uuid'] as String, nombre: u['nombre'] as String),
      sede: s == null ? null : (uuid: s['uuid'] as String, nombre: s['nombre'] as String),
    );
  }

  final int id;
  final String accion;
  final DateTime fecha;
  final String? entidad;
  final String? entidadUuid;
  final Object? antes;
  final Object? despues;
  final ({String uuid, String nombre})? usuario;
  final ({String uuid, String nombre})? sede;
}

/// Gestión que sólo tiene sentido en línea: sedes, cambios de sede y
/// auditoría.
///
/// Igual que las cuentas de usuario, no pasa por la cola de salida. Crear una
/// sede sin red en dos teléfonos produciría dos sedes con el mismo código; un
/// cambio de sede lo resuelve otra persona, así que esperar a tener red no
/// cuesta nada. Lo que sí hace falta sin red —las sedes y sus nombres— baja con
/// la sincronización normal.
class GestionApi {
  GestionApi(this._api);

  final ApiClient _api;

  static List<Map<String, dynamic>> _lista(Map<String, dynamic> r) =>
      (r['data'] as List<dynamic>).cast<Map<String, dynamic>>();

  // ── Sedes ─────────────────────────────────────────────────────────────────

  Future<List<SedeAdmin>> sedes() async => _lista(await _api.get('/sedes')).map(SedeAdmin.desdeJson).toList();

  /// Todas las sedes activas, sólo nombre: para elegir a cuál pedir el cambio.
  Future<List<SedeAdmin>> todasLasSedes() async =>
      _lista(await _api.get('/sedes/todas')).map(SedeAdmin.desdeJson).toList();

  Future<void> crearSede({required String nombre, required String codigo, String? direccion, String? telefono}) =>
      _api.post('/sedes', cuerpo: {
        'nombre': nombre,
        'codigo': codigo,
        if (direccion != null && direccion.isNotEmpty) 'direccion': direccion,
        if (telefono != null && telefono.isNotEmpty) 'telefono': telefono,
      });

  Future<void> actualizarSede(
    String uuid, {
    String? nombre,
    String? codigo,
    String? direccion,
    String? telefono,
    bool? activo,
  }) =>
      _api.patch('/sedes/$uuid', cuerpo: {
        'nombre': ?nombre,
        'codigo': ?codigo,
        'direccion': ?direccion,
        'telefono': ?telefono,
        'activo': ?activo,
      });

  // ── Cambios de sede ───────────────────────────────────────────────────────

  /// Las que me tocan: la mía (si la pedí) y las que llegan a mis sedes.
  Future<List<SolicitudCambioSede>> cambiosDeSede() async =>
      _lista(await _api.get('/sedes/cambios')).map(SolicitudCambioSede.desdeJson).toList();

  Future<void> solicitarCambioSede(String sedeUuid, {String? motivo}) => _api.post('/sedes/cambios', cuerpo: {
        'sede_uuid': sedeUuid,
        if (motivo != null && motivo.isNotEmpty) 'motivo': motivo,
      });

  Future<void> resolverCambioSede(String uuid, {required bool aceptar}) =>
      _api.post('/sedes/cambios/$uuid/${aceptar ? 'aceptar' : 'rechazar'}');

  // ── Auditoría ─────────────────────────────────────────────────────────────

  Future<({List<EntradaAuditoria> items, int? siguiente})> auditoria({
    String? desde,
    String? hasta,
    String? sede,
    String? accion,
    int? antesDe,
    int limite = 50,
  }) async {
    final r = await _api.get('/auditoria', query: {
      'desde': ?desde,
      'hasta': ?hasta,
      'sede': ?sede,
      'accion': ?accion,
      'antes_de': ?antesDe,
      'limite': limite,
    });
    final meta = r['meta'] as Map?;
    return (
      items: _lista(r).map(EntradaAuditoria.desdeJson).toList(),
      siguiente: (meta?['siguiente'] as num?)?.toInt(),
    );
  }
}

final gestionApiProvider = Provider<GestionApi>((ref) => GestionApi(ref.watch(apiClientProvider)));
