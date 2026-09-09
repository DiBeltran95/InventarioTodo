import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:inventario_pos/core/utils/fechas.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es_CO', null);
  });

  group('formatFechaHoraDocumento', () {
    // El ticket se reclama meses después y a veces se archiva junto a los del
    // año anterior. Sin año no distingue un 14 de septiembre de otro.
    test('lleva el año', () {
      final texto = Fechas.formatFechaHoraDocumento(DateTime.utc(2026, 9, 14, 20, 42));
      expect(texto, contains('2026'));
    });

    test('es numérico y de largo fijo, para que quepa en 80 mm', () {
      final texto = Fechas.formatFechaHoraDocumento(DateTime.utc(2026, 1, 5, 14, 3));
      expect(texto.length, 16);
      expect(RegExp(r'^\d{2}/\d{2}/\d{4} \d{2}:\d{2}$').hasMatch(texto), isTrue);
    });

    // La hora del ticket es la del negocio, no UTC: una venta de las 8 de la
    // noche no puede figurar al día siguiente.
    test('usa la hora del negocio', () {
      final enPantalla = Fechas.formatFechaHora(DateTime.utc(2026, 9, 14, 20, 42));
      final enTicket = Fechas.formatFechaHoraDocumento(DateTime.utc(2026, 9, 14, 20, 42));
      expect(enTicket.substring(11), enPantalla.substring(enPantalla.length - 5));
    });
  });
}
