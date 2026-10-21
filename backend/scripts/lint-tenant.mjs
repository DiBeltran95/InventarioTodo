#!/usr/bin/env node
/**
 * Chequeo estático del aislamiento entre empresas.
 *
 * La base aloja muchas empresas y los UUID son globales: una consulta que busca
 * un producto, una sede o una cuenta SOLO por su uuid (o su código, SKU o
 * correo) devuelve la fila aunque sea de otra empresa. Basta con conocer el
 * uuid ajeno —o escanear su QR— para leerla o modificarla.
 *
 * Regla: todo SQL que toca una tabla de empresa y busca por uno de esos campos
 * debe acotar por empresa:
 *   · `empresa_id` (directo o en un JOIN), o
 *   · las sedes del alcance (`sede_id IN (?)`, `${SEDE(...)}`, `${f.sql}`…),
 *     que ya son todas de la empresa.
 *
 * Las excepciones legítimas (el correo es la identidad global para entrar; un
 * uuid de dispositivo) se marcan con un comentario `// aislamiento: <motivo>`
 * en alguna de las 3 líneas anteriores a la consulta.
 *
 * Uso: node scripts/lint-tenant.mjs
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const RAIZ = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(RAIZ, 'src');

const TABLAS_DE_EMPRESA = [
  'productos',
  'producto_codigos',
  'categorias',
  'proveedores',
  'metodos_pago',
  'sedes',
  'usuarios',
  'ventas',
  'traslados',
  'solicitudes_ajuste',
  'cierres_caja',
  'recaudos',
  'alertas',
  'movimientos_inventario',
  'asis_empleados',
];
const TABLA = new RegExp(`\\b(FROM|JOIN|UPDATE|INTO)\\s+(${TABLAS_DE_EMPRESA.join('|')})\\b`, 'i');
const BUSQUEDA_GLOBAL = /\b(uuid|codigo|sku|email|documento)\s*(=|IN\b|LIKE)/i;
const ACOTA = /empresa_id|sede_id\s+IN\s*\(|\$\{SEDE\(|\$\{\w+\.sql\}|\$\{alc\.sql\}/i;

function archivosJs(dir) {
  const salida = [];
  for (const entrada of readdirSync(dir)) {
    const ruta = join(dir, entrada);
    if (statSync(ruta).isDirectory()) salida.push(...archivosJs(ruta));
    else if (entrada.endsWith('.js')) salida.push(ruta);
  }
  return salida;
}

/** Literales de texto (comillas simples, dobles o plantillas) con su posición. */
function literales(contenido) {
  const salida = [];
  const re = /`(?:[^`\\]|\\.)*`|'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"/g;
  let m;
  while ((m = re.exec(contenido)) !== null) salida.push({ texto: m[0], indice: m.index });
  return salida;
}

const problemas = [];

for (const archivo of archivosJs(SRC)) {
  const contenido = readFileSync(archivo, 'utf8');
  const lineas = contenido.split(/\r?\n/);
  for (const { texto, indice } of literales(contenido)) {
    if (!/\b(SELECT|UPDATE|DELETE|INSERT)\b/i.test(texto)) continue;
    if (!TABLA.test(texto) || !BUSQUEDA_GLOBAL.test(texto) || ACOTA.test(texto)) continue;

    const linea = contenido.slice(0, indice).split('\n').length;
    const previas = lineas.slice(Math.max(0, linea - 4), linea).join('\n');
    if (/\/\/\s*aislamiento:/i.test(previas)) continue;

    problemas.push({
      archivo: relative(RAIZ, archivo).replace(/\\/g, '/'),
      linea,
      sql: texto.replace(/\s+/g, ' ').slice(0, 110),
    });
  }
}

if (problemas.length) {
  console.error(`\x1b[31m✗ ${problemas.length} consulta(s) buscan por un campo global sin acotar por empresa:\x1b[0m\n`);
  for (const p of problemas) console.error(`  ${p.archivo}:${p.linea}\n    ${p.sql}\n`);
  console.error('Agrega `empresa_id = ?` (o filtra por las sedes del alcance), o marca la excepción con\n' +
    '`// aislamiento: <motivo>` justo antes de la consulta.');
  process.exit(1);
}
console.log('\x1b[32m✓ Todas las búsquedas por uuid, código, SKU o correo están acotadas por empresa\x1b[0m');
