import '../../../core/money/money.dart';

/// Decide si una entrada de mercancía debe además cambiar el precio de venta.
///
/// Vive aparte de la pantalla porque la regla no es obvia y sus consecuencias
/// no se ven al probar a mano:
///
///  · Encolar un `PRODUCTO_ACTUALIZAR` en **cada** entrada llenaría la cola de
///    operaciones que no cambian nada.
///  · Peor: cada una movería el `updated_at` del producto, y ése es el campo
///    con el que se resuelven los conflictos. Una entrada rutinaria podría
///    pisar un cambio de precio hecho desde otro dispositivo.
///
/// Devuelve `null` cuando no hay que tocar el precio.
Money? precioAActualizar({
  required String tipo,
  Money? tecleado,
  Money? original,
}) {
  // Sólo la entrada de mercancía repercute precios. Una merma o una devolución
  // no son una compra: no hay costo nuevo del que derivar un precio nuevo.
  if (tipo != 'ENTRADA') return null;

  // Campo vacío o ilegible: se deja el precio como estaba.
  if (tecleado == null) return null;

  // Un precio negativo no se guarda ni por error.
  if (tecleado.esNegativo) return null;

  // Sin cambio real, no hay nada que enviar.
  if (tecleado == original) return null;

  return tecleado;
}
