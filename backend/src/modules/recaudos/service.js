/**
 * Recaudos: lo que paga una entidad de crédito (Addi, Crediya…) por las ventas
 * que financió.
 *
 * La venta se cobró con un medio de tipo CREDITO: el cliente se llevó la
 * mercancía y la entidad le paga al negocio después, normalmente descontando una
 * comisión. Cada pago de ese tipo es una cuenta por cobrar contra la entidad;
 * `venta_pagos.cobrado` lleva cuánto ya pagó.
 *
 * Un recaudo («Addi consignó $480.000 el 12 de octubre») se reparte entre los
 * pagos pendientes, del más antiguo al más nuevo, salvo que se indique a
 * cuáles. Lo que se descuenta de la deuda es lo recibido MÁS la comisión: la
 * comisión también salda la venta, sólo que no llega a la cuenta.
 */
import { txQuery, txQueryOne, txExecute } from '../../db/tx.js';
import { nuevoUuid } from '../../utils/ids.js';
import { badRequest, conflict, forbidden, notFound } from '../../utils/ApiError.js';
import { toCents, fromCents } from '../../utils/money.js';
import { ROLES_GESTORES } from '../../config/constants.js';
import { filtroSede } from '../../domain/alcance.js';
import { aplicarRecaudo } from '../../domain/caja.js';
import { registrarAuditoria, ACCIONES } from '../../utils/auditoria.js';

export async function crearRecaudo(conn, p, ctx) {
  if (!ROLES_GESTORES.includes(ctx.rol)) {
    throw forbidden('Los recaudos los registra el gerente o el director', 'SIN_PERMISO');
  }
  const uuid = p.uuid ?? nuevoUuid();
  const existente = await txQueryOne(conn, 'SELECT uuid FROM recaudos WHERE uuid = ?', [uuid]);
  if (existente) return { uuid, duplicado: true };

  const metodo = await txQueryOne(
    conn,
    'SELECT id, uuid, nombre, tipo FROM metodos_pago WHERE uuid = ?',
    [p.metodo_pago_uuid],
  );
  if (!metodo) throw notFound('Medio de pago');
  if (metodo.tipo !== 'CREDITO') {
    throw badRequest('NO_ES_CREDITO', `${metodo.nombre} no es una entidad de crédito`);
  }

  const monto = toCents(p.monto ?? '0');
  const comision = toCents(p.comision ?? '0');
  if (monto < 0n || comision < 0n || monto + comision <= 0n) {
    throw badRequest('MONTO_INVALIDO', 'Indica cuánto pagó la entidad');
  }
  const total = monto + comision;

  // Pendientes de esta entidad en las sedes del gestor, del más antiguo al más
  // nuevo, bloqueados: dos recaudos simultáneos no pueden saldar lo mismo.
  const alc = filtroSede('v.sede_id', ctx.alcance);
  const pendientes = await txQuery(
    conn,
    `SELECT vp.id, vp.uuid, vp.monto, vp.cobrado, v.numero, v.sede_id
       FROM venta_pagos vp
       JOIN ventas v ON v.id = vp.venta_id
      WHERE vp.metodo_pago_id = ? AND v.estado = 'COMPLETADA' AND v.deleted_at IS NULL
        AND vp.cobrado < vp.monto AND ${alc.sql}
      ORDER BY v.fecha, vp.id
      FOR UPDATE`,
    [metodo.id, ...alc.params],
  );
  const pendienteDe = (f) => toCents(f.monto) - toCents(f.cobrado);

  let aplicaciones;
  if (p.aplicaciones?.length) {
    // Aplicación indicada a mano: cada monto cabe en lo pendiente de su pago, y
    // la suma es exactamente lo recaudado.
    const porUuid = new Map(pendientes.map((f) => [f.uuid, f]));
    aplicaciones = p.aplicaciones.map((a) => {
      const f = porUuid.get(a.venta_pago_uuid);
      if (!f) throw badRequest('PAGO_NO_PENDIENTE', 'Uno de los pagos ya no está pendiente o no es de tu sede');
      const m = toCents(a.monto);
      if (m <= 0n || m > pendienteDe(f)) {
        throw badRequest('APLICACION_INVALIDA', `A la venta ${f.numero} se le aplica más de lo que debe`);
      }
      return { id: f.id, monto: m };
    });
    const suma = aplicaciones.reduce((s, a) => s + a.monto, 0n);
    if (suma !== total) {
      throw badRequest(
        'APLICACION_NO_CUADRA',
        `Lo aplicado (${fromCents(suma)}) no es igual a lo recaudado más la comisión (${fromCents(total)})`,
      );
    }
  } else {
    const r = aplicarRecaudo(
      pendientes.map((f) => ({ id: f.id, pendiente: pendienteDe(f) })),
      total,
    );
    if (r.sobrante > 0n) {
      throw conflict(
        'RECAUDO_EXCEDE',
        `${metodo.nombre} pagó ${fromCents(r.sobrante)} más de lo que tiene pendiente. Revisa el monto o la comisión.`,
      );
    }
    aplicaciones = r.aplicaciones;
  }

  const sedeUnica = new Set(pendientes.filter((f) => aplicaciones.some((a) => a.id === f.id)).map((f) => f.sede_id));
  const r = await txExecute(
    conn,
    `INSERT INTO recaudos
       (uuid, metodo_pago_id, sede_id, fecha, monto, comision, referencia, notas,
        aplicaciones, registrado_por, dispositivo_uuid)
     VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
    [
      uuid,
      metodo.id,
      sedeUnica.size === 1 ? [...sedeUnica][0] : null,
      p.fecha,
      fromCents(monto),
      fromCents(comision),
      p.referencia ?? null,
      p.notas ?? null,
      JSON.stringify(
        aplicaciones.map((a) => ({
          venta_pago_uuid: pendientes.find((f) => f.id === a.id).uuid,
          monto: fromCents(a.monto),
        })),
      ),
      ctx.usuarioId,
      ctx.dispositivoUuid ?? null,
    ],
  );

  for (const a of aplicaciones) {
    await txExecute(
      conn,
      'INSERT INTO recaudo_aplicaciones (recaudo_id, venta_pago_id, monto) VALUES (?,?,?)',
      [r.insertId, a.id, fromCents(a.monto)],
    );
    await txExecute(conn, 'UPDATE venta_pagos SET cobrado = cobrado + ? WHERE id = ?', [
      fromCents(a.monto),
      a.id,
    ]);
  }

  await registrarAuditoria(conn, {
    usuarioId: ctx.usuarioId,
    sedeId: sedeUnica.size === 1 ? [...sedeUnica][0] : null,
    dispositivoUuid: ctx.dispositivoUuid,
    accion: ACCIONES.RECAUDO_REGISTRADO,
    entidad: 'recaudos',
    entidadUuid: uuid,
    despues: {
      entidad: metodo.nombre,
      monto: fromCents(monto),
      comision: fromCents(comision),
      ventas: aplicaciones.length,
      referencia: p.referencia ?? null,
    },
  });

  return { uuid, aplicadas: aplicaciones.length, total: fromCents(total) };
}
