import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

    Future<void> recargar() async {
      ref.invalidate(usuariosProvider);
      ref.invalidate(cambiosSedeProvider);
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
        onPressed: () => abrirFormularioEmpleado(context, ref),
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
                  texto: usuario.rol.etiqueta,
                  color: destacado ? context.dominio.info : context.colores.onSurfaceVariant,
                  fondo: destacado ? context.dominio.infoContenedor : context.colores.surfaceContainerHighest,
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
              ? 'Podrá volver a iniciar sesión.'
              : 'Se cerrará su sesión en todos sus teléfonos y no podrá volver a entrar hasta que lo '
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
                  u.rol.etiqueta,
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

class _FormularioUsuarioState extends ConsumerState<_FormularioUsuario> {
  final _formulario = GlobalKey<FormState>();
  late final _nombre = TextEditingController(text: widget.usuario?.nombre ?? '');
  late final _email = TextEditingController(text: widget.usuario?.email ?? '');
  late final _telefono = TextEditingController(text: widget.usuario?.telefono ?? '');
  final _password = TextEditingController();

  late RolUsuario _rol = widget.usuario?.rol ?? RolUsuario.vendedor;
  late Set<String> _sedes = {...?widget.usuario?.sedes.map((s) => s.uuid)};
  bool _ocultar = true;
  bool _guardando = false;

  bool get _esEdicion => widget.usuario != null;

  @override
  void dispose() {
    _nombre.dispose();
    _email.dispose();
    _telefono.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
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
      if (_esEdicion) {
        final antes = widget.usuario!;
        final cambiaronSedes = ({...antes.sedes.map((s) => s.uuid)}.length != sedes.length) ||
            !sedes.every((s) => antes.sedes.any((x) => x.uuid == s));
        final propio = antes.uuid == ref.read(sesionProvider).value?.usuarioUuid;
        final soyDirector = ref.read(sesionProvider).value?.rol.esDirector ?? false;
        // El gerente que se edita a sí mismo no puede tocar su rol ni sus
        // sedes (el servidor lo rechazaría): esos campos no viajan.
        final puedeTocarRol = !propio || soyDirector;
        await repo.actualizarUsuario(
          antes.uuid,
          nombre: _nombre.text.trim(),
          email: _email.text.trim(),
          rol: puedeTocarRol && _rol != antes.rol ? _rol : null,
          sedes: puedeTocarRol && (cambiaronSedes || _rol != antes.rol) ? sedes : null,
          password: _password.text.isEmpty ? null : _password.text,
        );
      } else {
        await repo.crearUsuario(
          nombre: _nombre.text.trim(),
          email: _email.text.trim(),
          password: _password.text,
          rol: _rol,
          telefono: _telefono.text.trim(),
          sedes: sedes,
        );
      }
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
    final sesion = ref.watch(sesionProvider).value;
    final soyDirector = sesion?.rol.esDirector ?? false;
    final propio = widget.usuario?.uuid == sesion?.usuarioUuid;
    final misSedes = ref.watch(misSedesProvider).value ?? const <Sede>[];
    // El gerente sólo da de alta vendedores y auxiliares: crear gerentes sería
    // repartir privilegios que no le corresponden.
    final rolesPosibles = soyDirector
        ? RolUsuario.values
        : const [RolUsuario.vendedor, RolUsuario.auxiliarInventario];
    final puedeTocarRol = (!propio || soyDirector) && rolesPosibles.contains(_rol);

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
                EncabezadoHoja(titulo: _esEdicion ? 'Editar empleado' : 'Nuevo empleado'),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _nombre,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Nombre *', prefixIcon: Icon(Icons.person_outline_rounded)),
                  validator: (v) => (v?.trim().length ?? 0) < 2 ? 'Escribe el nombre completo' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Correo *', prefixIcon: Icon(Icons.alternate_email_rounded)),
                  validator: (v) {
                    final texto = v?.trim() ?? '';
                    if (texto.isEmpty) return 'El correo es obligatorio';
                    if (!texto.contains('@') || !texto.contains('.')) return 'Correo no válido';
                    return null;
                  },
                ),
                if (!_esEdicion) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _telefono,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Teléfono', prefixIcon: Icon(Icons.phone_outlined)),
                  ),
                ],
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: _ocultar,
                  decoration: InputDecoration(
                    labelText: _esEdicion ? 'Nueva contraseña' : 'Contraseña *',
                    helperText: _esEdicion
                        ? 'Déjala vacía para no cambiarla. Cambiarla cierra sus sesiones.'
                        : 'Mínimo 8 caracteres',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _ocultar = !_ocultar),
                      icon: Icon(_ocultar ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    ),
                  ),
                  validator: (v) {
                    final texto = v ?? '';
                    if (_esEdicion && texto.isEmpty) return null;
                    return texto.length < 8 ? 'Mínimo 8 caracteres' : null;
                  },
                ),
                if (puedeTocarRol) ...[
                  const SizedBox(height: 20),
                  Text('Rol', style: context.textos.titleSmall),
                  const SizedBox(height: 4),
                  RadioGroup<RolUsuario>(
                    groupValue: _rol,
                    onChanged: (r) => setState(() {
                      _rol = r!;
                      // Pasar de gerente a vendedor deja varias sedes: se
                      // conserva sólo la primera.
                      if (_rol.esDeUnaSede && _sedes.length > 1) _sedes = {_sedes.first};
                    }),
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
                    const SizedBox(height: 12),
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
                            if (_rol == RolUsuario.gerente)
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
                        !_sedes.contains(widget.usuario!.sedes.first.uuid) && _rol.esDeUnaSede)
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
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _guardando ? null : _guardar,
                  icon: _guardando
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2))
                      : const Icon(Icons.check_rounded),
                  label: Text(_esEdicion ? 'Guardar cambios' : 'Crear empleado'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _descripcionRol(RolUsuario r) => switch (r) {
        RolUsuario.director => 'Ve y gestiona todas las sedes, el personal y los costos.',
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
