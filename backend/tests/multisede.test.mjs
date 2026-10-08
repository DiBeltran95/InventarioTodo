import test from 'node:test';
import assert from 'node:assert/strict';
import {
  veSede,
  filtroSede,
  huellaAlcance,
  puedeAdministrar,
  validarSedesDeRol,
} from '../src/domain/alcance.js';
import { quienConfirma, puedeCrear, puedeResolver, puedeCancelar } from '../src/domain/traslados.js';
import { calcularEsperado, compararConteo, aplicarRecaudo } from '../src/domain/caja.js';

// Sedes: 1 = principal, 2 = norte, 3 = sur.
const director = { id: 1, rol: 'ADMIN', alcance: { esDirector: true, sedeIds: [] } };
const gerenteNorte = { id: 2, rol: 'GERENTE', alcance: { esDirector: false, sedeIds: [2] } };
const gerenteVarias = { id: 3, rol: 'GERENTE', alcance: { esDirector: false, sedeIds: [2, 3] } };
const vendedorNorte = { id: 4, rol: 'VENDEDOR', alcance: { esDirector: false, sedeIds: [2] } };
const vendedorSur = { id: 5, rol: 'VENDEDOR', alcance: { esDirector: false, sedeIds: [3] } };
const auxNorte = { id: 6, rol: 'AUXILIAR_INVENTARIO', alcance: { esDirector: false, sedeIds: [2] } };

// ── Alcance ─────────────────────────────────────────────────────────────────

test('el director ve todas las sedes; el gerente sólo las suyas', () => {
  assert.equal(veSede(director.alcance, 3), true);
  assert.equal(veSede(gerenteNorte.alcance, 2), true);
  assert.equal(veSede(gerenteNorte.alcance, 3), false);
  assert.equal(veSede(gerenteVarias.alcance, '3'), true, 'el id puede llegar como texto');
});

test('el filtro SQL del alcance nunca genera IN () vacío', () => {
  assert.deepEqual(filtroSede('v.sede_id', { esDirector: false, sedeIds: [] }).params, [0, [0]]);
  assert.deepEqual(filtroSede('v.sede_id', director.alcance).params, [1, [0]]);
  assert.deepEqual(filtroSede('v.sede_id', gerenteVarias.alcance).params, [0, [2, 3]]);
});

test('la huella del alcance cambia al cambiar de sede, no al reordenarlas', () => {
  const a = huellaAlcance('GERENTE', { esDirector: false, sedeIds: [2, 3] });
  assert.equal(a, huellaAlcance('GERENTE', { esDirector: false, sedeIds: [3, 2] }));
  assert.notEqual(a, huellaAlcance('GERENTE', { esDirector: false, sedeIds: [2] }));
  assert.notEqual(a, huellaAlcance('VENDEDOR', { esDirector: false, sedeIds: [2, 3] }));
});

test('un gerente administra vendedores y auxiliares de sus sedes, y nada más', () => {
  const gestor = { rol: 'GERENTE', alcance: gerenteNorte.alcance };
  assert.equal(puedeAdministrar(gestor, { rol: 'VENDEDOR', sedeIds: [2] }), true);
  assert.equal(puedeAdministrar(gestor, { rol: 'AUXILIAR_INVENTARIO', sedeIds: [2] }), true);
  assert.equal(puedeAdministrar(gestor, { rol: 'VENDEDOR', sedeIds: [3] }), false, 'otra sede');
  assert.equal(puedeAdministrar(gestor, { rol: 'GERENTE', sedeIds: [2] }), false, 'otro gerente');
  assert.equal(puedeAdministrar(gestor, { rol: 'ADMIN', sedeIds: [] }), false, 'el director');
  assert.equal(puedeAdministrar({ rol: 'VENDEDOR', alcance: vendedorNorte.alcance }, { rol: 'VENDEDOR', sedeIds: [2] }), false);
  assert.equal(puedeAdministrar({ rol: 'ADMIN', alcance: director.alcance }, { rol: 'GERENTE', sedeIds: [2] }), true);
});

test('cada rol tiene el número de sedes que le corresponde', () => {
  assert.equal(validarSedesDeRol('VENDEDOR', [2]), null);
  assert.match(validarSedesDeRol('VENDEDOR', [2, 3]), /exactamente una/);
  assert.match(validarSedesDeRol('AUXILIAR_INVENTARIO', []), /exactamente una/);
  assert.equal(validarSedesDeRol('GERENTE', [2, 3]), null);
  assert.match(validarSedesDeRol('GERENTE', []), /al menos una/);
  assert.equal(validarSedesDeRol('ADMIN', []), null);
  assert.match(validarSedesDeRol('ADMIN', [1]), /todas las sedes/);
});

// ── Traslados ───────────────────────────────────────────────────────────────

test('si lo pide un empleado lo aprueba un gestor; si lo pide un gestor, la sede origen', () => {
  assert.equal(quienConfirma('VENDEDOR'), 'GESTOR');
  assert.equal(quienConfirma('GERENTE'), 'ORIGEN');
  assert.equal(quienConfirma('ADMIN'), 'ORIGEN');
});

test('se pide desde o hacia una sede propia; el auxiliar no pide traslados', () => {
  assert.equal(puedeCrear(vendedorNorte, 2, 3), null, 'enviar desde la suya');
  assert.equal(puedeCrear(vendedorNorte, 3, 2), null, 'pedir para la suya');
  assert.match(puedeCrear(vendedorNorte, 1, 3), /desde o hacia una sede tuya/);
  assert.match(puedeCrear(vendedorNorte, 2, 2), /distintas/);
  assert.match(puedeCrear(auxNorte, 2, 3), /no puede pedir/);
});

test('un traslado pedido por un vendedor lo aprueba el gerente de la sede origen, no otro vendedor', () => {
  const t = { estado: 'PENDIENTE', confirma: 'GESTOR', sede_origen_id: 2, solicitado_por: vendedorNorte.id };
  assert.equal(puedeResolver(t, gerenteNorte), null);
  assert.equal(puedeResolver(t, director), null);
  assert.match(puedeResolver(t, { ...vendedorNorte, id: 99 }), /lo aprueba el gerente/);
  assert.match(puedeResolver(t, vendedorSur), /sede de origen/);
});

test('un traslado pedido por un gerente lo confirma alguien de la sede origen', () => {
  const t = { estado: 'PENDIENTE', confirma: 'ORIGEN', sede_origen_id: 3, solicitado_por: gerenteNorte.id };
  assert.equal(puedeResolver(t, vendedorSur), null);
  assert.match(puedeResolver(t, vendedorNorte), /sede de origen/);
});

test('nadie confirma su propio traslado, ni uno ya resuelto', () => {
  const t = { estado: 'PENDIENTE', confirma: 'ORIGEN', sede_origen_id: 2, solicitado_por: gerenteNorte.id };
  assert.match(puedeResolver(t, gerenteNorte), /otra persona/);
  assert.match(puedeResolver({ ...t, estado: 'APROBADO' }, vendedorNorte), /ya fue resuelto/);
});

test('cancela quien lo pidió o el director', () => {
  const t = { estado: 'PENDIENTE', solicitado_por: vendedorNorte.id };
  assert.equal(puedeCancelar(t, vendedorNorte), null);
  assert.equal(puedeCancelar(t, director), null);
  assert.match(puedeCancelar(t, gerenteNorte), /quien lo pidió/);
});

// ── Cierre de caja ──────────────────────────────────────────────────────────

test('lo esperado en efectivo es la base más lo cobrado en efectivo', () => {
  const esperados = calcularEsperado(5_000_000n, [
    { metodo_uuid: 'e', metodo_nombre: 'Efectivo', metodo_tipo: 'EFECTIVO', monto: 3_000_000n },
    { metodo_uuid: 'n', metodo_nombre: 'Nequi', metodo_tipo: 'TRANSFERENCIA', monto: 1_200_000n },
    { metodo_uuid: 'e', metodo_nombre: 'Efectivo', metodo_tipo: 'EFECTIVO', monto: 500_000n },
  ]);
  assert.equal(esperados[0].metodo_tipo, 'EFECTIVO', 'el efectivo va primero');
  assert.equal(esperados[0].esperado, 8_500_000n);
  assert.equal(esperados[1].esperado, 1_200_000n);
});

test('sin ventas en efectivo, sigue habiendo que contar la base', () => {
  const [efectivo] = calcularEsperado(2_000_000n, []);
  assert.equal(efectivo.esperado, 2_000_000n);
});

test('un faltante sale negativo, y lo que no se contó no inventa diferencia', () => {
  const esperados = calcularEsperado(0n, [
    { metodo_uuid: 'e', metodo_nombre: 'Efectivo', metodo_tipo: 'EFECTIVO', monto: 1_000_000n },
    { metodo_uuid: 't', metodo_nombre: 'Datáfono', metodo_tipo: 'TARJETA', monto: 700_000n },
  ]);
  const r = compararConteo(esperados, [{ metodo_tipo: 'EFECTIVO', contado: 950_000n }]);
  assert.equal(r.diferenciaEfectivo, -50_000n);
  assert.equal(r.detalle.find((d) => d.metodo_tipo === 'TARJETA').diferencia, null);
});

// ── Cuentas por cobrar ──────────────────────────────────────────────────────

test('un recaudo paga primero lo más antiguo, y un pago a medias queda a medias', () => {
  const r = aplicarRecaudo(
    [
      { id: 10, pendiente: 300_000n },
      { id: 11, pendiente: 500_000n },
      { id: 12, pendiente: 200_000n },
    ],
    600_000n,
  );
  assert.deepEqual(r.aplicaciones, [
    { id: 10, monto: 300_000n },
    { id: 11, monto: 300_000n },
  ]);
  assert.equal(r.sobrante, 0n);
});

test('cobrar más de lo pendiente deja un sobrante, no un pago inventado', () => {
  const r = aplicarRecaudo([{ id: 1, pendiente: 100_000n }], 150_000n);
  assert.deepEqual(r.aplicaciones, [{ id: 1, monto: 100_000n }]);
  assert.equal(r.sobrante, 50_000n);
});
