import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/theme/app_theme.dart';
import 'package:inventario_pos/core/widgets/estados.dart';

/// Un mensaje lanzado DESDE una hoja inferior (p. ej. el formulario de nuevo
/// empleado) tiene que verse: antes el snackbar quedaba detrás de la hoja, la
/// persona creía que el botón no hizo nada y lo volvía a tocar.
void main() {
  testWidgets('el mensaje desde una hoja inferior flota encima y se ve', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.claro(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (hoja) => SizedBox(
                height: 300,
                child: Center(
                  child: TextButton(
                    onPressed: () => mostrarMensaje(hoja, 'Elige la sede donde trabaja', esError: true),
                    child: const Text('Dar acceso'),
                  ),
                ),
              ),
            ),
            child: const Text('Abrir'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('Abrir'));
    await t.pumpAndSettle();
    await t.tap(find.text('Dar acceso'));
    await t.pump();

    expect(find.text('Elige la sede donde trabaja'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing, reason: 'no va al snackbar oculto detrás de la hoja');
    await t.tap(find.text('Elige la sede donde trabaja'));
    await t.pump();
    expect(find.text('Elige la sede donde trabaja'), findsNothing);
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('en una pantalla normal sigue siendo un snackbar', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.claro(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => mostrarMensaje(context, 'Acceso creado', esExito: true),
            child: const Text('Guardar'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('Guardar'));
    await t.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
