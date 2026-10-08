import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/productos_dao.dart';
import '../../../core/database/daos/traslados_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/negocio/traslados.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/estados.dart';
import '../../sedes/presentation/sedes_providers.dart';

/// Pedir un traslado.
///
/// Dos direcciones con la misma pantalla: enviar desde mi sede a otra, o pedir
/// a otra sede que me envíe. El selector de sedes sólo deja combinaciones en
/// las que el usuario está en un extremo, y avisa antes de guardar si no lo
/// está.
///
/// Puede llegar con un producto ya elegido (desde «Stock bajo»), para que pedir
/// reposición sea un toque y no un formulario.
class TrasladoNuevoPage extends ConsumerStatefulWidget {
  const TrasladoNuevoPage({super.key, this.productoUuid, this.sedeDestinoUuid});

  final String? productoUuid;
  final String? sedeDestinoUuid;

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

  @override
  void dispose() {
    _notas.dispose();
    super.dispose();
  }

  Future<void> _precargar(List<Sede> misSedes, Sede? activa) async {
    if (_inicializado) return;
    _inicializado = true;
    // Por defecto: pedir PARA mi sede activa (el caso de «se me acabó»).
    _destino = widget.sedeDestinoUuid ?? activa?.uuid;
    if (widget.productoUuid != null) {
      final p = await ref.read(productosDaoProvider).obtener(widget.productoUuid!);
      if (p != null && mounted) {
        setState(() => _lineas.add(_Linea(p, Cantidad.unidades(1))));
      }
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

  Future<void> _guardar() async {
    final origen = _origen;
    final destino = _destino;
    if (origen == null || destino == null || _lineas.isEmpty) return;
    final actor = ref.read(actorProvider);
    final motivo = actor == null ? 'Sin sesión' : motivoNoPuedeCrear(actor, origen, destino);
    if (motivo != null) {
      mostrarMensaje(context, motivo, esError: true);
      return;
    }

    setState(() => _guardando = true);
    try {
      await ref.read(trasladosDaoProvider).crear(
            sedeOrigenUuid: origen,
            sedeDestinoUuid: destino,
            notas: _notas.text.trim().isEmpty ? null : _notas.text.trim(),
            lineas: [
              for (final l in _lineas)
                LineaTraslado(productoUuid: l.producto.uuid, descripcion: l.producto.nombre, cantidad: l.cantidad),
            ],
          );
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      mostrarMensaje(context, 'Traslado pedido', esExito: true);
      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final todas = ref.watch(sedesActivasProvider).value ?? const <Sede>[];
    final misSedes = ref.watch(misSedesProvider).value ?? const <Sede>[];
    final activa = ref.watch(sedeActivaProvider).value;
    final actor = ref.watch(actorProvider);
    _precargar(misSedes, activa);

    final motivo = (actor == null || _origen == null || _destino == null)
        ? null
        : motivoNoPuedeCrear(actor, _origen!, _destino!);
    final listo = _origen != null && _destino != null && _lineas.isNotEmpty && motivo == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Pedir traslado')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          _SelectorSede(
            etiqueta: 'Sale de',
            icono: Icons.logout_rounded,
            sedes: todas,
            valor: _origen,
            excluir: _destino,
            onCambio: (v) => setState(() => _origen = v),
          ),
          Center(
            child: IconButton(
              tooltip: 'Invertir',
              onPressed: () => setState(() {
                final o = _origen;
                _origen = _destino;
                _destino = o;
              }),
              icon: const Icon(Icons.swap_vert_rounded),
            ),
          ),
          _SelectorSede(
            etiqueta: 'Llega a',
            icono: Icons.login_rounded,
            sedes: todas,
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
            Card(
              child: ListTile(
                title: Text(l.producto.nombre, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('Aquí: ${l.producto.stock.format()}'),
                trailing: _Contador(
                  valor: l.cantidad,
                  onCambio: (c) => setState(() {
                    if (c.esCero) {
                      _lineas.remove(l);
                    } else {
                      l.cantidad = c;
                    }
                  }),
                ),
              ),
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
            'Lo aprueba otra persona: el gerente de la sede de origen si lo pides tú, '
            'o alguien de esa sede si lo pide un gerente. El stock se mueve al aprobarse.',
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
              : const Icon(Icons.send_rounded),
          label: Text(_lineas.isEmpty ? 'Añade productos' : 'Pedir traslado'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
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
  });

  final String etiqueta;
  final IconData icono;
  final List<Sede> sedes;
  final String? valor;
  final String? excluir;
  final ValueChanged<String?> onCambio;

  @override
  Widget build(BuildContext context) {
    final opciones = sedes.where((s) => s.uuid != excluir).toList();
    return DropdownButtonFormField<String>(
      initialValue: opciones.any((s) => s.uuid == valor) ? valor : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: etiqueta, prefixIcon: Icon(icono)),
      items: [
        for (final s in opciones) DropdownMenuItem(value: s.uuid, child: Text(s.nombre)),
      ],
      onChanged: onCambio,
    );
  }
}

class _Contador extends StatelessWidget {
  const _Contador({required this.valor, required this.onCambio});

  final Cantidad valor;
  final ValueChanged<Cantidad> onCambio;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Menos',
          onPressed: () => onCambio(valor - Cantidad.unidades(1)),
          icon: Icon(valor.milesimas <= 1000 ? Icons.delete_outline_rounded : Icons.remove_rounded),
        ),
        Text(valor.format(), style: context.textos.titleMedium),
        IconButton(
          tooltip: 'Más',
          onPressed: () => onCambio(valor + Cantidad.unidades(1)),
          icon: const Icon(Icons.add_rounded),
        ),
      ],
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
                        subtitle: Text('${lista[i].sku} · aquí ${lista[i].stock.format()}'),
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
