import { forbidden } from '../utils/ApiError.js';
import { ROLES, ROLES_GESTORES } from '../config/constants.js';

/**
 * Restringe una ruta a ciertos roles.
 *
 *   router.post('/', autenticar, exigirRol(ROLES.ADMIN), handler)
 */
export const exigirRol =
  (...rolesPermitidos) =>
  (req, _res, next) => {
    if (!req.usuario) return next(forbidden('Requiere autenticación'));
    if (!rolesPermitidos.includes(req.usuario.rol)) {
      return next(
        forbidden(
          `Esta operación requiere rol ${rolesPermitidos.join(' o ')}; tu rol es ${req.usuario.rol}`,
        ),
      );
    }
    return next();
  };

/** Sólo el Director General: sedes, datos del negocio, mantenimiento. */
export const soloDirector = exigirRol(ROLES.ADMIN);

/**
 * Director o Gerente de Sede: catálogo, precios, inventario, reportes y
 * personal. Lo que un gerente puede tocar se acota además por sus sedes en
 * cada servicio (`req.alcance`); esto sólo filtra por rol.
 */
export const soloGestor = exigirRol(...ROLES_GESTORES);

/**
 * Vendedores y auxiliares no ven márgenes ni costos de compra: es información
 * sensible del negocio. Director y gerentes sí. Se filtra en la capa de respuesta en lugar de tener
 * consultas distintas por rol.
 */
const CAMPOS_SENSIBLES = ['precio_compra', 'costo_unitario', 'costo_total', 'costo', 'margen', 'margen_bruto', 'margen_potencial', 'valor_costo'];

export function ocultarCostos(datos, rol) {
  if (ROLES_GESTORES.includes(rol)) return datos;
  if (Array.isArray(datos)) return datos.map((d) => ocultarCostos(d, rol));
  if (datos && typeof datos === 'object' && !(datos instanceof Date)) {
    const copia = {};
    for (const [k, v] of Object.entries(datos)) {
      if (CAMPOS_SENSIBLES.includes(k)) continue;
      copia[k] = v && typeof v === 'object' ? ocultarCostos(v, rol) : v;
    }
    return copia;
  }
  return datos;
}
