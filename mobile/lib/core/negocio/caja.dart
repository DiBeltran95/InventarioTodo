import '../money/money.dart';

/// Cierre de caja y cobro a entidades de crédito: el cálculo, sin base de datos.
///
/// Es la misma regla que aplica el servidor (backend/src/domain/caja.js). La
/// app la usa para mostrar el resultado al instante, incluso sin red; la cifra
/// que queda registrada es la que recalcula el servidor con las ventas del
/// turno ya sincronizadas.
class CobroPorMedio {
  const CobroPorMedio({
    required this.metodoUuid,
    required this.metodoNombre,
    required this.metodoTipo,
    required this.monto,
  });

  final String? metodoUuid;
  final String metodoNombre;
  final String metodoTipo;
  final Money monto;
}

class EsperadoPorMedio {
  const EsperadoPorMedio({
    required this.metodoUuid,
    required this.metodoNombre,
    required this.metodoTipo,
    required this.esperado,
  });

  final String? metodoUuid;
  final String metodoNombre;
  final String metodoTipo;
  final Money esperado;

  bool get esEfectivo => metodoTipo == 'EFECTIVO';
}

/// Lo que debería haber por medio de pago al cerrar.
///
/// El efectivo esperado es la base MÁS lo cobrado en efectivo (el monto de un
/// pago en efectivo ya es neto de vueltas). El efectivo aparece siempre, aunque
/// no se haya vendido nada en efectivo: la base sigue en el cajón.
List<EsperadoPorMedio> calcularEsperado(Money base, List<CobroPorMedio> cobros) {
  final porMedio = <String, EsperadoPorMedio>{};
  for (final c in cobros) {
    final clave = c.metodoTipo == 'EFECTIVO' ? 'EFECTIVO' : (c.metodoUuid ?? c.metodoNombre);
    final previo = porMedio[clave];
    porMedio[clave] = EsperadoPorMedio(
      metodoUuid: previo?.metodoUuid ?? c.metodoUuid,
      metodoNombre: c.metodoTipo == 'EFECTIVO' ? 'Efectivo' : c.metodoNombre,
      metodoTipo: c.metodoTipo,
      esperado: (previo?.esperado ?? const Money.cero()) + c.monto,
    );
  }
  final efectivo = porMedio['EFECTIVO'];
  porMedio['EFECTIVO'] = EsperadoPorMedio(
    metodoUuid: efectivo?.metodoUuid,
    metodoNombre: 'Efectivo',
    metodoTipo: 'EFECTIVO',
    esperado: (efectivo?.esperado ?? const Money.cero()) + base,
  );
  final lista = porMedio.values.toList()
    ..sort((a, b) {
      if (a.esEfectivo) return -1;
      if (b.esEfectivo) return 1;
      return a.metodoNombre.compareTo(b.metodoNombre);
    });
  return lista;
}

/// Reparte un recaudo entre los pagos pendientes, del más antiguo al más nuevo.
///
/// Devuelve cuánto se aplica a cada pago y lo que sobra. Lo que sobra NO se
/// asigna a ningún pago: indica que se escribió mal el monto o la comisión.
({List<({String id, Money monto})> aplicaciones, Money sobrante}) aplicarRecaudo(
  List<({String id, Money pendiente})> pendientes,
  Money total,
) {
  var resto = total;
  final aplicaciones = <({String id, Money monto})>[];
  for (final p in pendientes) {
    if (!resto.esPositivo) break;
    if (!p.pendiente.esPositivo) continue;
    final monto = p.pendiente < resto ? p.pendiente : resto;
    aplicaciones.add((id: p.id, monto: monto));
    resto = resto - monto;
  }
  return (aplicaciones: aplicaciones, sobrante: resto);
}

/// Comisión que debería retener la entidad sobre un monto.
/// `comisionPct` en centésimas de punto: 5 % = 500.
///
/// Aritmética entera con redondeo HALF_UP, como todo el dinero de la app: un
/// `double` aquí reintroduciría el error de coma flotante que `Money` evita.
Money comisionEsperada(Money bruto, int? comisionPct) {
  if (comisionPct == null || comisionPct <= 0 || !bruto.esPositivo) return const Money.cero();
  return Money((bruto.centavos * comisionPct + 5000) ~/ 10000);
}
