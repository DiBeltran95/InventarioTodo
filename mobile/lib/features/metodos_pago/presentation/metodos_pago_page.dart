import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/daos/metodos_pago_dao.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/widgets/estados.dart';
import '../../categorias/presentation/widgets/formulario_categoria.dart' show colorDesdeHex;
import 'widgets/formulario_metodo_pago.dart';

/// Medios de pago del negocio.
///
/// Aquí se registra con qué cobra esta tienda: Nequi, Daviplata, una llave
/// Bre-B, el datáfono… No hay lista fija porque no cabe en una: cada negocio
/// cobra por lo suyo.
///
/// Sólo el administrador entra, pero lo que configura aquí **lo usa el
/// vendedor** al cobrar, incluido el QR que le muestra al cliente.
class MetodosPagoPage extends ConsumerWidget {
  const MetodosPagoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metodos = ref.watch(metodosPagoTodosProvider);
    final permiteCredito = ref.watch(permiteCreditoProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Medios de pago')),
      body: metodos.when(
        loading: () => const SkeletonLista(),
        error: (e, _) => EstadoError(mensaje: '$e'),
        data: (lista) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          children: [
            _InterruptorFiado(activo: permiteCredito),
            const SizedBox(height: 16),

            if (lista.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 40),
                child: EstadoVacio(
                  icono: Icons.account_balance_wallet_outlined,
                  titulo: 'Sin medios de pago',
                  descripcion:
                      'Registra con qué cobras: efectivo, Nequi, datáfono… '
                      'Es lo que verá el vendedor al cerrar una venta.',
                ),
              )
            else
              for (var i = 0; i < lista.length; i++)
                EntradaEscalonada(
                  indice: i,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _FilaMetodo(
                      item: lista[i],
                      onEditar: () => abrirFormularioMetodo(context, metodo: lista[i].metodo),
                      onEliminar: () => _confirmarEliminar(context, ref, lista[i]),
                    ),
                  ),
                ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => abrirFormularioMetodo(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Añadir'),
      ),
    );
  }

  Future<void> _confirmarEliminar(
    BuildContext context,
    WidgetRef ref,
    MetodoPagoConUso item,
  ) async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('¿Eliminar el medio de pago?'),
        content: Text(
          item.cobros == 0
              ? 'Dejará de aparecer al cobrar.'
              // Se dice el número: el histórico conserva el nombre, así que
              // borrarlo no rompe nada, pero conviene saber que se usaba.
              : 'Dejará de aparecer al cobrar. Los ${item.cobros} pagos ya '
                  'registrados se conservan y seguirán mostrando su nombre en '
                  'los tickets y reportes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogo, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.dominio.peligro),
            onPressed: () => Navigator.pop(dialogo, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmado != true) return;
    await ref.read(metodosPagoDaoProvider).eliminar(item.uuid);
    ref.read(syncEngineProvider).solicitar();
    if (context.mounted) mostrarMensaje(context, 'Medio de pago eliminado');
  }
}

/// ¿Este negocio fía?
///
/// Es una decisión del negocio, no una preferencia de la app: fiar obliga a
/// llevar cuentas por cobrar. Mientras esté apagado, los medios de tipo
/// «Fiado» no aparecen al cobrar.
class _InterruptorFiado extends ConsumerWidget {
  const _InterruptorFiado({required this.activo});

  final bool activo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: SwitchListTile(
        value: activo,
        onChanged: (valor) async {
          // La configuración del negocio NO viaja por la cola de salida: la
          // escribe el administrador contra la API y baja a todos los
          // dispositivos en el pull. Por eso esto exige conexión.
          try {
            await ref.read(apiClientProvider).put(
              '/configuracion',
              cuerpo: {
                'valores': {'permite_credito': valor},
              },
            );
            await ref
                .read(syncDaoProvider)
                .guardarConfigLocal('permite_credito', '$valor');
            if (context.mounted) {
              mostrarMensaje(
                context,
                valor
                    ? 'El negocio ahora permite fiar'
                    : 'Fiado desactivado',
                esExito: true,
              );
            }
          } on ApiException catch (e) {
            if (context.mounted) {
              mostrarMensaje(
                context,
                e.esDeRed
                    ? 'Cambiar esta opción necesita conexión'
                    : e.mensajeUsuario,
                esError: true,
              );
            }
          }
        },
        secondary: const Icon(Icons.schedule_rounded),
        title: const Text('Permitir fiado'),
        subtitle: Text(
          activo
              ? 'Se puede dejar una venta como saldo pendiente del cliente'
              : 'Las ventas se cobran completas en el momento',
          style: context.textos.bodySmall,
        ),
      ),
    );
  }
}

class _FilaMetodo extends StatelessWidget {
  const _FilaMetodo({
    required this.item,
    required this.onEditar,
    required this.onEliminar,
  });

  final MetodoPagoConUso item;
  final VoidCallback onEditar;
  final VoidCallback onEliminar;

  @override
  Widget build(BuildContext context) {
    final m = item.metodo;
    final color = colorDesdeHex(m.color) ?? context.colores.primary;

    return Card(
      child: ListTile(
        onTap: onEditar,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.18),
          child: Icon(_icono(m.tipo), color: color, size: 20),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                m.nombre,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textos.titleSmall,
              ),
            ),
            if (!m.activo) ...[
              const SizedBox(width: 8),
              _Etiqueta(texto: 'Inactivo', color: context.dominio.peligro),
            ],
            if (m.tieneQr) ...[
              const SizedBox(width: 6),
              Icon(Icons.qr_code_2_rounded, size: 15, color: context.colores.primary),
            ],
          ],
        ),
        subtitle: Text(
          [
            _etiquetaTipo(m.tipo),
            if (m.requiereReferencia) 'pide referencia',
            if (item.cobros > 0) '${item.cobros} cobros',
          ].join(' · '),
          style: context.textos.bodySmall,
        ),
        trailing: IconButton(
          onPressed: onEliminar,
          icon: const Icon(Icons.delete_outline_rounded),
          tooltip: 'Eliminar',
        ),
      ),
    );
  }

  static String _etiquetaTipo(String tipo) =>
      MetodosPagoDao.tipos.firstWhere(
        (t) => t.codigo == tipo,
        orElse: () => (codigo: tipo, etiqueta: tipo, ayuda: ''),
      ).etiqueta;

  static IconData _icono(String tipo) => switch (tipo) {
        'EFECTIVO' => Icons.payments_outlined,
        'TARJETA' => Icons.credit_card_rounded,
        'TRANSFERENCIA' => Icons.smartphone_rounded,
        'CREDITO' => Icons.schedule_rounded,
        _ => Icons.account_balance_wallet_outlined,
      };
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta({required this.texto, required this.color});

  final String texto;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        texto,
        style: context.textos.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Abre el formulario de alta o edición.
Future<void> abrirFormularioMetodo(BuildContext context, {MetodoPago? metodo}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FormularioMetodoPago(metodo: metodo),
  );
}
