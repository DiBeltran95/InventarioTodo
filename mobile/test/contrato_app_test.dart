import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventario_pos/core/database/app_database.dart';
import 'package:inventario_pos/core/database/daos/ajustes_dao.dart';
import 'package:inventario_pos/core/database/daos/cierres_dao.dart';
import 'package:inventario_pos/core/database/daos/inventario_dao.dart';
import 'package:inventario_pos/core/database/daos/metodos_pago_dao.dart';
import 'package:inventario_pos/core/database/daos/outbox_dao.dart';
import 'package:inventario_pos/core/database/daos/recaudos_dao.dart';
import 'package:inventario_pos/core/database/daos/traslados_dao.dart';
import 'package:inventario_pos/core/database/daos/ventas_dao.dart';
import 'package:inventario_pos/core/money/money.dart';
import 'package:inventario_pos/core/negocio/caja.dart';

/// Contrato con el servidor: la app genera su cola de salida de un día
/// multisede completo, y `backend/scripts/contrato-app.mjs enviar` la sube a un
/// servidor de prueba y comprueba el resultado.
///
/// Sólo corre con `CONTRATO_FIXTURES` apuntando al archivo que escribe
/// `contrato-app.mjs preparar`. Sin él se salta: no hay servidor en la CI.
void main() {
  final rutaFixtures = Platform.environment['CONTRATO_FIXTURES'];

  test(
    'genera la cola de un día multisede con las cargas reales de la app',
    () async {
      final f = jsonDecode(File(rutaFixtures!).readAsStringSync()) as Map<String, dynamic>;
      final principal = f['principal']['uuid'] as String;
      final nueva = f['nueva']['uuid'] as String;
      final u = f['usuarios'] as Map<String, dynamic>;
      String uuidDe(String clave) => u[clave]['uuid'] as String;
      final p = f['producto'] as Map<String, dynamic>;
      final precio = Money.parse('${p['precio_venta']}');
      final costo = Money.parse('${p['precio_compra'] ?? '0'}');
      final iva = TasaIva.parse('${p['tasa_iva'] ?? '0'}');
      final stockPrincipal = Cantidad.parse('${p['stock_principal']}');

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final outbox = OutboxDao(db);
      final inventario = InventarioDao(db, outbox);

      await db.batch((x) {
        x.insertAll(db.sedes, [
          SedesCompanion.insert(
              uuid: principal, nombre: '${f['principal']['nombre']}', codigo: '${f['principal']['codigo']}', esPrincipal: const Value(true)),
          SedesCompanion.insert(uuid: nueva, nombre: '${f['nueva']['nombre']}', codigo: '${f['nueva']['codigo']}'),
        ]);
        for (final e in u.values) {
          final m = e as Map<String, dynamic>;
          x.insert(
            db.usuarios,
            UsuariosCompanion.insert(
              uuid: m['uuid'] as String,
              nombre: m['nombre'] as String,
              email: m['email'] as String,
              rol: Value(m['rol'] as String),
              sedes: Value((m['sedes'] as List).join(',')),
            ),
          );
        }
        x.insert(
          db.productos,
          ProductosCompanion.insert(
            uuid: p['uuid'] as String,
            sku: p['sku'] as String,
            nombre: p['nombre'] as String,
            precioVenta: Value(precio.centavos),
            precioCompra: Value(costo.centavos),
            tasaIva: Value(iva.escalada),
            stockActual: Value(stockPrincipal.milesimas),
          ),
        );
        x.insertAll(db.stockSedes, [
          StockSedesCompanion.insert(
              productoUuid: p['uuid'] as String, sedeUuid: principal, stockActual: Value(stockPrincipal.milesimas)),
          StockSedesCompanion.insert(productoUuid: p['uuid'] as String, sedeUuid: nueva),
        ]);
        x.insert(
          db.metodosPago,
          MetodosPagoCompanion.insert(
              uuid: f['efectivo']['uuid'] as String, nombre: f['efectivo']['nombre'] as String, tipo: const Value('EFECTIVO')),
        );
      });
      await (db.update(db.estadoApp)..where((t) => t.id.equals(1))).write(
        EstadoAppCompanion(sedeActivaUuid: Value(principal), prefijoFolio: Value(f['prefijo'] as String)),
      );
      Future<void> como(String clave) => (db.update(db.estadoApp)..where((t) => t.id.equals(1)))
          .write(EstadoAppCompanion(usuarioUuid: Value(uuidDe(clave))));

      LineaParaVender linea() => LineaParaVender(
            productoUuid: p['uuid'] as String,
            descripcion: p['nombre'] as String,
            sku: p['sku'] as String,
            cantidad: Cantidad.unidades(1),
            precioUnitario: precio,
            costoUnitario: costo,
            tasaIva: iva,
          );
      final totalUna = calcularLinea(precioUnitario: precio, cantidad: Cantidad.unidades(1), tasaIva: iva).total;

      final traslados = TrasladosDao(db, outbox, inventario);
      final ajustes = AjustesDao(db, outbox, inventario);
      final cierres = CierresDao(db, outbox);
      final ventas = VentasDao(db, outbox, inventario);
      final metodos = MetodosPagoDao(db, outbox);
      final recaudos = RecaudosDao(db, outbox);

      // 1. El vendedor pide 3 a la sede nueva; el gerente lo aprueba.
      await como('vendedor');
      final traslado = await traslados.crear(
        sedeOrigenUuid: principal,
        sedeDestinoUuid: nueva,
        lineas: [LineaTraslado(productoUuid: p['uuid'] as String, descripcion: p['nombre'] as String, cantidad: Cantidad.unidades(3))],
        notas: 'Contrato',
      );
      await como('gerente');
      await traslados.aprobar(traslado);

      // 2. El vendedor abre caja, vende 1 en efectivo y cierra contando lo esperado.
      await como('vendedor');
      final turno = await cierres.abrir(baseEfectivo: Money.parse('50000'));
      await ventas.registrarVenta(
        lineas: [linea()],
        pagos: [
          PagoDeVenta(
            metodoUuid: f['efectivo']['uuid'] as String,
            metodoNombre: f['efectivo']['nombre'] as String,
            metodoTipo: 'EFECTIVO',
            monto: totalUna,
            montoRecibido: totalUna,
          ),
        ],
        usuarioUuid: uuidDe('vendedor'),
      );
      final esperados = await cierres.esperado(turno);
      await cierres.cerrar(
        turnoUuid: turno,
        conteos: [for (final e in esperados) ConteoMedio(medio: e, contado: e.esperado)],
      );

      // 3. El auxiliar pide una merma de 1; el gerente la aprueba.
      await como('auxiliar');
      final solicitud = await ajustes.solicitar(
        productoUuid: p['uuid'] as String,
        tipo: 'MERMA',
        cantidad: Cantidad.unidades(1),
        motivo: 'Empaque roto',
      );
      await como('gerente');
      await ajustes.aprobar(solicitud);

      // 4. El gerente da de alta Addi en su sede; el vendedor vende 1 con Addi;
      //    el gerente registra el pago de Addi descontando un 5 %.
      final addi = await metodos.crear(
        nombre: 'Addi ${f['prefijo']}',
        tipo: 'CREDITO',
        sedeUuid: principal,
        comisionPct: 500,
        diasPago: 15,
      );
      await como('vendedor');
      await ventas.registrarVenta(
        lineas: [linea()],
        pagos: [
          PagoDeVenta(
            metodoUuid: addi,
            metodoNombre: 'Addi ${f['prefijo']}',
            metodoTipo: 'CREDITO',
            monto: totalUna,
            referencia: 'APR-${f['prefijo']}',
          ),
        ],
        clienteNombre: 'Cliente Contrato',
        clienteDocumento: '1234567',
        usuarioUuid: uuidDe('vendedor'),
      );
      await como('gerente');
      final cuenta = (await recaudos.observarCuentas().first).singleWhere((c) => c.metodo.uuid == addi);
      final comision = comisionEsperada(cuenta.total, 500);
      await recaudos.registrar(cuenta: cuenta, monto: cuenta.total - comision, comision: comision, referencia: 'CONSIG');

      // Volcado de la cola, en el orden en que la app la enviaría.
      final cola = await (db.select(db.syncOutbox)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
      final ops = [
        for (final o in cola) {'client_op_id': o.clientOpId, 'tipo': o.tipo, 'payload': jsonDecode(o.payload)},
      ];
      final salida = Platform.environment['CONTRATO_OPS'] ?? '${File(rutaFixtures).parent.path}/ops.json';
      File(salida).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(ops));

      expect(ops.map((o) => o['tipo']), [
        'TRASLADO_CREAR',
        'TRASLADO_APROBAR',
        'CIERRE_ABRIR',
        'VENTA_CREAR',
        'CIERRE_CERRAR',
        'AJUSTE_SOLICITAR',
        'AJUSTE_APROBAR',
        'METODO_PAGO_CREAR',
        'VENTA_CREAR',
        'RECAUDO_CREAR',
      ]);
    },
    skip: rutaFixtures == null ? 'Sólo con CONTRATO_FIXTURES (ver backend/scripts/contrato-app.mjs)' : false,
  );
}
