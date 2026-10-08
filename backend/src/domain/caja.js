/**
 * Cierre de caja y cobro a entidades de crédito: el cálculo, sin base de datos.
 *
 * Todo en CENTAVOS (BigInt). Ver src/utils/money.js: el dinero nunca pasa por
 * un número de coma flotante.
 */

/**
 * Lo que debería haber por medio de pago al cerrar el turno.
 *
 * @param baseEfectivo  centavos con los que se abrió la caja
 * @param cobros        [{ metodo_uuid, metodo_nombre, metodo_tipo, monto }] —
 *                      suma por medio de las ventas COMPLETADAS del turno. El
 *                      monto de un pago en efectivo ya es neto de vueltas.
 * @returns [{ metodo_uuid, metodo_nombre, metodo_tipo, esperado }]
 *          El efectivo siempre aparece, aunque no se haya vendido nada en
 *          efectivo: la base sigue en el cajón y hay que contarla.
 */
export function calcularEsperado(baseEfectivo, cobros) {
  const porMedio = new Map();
  for (const c of cobros) {
    const clave = c.metodo_tipo === 'EFECTIVO' ? 'EFECTIVO' : (c.metodo_uuid ?? c.metodo_nombre);
    const previo = porMedio.get(clave);
    porMedio.set(clave, {
      metodo_uuid: previo?.metodo_uuid ?? c.metodo_uuid ?? null,
      metodo_nombre: c.metodo_tipo === 'EFECTIVO' ? 'Efectivo' : c.metodo_nombre,
      metodo_tipo: c.metodo_tipo,
      esperado: (previo?.esperado ?? 0n) + BigInt(c.monto),
    });
  }
  const efectivo = porMedio.get('EFECTIVO');
  porMedio.set('EFECTIVO', {
    metodo_uuid: efectivo?.metodo_uuid ?? null,
    metodo_nombre: 'Efectivo',
    metodo_tipo: 'EFECTIVO',
    esperado: (efectivo?.esperado ?? 0n) + BigInt(baseEfectivo),
  });
  return [...porMedio.values()].sort((a, b) =>
    a.metodo_tipo === 'EFECTIVO' ? -1 : b.metodo_tipo === 'EFECTIVO' ? 1 : a.metodo_nombre.localeCompare(b.metodo_nombre),
  );
}

/**
 * Cruza lo esperado con lo contado.
 *
 * Los medios que no se contaron (`contado` ausente) quedan sin diferencia: un
 * datáfono puede no permitir verificar en el momento, y forzar un 0 inventaría
 * un faltante que no existe.
 *
 * @param contados [{ metodo_uuid?, metodo_tipo, contado }] en centavos
 */
export function compararConteo(esperados, contados) {
  const buscar = (e) =>
    contados.find((c) =>
      e.metodo_tipo === 'EFECTIVO' ? c.metodo_tipo === 'EFECTIVO' : c.metodo_uuid === e.metodo_uuid,
    );
  const detalle = esperados.map((e) => {
    const c = buscar(e);
    const contado = c?.contado == null ? null : BigInt(c.contado);
    return { ...e, contado, diferencia: contado == null ? null : contado - e.esperado };
  });
  const efectivo = detalle.find((d) => d.metodo_tipo === 'EFECTIVO');
  return {
    detalle,
    diferenciaEfectivo: efectivo?.diferencia ?? null,
    esperadoTotal: detalle.reduce((s, d) => s + d.esperado, 0n),
    contadoTotal: detalle.reduce((s, d) => s + (d.contado ?? 0n), 0n),
  };
}

/**
 * Reparte un recaudo entre los pagos pendientes, del más antiguo al más nuevo.
 *
 * Es lo que hace la entidad en la práctica: liquida por orden de antigüedad.
 * Si se cobra más de lo pendiente, el sobrante se informa y NO se inventa un
 * pago al que asignarlo.
 *
 * @param pendientes [{ id, pendiente }] ya ordenados por antigüedad (centavos)
 * @param total      centavos a repartir (neto recibido + comisión)
 * @returns { aplicaciones: [{ id, monto }], sobrante }
 */
export function aplicarRecaudo(pendientes, total) {
  let resto = BigInt(total);
  const aplicaciones = [];
  for (const p of pendientes) {
    if (resto <= 0n) break;
    const pendiente = BigInt(p.pendiente);
    if (pendiente <= 0n) continue;
    const monto = pendiente < resto ? pendiente : resto;
    aplicaciones.push({ id: p.id, monto });
    resto -= monto;
  }
  return { aplicaciones, sobrante: resto };
}
