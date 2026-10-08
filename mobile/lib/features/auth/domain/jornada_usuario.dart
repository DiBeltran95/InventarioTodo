import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/negocio/jornada.dart';
import '../../../core/utils/fechas.dart';

/// Jornada de un usuario tal como está guardada en el teléfono.
///
/// El Director General nunca queda restringido por horario, aunque la fila lo
/// diga: igual que en el servidor, un horario mal puesto no puede dejar al
/// dueño fuera de su propio negocio.
Jornada jornadaDeUsuario(Usuario u) => Jornada(
      restringir: u.rol != 'ADMIN' && u.restringirHorario,
      horario: leerHorario(u.horario),
      accesoExtraHasta: u.accesoExtraHasta,
    );

/// Hora «real» según el servidor: la del teléfono corregida con el desfase
/// medido en la última sincronización.
DateTime ahoraCorregido(EstadoAppData? estado) =>
    DateTime.now().toUtc().add(Duration(milliseconds: estado?.desfaseServidorMs ?? 0));

EvaluacionJornada evaluarUsuario(Usuario u, EstadoAppData? estado) =>
    evaluarJornada(jornadaDeUsuario(u), ahoraCorregido(estado), AppConfig.desfaseNegocio);

String mensajeFueraDeHorario(EvaluacionJornada e) {
  final proximo = e.proximoInicio;
  return proximo == null
      ? 'Estás fuera de tu horario de trabajo. Pide a tu gerente que te dé acceso.'
      : 'Estás fuera de tu horario de trabajo. Puedes volver a entrar el '
          '${Fechas.formatFechaHora(proximo)}.';
}
