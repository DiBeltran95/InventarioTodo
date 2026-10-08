import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

/**
 * Los triggers que mantienen el stock tienen UNA sola definición: la de
 * `migrations/002_multisede.sql`.
 *
 * Mantienen dos proyecciones —`stock_sedes` por sede y `productos.stock_actual`
 * total— y usan `movimientos_inventario.sede_id`, que crea esa migración.
 * MariaDB valida las columnas de NEW al crear un trigger, así que en schema.sql
 * romperían la instalación desde cero.
 *
 * Y si alguien los vuelve a poner en schema.sql «para que esté completo»,
 * reimportar ese archivo a mano reinstalaría la versión de una sola sede: el
 * total seguiría moviéndose y el stock de cada sede quedaría congelado sin un
 * solo error. Esta prueba lo impide.
 */

const leer = (ruta) => readFileSync(new URL(ruta, import.meta.url), 'utf8');

const esquema = leer('../../database/schema.sql');
const migracion = leer('../../database/migrations/002_multisede.sql');

const OBJETOS = [
  ['TRIGGER', 'trg_mov_before_insert'],
  ['TRIGGER', 'trg_mov_after_insert'],
  ['PROCEDURE', 'sp_recalcular_stock'],
];

for (const [tipo, nombre] of OBJETOS) {
  test(`${nombre} sólo se define en la migración 002`, () => {
    assert.ok(
      migracion.includes(`CREATE ${tipo} ${nombre}`),
      `${nombre} debe definirse en migrations/002_multisede.sql`,
    );
    assert.ok(
      !esquema.includes(`CREATE ${tipo} ${nombre}`),
      `${nombre} no debe estar en schema.sql: reimportarlo reinstalaría la versión de una sola sede`,
    );
  });
}

test('el trigger de stock mantiene la proyección por sede y el total', () => {
  const inicio = migracion.indexOf('CREATE TRIGGER trg_mov_after_insert');
  const cuerpo = migracion.slice(inicio, migracion.indexOf('END$$', inicio));
  assert.match(cuerpo, /INSERT INTO stock_sedes/);
  assert.match(cuerpo, /UPDATE productos/);
});
