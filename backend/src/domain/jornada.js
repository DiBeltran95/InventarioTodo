/**
 * Jornada laboral: ¿puede trabajar este usuario ahora, y hasta cuándo?
 *
 * Función PURA a propósito —recibe el instante y la zona horaria, no lee el
 * reloj ni la base— porque la misma regla se aplica en dos sitios que no pueden
 * discrepar: el servidor (login, refresh y cada petición) y la app (que cierra
 * la sesión al terminar el turno aunque no haya red). Los casos de prueba viven
 * en `shared/jornada_casos.json` y los ejecutan los tests de ambos lados.
 *
 * Horario: lista de tramos `{ dia, inicio, fin }`
 *   · dia 1 = lunes … 7 = domingo (ISO 8601)
 *   · inicio/fin 'HH:MM' en la hora del negocio
 *   · fin <= inicio → el tramo cruza la medianoche (turno de noche): el de
 *     viernes 18:00–02:00 termina el sábado a las 2.
 *   · fin es EXCLUSIVO: a las 17:00 en punto ya no se está en el turno 08–17.
 *
 * Tramos contiguos o solapados se encadenan: 08–12 y 12–16 son un turno hasta
 * las 16, no uno que termina a las 12.
 */

const HHMM = /^([01]\d|2[0-3]):([0-5]\d)$/;
const MS_MIN = 60_000;

const formatos = new Map();

function formateador(tz) {
  let f = formatos.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      weekday: 'short',
      hourCycle: 'h23',
    });
    formatos.set(tz, f);
  }
  return f;
}

const DIAS = { Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6, Sun: 7 };

/** Fecha local, día de la semana y desfase respecto a UTC en `tz`. */
function local(instante, tz) {
  const p = Object.fromEntries(
    formateador(tz)
      .formatToParts(instante)
      .filter((x) => x.type !== 'literal')
      .map((x) => [x.type, x.value]),
  );
  const anio = Number(p.year);
  const mes = Number(p.month);
  const dia = Number(p.day);
  const comoUtc = Date.UTC(anio, mes - 1, dia, Number(p.hour), Number(p.minute), Number(p.second));
  const segundos = Math.floor(instante.getTime() / 1000) * 1000;
  return { anio, mes, dia, diaSemana: DIAS[p.weekday], desfaseMs: comoUtc - segundos };
}

const aMinutos = (hhmm) => {
  const m = HHMM.exec(hhmm);
  return Number(m[1]) * 60 + Number(m[2]);
};

/**
 * Valida y normaliza un horario. Devuelve los tramos ordenados.
 * Lanza `Error` con un mensaje para el usuario si algo no es válido.
 */
export function normalizarHorario(horario) {
  if (horario == null) return [];
  if (!Array.isArray(horario)) throw new Error('El horario debe ser una lista de tramos');
  if (horario.length > 28) throw new Error('Demasiados tramos en el horario (máximo 28)');

  return horario
    .map((t, i) => {
      const dia = Number(t?.dia);
      if (!Number.isInteger(dia) || dia < 1 || dia > 7) {
        throw new Error(`Tramo ${i + 1}: el día debe ir de 1 (lunes) a 7 (domingo)`);
      }
      if (!HHMM.test(t?.inicio ?? '') || !HHMM.test(t?.fin ?? '')) {
        throw new Error(`Tramo ${i + 1}: la hora debe tener el formato HH:MM`);
      }
      if (t.inicio === t.fin) {
        throw new Error(`Tramo ${i + 1}: la hora de inicio y la de fin no pueden ser iguales`);
      }
      return { dia, inicio: t.inicio, fin: t.fin };
    })
    .sort((a, b) => a.dia - b.dia || a.inicio.localeCompare(b.inicio));
}

/** Lee el horario tal como viene de la base (texto JSON) sin lanzar. */
export function leerHorario(valor) {
  if (valor == null || valor === '') return [];
  try {
    return normalizarHorario(typeof valor === 'string' ? JSON.parse(valor) : valor);
  } catch {
    // Un horario ilegible no puede dejar a nadie trabajando sin control ni
    // bloquear a todos: se trata como vacío, que con la restricción activa
    // equivale a «sin turno».
    return [];
  }
}

/**
 * @param {{ restringir: boolean, horario: Array, accesoExtraHasta?: Date|string|null }} jornada
 * @param {Date} ahora
 * @param {string} tz  zona IANA del negocio ('America/Bogota')
 * @returns {{ permitido: boolean,
 *             motivo: 'SIN_RESTRICCION'|'EN_TURNO'|'ACCESO_EXTRA'|'FUERA_DE_HORARIO',
 *             hasta: Date|null, proximoInicio: Date|null }}
 */
export function evaluarJornada(jornada, ahora, tz) {
  if (!jornada?.restringir) {
    return { permitido: true, motivo: 'SIN_RESTRICCION', hasta: null, proximoInicio: null };
  }

  const tramos = leerHorario(jornada.horario);
  const l = local(ahora, tz);
  const t = ahora.getTime();

  // Instante UTC de «día local de hoy + k, a los `minutos` del día».
  const instante = (k, minutos) => Date.UTC(l.anio, l.mes - 1, l.dia + k, 0, minutos) - l.desfaseMs;
  const diaSemana = (k) => ((((l.diaSemana - 1 + k) % 7) + 7) % 7) + 1;

  // Desde ayer (un turno de noche que empezó ayer puede seguir vigente) hasta
  // una semana adelante (para poder decir cuándo empieza el próximo).
  const ventanas = [];
  for (let k = -1; k <= 7; k += 1) {
    for (const tramo of tramos) {
      if (tramo.dia !== diaSemana(k)) continue;
      const ini = aMinutos(tramo.inicio);
      const fin = aMinutos(tramo.fin);
      ventanas.push({
        inicio: instante(k, ini),
        fin: fin > ini ? instante(k, fin) : instante(k + 1, fin),
      });
    }
  }
  ventanas.sort((a, b) => a.inicio - b.inicio);

  let hasta = null;
  for (const v of ventanas) {
    if (v.inicio <= t && t < v.fin) hasta = Math.max(hasta ?? 0, v.fin);
  }
  // Encadena tramos contiguos o solapados.
  if (hasta != null) {
    let cambio = true;
    while (cambio) {
      cambio = false;
      for (const v of ventanas) {
        if (v.inicio <= hasta && v.fin > hasta) {
          hasta = v.fin;
          cambio = true;
        }
      }
    }
  }

  const referencia = hasta ?? t;
  const siguiente = ventanas.find((v) => v.inicio > referencia);
  const proximoInicio = siguiente ? new Date(siguiente.inicio) : null;

  const extra = jornada.accesoExtraHasta ? new Date(jornada.accesoExtraHasta).getTime() : null;
  const extraVigente = extra != null && extra > t ? extra : null;

  if (hasta != null) {
    return {
      permitido: true,
      motivo: 'EN_TURNO',
      hasta: new Date(extraVigente != null && extraVigente > hasta ? extraVigente : hasta),
      proximoInicio,
    };
  }
  if (extraVigente != null) {
    return { permitido: true, motivo: 'ACCESO_EXTRA', hasta: new Date(extraVigente), proximoInicio };
  }
  return { permitido: false, motivo: 'FUERA_DE_HORARIO', hasta: null, proximoInicio };
}

/**
 * ¿Puede subir su cola? Igual que `evaluarJornada`, pero con unos minutos de
 * gracia tras el fin del turno para el último envío.
 */
export function permitidoConGracia(jornada, ahora, tz, graciaMin) {
  if (evaluarJornada(jornada, ahora, tz).permitido) return true;
  return evaluarJornada(jornada, new Date(ahora.getTime() - graciaMin * MS_MIN), tz).permitido;
}

/**
 * Jornada a partir de una fila de `usuarios`.
 *
 * El Director General nunca queda restringido por horario, aunque la fila lo
 * diga: un horario mal puesto no puede dejar al dueño fuera de su propio
 * negocio sin nadie con permisos para corregirlo.
 */
export const jornadaDe = (u) => ({
  restringir: u.rol !== 'ADMIN' && !!u.restringir_horario,
  horario: u.horario,
  accesoExtraHasta: u.acceso_extra_hasta,
});

const formatosFecha = new Map();

/** «martes, 6 de octubre, 08:00», en la hora del negocio. */
export function describirInstante(instante, tz) {
  let f = formatosFecha.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('es-CO', {
      timeZone: tz,
      weekday: 'long',
      day: 'numeric',
      month: 'long',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    });
    formatosFecha.set(tz, f);
  }
  return f.format(instante);
}
