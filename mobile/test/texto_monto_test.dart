import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/money/money.dart';
import 'package:inventario_pos/features/ventas/presentation/widgets/hoja_cobro.dart';

/// Los atajos de importe escriben en el mismo campo que teclea el vendedor, y
/// ese campo se lee quitando separadores. Si el atajo escribiera «23.400», al
/// releerlo saldría 23.400 pesos… o 23,4, según el separador. De ahí que se
/// pruebe el ida y vuelta.
void main() {
  group('textoDeMonto', () {
    test('sin separadores de miles', () {
      expect(textoDeMonto(const Money(2340000)), '23400');
    });

    test('omite los decimales cuando no los hay', () {
      expect(textoDeMonto(const Money(100000)), '1000');
    });

    test('conserva los centavos cuando existen', () {
      expect(textoDeMonto(const Money(150050)), '1500.50');
    });

    test('el campo vuelve a leer el mismo importe', () {
      for (final centavos in [100000, 2340000, 150050, 1]) {
        final valor = Money(centavos);
        expect(Money.tryParse(textoDeMonto(valor)), valor);
      }
    });
  });
}
