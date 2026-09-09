import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Cada consulta debe recibir tantos parámetros como marcadores `?` declara.
 *
 * Esta prueba nace de un fallo real: un INSERT en `venta_pagos` declaraba nueve
 * columnas y pasaba ocho valores —faltaba `referencia`—. El driver deja el
 * último `?` sin sustituir y MariaDB responde «syntax error near '?)'», un
 * mensaje que no menciona la tabla ni la columna que falta.
 *
 * Lo grave no fue el error, sino dónde apareció: sólo al sincronizar, sólo en
 * las ventas, y desde el dispositivo se veía como «no sincroniza» sin más. Un
 * desajuste de aridad es comprobable sin base de datos, así que se comprueba
 * aquí y no en producción.
 */

const RAIZ = new URL('../src', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');

function archivosJs(dir) {
  return readdirSync(dir).flatMap((entrada) => {
    const ruta = join(dir, entrada);
    if (statSync(ruta).isDirectory()) return archivosJs(ruta);
    return ruta.endsWith('.js') ? [ruta] : [];
  });
}

/** Recorre desde `inicio` hasta cerrar el delimitador, respetando anidamiento. */
function leerBloque(texto, inicio, abre, cierra) {
  let nivel = 0;
  for (let i = inicio; i < texto.length; i += 1) {
    const c = texto[i];
    if (c === abre) nivel += 1;
    else if (c === cierra) {
      nivel -= 1;
      if (nivel === 0) return { fin: i, contenido: texto.slice(inicio + 1, i) };
    }
  }
  return null;
}

/** Comas del primer nivel: separan los parámetros, no los de llamadas internas. */
function contarElementos(lista) {
  const limpia = lista.trim();
  if (!limpia) return 0;

  let nivel = 0;
  let elementos = 1;
  for (const c of limpia) {
    if ('([{'.includes(c)) nivel += 1;
    else if (')]}'.includes(c)) nivel -= 1;
    else if (c === ',' && nivel === 0) elementos += 1;
  }
  // Una coma final («trailing comma») no introduce un elemento más.
  return /,\s*$/.test(limpia) ? elementos - 1 : elementos;
}

const desajustes = [];

for (const ruta of archivosJs(RAIZ)) {
  const codigo = readFileSync(ruta, 'utf8');

  // `txExecute(conn, `…`, [ … ])` y `txQuery(conn, `…`, [ … ])`.
  const patron = /\b(txExecute|txQuery|txQueryOne)\(\s*conn,\s*`/g;
  let coincidencia;

  while ((coincidencia = patron.exec(codigo)) !== null) {
    const inicioSql = patron.lastIndex - 1;
    const finSql = codigo.indexOf('`', inicioSql + 1);
    if (finSql === -1) continue;

    const sql = codigo.slice(inicioSql + 1, finSql);

    // Las consultas que construyen sus marcadores en tiempo de ejecución
    // (`uuids.map(() => '?')`) no tienen aridad fija: no se pueden comprobar así.
    if (sql.includes('${')) continue;

    const resto = codigo.slice(finSql + 1);
    const abre = resto.indexOf('[');
    // Sin array de parámetros la consulta no lleva marcadores, o los lleva mal.
    if (abre === -1 || abre > resto.indexOf(')') + 200) continue;

    const bloque = leerBloque(resto, abre, '[', ']');
    if (!bloque) continue;

    const marcadores = (sql.match(/\?/g) ?? []).length;
    const parametros = contarElementos(bloque.contenido);

    if (marcadores !== parametros) {
      const linea = codigo.slice(0, inicioSql).split('\n').length;
      desajustes.push(
        `${ruta.split(/[\\/]/).slice(-3).join('/')}:${linea} — ` +
          `${marcadores} marcadores, ${parametros} parámetros`,
      );
    }
  }
}

test('cada consulta pasa tantos parámetros como marcadores declara', () => {
  assert.deepEqual(desajustes, [], `Consultas con la aridad rota:\n${desajustes.join('\n')}`);
});
