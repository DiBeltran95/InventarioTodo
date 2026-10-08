#!/usr/bin/env node
/**
 * Contrato app ↔ servidor de la operación multisede.
 *
 * El smoke (`smoke-multisede.mjs`) prueba el servidor con cargas escritas a
 * mano. Esto prueba otra cosa: que lo que ENCOLA LA APP —generado por sus
 * propios DAOs, con sus uuid de movimientos, sus aplicaciones de recaudo y sus
 * conteos de caja— lo acepta el servidor y deja el mismo resultado.
 *
 * NO usar contra producción: crea sedes, empleados, ventas y traslados.
 *
 * Tres pasos:
 *   1. node scripts/contrato-app.mjs preparar <fixtures.json> [http://localhost:3999] [email] [clave]
 *      Crea en el servidor una sede, un gerente, un vendedor y un auxiliar, y
 *      escribe sus uuid y los de un producto con stock.
 *   2. (en mobile/) CONTRATO_FIXTURES=<fixtures.json> flutter test test/contrato_app_test.dart
 *      La app ejecuta el flujo en SQLite y vuelca su cola de salida a ops.json.
 *   3. node scripts/contrato-app.mjs enviar <fixtures.json> <ops.json>
 *      Sube cada operación con la sesión de su autor, desde un mismo
 *      dispositivo (como un teléfono compartido), y comprueba el resultado.
 */
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const c = { reset: '\x1b[0m', dim: '\x1b[2m', red: '\x1b[31m', green: '\x1b[32m', cyan: '\x1b[36m' };
let ok = 0;
let fallos = 0;
function afirmar(condicion, descripcion, detalle = '') {
  if (condicion) {
    console.log(`  ${c.green}✓${c.reset} ${descripcion}`);
    ok += 1;
  } else {
    console.log(`  ${c.red}✗ ${descripcion}${c.reset}${detalle ? `\n      ${c.dim}${detalle}${c.reset}` : ''}`);
    fallos += 1;
  }
}
const seccion = (t) => console.log(`\n${c.cyan}${t}${c.reset}`);

function cliente(base, nombre, dispositivo = randomUUID()) {
  const API = `${base}/api/v1`;
  let token = null;
  const pedir = async (metodo, ruta, cuerpo) => {
    const r = await fetch(`${API}${ruta}`, {
      method: metodo,
      headers: {
        'Content-Type': 'application/json',
        'X-Dispositivo': dispositivo,
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: cuerpo ? JSON.stringify(cuerpo) : undefined,
    });
    const json = await r.json().catch(() => null);
    return { status: r.status, data: json?.data, error: json?.error };
  };
  return {
    pedir,
    async entrar(email, clave, sedeUuid) {
      const r = await pedir('POST', '/auth/login', {
        email,
        password: clave,
        dispositivo: { uuid: dispositivo, nombre },
        ...(sedeUuid ? { sede_uuid: sedeUuid } : {}),
      });
      if (r.status === 200) token = r.data.access_token;
      return r;
    },
    async push(operaciones) {
      const r = await pedir('POST', '/sync/push', { operaciones });
      return r.data?.resultados ?? r;
    },
    async pullTodo() {
      // Página a página hasta agotar, como hace la app.
      let cursores = {};
      const todo = {};
      for (let i = 0; i < 50; i++) {
        const r = await pedir('POST', '/sync/pull', { cursores, limite: 500 });
        if (r.status !== 200) throw new Error(`pull ${r.status} ${JSON.stringify(r.error)}`);
        for (const [entidad, bloque] of Object.entries(r.data.entidades)) {
          (todo[entidad] ??= []).push(...(bloque.items ?? []));
          if (bloque.cursor) cursores[entidad] = bloque.cursor;
        }
        if (!r.data.hay_mas) break;
      }
      return todo;
    },
  };
}

const CLAVE = 'Prueba1234';

async function preparar(salida, base = 'http://localhost:3999', email = 'admin@inventario.local', clave = 'Admin1234') {
  const director = cliente(base, 'Director contrato');
  let r = await director.entrar(email, clave);
  if (r.status !== 200) throw new Error(`login director: ${JSON.stringify(r.error)}`);
  const principal = r.data.sedes.find((s) => s.es_principal);

  const codigo = `K${Date.now().toString(36).slice(-4).toUpperCase()}`;
  r = await director.pedir('POST', '/sedes', { nombre: `Sede Contrato ${codigo}`, codigo });
  if (r.status !== 201) throw new Error(`crear sede: ${JSON.stringify(r.error)}`);
  const nueva = r.data;

  const usuarios = {};
  for (const [clave2, rol, sedes] of [
    ['gerente', 'GERENTE', [principal.uuid, nueva.uuid]],
    ['vendedor', 'VENDEDOR', [principal.uuid]],
    ['auxiliar', 'AUXILIAR_INVENTARIO', [principal.uuid]],
  ]) {
    const u = {
      uuid: randomUUID(),
      nombre: `${clave2} ${codigo}`,
      email: `${clave2}.${codigo.toLowerCase()}@contrato.local`,
      rol,
      sedes,
    };
    r = await director.pedir('POST', '/auth/usuarios', { ...u, password: CLAVE });
    if (r.status !== 201) throw new Error(`crear ${clave2}: ${JSON.stringify(r.error)}`);
    usuarios[clave2] = u;
  }

  const datos = await director.pullTodo();
  const stockPrincipal = new Map(
    (datos.stock_sedes ?? []).filter((s) => s.sede_uuid === principal.uuid).map((s) => [s.producto_uuid, Number(s.stock_actual)]),
  );
  const producto = (datos.productos ?? []).find(
    (p) => !p.deleted_at && (p.activo === true || p.activo === 1) && (stockPrincipal.get(p.uuid) ?? 0) >= 20,
  );
  if (!producto) throw new Error('No hay un producto con 20 o más unidades en la sede principal');
  const efectivo = (datos.metodos_pago ?? []).find((m) => m.tipo === 'EFECTIVO' && !m.sede_uuid && !m.deleted_at);
  if (!efectivo) throw new Error('No hay un medio de pago EFECTIVO común');

  const fixtures = {
    base,
    prefijo: codigo,
    principal: { uuid: principal.uuid, nombre: principal.nombre, codigo: principal.codigo },
    nueva: { uuid: nueva.uuid, nombre: nueva.nombre, codigo: nueva.codigo },
    usuarios,
    producto: {
      uuid: producto.uuid,
      sku: producto.sku,
      nombre: producto.nombre,
      precio_venta: producto.precio_venta,
      precio_compra: producto.precio_compra,
      tasa_iva: producto.tasa_iva,
      stock_principal: stockPrincipal.get(producto.uuid),
    },
    efectivo: { uuid: efectivo.uuid, nombre: efectivo.nombre },
  };
  writeFileSync(salida, JSON.stringify(fixtures, null, 2));
  console.log(`Fixtures en ${salida} (producto ${producto.nombre}, ${fixtures.producto.stock_principal} en la principal)`);
}

async function enviar(rutaFixtures, rutaOps) {
  const f = JSON.parse(readFileSync(rutaFixtures, 'utf8'));
  const ops = JSON.parse(readFileSync(rutaOps, 'utf8'));
  const porUuid = Object.fromEntries(Object.values(f.usuarios).map((u) => [u.uuid, u]));

  // Un solo teléfono para todos: así funciona un mostrador compartido.
  const dispositivo = randomUUID();
  const sesiones = {};
  async function sesion(usuarioUuid) {
    if (!sesiones[usuarioUuid]) {
      const u = porUuid[usuarioUuid];
      const cli = cliente(f.base, 'Teléfono contrato', dispositivo);
      const r = await cli.entrar(u.email, CLAVE, f.principal.uuid);
      if (r.status !== 200) throw new Error(`login ${u.email}: ${JSON.stringify(r.error)}`);
      sesiones[usuarioUuid] = cli;
    }
    return sesiones[usuarioUuid];
  }

  seccion('Subida de la cola de la app, en orden, con la sesión de cada autor');
  for (const op of ops) {
    const autor = porUuid[op.payload.usuario_uuid];
    const cli = await sesion(op.payload.usuario_uuid);
    const [res] = await cli.push([{ client_op_id: op.client_op_id, tipo: op.tipo, payload: op.payload }]);
    afirmar(res?.estado === 'OK', `${op.tipo} (${autor?.rol ?? '¿?'})`, JSON.stringify(res?.error ?? res));
  }

  seccion('Lo que quedó en el servidor');
  const gerente = await sesion(f.usuarios.gerente.uuid);
  const d = await gerente.pullTodo();
  const op = (tipo) => ops.find((o) => o.tipo === tipo)?.payload;

  const stock = (sede) =>
    Number((d.stock_sedes ?? []).find((s) => s.producto_uuid === f.producto.uuid && s.sede_uuid === sede)?.stock_actual ?? NaN);
  // Traslado de 3, venta en efectivo de 1, merma de 1, venta a crédito de 1.
  afirmar(stock(f.principal.uuid) === f.producto.stock_principal - 6, `la principal queda en ${f.producto.stock_principal - 6}`, `hay ${stock(f.principal.uuid)}`);
  afirmar(stock(f.nueva.uuid) === 3, 'la sede nueva recibe 3', `hay ${stock(f.nueva.uuid)}`);

  const movs = new Map((d.movimientos_inventario ?? []).map((m) => [m.uuid, m]));
  const aprobacion = op('TRASLADO_APROBAR');
  for (const m of aprobacion?.movimientos ?? []) {
    afirmar(movs.get(m.salida_uuid)?.sede_uuid === f.principal.uuid, 'la salida del traslado tiene el uuid que generó la app');
    afirmar(movs.get(m.entrada_uuid)?.sede_uuid === f.nueva.uuid, 'y la entrada también');
  }
  const lineasVenta = ops.filter((o) => o.tipo === 'VENTA_CREAR').flatMap((o) => o.payload.lineas ?? []);
  afirmar(
    lineasVenta.length > 0 && lineasVenta.every((l) => movs.get(l.movimiento_uuid)?.sede_uuid === f.principal.uuid),
    'los movimientos de las ventas tienen los uuid de la app (no se cuentan dos veces en el teléfono)',
  );
  const ajuste = op('AJUSTE_APROBAR');
  const movAjuste = movs.get(ajuste?.movimiento_uuid);
  afirmar(!!movAjuste, 'la merma aprobada tiene el uuid de la app');
  afirmar(movAjuste?.usuario_uuid === f.usuarios.auxiliar.uuid, 'a nombre del auxiliar que la pidió', JSON.stringify(movAjuste));

  const traslado = (d.traslados ?? []).find((t) => t.uuid === op('TRASLADO_CREAR')?.uuid);
  afirmar(traslado?.estado === 'APROBADO', 'el traslado queda APROBADO');

  const turno = op('CIERRE_ABRIR')?.uuid;
  const ventaEfectivo = (d.ventas ?? []).find((v) => v.uuid === ops.filter((o) => o.tipo === 'VENTA_CREAR')[0]?.payload.uuid);
  afirmar(ventaEfectivo?.turno_uuid === turno, 'la venta en efectivo queda en el turno de la caja');
  afirmar(ventaEfectivo?.sede_uuid === f.principal.uuid, 'y en la sede principal');
  const cierre = (d.cierres_caja ?? []).find((x) => x.uuid === turno);
  afirmar(cierre?.estado === 'CERRADO', 'la caja queda CERRADA', JSON.stringify(cierre));
  afirmar(Number(cierre?.diferencia_efectivo ?? 1) === 0, 'sin diferencia: se contó lo esperado');

  const credito = ops.filter((o) => o.tipo === 'VENTA_CREAR')[1]?.payload;
  const pagoCredito = (d.venta_pagos ?? []).find((p) => p.uuid === credito?.pagos?.[0]?.uuid);
  afirmar(!!pagoCredito && Number(pagoCredito.cobrado) === Number(pagoCredito.monto), 'el recaudo de la entidad salda la venta a crédito', JSON.stringify(pagoCredito));
  const ventaCredito = (d.ventas ?? []).find((v) => v.uuid === credito?.uuid);
  afirmar(!!ventaCredito?.cliente_nombre && !!ventaCredito?.cliente_documento, 'la venta a crédito guarda el cliente');

  console.log(`\n${fallos ? c.red : c.green}${ok} correctas, ${fallos} fallidas${c.reset}`);
  process.exit(fallos ? 1 : 0);
}

const [accion, ...args] = process.argv.slice(2);
const tareas = { preparar, enviar };
if (!tareas[accion]) {
  console.error('Uso: contrato-app.mjs preparar <fixtures.json> [base] [email] [clave] | enviar <fixtures.json> <ops.json>');
  process.exit(2);
}
tareas[accion](...args).catch((e) => {
  console.error(e);
  process.exit(1);
});
