import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/ajustes/presentation/ajustes_page.dart';
import '../../features/ajustes/presentation/pendientes_page.dart';
import '../../features/auditoria/presentation/auditoria_page.dart';
import '../../features/auth/domain/sesion.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../features/auth/presentation/login_page.dart';
import '../../features/auth/presentation/usuarios_page.dart';
import '../../features/caja/presentation/caja_page.dart';
import '../../features/categorias/presentation/categorias_page.dart';
import '../../features/cuentas/presentation/cuentas_por_cobrar_page.dart';
import '../../features/dashboard/presentation/dashboard_page.dart';
import '../../features/disponibilidad/presentation/disponibilidad_page.dart';
import '../../features/inventario/presentation/entrada_page.dart';
import '../../features/inventario/presentation/movimientos_page.dart';
import '../../features/inventario/presentation/solicitudes_ajuste_page.dart';
import '../../features/inventario/presentation/stock_bajo_page.dart';
import '../../features/metodos_pago/presentation/metodos_pago_page.dart';
import '../../features/negocio/presentation/negocio_page.dart';
import '../../features/productos/presentation/producto_detalle_page.dart';
import '../../features/productos/presentation/producto_form_page.dart';
import '../../features/productos/presentation/productos_page.dart';
import '../../features/proveedores/presentation/proveedores_page.dart';
import '../../features/reportes/presentation/empleados_page.dart';
import '../../features/reportes/presentation/reportes_page.dart';
import '../../features/scanner/domain/modo_escaner.dart';
import '../../features/scanner/presentation/scanner_page.dart';
import '../../features/sedes/presentation/cambio_sede_page.dart';
import '../../features/sedes/presentation/sedes_page.dart';
import '../../features/traslados/presentation/traslado_detalle_page.dart';
import '../../features/traslados/presentation/traslado_nuevo_page.dart';
import '../../features/traslados/presentation/traslados_page.dart';
import '../../features/ventas/presentation/carrito_page.dart';
import '../../features/ventas/presentation/venta_detalle_page.dart';
import '../../features/ventas/presentation/ventas_page.dart';
import '../widgets/app_shell.dart';

/// Rutas de la app.
///
/// La guarda de sesión se resuelve con datos LOCALES: no hay ninguna petición
/// de red entre abrir la app y ver el dashboard. Abrirla en modo avión debe
/// llevar directamente a la pantalla de trabajo.
class Rutas {
  const Rutas._();

  static const login = '/login';
  static const dashboard = '/';
  static const productos = '/productos';
  static const ventas = '/ventas';
  static const reportes = '/reportes';
  static const escanear = '/escanear';
  static const carrito = '/carrito';
  static const entrada = '/entrada';
  static const movimientos = '/movimientos';
  static const ajustes = '/ajustes';
  static const pendientes = '/pendientes';
  static const usuarios = '/usuarios';
  static const proveedores = '/proveedores';
  static const categorias = '/categorias';
  static const metodosPago = '/metodos-pago';
  static const negocio = '/negocio';
  static const empleados = '/empleados';
  static const productoNuevo = '/productos/nuevo';

  // Multisede y gestión.
  static const sedes = '/sedes';
  static const traslados = '/traslados';
  static const trasladoNuevo = '/traslados/nuevo';
  static const stockBajo = '/stock-bajo';
  static const solicitudesAjuste = '/solicitudes-ajuste';
  static const caja = '/caja';
  static const cierres = '/cierres';
  static const cuentasPorCobrar = '/cuentas-por-cobrar';
  static const auditoria = '/auditoria';
  static const cambioSede = '/cambio-sede';
  static const disponibilidad = '/disponibilidad';

  static String trasladoDetalle(String uuid) => '/traslados/$uuid';
  static String productoDetalle(String uuid) => '/productos/$uuid';
  static String productoEditar(String uuid) => '/productos/$uuid/editar';
  static String ventaDetalle(String uuid) => '/ventas/$uuid';
}

final _navegadorRaiz = GlobalKey<NavigatorState>(debugLabel: 'raiz');
final _navegadorShell = GlobalKey<NavigatorState>(debugLabel: 'shell');

/// Observador de rutas.
///
/// Lo necesita el escáner para saber cuándo deja de estar en primer plano: la
/// cámara es un recurso exclusivo del sistema y no puede seguir encendida
/// mientras el usuario está en el carrito. Se declara con `ModalRoute<dynamic>`
/// —y no `PageRoute`— para que también avise cuando se abre una hoja inferior
/// encima, como la rejilla de venta rápida.
final observadorRutas = RouteObserver<ModalRoute<dynamic>>();

/// ¿Puede este rol abrir esta ubicación?
///
/// El criterio no es «funciones avanzadas», es **qué permite tapar un robo o
/// ver lo que no le toca**: cargar existencias, ajustar un conteo, cambiar
/// precios, anular ventas, ver costos o gestionar personal. Cada rol entra sólo
/// a lo que su trabajo necesita; lo demás lo devuelve al inicio.
///
/// Se decide con la ruta completa (con su consulta) porque el escáner es una
/// sola pantalla con varios modos: vender no es lo mismo que recibir mercancía.
bool puedeAbrir(Uri ubicacion, RolUsuario rol) {
  final ruta = ubicacion.path;
  bool en(String prefijo) => ruta == prefijo || ruta.startsWith('$prefijo/');

  // Sólo el Director General: la identidad del negocio y sus sedes.
  if (en(Rutas.negocio) || en(Rutas.sedes)) return rol.esDirector;

  // Gestores (director y gerentes).
  if (en(Rutas.reportes) || // márgenes y costos
      en(Rutas.usuarios) || // personal
      en(Rutas.proveedores) ||
      en(Rutas.categorias) ||
      en(Rutas.metodosPago) ||
      en(Rutas.empleados) || // control de cajas
      en(Rutas.cierres) ||
      en(Rutas.cuentasPorCobrar) ||
      en(Rutas.auditoria) ||
      ruta == Rutas.productoNuevo ||
      ruta.endsWith('/editar')) {
    return rol.esGestor;
  }

  // Inventario: el auxiliar también, pero sólo para entradas.
  if (en(Rutas.entrada) || en(Rutas.movimientos)) return rol.puedeRegistrarEntradas;
  if (en(Rutas.solicitudesAjuste)) return rol.esGestor || rol.solicitaAjustes;

  // Vender y lo que cuelga de la venta: el auxiliar no vende.
  if (en(Rutas.carrito) || en(Rutas.caja) || en(Rutas.ventas)) return rol.puedeVender;
  if (en(Rutas.escanear)) {
    return switch (ModoEscaner.desde(ubicacion.queryParameters['modo'])) {
      ModoEscaner.venta => rol.puedeVender,
      ModoEscaner.entrada => rol.puedeRegistrarEntradas,
      ModoEscaner.consulta || ModoEscaner.capturarCodigo => true,
    };
  }

  // Ver dónde hay un producto, cualquiera. Los traslados, quien interviene en
  // ellos: el gerente solicita; el director y el auxiliar despachan y mueven.
  if (en(Rutas.disponibilidad)) return true;
  if (en(Rutas.traslados)) return rol.veTraslados;

  // Sólo quien pertenece a una sede pide pasar a otra; las de un gerente las
  // asigna el director.
  if (en(Rutas.cambioSede)) return rol.esDeUnaSede;

  return true;
}

/// Vuelve al escáner **sin apilar otra pantalla de cámara**.
///
/// El camino normal es escáner → carrito, así que el escáner sigue vivo debajo
/// y basta con hacer `pop`. Empujar uno nuevo dejaba DOS `ScannerPage` montadas
/// y dos `MobileScannerController` peleando por la cámara; el segundo fallaba
/// con «already running. Stop it before starting again», y como la pantalla de
/// error no tenía forma de volver, el usuario quedaba atrapado.
void volverAlEscaner(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.pushReplacement('${Rutas.escanear}?modo=venta');
  }
}

/// Puente entre Riverpod y go_router.
///
/// Existe para NO tener que reconstruir el `GoRouter` cuando cambia la sesión.
/// `refreshListenable` hace que go_router vuelva a evaluar el `redirect`
/// manteniendo la misma instancia y el mismo `Navigator`.
class _RefrescoSesion extends ChangeNotifier {
  _RefrescoSesion(Ref ref) {
    ref.listen(sesionProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  // ¡Ojo! Aquí NO se hace `ref.watch(sesionProvider)`.
  //
  // Hacerlo reconstruía el GoRouter entero en cada cambio de estado de la
  // sesión —y al iniciar sesión hay dos seguidos: `loading` y luego `data`—.
  // Cada instancia nueva remonta el Navigator completo, con dos efectos que se
  // veían en la app:
  //
  //   · Tras iniciar sesión, el inicio aparecía vacío hasta navegar a otra
  //     pestaña y volver, porque el árbol se remontaba a mitad de la carga.
  //   · La pestaña «Reportes» no respondía: el `redirect` capturaba la sesión
  //     POR VALOR al construirse, así que una instancia antigua seguía viendo
  //     `sesion == null`, concluía que el usuario no era administrador y
  //     devolvía al inicio en silencio.
  //
  // Con `refreshListenable` la instancia es única y el `redirect` lee la sesión
  // fresca en cada evaluación.
  final refresco = _RefrescoSesion(ref);
  ref.onDispose(refresco.dispose);

  return GoRouter(
    navigatorKey: _navegadorRaiz,
    initialLocation: Rutas.dashboard,
    debugLogDiagnostics: false,
    observers: [observadorRutas],
    refreshListenable: refresco,
    redirect: (context, estado) {
      // Se lee AQUÍ, no en el cuerpo del provider: así el valor es el actual en
      // el momento de decidir, no el que hubiera cuando se creó el router.
      final sesion = ref.read(sesionProvider);

      // Mientras se resuelve la sesión guardada no se redirige: mover al
      // usuario y devolverlo produce un parpadeo desagradable al arrancar.
      if (sesion.isLoading) return null;

      final autenticado = sesion.value != null;
      final enLogin = estado.matchedLocation == Rutas.login;

      if (!autenticado && !enLogin) return Rutas.login;
      if (autenticado && enLogin) return Rutas.dashboard;

      // Barrera de rol en el enrutador.
      //
      // Ocultar los botones no basta: la ruta se puede alcanzar por un enlace
      // profundo, por el historial o por un `push` que se cuele en otra
      // pantalla. El servidor ya rechaza estas operaciones (ver PERMISOS en
      // backend/src/modules/sync/service.js), pero dejar entrar a alguien a un
      // formulario que nunca podrá guardar es cruel.
      final rol = sesion.value?.rol;
      if (rol != null && !puedeAbrir(estado.uri, rol)) return Rutas.dashboard;

      return null;
    },
    routes: [
      GoRoute(
        path: Rutas.login,
        builder: (context, estado) => const LoginPage(),
      ),

      // Escáner y carrito van fuera del shell: ocupan la pantalla completa
      // porque son el flujo de trabajo, no una sección más.
      GoRoute(
        path: Rutas.escanear,
        parentNavigatorKey: _navegadorRaiz,
        pageBuilder: (context, estado) => CustomTransitionPage(
          key: estado.pageKey,
          child: ScannerPage(
            modo: ModoEscaner.desde(estado.uri.queryParameters['modo']),
          ),
          transitionsBuilder: (context, animacion, _, hijo) => FadeTransition(
            opacity: animacion,
            child: ScaleTransition(
              scale: Tween(begin: 1.04, end: 1.0).animate(
                CurvedAnimation(parent: animacion, curve: Curves.easeOutCubic),
              ),
              child: hijo,
            ),
          ),
        ),
      ),
      GoRoute(
        path: Rutas.carrito,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const CarritoPage(),
      ),
      GoRoute(
        path: Rutas.entrada,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => EntradaPage(
          productoUuid: estado.uri.queryParameters['producto'],
        ),
      ),
      GoRoute(
        path: Rutas.productoNuevo,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => ProductoFormPage(
          codigoInicial: estado.uri.queryParameters['codigo'],
        ),
      ),
      GoRoute(
        path: Rutas.movimientos,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => MovimientosPage(
          productoUuid: estado.uri.queryParameters['producto'],
        ),
      ),
      GoRoute(
        path: Rutas.ajustes,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const AjustesPage(),
      ),
      GoRoute(
        path: Rutas.pendientes,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const PendientesPage(),
      ),
      GoRoute(
        path: Rutas.empleados,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const EmpleadosPage(),
      ),
      GoRoute(
        path: Rutas.negocio,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const NegocioPage(),
      ),
      GoRoute(
        path: Rutas.metodosPago,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const MetodosPagoPage(),
      ),
      GoRoute(
        path: Rutas.categorias,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const CategoriasPage(),
      ),
      GoRoute(
        path: Rutas.proveedores,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const ProveedoresPage(),
      ),
      GoRoute(
        path: Rutas.usuarios,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const UsuariosPage(),
      ),

      // Multisede y gestión.
      GoRoute(
        path: Rutas.sedes,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const SedesPage(),
      ),
      GoRoute(
        path: Rutas.cambioSede,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const CambioSedePage(),
      ),
      GoRoute(
        path: Rutas.traslados,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const TrasladosPage(),
        routes: [
          // 'nuevo' antes que ':uuid': si no, «nuevo» se leería como un uuid.
          GoRoute(
            path: 'nuevo',
            parentNavigatorKey: _navegadorRaiz,
            builder: (context, estado) => TrasladoNuevoPage(
              productoUuid: estado.uri.queryParameters['producto'],
              sedeDestinoUuid: estado.uri.queryParameters['destino'],
              sedeOrigenUuid: estado.uri.queryParameters['origen'],
            ),
          ),
          GoRoute(
            path: ':uuid',
            parentNavigatorKey: _navegadorRaiz,
            builder: (context, estado) => TrasladoDetallePage(uuid: estado.pathParameters['uuid']!),
          ),
        ],
      ),
      GoRoute(
        path: Rutas.disponibilidad,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => DisponibilidadPage(productoUuid: estado.uri.queryParameters['producto']),
      ),
      GoRoute(
        path: Rutas.stockBajo,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const StockBajoPage(),
      ),
      GoRoute(
        path: Rutas.solicitudesAjuste,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const SolicitudesAjustePage(),
      ),
      GoRoute(
        path: Rutas.caja,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const CajaPage(),
      ),
      GoRoute(
        path: Rutas.cierres,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const CierresPage(),
      ),
      GoRoute(
        path: Rutas.cuentasPorCobrar,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const CuentasPorCobrarPage(),
      ),
      GoRoute(
        path: Rutas.auditoria,
        parentNavigatorKey: _navegadorRaiz,
        builder: (context, estado) => const AuditoriaPage(),
      ),

      ShellRoute(
        navigatorKey: _navegadorShell,
        builder: (context, estado, hijo) => AppShell(child: hijo),
        routes: [
          GoRoute(
            path: Rutas.dashboard,
            pageBuilder: (context, estado) =>
                NoTransitionPage(key: estado.pageKey, child: const DashboardPage()),
          ),
          GoRoute(
            path: Rutas.productos,
            pageBuilder: (context, estado) =>
                NoTransitionPage(key: estado.pageKey, child: const ProductosPage()),
            routes: [
              GoRoute(
                path: 'nuevo',
                parentNavigatorKey: _navegadorRaiz,
                builder: (context, estado) => const ProductoFormPage(),
              ),
              GoRoute(
                path: ':uuid',
                parentNavigatorKey: _navegadorRaiz,
                builder: (context, estado) =>
                    ProductoDetallePage(uuid: estado.pathParameters['uuid']!),
                routes: [
                  GoRoute(
                    path: 'editar',
                    parentNavigatorKey: _navegadorRaiz,
                    builder: (context, estado) =>
                        ProductoFormPage(uuid: estado.pathParameters['uuid']),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: Rutas.ventas,
            pageBuilder: (context, estado) =>
                NoTransitionPage(key: estado.pageKey, child: const VentasPage()),
            routes: [
              GoRoute(
                path: ':uuid',
                parentNavigatorKey: _navegadorRaiz,
                builder: (context, estado) =>
                    VentaDetallePage(uuid: estado.pathParameters['uuid']!),
              ),
            ],
          ),
          GoRoute(
            path: Rutas.reportes,
            pageBuilder: (context, estado) =>
                NoTransitionPage(key: estado.pageKey, child: const ReportesPage()),
          ),
        ],
      ),
    ],
    errorBuilder: (context, estado) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off_outlined, size: 48),
            const SizedBox(height: 12),
            Text('No se encontró ${estado.uri}'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go(Rutas.dashboard),
              child: const Text('Ir al inicio'),
            ),
          ],
        ),
      ),
    ),
  );
});
