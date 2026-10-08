import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/providers.dart';
import '../data/auth_repository.dart';
import '../domain/sesion.dart';
import 'guardia_sesion.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    db: ref.watch(appDatabaseProvider),
    api: ref.watch(apiClientProvider),
    tokens: ref.watch(tokenStoreProvider),
  );
});

/// Aviso de fin de turno: a qué hora termina, cuando faltan 15 minutos o
/// menos. null = sin aviso. Lo muestra el inicio («haz tu cierre de caja»).
class AvisoTurno extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void fijar(DateTime? hasta) => state = hasta;
}

final avisoTurnoProvider = NotifierProvider<AvisoTurno, DateTime?>(AvisoTurno.new);

/// Sesión actual. `null` = no autenticado.
///
/// Se resuelve **sin red**: lee el usuario guardado en SQLite. Abrir la app en
/// modo avión debe llevar directamente al dashboard, no a una pantalla de carga
/// esperando un servidor que no está.
///
/// Mientras hay sesión, una `GuardiaSesion` la vigila: la cierra si el
/// servidor inhabilita la cuenta o si termina el turno.
class SesionNotifier extends AsyncNotifier<Sesion?> {
  GuardiaSesion? _guardia;

  @override
  Future<Sesion?> build() async {
    ref.onDispose(() => _guardia?.detener());
    final repo = ref.watch(authRepositoryProvider);
    final sesion = await repo.sesionGuardada();

    if (sesion != null) {
      // Arrancar el motor aquí y no en `main()` evita sincronizar cuando no hay
      // nadie autenticado.
      await ref.read(syncEngineProvider).iniciar();
      _vigilar(sesion);
    }
    return sesion;
  }

  void _vigilar(Sesion sesion) {
    _guardia ??= GuardiaSesion(
      db: ref.read(appDatabaseProvider),
      api: ref.read(apiClientProvider),
      alExpulsar: _expulsar,
      alAvisar: (hasta) => ref.read(avisoTurnoProvider.notifier).fijar(hasta),
      sincronizarFinal: () => ref.read(syncEngineProvider).sincronizar(motivo: 'fin de turno', forzar: true),
    );
    _guardia!.iniciar(sesion.usuarioUuid);
  }

  Future<void> _expulsar(String motivo, {bool inhabilitado = false}) async {
    _guardia?.detener();
    await ref.read(authRepositoryProvider).expulsar(motivo, inhabilitado: inhabilitado);
    state = const AsyncValue.data(null);
  }

  Future<ResultadoLogin> iniciarSesion(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final resultado = await ref.read(authRepositoryProvider).iniciarSesion(email, password);

      if (!resultado.exito) {
        state = AsyncValue.data(null);
        return resultado;
      }

      state = AsyncValue.data(resultado.sesion);

      final motor = ref.read(syncEngineProvider);
      await motor.iniciar();
      _vigilar(resultado.sesion!);
      if (resultado.necesitaDescargaInicial) {
        // Primera vez en este dispositivo: hay que traer el catálogo antes de
        // poder vender. Se deja en segundo plano; la UI muestra el progreso.
        unawaited(motor.descargaInicial());
      } else {
        // Con otro usuario pueden cambiar las sedes visibles: se sincroniza ya
        // para que el alcance se ajuste antes de que empiece a trabajar.
        unawaited(motor.sincronizar(motivo: 'inicio de sesión'));
      }

      return resultado;
    } catch (e, s) {
      state = AsyncValue.error(e, s);
      rethrow;
    }
  }

  Future<void> cerrarSesion({bool borrarDatos = false}) async {
    _guardia?.detener();
    await ref.read(authRepositoryProvider).cerrarSesion(borrarDatos: borrarDatos);
    state = const AsyncValue.data(null);
  }
}

final sesionProvider =
    AsyncNotifierProvider<SesionNotifier, Sesion?>(SesionNotifier.new);

/// Rol efectivo. Ante la duda, el rol más restrictivo: si algo falla al leer la
/// sesión, es preferible ocultar los costos que enseñarlos por accidente.
final rolProvider = Provider<RolUsuario>((ref) {
  return ref.watch(sesionProvider).maybeWhen(
        data: (s) => s?.rol ?? RolUsuario.vendedor,
        orElse: () => RolUsuario.vendedor,
      );
});

/// Director o gerente: catálogo, costos, reportes y personal.
final esGestorProvider = Provider<bool>((ref) => ref.watch(rolProvider).esGestor);

/// Sólo el Director General: sedes, datos del negocio, todo el negocio.
final esDirectorProvider = Provider<bool>((ref) => ref.watch(rolProvider).esDirector);
