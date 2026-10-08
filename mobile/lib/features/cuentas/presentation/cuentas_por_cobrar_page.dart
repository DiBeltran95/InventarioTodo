import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/database/daos/recaudos_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/negocio/caja.dart';
import '../../../core/providers/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/encabezado_hoja.dart';
import '../../../core/widgets/estados.dart';

final _cuentasProvider = StreamProvider.autoDispose<List<CuentaEntidad>>(
  (ref) => ref.watch(recaudosDaoProvider).observarCuentas(),
);

/// Cuentas por cobrar a entidades de crédito (Addi, Crediya…).
///
/// La venta ya se entregó: el cliente pagó con la entidad, y la entidad le paga
/// al negocio después, descontando su comisión. Aquí se ve cuánto debe cada
/// una, qué está vencido —más días de los que suele tardar— y, venta por venta,
/// a quién se le vendió y qué se llevó.
class CuentasPorCobrarPage extends ConsumerWidget {
  const CuentasPorCobrarPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cuentas = ref.watch(_cuentasProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cuentas por cobrar')),
      body: cuentas.when(
        loading: () => const SkeletonLista(),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (lista) {
          if (lista.isEmpty) {
            return const EstadoVacio(
              icono: Icons.account_balance_outlined,
              titulo: 'Nada por cobrar',
              descripcion: 'Las ventas pagadas con una entidad de crédito (Addi, Crediya…) '
                  'aparecen aquí hasta que la entidad las pague.',
            );
          }
          final total = Money.sumar(lista.map((c) => c.total));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                color: context.colores.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Te deben en total', style: context.textos.labelLarge),
                      Text(total.format(), style: context.textos.headlineMedium),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final (i, c) in lista.indexed) EntradaEscalonada(indice: i, child: _Entidad(cuenta: c)),
            ],
          );
        },
      ),
    );
  }
}

class _Entidad extends StatelessWidget {
  const _Entidad({required this.cuenta});

  final CuentaEntidad cuenta;

  @override
  Widget build(BuildContext context) {
    final vencidos = cuenta.vencidos;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: ExpansionTile(
        shape: const Border(),
        title: Text(cuenta.metodo.nombre, style: context.textos.titleMedium),
        subtitle: Text(
          '${cuenta.pendientes.length} venta${cuenta.pendientes.length == 1 ? '' : 's'} pendiente${cuenta.pendientes.length == 1 ? '' : 's'}'
          '${vencidos.isEmpty ? '' : ' · ${vencidos.length} vencida${vencidos.length == 1 ? '' : 's'} (${cuenta.totalVencido.format()})'}',
          style: context.textos.bodySmall?.copyWith(color: vencidos.isEmpty ? null : context.dominio.peligro),
        ),
        trailing: Text(cuenta.total.format(), style: context.textos.titleMedium),
        children: [
          for (final p in cuenta.pendientes)
            ListTile(
              dense: true,
              onTap: () => context.push(Rutas.ventaDetalle(p.venta.uuid)),
              title: Text(p.venta.clienteNombre ?? 'Cliente sin nombre'),
              subtitle: Text(
                '${p.venta.numero} · ${p.venta.clienteDocumento ?? 's/d'}'
                '${p.pago.referencia == null ? '' : ' · ref. ${p.pago.referencia}'}'
                ' · ${Fechas.formatFechaCorta(p.venta.fecha)} (${p.dias} d)'
                '${p.sede == null ? '' : ' · ${p.sede!.nombre}'}',
              ),
              trailing: Text(
                p.pendiente.format(),
                style: context.textos.titleSmall?.copyWith(
                  color: cuenta.metodo.diasPago != null && p.dias > cuenta.metodo.diasPago!
                      ? context.dominio.peligro
                      : null,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: FilledButton.tonalIcon(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => _HojaRecaudo(cuenta: cuenta),
              ),
              icon: const Icon(Icons.savings_outlined),
              label: Text('Registrar pago de ${cuenta.metodo.nombre}'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Registrar lo que pagó la entidad.
///
/// Se escribe lo que llegó a la cuenta; la comisión se propone según la que
/// tiene configurada la entidad, y se puede corregir. Lo que se descuenta de la
/// deuda es la suma de ambas: la comisión también salda la venta.
class _HojaRecaudo extends ConsumerStatefulWidget {
  const _HojaRecaudo({required this.cuenta});

  final CuentaEntidad cuenta;

  @override
  ConsumerState<_HojaRecaudo> createState() => _HojaRecaudoState();
}

class _HojaRecaudoState extends ConsumerState<_HojaRecaudo> {
  final _monto = TextEditingController();
  final _comision = TextEditingController();
  final _referencia = TextEditingController();
  bool _comisionTocada = false;
  bool _guardando = false;

  @override
  void dispose() {
    _monto.dispose();
    _comision.dispose();
    _referencia.dispose();
    super.dispose();
  }

  Money get _neto => Money.tryParse(_monto.text.replaceAll('.', ''));
  Money get _com => Money.tryParse(_comision.text.replaceAll('.', ''));

  /// Si la entidad paga un neto N con comisión p, el bruto saldado es
  /// N / (1 − p). Se propone la comisión que corresponde a ese bruto.
  void _proponerComision() {
    if (_comisionTocada) return;
    final pct = widget.cuenta.metodo.comisionPct;
    if (pct == null || pct <= 0 || pct >= 10000 || !_neto.esPositivo) {
      _comision.text = '';
      return;
    }
    final bruto = Money((_neto.centavos * 10000 + (10000 - pct) ~/ 2) ~/ (10000 - pct));
    _comision.text = (bruto - _neto).toApi().split('.').first;
  }

  Future<void> _guardar() async {
    setState(() => _guardando = true);
    try {
      final r = await ref.read(recaudosDaoProvider).registrar(
            cuenta: widget.cuenta,
            monto: _neto,
            comision: _com,
            referencia: _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
          );
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      Navigator.pop(context);
      mostrarMensaje(context, 'Pago aplicado a ${r.aplicadas} venta${r.aplicadas == 1 ? '' : 's'}', esExito: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _neto + _com;
    final excede = total > widget.cuenta.total;
    final esperada = comisionEsperada(total, widget.cuenta.metodo.comisionPct);

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
                titulo: 'Pago de ${widget.cuenta.metodo.nombre}',
                subtitulo: 'Debe ${widget.cuenta.total.format()}',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _monto,
                autofocus: true,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(_proponerComision),
                decoration: const InputDecoration(labelText: 'Lo que llegó a la cuenta', prefixText: r'$ '),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _comision,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() => _comisionTocada = true),
                decoration: InputDecoration(
                  labelText: 'Comisión que retuvo',
                  prefixText: r'$ ',
                  helperText: widget.cuenta.metodo.comisionPct == null
                      ? 'Configura su comisión en Medios de pago para proponerla'
                      : 'Según su comisión debería ser ${esperada.format()}',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _referencia,
                decoration: const InputDecoration(labelText: 'Referencia de la consignación'),
              ),
              const SizedBox(height: 12),
              Text(
                excede
                    ? 'Es más de lo que debe: revisa el monto o la comisión.'
                    : 'Se descuentan ${total.format()} de las ventas más antiguas.',
                style: context.textos.bodySmall?.copyWith(
                  color: excede ? context.dominio.peligro : context.colores.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: !_guardando && total.esPositivo && !excede ? _guardar : null,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Aplicar pago'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
