import test from 'node:test';
import assert from 'node:assert/strict';
import {
  veSede,
  filtroSede,
  huellaAlcance,
  puedeAdministrar,
  validarSedesDeRol,
} from '../src/domain/alcance.js';
import {
  puedeSolicitar,
  puedeMover,
  puedeDespachar,
  puedeCancelar,
  repartoDeDespacho,
} from '../src/domain/traslados.js';
import { calcularEsperado, compararConteo, aplicarRecaudo } from '../src/domain/caja.js';

// Sedes: 1 = principal, 2 = norte, 3 = sur.
const director = { id: 1, rol: 'ADMIN', alcance: { esDirector: true, sedeIds: [] } };
const gerenteNorte = { id: 2, rol: 'GERENTE', alcance: { esDirector: false, sedeIds: [2] } };
const gerenteVarias = { id: 3, rol: 'GERENTE', alcance: { esDirector: false, sedeIds: [2, 3] } };
const vendedorNorte = { id: 4, rol: 'VENDEDOR', alcance: { esDirector: false, sedeIds: [2] } };
const vendedorSur = { id: 5, rol: 'VENDEDOR', alcance: { esDirector: false, sedeIds: [3] } };
const auxNorte = { id: 6, rol: 'AUXILIAR_INVENTARIO', alcance: { esDirector: false, sedeIds: [2] } };
const auxSur = { id: 7, rol: 'AUXILIAR_INVENTARIO', alcance: { esDirector: false, sedeIds: [3] } };

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

test('el gerente solicita unidades PARA una sede suya y desde otra', () => {
  assert.equal(puedeSolicitar(gerenteNorte, 3, 2), null, 'de Sur para Norte');
  assert.equal(puedeSolicitar(gerenteVarias, 2, 3), null, 'entre dos sedes suyas también');
  assert.match(puedeSolicitar(gerenteNorte, 2, 3), /para una sede tuya/, 'no pide para otra sede');
  assert.match(puedeSolicitar(gerenteNorte, 2, 2), /distintas/);
});

test('el vendedor sólo consulta; el director y el auxiliar no solicitan, mueven', () => {
  assert.match(puedeSolicitar(vendedorNorte, 3, 2), /Sólo un gerente/);
  assert.match(puedeSolicitar(director, 3, 2), /directamente/);
  assert.match(puedeSolicitar(auxNorte, 3, 2), /directamente/);
});

test('mueve unidades el director entre cualesquiera sedes, y el auxiliar desde la suya', () => {
  assert.equal(puedeMover(director, 1, 3), null);
  assert.equal(puedeMover(auxNorte, 2, 3), null, 'desde su sede');
  assert.match(puedeMover(auxNorte, 3, 2), /desde tu sede/, 'no saca de otra sede');
  assert.match(puedeMover(gerenteNorte, 2, 3), /Director General o el auxiliar/, 'el gerente solicita');
  assert.match(puedeMover(vendedorNorte, 2, 3), /Director General o el auxiliar/);
  assert.match(puedeMover(director, 2, 2), /distintas/);
});

test('despacha la solicitud el auxiliar de la sede origen o el director', () => {
  const t = { estado: 'PENDIENTE', sede_origen_id: 3, solicitado_por: gerenteNorte.id };
  assert.equal(puedeDespachar(t, auxSur), null);
  assert.equal(puedeDespachar(t, director), null);
  assert.match(puedeDespachar(t, auxNorte), /de la sede de origen/, 'auxiliar de otra sede');
  assert.match(puedeDespachar(t, gerenteVarias), /de la sede de origen/, 'ni el gerente de la sede origen');
  assert.match(puedeDespachar(t, vendedorSur), /de la sede de origen/);
  assert.match(puedeDespachar({ ...t, estado: 'APROBADO' }, director), /ya fue resuelto/);
});

test('cancela quien lo pidió o el director, mientras esté pendiente', () => {
  const t = { estado: 'PENDIENTE', solicitado_por: gerenteNorte.id };
  assert.equal(puedeCancelar(t, gerenteNorte), null);
  assert.equal(puedeCancelar(t, director), null);
  assert.match(puedeCancelar(t, auxSur), /quien lo pidió/);
  assert.match(puedeCancelar({ ...t, estado: 'RECHAZADO' }, gerenteNorte), /ya fue resuelto/);
});

test('al despachar se pueden enviar menos unidades, o ninguna de una línea, pero algo', () => {
  const detalles = [
    { uuid: 'a', cantidad: 5000n },
    { uuid: 'b', cantidad: 2000n },
  ];
  // Sin indicar nada: sale todo lo pedido (teléfonos anteriores).
  assert.deepEqual(repartoDeDespacho(detalles, new Map()).total, 7000n);

  const parcial = repartoDeDespacho(detalles, new Map([['a', 3000n], ['b', 0n]]));
  assert.equal(parcial.total, 3000n);
  assert.deepEqual(parcial.lineas.map((l) => [l.uuid, l.pedida, l.enviada]), [
    ['a', 5000n, 3000n],
    ['b', 2000n, 0n],
  ]);

  assert.match(repartoDeDespacho(detalles, new Map([['a', 0n], ['b', 0n]])).error, /recházalo/);
  assert.match(repartoDeDespacho(detalles, new Map([['a', -1n]])).error, /negativa/);
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
