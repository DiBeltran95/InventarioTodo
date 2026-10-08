import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { evaluarJornada, normalizarHorario, permitidoConGracia } from '../src/domain/jornada.js';

/**
 * Los casos son los MISMOS que ejecuta la app (mobile/test/jornada_test.dart):
 * si el servidor deja entrar a alguien que la app expulsaría —o al revés—, el
 * empleado ve un cierre de sesión que nadie sabe explicar.
 */
const { zona, casos } = JSON.parse(
  readFileSync(new URL('../../shared/jornada_casos.json', import.meta.url), 'utf8'),
);

const iso = (d) => (d ? d.toISOString() : null);

for (const caso of casos) {
  test(caso.nombre, () => {
    const r = evaluarJornada(caso.jornada, new Date(caso.ahora), zona);
    assert.deepEqual(
      { permitido: r.permitido, motivo: r.motivo, hasta: iso(r.hasta), proximoInicio: iso(r.proximoInicio) },
      caso.esperado,
    );
  });
}

test('la gracia deja subir la cola unos minutos después del turno, no más', () => {
  const jornada = { restringir: true, horario: [{ dia: 1, inicio: '08:00', fin: '17:00' }] };
  // Lunes 17:10 y 17:20 en Bogotá (22:10Z y 22:20Z).
  assert.equal(permitidoConGracia(jornada, new Date('2026-10-05T22:10:00Z'), zona, 15), true);
  assert.equal(permitidoConGracia(jornada, new Date('2026-10-05T22:20:00Z'), zona, 15), false);
});

test('un horario mal escrito se rechaza con un mensaje entendible', () => {
  assert.throws(() => normalizarHorario([{ dia: 8, inicio: '08:00', fin: '17:00' }]), /día/);
  assert.throws(() => normalizarHorario([{ dia: 1, inicio: '8:00', fin: '17:00' }]), /HH:MM/);
  assert.throws(() => normalizarHorario([{ dia: 1, inicio: '08:00', fin: '08:00' }]), /iguales/);
});

test('un horario ilegible en la base no deja trabajar sin control', () => {
  const r = evaluarJornada(
    { restringir: true, horario: '{esto no es json' },
    new Date('2026-10-05T15:00:00Z'),
    zona,
  );
  assert.equal(r.permitido, false);
});
