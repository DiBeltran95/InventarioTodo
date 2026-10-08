import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_client.dart';
import '../domain/jornada_usuario.dart';

/// Vigila que la sesión siga siendo válida mientras la app está abierta.
///
/// Tres vías la pueden cerrar:
///
///  1. **El servidor** responde que la cuenta está inhabilitada, que está fuera
///     de turno o que la sesión fue revocada (`ApiClient.alPerderSesion`).
///  2. **La sincronización** baja la fila del usuario con `activo = false`.
///  3. **El reloj**: al terminar el turno. Avisa 15 minutos antes —para que
///     dé tiempo a cerrar la caja—, y al llegar intenta un último envío y
///     cierra. Funciona sin red, con el horario que bajó la última vez.
///
/// Cerrar la sesión NUNCA borra datos: lo que quede en la cola lo sube el
/// siguiente que entre en el teléfono, a nombre de quien lo hizo.
class GuardiaSesion with WidgetsBindingObserver {
  GuardiaSesion({
    required this.db,
    required this.api,
    required this.alExpulsar,
    required this.alAvisar,
    required this.sincronizarFinal,
  });

  final AppDatabase db;
  final ApiClient api;

  /// Cierra la sesión con un motivo para la pantalla de inicio.
  final Future<void> Function(String motivo, {bool inhabilitado}) alExpulsar;

  /// Aviso de fin de turno: la hora a la que termina, o null para quitarlo.
  final void Function(DateTime? hasta) alAvisar;

  /// Último intento de subir la cola antes de cerrar por fin de turno.
  final Future<void> Function() sincronizarFinal;

  static const anticipacionAviso = Duration(minutes: 15);

  String? _usuarioUuid;
  StreamSubscription<Usuario?>? _subUsuario;
  Timer? _temporizadorAviso;
  Timer? _temporizadorFin;
  bool _cerrando = false;

  void iniciar(String usuarioUuid) {
    detener();
    _usuarioUuid = usuarioUuid;
    _cerrando = false;
    api.alPerderSesion = _porServidor;
    WidgetsBinding.instance.addObserver(this);
    _subUsuario = (db.select(db.usuarios)..where((t) => t.uuid.equals(usuarioUuid)))
        .watchSingleOrNull()
        .listen((u) => unawaited(_evaluar(u)));
  }

  void detener() {
    _subUsuario?.cancel();
    _subUsuario = null;
    _temporizadorAviso?.cancel();
    _temporizadorFin?.cancel();
    if (_usuarioUuid != null) WidgetsBinding.instance.removeObserver(this);
    _usuarioUuid = null;
    api.alPerderSesion = null;
    alAvisar(null);
  }

  void _porServidor(String codigo, String mensaje) {
    final motivo = switch (codigo) {
      'CUENTA_DESACTIVADA' => 'Tu cuenta fue inhabilitada. Habla con tu gerente.',
      'USUARIO_INEXISTENTE' => 'Tu cuenta ya no existe. Habla con tu gerente.',
      'FUERA_DE_HORARIO' => mensaje.isNotEmpty ? mensaje : 'Tu turno terminó.',
      'SIN_SEDE' => mensaje.isNotEmpty ? mensaje : 'Tu cuenta no tiene sede asignada.',
      _ => 'Tu sesión venció. Vuelve a entrar con tu contraseña.',
    };
    unawaited(_expulsar(
      motivo,
      inhabilitado: codigo == 'CUENTA_DESACTIVADA' || codigo == 'USUARIO_INEXISTENTE',
    ));
  }

  Future<void> _reevaluar() async {
    final uuid = _usuarioUuid;
    if (uuid == null) return;
    final u = await (db.select(db.usuarios)..where((t) => t.uuid.equals(uuid))).getSingleOrNull();
    await _evaluar(u);
  }

  Future<void> _evaluar(Usuario? u) async {
    _temporizadorAviso?.cancel();
    _temporizadorFin?.cancel();
    if (u == null || _cerrando) return;

    if (!u.activo) {
      await _expulsar('Tu cuenta fue inhabilitada. Habla con tu gerente.', inhabilitado: true);
      return;
    }

    final estado = await (db.select(db.estadoApp)..where((t) => t.id.equals(1))).getSingleOrNull();
    final e = evaluarUsuario(u, estado);
    if (!e.permitido) {
      await _finDeTurno(mensajeFueraDeHorario(e));
      return;
    }

    final hasta = e.hasta;
    if (hasta == null) {
      alAvisar(null);
      return;
    }

    final falta = hasta.difference(ahoraCorregido(estado));
    final faltaAviso = falta - anticipacionAviso;
    if (faltaAviso <= Duration.zero) {
      alAvisar(hasta);
    } else {
      alAvisar(null);
      _temporizadorAviso = Timer(faltaAviso, () => alAvisar(hasta));
    }
    // Al llegar la hora se vuelve a evaluar —y no se cierra a ciegas—: el
    // gerente pudo haber dado acceso extra entretanto.
    _temporizadorFin = Timer(falta + const Duration(seconds: 1), () => unawaited(_reevaluar()));
  }

  Future<void> _finDeTurno(String motivo) async {
    if (_cerrando) return;
    _cerrando = true;
    try {
      await sincronizarFinal().timeout(const Duration(seconds: 20));
    } catch (_) {
      // Sin red o lento: la cola se queda en el teléfono y la sube quien entre.
    }
    await alExpulsar(motivo);
  }

  Future<void> _expulsar(String motivo, {bool inhabilitado = false}) async {
    if (_cerrando) return;
    _cerrando = true;
    await alExpulsar(motivo, inhabilitado: inhabilitado);
  }

  /// En segundo plano los temporizadores se congelan: al volver se re-evalúa
  /// con la hora real.
  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado == AppLifecycleState.resumed) unawaited(_reevaluar());
  }
}
