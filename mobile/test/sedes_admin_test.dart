import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/features/sedes/data/gestion_api.dart';

void main() {
  test('las sedes dicen en qué app se usan', () {
    final s = SedeAdmin.desdeJson({
      'uuid': 'a', 'nombre': 'Norte', 'codigo': 'NOR', 'elegida': 0, 'elegida_presente': 1, 'activo': 1,
    });
    expect(s.elegida, isFalse);
    expect(s.elegidaPresente, isTrue);
    // El listado de siempre (solo las de Ventario) no trae el campo: ya están elegidas.
    final vieja = SedeAdmin.desdeJson({'uuid': 'b', 'nombre': 'Centro', 'codigo': 'CEN'});
    expect(vieja.elegida, isTrue);
    expect(vieja.elegidaPresente, isNull);
  });
}
