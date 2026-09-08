import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/database/daos/metodos_pago_dao.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/encabezado_hoja.dart';
import '../../../../core/widgets/estados.dart';
import '../../../categorias/presentation/widgets/formulario_categoria.dart' show colorDesdeHex;
import '../../data/imagen_qr.dart';

/// Alta y edición de un medio de pago.
///
/// El **nombre** es libre porque es el del negocio («Nequi», «Llave Bre-B»); el
/// **tipo** está acotado porque decide qué hace la pantalla de cobro: sólo
/// EFECTIVO calcula vueltas, sólo CREDITO deja saldo pendiente, y el QR sólo
/// tiene sentido en los que se pagan desde el banco del cliente.
class FormularioMetodoPago extends ConsumerStatefulWidget {
  const FormularioMetodoPago({super.key, this.metodo});

  final MetodoPago? metodo;

  @override
  ConsumerState<FormularioMetodoPago> createState() => _FormularioMetodoPagoState();
}

class _FormularioMetodoPagoState extends ConsumerState<FormularioMetodoPago> {
  final _formulario = GlobalKey<FormState>();
  late final _nombre = TextEditingController(text: widget.metodo?.nombre ?? '');
  late final _instrucciones =
      TextEditingController(text: widget.metodo?.instrucciones ?? '');

  late String _tipo = widget.metodo?.tipo ?? 'TRANSFERENCIA';
  late String _color = widget.metodo?.color ?? MetodosPagoDao.paleta.first;
  late bool _requiereReferencia = widget.metodo?.requiereReferencia ?? false;
  late bool _activo = widget.metodo?.activo ?? true;
  late String? _qrLocal = widget.metodo?.qrLocal;

  bool _guardando = false;

  bool get _esEdicion => widget.metodo != null;

  /// El QR sólo tiene sentido donde el cliente paga desde su propio banco.
  bool get _admiteQr => _tipo == 'TRANSFERENCIA' || _tipo == 'OTRO';

  @override
  void dispose() {
    _nombre.dispose();
    _instrucciones.dispose();
    super.dispose();
  }

  Future<void> _elegirQr() async {
    try {
      final imagen = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // El QR llega como captura de pantalla del banco. Se reduce aquí: un
        // PNG de 12 MP para mostrarlo a 260 px no aporta y sí llena memoria.
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 90,
      );
      if (imagen == null || !mounted) return;
      setState(() => _qrLocal = imagen.path);
    } catch (e) {
      if (mounted) mostrarMensaje(context, 'No se pudo abrir la galería: $e', esError: true);
    }
  }

  Future<void> _guardar() async {
    if (!(_formulario.currentState?.validate() ?? false)) return;

    final dao = ref.read(metodosPagoDaoProvider);
    final nombre = _nombre.text.trim();

    // Dos «Nequi» en la lista de cobro son indistinguibles y parten el reporte
    // de ingresos en dos filas.
    final repetido = await dao.porNombre(nombre, exceptoUuid: widget.metodo?.uuid);
    if (repetido != null) {
      if (mounted) {
        mostrarMensaje(context, 'Ya existe un medio llamado «${repetido.nombre}»',
            esError: true);
      }
      return;
    }

    if (!mounted) return;
    setState(() => _guardando = true);

    try {
      final uuid = widget.metodo?.uuid;

      // La imagen se copia a un sitio estable ANTES de guardar: `image_picker`
      // entrega rutas del caché temporal, que el sistema borra cuando quiere.
      String? qr = _qrLocal;
      if (qr != null && qr != widget.metodo?.qrLocal) {
        qr = await ImagenQr.persistir(qr, uuid ?? nombre) ?? qr;
      }

      if (_esEdicion) {
        await dao.actualizar(
          uuid!,
          nombre: nombre,
          tipo: _tipo,
          color: _color,
          requiereReferencia: _requiereReferencia,
          instrucciones: _instrucciones.text,
          qrLocal: _admiteQr ? qr : null,
          activo: _activo,
        );
      } else {
        await dao.crear(
          nombre: nombre,
          tipo: _tipo,
          color: _color,
          requiereReferencia: _requiereReferencia,
          instrucciones: _instrucciones.text,
          qrLocal: _admiteQr ? qr : null,
        );
      }

      // El QR lo sube el motor de sincronización cuando haya red, igual que las
      // fotos de producto: sin eso viviría sólo en este teléfono y el vendedor
      // no podría mostrarlo desde el suyo.
      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();

      if (!mounted) return;
      Navigator.pop(context);
      mostrarMensaje(
        context,
        _esEdicion ? 'Medio de pago actualizado' : 'Medio de pago añadido',
        esExito: true,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        mostrarMensaje(context, 'No se pudo guardar: $e', esError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  titulo: _esEdicion ? 'Editar medio de pago' : 'Nuevo medio de pago',
                  subtitulo: 'Con qué cobra tu negocio',
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _nombre,
                  autofocus: !_esEdicion,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nombre *',
                    hintText: 'Nequi, Daviplata, Datáfono…',
                    helperText: 'Es lo que verá el vendedor al cobrar',
                    prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                  ),
                  validator: (v) =>
                      (v?.trim().length ?? 0) < 2 ? 'Escribe el nombre' : null,
                ),
                const SizedBox(height: 20),

                Text('¿Cómo se comporta al cobrar?', style: context.textos.titleSmall),
                const SizedBox(height: 8),
                RadioGroup<String>(
                  groupValue: _tipo,
                  onChanged: (v) => setState(() => _tipo = v ?? _tipo),
                  child: Column(
                    children: [
                      for (final t in MetodosPagoDao.tipos)
                        RadioListTile<String>(
                          value: t.codigo,
                          title: Text(t.etiqueta),
                          subtitle: Text(t.ayuda, style: context.textos.bodySmall),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                        ),
                    ],
                  ),
                ),

                if (_admiteQr) ...[
                  const SizedBox(height: 12),
                  _SelectorQr(
                    ruta: _qrLocal,
                    urlSubida: widget.metodo?.qrUrl,
                    onElegir: _elegirQr,
                    onQuitar: _qrLocal == null ? null : () => setState(() => _qrLocal = null),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _instrucciones,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Texto bajo el QR',
                      hintText: 'Nequi 300 123 4567',
                      helperText: 'Por si el cliente prefiere teclear el número',
                    ),
                  ),
                ],

                const SizedBox(height: 8),
                SwitchListTile(
                  value: _requiereReferencia,
                  onChanged: (v) => setState(() => _requiereReferencia = v),
                  title: const Text('Pedir referencia al cobrar'),
                  subtitle: Text(
                    'Número de aprobación del datáfono o de la transferencia. '
                    'Es lo que permite cuadrar la caja contra el extracto.',
                    style: context.textos.bodySmall,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),

                if (_esEdicion)
                  SwitchListTile(
                    value: _activo,
                    onChanged: (v) => setState(() => _activo = v),
                    title: const Text('Disponible al cobrar'),
                    subtitle: Text(
                      _activo ? 'Aparece en la pantalla de cobro' : 'Oculto para el vendedor',
                      style: context.textos.bodySmall,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),

                const SizedBox(height: 16),
                Text('Color', style: context.textos.titleSmall),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final hex in MetodosPagoDao.paleta)
                      _Muestra(
                        hex: hex,
                        elegido: _color.toUpperCase() == hex.toUpperCase(),
                        onTap: () => setState(() => _color = hex),
                      ),
                  ],
                ),

                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _guardando ? null : _guardar,
                  icon: _guardando
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_esEdicion ? 'Guardar cambios' : 'Añadir medio'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(54)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Selector del QR que se le mostrará al cliente.
class _SelectorQr extends StatelessWidget {
  const _SelectorQr({
    required this.ruta,
    required this.urlSubida,
    required this.onElegir,
    this.onQuitar,
  });

  final String? ruta;
  final String? urlSubida;
  final VoidCallback onElegir;
  final VoidCallback? onQuitar;

  @override
  Widget build(BuildContext context) {
    final hayLocal = ruta != null && ruta!.isNotEmpty && File(ruta!).existsSync();
    final hayRemoto = urlSubida != null && urlSubida!.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            GestureDetector(
              onTap: onElegir,
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.colores.outlineVariant),
                ),
                child: hayLocal
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Image.file(File(ruta!), fit: BoxFit.contain),
                      )
                    : hayRemoto
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(11),
                            child: Image.network(
                              urlSubida!,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.qr_code_2_rounded, color: Colors.black38),
                            ),
                          )
                        : const Icon(Icons.qr_code_2_rounded, size: 34, color: Colors.black38),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Código QR', style: context.textos.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    hayLocal || hayRemoto
                        ? 'El vendedor podrá mostrárselo al cliente al cobrar.'
                        : 'Sube la captura del QR de tu banco. Opcional.',
                    style: context.textos.bodySmall?.copyWith(
                      color: context.colores.onSurfaceVariant,
                    ),
                  ),
                  // Mientras no se haya subido, el QR sólo existe en este
                  // teléfono: conviene decirlo, porque quien lo va a mostrar es
                  // el vendedor desde otro dispositivo.
                  if (hayLocal && !hayRemoto) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Se enviará al servidor en la próxima sincronización.',
                      style: context.textos.labelSmall?.copyWith(
                        color: context.dominio.advertencia,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onElegir,
                        icon: const Icon(Icons.image_outlined, size: 16),
                        label: Text(hayLocal || hayRemoto ? 'Cambiar' : 'Elegir'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
                      ),
                      if (onQuitar != null)
                        TextButton(onPressed: onQuitar, child: const Text('Quitar')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Muestra extends StatelessWidget {
  const _Muestra({required this.hex, required this.elegido, required this.onTap});

  final String hex;
  final bool elegido;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = colorDesdeHex(hex) ?? context.colores.primary;

    return Semantics(
      selected: elegido,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: elegido
                ? Border.all(color: context.colores.onSurface, width: 3)
                : Border.all(color: context.colores.outlineVariant),
          ),
          child: elegido
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 20)
              : null,
        ),
      ),
    );
  }
}
