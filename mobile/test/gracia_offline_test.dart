import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/features/auth/domain/sesion.dart';

/// El reloj se inyecta: un test que lee `DateTime.now()` dos veces ya rompió
/// una build de CI por milisegundos.
void main() {
  final ahora = DateTime.utc(2026, 9, 21, 12);

  test('recién sincronizado: siete días y sin aviso', () {
    final limite = ahora.add(const Duration(days: 7));
    expect(diasDeGraciaRestantes(limite, ahora: ahora), 7);
    expect(debeAvisarCaducidad(limite, ahora: ahora), isFalse);
  });

  test('a un día del límite se avisa', () {
    final limite = ahora.add(const Duration(days: 1, hours: 3));
    expect(diasDeGraciaRestantes(limite, ahora: ahora), 1);
    expect(debeAvisarCaducidad(limite, ahora: ahora), isTrue);
  });

  test('pasado el límite es 0, nunca negativo, y se avisa', () {
    final limite = ahora.subtract(const Duration(days: 5));
    expect(diasDeGraciaRestantes(limite, ahora: ahora), 0);
    expect(debeAvisarCaducidad(limite, ahora: ahora), isTrue);
  });

  test('sin límite registrado no hay aviso', () {
    expect(diasDeGraciaRestantes(null, ahora: ahora), isNull);
    expect(debeAvisarCaducidad(null, ahora: ahora), isFalse);
  });
}
