import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/domain/sesion.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/ventas/presentation/carrito_provider.dart';
import '../router/app_router.dart';
import '../theme/app_theme.dart';

/// Armazón con la navegación principal.
///
/// El botón central de escanear es más grande y sobresale a propósito: escanear
/// es la acción que se repite cientos de veces al día, y debe ser alcanzable
/// con el pulgar sin mirar.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child});

  final Widget child;

  /// Destinos según el rol.
  ///
  /// El vendedor sólo tiene **Inicio y Ventas**. No es una versión recortada
  /// por recortar: su trabajo cabe en el botón de escanear y en revisar lo que
  /// lleva vendido. «Reportes» guarda márgenes y costos, que son datos del
  /// negocio y no de su turno; y el catálogo, que sí necesita consultar, lo
  /// alcanza desde el acceso directo del inicio.
  ///
  /// El auxiliar de inventario no vende: su botón central abre el escáner en
  /// modo entrada, y su segunda pestaña es el catálogo, donde consulta el stock
  /// y pide conteos y mermas.
  ///
  /// Que el número de destinos sea **par** en todos los roles no es
  /// casualidad: el hueco del botón central sólo queda centrado si a cada lado
  /// hay los mismos.
  static List<DestinoNav> destinosDe(RolUsuario rol) => switch (rol) {
        RolUsuario.director || RolUsuario.gerente => const [
            DestinoNav(Rutas.dashboard, Icons.dashboard_outlined, Icons.dashboard_rounded, 'Inicio'),
            DestinoNav(Rutas.productos, Icons.inventory_2_outlined, Icons.inventory_2_rounded, 'Productos'),
            DestinoNav(Rutas.ventas, Icons.receipt_long_outlined, Icons.receipt_long_rounded, 'Ventas'),
            DestinoNav(Rutas.reportes, Icons.insights_outlined, Icons.insights_rounded, 'Reportes'),
          ],
        RolUsuario.auxiliarInventario => const [
            DestinoNav(Rutas.dashboard, Icons.dashboard_outlined, Icons.dashboard_rounded, 'Inicio'),
            DestinoNav(Rutas.productos, Icons.inventory_2_outlined, Icons.inventory_2_rounded, 'Productos'),
          ],
        RolUsuario.vendedor => const [
            DestinoNav(Rutas.dashboard, Icons.dashboard_outlined, Icons.dashboard_rounded, 'Inicio'),
            DestinoNav(Rutas.ventas, Icons.receipt_long_outlined, Icons.receipt_long_rounded, 'Ventas'),
          ],
      };

  /// Pestañas tal como las recibe `NavigationBar`, con el hueco del botón
  /// central incluido (`null`).
  ///
  /// Es público para poder probarlo: aquí vivía el fallo que dejaba «Reportes»
  /// y «Ventas» sin respuesta, y no se ve a simple vista.
  static List<DestinoNav?> ranurasDe(RolUsuario rol) {
    final destinos = destinosDe(rol);
    return <DestinoNav?>[...destinos]..insert(destinos.length ~/ 2, null);
  }

  /// Pestaña que corresponde a una ubicación. Nunca devuelve el hueco.
  static int indiceDe(String ubicacion, List<DestinoNav?> ranuras) {
    // De derecha a izquierda: «Inicio» es prefijo de todo y con una búsqueda
    // normal se quedaría siempre encendido.
    final i = ranuras.lastIndexWhere((d) => d != null && _coincide(ubicacion, d.ruta));
    return i >= 0 ? i : 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ubicacion = GoRouterState.of(context).matchedLocation;
    final articulos = ref.watch(carritoProvider).articulos;

    // El hueco del botón central es una pestaña más para `NavigationBar`, así
    // que la lista pintada NO coincide con la de destinos. Antes se mezclaban
    // ambos índices: al tocar «Ventas» se navegaba a «Reportes» y «Reportes»
    // se salía del rango, así que no hacía nada.
    final rol = ref.watch(rolProvider);
    final ranuras = ranurasDe(rol);
    final seleccionado = indiceDe(ubicacion, ranuras);

    return Scaffold(
      body: child,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: _BotonEscanear(articulosEnCarrito: articulos, paraVender: rol.puedeVender),
      bottomNavigationBar: NavigationBar(
        selectedIndex: seleccionado,
        onDestinationSelected: (i) {
          final destino = ranuras[i];
          if (destino != null) context.go(destino.ruta);
        },
        destinations: [
          for (final ranura in ranuras)
            if (ranura == null)
              const NavigationDestination(
                icon: SizedBox(width: 48),
                label: '',
                enabled: false,
              )
            else
              NavigationDestination(
                icon: Icon(ranura.icono),
                selectedIcon: Icon(ranura.activo),
                label: ranura.etiqueta,
              ),
        ],
      ),
    );
  }

  /// «Inicio» sólo se activa con la raíz exacta; el resto, también con sus
  /// subrutas (`/ventas/<uuid>` mantiene encendida la pestaña de Ventas).
  static bool _coincide(String ubicacion, String ruta) =>
      ruta == Rutas.dashboard ? ubicacion == ruta : ubicacion.startsWith(ruta);
}

class DestinoNav {
  const DestinoNav(this.ruta, this.icono, this.activo, this.etiqueta);

  final String ruta;
  final IconData icono;
  final IconData activo;
  final String etiqueta;
}

class _BotonEscanear extends StatelessWidget {
  const _BotonEscanear({required this.articulosEnCarrito, required this.paraVender});

  final int articulosEnCarrito;

  /// false = auxiliar de inventario: escanea para recibir mercancía.
  final bool paraVender;

  @override
  Widget build(BuildContext context) {
    final boton = FloatingActionButton.large(
      heroTag: 'fab-escanear',
      onPressed: () => context.push('${Rutas.escanear}?modo=${paraVender ? 'venta' : 'entrada'}'),
      tooltip: paraVender ? 'Escanear producto' : 'Recibir mercancía',
      elevation: 4,
      child: Icon(paraVender ? Icons.qr_code_scanner_rounded : Icons.move_to_inbox_rounded, size: 30),
    );

    if (articulosEnCarrito == 0 || !paraVender) return boton;

    return Badge.count(
      count: articulosEnCarrito,
      alignment: const AlignmentDirectional(0.9, -0.85),
      backgroundColor: context.dominio.advertencia,
      textColor: Colors.white,
      largeSize: 22,
      child: boton,
    );
  }
}
