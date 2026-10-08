import '../../features/auth/domain/sesion.dart';
import '../money/money.dart';

/// Reglas de los traslados entre sedes, igual que en el servidor
/// (backend/src/domain/traslados.js). La app las usa para mostrar sólo los
/// botones que van a funcionar; la decisión final la toma el servidor.
///
///   · VER en qué sedes hay un producto: todos.
///   · SOLICITAR unidades: el Gerente de Sede, para una sede suya y desde otra.
///   · DESPACHAR o RECHAZAR una solicitud: el Director General o el Auxiliar
///     de Inventario de la sede de origen, con las unidades que decida.
///   · MOVER directamente: el director entre cualesquiera sedes; el auxiliar,
///     desde la suya.
///   · CANCELAR una solicitud pendiente: quien la pidió o el director.

/// Usuario que mira el traslado: su rol y las sedes que ve (null = todas).
class Actor {
  const Actor({required this.uuid, required this.rol, this.sedes});

  final String uuid;
  final RolUsuario rol;
  final Set<String>? sedes;

  bool ve(String sedeUuid) => sedes == null || sedes!.contains(sedeUuid);
}

/// Motivo por el que no puede SOLICITAR unidades de [origen] para [destino].
String? motivoNoPuedeSolicitar(Actor actor, String origen, String destino) {
  if (actor.rol != RolUsuario.gerente) {
    return actor.rol.mueveEntreSedes
        ? 'Tú mueves las unidades directamente: no necesitas solicitarlas'
        : 'Sólo un gerente de sede solicita unidades a otra sede';
  }
  if (origen == destino) return 'La sede de origen y la de destino deben ser distintas';
  if (!actor.ve(destino)) return 'Sólo puedes solicitar unidades para una sede tuya';
  return null;
}

/// Motivo por el que no puede MOVER unidades directamente.
String? motivoNoPuedeMover(Actor actor, String origen, String destino) {
  if (origen == destino) return 'La sede de origen y la de destino deben ser distintas';
  if (actor.rol.esDirector) return null;
  if (actor.rol == RolUsuario.auxiliarInventario) {
    return actor.ve(origen) ? null : 'Sólo puedes enviar unidades desde tu sede';
  }
  return 'Mueven unidades entre sedes el Director General o el auxiliar de inventario de la sede';
}

/// Motivo por el que no puede despachar o rechazar esta solicitud, o null.
String? motivoNoPuedeDespachar({required String estado, required String sedeOrigen, required Actor actor}) {
  if (estado != 'PENDIENTE') return 'El traslado ya fue resuelto';
  if (actor.rol.esDirector) return null;
  if (actor.rol == RolUsuario.auxiliarInventario && actor.ve(sedeOrigen)) return null;
  return 'Lo despacha el auxiliar de inventario de la sede de origen o el Director General';
}

String? motivoNoPuedeCancelar({
  required String estado,
  required String? solicitadoPor,
  required Actor actor,
}) {
  if (estado != 'PENDIENTE') return 'El traslado ya fue resuelto';
  if (solicitadoPor == actor.uuid || actor.rol.esDirector) return null;
  return 'Sólo quien lo pidió puede cancelarlo';
}

/// Lo que sale por línea al despachar: [enviadas] (uuid de línea → cantidad)
/// manda; una línea ausente sale completa. Se puede enviar menos —o nada de
/// una línea— pero algo tiene que salir: despachar cero es un rechazo.
///
/// Devuelve el motivo del error, o null si el reparto vale.
String? motivoRepartoInvalido(Map<String, Cantidad> pedidas, Map<String, Cantidad> enviadas) {
  var total = 0;
  for (final e in pedidas.entries) {
    final enviada = enviadas[e.key] ?? e.value;
    if (enviada.esNegativa) return 'Una cantidad enviada no puede ser negativa';
    total += enviada.milesimas;
  }
  if (total <= 0) return 'No se envía ninguna unidad: si no se puede atender, recházalo';
  return null;
}
