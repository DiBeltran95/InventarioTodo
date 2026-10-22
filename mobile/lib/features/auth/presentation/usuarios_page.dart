import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/config/app_config.dart';
import '../../../core/database/app_database.dart';
import '../../../core/negocio/jornada.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/utils/fechas.dart';
import '../../../core/widgets/encabezado_hoja.dart';
import '../../../core/widgets/estados.dart';
import '../../cuenta/domain/plan.dart';
import '../../cuenta/presentation/plan_ui.dart';
import '../../sedes/data/gestion_api.dart';
import '../../sedes/presentation/sedes_providers.dart';
import '../domain/sesion.dart';
import 'auth_providers.dart';

/// Empleados (director y gerentes).
///
/// **Exige conexión**, igual que antes. Si dos gestores crearan sin red la
/// misma cuenta en dos teléfonos quedarían dos usuarios con el mismo correo y
/// contraseñas distintas, y no hay forma razonable de resolverlo al
/// sincronizar. Lo mismo vale para inhabilitar: tiene que surtir efecto en el
/// servidor para que el empleado quede fuera de verdad.
///
/// El director ve a todos. El gerente, a los vendedores y auxiliares de sus
/// sedes (el servidor ya filtra la lista).
class UsuariosPage extends ConsumerWidget {
  const UsuariosPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usuarios = ref.watch(usuariosProvider);
    final cambios = ref.watch(cambiosSedeProvider).value ?? const <SolicitudCambioSede>[];
    final sesion = ref.watch(sesionProvider).value;
    final porResolver = cambios.where((c) => c.puedoResolver).toList();
    final plan = ref.watch(planProvider);

    Future<void> recargar() async {
      ref.invalidate(usuariosProvider);
      ref.invalidate(cambiosSedeProvider);
      ref.invalidate(empresaProvider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Empleados')),
      body: usuarios.when(
        loading: () => const SkeletonLista(),
        error: (e, _) => _Error(error: e, onReintentar: recargar),
        data: (lista) {
          final grupos = _agrupar(lista);
          var i = 0;
          return RefreshIndicator(
            onRefresh: recargar,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                const _AvisoEnLinea(),
                if (plan != null && !plan.personas.ilimitado) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: MedidorUso(recurso: RecursoLimitado.personas, uso: plan.personas),
                    ),
                  ),
                ],
                if (porResolver.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('Piden cambiar de sede', style: context.textos.titleMedium),
                  const SizedBox(height: 8),
                  for (final c in porResolver) _TarjetaCambio(solicitud: c, alResolver: recargar),
                ],
                for (final g in grupos.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                    child: Row(
                      children: [
                        Icon(
                          g.key == null ? Icons.workspace_premium_outlined : Icons.storefront_outlined,
                          size: 18,
                          color: context.colores.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(g.key ?? 'Dirección general', style: context.textos.titleMedium),
                        const SizedBox(width: 8),
                        Text('${g.value.length}', style: context.textos.bodySmall),
                      ],
                    ),
                  ),
                  for (final u in g.value)
                    EntradaEscalonada(
                      indice: i++,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _FilaUsuario(
                          usuario: u,
                          esUsuarioActual: u.uuid == sesion?.usuarioUuid,
                          onTap: () => _acciones(context, ref, u, esUsuarioActual: u.uuid == sesion?.usuarioUuid),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          if (await hayCupo(context, ref, RecursoLimitado.personas) && context.mounted) {
            await abrirFormularioEmpleado(context, ref);
          }
        },
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Nuevo empleado'),
      ),
    );
  }

  /// Agrupa por sede. El director va aparte («Dirección general»); un gerente
  /// con varias sedes aparece en cada una, porque responde por todas.
  static Map<String?, List<UsuarioAdmin>> _agrupar(List<UsuarioAdmin> lista) {
    final grupos = <String?, List<UsuarioAdmin>>{};
    for (final u in lista.where((u) => u.rol.esDirector)) {
      grupos.putIfAbsent(null, () => []).add(u);
    }
    final conSede = lista.where((u) => !u.rol.esDirector).toList();
    final nombres = {for (final u in conSede) ...u.sedes.map((s) => s.nombre)}.toList()..sort();
    for (final n in nombres) {
      grupos[n] = conSede.where((u) => u.sedes.any((s) => s.nombre == n)).toList()
        ..sort((a, b) {
          // Gerentes primero, luego por nombre.
          final r = (b.rol == RolUsuario.gerente ? 1 : 0) - (a.rol == RolUsuario.gerente ? 1 : 0);
          return r != 0 ? r : a.nombre.compareTo(b.nombre);
        });
    }
    final sinSede = conSede.where((u) => u.sedes.isEmpty).toList();
    if (sinSede.isNotEmpty) grupos['Sin sede asignada'] = sinSede;
    return grupos;
  }

  Future<void> _acciones(BuildContext context, WidgetRef ref, UsuarioAdmin u, {required bool esUsuarioActual}) async {
    final cambio = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _HojaEmpleado(usuario: u, esUsuarioActual: esUsuarioActual),
    );
    if (cambio == true) ref.invalidate(usuariosProvider);
  }
}

/// Abre el formulario de alta o edición. Devuelve true si se guardó.
Future<void> abrirFormularioEmpleado(BuildContext context, WidgetRef ref, {UsuarioAdmin? usuario}) async {
  final guardado = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FormularioUsuario(usuario: usuario),
  );
  if (guardado == true) ref.invalidate(usuariosProvider);
}

/// Su rol en Ventario.
String _etiquetaRol(UsuarioAdmin u) => u.rol.etiqueta;

/// Lista de cuentas. Es un `FutureProvider` y no un stream de Drift porque
/// estos datos viven en el servidor, no en la base local.
final usuariosProvider = FutureProvider.autoDispose<List<UsuarioAdmin>>(
  (ref) => ref.watch(authRepositoryProvider).listarUsuarios(),
);

/// Solicitudes de cambio de sede que le tocan a quien consulta.
final cambiosSedeProvider = FutureProvider.autoDispose<List<SolicitudCambioSede>>(
  (ref) => ref.watch(gestionApiProvider).cambiosDeSede(),
);

String _textoError(Object e) => e is ApiException ? e.mensajeUsuario : '$e';

// ─── Piezas ─────────────────────────────────────────────────────────────────

class _AvisoEnLinea extends StatelessWidget {
  const _AvisoEnLinea();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.dominio.infoContenedor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_rounded, size: 20, color: context.dominio.info),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Gestionar empleados requiere conexión: así, inhabilitar a alguien '
              'lo saca al instante de todos sus teléfonos.',
              style: context.textos.bodySmall?.copyWith(color: context.dominio.info),
            ),
          ),
        ],
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error({required this.error, required this.onReintentar});

  final Object error;
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) {
    final sinRed = error is ApiException && (error as ApiException).esDeRed;

    return EstadoVacio(
      icono: sinRed ? Icons.cloud_off_rounded : Icons.error_outline_rounded,
      titulo: sinRed ? 'Sin conexión' : 'No se pudieron cargar los empleados',
      descripcion: sinRed
          ? 'La gestión de empleados necesita conexión con el servidor. '
              'Vuelve a intentarlo cuando tengas red.'
          : _textoError(error),
      textoAccion: 'Reintentar',
      onAccion: onReintentar,
    );
  }
}

/// Estado de la jornada en pocas palabras, para la fila y la hoja.
({String texto, Color color, Color fondo, IconData icono})? _estadoJornada(BuildContext context, UsuarioAdmin u) {
  final d = context.dominio;
  if (!u.activo) {
    return (texto: 'Inhabilitado', color: d.peligro, fondo: d.peligroContenedor, icono: Icons.block_rounded);
  }
  final j = u.jornada;
  if (j == null || j.motivo == 'SIN_RESTRICCION') return null;
  return switch (j.motivo) {
    'EN_TURNO' => (
        texto: j.hasta == null ? 'En turno' : 'En turno hasta ${Fechas.formatHora(j.hasta!)}',
        color: d.exito,
        fondo: d.exitoContenedor,
        icono: Icons.schedule_rounded,
      ),
    'ACCESO_EXTRA' => (
        texto: 'Acceso extra hasta ${j.hasta == null ? '' : Fechas.formatHora(j.hasta!)}',
        color: d.advertencia,
        fondo: d.advertenciaContenedor,
        icono: Icons.more_time_rounded,
      ),
    _ => (
        texto: 'Fuera de turno',
        color: context.colores.onSurfaceVariant,
        fondo: context.colores.surfaceContainerHighest,
        icono: Icons.bedtime_outlined,
      ),
  };
}

class _FilaUsuario extends StatelessWidget {
  const _FilaUsuario({required this.usuario, required this.esUsuarioActual, required this.onTap});

  final UsuarioAdmin usuario;
  final bool esUsuarioActual;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final destacado = usuario.rol.esGestor;
    final estado = _estadoJornada(context, usuario);

    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: usuario.activo
              ? (destacado ? context.colores.primaryContainer : context.colores.secondaryContainer)
              : context.colores.surfaceContainerHighest,
          child: Text(
            usuario.iniciales,
            style: context.textos.titleSmall?.copyWith(
              color: usuario.activo
                  ? (destacado ? context.colores.onPrimaryContainer : context.colores.onSecondaryContainer)
                  : context.colores.onSurfaceVariant,
            ),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(usuario.nombre, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.textos.titleSmall),
            ),
            if (esUsuarioActual) ...[
              const SizedBox(width: 8),
              Text('(tú)', style: context.textos.labelSmall?.copyWith(color: context.colores.onSurfaceVariant)),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(usuario.email, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _Etiqueta(
                  texto: _etiquetaRol(usuario),
                  color: destacado ? context.dominio.info : context.colores.onSurfaceVariant,
                  fondo: destacado ? context.dominio.infoContenedor : context.colores.surfaceContainerHighest,
                ),
                if (usuario.conAccesoInventario && usuario.pausaInventario)
                  _Etiqueta(
                    texto: 'En pausa en Ventario',
                    color: context.dominio.advertencia,
                    fondo: context.dominio.advertenciaContenedor,
                    icono: Icons.pause_circle_outline_rounded,
                  ),
                if (estado != null) _Etiqueta(texto: estado.texto, color: estado.color, fondo: estado.fondo, icono: estado.icono),
              ],
            ),
          ],
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right_rounded),
      ),
    );
  }
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta({required this.texto, required this.color, required this.fondo, this.icono});

  final String texto;
  final Color color;
  final Color fondo;
  final IconData? icono;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icono != null) ...[Icon(icono, size: 12, color: color), const SizedBox(width: 4)],
          Text(texto, style: context.textos.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _TarjetaCambio extends ConsumerStatefulWidget {
  const _TarjetaCambio({required this.solicitud, required this.alResolver});

  final SolicitudCambioSede solicitud;
  final Future<void> Function() alResolver;

  @override
  ConsumerState<_TarjetaCambio> createState() => _TarjetaCambioState();
}

class _TarjetaCambioState extends ConsumerState<_TarjetaCambio> {
  bool _enviando = false;

  Future<void> _resolver(bool aceptar) async {
    setState(() => _enviando = true);
    try {
      await ref.read(gestionApiProvider).resolverCambioSede(widget.solicitud.uuid, aceptar: aceptar);
      // Las sedes del empleado viajan con su fila de usuario: que baje ya.
      ref.read(syncEngineProvider).solicitar();
      if (mounted) {
        mostrarMensaje(
          context,
          aceptar ? '${widget.solicitud.empleadoNombre} ya es de ${widget.solicitud.destino.nombre}' : 'Solicitud rechazada',
          esExito: aceptar,
        );
      }
      await widget.alResolver();
    } catch (e) {
      if (!mounted) return;
      setState(() => _enviando = false);
      mostrarMensaje(context, _textoError(e), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.solicitud;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.empleadoNombre, style: context.textos.titleSmall),
            const SizedBox(height: 2),
            Text('${s.origen?.nombre ?? 'Sin sede'}  →  ${s.destino.nombre}', style: context.textos.bodyMedium),
            if (s.motivo != null) Text('«${s.motivo}»', style: context.textos.bodySmall),
            Text(
              'Pedido ${Fechas.relativo(s.creada)}',
              style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: _enviando ? null : () => _resolver(false), child: const Text('Rechazar')),
                const SizedBox(width: 4),
                FilledButton.tonal(onPressed: _enviando ? null : () => _resolver(true), child: const Text('Aceptar')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Hoja de acciones de un empleado ────────────────────────────────────────

class _HojaEmpleado extends ConsumerStatefulWidget {
  const _HojaEmpleado({required this.usuario, required this.esUsuarioActual});

  final UsuarioAdmin usuario;
  final bool esUsuarioActual;

  @override
  ConsumerState<_HojaEmpleado> createState() => _HojaEmpleadoState();
}

class _HojaEmpleadoState extends ConsumerState<_HojaEmpleado> {
  bool _enviando = false;

  UsuarioAdmin get u => widget.usuario;

  Future<void> _ejecutar(Future<void> Function() accion, String ok) async {
    setState(() => _enviando = true);
    try {
      await accion();
      ref.read(syncEngineProvider).solicitar();
      if (!mounted) return;
      Navigator.pop(context, true);
      mostrarMensaje(context, ok, esExito: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enviando = false);
      // Reactivar a alguien vuelve a ocupar un cupo del plan.
      if (await manejarLimite(context, e)) return;
      if (!mounted) return;
      mostrarMensaje(context, _textoError(e), esError: true);
    }
  }

  Future<void> _cambiarHabilitacion() async {
    final habilitar = !u.activo;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(habilitar ? '¿Habilitar a ${u.nombre}?' : '¿Inhabilitar a ${u.nombre}?'),
        content: Text(
          habilitar
              ? 'Podrá volver a iniciar sesión en las apps de la empresa.'
              : 'Se cerrará su sesión en todos sus teléfonos, en Ventario y en Presente, y no podrá volver a entrar hasta que lo '
                  'habilites. Lo que haya vendido sin conexión se conserva y se sube con el siguiente '
                  'que entre en ese teléfono.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(
            style: habilitar ? null : FilledButton.styleFrom(backgroundColor: context.dominio.peligro),
            onPressed: () => Navigator.pop(d, true),
            child: Text(habilitar ? 'Habilitar' : 'Inhabilitar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _ejecutar(
      () => ref.read(authRepositoryProvider).actualizarUsuario(u.uuid, activo: habilitar),
      habilitar ? '${u.nombre} puede volver a entrar' : '${u.nombre} quedó inhabilitado',
    );
  }

  /// Pausar libera su cupo del plan de esa app; en la otra sigue igual.
  Future<void> _pausar(String aplicativo, bool pausada) async {
    final app = aplicativo == 'INVENTARIO' ? 'Ventario' : 'Presente';
    if (pausada) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('¿Pausar a ${u.nombre} en $app?'),
          content: Text(
            'No podrá entrar a $app y deja libre su cupo del plan de esa app. '
            'Conserva su cuenta y sus datos: puedes reactivarla cuando haya cupo.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Pausar')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _ejecutar(
      () async {
        await ref.read(authRepositoryProvider).pausarUsuario(u.uuid, aplicativo: aplicativo, pausada: pausada);
        ref.invalidate(empresaProvider);
      },
      pausada ? '${u.nombre} quedó en pausa en $app' : '${u.nombre} ya puede entrar a $app',
    );
  }

  Future<void> _darDeBaja() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('¿Dar de baja la cuenta?'),
        content: Text(
          '${u.nombre} desaparece de la lista y no podrá volver a entrar. Sus ventas y movimientos '
          'se conservan intactos. Si sólo quieres impedir que entre por un tiempo, inhabilítalo.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.dominio.peligro),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Dar de baja'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _ejecutar(() => ref.read(authRepositoryProvider).eliminarUsuario(u.uuid), 'Cuenta dada de baja');
  }

  Future<void> _abrir(Widget hoja) async {
    final guardado = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => hoja,
    );
    if (guardado == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final estado = _estadoJornada(context, u);
    final propio = widget.esUsuarioActual;
    final soyDirector = ref.watch(sesionProvider).value?.rol.esDirector ?? false;
    // Al gerente lo gestiona el director: él mismo sólo edita sus datos.
    final gestionable = !propio || soyDirector;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: EncabezadoHoja(
                titulo: u.nombre,
                subtitulo: [
                  _etiquetaRol(u),
                  if (u.sedes.isNotEmpty) u.sedes.map((s) => s.nombre).join(', '),
                ].join(' · '),
              ),
            ),
            if (estado != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _Etiqueta(texto: estado.texto, color: estado.color, fondo: estado.fondo, icono: estado.icono),
                ),
              ),
            if (u.restringirHorario && u.horario.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Text(
                  resumenHorario(u.horario),
                  style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 8),
            ListTile(
              enabled: !_enviando,
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Datos, rol y sede'),
              onTap: () => _abrir(_FormularioUsuario(usuario: u)),
            ),
            if (gestionable && !u.rol.esDirector) ...[
              ListTile(
                enabled: !_enviando,
                leading: const Icon(Icons.calendar_month_outlined),
                title: const Text('Horario de trabajo'),
                subtitle: Text(u.restringirHorario ? 'Sólo puede entrar en su horario' : 'Sin restricción de horario'),
                onTap: () => _abrir(_HojaHorario(usuario: u)),
              ),
              if (u.restringirHorario)
                ListTile(
                  enabled: !_enviando,
                  leading: const Icon(Icons.more_time_rounded),
                  title: Text(u.conAccesoExtra ? 'Ampliar acceso extra' : 'Dar acceso extra'),
                  subtitle: Text(
                    u.conAccesoExtra
                        ? 'Puede entrar hasta ${Fechas.formatFechaHora(u.accesoExtraHasta!)}'
                        : 'Para que entre fuera de su horario',
                  ),
                  onTap: () => _abrir(_HojaAccesoExtra(usuario: u)),
                ),
              if (u.conAccesoExtra)
                ListTile(
                  enabled: !_enviando,
                  leading: const Icon(Icons.timer_off_outlined),
                  title: const Text('Quitar acceso extra'),
                  onTap: () => _ejecutar(
                    () => ref.read(authRepositoryProvider).revocarAccesoExtra(u.uuid),
                    'Acceso extra retirado',
                  ),
                ),
            ],
            if (!propio && u.activo && !u.rol.esDirector && u.conAccesoInventario)
              ListTile(
                enabled: !_enviando,
                leading: Icon(u.pausaInventario ? Icons.play_circle_outline_rounded : Icons.pause_circle_outline_rounded),
                title: Text(u.pausaInventario ? 'Reactivar en Ventario' : 'Pausar en Ventario'),
                subtitle: const Text('Cuando el plan no alcanza para todos'),
                onTap: () => _pausar('INVENTARIO', !u.pausaInventario),
              ),
            if (!propio) ...[
              ListTile(
                enabled: !_enviando,
                leading: Icon(
                  u.activo ? Icons.person_off_outlined : Icons.how_to_reg_outlined,
                  color: u.activo ? context.dominio.peligro : context.dominio.exito,
                ),
                title: Text(u.activo ? 'Inhabilitar' : 'Habilitar'),
                subtitle: Text(u.activo ? 'Cierra su sesión y no lo deja entrar' : 'Le permite volver a entrar'),
                onTap: _cambiarHabilitacion,
              ),
              ListTile(
                enabled: !_enviando,
                leading: Icon(Icons.delete_outline_rounded, color: context.dominio.peligro),
                title: const Text('Dar de baja'),
                onTap: _darDeBaja,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const _dias = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];

/// «Lun–Vie 08:00–17:00 · Sáb 08:00–12:00».
String resumenHorario(List<TramoHorario> tramos) {
  final porDia = <int, String>{};
  for (var d = 1; d <= 7; d++) {
    final t = tramos.where((x) => x.dia == d).map((x) => '${x.inicio}–${x.fin}').join(', ');
    if (t.isNotEmpty) porDia[d] = t;
  }
  final partes = <String>[];
  var d = 1;
  while (d <= 7) {
    if (!porDia.containsKey(d)) {
      d++;
      continue;
    }
    var fin = d;
    while (fin + 1 <= 7 && porDia[fin + 1] == porDia[d]) {
      fin++;
    }
    partes.add('${fin == d ? _dias[d - 1] : '${_dias[d - 1]}–${_dias[fin - 1]}'} ${porDia[d]}');
    d = fin + 1;
  }
  return partes.join(' · ');
}

// ─── Formulario de datos, rol y sedes ───────────────────────────────────────

class _FormularioUsuario extends ConsumerStatefulWidget {
  const _FormularioUsuario({this.usuario});

  final UsuarioAdmin? usuario;

  @override
  ConsumerState<_FormularioUsuario> createState() => _FormularioUsuarioState();
}

/// Alta o edición del acceso a Ventario de un empleado.
///
/// El empleado es uno solo para las dos apps: lo normal es ELEGIRLO de los ya
/// registrados (en Presente o aquí) y solo darle su rol de Ventario. Si es
/// nuevo, se escriben sus datos una vez y aparecerá también en Presente (allá
/// solo falta registrar su rostro). La contraseña no se escribe: se genera al
/// azar y la persona crea la suya con «¿Olvidaste tu contraseña?».
class _FormularioUsuarioState extends ConsumerState<_FormularioUsuario> {
  final _formulario = GlobalKey<FormState>();
  late final _nombre = TextEditingController(text: widget.usuario?.nombre ?? '');
  late final _email = TextEditingController(text: widget.usuario?.email ?? '');
  late final _telefono = TextEditingController(text: widget.usuario?.telefono ?? '');
  late final _documento = TextEditingController(text: widget.usuario?.documento ?? '');
  final _password = TextEditingController();
  final _buscar = TextEditingController();

  late RolUsuario _rol = widget.usuario?.rol ?? RolUsuario.vendedor;
  late Set<String> _sedes = {...?widget.usuario?.sedes.map((s) => s.uuid)};
  bool _ocultar = true;
  bool _guardando = false;

  /// Alta: elegir un empleado ya registrado (true) o registrar uno nuevo.
  bool _registrado = true;
  EmpleadoRegistrado? _elegido;
  late Future<List<EmpleadoRegistrado>> _candidatos = _cargarCandidatos();

  bool get _esEdicion => widget.usuario != null;

  /// Identidad de ESTA alta: si la respuesta se pierde y se reintenta, el
  /// servidor reconoce que ya la creó en vez de crear otra.
  final String _uuidAlta = const Uuid().v4();

  /// Ya entra a Presente: usa su misma cuenta, no se le pide correo.
  bool get _usaCuentaExistente => !_esEdicion && (_elegido?.conCuenta ?? false);

  Future<List<EmpleadoRegistrado>> _cargarCandidatos() =>
      ref.read(authRepositoryProvider).empleadosSinAcceso(q: _buscar.text.trim());

  @override
  void dispose() {
    for (final c in [_nombre, _email, _telefono, _documento, _password, _buscar]) {
      c.dispose();
    }
    super.dispose();
  }

  void _elegirRol(RolUsuario r) => setState(() {
        _rol = r;
        if (r.esDirector) _sedes = {};
        // Pasar de gerente a vendedor deja varias sedes: se conserva la primera.
        if (r.esDeUnaSede && _sedes.length > 1) _sedes = {_sedes.first};
      });

  void _elegir(EmpleadoRegistrado e, List<Sede> misSedes) => setState(() {
        _elegido = e;
        _nombre.text = e.nombre;
        _documento.text = e.documento;
        _telefono.text = e.telefono ?? '';
        _email.text = e.email ?? '';
        // Su sede de siempre, si la gestiono.
        if (!_rol.esDirector && misSedes.any((s) => s.uuid == e.sedeUuid)) _sedes = {e.sedeUuid};
      });

  Future<void> _guardar() async {
    // Un segundo toque mientras guarda no envía otra alta.
    if (_guardando) return;
    if (!_esEdicion && _registrado && _elegido == null) {
      mostrarMensaje(context, 'Elige el empleado al que le das acceso', esError: true);
      return;
    }
    if (!(_formulario.currentState?.validate() ?? false)) return;
    if (_rol.esDeUnaSede && _sedes.length != 1) {
      mostrarMensaje(context, 'Elige la sede donde trabaja', esError: true);
      return;
    }
    if (_rol == RolUsuario.gerente && _sedes.isEmpty) {
      mostrarMensaje(context, 'Elige al menos una sede para el gerente', esError: true);
      return;
    }
    setState(() => _guardando = true);

    final sedes = _rol.esDirector ? <String>[] : _sedes.toList();
    try {
      final repo = ref.read(authRepositoryProvider);
      var mensaje = 'Cambios guardados';
      if (_esEdicion) {
        final antes = widget.usuario!;
        final cambiaronSedes = ({...antes.sedes.map((s) => s.uuid)}.length != sedes.length) ||
            !sedes.every((s) => antes.sedes.any((x) => x.uuid == s));
        final propio = antes.uuid == ref.read(sesionProvider).value?.usuarioUuid;
        final soyDirector = ref.read(sesionProvider).value?.rol.esDirector ?? false;
        // El gerente que se edita a sí mismo no puede tocar su rol ni sus
        // sedes (el servidor lo rechazaría): esos campos no viajan.
        final puedeTocarRol = !propio || soyDirector;
        final cambiaRol = puedeTocarRol && _rol != antes.rol;
        String? cambio(TextEditingController c, String? antes) => c.text.trim() == (antes ?? '') ? null : c.text.trim();
        await repo.actualizarUsuario(
          antes.uuid,
          nombre: cambio(_nombre, antes.nombre),
          email: cambio(_email, antes.email),
          documento: cambio(_documento, antes.documento),
          telefono: cambio(_telefono, antes.telefono),
          rol: cambiaRol ? _rol : null,
          sedes: puedeTocarRol && (cambiaronSedes || cambiaRol) ? sedes : null,
          password: _password.text.isEmpty ? null : _password.text,
        );
      } else {
        final r = await repo.crearUsuario(
          uuid: _uuidAlta,
          nombre: _nombre.text.trim(),
          email: _email.text.trim().toLowerCase(),
          documento: _documento.text.trim(),
          telefono: _telefono.text.trim(),
          rol: _rol,
          sedes: sedes,
        );
        mensaje = r.cuentaExistente
            ? '${_nombre.text.trim()} ya entra a Ventario con su misma cuenta'
            : r.avisoEnviado
                ? 'Listo: le enviamos un correo para que cree su contraseña'
                : 'Acceso creado: que entre con «¿Olvidaste tu contraseña?» para crear la suya';
      }
      ref.read(syncEngineProvider).solicitar();
      // El cupo de personas cambió: que los medidores lo reflejen.
      ref.invalidate(empresaProvider);
      if (!mounted) return;
      mostrarMensaje(context, mensaje, esExito: true);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      if (await manejarLimite(context, e)) return;
      if (!mounted) return;
      mostrarMensaje(context, _textoError(e), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sesion = ref.watch(sesionProvider).value;
    final soyDirector = sesion?.rol.esDirector ?? false;
    final propio = widget.usuario?.uuid == sesion?.usuarioUuid;
    final misSedes = ref.watch(misSedesProvider).value ?? const <Sede>[];
    // El gerente sólo da acceso de vendedor o auxiliar: crear gerentes sería
    // repartir privilegios que no le corresponden.
    final rolesPosibles = soyDirector ? RolUsuario.values : const [RolUsuario.vendedor, RolUsuario.auxiliarInventario];
    final puedeTocarRol = (!propio || soyDirector) && rolesPosibles.contains(_rol);
    final sedeUnica = _rol.esDeUnaSede;
    final muestraDatos = _esEdicion || !_registrado || _elegido != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Form(
            key: _formulario,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EncabezadoHoja(
                  titulo: _esEdicion ? 'Editar empleado' : 'Dar acceso a Ventario',
                  subtitulo: _esEdicion ? null : 'Elige un empleado ya registrado o registra uno nuevo',
                ),
                if (!_esEdicion) ...[
                  const SizedBox(height: 16),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, icon: Icon(Icons.badge_outlined), label: Text('Ya registrado')),
                      ButtonSegment(value: false, icon: Icon(Icons.person_add_alt_1_outlined), label: Text('Nuevo')),
                    ],
                    selected: {_registrado},
                    onSelectionChanged: (v) => setState(() {
                      _registrado = v.first;
                      _elegido = null;
                      for (final c in [_nombre, _email, _telefono, _documento]) {
                        c.clear();
                      }
                    }),
                  ),
                ],
                if (!_esEdicion && _registrado && _elegido == null) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _buscar,
                    decoration: const InputDecoration(
                      hintText: 'Buscar por nombre o documento',
                      prefixIcon: Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() => _candidatos = _cargarCandidatos()),
                  ),
                  const SizedBox(height: 8),
                  FutureBuilder<List<EmpleadoRegistrado>>(
                    future: _candidatos,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Text(_textoError(snap.error!), style: TextStyle(color: context.dominio.peligro));
                      }
                      final lista = snap.data;
                      if (lista == null) {
                        return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
                      }
                      if (lista.isEmpty) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'No hay empleados registrados sin acceso a Ventario. Usa «Nuevo» para registrarlo.',
                            style: context.textos.bodyMedium?.copyWith(color: context.colores.onSurfaceVariant),
                          ),
                        );
                      }
                      return Column(
                        children: [
                          for (final e in lista.take(30))
                            Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: const Icon(Icons.person_outline_rounded),
                                title: Text(e.nombre),
                                subtitle: Text([e.documento, e.sedeNombre].join(' · ')),
                                trailing: const Icon(Icons.chevron_right_rounded),
                                onTap: () => _elegir(e, misSedes),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
                if (_elegido != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(_elegido!.nombre),
                      subtitle: Text([_elegido!.documento, _elegido!.sedeNombre].join(' · ')),
                      trailing: TextButton(onPressed: () => setState(() => _elegido = null), child: const Text('Cambiar')),
                    ),
                  ),
                  if (_usaCuentaExistente)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Ya entra a Presente: usará el mismo correo y contraseña.',
                        style: context.textos.bodySmall?.copyWith(color: context.dominio.exito),
                      ),
                    ),
                ],
                if (muestraDatos && _elegido == null) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _nombre,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Nombre *', prefixIcon: Icon(Icons.person_outline_rounded)),
                    validator: (v) => (v?.trim().length ?? 0) < 2 ? 'Escribe el nombre completo' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _documento,
                    decoration: const InputDecoration(
                      labelText: 'Documento *',
                      helperText: 'Cédula u otro documento: lo identifica en las dos apps',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    validator: (v) =>
                        RegExp(r'^[A-Za-z0-9.-]{3,20}$').hasMatch(v?.trim() ?? '') ? null : 'De 3 a 20 letras o números',
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _telefono,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Teléfono', prefixIcon: Icon(Icons.phone_outlined)),
                  ),
                ],
                if (muestraDatos && !_usaCuentaExistente) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Correo *',
                      helperText: _esEdicion
                          ? 'Con él entra a las apps de la empresa'
                          : 'Con él entra. Le llegará un aviso para crear su contraseña.',
                      helperMaxLines: 2,
                      prefixIcon: const Icon(Icons.alternate_email_rounded),
                    ),
                    validator: (v) {
                      final texto = v?.trim() ?? '';
                      if (texto.isEmpty) return 'El correo es obligatorio';
                      if (!texto.contains('@') || !texto.contains('.')) return 'Correo no válido';
                      return null;
                    },
                  ),
                ],
                if (_esEdicion) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: _ocultar,
                    decoration: InputDecoration(
                      labelText: 'Nueva contraseña',
                      helperText: 'Déjala vacía para no cambiarla. Cambiarla cierra sus sesiones.',
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        tooltip: _ocultar ? 'Mostrar contraseña' : 'Ocultar contraseña',
                        onPressed: () => setState(() => _ocultar = !_ocultar),
                        icon: Icon(_ocultar ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      ),
                    ),
                    validator: (v) {
                      final texto = v ?? '';
                      return texto.isEmpty || texto.length >= 8 ? null : 'Mínimo 8 caracteres';
                    },
                  ),
                ],
                if (puedeTocarRol && muestraDatos) ...[
                  const SizedBox(height: 20),
                  Text('Rol en Ventario', style: context.textos.titleSmall),
                  const SizedBox(height: 4),
                  RadioGroup<RolUsuario>(
                    groupValue: _rol,
                    onChanged: (r) {
                      if (r != null) _elegirRol(r);
                    },
                    child: Column(
                      children: [
                        for (final r in rolesPosibles)
                          RadioListTile<RolUsuario>(
                            value: r,
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(r.etiqueta),
                            subtitle: Text(_descripcionRol(r)),
                          ),
                      ],
                    ),
                  ),
                  if (!_rol.esDirector) ...[
                    const SizedBox(height: 16),
                    Text(
                      _rol == RolUsuario.gerente ? 'Sedes que gestiona' : 'Sede donde trabaja',
                      style: context.textos.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    if (misSedes.isEmpty)
                      Text('Aún no hay sedes en este teléfono. Sincroniza e inténtalo de nuevo.',
                          style: context.textos.bodySmall)
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final s in misSedes)
                            if (!sedeUnica)
                              FilterChip(
                                label: Text(s.nombre),
                                selected: _sedes.contains(s.uuid),
                                onSelected: (v) => setState(() => v ? _sedes.add(s.uuid) : _sedes.remove(s.uuid)),
                              )
                            else
                              ChoiceChip(
                                label: Text(s.nombre),
                                selected: _sedes.contains(s.uuid),
                                onSelected: (_) => setState(() => _sedes = {s.uuid}),
                              ),
                        ],
                      ),
                    if (_esEdicion && _sedes.isNotEmpty && widget.usuario!.sedes.isNotEmpty &&
                        !_sedes.contains(widget.usuario!.sedes.first.uuid) && sedeUnica)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Al cambiarlo de sede deja de ver las ventas y el inventario de la anterior. '
                          'Si tiene una caja abierta, debe cerrarla primero.',
                          style: context.textos.bodySmall?.copyWith(color: context.dominio.advertencia),
                        ),
                      ),
                  ],
                ],
                if (muestraDatos) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _guardando ? null : _guardar,
                    icon: _guardando
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2))
                        : const Icon(Icons.check_rounded),
                    label: Text(_esEdicion ? 'Guardar cambios' : 'Dar acceso'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _descripcionRol(RolUsuario r) => switch (r) {
        RolUsuario.director => 'Ve y gestiona todas las sedes, el personal y los costos. También administra Presente.',
        RolUsuario.gerente => 'Gestiona catálogo, stock y personal de sus sedes; aprueba traslados y ajustes.',
        RolUsuario.auxiliarInventario => 'Registra entradas; sus conteos y mermas los aprueba el gerente. No vende.',
        RolUsuario.vendedor => 'Vende y consulta. No ve costos ni edita el catálogo.',
      };
}

// ─── Horario ────────────────────────────────────────────────────────────────

class _HojaHorario extends ConsumerStatefulWidget {
  const _HojaHorario({required this.usuario});

  final UsuarioAdmin usuario;

  @override
  ConsumerState<_HojaHorario> createState() => _HojaHorarioState();
}

class _HojaHorarioState extends ConsumerState<_HojaHorario> {
  late bool _restringir = widget.usuario.restringirHorario;
  late final List<TramoHorario> _tramos = [...widget.usuario.horario];
  bool _guardando = false;

  static String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static TimeOfDay _desde(String hhmm) {
    final p = hhmm.split(':');
    return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
  }

  Future<void> _agregar(int dia) async {
    final previo = _tramos.where((t) => t.dia == dia).lastOrNull;
    final inicio = await showTimePicker(
      context: context,
      helpText: 'Entrada (${_dias[dia - 1]})',
      initialTime: previo == null ? const TimeOfDay(hour: 8, minute: 0) : _desde(previo.fin),
    );
    if (inicio == null || !mounted) return;
    final fin = await showTimePicker(
      context: context,
      helpText: 'Salida (${_dias[dia - 1]})',
      initialTime: TimeOfDay(hour: (inicio.hour + 8) % 24, minute: inicio.minute),
    );
    if (fin == null) return;
    final tramo = TramoHorario(dia: dia, inicio: _hhmm(inicio), fin: _hhmm(fin));
    if (!tramo.esValido) {
      if (mounted) mostrarMensaje(context, 'La entrada y la salida no pueden ser iguales', esError: true);
      return;
    }
    setState(() => _tramos.add(tramo));
  }

  void _copiar(int dia, List<int> destinos) {
    final base = _tramos.where((t) => t.dia == dia).toList();
    setState(() {
      _tramos.removeWhere((t) => destinos.contains(t.dia) && t.dia != dia);
      for (final d in destinos.where((d) => d != dia)) {
        _tramos.addAll(base.map((t) => TramoHorario(dia: d, inicio: t.inicio, fin: t.fin)));
      }
    });
  }

  Future<void> _guardar() async {
    if (_restringir && _tramos.isEmpty) {
      mostrarMensaje(context, 'Agrega al menos un tramo: sin tramos no podría entrar nunca', esError: true);
      return;
    }
    setState(() => _guardando = true);
    try {
      await ref.read(authRepositoryProvider).actualizarUsuario(
            widget.usuario.uuid,
            restringirHorario: _restringir,
            horario: _tramos,
          );
      ref.read(syncEngineProvider).solicitar();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, _textoError(e), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            EncabezadoHoja(titulo: 'Horario de trabajo', subtitulo: widget.usuario.nombre),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _restringir,
              onChanged: (v) => setState(() => _restringir = v),
              title: const Text('Sólo puede entrar en su horario'),
              subtitle: Text(
                _restringir
                    ? 'Fuera de estos tramos se le cierra la sesión (con aviso 15 min antes) y no puede entrar.'
                    : 'Puede entrar a cualquier hora. El horario queda guardado como referencia.',
                style: context.textos.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            for (var dia = 1; dia <= 7; dia++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: 40, child: Text(_dias[dia - 1], style: context.textos.titleSmall)),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in _tramos.where((t) => t.dia == dia))
                            InputChip(
                              label: Text('${t.inicio}–${t.fin}${t.nocturno ? ' (+1)' : ''}'),
                              onDeleted: () => setState(() => _tramos.remove(t)),
                            ),
                          ActionChip(
                            avatar: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('Tramo'),
                            onPressed: () => _agregar(dia),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<List<int>>(
                      tooltip: 'Copiar a otros días',
                      icon: const Icon(Icons.content_copy_rounded, size: 18),
                      enabled: _tramos.any((t) => t.dia == dia),
                      onSelected: (destinos) => _copiar(dia, destinos),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: [1, 2, 3, 4, 5], child: Text('Copiar a lunes–viernes')),
                        PopupMenuItem(value: [1, 2, 3, 4, 5, 6], child: Text('Copiar a lunes–sábado')),
                        PopupMenuItem(value: [1, 2, 3, 4, 5, 6, 7], child: Text('Copiar a todos los días')),
                      ],
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Un tramo cuya salida es anterior a la entrada termina al día siguiente (turno de noche). '
              'Horas en la zona del negocio.',
              style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _guardando ? null : _guardar,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Guardar horario'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Acceso extra ───────────────────────────────────────────────────────────

class _HojaAccesoExtra extends ConsumerStatefulWidget {
  const _HojaAccesoExtra({required this.usuario});

  final UsuarioAdmin usuario;

  @override
  ConsumerState<_HojaAccesoExtra> createState() => _HojaAccesoExtraState();
}

class _HojaAccesoExtraState extends ConsumerState<_HojaAccesoExtra> {
  /// Minutos; -1 = hasta el final del día del negocio.
  int _opcion = 60;
  final _motivo = TextEditingController();
  bool _guardando = false;

  @override
  void dispose() {
    _motivo.dispose();
    super.dispose();
  }

  DateTime get _hasta {
    final ahora = DateTime.now().toUtc();
    if (_opcion > 0) return ahora.add(Duration(minutes: _opcion));
    // 23:59 de hoy en la hora del negocio.
    final local = ahora.add(AppConfig.desfaseNegocio);
    return DateTime.utc(local.year, local.month, local.day, 23, 59).subtract(AppConfig.desfaseNegocio);
  }

  Future<void> _guardar() async {
    final hasta = _hasta;
    if (!hasta.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 4)))) {
      mostrarMensaje(context, 'El día ya casi termina: elige una cantidad de horas', esError: true);
      return;
    }
    setState(() => _guardando = true);
    try {
      await ref.read(authRepositoryProvider).otorgarAccesoExtra(
            widget.usuario.uuid,
            hasta: hasta,
            motivo: _motivo.text.trim(),
          );
      ref.read(syncEngineProvider).solicitar();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarMensaje(context, _textoError(e), esError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              EncabezadoHoja(titulo: 'Acceso extra', subtitulo: widget.usuario.nombre),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (valor, texto) in const [(60, '1 hora'), (120, '2 horas'), (240, '4 horas'), (-1, 'Hasta el fin del día')])
                    ChoiceChip(
                      label: Text(texto),
                      selected: _opcion == valor,
                      onSelected: (_) => setState(() => _opcion = valor),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Podrá entrar hasta ${Fechas.formatFechaHora(_hasta)}.',
                style: context.textos.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _motivo,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Motivo', hintText: 'Ej.: inventario de fin de mes'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _guardando ? null : _guardar,
                icon: const Icon(Icons.more_time_rounded),
                label: const Text('Dar acceso'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
