import '../../features/auth/domain/sesion.dart';

/// Reglas de los traslados entre sedes, igual que en el servidor
/// (backend/src/domain/traslados.js). La app las usa para mostrar sólo los
/// botones que van a funcionar; la decisión final la toma el servidor.
///
/// Siempre confirma «la otra parte», nunca quien lo pidió:
///   · Lo pide un empleado → lo aprueba un gestor de la sede origen.
///   · Lo pide un gestor → lo confirma alguien de la sede origen.

/// Usuario que mira el traslado: su rol y las sedes que ve (null = todas).
class Actor {
  const Actor({required this.uuid, required this.rol, this.sedes});

  final String uuid;
  final RolUsuario rol;
  final Set<String>? sedes;

  bool ve(String sedeUuid) => sedes == null || sedes!.contains(sedeUuid);
}

/// 'ORIGEN' si lo pide un gestor, 'GESTOR' si lo pide un empleado.
String quienConfirma(RolUsuario rolCreador) => rolCreador.esGestor ? 'ORIGEN' : 'GESTOR';

/// Motivo por el que no puede crear un traslado entre estas sedes, o null.
String? motivoNoPuedeCrear(Actor actor, String origen, String destino) {
  if (!actor.rol.pideTraslados) return 'Tu rol no puede pedir traslados';
  if (origen == destino) return 'La sede de origen y la de destino deben ser distintas';
  if (!actor.ve(origen) && !actor.ve(destino)) {
    return 'Sólo puedes pedir traslados desde o hacia una sede tuya';
  }
  return null;
}

/// Motivo por el que no puede aprobar o rechazar, o null si puede.
String? motivoNoPuedeResolver({
  required String estado,
  required String confirma,
  required String sedeOrigen,
  required String? solicitadoPor,
  required Actor actor,
}) {
  if (estado != 'PENDIENTE') return 'El traslado ya fue resuelto';
  if (solicitadoPor == actor.uuid) return 'Un traslado lo confirma otra persona, no quien lo pidió';
  if (!actor.ve(sedeOrigen)) return 'Lo confirma alguien de la sede de origen';
  if (confirma == 'GESTOR' && !actor.rol.esGestor) {
    return 'Este traslado lo pidió un empleado: lo aprueba el gerente de la sede o el director';
  }
  if (confirma == 'ORIGEN' && !actor.rol.pideTraslados) return 'Tu rol no puede confirmar traslados';
  return null;
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
