import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/productos_dao.dart';
import '../../../core/database/daos/sedes_dao.dart';
import '../../../core/database/daos/traslados_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/negocio/traslados.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/encabezado_hoja.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/domain/sesion.dart';
import '../../sedes/presentation/sedes_providers.dart';

/// Qué puede hacer quien mira con las existencias de una sede.
enum AccionSede {
  /// El gerente pide unidades de esa sede para la suya.
  solicitar,

  /// El director o el auxiliar envían unidades de esa sede a otra.
  mover,
}

/// La acción que corresponde a [rol] sobre la fila de [sede], o null.
///
/// Las mismas reglas que `motivoNoPuedeSolicitar` / `motivoNoPuedeMover`: sólo
/// se ofrece lo que va a funcionar, y nunca sobre una sede sin unidades.
AccionSede? accionSobreSede({required Actor actor, required StockEnSede fila, required Set<String> misSedes}) {
  if (fila.stock.milesimas <= 0) return null;
  final sede = fila.sede.uuid;
  switch (actor.rol) {
    case RolUsuario.gerente:
      // Pide para una sede suya: tiene sentido desde cualquier sede que no sea
      // la única suya.
      final destinos = misSedes.where((s) => s != sede);
      return destinos.isEmpty ? null : AccionSede.solicitar;
    case RolUsuario.director:
      return AccionSede.mover;
    case RolUsuario.auxiliarInventario:
      return actor.ve(sede) ? AccionSede.mover : null;
    case RolUsuario.vendedor:
      return null;
  }
}

/// Existencias de un producto en cada sede, con la acción que le toca a quien
/// mira: el vendedor sólo consulta (sede, cantidad y precio); el gerente
/// solicita; el director y el auxiliar mueven.
///
/// Sale de SQLite: el stock de todas las sedes baja con la sincronización, así
/// que responde también sin red. Por eso dice de cuándo es el dato.
class DisponibilidadProducto extends ConsumerWidget {
  const DisponibilidadProducto({super.key, required this.item, this.titulo = 'Disponibilidad por sede'});

  final ProductoConCategoria item;
  final String titulo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filas = ref.watch(disponibilidadProvider(item.uuid)).value;
    final sedes = ref.watch(sedesActivasProvider).value ?? const <Sede>[];
    if (filas == null || sedes.length < 2) return const SizedBox.shrink();

    final porSede = {for (final f in filas) f.sede.uuid: f};
    // Todas las sedes activas: la que no tiene fila, nunca lo tuvo (cero).
    final completas = [
      for (final s in sedes) porSede[s.uuid] ?? StockEnSede(sede: s, stock: const Cantidad(0)),
    ];
    final total = Cantidad.sumar(completas.map((f) => f.stock));
    final activa = ref.watch(sedeActivaProvider).value?.uuid;
    final actor = ref.watch(actorProvider);
    final misSedes = (ref.watch(misSedesProvider).value ?? const <Sede>[]).map((s) => s.uuid).toSet();
    final ultimoSync = ref.watch(estadoSyncProvider).value?.ultimoSync;

    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(titulo, style: context.textos.titleSmall),
              subtitle: Text(
                '${total.format()} en total · ${item.precioVenta.format()} c/u'
                '${ultimoSync == null ? '' : ' · datos de ${Fechas.relativo(ultimoSync)}'}',
                style: context.textos.bodySmall,
              ),
            ),
            for (final f in completas)
              _FilaSede(
                fila: f,
                unidad: item.producto.unidadMedida,
                esActiva: f.sede.uuid == activa,
                accion: actor == null ? null : accionSobreSede(actor: actor, fila: f, misSedes: misSedes),
                onAccion: (accion) => abrirHojaTraslado(context, item: item, origen: f, accion: accion),
              ),
          ],
        ),
      ),
    );
  }
}

class _FilaSede extends StatelessWidget {
  const _FilaSede({
    required this.fila,
    required this.unidad,
    required this.esActiva,
    required this.accion,
    required this.onAccion,
  });

  final StockEnSede fila;
  final String unidad;
  final bool esActiva;
  final AccionSede? accion;
  final ValueChanged<AccionSede> onAccion;

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    final agotado = fila.stock.milesimas <= 0;
    final bajo = !agotado && fila.minimo != null && fila.stock <= fila.minimo!;
    final color = agotado ? d.peligro : (bajo ? d.advertencia : d.exito);

    return ListTile(
      dense: true,
      leading: Icon(
        esActiva ? Icons.location_on_rounded : Icons.storefront_outlined,
        size: 20,
        color: esActiva ? context.colores.primary : null,
      ),
      title: Text(esActiva ? '${fila.sede.nombre} (aquí)' : fila.sede.nombre),
      subtitle: fila.sede.direccion == null ? null : Text(fila.sede.direccion!, maxLines: 1),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            agotado ? 'No hay' : fila.stock.formatConUnidad(unidad.toLowerCase()),
            style: context.textos.titleSmall?.copyWith(color: color),
          ),
          if (accion != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => onAccion(accion!),
              child: Text(accion == AccionSede.solicitar ? 'Solicitar' : 'Mover'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Abre la hoja para solicitar o mover unidades de [origen].
Future<void> abrirHojaTraslado(
  BuildContext context, {
  required ProductoConCategoria item,
  required StockEnSede origen,
  required AccionSede accion,
}) async {
  final hecho = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => HojaTrasladoRapido(item: item, origen: origen, accion: accion),
  );
  if (hecho != null && context.mounted) mostrarMensaje(context, hecho, esExito: true);
}

/// Solicitar o mover unidades de UN producto desde UNA sede, en un paso.
///
/// · Solicitar (gerente): llegan a una sede suya; despacha el auxiliar del
///   origen o el director, que pueden enviar menos.
/// · Mover (director o auxiliar): se mueven ya; el destino es cualquier otra
///   sede activa.
///
/// No deja pedir ni mover más de lo que hay en el origen según el teléfono.
class HojaTrasladoRapido extends ConsumerStatefulWidget {
  const HojaTrasladoRapido({super.key, required this.item, required this.origen, required this.accion});

  final ProductoConCategoria item;
  final StockEnSede origen;
  final AccionSede accion;

  @override
  ConsumerState<HojaTrasladoRapido> createState() => _HojaTrasladoRapidoState();
}

class _HojaTrasladoRapidoState extends ConsumerState<HojaTrasladoRapido> {
  late Cantidad _cantidad = Cantidad.unidades(1) > widget.origen.stock ? widget.origen.stock : Cantidad.unidades(1);
  String? _destino;
  final _notas = TextEditingController();
  bool _guardando = false;

  bool get _solicitar => widget.accion == AccionSede.solicitar;

  @override
  void dispose() {
    _notas.dispose();
    super.dispose();
  }

  List<Sede> _destinos(List<Sede> activas, List<Sede> mias) {
    final base = _solicitar ? mias : activas;
    return base.where((s) => s.uuid != widget.origen.sede.uuid).toList();
  }

  Future<void> _guardar() async {
    final destino = _destino;
    if (destino == null || _cantidad.milesimas <= 0) return;
    setState(() => _guardando = true);
    final dao = ref.read(trasladosDaoProvider);
    final lineas = [
      LineaTraslado(productoUuid: widget.item.uuid, descripcion: widget.item.nombre, cantidad: _cantidad),
    ];
    final notas = _notas.text.trim().isEmpty ? null : _notas.text.trim();
    try {
      if (_solicitar) {
        await dao.solicitar(
          sedeOrigenUuid: widget.origen.sede.uuid,
          sedeDestinoUuid: destino,
          lineas: lineas,
          notas: notas,
        );
      } else {
        await dao.mover(
          sedeOrigenUuid: widget.origen.sede.uuid,
          sedeDestinoUuid: destino,
          lineas: lineas,
          notas: notas,
        );
      }
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      Navigator.pop(
        context,
        _solicitar
            ? 'Solicitud enviada a ${widget.origen.sede.nombre}'
            : '${_cantidad.format()} movidas desde ${widget.origen.sede.nombre}',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final activas = ref.watch(sedesActivasProvider).value ?? const <Sede>[];
    final mias = ref.watch(misSedesProvider).value ?? const <Sede>[];
    final activa = ref.watch(sedeActivaProvider).value?.uuid;
    final destinos = _destinos(activas, mias);
    // Por defecto, la sede donde está el teléfono si es un destino posible.
    _destino ??= destinos.any((s) => s.uuid == activa) ? activa : destinos.firstOrNull?.uuid;
    final maximo = widget.origen.stock;
    final unidad = widget.item.producto.unidadMedida.toLowerCase();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              EncabezadoHoja(
                titulo: _solicitar ? 'Solicitar unidades' : 'Mover unidades',
                subtitulo: widget.item.nombre,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout_rounded),
                title: Text('Sale de ${widget.origen.sede.nombre}'),
                subtitle: Text('Hay ${maximo.formatConUnidad(unidad)}'),
              ),
              if (destinos.isEmpty)
                Text(
                  'No hay a qué sede llevarlas.',
                  style: context.textos.bodySmall?.copyWith(color: context.dominio.peligro),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: _destino,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Llega a', prefixIcon: Icon(Icons.login_rounded)),
                  items: [for (final s in destinos) DropdownMenuItem(value: s.uuid, child: Text(s.nombre))],
                  onChanged: (v) => setState(() => _destino = v),
                ),
              const SizedBox(height: 16),
              SelectorCantidad(
                valor: _cantidad,
                maximo: maximo,
                unidad: unidad,
                onCambio: (c) => setState(() => _cantidad = c),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notas,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nota (opcional)', hintText: 'Para un cliente que espera…'),
              ),
              const SizedBox(height: 12),
              Text(
                _solicitar
                    ? 'No mueve nada todavía: lo despacha el auxiliar de inventario de '
                        '${widget.origen.sede.nombre} o el Director General, que pueden enviar menos.'
                    : 'Las unidades salen de ${widget.origen.sede.nombre} y entran en el destino ahora mismo. '
                        'Queda registrado a tu nombre.',
                style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: !_guardando && _destino != null && _cantidad.milesimas > 0 ? _guardar : null,
                icon: Icon(_solicitar ? Icons.send_rounded : Icons.local_shipping_outlined),
                label: Text(_solicitar ? 'Solicitar ${_cantidad.format()}' : 'Mover ${_cantidad.format()}'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Selector de cantidad con tope: − / valor / +, y «todo» para llevar lo que
/// hay. Nunca baja de cero ni pasa de [maximo].
class SelectorCantidad extends StatelessWidget {
  const SelectorCantidad({
    super.key,
    required this.valor,
    required this.maximo,
    required this.onCambio,
    this.unidad = '',
    this.minimo = const Cantidad(0),
  });

  final Cantidad valor;
  final Cantidad maximo;
  final Cantidad minimo;
  final String unidad;
  final ValueChanged<Cantidad> onCambio;

  @override
  Widget build(BuildContext context) {
    Cantidad acotar(Cantidad c) => c < minimo ? minimo : (c > maximo ? maximo : c);
    return Row(
      children: [
        IconButton.filledTonal(
          tooltip: 'Menos',
          onPressed: valor > minimo ? () => onCambio(acotar(valor - Cantidad.unidades(1))) : null,
          icon: const Icon(Icons.remove_rounded),
        ),
        Expanded(
          child: Column(
            children: [
              Text(valor.format(), style: context.textos.headlineSmall),
              Text('de ${maximo.format()} $unidad'.trim(), style: context.textos.bodySmall),
            ],
          ),
        ),
        IconButton.filledTonal(
          tooltip: 'Más',
          onPressed: valor < maximo ? () => onCambio(acotar(valor + Cantidad.unidades(1))) : null,
          icon: const Icon(Icons.add_rounded),
        ),
        const SizedBox(width: 4),
        TextButton(onPressed: valor == maximo ? null : () => onCambio(maximo), child: const Text('Todo')),
      ],
    );
  }
}
