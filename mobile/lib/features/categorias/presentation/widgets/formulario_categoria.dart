import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/database/daos/categorias_dao.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/encabezado_hoja.dart';
import '../../../../core/widgets/estados.dart';

/// Alta y edición de categoría.
///
/// Se abre como hoja inferior y **devuelve el UUID de la categoría guardada**.
/// Eso es lo que permite crear una sin salir del formulario de producto: la
/// pantalla de atrás la recibe y la deja seleccionada, sin perder lo tecleado.
///
/// Sólo pide nombre y color. Una categoría es una etiqueta para agrupar y
/// filtrar; pedir descripción, icono y orden para crear «Bebidas» convierte
/// treinta segundos en dos minutos.
class FormularioCategoria extends ConsumerStatefulWidget {
  const FormularioCategoria({super.key, this.categoria, this.nombreInicial});

  final Categoria? categoria;

  /// Texto con el que se abrió desde otra pantalla, para no teclearlo dos veces.
  final String? nombreInicial;

  @override
  ConsumerState<FormularioCategoria> createState() => _FormularioCategoriaState();
}

class _FormularioCategoriaState extends ConsumerState<FormularioCategoria> {
  final _formulario = GlobalKey<FormState>();
  late final _nombre = TextEditingController(
    text: widget.categoria?.nombre ?? widget.nombreInicial ?? '',
  );

  String? _color;
  bool _guardando = false;

  bool get _esEdicion => widget.categoria != null;

  @override
  void initState() {
    super.initState();
    _color = widget.categoria?.color;
    if (!_esEdicion) {
      // Se propone un color libre de la paleta: dos categorías creadas seguidas
      // con el mismo tono no se distinguen en la lista de productos.
      ref.read(categoriasDaoProvider).colorSugerido().then((c) {
        if (mounted && _color == null) setState(() => _color = c);
      });
    }
  }

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!(_formulario.currentState?.validate() ?? false)) return;

    final dao = ref.read(categoriasDaoProvider);
    final nombre = _nombre.text.trim();

    // Dos «Bebidas» parten el catálogo en dos filtros idénticos a la vista, y
    // nadie entiende por qué al filtrar falta la mitad de los productos.
    final repetida = await dao.porNombre(nombre, exceptoUuid: widget.categoria?.uuid);
    if (repetida != null) {
      if (mounted) {
        mostrarMensaje(context, 'Ya existe una categoría «${repetida.nombre}»',
            esError: true);
      }
      return;
    }

    if (!mounted) return;
    setState(() => _guardando = true);

    try {
      final color = _color ?? CategoriasDao.paleta.first;
      String uuid;

      if (_esEdicion) {
        uuid = widget.categoria!.uuid;
        await dao.actualizar(uuid, nombre: nombre, color: color);
      } else {
        uuid = await dao.crear(nombre: nombre, color: color);
      }

      ref.read(syncEngineProvider).solicitar();
      await HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context, uuid);
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
                  titulo: _esEdicion ? 'Editar categoría' : 'Nueva categoría',
                ),
                const SizedBox(height: 16),

                TextFormField(
                  controller: _nombre,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _guardar(),
                  decoration: const InputDecoration(
                    labelText: 'Nombre *',
                    hintText: 'Bebidas, Aseo, Snacks…',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  validator: (v) =>
                      (v?.trim().length ?? 0) < 2 ? 'Escribe el nombre' : null,
                ),
                const SizedBox(height: 20),

                Text('Color', style: context.textos.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'Identifica la categoría de un vistazo en la lista de productos.',
                  style: context.textos.bodySmall?.copyWith(
                    color: context.colores.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                _Paleta(
                  seleccionado: _color,
                  onElegir: (c) => setState(() => _color = c),
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
                  label: Text(_esEdicion ? 'Guardar cambios' : 'Crear categoría'),
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

/// Selector de color.
///
/// Una rejilla de tonos fijos en lugar de un selector libre: garantiza
/// contraste suficiente y evita que dos categorías acaben con el mismo azul.
class _Paleta extends StatelessWidget {
  const _Paleta({required this.seleccionado, required this.onElegir});

  final String? seleccionado;
  final ValueChanged<String> onElegir;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final hex in CategoriasDao.paleta)
          _Muestra(
            hex: hex,
            elegido: seleccionado?.toUpperCase() == hex.toUpperCase(),
            onTap: () => onElegir(hex),
          ),
      ],
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
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            // El anillo marca la selección sin depender del color, que en
            // algunos tonos no se distinguiría del borde.
            border: elegido
                ? Border.all(color: context.colores.onSurface, width: 3)
                : Border.all(color: context.colores.outlineVariant, width: 1),
          ),
          child: elegido
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 22)
              : null,
        ),
      ),
    );
  }
}

/// Convierte `#RRGGBB` en un `Color`. Devuelve `null` si el texto no es válido:
/// el color llega del servidor y no se puede dar por bueno.
Color? colorDesdeHex(String? hex) {
  if (hex == null || !hex.startsWith('#') || hex.length != 7) return null;
  final valor = int.tryParse(hex.substring(1), radix: 16);
  return valor == null ? null : Color(0xFF000000 | valor);
}
