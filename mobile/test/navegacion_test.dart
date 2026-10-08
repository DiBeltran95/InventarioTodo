import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/router/app_router.dart';
import 'package:inventario_pos/core/widgets/app_shell.dart';
import 'package:inventario_pos/features/auth/domain/sesion.dart';

/// Regresión de la barra inferior.
///
/// El hueco del botón central de escanear es, para `NavigationBar`, una pestaña
/// más. Durante un tiempo el código mezcló dos numeraciones —la de destinos y
/// la de pestañas pintadas—, con dos consecuencias en producción:
///
///  · al administrador, «Reportes» no le hacía nada (índice fuera de rango) y
///    «Ventas» lo llevaba a Reportes;
///  · al vendedor, «Ventas» tampoco respondía, y el botón de escanear se
///    montaba encima de «Productos» porque el hueco no quedaba centrado.
///
/// Nada de esto se nota leyendo el código, así que se fija aquí.
void main() {
  group('Ranuras de la barra inferior', () {
    test('director y gerente tienen sus cuatro secciones y el hueco centrado', () {
      for (final rol in [RolUsuario.director, RolUsuario.gerente]) {
        final ranuras = AppShell.ranurasDe(rol);

        expect(ranuras.length, 5, reason: '4 destinos + el hueco del botón');
        expect(ranuras[2], isNull, reason: 'el hueco va justo en el centro');
        expect(ranuras.map((d) => d?.ruta).toList(), [
          Rutas.dashboard,
          Rutas.productos,
          null,
          Rutas.ventas,
          Rutas.reportes,
        ]);
      }
    });

    test('el vendedor sólo tiene Inicio y Ventas, con el hueco en medio', () {
      final ranuras = AppShell.ranurasDe(RolUsuario.vendedor);

      expect(ranuras.length, 3);
      expect(ranuras[1], isNull);
      expect(ranuras.map((d) => d?.ruta).toList(), [
        Rutas.dashboard,
        null,
        Rutas.ventas,
      ]);
    });

    test('el vendedor no ve Reportes ni Productos en la barra', () {
      final rutas = AppShell.ranurasDe(RolUsuario.vendedor).map((d) => d?.ruta).toList();
      expect(rutas, isNot(contains(Rutas.reportes)));
      expect(rutas, isNot(contains(Rutas.productos)));
    });

    test('el auxiliar tiene Inicio y Productos, y no ve Ventas ni Reportes', () {
      final rutas = AppShell.ranurasDe(RolUsuario.auxiliarInventario).map((d) => d?.ruta).toList();
      expect(rutas, [Rutas.dashboard, null, Rutas.productos]);
    });

    test('el hueco queda centrado en todos los roles', () {
      for (final rol in RolUsuario.values) {
        final ranuras = AppShell.ranurasDe(rol);
        final hueco = ranuras.indexWhere((d) => d == null);
        // Mismo número de pestañas a cada lado: si no, el botón flotante
        // —anclado al centro— se monta encima de una de ellas.
        expect(hueco, ranuras.length - 1 - hueco, reason: 'hueco descentrado para ${rol.etiqueta}');
      }
    });

    test('ningún rol tiene en la barra una sección que el router le prohíbe', () {
      for (final rol in RolUsuario.values) {
        for (final d in AppShell.destinosDe(rol)) {
          expect(puedeAbrir(Uri.parse(d.ruta), rol), isTrue, reason: '${rol.etiqueta} → ${d.ruta}');
        }
      }
    });
  });

  group('Pestaña activa', () {
    test('cada destino se enciende en su propia ranura', () {
      final ranuras = AppShell.ranurasDe(RolUsuario.director);

      expect(AppShell.indiceDe(Rutas.dashboard, ranuras), 0);
      expect(AppShell.indiceDe(Rutas.productos, ranuras), 1);
      expect(AppShell.indiceDe(Rutas.ventas, ranuras), 3);
      expect(AppShell.indiceDe(Rutas.reportes, ranuras), 4);
    });

    test('nunca selecciona el hueco', () {
      for (final rol in RolUsuario.values) {
        final ranuras = AppShell.ranurasDe(rol);
        for (final ubicacion in [Rutas.dashboard, Rutas.ventas, '/ventas/abc-123', '/desconocida']) {
          final i = AppShell.indiceDe(ubicacion, ranuras);
          expect(ranuras[i], isNotNull, reason: '«$ubicacion» seleccionó el hueco (${rol.etiqueta})');
        }
      }
    });

    test('una subruta mantiene encendida su sección, no Inicio', () {
      final ranuras = AppShell.ranurasDe(RolUsuario.director);
      // '/' es prefijo de todo: buscar de izquierda a derecha dejaría siempre
      // «Inicio» encendido.
      expect(AppShell.indiceDe('/ventas/abc-123', ranuras), 3);
      expect(AppShell.indiceDe('/productos/abc-123', ranuras), 1);
    });

    test('una ruta desconocida cae en Inicio', () {
      final ranuras = AppShell.ranurasDe(RolUsuario.director);
      expect(AppShell.indiceDe('/no-existe', ranuras), 0);
    });

    test('el vendedor en Ventas enciende la ranura correcta', () {
      final ranuras = AppShell.ranurasDe(RolUsuario.vendedor);
      expect(AppShell.indiceDe(Rutas.ventas, ranuras), 2);
      expect(ranuras[2]?.ruta, Rutas.ventas);
    });
  });

  group('puedeAbrir', () {
    bool abre(String ruta, RolUsuario rol) => puedeAbrir(Uri.parse(ruta), rol);

    test('el director entra a todo', () {
      for (final ruta in [
        Rutas.negocio,
        Rutas.sedes,
        Rutas.reportes,
        Rutas.usuarios,
        Rutas.auditoria,
        Rutas.cuentasPorCobrar,
        Rutas.trasladoNuevo,
        Rutas.entrada,
        '${Rutas.escanear}?modo=venta',
      ]) {
        expect(abre(ruta, RolUsuario.director), isTrue, reason: ruta);
      }
    });

    test('el gerente gestiona, pero no los datos del negocio ni las sedes', () {
      const g = RolUsuario.gerente;
      expect(abre(Rutas.negocio, g), isFalse);
      expect(abre(Rutas.sedes, g), isFalse);
      for (final ruta in [Rutas.reportes, Rutas.usuarios, Rutas.auditoria, Rutas.cierres, '/productos/x/editar']) {
        expect(abre(ruta, g), isTrue, reason: ruta);
      }
      expect(abre(Rutas.cambioSede, g), isFalse, reason: 'sus sedes las asigna el director');
    });

    test('el vendedor vende y pide traslados, pero no toca inventario ni catálogo', () {
      const v = RolUsuario.vendedor;
      for (final ruta in [Rutas.carrito, Rutas.caja, Rutas.ventas, '/ventas/abc', Rutas.traslados, Rutas.cambioSede]) {
        expect(abre(ruta, v), isTrue, reason: ruta);
      }
      for (final ruta in [
        Rutas.entrada,
        Rutas.movimientos,
        Rutas.productoNuevo,
        '/productos/x/editar',
        Rutas.reportes,
        Rutas.usuarios,
        Rutas.auditoria,
        '${Rutas.escanear}?modo=entrada',
      ]) {
        expect(abre(ruta, v), isFalse, reason: ruta);
      }
    });

    test('el auxiliar recibe mercancía y pide ajustes, pero no vende', () {
      const a = RolUsuario.auxiliarInventario;
      for (final ruta in [
        Rutas.entrada,
        Rutas.movimientos,
        Rutas.solicitudesAjuste,
        Rutas.stockBajo,
        Rutas.cambioSede,
        '${Rutas.escanear}?modo=entrada',
        '${Rutas.escanear}?modo=consulta',
      ]) {
        expect(abre(ruta, a), isTrue, reason: ruta);
      }
      for (final ruta in [
        Rutas.carrito,
        Rutas.caja,
        Rutas.ventas,
        Rutas.escanear, // sin modo = venta
        '${Rutas.escanear}?modo=venta',
        Rutas.traslados,
        Rutas.productoNuevo,
        Rutas.reportes,
      ]) {
        expect(abre(ruta, a), isFalse, reason: ruta);
      }
    });

    test('las rutas comunes las abre cualquiera', () {
      for (final rol in RolUsuario.values) {
        for (final ruta in [Rutas.dashboard, Rutas.productos, '/productos/abc', Rutas.ajustes, Rutas.pendientes]) {
          expect(abre(ruta, rol), isTrue, reason: '${rol.etiqueta} → $ruta');
        }
      }
    });

    test('un prefijo parecido no cuela una ruta protegida', () {
      // «/ventas-x» no es «/ventas», y «/cajas» no es «/caja».
      expect(abre('/ventas-x', RolUsuario.auxiliarInventario), isTrue);
      expect(abre('/cajas', RolUsuario.auxiliarInventario), isTrue);
    });
  });
}
