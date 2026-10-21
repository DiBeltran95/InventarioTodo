import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/router/app_router.dart';
import 'package:inventario_pos/core/theme/app_theme.dart';
import 'package:inventario_pos/features/auth/domain/sesion.dart';
import 'package:inventario_pos/features/cuenta/domain/plan.dart';
import 'package:inventario_pos/features/cuenta/presentation/plan_ui.dart';
import 'package:inventario_pos/features/cuenta/presentation/registro_empresa_page.dart';
import 'package:inventario_pos/features/cuenta/presentation/sin_acceso.dart';

/// Plan tal como lo mandan los backends (docs/PLATAFORMA.md).
const _planGratis = {
  'codigo': 'GRATIS',
  'nombre': 'Gratis',
  'vence': null,
  'vencido': false,
  'sedes': {'usados': 1, 'maximo': 1},
  'personas': {'usados': 2, 'maximo': 3},
  'productos': {'usados': 3, 'maximo': 3},
};

Widget _envolver(Widget hijo) => ProviderScope(
      child: MaterialApp(theme: AppTheme.claro(), home: Scaffold(body: hijo)),
    );

void main() {
  group('PlanEmpresa', () {
    test('lee el plan del servidor y sabe qué está lleno', () {
      final plan = PlanEmpresa.desdeJson(_planGratis)!;
      expect(plan.esGratis, isTrue);
      expect(plan.sedes.lleno, isTrue);
      expect(plan.productos.lleno, isTrue);
      expect(plan.personas.lleno, isFalse);
      expect(plan.personas.disponibles, 1);
    });

    test('sin máximo es ilimitado y nunca se llena', () {
      final plan = PlanEmpresa.desdeJson({
        'codigo': 'ILIMITADO',
        'nombre': 'Ilimitado',
        'productos': {'usados': 5000, 'maximo': null},
      })!;
      expect(plan.productos.ilimitado, isTrue);
      expect(plan.productos.lleno, isFalse);
      expect(plan.productos.disponibles, isNull);
    });

    test('se guarda y se vuelve a leer igual (para usarlo sin red)', () {
      final plan = PlanEmpresa.desdeJson(_planGratis)!;
      final otra = PlanEmpresa.desdeJson(plan.aJson())!;
      for (final r in RecursoLimitado.values) {
        expect(otra.de(r).usados, plan.de(r).usados);
        expect(otra.de(r).maximo, plan.de(r).maximo);
      }
    });

    test('un JSON que no es mapa no produce plan', () {
      expect(PlanEmpresa.desdeJson(null), isNull);
      expect(PlanEmpresa.desdeJson('GRATIS'), isNull);
    });

    test('el recurso del error LIMITE_PLAN se reconoce', () {
      expect(RecursoLimitado.desdeApi('productos'), RecursoLimitado.productos);
      expect(RecursoLimitado.desdeApi('sedes'), RecursoLimitado.sedes);
      expect(RecursoLimitado.desdeApi('otra-cosa'), isNull);
    });
  });

  group('Planes y roles por app', () {
    test('Mi empresa trae el plan de cada app', () {
      final e = EmpresaInfo.desdeJson({
        'empresa': {'uuid': 'u', 'nombre': 'Tienda'},
        'plan': {..._planGratis, 'aplicativo': 'INVENTARIO'},
        'planes': {
          'INVENTARIO': {..._planGratis, 'aplicativo': 'INVENTARIO'},
          'ASISTENCIA': {..._planGratis, 'aplicativo': 'ASISTENCIA', 'codigo': 'ILIMITADO', 'nombre': 'Ilimitado'},
        },
        'aplicativos': ['ASISTENCIA', 'INVENTARIO'],
      });
      expect(e.plan!.esVentario, isTrue);
      expect(e.plan!.recursos, contains(RecursoLimitado.productos));
      expect(e.planPresente!.nombreApp, 'Presente');
      expect(e.planPresente!.esGratis, isFalse);
      expect(e.planPresente!.recursos, isNot(contains(RecursoLimitado.productos)));
    });

    test('el plan guardado conserva su app', () {
      final plan = PlanEmpresa.desdeJson({..._planGratis, 'aplicativo': 'ASISTENCIA'})!;
      expect(PlanEmpresa.desdeJson(plan.aJson())!.aplicativo, 'ASISTENCIA');
      expect(PlanEmpresa.desdeJson(_planGratis)!.aplicativo, 'INVENTARIO');
    });

    test('el rol único decide a qué app entra la cuenta', () {
      expect(RolCuenta.director.enLasDos, isTrue);
      expect(RolCuenta.gerente.asistencia, 'GERENTE');
      expect(RolCuenta.vendedor.asistencia, isNull);
      expect(RolCuenta.vendedor.unaSede, isTrue);
      expect(RolCuenta.talentoHumano.inventario, isNull);
      expect(RolCuenta.operario.conSedes, isFalse);
      expect(RolCuenta.asignablesPorGerente, isNot(contains(RolCuenta.gerente)));
      expect(RolCuenta.de(inventario: RolUsuario.auxiliarInventario), RolCuenta.auxiliar);
      expect(RolCuenta.de(asistencia: 'OPERADOR'), RolCuenta.operario);
      expect(RolCuenta.de(), isNull);
    });

    test('una cuenta solo de Presente y en pausa se reconoce', () {
      final u = UsuarioAdmin.desdeJson({
        'uuid': 'x', 'nombre': 'Luz', 'email': 'luz@ej.co', 'rol': null, 'rol_asistencia': 'TALENTO_HUMANO',
        'activo': true, 'pausa_asistencia': 1, 'pausa_inventario': false,
      });
      expect(u.conAccesoInventario, isFalse);
      expect(u.rolCuenta, RolCuenta.talentoHumano);
      expect(u.pausaAsistencia, isTrue);
      expect(u.pausaInventario, isFalse);
    });
  });

  group('Acceso a la app', () {
    test('una cuenta válida sin acceso a Inventario no es «credenciales incorrectas»', () {
      for (final codigo in ['APP_NO_HABILITADA', 'SIN_ACCESO_APP', 'EMPRESA_SUSPENDIDA', 'CUENTA_DESACTIVADA']) {
        expect(ResultadoLogin.error('x', codigo: codigo).sinAccesoApp, isTrue, reason: codigo);
      }
      expect(ResultadoLogin.error('x', codigo: 'CREDENCIALES_INVALIDAS').sinAccesoApp, isFalse);
      expect(ResultadoLogin.error('x').sinAccesoApp, isFalse);
    });

    test('registro y recuperación se abren sin sesión; Mi empresa la ve cualquier rol', () {
      expect(Rutas.publicas, containsAll([Rutas.login, Rutas.registro, Rutas.recuperarClave]));
      expect(Rutas.publicas, isNot(contains(Rutas.miEmpresa)));
      for (final rol in RolUsuario.values) {
        expect(puedeAbrir(Uri.parse(Rutas.miEmpresa), rol), isTrue, reason: rol.name);
      }
    });

    test('una cuenta sin rol en Inventario se marca como tal', () {
      final u = UsuarioAdmin.desdeJson({
        'uuid': 'u1',
        'nombre': 'Ana',
        'email': 'ana@x.co',
        'rol': null,
        'rol_asistencia': 'OPERADOR',
        'activo': 1,
      });
      expect(u.conAccesoInventario, isFalse);
      expect(u.rolAsistencia, 'OPERADOR');
    });
  });

  group('Pantallas', () {
    testWidgets('el medidor dice el uso con número y texto, no solo con color', (tester) async {
      await tester.pumpWidget(_envolver(
        const MedidorUso(recurso: RecursoLimitado.productos, uso: RecursoPlan(usados: 3, maximo: 3)),
      ));
      expect(find.text('3 de 3'), findsOneWidget);
      expect(find.text('Límite alcanzado'), findsOneWidget);
    });

    testWidgets('la hoja de límite explica el plan y se cierra', (tester) async {
      final plan = PlanEmpresa.desdeJson(_planGratis)!;
      await tester.pumpWidget(_envolver(Builder(
        builder: (context) => TextButton(
          onPressed: () => mostrarHojaLimite(context, RecursoLimitado.productos, plan: plan),
          child: const Text('abrir'),
        ),
      )));
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Llegaste al límite de tu plan'), findsOneWidget);
      expect(find.textContaining('hasta 3 productos'), findsOneWidget);
      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();
      expect(find.text('Llegaste al límite de tu plan'), findsNothing);
    });

    testWidgets('sin acceso explica el motivo y deja usar otra cuenta', (tester) async {
      var otra = false;
      await tester.pumpWidget(_envolver(SingleChildScrollView(
        child: PanelSinAcceso(codigo: 'APP_NO_HABILITADA', alUsarOtraCuenta: () => otra = true),
      )));
      expect(find.text('Tu empresa aún no usa Ventario'), findsOneWidget);
      await tester.tap(find.text('Usar otra cuenta'));
      expect(otra, isTrue);
    });

    testWidgets('el registro valida cada paso antes de avanzar y permite volver', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(theme: AppTheme.claro(), home: const RegistroEmpresaPage()),
      ));
      expect(find.text('Tus datos'), findsOneWidget);

      // Vacío: no avanza y dice qué falta junto a cada campo.
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.text('Tus datos'), findsOneWidget);
      expect(find.text('Escribe tu nombre completo'), findsOneWidget);
      expect(find.text('Escribe un correo válido'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, 'Tu nombre completo'), 'Ana Gómez');
      await tester.enterText(find.widgetWithText(TextFormField, 'Correo'), 'ana@tienda.co');
      await tester.enterText(find.widgetWithText(TextFormField, 'Contraseña'), 'Clave-Segura-2026');
      await tester.pump();
      expect(find.text('Muy buena'), findsOneWidget);

      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.text('Tu empresa'), findsWidgets);
      expect(find.text('Tus datos'), findsNothing);

      // Atrás conserva lo escrito.
      await tester.tap(find.byTooltip('Paso anterior'));
      await tester.pumpAndSettle();
      expect(find.text('Tus datos'), findsOneWidget);
      expect(find.text('ana@tienda.co'), findsOneWidget);
    });
  });
}
