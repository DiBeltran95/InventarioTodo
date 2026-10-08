import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/cierres_dao.dart';
import '../../../core/money/money.dart';
import '../../../core/negocio/caja.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/estados.dart';
import '../../sedes/presentation/sedes_providers.dart';

final _esperadoProvider = FutureProvider.autoDispose.family<List<EsperadoPorMedio>, String>(
  (ref, turno) {
    // Se recalcula cada vez que cambia la cola: es decir, con cada venta nueva.
    ref.watch(estadoSyncProvider.select((e) => e.value?.pendientes));
    return ref.watch(cierresDaoProvider).esperado(turno);
  },
);

/// Mi caja.
///
/// Abrir con la base de efectivo, ver lo que debería haber en cada medio
/// mientras se vende, y cerrar contando. La diferencia se ve mientras se
/// escribe, antes de confirmar: es el momento de volver a contar, no después.
class CajaPage extends ConsumerWidget {
  const CajaPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caja = ref.watch(cajaAbiertaProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mi caja')),
      body: caja.when(
        loading: () => const SkeletonLista(filas: 3),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (abierta) => abierta == null ? const _Abrir() : _Abierta(caja: abierta),
      ),
    );
  }
}

class _Abrir extends ConsumerStatefulWidget {
  const _Abrir();

  @override
  ConsumerState<_Abrir> createState() => _AbrirState();
}

class _AbrirState extends ConsumerState<_Abrir> {
  final _base = TextEditingController();
  bool _guardando = false;

  @override
  void dispose() {
    _base.dispose();
    super.dispose();
  }

  Future<void> _abrir() async {
    setState(() => _guardando = true);
    try {
      await ref.read(cierresDaoProvider).abrir(baseEfectivo: Money.tryParse(_base.text.replaceAll('.', '')));
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (mounted) mostrarMensaje(context, 'Caja abierta', esExito: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(Icons.point_of_sale_rounded, size: 56, color: context.colores.primary),
        const SizedBox(height: 12),
        Text('Abre tu caja', textAlign: TextAlign.center, style: context.textos.headlineSmall),
        const SizedBox(height: 8),
        Text(
          'Cuenta el efectivo con el que empiezas. Al cerrar, la app sabrá cuánto debería haber.',
          textAlign: TextAlign.center,
          style: context.textos.bodyMedium?.copyWith(color: context.colores.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _base,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Base de efectivo', prefixText: r'$ ', hintText: '0'),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _guardando ? null : _abrir,
          icon: const Icon(Icons.lock_open_rounded),
          label: const Text('Abrir caja'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
        ),
      ],
    );
  }
}

class _Abierta extends ConsumerWidget {
  const _Abierta({required this.caja});

  final CierreCaja caja;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final esperado = ref.watch(_esperadoProvider(caja.uuid));
    final tardia = Fechas.diaHabil(caja.abiertoEn) != Fechas.hoy();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          color: tardia ? context.dominio.advertenciaContenedor : context.dominio.exitoContenedor,
          child: ListTile(
            leading: Icon(
              tardia ? Icons.warning_amber_rounded : Icons.lock_open_rounded,
              color: tardia ? context.dominio.advertencia : context.dominio.exito,
            ),
            title: Text(tardia ? 'Caja abierta desde otro día' : 'Caja abierta'),
            subtitle: Text(
              'Desde ${Fechas.formatFechaHora(caja.abiertoEn)} · base ${Money(caja.baseEfectivo).format()}'
              '${tardia ? '\nCiérrala: el turno anterior quedó sin cuadrar.' : ''}',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Debería haber', style: context.textos.titleMedium),
        const SizedBox(height: 8),
        esperado.when(
          loading: () => const SkeletonBloque(alto: 120),
          error: (e, _) => EstadoError(mensaje: '$e'),
          data: (medios) => Card(
            child: Column(
              children: [
                for (final m in medios)
                  ListTile(
                    leading: Icon(m.esEfectivo ? Icons.payments_outlined : Icons.account_balance_wallet_outlined),
                    title: Text(m.metodoNombre),
                    subtitle: m.esEfectivo ? const Text('Base + ventas en efectivo') : null,
                    trailing: Text(m.esperado.format(), style: context.textos.titleMedium),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () async {
            final medios = await ref.read(cierresDaoProvider).esperado(caja.uuid);
            if (!context.mounted) return;
            await showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => HojaCerrarCaja(caja: caja, medios: medios, tardia: tardia),
            );
          },
          icon: const Icon(Icons.lock_rounded),
          label: const Text('Contar y cerrar caja'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
        ),
      ],
    );
  }
}

/// Conteo de cierre. El efectivo es obligatorio; los demás medios se pueden
/// dejar sin verificar —un datáfono no siempre permite comprobarlo en el
/// momento— y no inventan una diferencia.
class HojaCerrarCaja extends ConsumerStatefulWidget {
  const HojaCerrarCaja({super.key, required this.caja, required this.medios, this.tardia = false});

  final CierreCaja caja;
  final List<EsperadoPorMedio> medios;
  final bool tardia;

  @override
  ConsumerState<HojaCerrarCaja> createState() => _HojaCerrarCajaState();
}

class _HojaCerrarCajaState extends ConsumerState<HojaCerrarCaja> {
  late final _controles = {for (final m in widget.medios) m: TextEditingController()};
  final _notas = TextEditingController();
  bool _guardando = false;

  @override
  void dispose() {
    for (final c in _controles.values) {
      c.dispose();
    }
    _notas.dispose();
    super.dispose();
  }

  Money? _contado(EsperadoPorMedio m) {
    final t = _controles[m]!.text.trim();
    return t.isEmpty ? null : Money.tryParse(t.replaceAll('.', ''));
  }

  Future<void> _cerrar() async {
    final efectivo = widget.medios.firstWhere((m) => m.esEfectivo);
    if (_contado(efectivo) == null) {
      mostrarMensaje(context, 'Cuenta el efectivo antes de cerrar', esError: true);
      return;
    }
    setState(() => _guardando = true);
    try {
      await ref.read(cierresDaoProvider).cerrar(
            turnoUuid: widget.caja.uuid,
            conteos: [for (final m in widget.medios) ConteoMedio(medio: m, contado: _contado(m))],
            notas: _notas.text.trim().isEmpty ? null : _notas.text.trim(),
            tardio: widget.tardia,
          );
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.heavyImpact();
      if (!mounted) return;
      Navigator.pop(context);
      mostrarMensaje(context, 'Caja cerrada', esExito: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, '$e'.replaceFirst('Bad state: ', ''), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final efectivo = widget.medios.firstWhere((m) => m.esEfectivo);
    final contadoEfectivo = _contado(efectivo);
    final diferencia = contadoEfectivo == null ? null : contadoEfectivo - efectivo.esperado;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Cierre de caja', style: context.textos.headlineSmall),
              const SizedBox(height: 16),
              for (final m in widget.medios) ...[
                TextField(
                  controller: _controles[m],
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: m.esEfectivo ? 'Efectivo contado *' : '${m.metodoNombre} (opcional)',
                    helperText: 'Debería haber ${m.esperado.format()}',
                    prefixText: r'$ ',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (diferencia != null) _Diferencia(diferencia: diferencia),
              const SizedBox(height: 12),
              TextField(
                controller: _notas,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Notas',
                  hintText: 'Si hay diferencia, explícala aquí',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _guardando ? null : _cerrar,
                icon: const Icon(Icons.lock_rounded),
                label: const Text('Cerrar caja'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Diferencia extends StatelessWidget {
  const _Diferencia({required this.diferencia});

  final Money diferencia;

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    final cuadra = diferencia.esCero;
    final (color, fondo, texto) = cuadra
        ? (d.exito, d.exitoContenedor, 'Cuadra exacto')
        : diferencia.esNegativo
            ? (d.peligro, d.peligroContenedor, 'Faltan ${(-diferencia).format()}')
            : (d.advertencia, d.advertenciaContenedor, 'Sobran ${diferencia.format()}');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(cuadra ? Icons.check_circle_rounded : Icons.error_outline_rounded, color: color),
          const SizedBox(width: 10),
          Text(texto, style: context.textos.titleMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// Cierres de caja de las sedes del gestor: lo primero, los que tienen
/// diferencia y nadie ha revisado.
class CierresPage extends ConsumerWidget {
  const CierresPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cierres = ref.watch(_cierresProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Cierres de caja')),
      body: cierres.when(
        loading: () => const SkeletonLista(),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (lista) {
          if (lista.isEmpty) {
            return const EstadoVacio(
              icono: Icons.point_of_sale_outlined,
              titulo: 'Sin cierres todavía',
              descripcion: 'Cuando tu equipo abra y cierre caja, sus turnos aparecen aquí.',
            );
          }
          final ordenados = [...lista]
            ..sort((a, b) {
              int peso(CierreConDatos c) => c.conDiferencia && !c.revisado ? 0 : (c.abierto ? 1 : 2);
              final p = peso(a) - peso(b);
              return p != 0 ? p : b.cierre.abiertoEn.compareTo(a.cierre.abiertoEn);
            });
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: ordenados.length,
            itemBuilder: (context, i) => _FilaCierre(item: ordenados[i]),
          );
        },
      ),
    );
  }
}

final _cierresProvider = StreamProvider.autoDispose<List<CierreConDatos>>(
  (ref) => ref.watch(cierresDaoProvider).observar(desde: Fechas.sumarDias(Fechas.hoy(), -30)),
);

class _FilaCierre extends ConsumerWidget {
  const _FilaCierre({required this.item});

  final CierreConDatos item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = item.cierre;
    final d = context.dominio;
    final dif = item.diferencia;
    final (color, texto) = item.abierto
        ? (d.info, 'Abierta')
        : dif == null
            ? (context.colores.onSurfaceVariant, 'Cerrada')
            : dif.esCero
                ? (d.exito, 'Cuadra')
                : dif.esNegativo
                    ? (d.peligro, 'Faltan ${(-dif).format()}')
                    : (d.advertencia, 'Sobran ${dif.format()}');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(item.usuario?.nombre ?? 'Empleado'),
        subtitle: Text(
          '${item.sede?.nombre ?? ''} · ${Fechas.formatFechaHora(c.abiertoEn)}'
          '${c.cerradoEn == null ? '' : ' → ${Fechas.formatHora(c.cerradoEn!)}'}'
          '${c.cierreTardio ? ' · cierre tardío' : ''}'
          '${c.notas == null ? '' : '\n«${c.notas}»'}',
        ),
        isThreeLine: c.notas != null,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(texto, style: context.textos.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700)),
            if (item.revisado)
              Text('Revisado', style: context.textos.labelSmall)
            else if (!item.abierto)
              InkWell(
                onTap: () async {
                  await ref.read(cierresDaoProvider).marcarRevisado(c.uuid);
                  ref.read(syncEngineProvider).solicitar();
                },
                child: Text(
                  'Marcar revisado',
                  style: context.textos.labelSmall?.copyWith(color: context.colores.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
