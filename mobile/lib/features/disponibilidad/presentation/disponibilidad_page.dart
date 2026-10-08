import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/daos/productos_dao.dart';
import '../../../core/database/daos/sedes_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/providers/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../productos/presentation/productos_providers.dart';
import '../../sedes/presentation/sedes_providers.dart';
import 'disponibilidad_widgets.dart';

final _resultadosProvider = StreamProvider.autoDispose.family<List<ProductoConCategoria>, String>(
  (ref, texto) => texto.trim().isEmpty
      ? Stream.value(const [])
      : ref.watch(productosDaoProvider).observar(busqueda: texto, limite: 30),
);

/// Existencias en todas las sedes de varios productos a la vez, con una sola
/// consulta (la clave es la lista de uuids unida).
final _existenciasProvider = StreamProvider.autoDispose.family<Map<String, List<StockEnSede>>, String>(
  (ref, uuids) => ref.watch(sedesDaoProvider).observarDisponibilidad(uuids.isEmpty ? const [] : uuids.split(',')),
);

/// «¿Dónde hay?»: busca un producto y muestra en qué sedes hay, cuántas
/// unidades y a qué precio.
///
/// Es para el mostrador: el cliente pide un Samsung A17, aquí no queda, y el
/// vendedor ve al instante que en Norte hay 3. El vendedor sólo consulta; el
/// gerente puede solicitarlo para su sede, y el director o el auxiliar
/// moverlo. Funciona sin red con los datos de la última sincronización (lo
/// dice arriba); deslizar hacia abajo los actualiza.
class DisponibilidadPage extends ConsumerStatefulWidget {
  const DisponibilidadPage({super.key, this.productoUuid});

  /// Si llega, se abre directamente en ese producto.
  final String? productoUuid;

  @override
  ConsumerState<DisponibilidadPage> createState() => _DisponibilidadPageState();
}

class _DisponibilidadPageState extends ConsumerState<DisponibilidadPage> {
  final _texto = TextEditingController();
  String _busqueda = '';

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  Future<void> _escanear() async {
    final codigo = await context.push<String>('${Rutas.escanear}?modo=codigo');
    if (codigo == null || !mounted) return;
    final r = await ref.read(productosDaoProvider).resolverCodigo(codigo);
    if (!mounted) return;
    if (r == null) {
      mostrarMensaje(context, 'Ese código no está en el catálogo', esError: true);
      return;
    }
    _texto.text = r.producto.nombre;
    setState(() => _busqueda = r.producto.nombre);
  }

  @override
  Widget build(BuildContext context) {
    final ultimoSync = ref.watch(estadoSyncProvider).value?.ultimoSync;
    final unico = widget.productoUuid == null ? null : ref.watch(productoProvider(widget.productoUuid!)).value;

    return Scaffold(
      appBar: AppBar(title: const Text('¿Dónde hay?')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncEngineProvider).sincronizar(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (widget.productoUuid == null)
              TextField(
                controller: _texto,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _busqueda = v),
                decoration: InputDecoration(
                  hintText: 'Producto, referencia o código',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    tooltip: 'Escanear',
                    onPressed: _escanear,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
              child: Text(
                ultimoSync == null
                    ? 'Existencias guardadas en el teléfono. Desliza hacia abajo para actualizarlas.'
                    : 'Existencias de ${Fechas.relativo(ultimoSync)}. Desliza hacia abajo para actualizarlas.',
                style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
              ),
            ),
            if (unico != null)
              DisponibilidadProducto(item: unico, titulo: unico.nombre)
            else if (widget.productoUuid == null)
              _Resultados(busqueda: _busqueda),
          ],
        ),
      ),
    );
  }
}

class _Resultados extends ConsumerWidget {
  const _Resultados({required this.busqueda});

  final String busqueda;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (busqueda.trim().length < 2) {
      return const Padding(
        padding: EdgeInsets.only(top: 32),
        child: EstadoVacio(
          icono: Icons.travel_explore_rounded,
          titulo: 'Busca un producto',
          descripcion: 'Escribe el nombre o la referencia —por ejemplo «samsung a17»— o escanea el código.',
          compacto: true,
        ),
      );
    }
    final productos = ref.watch(_resultadosProvider(busqueda));
    return productos.when(
      loading: () => const SkeletonLista(filas: 3),
      error: (e, _) => EstadoError(mensaje: '$e'),
      data: (lista) {
        if (lista.isEmpty) {
          return const EstadoVacio(
            icono: Icons.search_off_rounded,
            titulo: 'Nada coincide',
            descripcion: 'Prueba con menos palabras o con la referencia.',
            compacto: true,
          );
        }
        final existencias = ref.watch(_existenciasProvider(lista.map((p) => p.uuid).join(','))).value ?? const {};
        return Column(
          children: [
            for (final (i, p) in lista.indexed)
              EntradaEscalonada(
                indice: i,
                child: _TarjetaProducto(item: p, filas: existencias[p.uuid] ?? const []),
              ),
          ],
        );
      },
    );
  }
}

/// Un resultado: el producto, cuánto hay aquí y en qué otras sedes hay.
/// Al tocarlo se despliega el detalle por sede con sus acciones.
class _TarjetaProducto extends ConsumerStatefulWidget {
  const _TarjetaProducto({required this.item, required this.filas});

  final ProductoConCategoria item;
  final List<StockEnSede> filas;

  @override
  ConsumerState<_TarjetaProducto> createState() => _TarjetaProductoState();
}

class _TarjetaProductoState extends ConsumerState<_TarjetaProducto> {
  bool _abierta = false;

  @override
  Widget build(BuildContext context) {
    final activa = ref.watch(sedeActivaProvider).value?.uuid;
    final aqui = widget.filas.where((f) => f.sede.uuid == activa).firstOrNull?.stock ?? const Cantidad(0);
    final otras = widget.filas.where((f) => f.sede.uuid != activa && f.stock.milesimas > 0).toList()
      ..sort((a, b) => b.stock.milesimas.compareTo(a.stock.milesimas));
    final d = context.dominio;

    if (_abierta) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          children: [
            DisponibilidadProducto(item: widget.item, titulo: widget.item.nombre),
            TextButton.icon(
              onPressed: () => setState(() => _abierta = false),
              icon: const Icon(Icons.expand_less_rounded),
              label: const Text('Cerrar'),
            ),
          ],
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => setState(() => _abierta = true),
        title: Text(widget.item.nombre, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.item.sku} · ${widget.item.precioVenta.format()}'),
            const SizedBox(height: 2),
            Text(
              otras.isEmpty
                  ? 'No hay en ninguna otra sede'
                  : 'Hay en: ${otras.map((f) => '${f.sede.nombre} (${f.stock.format()})').join(' · ')}',
              style: context.textos.bodySmall?.copyWith(color: otras.isEmpty ? d.peligro : d.exito),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('Aquí', style: context.textos.labelSmall),
            Text(
              aqui.milesimas <= 0 ? '0' : aqui.format(),
              style: context.textos.titleMedium?.copyWith(color: aqui.milesimas <= 0 ? d.peligro : null),
            ),
          ],
        ),
      ),
    );
  }
}

/// Una línea para donde un producto está agotado en la sede activa: «Hay en
/// Norte (3) · Centro (1)», que lleva a «¿Dónde hay?». Si no hay en ninguna,
/// no ocupa espacio.
class HayEnOtrasSedes extends ConsumerWidget {
  const HayEnOtrasSedes({super.key, required this.productoUuid, this.colorTexto});

  final String productoUuid;
  final Color? colorTexto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filas = ref.watch(disponibilidadProvider(productoUuid)).value ?? const <StockEnSede>[];
    final activa = ref.watch(sedeActivaProvider).value?.uuid;
    final otras = filas.where((f) => f.sede.uuid != activa && f.stock.milesimas > 0).toList()
      ..sort((a, b) => b.stock.milesimas.compareTo(a.stock.milesimas));
    if (otras.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: () => context.push('${Rutas.disponibilidad}?producto=$productoUuid'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(Icons.travel_explore_rounded, size: 16, color: colorTexto ?? context.dominio.info),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Hay en ${otras.take(3).map((f) => '${f.sede.nombre} (${f.stock.format()})').join(' · ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.textos.bodySmall?.copyWith(
                  color: colorTexto ?? context.dominio.info,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
