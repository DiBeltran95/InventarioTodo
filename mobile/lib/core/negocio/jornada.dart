import 'dart:convert';

/// Jornada laboral: ¿puede trabajar este usuario ahora, y hasta cuándo?
///
/// Es la MISMA regla que aplica el servidor (backend/src/domain/jornada.js) y
/// se prueba con los mismos casos (shared/jornada_casos.json). Tienen que
/// coincidir: si el servidor deja entrar a alguien que la app expulsa —o al
/// revés—, el empleado ve un cierre de sesión que nadie sabe explicar.
///
/// Horario: tramos `{dia, inicio, fin}`.
///   · dia 1 = lunes … 7 = domingo.
///   · inicio/fin 'HH:MM' en la hora del negocio.
///   · fin <= inicio → turno que cruza la medianoche.
///   · fin es EXCLUSIVO.
/// Tramos contiguos o solapados se encadenan en un solo turno.
class TramoHorario {
  const TramoHorario({required this.dia, required this.inicio, required this.fin});

  factory TramoHorario.desdeJson(Map<String, dynamic> j) => TramoHorario(
        dia: (j['dia'] as num).toInt(),
        inicio: j['inicio'] as String,
        fin: j['fin'] as String,
      );

  final int dia;
  final String inicio;
  final String fin;

  Map<String, dynamic> toJson() => {'dia': dia, 'inicio': inicio, 'fin': fin};

  static final _hhmm = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

  bool get esValido => dia >= 1 && dia <= 7 && _hhmm.hasMatch(inicio) && _hhmm.hasMatch(fin) && inicio != fin;

  /// Cruza la medianoche: el viernes 18:00–02:00 termina el sábado.
  bool get nocturno => minutos(fin) <= minutos(inicio);

  static int minutos(String hhmm) {
    final m = _hhmm.firstMatch(hhmm)!;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

  @override
  bool operator ==(Object other) =>
      other is TramoHorario && other.dia == dia && other.inicio == inicio && other.fin == fin;

  @override
  int get hashCode => Object.hash(dia, inicio, fin);
}

/// Lee el horario guardado (texto JSON) sin lanzar: uno ilegible cuenta como
/// vacío, que con la restricción activa equivale a «sin turno».
List<TramoHorario> leerHorario(String? texto) {
  if (texto == null || texto.isEmpty) return const [];
  try {
    final lista = jsonDecode(texto);
    if (lista is! List) return const [];
    final tramos = lista
        .whereType<Map<String, dynamic>>()
        .map(TramoHorario.desdeJson)
        .where((t) => t.esValido)
        .toList()
      ..sort((a, b) => a.dia != b.dia ? a.dia.compareTo(b.dia) : a.inicio.compareTo(b.inicio));
    return tramos;
  } catch (_) {
    return const [];
  }
}

String escribirHorario(List<TramoHorario> tramos) => jsonEncode(tramos.map((t) => t.toJson()).toList());

class Jornada {
  const Jornada({required this.restringir, this.horario = const [], this.accesoExtraHasta});

  final bool restringir;
  final List<TramoHorario> horario;
  final DateTime? accesoExtraHasta;
}

enum MotivoJornada { sinRestriccion, enTurno, accesoExtra, fueraDeHorario }

class EvaluacionJornada {
  const EvaluacionJornada({
    required this.permitido,
    required this.motivo,
    this.hasta,
    this.proximoInicio,
  });

  final bool permitido;
  final MotivoJornada motivo;

  /// Hasta cuándo puede seguir (fin del turno o del acceso extra).
  final DateTime? hasta;

  /// Cuándo empieza su próximo turno.
  final DateTime? proximoInicio;
}

/// @param ahora    instante (UTC)
/// @param desfase  hora del negocio − UTC (Bogotá: −5 h). Colombia no tiene
///                 horario de verano, así que un desfase fijo es exacto.
EvaluacionJornada evaluarJornada(Jornada jornada, DateTime ahora, Duration desfase) {
  if (!jornada.restringir) {
    return const EvaluacionJornada(permitido: true, motivo: MotivoJornada.sinRestriccion);
  }

  final t = ahora.toUtc();
  final local = t.add(desfase);
  int diaSemana(int k) => ((local.weekday - 1 + k) % 7 + 7) % 7 + 1;
  DateTime instante(int k, int minutos) =>
      DateTime.utc(local.year, local.month, local.day + k).add(Duration(minutes: minutos)).subtract(desfase);

  // Desde ayer (un turno de noche que empezó ayer puede seguir) hasta una
  // semana adelante (para saber cuándo empieza el próximo).
  final ventanas = <({DateTime inicio, DateTime fin})>[];
  for (var k = -1; k <= 7; k++) {
    for (final tramo in jornada.horario) {
      if (tramo.dia != diaSemana(k)) continue;
      final ini = TramoHorario.minutos(tramo.inicio);
      final fin = TramoHorario.minutos(tramo.fin);
      ventanas.add((
        inicio: instante(k, ini),
        fin: fin > ini ? instante(k, fin) : instante(k + 1, fin),
      ));
    }
  }
  ventanas.sort((a, b) => a.inicio.compareTo(b.inicio));

  DateTime? hasta;
  for (final v in ventanas) {
    if (!v.inicio.isAfter(t) && t.isBefore(v.fin)) {
      if (hasta == null || v.fin.isAfter(hasta)) hasta = v.fin;
    }
  }
  // Encadena tramos contiguos o solapados.
  if (hasta != null) {
    var cambio = true;
    while (cambio) {
      cambio = false;
      for (final v in ventanas) {
        if (!v.inicio.isAfter(hasta!) && v.fin.isAfter(hasta)) {
          hasta = v.fin;
          cambio = true;
        }
      }
    }
  }

  final referencia = hasta ?? t;
  DateTime? proximo;
  for (final v in ventanas) {
    if (v.inicio.isAfter(referencia)) {
      proximo = v.inicio;
      break;
    }
  }

  final extra = jornada.accesoExtraHasta?.toUtc();
  final extraVigente = extra != null && extra.isAfter(t) ? extra : null;

  if (hasta != null) {
    return EvaluacionJornada(
      permitido: true,
      motivo: MotivoJornada.enTurno,
      hasta: extraVigente != null && extraVigente.isAfter(hasta) ? extraVigente : hasta,
      proximoInicio: proximo,
    );
  }
  if (extraVigente != null) {
    return EvaluacionJornada(
      permitido: true,
      motivo: MotivoJornada.accesoExtra,
      hasta: extraVigente,
      proximoInicio: proximo,
    );
  }
  return EvaluacionJornada(
    permitido: false,
    motivo: MotivoJornada.fueraDeHorario,
    proximoInicio: proximo,
  );
}

/// ¿Es confiable el reloj del teléfono?
///
/// Si marca una hora ANTERIOR a la última que vio del servidor (con un margen
/// por desajustes normales), alguien lo atrasó: puede ser un error, o un
/// intento de trabajar fuera de turno sin red. En ese caso se exige conexión.
bool relojConfiable({required DateTime ahora, DateTime? ultimaHoraServidor}) {
  if (ultimaHoraServidor == null) return true;
  return !ahora.toUtc().isBefore(ultimaHoraServidor.toUtc().subtract(const Duration(minutes: 10)));
}
