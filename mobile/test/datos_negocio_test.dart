import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/config/datos_negocio.dart';
import 'package:inventario_pos/core/widgets/foto_producto.dart';

void main() {
  group('DatosNegocio.desdeConfig', () {
    test('lee las claves del negocio', () {
      final n = DatosNegocio.desdeConfig(const {
        'nombre_negocio': 'Tienda Doña Ana',
        'nit': '900123456-7',
        'direccion': 'Calle 5 # 3-21',
        'telefono': '3001234567',
        'ticket_pie': 'Cambios dentro de 8 días',
      });

      expect(n.nombre, 'Tienda Doña Ana');
      expect(n.nit, '900123456-7');
      expect(n.direccion, 'Calle 5 # 3-21');
      expect(n.telefono, '3001234567');
      expect(n.pieTicket, 'Cambios dentro de 8 días');
    });

    // El servidor guarda cadena vacía cuando el negocio no tiene NIT. Si eso
    // llegara como '' en vez de null, el ticket imprimiría la línea «NIT» sin
    // número al lado.
    test('un valor vacío o en blanco equivale a no tenerlo', () {
      final n = DatosNegocio.desdeConfig(const {
        'nombre_negocio': 'Tienda',
        'nit': '',
        'direccion': '   ',
      });

      expect(n.nit, isNull);
      expect(n.direccion, isNull);
      expect(n.telefono, isNull);
      expect(n.pieTicket, isNull);
    });

    test('sin nombre configurado queda el del servidor', () {
      expect(DatosNegocio.desdeConfig(const {}).nombre, 'Mi Negocio');
      expect(DatosNegocio.desdeConfig(const {'nombre_negocio': ''}).nombre, 'Mi Negocio');
    });
  });

  group('inicialesDe', () {
    test('toma la inicial de las dos primeras palabras', () {
      expect(inicialesDe('Gaseosa Grande'), 'GG');
      expect(inicialesDe('Arroz Diana 500 g'), 'AD');
    });

    test('con una sola palabra toma sus dos primeras letras', () {
      expect(inicialesDe('Pan'), 'PA');
      expect(inicialesDe('X'), 'X');
    });

    test('un nombre vacío no revienta la lista', () {
      expect(inicialesDe('   '), '?');
      expect(inicialesDe(''), '?');
    });
  });
}
