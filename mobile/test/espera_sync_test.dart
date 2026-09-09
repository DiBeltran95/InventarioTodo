import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/sync/estado_sync.dart';
import 'package:inventario_pos/core/utils/fechas.dart';

/// La cola distingue «pendiente» de «lista para enviar»: tras un fallo la fila
/// sigue contando como pendiente pero no sale hasta que vence su backoff.
///
/// Callarlo producía una pantalla que se contradecía —«hay conexión», «última
/// sincronización: hace un momento» y «4 por enviar» a la vez— y un botón de
/// sincronizar que no hacía nada visible. Estas pruebas fijan que ese estado
/// intermedio se pueda nombrar.
void main() {
  group('EstadoSync.enEspera', () {
    test('hay espera mientras el backoff no venza', () {
      final estado = EstadoSync(
        fase: FaseSync.pendiente,
        pendientes: 4,
        esperaHasta: DateTime.now().add(const Duration(minutes: 3)),
        errorEnCola: 'Error del servidor',
      );

      expect(estado.enEspera, isTrue);
    });

    test('un vencimiento ya pasado no es espera', () {
      final estado = EstadoSync(
        pendientes: 4,
        esperaHasta: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(estado.enEspera, isFalse);
    });

    test('sin nada frenado no hay espera', () {
      expect(const EstadoSync(pendientes: 4).enEspera, isFalse);
    });

    test('limpiarEspera borra el aviso al vaciarse la cola', () {
      final conEspera = EstadoSync(
        pendientes: 4,
        esperaHasta: DateTime.now().add(const Duration(minutes: 3)),
        errorEnCola: 'Error del servidor',
      );

      final limpio = conEspera.copyWith(limpiarEspera: true);

      expect(limpio.esperaHasta, isNull);
      expect(limpio.errorEnCola, isNull);
      expect(limpio.enEspera, isFalse);
    });
  });

  group('Fechas.enCuanto', () {
    test('cuenta hacia adelante', () {
      expect(Fechas.enCuanto(DateTime.now().add(const Duration(seconds: 40))), 'en 40 s');
      expect(Fechas.enCuanto(DateTime.now().add(const Duration(minutes: 3))), 'en 3 min');
    });

    test('un vencimiento pasado es «ya», nunca un número negativo', () {
      expect(Fechas.enCuanto(DateTime.now().subtract(const Duration(minutes: 5))), 'ya');
    });

    test('sin fecha no inventa una cuenta atrás', () {
      expect(Fechas.enCuanto(null), 'enseguida');
    });
  });
}
