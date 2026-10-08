#!/usr/bin/env node
/**
 * Prueba de punta a punta de la operación multisede contra una API en marcha.
 *
 * NO usar contra producción: crea sedes, empleados, ventas y traslados.
 * Pensada para una base de prueba recién creada con `db:migrate` + `db:seed`.
 *
 * Uso:
 *   node scripts/smoke-multisede.mjs [http://localhost:3999] [admin@inventario.local] [Admin1234]
 *
 * Recorre: sedes, empleados por rol, horario y acceso extra, inhabilitación,
 * stock por sede, traslado con aprobación, venta en una sede, auxiliar que
 * registra entrada y solicita una merma, aprobación del gerente, atribución de
 * ventas subidas con la sesión de otro, cierre de caja con faltante, cobro con
 * entidad de crédito y su recaudo, reportes por sede, cambio de sede y
 * auditoría.
 */
import { randomUUID } from 'node:crypto';

const [BASE = 'http://localhost:3999', EMAIL = 'admin@inventario.local', CLAVE = 'Admin1234'] =
  process.argv.slice(2);
const API = `${BASE}/api/v1`;

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

/** Cliente con su propio dispositivo y sesión. */
function cliente(nombre) {
  const dispositivo = randomUUID();
  let token = null;
  let yo = null;
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
    return { status: r.status, json, data: json?.data, error: json?.error };
  };
  return {
    nombre,
    dispositivo,
    get yo() {
      return yo;
    },
    pedir,
    async entrar(email, clave, sedeUuid) {
      const r = await pedir('POST', '/auth/login', {
        email,
        password: clave,
        dispositivo: { uuid: dispositivo, nombre },
        ...(sedeUuid ? { sede_uuid: sedeUuid } : {}),
      });
      if (r.status === 200) {
        token = r.data.access_token;
        yo = r.data;
      }
      return r;
    },
    async push(operaciones) {
      const r = await pedir('POST', '/sync/push', {
        operaciones: operaciones.map((o) => ({ client_op_id: randomUUID(), ...o })),
      });
      return r.data?.resultados ?? r;
    },
    pull: (cursores = {}) => pedir('POST', '/sync/pull', { cursores }),
  };
}

const ahoraBogota = () => {
  const d = new Date(Date.now() - 5 * 3_600_000);
  return { dia: ((d.getUTCDay() + 6) % 7) + 1, minutos: d.getUTCHours() * 60 + d.getUTCMinutes() };
};
const hhmm = (min) => {
  const m = ((min % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
};

async function main() {
  const director = cliente('Director');
  seccion('1. Director y sedes');
  let r = await director.entrar(EMAIL, CLAVE);
  afirmar(r.status === 200, 'el director entra', JSON.stringify(r.error));
  const principal = r.data.sedes.find((s) => s.es_principal);
  afirmar(!!principal && r.data.sede_activa === principal.uuid, 'el director opera en la sede principal');

  const codigo = `N${Date.now().toString(36).slice(-4).toUpperCase()}`;
  r = await director.pedir('POST', '/sedes', { nombre: `Sede Norte ${codigo}`, codigo });
  afirmar(r.status === 201, 'crea la sede Norte', JSON.stringify(r.error));
  const norte = r.data;

  seccion('2. Empleados por rol y horario');
  const sufijo = Date.now();
  const ahora = ahoraBogota();
  // Un turno que incluye ahora y otro que no: hoy, de 2 h antes a 2 h después;
  // y un turno de hace 6 h a hace 4 h.
  const enTurno = [{ dia: ahora.dia, inicio: hhmm(ahora.minutos - 120), fin: hhmm(ahora.minutos + 120) }];
  const fueraTurno = [{ dia: ahora.dia, inicio: hhmm(ahora.minutos - 360), fin: hhmm(ahora.minutos - 240) }];
  const crear = (nombre, rol, extra = {}) =>
    director.pedir('POST', '/auth/usuarios', {
      nombre,
      email: `${nombre.toLowerCase().replace(/\s/g, '.')}.${sufijo}@prueba.local`,
      password: 'Prueba1234',
      rol,
      sedes: [norte.uuid],
      ...extra,
    });
  const gerente = (await crear('Gerente Norte', 'GERENTE')).data;
  const vendedor = (await crear('Vendedora Ana', 'VENDEDOR', { restringir_horario: true, horario: enTurno })).data;
  const vendedor2 = (await crear('Vendedor Luis', 'VENDEDOR', { restringir_horario: true, horario: fueraTurno })).data;
  const auxiliar = (await crear('Auxiliar Pedro', 'AUXILIAR_INVENTARIO')).data;
  afirmar(gerente && vendedor && vendedor2 && auxiliar, 'crea gerente, dos vendedores y un auxiliar en Norte');
  r = await director.pedir('POST', '/auth/usuarios', {
    nombre: 'Sin sede',
    email: `sinsede.${sufijo}@prueba.local`,
    password: 'Prueba1234',
    rol: 'VENDEDOR',
  });
  afirmar(
    r.status === 201 && r.data.sedes[0]?.uuid === principal.uuid,
    'un vendedor creado sin sede (app vieja) va a la principal',
    JSON.stringify(r.error ?? r.data?.sedes),
  );
  r = await director.pedir('POST', '/auth/usuarios', {
    nombre: 'Gerente sin sede',
    email: `gsinsede.${sufijo}@prueba.local`,
    password: 'Prueba1234',
    rol: 'GERENTE',
  });
  afirmar(r.status === 400 && r.error?.codigo === 'SEDES_INVALIDAS', 'un gerente sin sedes se rechaza');

  const gerenteCli = cliente('Tablet gerente');
  r = await gerenteCli.entrar(gerente.email, 'Prueba1234');
  afirmar(r.status === 200 && r.data.sede_activa === norte.uuid, 'el gerente entra en Norte');
  r = await gerenteCli.pedir('POST', '/auth/usuarios', {
    nombre: 'Otro gerente',
    email: `otro.${sufijo}@prueba.local`,
    password: 'Prueba1234',
    rol: 'GERENTE',
    sedes: [norte.uuid],
  });
  afirmar(r.status === 403, 'un gerente no puede crear gerentes');

  seccion('3. Horario y acceso extra');
  const caja = cliente('Caja Norte');
  r = await caja.entrar(vendedor.email, 'Prueba1234');
  afirmar(r.status === 200 && r.data.jornada.motivo === 'EN_TURNO', 'Ana entra en su turno', JSON.stringify(r.error));
  const luisCli = cliente('Celular Luis');
  r = await luisCli.entrar(vendedor2.email, 'Prueba1234');
  afirmar(r.status === 403 && r.error?.codigo === 'FUERA_DE_HORARIO', 'Luis, fuera de su turno, no entra');
  r = await gerenteCli.pedir('POST', `/auth/usuarios/${vendedor2.uuid}/acceso-extra`, {
    minutos: 60,
    motivo: 'Inventario de fin de mes',
  });
  afirmar(r.status === 200, 'el gerente le da una hora de acceso extra', JSON.stringify(r.error));
  r = await luisCli.entrar(vendedor2.email, 'Prueba1234');
  afirmar(r.status === 200 && r.data.jornada.motivo === 'ACCESO_EXTRA', 'con el acceso extra, Luis entra');

  seccion('4. Disponibilidad en todas las sedes y traslados');
  r = await director.pedir('GET', '/productos?limite=50');
  const producto = r.data.find((p) => Number(p.stock_actual) >= 10);
  afirmar(!!producto, `hay un producto con stock en la principal (${producto?.nombre})`);
  const stockTotalAntes = Number(producto.stock_actual);
  // El stock de la principal se lee aparte: en una base ya usada, parte del
  // total puede estar en otras sedes.
  const pullAntes = await director.pull();
  const principalAntes = Number(
    pullAntes.data.entidades.stock_sedes.items.find(
      (s) => s.producto_uuid === producto.uuid && s.sede_uuid === principal.uuid,
    )?.stock_actual ?? stockTotalAntes,
  );

  // El stock de TODAS las sedes baja a todos; se recorren las páginas porque
  // la fila buscada puede no estar en la primera.
  const stockDe = async (cli, sedeUuid) => {
    let ultimo = null;
    let cursores = {};
    for (let i = 0; i < 50; i++) {
      const p = await cli.pedir('POST', '/sync/pull', { cursores, entidades: ['stock_sedes'] });
      const bloque = p.data.entidades.stock_sedes;
      const fila = bloque.items.findLast((s) => s.producto_uuid === producto.uuid && s.sede_uuid === sedeUuid);
      if (fila) ultimo = Number(fila.stock_actual);
      if (!bloque.hay_mas) break;
      cursores = { stock_sedes: bloque.cursor };
    }
    return ultimo ?? 0;
  };

  afirmar(
    (await stockDe(caja, principal.uuid)) === principalAntes,
    'Ana (vendedora de Norte) ve cuánto hay en la principal',
  );

  let res = await caja.push([
    {
      tipo: 'TRASLADO_CREAR',
      payload: {
        uuid: randomUUID(),
        sede_origen_uuid: principal.uuid,
        sede_destino_uuid: norte.uuid,
        detalles: [{ uuid: randomUUID(), producto_uuid: producto.uuid, cantidad: '1.000' }],
      },
    },
  ]);
  afirmar(res[0]?.error?.codigo === 'SIN_PERMISO', 'Ana sólo consulta: no solicita traslados');

  const traslado = { uuid: randomUUID(), detalle: randomUUID() };
  res = await gerenteCli.push([
    {
      tipo: 'TRASLADO_CREAR',
      payload: {
        uuid: traslado.uuid,
        sede_origen_uuid: principal.uuid,
        sede_destino_uuid: norte.uuid,
        detalles: [{ uuid: traslado.detalle, producto_uuid: producto.uuid, cantidad: '6.000' }],
        notas: 'Para la vitrina',
      },
    },
  ]);
  afirmar(res[0]?.estado === 'OK', 'el gerente de Norte solicita 6 a la principal', JSON.stringify(res[0]?.error));
  afirmar((await stockDe(gerenteCli, norte.uuid)) === 0, 'solicitar no mueve stock');
  res = await gerenteCli.push([{ tipo: 'TRASLADO_APROBAR', payload: { uuid: traslado.uuid } }]);
  afirmar(
    res[0]?.estado === 'ERROR' && res[0]?.error?.codigo === 'SIN_PERMISO',
    'el gerente no despacha su propia solicitud',
  );
  const salida = randomUUID();
  const entrada = randomUUID();
  res = await director.push([
    {
      tipo: 'TRASLADO_APROBAR',
      payload: {
        uuid: traslado.uuid,
        movimientos: [{ detalle_uuid: traslado.detalle, salida_uuid: salida, entrada_uuid: entrada, cantidad: '5.000' }],
      },
    },
  ]);
  afirmar(
    res[0]?.estado === 'OK' && res[0]?.resultado?.parcial === true,
    'el director despacha 5 de las 6 pedidas',
    JSON.stringify(res[0]?.error ?? res[0]?.resultado),
  );
  afirmar((await stockDe(gerenteCli, norte.uuid)) === 5, 'Norte tiene 5');
  afirmar(
    (await stockDe(director, principal.uuid)) === principalAntes - 5,
    `la principal tiene ${principalAntes - 5}`,
  );
  r = await director.pedir('GET', `/productos/${producto.uuid}`);
  afirmar(Number(r.data.stock_actual) === stockTotalAntes, 'el total del producto no cambió con el traslado');

  seccion('5. Venta en Norte y caja');
  const turno = randomUUID();
  res = await caja.push([
    { tipo: 'CIERRE_ABRIR', payload: { uuid: turno, base_efectivo: '50000.00', sede_uuid: norte.uuid } },
  ]);
  afirmar(res[0]?.estado === 'OK', 'Ana abre caja con $50.000', JSON.stringify(res[0]?.error));
  const precio = Number(producto.precio_venta).toFixed(2);
  const venta = randomUUID();
  res = await caja.push([
    {
      tipo: 'VENTA_CREAR',
      payload: {
        uuid: venta,
        sede_uuid: norte.uuid,
        turno_uuid: turno,
        usuario_uuid: vendedor.uuid,
        lineas: [{ producto_uuid: producto.uuid, cantidad: '2.000', precio_unitario: precio }],
        metodo_pago: 'EFECTIVO',
        pagos: [{ metodo_nombre: 'Efectivo', metodo_tipo: 'EFECTIVO', monto: (2 * precio).toFixed(2) }],
      },
    },
  ]);
  afirmar(res[0]?.estado === 'OK', 'Ana vende 2 en Norte', JSON.stringify(res[0]?.error));
  afirmar((await stockDe(gerenteCli, norte.uuid)) === 3, 'Norte queda en 3');
  afirmar(
    (await stockDe(director, principal.uuid)) === principalAntes - 5,
    'la venta de Norte no tocó la principal',
  );

  const faltante = 1000;
  res = await caja.push([
    {
      tipo: 'CIERRE_CERRAR',
      payload: {
        uuid: turno,
        contado: [{ metodo_tipo: 'EFECTIVO', contado: (50000 + 2 * precio - faltante).toFixed(2) }],
        notas: 'Prueba',
      },
    },
  ]);
  afirmar(
    res[0]?.estado === 'OK' && Number(res[0].resultado.diferencia_efectivo) === -faltante,
    `el cierre detecta un faltante de $${faltante}`,
    JSON.stringify(res[0]),
  );

  seccion('6. Auxiliar de inventario');
  const bodega = cliente('Bodega Norte');
  r = await bodega.entrar(auxiliar.email, 'Prueba1234');
  afirmar(r.status === 200, 'el auxiliar entra');
  res = await bodega.push([
    {
      tipo: 'VENTA_CREAR',
      payload: {
        uuid: randomUUID(),
        sede_uuid: norte.uuid,
        lineas: [{ producto_uuid: producto.uuid, cantidad: '1.000', precio_unitario: precio }],
      },
    },
    {
      tipo: 'MOVIMIENTO_CREAR',
      payload: { uuid: randomUUID(), producto_uuid: producto.uuid, tipo: 'ENTRADA', cantidad: '10.000', sede_uuid: norte.uuid },
    },
    {
      tipo: 'MOVIMIENTO_CREAR',
      payload: { uuid: randomUUID(), producto_uuid: producto.uuid, tipo: 'MERMA', cantidad: '1.000', sede_uuid: norte.uuid },
    },
  ]);
  afirmar(res[0]?.error?.codigo === 'SIN_PERMISO', 'el auxiliar no puede vender');
  afirmar(res[1]?.estado === 'OK', 'el auxiliar registra una entrada de 10', JSON.stringify(res[1]?.error));
  afirmar(res[2]?.error?.codigo === 'SIN_PERMISO', 'el auxiliar no registra mermas directas');
  afirmar((await stockDe(gerenteCli, norte.uuid)) === 13, 'Norte sube a 13');

  const solicitud = randomUUID();
  res = await bodega.push([
    {
      tipo: 'AJUSTE_SOLICITAR',
      payload: { uuid: solicitud, producto_uuid: producto.uuid, tipo: 'MERMA', cantidad: '2.000', motivo: 'Vencidos', sede_uuid: norte.uuid },
    },
  ]);
  afirmar(res[0]?.estado === 'OK', 'el auxiliar solicita una merma de 2', JSON.stringify(res[0]?.error));
  afirmar((await stockDe(gerenteCli, norte.uuid)) === 13, 'la solicitud no toca el stock');
  res = await gerenteCli.push([{ tipo: 'AJUSTE_APROBAR', payload: { uuid: solicitud } }]);
  afirmar(res[0]?.estado === 'OK', 'el gerente la aprueba', JSON.stringify(res[0]?.error));
  afirmar((await stockDe(gerenteCli, norte.uuid)) === 11, 'Norte baja a 11');

  res = await bodega.push([
    {
      tipo: 'TRASLADO_CREAR',
      payload: {
        uuid: randomUUID(),
        directo: true,
        sede_origen_uuid: norte.uuid,
        sede_destino_uuid: principal.uuid,
        detalles: [{ uuid: randomUUID(), producto_uuid: producto.uuid, cantidad: '1.000' }],
      },
    },
    {
      tipo: 'TRASLADO_CREAR',
      payload: {
        uuid: randomUUID(),
        directo: true,
        sede_origen_uuid: principal.uuid,
        sede_destino_uuid: norte.uuid,
        detalles: [{ uuid: randomUUID(), producto_uuid: producto.uuid, cantidad: '1.000' }],
      },
    },
    {
      tipo: 'TRASLADO_CREAR',
      payload: {
        uuid: randomUUID(),
        directo: true,
        sede_origen_uuid: norte.uuid,
        sede_destino_uuid: principal.uuid,
        detalles: [{ uuid: randomUUID(), producto_uuid: producto.uuid, cantidad: '999.000' }],
      },
    },
  ]);
  afirmar(res[0]?.estado === 'OK', 'el auxiliar de Norte envía 1 a la principal', JSON.stringify(res[0]?.error));
  afirmar(res[1]?.error?.codigo === 'SIN_PERMISO', 'pero no saca unidades de otra sede');
  afirmar(res[2]?.error?.codigo === 'TRASLADO_SIN_STOCK', 'ni envía más de lo que hay');
  afirmar((await stockDe(gerenteCli, norte.uuid)) === 10, 'Norte queda en 10');

  seccion('7. Atribución: la cola de Ana sube con la sesión de Luis');
  // El turno de Ana terminó con una venta sin subir. Luis entra en el MISMO
  // teléfono (el cliente `caja` conserva el dispositivo y cambia de usuario) y
  // la cola de Ana sube con su sesión.
  const ventaAna = randomUUID();
  r = await caja.entrar(vendedor2.email, 'Prueba1234');
  afirmar(r.status === 200, 'Luis entra en el teléfono de Ana');
  res = await caja.push([
    {
      tipo: 'VENTA_CREAR',
      payload: {
        uuid: ventaAna,
        sede_uuid: norte.uuid,
        usuario_uuid: vendedor.uuid,
        lineas: [{ producto_uuid: producto.uuid, cantidad: '1.000', precio_unitario: precio }],
        pagos: [{ metodo_nombre: 'Efectivo', metodo_tipo: 'EFECTIVO', monto: Number(precio).toFixed(2) }],
      },
    },
    {
      tipo: 'VENTA_ANULAR',
      payload: { venta_uuid: venta, motivo: 'prueba', usuario_uuid: gerente.uuid },
    },
  ]);
  afirmar(res[0]?.estado === 'OK', 'la venta pendiente de Ana se acepta', JSON.stringify(res[0]?.error));
  r = await director.pedir('GET', `/ventas/${ventaAna}`);
  afirmar(r.data?.usuario_uuid === vendedor.uuid, 'y queda a nombre de Ana, no de Luis', JSON.stringify(r.data?.usuario_uuid));
  afirmar(
    res[1]?.error?.codigo === 'AUTOR_NO_AUTENTICADO',
    'una anulación firmada por un gerente que nunca usó ese teléfono se rechaza',
  );

  seccion('8. Entidad de crédito y recaudo');
  const addi = randomUUID();
  res = await director.push([
    {
      tipo: 'METODO_PAGO_CREAR',
      payload: { uuid: addi, nombre: 'Addi', tipo: 'CREDITO', requiere_referencia: true, comision_pct: 5, dias_pago: 8 },
    },
  ]);
  afirmar(res[0]?.estado === 'OK', 'el director crea Addi por la cola (antes tumbaba el lote entero)', JSON.stringify(res[0]?.error));
  const ventaAddi = randomUUID();
  const totalAddi = (2 * precio).toFixed(2);
  r = await caja.entrar(vendedor.email, 'Prueba1234');
  res = await caja.push([
    {
      tipo: 'VENTA_CREAR',
      payload: {
        uuid: ventaAddi,
        sede_uuid: norte.uuid,
        cliente_nombre: 'Marta Gómez',
        cliente_documento: '1020304050',
        lineas: [{ producto_uuid: producto.uuid, cantidad: '2.000', precio_unitario: precio }],
        metodo_pago: 'CREDITO',
        pagos: [{ metodo_pago_uuid: addi, metodo_nombre: 'Addi', metodo_tipo: 'CREDITO', monto: totalAddi, referencia: 'AD-778' }],
      },
    },
  ]);
  afirmar(res[0]?.estado === 'OK', 'Ana vende con Addi', JSON.stringify(res[0]?.error));
  const comision = (totalAddi * 0.05).toFixed(2);
  const neto = (totalAddi - comision).toFixed(2);
  res = await gerenteCli.push([
    {
      tipo: 'RECAUDO_CREAR',
      payload: { uuid: randomUUID(), metodo_pago_uuid: addi, fecha: new Date().toISOString().slice(0, 10), monto: neto, comision, referencia: 'CONSIG-1' },
    },
  ]);
  afirmar(res[0]?.estado === 'OK' && res[0].resultado.aplicadas === 1, 'el gerente registra el pago de Addi', JSON.stringify(res[0]?.error));
  const p = await gerenteCli.pull();
  const pago = p.data.entidades.venta_pagos.items.find((x) => x.metodo_pago_uuid === addi);
  afirmar(pago && Number(pago.cobrado) === Number(totalAddi), 'la venta queda saldada (neto + comisión)');

  seccion('9. Alcance y reportes');
  const pv = await gerenteCli.pull();
  const sedesVentas = new Set(pv.data.entidades.ventas.items.map((v) => v.sede_uuid));
  afirmar(sedesVentas.size === 1 && sedesVentas.has(norte.uuid), 'el gerente de Norte sólo baja ventas de Norte');
  r = await gerenteCli.pedir('GET', '/reportes/por-sede?periodo=hoy');
  afirmar(r.status === 200 && r.data.length === 1, 'el reporte por sede del gerente sólo muestra Norte');
  r = await gerenteCli.pedir('GET', `/reportes/dashboard?sede=${principal.uuid}`);
  afirmar(r.status === 403, 'el gerente no ve el dashboard de la principal');
  r = await director.pedir('GET', '/reportes/por-sede?periodo=hoy');
  afirmar(r.status === 200 && r.data.length >= 2, 'el director ve todas las sedes');
  r = await director.pedir('GET', '/reportes/metodos-pago?periodo=hoy');
  afirmar(r.status === 200, 'el reporte por medio de pago ya no responde 500');

  seccion('10. Cambio de sede');
  r = await luisCli.entrar(vendedor2.email, 'Prueba1234');
  r = await luisCli.pedir('POST', '/sedes/cambios', { sede_uuid: principal.uuid, motivo: 'Vivo cerca' });
  afirmar(r.status === 201, 'Luis pide pasar a la principal', JSON.stringify(r.error));
  r = await gerenteCli.pedir('POST', `/sedes/cambios/${r.data.uuid}/aceptar`);
  afirmar(r.status === 403, 'el gerente de Norte no puede aceptarlo (la destino es la principal)');
  const lista = await director.pedir('GET', '/sedes/cambios');
  const sol = lista.data.find((s) => s.empleado.uuid === vendedor2.uuid);
  r = await director.pedir('POST', `/sedes/cambios/${sol.uuid}/aceptar`);
  afirmar(r.status === 200, 'el director lo acepta');
  const despues = await director.pedir('GET', '/sedes/cambios');
  afirmar(!despues.data.some((s) => s.uuid === sol.uuid), 'la solicitud se borra al resolverse');

  seccion('11. Inhabilitar');
  r = await gerenteCli.pedir('PATCH', `/auth/usuarios/${vendedor.uuid}`, { activo: false });
  afirmar(r.status === 200, 'el gerente inhabilita a Ana');
  r = await caja.pull();
  afirmar(r.status === 403 && r.error?.codigo === 'CUENTA_DESACTIVADA', 'su siguiente petición se rechaza');
  r = await caja.entrar(vendedor.email, 'Prueba1234');
  afirmar(r.status === 401 && r.error?.codigo === 'CUENTA_DESACTIVADA', 'y no puede volver a entrar');

  seccion('12. Auditoría');
  r = await director.pedir('GET', '/auditoria?limite=200');
  const acciones = new Set((r.data ?? []).map((a) => a.accion));
  for (const a of [
    'USUARIO_CREADO',
    'ACCESO_EXTRA_OTORGADO',
    'TRASLADO_APROBADO',
    'ENTRADA_REGISTRADA',
    'AJUSTE_SOLICITADO',
    'AJUSTE_APROBADO',
    'CIERRE_CON_DIFERENCIA',
    'RECAUDO_REGISTRADO',
    'SEDES_CAMBIADAS',
    'USUARIO_DESACTIVADO',
    'INGRESO_FUERA_DE_HORARIO',
  ]) {
    afirmar(acciones.has(a), `auditoría registra ${a}`);
  }
  r = await gerenteCli.pedir('GET', '/auditoria?limite=200');
  afirmar(
    r.status === 200 && r.data.every((a) => !a.sede || a.sede.uuid === norte.uuid),
    'el gerente sólo ve la auditoría de Norte',
  );

  console.log(`\n${fallos ? c.red : c.green}${ok} correctas, ${fallos} fallidas${c.reset}`);
  process.exit(fallos ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
