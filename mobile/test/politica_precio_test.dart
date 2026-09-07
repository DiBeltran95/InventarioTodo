import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/money/money.dart';
import 'package:inventario_pos/features/inventario/domain/politica_precio.dart';

/// El proveedor no siempre vende al mismo precio: hoy una caja llega a un
/// costo y mañana a otro. Al reponer stock se puede repercutir esa subida al
/// precio de venta, pero **sólo si el usuario lo cambia de verdad**.
///
/// Encolar un cambio de catálogo en cada entrada rutinaria movería el
/// `updated_at` del producto, y ése es el campo que decide quién gana en un
/// conflicto: una reposición podría pisar un cambio de precio hecho desde otro
/// dispositivo. Por eso la regla se fija aquí.
void main() {
  final original = Money.parse('10000.00');

  group('Cuándo se actualiza el precio de venta', () {
    test('se actualiza si la reposición trae un precio distinto', () {
      final nuevo = Money.parse('12000.00');
      expect(
        precioAActualizar(tipo: 'ENTRADA', tecleado: nuevo, original: original),
        nuevo,
      );
    });

    test('NO se actualiza si el precio es el mismo', () {
      expect(
        precioAActualizar(
          tipo: 'ENTRADA',
          tecleado: Money.parse('10000.00'),
          original: original,
        ),
        isNull,
        reason: 'encolaría una operación que no cambia nada',
      );
    });

    test('NO se actualiza si el campo se dejó vacío', () {
      expect(
        precioAActualizar(tipo: 'ENTRADA', tecleado: null, original: original),
        isNull,
      );
    });

    test('también baja el precio, no sólo sube', () {
      // Una promoción del proveedor es tan válida como una subida.
      final rebaja = Money.parse('8000.00');
      expect(
        precioAActualizar(tipo: 'ENTRADA', tecleado: rebaja, original: original),
        rebaja,
      );
    });

    test('sirve para un producto que aún no tenía precio', () {
      final primero = Money.parse('5000.00');
      expect(
        precioAActualizar(tipo: 'ENTRADA', tecleado: primero, original: null),
        primero,
      );
    });
  });

  group('Movimientos que NO repercuten precio', () {
    test('una merma no cambia el precio de venta', () {
      expect(
        precioAActualizar(
          tipo: 'MERMA',
          tecleado: Money.parse('99000.00'),
          original: original,
        ),
        isNull,
      );
    });

    test('una devolución tampoco', () {
      expect(
        precioAActualizar(
          tipo: 'DEVOLUCION',
          tecleado: Money.parse('99000.00'),
          original: original,
        ),
        isNull,
      );
    });
  });

  test('un precio negativo nunca se guarda', () {
    expect(
      precioAActualizar(
        tipo: 'ENTRADA',
        tecleado: const Money(-500),
        original: original,
      ),
      isNull,
    );
  });
}
