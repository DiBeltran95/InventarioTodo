import 'dart:convert';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:drift/drift.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/database/daos/sync_dao.dart';
import '../../../core/negocio/jornada.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/token_store.dart';
import '../../../core/security/password_hash.dart';
import '../domain/jornada_usuario.dart';
import '../domain/sesion.dart';

/// Autenticación con soporte offline real.
///
/// El JWT caduca a los 15 minutos; el turno de un vendedor dura ocho horas y
/// puede transcurrir entero sin señal. Por eso la sesión de la APP y la sesión
/// de la API son cosas distintas:
///
///  · El JWT sólo sirve para hablar con el servidor.
///  · Para entrar a la app basta con verificar la contraseña contra un derivado
///    PBKDF2 guardado en el dispositivo la primera vez que se inició sesión con
///    red, dentro de una ventana de gracia.
class AuthRepository {
  AuthRepository({
    required AppDatabase db,
    required ApiClient api,
    required TokenStore tokens,
  })  : _db = db,
        _api = api,
        _tokens = tokens;

  final AppDatabase _db;
  final ApiClient _api;
  final TokenStore _tokens;

  static const _uuid = Uuid();
  static const _kUltimoEmail = 'ultimo_email';
  static const _kDispositivoUuid = 'dispositivo_uuid';

  /// UUID estable del dispositivo. Se genera una vez y se conserva: es la clave
  /// con la que el servidor le asigna su prefijo de folio.
  Future<String> _uuidDispositivo() async {
    final prefs = await SharedPreferences.getInstance();
    var uuid = prefs.getString(_kDispositivoUuid);
    if (uuid == null) {
      uuid = _uuid.v7();
      await prefs.setString(_kDispositivoUuid, uuid);
    }
    return uuid;
  }

  Future<Map<String, dynamic>> _datosDispositivo() async {
    final uuid = await _uuidDispositivo();
    var nombre = 'Dispositivo';
    var plataforma = 'android';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      nombre = '${info.manufacturer} ${info.model}';
      plataforma = 'Android ${info.version.release}';
    } catch (_) {
      // En pruebas o en otra plataforma se queda con los valores por defecto.
    }
    var version = '1.0.0';
    try {
      version = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}

    return {
      'uuid': uuid,
      'nombre': nombre,
      'plataforma': plataforma,
      'app_version': version,
    };
  }

  /// Inicia sesión. Intenta primero contra el servidor; si no hay red, cae a la
  /// verificación local.
  Future<ResultadoLogin> iniciarSesion(String email, String password) async {
    final correo = email.trim().toLowerCase();

    try {
      return await _loginEnLinea(correo, password);
    } on ApiException catch (e) {
      // Credenciales rechazadas por el servidor: no tiene sentido caer al modo
      // offline. Si la contraseña cambió, la copia local está obsoleta.
      if (!e.esDeRed) {
        if (e.status == 401 || e.status == 403) {
          // Una cuenta inhabilitada no debe poder entrar tampoco sin red con
          // la copia local de su contraseña.
          if (e.codigo == 'CUENTA_DESACTIVADA') await _marcarInactivo(correo);
          return ResultadoLogin.error(e.mensajeUsuario);
        }
        rethrow;
      }
      return _loginOffline(correo, password);
    }
  }

  Future<ResultadoLogin> _loginEnLinea(String email, String password) async {
    final dispositivo = await _datosDispositivo();
    _api.dispositivoUuid = dispositivo['uuid'] as String;

    final respuesta = await _api.post(
      '/auth/login',
      sinAuth: true,
      cuerpo: {'email': email, 'password': password, 'dispositivo': dispositivo},
    );

    final datos = respuesta['data'] as Map<String, dynamic>;
    final usuario = datos['usuario'] as Map<String, dynamic>;

    await _tokens.guardarTokens(
      accessToken: datos['access_token'] as String,
      refreshToken: datos['refresh_token'] as String,
      refreshExpira: DateTime.tryParse(datos['refresh_expira'] as String? ?? ''),
    );

    // Derivado local de la contraseña, para poder entrar sin red la próxima vez.
    final salt = PasswordHash.generarSalt();
    final hash = await PasswordHash.derivar(password, salt);

    final diasGracia = (datos['offline_grace_days'] as num?)?.toInt() ??
        AppConfig.diasGraciaOffline;
    final valido = DateTime.now().toUtc().add(Duration(days: diasGracia));

    final esPrimeraVez = await _esDispositivoNuevo(usuario['uuid'] as String);
    final rol = usuario['rol'] as String? ?? 'VENDEDOR';
    final sedes = ((datos['sedes'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final sedeActiva = datos['sede_activa'] as String?;
    final sedeAnterior =
        (await (_db.select(_db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull())?.sedeActivaUuid;

    await _db.transaction(() async {
      // Las sedes llegan con el login para poder operar desde el primer
      // segundo, antes de la primera bajada.
      for (final s in sedes) {
        await _db.into(_db.sedes).insertOnConflictUpdate(
              SedesCompanion.insert(
                uuid: s['uuid'] as String,
                nombre: s['nombre'] as String,
                codigo: s['codigo'] as String,
                direccion: Value(s['direccion'] as String?),
                telefono: Value(s['telefono'] as String?),
                esPrincipal: Value(s['es_principal'] == true),
                activo: Value(s['activo'] != false),
              ),
            );
      }

      await _db.into(_db.usuarios).insertOnConflictUpdate(
            UsuariosCompanion.insert(
              uuid: usuario['uuid'] as String,
              nombre: usuario['nombre'] as String,
              email: usuario['email'] as String,
              rol: Value(rol),
              activo: const Value(true),
              passwordHashLocal: Value(hash),
              saltLocal: Value(salt),
              restringirHorario: Value(usuario['restringir_horario'] == true),
              horario: Value(usuario['horario'] == null ? null : jsonEncode(usuario['horario'])),
              accesoExtraHasta: Value(DateTime.tryParse(usuario['acceso_extra_hasta'] as String? ?? '')),
              // El director ve todas: su lista de sedes queda vacía.
              sedes: Value(rol == 'ADMIN' ? '' : sedes.map((s) => s['uuid']).join(',')),
              updatedAt: Value(DateTime.now().toUtc()),
            ),
          );

      await (_db.update(_db.estadoApp)..where((t) => t.id.equals(1))).write(
        EstadoAppCompanion(
          usuarioUuid: Value(usuario['uuid'] as String),
          dispositivoUuid: Value(dispositivo['uuid'] as String),
          prefijoFolio: Value((datos['dispositivo'] as Map?)?['prefijo_folio'] as String?),
          offlineValidoHasta: Value(valido),
          sedeActivaUuid: Value(sedeActiva ?? sedeAnterior),
          motivoCierreSesion: const Value(null),
        ),
      );
    });

    final sync = SyncDao(_db);
    await sync.registrarHoraServidor(datos['servidor_utc'] as String?);
    if (sedeActiva != null && sedeActiva != sedeAnterior) {
      await sync.proyectarSedeActiva(sedeActiva);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUltimoEmail, email);

    return ResultadoLogin.ok(
      Sesion(
        usuarioUuid: usuario['uuid'] as String,
        nombre: usuario['nombre'] as String,
        email: usuario['email'] as String,
        rol: RolUsuario.desde(usuario['rol'] as String?),
        enLinea: true,
        validaHasta: valido,
      ),
      necesitaDescargaInicial: esPrimeraVez,
    );
  }

  Future<ResultadoLogin> _loginOffline(String email, String password) async {
    final usuario = await (_db.select(_db.usuarios)
          ..where((t) => t.email.equals(email) & t.deletedAt.isNull()))
        .getSingleOrNull();

    if (usuario == null || usuario.passwordHashLocal == null || usuario.saltLocal == null) {
      return ResultadoLogin.error(
        'No hay conexión y este usuario nunca ha iniciado sesión en este '
        'dispositivo. Conéctate a internet la primera vez.',
      );
    }

    if (!usuario.activo) {
      return ResultadoLogin.error('La cuenta está desactivada');
    }

    final estado = await (_db.select(_db.estadoApp)..where((t) => t.id.equals(1))).getSingle();
    final limite = estado.offlineValidoHasta;
    if (limite != null && DateTime.now().toUtc().isAfter(limite)) {
      return ResultadoLogin.error(
        'Llevas demasiado tiempo sin conectarte. Conéctate a internet para '
        'seguir usando la app.',
      );
    }

    final valida = await PasswordHash.verificar(
      password,
      usuario.saltLocal!,
      usuario.passwordHashLocal!,
    );
    if (!valida) return ResultadoLogin.error('Correo o contraseña incorrectos');

    // Sin red no se le puede preguntar al servidor si está en su turno: se
    // decide con el horario que bajó la última vez y con un reloj en el que se
    // pueda confiar. Si el teléfono marca una hora anterior a la última que
    // vio del servidor, alguien lo atrasó: se exige conexión.
    if (!relojConfiable(ahora: DateTime.now(), ultimaHoraServidor: estado.horaServidor)) {
      return ResultadoLogin.error(
        'La hora del teléfono no coincide con la del servidor. Corrígela o conéctate a internet para entrar.',
      );
    }
    final jornada = evaluarUsuario(usuario, estado);
    if (!jornada.permitido) return ResultadoLogin.error(mensajeFueraDeHorario(jornada));

    final sede = _sedeParaOperar(usuario, estado.sedeActivaUuid);
    if (sede == null && usuario.rol != 'ADMIN') {
      return ResultadoLogin.error('Tu cuenta no tiene una sede asignada. Pide a tu gerente que te asigne una.');
    }

    await (_db.update(_db.estadoApp)..where((t) => t.id.equals(1))).write(
      EstadoAppCompanion(
        usuarioUuid: Value(usuario.uuid),
        sedeActivaUuid: sede == null ? const Value.absent() : Value(sede),
        motivoCierreSesion: const Value(null),
      ),
    );
    if (sede != null && sede != estado.sedeActivaUuid) {
      await SyncDao(_db).proyectarSedeActiva(sede);
    }

    return ResultadoLogin.ok(
      Sesion(
        usuarioUuid: usuario.uuid,
        nombre: usuario.nombre,
        email: usuario.email,
        rol: RolUsuario.desde(usuario.rol),
        enLinea: false,
        validaHasta: limite,
      ),
    );
  }

  Future<bool> _esDispositivoNuevo(String usuarioUuid) async {
    final n = await _db.customSelect(
      'SELECT COUNT(*) AS n FROM productos',
      readsFrom: {_db.productos},
    ).getSingle();
    return n.read<int>('n') == 0;
  }

  /// Restaura la sesión al abrir la app. No requiere red.
  Future<Sesion?> sesionGuardada() async {
    final estado =
        await (_db.select(_db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull();
    if (estado?.usuarioUuid == null) return null;

    final usuario = await (_db.select(_db.usuarios)
          ..where((t) => t.uuid.equals(estado!.usuarioUuid!)))
        .getSingleOrNull();
    if (usuario == null) return null;
    if (!usuario.activo) {
      await _cerrarConMotivo('Tu cuenta está inhabilitada. Habla con tu gerente.');
      return null;
    }
    final jornada = evaluarUsuario(usuario, estado);
    if (!jornada.permitido) {
      await _cerrarConMotivo(mensajeFueraDeHorario(jornada));
      return null;
    }

    _api.dispositivoUuid = estado!.dispositivoUuid;

    // Fuera de la ventana de gracia hay que volver a autenticarse con red.
    final limite = estado.offlineValidoHasta;
    if (limite != null && DateTime.now().toUtc().isAfter(limite)) {
      final refresh = await _tokens.refreshToken;
      if (refresh == null) return null;
    }

    return Sesion(
      usuarioUuid: usuario.uuid,
      nombre: usuario.nombre,
      email: usuario.email,
      rol: RolUsuario.desde(usuario.rol),
      enLinea: false,
      validaHasta: limite,
    );
  }

  /// Cierra sesión. `borrarDatos` sólo debería usarse al cambiar de negocio o
  /// de servidor: **destruye las ventas que no se hayan sincronizado**.
  /// Sede en la que opera el usuario: la suya si es de una sola; si gestiona
  /// varias, la que ya estaba activa en el teléfono si es suya, o la primera.
  String? _sedeParaOperar(Usuario u, String? actual) {
    if (u.rol == 'ADMIN') return actual;
    final suyas = u.sedes.split(',').where((s) => s.isNotEmpty).toList();
    if (suyas.isEmpty) return null;
    return suyas.contains(actual) ? actual : suyas.first;
  }

  Future<void> _marcarInactivo(String email) =>
      (_db.update(_db.usuarios)..where((t) => t.email.equals(email)))
          .write(const UsuariosCompanion(activo: Value(false)));

  /// Cierre forzado: conserva TODO (la cola incluida) y deja el motivo para
  /// que la pantalla de inicio lo explique.
  Future<void> _cerrarConMotivo(String motivo) async {
    await _tokens.limpiar();
    await (_db.update(_db.estadoApp)..where((t) => t.id.equals(1))).write(
      EstadoAppCompanion(usuarioUuid: const Value(null), motivoCierreSesion: Value(motivo)),
    );
  }

  /// Expulsión ordenada por la guardia de sesión (cuenta inhabilitada, fin de
  /// turno). Nunca borra datos: las ventas sin subir las sube el siguiente que
  /// entre en este teléfono, a nombre de quien las hizo.
  Future<void> expulsar(String motivo, {bool inhabilitado = false}) async {
    if (inhabilitado) {
      final estado = await (_db.select(_db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull();
      if (estado?.usuarioUuid != null) {
        await (_db.update(_db.usuarios)..where((t) => t.uuid.equals(estado!.usuarioUuid!)))
            .write(const UsuariosCompanion(activo: Value(false)));
      }
    }
    await _cerrarConMotivo(motivo);
  }

  /// Lee y borra el motivo del último cierre forzado.
  Future<String?> tomarMotivoCierre() async {
    final estado = await (_db.select(_db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull();
    final motivo = estado?.motivoCierreSesion;
    if (motivo != null) {
      await (_db.update(_db.estadoApp)..where((t) => t.id.equals(1)))
          .write(const EstadoAppCompanion(motivoCierreSesion: Value(null)));
    }
    return motivo;
  }

  /// Cambia la sede en la que opera el teléfono (gerente con varias sedes o
  /// director). Avisa al servidor si hay red; sin red, el cambio local basta,
  /// porque cada operación lleva su sede.
  Future<void> cambiarSedeActiva(String sedeUuid) async {
    await (_db.update(_db.estadoApp)..where((t) => t.id.equals(1)))
        .write(EstadoAppCompanion(sedeActivaUuid: Value(sedeUuid)));
    await SyncDao(_db).proyectarSedeActiva(sedeUuid);
    try {
      await _api.post('/auth/sede-activa', cuerpo: {'sede_uuid': sedeUuid});
    } catch (_) {
      // Sin red: el dispositivo informará su sede en el próximo login.
    }
  }

  Future<void> cerrarSesion({bool borrarDatos = false}) async {
    try {
      final refresh = await _tokens.refreshToken;
      if (refresh != null) {
        await _api.post('/auth/logout', cuerpo: {'refresh_token': refresh});
      }
    } catch (_) {
      // Sin red no se puede revocar en el servidor; el token caducará solo.
    }

    await _tokens.limpiar();
    await (_db.update(_db.estadoApp)..where((t) => t.id.equals(1)))
        .write(const EstadoAppCompanion(usuarioUuid: Value(null)));

    if (borrarDatos) {
      await _db.limpiarDatos();
      await (_db.update(_db.estadoApp)..where((t) => t.id.equals(1)))
          .write(const EstadoAppCompanion(secuenciaFolio: Value(0)));
    }
  }

  /// Cuántas operaciones se perderían al borrar los datos locales. Se enseña
  /// antes de confirmar un cierre de sesión destructivo.
  Future<int> operacionesSinEnviar() async {
    final fila = await _db.customSelect(
      "SELECT COUNT(*) AS n FROM sync_outbox WHERE estado IN ('PENDIENTE','ENVIANDO')",
      readsFrom: {_db.syncOutbox},
    ).getSingle();
    return fila.read<int>('n');
  }

  Future<String?> ultimoEmail() async =>
      (await SharedPreferences.getInstance()).getString(_kUltimoEmail);

  // ── Gestión de usuarios (ADMIN) ─────────────────────────────────────────
  //
  // Único rincón de la app que **exige conexión**. No es una omisión: crear una
  // cuenta sin poder comprobar que el correo no está repetido en el servidor
  // produciría dos usuarios distintos con el mismo correo en dos dispositivos,
  // y no hay forma sensata de resolver ese conflicto después. Las credenciales
  // las emite el servidor, siempre.

  Future<List<UsuarioAdmin>> listarUsuarios() async {
    final respuesta = await _api.get('/auth/usuarios');
    final datos = respuesta['data'] as List<dynamic>;
    return datos
        .map((u) => UsuarioAdmin.desdeJson(u as Map<String, dynamic>))
        .toList();
  }

  Future<void> crearUsuario({
    required String nombre,
    required String email,
    required String password,
    required RolUsuario rol,
    String? telefono,
    List<String> sedes = const [],
    bool restringirHorario = false,
    List<TramoHorario> horario = const [],
  }) async {
    await _api.post('/auth/usuarios', cuerpo: {
      'nombre': nombre,
      'email': email,
      'password': password,
      'rol': rol.api,
      if (telefono != null && telefono.isNotEmpty) 'telefono': telefono,
      'sedes': sedes,
      'restringir_horario': restringirHorario,
      'horario': [for (final t in horario) t.toJson()],
    });
  }

  Future<void> actualizarUsuario(
    String uuid, {
    String? nombre,
    String? email,
    RolUsuario? rol,
    bool? activo,
    String? password,
    List<String>? sedes,
    bool? restringirHorario,
    List<TramoHorario>? horario,
  }) async {
    await _api.patch('/auth/usuarios/$uuid', cuerpo: {
      // Sólo viajan los campos que cambian: un PATCH con nulos borraría datos.
      'nombre': ?nombre,
      'email': ?email,
      'rol': ?rol?.api,
      'activo': ?activo,
      if (password != null && password.isNotEmpty) 'password': password,
      'sedes': ?sedes,
      'restringir_horario': ?restringirHorario,
      if (horario != null) 'horario': [for (final t in horario) t.toJson()],
    });
  }

  /// Deja entrar a alguien fuera de su horario hasta [hasta] (máximo 24 h).
  /// Nunca acorta un acceso extra ya vigente; para eso está [revocarAccesoExtra].
  Future<void> otorgarAccesoExtra(String uuid, {required DateTime hasta, String? motivo}) async {
    await _api.post('/auth/usuarios/$uuid/acceso-extra', cuerpo: {
      'hasta': hasta.toUtc().toIso8601String(),
      if (motivo != null && motivo.isNotEmpty) 'motivo': motivo,
    });
  }

  Future<void> revocarAccesoExtra(String uuid) => _api.delete('/auth/usuarios/$uuid/acceso-extra');

  /// Baja lógica. El servidor protege al último administrador.
  Future<void> eliminarUsuario(String uuid) => _api.delete('/auth/usuarios/$uuid');

  Future<void> cambiarPassword(String actual, String nueva) async {
    await _api.post(
      '/auth/password',
      cuerpo: {'password_actual': actual, 'password_nueva': nueva},
    );

    // Se regenera el derivado local: si no, el login offline seguiría aceptando
    // la contraseña vieja.
    final estado = await (_db.select(_db.estadoApp)..where((t) => t.id.equals(1))).getSingle();
    if (estado.usuarioUuid != null) {
      final salt = PasswordHash.generarSalt();
      final hash = await PasswordHash.derivar(nueva, salt);
      await (_db.update(_db.usuarios)..where((t) => t.uuid.equals(estado.usuarioUuid!)))
          .write(UsuariosCompanion(
        passwordHashLocal: Value(hash),
        saltLocal: Value(salt),
      ));
    }
  }
}
