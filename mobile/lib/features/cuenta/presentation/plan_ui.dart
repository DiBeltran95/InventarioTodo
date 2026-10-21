import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/plan.dart';

/// Último plan conocido (se actualiza con cada bajada y con «Mi empresa»).
final planProvider = Provider<PlanEmpresa?>((ref) {
  void avisar() => ref.invalidateSelf();
  PlanLocal.actual.addListener(avisar);
  ref.onDispose(() => PlanLocal.actual.removeListener(avisar));
  if (PlanLocal.actual.value == null) unawaited(PlanLocal.cargar());
  return PlanLocal.actual.value;
});

/// Datos, plan y apps de la empresa, consultados al servidor (exige red).
final empresaProvider = FutureProvider.autoDispose<EmpresaInfo>(
  (ref) => ref.watch(authRepositoryProvider).empresa(),
);

/// Uso de un recurso del plan: nombre, «2 de 3» y una barra.
///
/// El estado se dice con número y texto («límite alcanzado»), nunca solo con
/// el color: se entiende sin distinguir colores y con lector de pantalla.
class MedidorUso extends StatelessWidget {
  const MedidorUso({super.key, required this.recurso, required this.uso});

  final RecursoLimitado recurso;
  final RecursoPlan uso;

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    final maximo = uso.maximo;
    final fraccion = maximo == null || maximo == 0 ? 0.0 : (uso.usados / maximo).clamp(0.0, 1.0);
    final color = uso.lleno
        ? d.peligro
        : fraccion >= 0.8
            ? d.advertencia
            : context.colores.primary;
    final cifra = maximo == null ? '${uso.usados}' : '${uso.usados} de $maximo';
    final estado = maximo == null
        ? 'Sin límite'
        : uso.lleno
            ? 'Límite alcanzado'
            : '${uso.disponibles} disponible${uso.disponibles == 1 ? '' : 's'}';

    return Semantics(
      label: '${recurso.titulo}: $cifra. $estado',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(recurso.titulo, style: context.textos.titleSmall)),
              Text(cifra, style: context.textos.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: maximo == null ? 0 : fraccion,
              minHeight: 6,
              color: color,
              backgroundColor: color.withValues(alpha: 0.16),
            ),
          ),
          const SizedBox(height: 4),
          Text(estado, style: context.textos.bodySmall?.copyWith(color: uso.lleno ? d.peligro : context.colores.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Hoja inferior que explica que el plan no admite un [recurso] más.
///
/// Se muestra antes de abrir el formulario y también si el servidor responde
/// LIMITE_PLAN. Texto neutro y sin enlaces de pago: los planes se gestionan
/// fuera de la app (política de Google Play).
Future<void> mostrarHojaLimite(BuildContext context, RecursoLimitado recurso, {PlanEmpresa? plan, RecursoPlan? uso}) {
  final usoMostrado = uso ?? plan?.de(recurso);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final d = ctx.dominio;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: CircleAvatar(
                  radius: 28,
                  backgroundColor: d.advertenciaContenedor,
                  child: Icon(Icons.workspace_premium_outlined, color: d.advertencia, size: 28),
                ),
              ),
              const SizedBox(height: 16),
              Text('Llegaste al límite de tu plan', style: ctx.textos.headlineSmall),
              const SizedBox(height: 8),
              Text(
                usoMostrado?.maximo == null
                    ? 'Tu plan no admite más ${recurso.plural} por ahora.'
                    : 'Tu plan${plan == null ? '' : ' ${plan.nombre}'} incluye hasta ${usoMostrado!.maximo} '
                        '${usoMostrado.maximo == 1 ? recurso.singular : recurso.plural} y ya los estás usando.',
                style: ctx.textos.bodyLarge?.copyWith(color: ctx.colores.onSurfaceVariant),
              ),
              if (plan?.vencido ?? false) ...[
                const SizedBox(height: 8),
                Text(
                  'Tu plan venció y la empresa opera con los límites del plan Gratis. Lo que ya tenías se conserva.',
                  style: ctx.textos.bodyMedium?.copyWith(color: d.advertencia),
                ),
              ],
              if (usoMostrado != null) ...[
                const SizedBox(height: 20),
                MedidorUso(recurso: recurso, uso: usoMostrado),
              ],
              const SizedBox(height: 20),
              _Sugerencia(
                icono: Icons.swap_horiz_rounded,
                texto: switch (recurso) {
                  RecursoLimitado.productos => 'Puedes desactivar un producto que ya no vendas para liberar su cupo.',
                  RecursoLimitado.sedes => 'Puedes desactivar una sede que ya no uses para liberar su cupo.',
                  RecursoLimitado.personas => 'Puedes inhabilitar la cuenta de alguien que ya no trabaje contigo para liberar su cupo.',
                },
              ),
              const SizedBox(height: 12),
              const _Sugerencia(
                icono: Icons.support_agent_rounded,
                texto: 'Tu plan lo gestiona el equipo de la plataforma: el director de tu empresa puede solicitar un cambio.',
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Entendido')),
            ],
          ),
        ),
      );
    },
  );
}

class _Sugerencia extends StatelessWidget {
  const _Sugerencia({required this.icono, required this.texto});
  final IconData icono;
  final String texto;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 20, color: context.colores.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(texto, style: context.textos.bodyMedium)),
        ],
      );
}

/// ¿Cabe un [recurso] más? Si no, explica el límite y devuelve false.
///
/// Funciona sin red: usa el último plan conocido y, para productos y sedes, lo
/// que hay en el teléfono (un alta hecha sin red todavía no está en el
/// servidor, pero sí ocupa su cupo). Con red intenta antes refrescar el plan.
/// El servidor tiene la última palabra: si responde LIMITE_PLAN, la misma hoja.
///
/// Con [refrescar] en false no consulta la red: respuesta inmediata, para
/// comprobar al abrir una pantalla sin hacer esperar a quien ya está en ella.
Future<bool> hayCupo(BuildContext context, WidgetRef ref, RecursoLimitado recurso, {bool refrescar = true}) async {
  PlanEmpresa? plan;
  try {
    if (!refrescar) throw StateError('sin refresco');
    plan = (await ref.read(authRepositoryProvider).empresa().timeout(const Duration(seconds: 4))).plan;
  } catch (_) {
    plan = PlanLocal.actual.value ?? await PlanLocal.cargar();
  }
  if (plan == null) return true;

  var uso = plan.de(recurso);
  final tabla = switch (recurso) {
    RecursoLimitado.productos => 'productos',
    RecursoLimitado.sedes => 'sedes',
    RecursoLimitado.personas => null,
  };
  if (tabla != null) {
    final db = ref.read(appDatabaseProvider);
    final fila = await db
        .customSelect('SELECT COUNT(*) AS n FROM $tabla WHERE activo = 1 AND deleted_at IS NULL')
        .getSingle();
    final locales = fila.read<int>('n');
    if (locales > uso.usados) uso = uso.conUsados(locales);
  }
  if (!uso.lleno) return true;
  if (context.mounted) await mostrarHojaLimite(context, recurso, plan: plan, uso: uso);
  return false;
}

/// Si [error] es LIMITE_PLAN, explica el límite y devuelve true.
Future<bool> manejarLimite(BuildContext context, Object error) async {
  if (error is! ApiException || error.codigo != 'LIMITE_PLAN') return false;
  final detalles = error.detalles;
  final recurso = RecursoLimitado.desdeApi(detalles is Map ? detalles['recurso'] : null) ?? RecursoLimitado.personas;
  final plan = PlanLocal.actual.value ?? await PlanLocal.cargar();
  if (context.mounted) await mostrarHojaLimite(context, recurso, plan: plan);
  return true;
}

/// Tarjeta con el plan vigente y sus tres medidores.
class TarjetaPlan extends StatelessWidget {
  const TarjetaPlan({super.key, required this.plan});
  final PlanEmpresa plan;

  @override
  Widget build(BuildContext context) {
    final d = context.dominio;
    final vence = plan.vence;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Plan ${plan.nombre}', style: context.textos.titleLarge)),
                Chip(
                  label: Text(plan.vencido ? 'Vencido' : (plan.esGratis ? 'Gratis' : 'Activo')),
                  backgroundColor: plan.vencido ? d.advertenciaContenedor : d.exitoContenedor,
                  labelStyle: TextStyle(color: plan.vencido ? d.advertencia : d.exito, fontWeight: FontWeight.w700),
                  side: BorderSide.none,
                ),
              ],
            ),
            if (vence != null)
              Text(
                plan.vencido
                    ? 'Venció el ${vence.day}/${vence.month}/${vence.year}: la empresa opera con los límites del plan Gratis.'
                    : 'Vigente hasta el ${vence.day}/${vence.month}/${vence.year}',
                style: context.textos.bodySmall?.copyWith(color: plan.vencido ? d.advertencia : context.colores.onSurfaceVariant),
              ),
            const SizedBox(height: 16),
            for (final r in RecursoLimitado.values) ...[
              MedidorUso(recurso: r, uso: plan.de(r)),
              if (r != RecursoLimitado.values.last) const SizedBox(height: 16),
            ],
            const SizedBox(height: 16),
            Text(
              'Las personas incluyen a gerentes y a quienes solo marcan asistencia en Presente. '
              'Para ampliar tu plan, el director de la empresa puede solicitarlo al equipo de la plataforma.',
              style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
