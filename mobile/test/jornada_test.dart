import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/negocio/jornada.dart';

/// Los casos son los MISMOS que ejecuta el servidor
/// (backend/tests/jornada.test.mjs): un único archivo, dos implementaciones.
/// Si alguna de las dos cambia la regla sin la otra, falla aquí o allá.
void main() {
  final doc = jsonDecode(File('../shared/jornada_casos.json').readAsStringSync()) as Map<String, dynamic>;
  final desfase = Duration(minutes: (doc['desfaseMinutos'] as num).toInt());
  final casos = (doc['casos'] as List).cast<Map<String, dynamic>>();

  const motivos = {
    'SIN_RESTRICCION': MotivoJornada.sinRestriccion,
    'EN_TURNO': MotivoJornada.enTurno,
    'ACCESO_EXTRA': MotivoJornada.accesoExtra,
    'FUERA_DE_HORARIO': MotivoJornada.fueraDeHorario,
  };

  for (final caso in casos) {
    test(caso['nombre'] as String, () {
      final j = caso['jornada'] as Map<String, dynamic>;
      final jornada = Jornada(
        restringir: j['restringir'] as bool,
        horario: (j['horario'] as List).cast<Map<String, dynamic>>().map(TramoHorario.desdeJson).toList(),
        accesoExtraHasta: j['accesoExtraHasta'] == null ? null : DateTime.parse(j['accesoExtraHasta'] as String),
      );
      final r = evaluarJornada(jornada, DateTime.parse(caso['ahora'] as String), desfase);
      final e = caso['esperado'] as Map<String, dynamic>;

      expect(r.permitido, e['permitido']);
      expect(r.motivo, motivos[e['motivo']]);
      expect(r.hasta?.toUtc(), e['hasta'] == null ? isNull : DateTime.parse(e['hasta'] as String));
      expect(
        r.proximoInicio?.toUtc(),
        e['proximoInicio'] == null ? isNull : DateTime.parse(e['proximoInicio'] as String),
      );
    });
  }

  test('un horario ilegible guardado se trata como vacío, sin lanzar', () {
    expect(leerHorario('{esto no es json'), isEmpty);
    expect(leerHorario('[{"dia":9,"inicio":"08:00","fin":"17:00"}]'), isEmpty);
  });

  test('el horario se escribe y se vuelve a leer igual', () {
    const tramos = [
      TramoHorario(dia: 5, inicio: '18:00', fin: '02:00'),
      TramoHorario(dia: 1, inicio: '08:00', fin: '17:00'),
    ];
    final leido = leerHorario(escribirHorario(tramos));
    expect(leido, [tramos[1], tramos[0]], reason: 'se ordena por día');
    expect(leido.last.nocturno, isTrue);
  });

  group('reloj del teléfono', () {
    final servidor = DateTime.utc(2026, 10, 8, 15);

    test('unos minutos atrasado por desajuste normal es aceptable', () {
      expect(relojConfiable(ahora: servidor.subtract(const Duration(minutes: 3)), ultimaHoraServidor: servidor), isTrue);
    });

    test('atrasado a propósito para entrar fuera de turno no lo es', () {
      expect(relojConfiable(ahora: servidor.subtract(const Duration(hours: 5)), ultimaHoraServidor: servidor), isFalse);
    });

    test('sin hora del servidor todavía, no se puede juzgar', () {
      expect(relojConfiable(ahora: DateTime.utc(2000), ultimaHoraServidor: null), isTrue);
    });
  });
}
