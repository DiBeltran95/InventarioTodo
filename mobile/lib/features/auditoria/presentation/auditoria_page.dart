import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../sedes/data/gestion_api.dart';
import '../../sedes/presentation/sedes_providers.dart';

/// Qué significa cada acción, en lenguaje del negocio.
const _acciones = <String, (String, IconData)>{
  'VENTA_ANULADA': ('anuló una venta', Icons.receipt_long_outlined),
  'STOCK_AJUSTADO': ('ajustó el stock', Icons.tune_rounded),
  'MERMA_REGISTRADA': ('registró una merma', Icons.broken_image_outlined),
  'ENTRADA_REGISTRADA': ('registró una entrada', Icons.add_box_outlined),
  'AJUSTE_SOLICITADO': ('pidió un ajuste', Icons.fact_check_outlined),
  'AJUSTE_APROBADO': ('aprobó un ajuste', Icons.task_alt_rounded),
  'AJUSTE_RECHAZADO': ('rechazó un ajuste', Icons.unpublished_outlined),
  'PRECIO_CAMBIADO': ('cambió un precio', Icons.sell_outlined),
  'PRODUCTO_ELIMINADO': ('eliminó un producto', Icons.delete_outline_rounded),
  'USUARIO_CREADO': ('creó una cuenta', Icons.person_add_alt_1_outlined),
  'USUARIO_ACTIVADO': ('habilitó a un empleado', Icons.how_to_reg_outlined),
  'USUARIO_DESACTIVADO': ('inhabilitó a un empleado', Icons.person_off_outlined),
  'USUARIO_ELIMINADO': ('dio de baja una cuenta', Icons.person_remove_outlined),
  'ROL_CAMBIADO': ('cambió un rol', Icons.badge_outlined),
  'SEDES_CAMBIADAS': ('cambió de sede a un empleado', Icons.swap_horiz_rounded),
  'HORARIO_CAMBIADO': ('cambió un horario', Icons.calendar_month_outlined),
  'ACCESO_EXTRA_OTORGADO': ('dio acceso extra', Icons.more_time_rounded),
  'ACCESO_EXTRA_REVOCADO': ('quitó un acceso extra', Icons.timer_off_outlined),
  'INGRESO_FUERA_DE_HORARIO': ('intentó entrar fuera de horario', Icons.bedtime_outlined),
  'TRASLADO_APROBADO': ('aprobó un traslado', Icons.local_shipping_outlined),
  'TRASLADO_RECHAZADO': ('rechazó un traslado', Icons.block_rounded),
  'CIERRE_CON_DIFERENCIA': ('cerró caja con diferencia', Icons.point_of_sale_outlined),
  'CIERRE_REVISADO': ('revisó un cierre de caja', Icons.verified_outlined),
  'RECAUDO_REGISTRADO': ('registró un pago de una entidad', Icons.savings_outlined),
  'MEDIO_PAGO_CAMBIADO': ('cambió un medio de pago', Icons.payments_outlined),
  'SEDE_CREADA': ('creó una sede', Icons.add_business_outlined),
  'SEDE_CAMBIADA': ('editó una sede', Icons.storefront_outlined),
  'NEGOCIO_CAMBIADO': ('cambió los datos del negocio', Icons.business_outlined),
};

enum _Periodo {
  hoy('Hoy', 0),
  semana('7 días', 6),
  mes('30 días', 29),
  todo('Todo', null);

  const _Periodo(this.etiqueta, this.dias);
  final String etiqueta;
  final int? dias;
}

/// Registro de auditoría: quién hizo qué cosa sensible, dónde y cuándo.
///
/// Sólo en línea. El director ve todo; el gerente, lo de sus sedes (el
/// servidor filtra). Se pagina hacia atrás de 50 en 50.
class AuditoriaPage extends ConsumerStatefulWidget {
  const AuditoriaPage({super.key});

  @override
  ConsumerState<AuditoriaPage> createState() => _AuditoriaPageState();
}

class _AuditoriaPageState extends ConsumerState<AuditoriaPage> {
  _Periodo _periodo = _Periodo.semana;
  String? _sede;
  String? _accion;

  final _items = <EntradaAuditoria>[];
  int? _siguiente;
  bool _cargando = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _cargar(reiniciar: true);
  }

  Future<void> _cargar({bool reiniciar = false}) async {
    if (_cargando) return;
    setState(() {
      _cargando = true;
      _error = null;
      if (reiniciar) {
        _items.clear();
        _siguiente = null;
      }
    });
    try {
      final hoy = Fechas.hoy();
      final r = await ref.read(gestionApiProvider).auditoria(
            desde: _periodo.dias == null ? null : Fechas.sumarDias(hoy, -_periodo.dias!),
            sede: _sede,
            accion: _accion,
            antesDe: reiniciar ? null : _siguiente,
          );
      if (!mounted) return;
      setState(() {
        _items.addAll(r.items);
        _siguiente = r.siguiente;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _cargando = false;
      });
    }
  }

  void _filtrar(VoidCallback cambio) {
    setState(cambio);
    _cargar(reiniciar: true);
  }

  @override
  Widget build(BuildContext context) {
    final sedes = ref.watch(misSedesProvider).value ?? const <Sede>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Auditoría'),
        actions: [
          PopupMenuButton<String?>(
            tooltip: 'Filtrar por acción',
            icon: Icon(_accion == null ? Icons.filter_list_rounded : Icons.filter_list_alt),
            onSelected: (v) => _filtrar(() => _accion = v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('Todas las acciones')),
              for (final a in _acciones.entries)
                PopupMenuItem(value: a.key, child: Text(_mayuscula(a.value.$1))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _cargar(reiniciar: true),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in _Periodo.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(p.etiqueta),
                        selected: _periodo == p,
                        onSelected: (_) => _filtrar(() => _periodo = p),
                      ),
                    ),
                ],
              ),
            ),
            if (sedes.length > 1)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: const Text('Todas las sedes'),
                        selected: _sede == null,
                        onSelected: (_) => _filtrar(() => _sede = null),
                      ),
                    ),
                    for (final s in sedes)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(s.nombre),
                          selected: _sede == s.uuid,
                          onSelected: (_) => _filtrar(() => _sede = s.uuid),
                        ),
                      ),
                  ],
                ),
              ),
            if (_accion != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: InputChip(
                  label: Text(_mayuscula(_acciones[_accion]?.$1 ?? _accion!)),
                  onDeleted: () => _filtrar(() => _accion = null),
                ),
              ),
            const SizedBox(height: 8),
            if (_error != null && _items.isEmpty)
              EstadoVacio(
                icono: _error is ApiException && (_error as ApiException).esDeRed
                    ? Icons.cloud_off_rounded
                    : Icons.error_outline_rounded,
                titulo: _error is ApiException && (_error as ApiException).esDeRed
                    ? 'Sin conexión'
                    : 'No se pudo cargar la auditoría',
                descripcion: _error is ApiException ? (_error as ApiException).mensajeUsuario : '$_error',
                textoAccion: 'Reintentar',
                onAccion: () => _cargar(reiniciar: true),
              )
            else if (_items.isEmpty && _cargando)
              const SkeletonLista(filas: 5)
            else if (_items.isEmpty)
              const EstadoVacio(
                icono: Icons.manage_search_rounded,
                titulo: 'Sin registros',
                descripcion: 'No hay acciones registradas con estos filtros.',
              )
            else ...[
              for (final e in _items) _Fila(entrada: e),
              if (_siguiente != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    onPressed: _cargando ? null : _cargar,
                    child: Text(_cargando ? 'Cargando…' : 'Ver más antiguos'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _mayuscula(String t) => t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);

class _Fila extends StatelessWidget {
  const _Fila({required this.entrada});

  final EntradaAuditoria entrada;

  @override
  Widget build(BuildContext context) {
    final (texto, icono) = _acciones[entrada.accion] ?? (entrada.accion, Icons.history_rounded);
    final detalle = [
      ..._lineas('Antes', entrada.antes),
      ..._lineas('Después', entrada.despues),
    ];
    final peligro = const {'VENTA_ANULADA', 'USUARIO_DESACTIVADO', 'CIERRE_CON_DIFERENCIA', 'INGRESO_FUERA_DE_HORARIO'}
        .contains(entrada.accion);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        enabled: detalle.isNotEmpty,
        leading: Icon(icono, color: peligro ? context.dominio.peligro : context.colores.primary),
        title: Text('${entrada.usuario?.nombre ?? 'Sistema'} $texto', style: context.textos.bodyMedium),
        subtitle: Text(
          [Fechas.formatFechaHoraDocumento(entrada.fecha), ?entrada.sede?.nombre].join(' · '),
          style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
        ),
        trailing: detalle.isEmpty ? const SizedBox.shrink() : null,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [for (final l in detalle) Text(l, style: context.textos.bodySmall)],
      ),
    );
  }

  /// `{precio: 1000}` → «Antes · precio: 1000». Los valores anidados se
  /// muestran como JSON compacto: es un registro, no un informe.
  static List<String> _lineas(String titulo, Object? datos) {
    if (datos == null) return const [];
    if (datos is Map) {
      return [
        for (final e in datos.entries)
          if (e.value != null) '$titulo · ${e.key}: ${e.value is String || e.value is num || e.value is bool ? e.value : jsonEncode(e.value)}',
      ];
    }
    return ['$titulo · $datos'];
  }
}
