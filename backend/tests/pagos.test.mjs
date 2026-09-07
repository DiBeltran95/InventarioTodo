import test from 'node:test';
import assert from 'node:assert/strict';
import { crearVentaSchema } from '../src/modules/ventas/schemas.js';
import { toCents, sumar } from '../src/utils/money.js';

const LINEA = {
  producto_uuid: '11111111-1111-4111-8111-111111111111',
  cantidad: '2.000',
  precio_unitario: '10000.00',
};

const venta = (extra) => crearVentaSchema.safeParse({ lineas: [LINEA], ...extra });

test('una venta SIN desglose de pagos sigue siendo válida', () => {
  // Compatibilidad hacia atrás: los dispositivos que aún no se han actualizado
  // mandan sólo `metodo_pago`. Rechazarlas dejaría ventas atrapadas en su cola
  // de salida, que es justo lo que el modo offline promete que no pasa.
  const r = venta({ metodo_pago: 'EFECTIVO', monto_recibido: '20000.00' });
  assert.ok(r.success, 'debería aceptarse sin el campo `pagos`');
  assert.equal(r.data.pagos, undefined);
});

test('acepta un cobro repartido entre varios medios', () => {
  const r = venta({
    pagos: [
      { metodo_nombre: 'Efectivo', metodo_tipo: 'EFECTIVO', monto: '12000.00' },
      { metodo_nombre: 'Nequi', metodo_tipo: 'TRANSFERENCIA', monto: '8000.00' },
    ],
  });
  assert.ok(r.success);
  assert.equal(r.data.pagos.length, 2);
});

test('el medio de pago admite nombres libres del negocio', () => {
  // El nombre es del negocio («Nequi», «Llave Bre-B», «Datáfono Bancolombia»);
  // lo acotado es el TIPO, porque gobierna el comportamiento del cobro.
  const r = venta({
    pagos: [{ metodo_nombre: 'Llave Bre-B @mitienda', metodo_tipo: 'TRANSFERENCIA', monto: '20000.00' }],
  });
  assert.ok(r.success);
  assert.equal(r.data.pagos[0].metodo_nombre, 'Llave Bre-B @mitienda');
});

test('rechaza un tipo de medio desconocido', () => {
  const r = venta({
    pagos: [{ metodo_nombre: 'Cripto', metodo_tipo: 'BITCOIN', monto: '20000.00' }],
  });
  assert.ok(!r.success, 'un tipo fuera del vocabulario rompería el cobro');
});

test('guarda la referencia del datáfono o de la transferencia', () => {
  // Es lo que permite cuadrar la caja contra el extracto al cierre del día.
  const r = venta({
    pagos: [
      {
        metodo_nombre: 'Datáfono',
        metodo_tipo: 'TARJETA',
        monto: '20000.00',
        referencia: 'APROB-884213',
      },
    ],
  });
  assert.ok(r.success);
  assert.equal(r.data.pagos[0].referencia, 'APROB-884213');
});

test('exige al menos un pago si se envía el desglose', () => {
  assert.ok(!venta({ pagos: [] }).success);
});

test('la suma de los pagos se compara en centavos enteros', () => {
  // El servidor rechaza el cobro si no cuadra. La comprobación se hace sobre
  // enteros y NO sobre coma flotante: 0.1 + 0.2 !== 0.3 en IEEE-754, y aceptar
  // una venta descuadrada por un peso deja un agujero que nadie sabe dónde
  // buscar al cerrar la caja.
  const total = toCents('20000.00');

  const cuadra = sumar([toCents('12000.00'), toCents('8000.00')]);
  assert.equal(cuadra, total);

  const noCuadra = sumar([toCents('12000.00'), toCents('7999.99')]);
  assert.notEqual(noCuadra, total);
  assert.equal(total - noCuadra, 1n, 'falta exactamente un centavo');
});

test('tres decimales imposibles no se cuelan en un importe', () => {
  const r = venta({
    pagos: [{ metodo_nombre: 'Efectivo', metodo_tipo: 'EFECTIVO', monto: 'diez mil' }],
  });
  assert.ok(!r.success);
});
