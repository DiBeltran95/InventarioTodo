import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/productos_dao.dart';
import '../../../core/database/daos/sedes_dao.dart';
import '../../../core/database/daos/traslados_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/negocio/traslados.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/estados.dart';
import '../../auth/domain/sesion.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../disponibilidad/presentation/disponibilidad_widgets.dart';
import '../../sedes/presentation/sedes_providers.dart';

/// Un traslado de varios productos.
///
/// Cambia con el rol:
///   · Gerente → SOLICITA unidades de otra sede para una suya. No mueve nada:
///     lo despacha el auxiliar del origen o el director.
///   · Director → MUEVE unidades entre cualesquiera sedes, en el acto.
///   · Auxiliar → MUEVE unidades desde su sede a otra, en el acto.
///
/// Cada línea muestra cuánto hay en la sede de origen y no deja pasar de ahí.
/// Puede llegar con producto, origen o destino ya elegidos (desde «Stock bajo»
/// o «¿Dónde hay?»).
class TrasladoNuevoPage extends ConsumerStatefulWidget {
  const TrasladoNuevoPage({super.key, this.productoUuid, this.sedeDestinoUuid, this.sedeOrigenUuid});

  final String? productoUuid;
  final String? sedeDestinoUuid;
  final String? sedeOrigenUuid;

  @override
  ConsumerState<TrasladoNuevoPage> createState() => _TrasladoNuevoPageState();
}

class _Linea {
  _Linea(this.producto, this.cantidad);
  final ProductoConCategoria producto;
  Cantidad cantidad;
}

class _TrasladoNuevoPageState extends ConsumerState<TrasladoNuevoPage> {
  String? _origen;
  String? _destino;
  final _lineas = <_Linea>[];
  final _notas = TextEditingController();
  bool _guardando = false;
  bool _inicializado = false;

  bool get _solicita => ref.read(rolProvider).solicitaTraslados;

  @override
  void dispose() {
    _notas.dispose();
    super.dispose();
  }

  Future<void> _precargar({required List<Sede> activas, required List<Sede> mias, required Sede? activa}) async {
    if (_inicializado || activas.isEmpty) return;
    _inicializado = true;
    final rol = ref.read(rolProvider);
    String? valida(String? uuid, Iterable<Sede> opciones) => opciones.any((s) => s.uuid == uuid) ? uuid : null;

    if (rol.solicitaTraslados) {
      // Pide PARA una sede suya: la indicada, la activa o la primera.
      _destino = valida(widget.sedeDestinoUuid, mias) ?? valida(activa?.uuid, mias) ?? mias.firstOrNull?.uuid;
      _origen = valida(widget.sedeOrigenUuid, activas.where((s) => s.uuid != _destino));
    } else if (rol == RolUsuario.auxiliarInventario) {
      // Envía DESDE su sede.
      _origen = mias.firstOrNull?.uuid;
      _destino = valida(widget.sedeDestinoUuid, activas.where((s) => s.uuid != _origen));
    } else {
      _origen = valida(widget.sedeOrigenUuid, activas);
      _destino = valida(widget.sedeDestinoUuid, activas.where((s) => s.uuid != _origen));
    }

    if (widget.productoUuid != null) {
      final p = await ref.read(productosDaoProvider).obtener(widget.productoUuid!);
      if (p == null || !mounted) return;
      // Sin origen elegido, el que más tiene de ese producto.
      if (_origen == null) {
        final filas = await ref.read(sedesDaoProvider).observarDisponibilidad([p.uuid]).first;
        final candidatas = (filas[p.uuid] ?? const <StockEnSede>[])
            .where((f) => f.sede.uuid != _destino && f.stock.milesimas > 0)
            .toList()
          ..sort((a, b) => b.stock.milesimas.compareTo(a.stock.milesimas));
        _origen = candidatas.firstOrNull?.sede.uuid;
      }
      if (mounted) setState(() => _lineas.add(_Linea(p, Cantidad.unidades(1))));
    } else {
      setState(() {});
    }
  }

  Future<void> _agregarProducto() async {
    final elegido = await showModalBottomSheet<ProductoConCategoria>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _SelectorProducto(),
    );
    if (elegido == null || !mounted) return;
    final existente = _lineas.where((l) => l.producto.uuid == elegido.uuid).firstOrNull;
    setState(() {
      if (existente != null) {
        existente.cantidad = existente.cantidad + Cantidad.unidades(1);
      } else {
        _lineas.add(_Linea(elegido, Cantidad.unidades(1)));
      }
    });
  }

  String? _impedimento(Actor? actor) {
    if (actor == null) return 'Sin sesión';
    if (_origen == null || _destino == null) return null;
    return _solicita
        ? motivoNoPuedeSolicitar(actor, _origen!, _destino!)
        : motivoNoPuedeMover(actor, _origen!, _destino!);
  }

  Future<void> _guardar() async {
    final origen = _origen;
    final destino = _destino;
    if (origen == null || destino == null || _lineas.isEmpty) return;
    final motivo = _impedimento(ref.read(actorProvider));
    if (motivo != null) {
      mostrarMensaje(context, motivo, esError: true);
      return;
    }

    // Lo que hay en el origen según el teléfono: no se pide ni se mueve más.
    final existencias = await ref.read(sedesDaoProvider).observarDisponibilidad(
          _lineas.map((l) => l.producto.uuid).toList(),
        ).first;
    for (final l in _lineas) {
      final hay = (existencias[l.producto.uuid] ?? const <StockEnSede>[])
              .where((f) => f.sede.uuid == origen)
              .firstOrNull
              ?.stock ??
          const Cantidad(0);
      if (l.cantidad > hay) {
        if (mounted) {
          mostrarMensaje(context, '${l.producto.nombre}: en el origen hay ${hay.format()}', esError: true);
        }
        return;
      }
    }

    setState(() => _guardando = true);
    final dao = ref.read(trasladosDaoProvider);
    final lineas = [
      for (final l in _lineas)
        LineaTraslado(productoUuid: l.producto.uuid, descripcion: l.producto.nombre, cantidad: l.cantidad),
    ];
    final notas = _notas.text.trim().isEmpty ? null : _notas.text.trim();
    try {
      if (_solicita) {
        await dao.solicitar(sedeOrigenUuid: origen, sedeDestinoUuid: destino, lineas: lineas, notas: notas);
      } else {
        await dao.mover(sedeOrigenUuid: origen, sedeDestinoUuid: destino, lineas: lineas, notas: notas);
      }
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      mostrarMensaje(context, _solicita ? 'Solicitud enviada' : 'Unidades movidas', esExito: true);
      context.pop();
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
    final activa = ref.watch(sedeActivaProvider).value;
    final rol = ref.watch(rolProvider);
    final actor = ref.watch(actorProvider);
    _precargar(activas: activas, mias: mias, activa: activa);

    final solicita = rol.solicitaTraslados;
    final origenFijo = rol == RolUsuario.auxiliarInventario;
    final motivo = _impedimento(actor);
    final listo = _origen != null && _destino != null && _lineas.isNotEmpty && motivo == null;
    final nombreOrigen = activas.where((s) => s.uuid == _origen).firstOrNull?.nombre;

    return Scaffold(
      appBar: AppBar(title: Text(solicita ? 'Solicitar unidades' : 'Mover unidades')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          _SelectorSede(
            etiqueta: 'Sale de',
            icono: Icons.logout_rounded,
            sedes: origenFijo ? mias : activas,
            valor: _origen,
            excluir: _destino,
            habilitado: !origenFijo,
            onCambio: (v) => setState(() => _origen = v),
          ),
          const SizedBox(height: 12),
          _SelectorSede(
            etiqueta: 'Llega a',
            icono: Icons.login_rounded,
            // El gerente pide para una sede suya.
            sedes: solicita ? mias : activas,
            valor: _destino,
            excluir: _origen,
            onCambio: (v) => setState(() => _destino = v),
          ),
          if (motivo != null) ...[
            const SizedBox(height: 10),
            Text(motivo, style: context.textos.bodySmall?.copyWith(color: context.dominio.peligro)),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Text('Productos', style: context.textos.titleMedium),
              const Spacer(),
              TextButton.icon(
                onPressed: _agregarProducto,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Añadir'),
              ),
            ],
          ),
          if (_lineas.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Añade los productos y la cantidad de cada uno.',
                style: context.textos.bodyMedium?.copyWith(color: context.colores.onSurfaceVariant),
              ),
            ),
          for (final l in _lineas)
            _FilaLinea(
              key: ValueKey(l.producto.uuid),
              linea: l,
              origen: _origen,
              nombreOrigen: nombreOrigen,
              onCambio: (c) => setState(() => l.cantidad = c),
              onQuitar: () => setState(() => _lineas.remove(l)),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _notas,
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Nota (opcional)',
              hintText: 'Para la vitrina, urgente para el fin de semana…',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            solicita
                ? 'No mueve nada todavía: lo despacha el auxiliar de inventario de la sede de origen o '
                    'el Director General, que pueden enviar menos de lo pedido.'
                : 'Las unidades salen del origen y entran en el destino al guardar. Queda registrado a tu '
                    'nombre y el Director General lo ve en los cambios de inventario.',
            style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: listo && !_guardando ? _guardar : null,
          icon: _guardando
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2))
              : Icon(solicita ? Icons.send_rounded : Icons.local_shipping_outlined),
          label: Text(_lineas.isEmpty ? 'Añade productos' : (solicita ? 'Solicitar' : 'Mover ahora')),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
        ),
      ),
    );
  }
}

/// Una línea: el producto, cuánto hay en el origen y cuánto se lleva.
class _FilaLinea extends ConsumerWidget {
  const _FilaLinea({
    super.key,
    required this.linea,
    required this.origen,
    required this.nombreOrigen,
    required this.onCambio,
    required this.onQuitar,
  });

  final _Linea linea;
  final String? origen;
  final String? nombreOrigen;
  final ValueChanged<Cantidad> onCambio;
  final VoidCallback onQuitar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filas = ref.watch(disponibilidadProvider(linea.producto.uuid)).value ?? const <StockEnSede>[];
    final hay = filas.where((f) => f.sede.uuid == origen).firstOrNull?.stock ?? const Cantidad(0);
    final excede = origen != null && linea.cantidad > hay;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(linea.producto.nombre, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                IconButton(tooltip: 'Quitar', onPressed: onQuitar, icon: const Icon(Icons.close_rounded)),
              ],
            ),
            Text(
              origen == null ? 'Elige la sede de origen' : 'En ${nombreOrigen ?? 'el origen'}: ${hay.format()}',
              style: context.textos.bodySmall?.copyWith(
                color: excede || hay.milesimas <= 0 ? context.dominio.peligro : context.colores.onSurfaceVariant,
              ),
            ),
            if (origen != null && hay.milesimas > 0)
              SelectorCantidad(
                valor: excede ? hay : linea.cantidad,
                minimo: Cantidad.unidades(1) > hay ? hay : Cantidad.unidades(1),
                maximo: hay,
                onCambio: onCambio,
              ),
          ],
        ),
      ),
    );
  }
}

class _SelectorSede extends StatelessWidget {
  const _SelectorSede({
    required this.etiqueta,
    required this.icono,
    required this.sedes,
    required this.valor,
    required this.excluir,
    required this.onCambio,
    this.habilitado = true,
  });

  final String etiqueta;
  final IconData icono;
  final List<Sede> sedes;
  final String? valor;
  final String? excluir;
  final bool habilitado;
  final ValueChanged<String?> onCambio;

  @override
  Widget build(BuildContext context) {
    final opciones = sedes.where((s) => s.uuid != excluir).toList();
    return DropdownButtonFormField<String>(
      key: ValueKey('$etiqueta-$valor-${opciones.length}'),
      initialValue: opciones.any((s) => s.uuid == valor) ? valor : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: etiqueta, prefixIcon: Icon(icono)),
      items: [
        for (final s in opciones) DropdownMenuItem(value: s.uuid, child: Text(s.nombre)),
      ],
      onChanged: habilitado ? onCambio : null,
    );
  }
}

/// Buscador de productos para añadir al traslado.
class _SelectorProducto extends ConsumerStatefulWidget {
  const _SelectorProducto();

  @override
  ConsumerState<_SelectorProducto> createState() => _SelectorProductoState();
}

class _SelectorProductoState extends ConsumerState<_SelectorProducto> {
  String _busqueda = '';

  @override
  Widget build(BuildContext context) {
    final productos = ref.watch(_busquedaProvider(_busqueda));
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _busqueda = v),
              decoration: const InputDecoration(
                hintText: 'Buscar producto o código',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(
            child: productos.when(
              loading: () => const SkeletonLista(),
              error: (e, _) => EstadoError(mensaje: '$e'),
              data: (lista) => lista.isEmpty
                  ? const EstadoVacio(
                      icono: Icons.search_off_rounded,
                      titulo: 'Nada coincide',
                      descripcion: 'Prueba con menos letras o con el código.',
                      compacto: true,
                    )
                  : ListView.builder(
                      controller: scroll,
                      itemCount: lista.length,
                      itemBuilder: (context, i) => ListTile(
                        title: Text(lista[i].nombre),
                        subtitle: Text(lista[i].sku),
                        onTap: () => Navigator.of(context).pop(lista[i]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

final _busquedaProvider = StreamProvider.autoDispose.family<List<ProductoConCategoria>, String>(
  (ref, texto) => ref.watch(productosDaoProvider).observar(busqueda: texto, limite: 80),
);
