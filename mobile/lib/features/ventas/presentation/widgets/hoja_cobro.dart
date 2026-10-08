import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/database/daos/metodos_pago_dao.dart';
import '../../../../core/database/daos/ventas_dao.dart';
import '../../../../core/money/money.dart';
import '../../../../core/providers/providers.dart';
import '../../../../core/theme/app_theme.dart';
import 'qr_cobro.dart';

/// Resultado del cobro: el desglose de con qué se pagó.
class ResultadoCobro {
  const ResultadoCobro({required this.pagos, this.clienteNombre, this.clienteDocumento});

  final List<PagoDeVenta> pagos;

  /// A quién se le vendió. Obligatorio cuando parte del pago es con una
  /// entidad de crédito (Addi, Crediya…): la cuenta por cobrar es contra la
  /// entidad, pero para reclamarle hay que poder decirle qué cliente fue.
  final String? clienteNombre;
  final String? clienteDocumento;

  bool get esMixto => pagos.length > 1;

  /// Lo que se guarda en la columna heredada `ventas.metodo_pago`.
  String get metodoLegado =>
      esMixto ? 'MIXTO' : (pagos.isEmpty ? 'EFECTIVO' : pagos.first.metodoTipo);

  /// Vueltas totales, sumando las de cada pago en efectivo.
  Money get cambio => Money.sumar(pagos.map((p) => p.cambio));
}

/// Cómo salió el usuario de la hoja de cobro.
///
/// Hace falta distinguir «me arrepentí» de «quiero añadir otro producto»: en el
/// mostrador, lo segundo pasa constantemente —el cliente ve algo más junto a la
/// caja cuando ya estás cobrando— y dejarlo sin salida obligaba a cancelar la
/// venta entera.
enum SalidaCobro {
  /// Volver al carrito y dejarlo como está.
  volverAlCarrito,

  /// Volver al carrito Y abrir el escáner para seguir añadiendo.
  seguirAgregando,
}

/// Hoja de cobro.
///
/// El cobro se **reparte entre varios medios**: en una tienda es corriente que
/// el cliente pague una parte en efectivo y el resto por Nequi. La hoja lleva
/// la cuenta de lo que falta y no deja confirmar hasta que la suma cuadra
/// exactamente con el total.
///
/// Los medios los configura cada negocio (Ajustes → Medios de pago), así que
/// aquí no hay ninguna lista fija: se leen de SQLite y por eso funcionan sin
/// conexión.
class HojaCobro extends ConsumerStatefulWidget {
  const HojaCobro({super.key, required this.total});

  final Money total;

  @override
  ConsumerState<HojaCobro> createState() => _HojaCobroState();
}

class _HojaCobroState extends ConsumerState<HojaCobro> {
  /// Pagos ya confirmados de este cobro.
  final List<PagoDeVenta> _pagos = [];

  final _monto = TextEditingController();
  final _referencia = TextEditingController();
  final _clienteNombre = TextEditingController();
  final _clienteDocumento = TextEditingController();

  MetodoPago? _metodo;
  bool _cobrando = false;

  @override
  void dispose() {
    _monto.dispose();
    _referencia.dispose();
    _clienteNombre.dispose();
    _clienteDocumento.dispose();
    super.dispose();
  }

  // ── Cálculo ───────────────────────────────────────────────────────────────

  Money get _yaPagado => Money.sumar(_pagos.map((p) => p.monto));

  /// Lo que queda por cubrir. Nunca negativo.
  Money get _pendiente {
    final falta = widget.total - _yaPagado;
    return falta.esNegativo ? const Money.cero() : falta;
  }

  bool get _cuadra => _yaPagado == widget.total;

  /// Importe tecleado, o el pendiente completo si el campo está vacío.
  ///
  /// El caso normal es pagar todo con un medio, así que dejar el campo en
  /// blanco significa «el resto con esto» y ahorra teclear el total exacto.
  Money get _importe {
    final limpio = _monto.text.trim().replaceAll('.', '').replaceAll(',', '.');
    if (limpio.isEmpty) return _pendiente;
    return Money.tryParse(limpio);
  }

  /// En efectivo se puede entregar de más: la diferencia son las vueltas. En
  /// los demás medios el importe es exacto.
  Money get _aplicado {
    final m = _metodo;
    if (m != null && m.esEfectivo && _importe > _pendiente) return _pendiente;
    return _importe;
  }

  Money get _cambio {
    final m = _metodo;
    if (m == null || !m.esEfectivo) return const Money.cero();
    return _importe > _pendiente ? _importe - _pendiente : const Money.cero();
  }

  bool get _puedeAgregar {
    final m = _metodo;
    if (m == null || _cobrando) return false;
    if (_aplicado.esCero || _aplicado.esNegativo) return false;
    // Con una entidad de crédito, el número de aprobación y los datos del
    // cliente son lo único que permite cobrarle después a la entidad.
    if ((m.requiereReferencia || m.esCredito) && _referencia.text.trim().isEmpty) return false;
    if (m.esCredito && (_clienteNombre.text.trim().length < 2 || _clienteDocumento.text.trim().length < 3)) {
      return false;
    }
    // Nunca se puede aplicar más de lo que falta: eso descuadraría la venta.
    return _aplicado <= _pendiente;
  }

  // ── Acciones ──────────────────────────────────────────────────────────────

  void _agregarPago() {
    final m = _metodo;
    if (m == null || !_puedeAgregar) return;

    setState(() {
      _pagos.add(
        PagoDeVenta(
          metodoUuid: m.uuid,
          metodoNombre: m.nombre,
          metodoTipo: m.tipo,
          monto: _aplicado,
          montoRecibido: m.esEfectivo ? _importe : null,
          referencia: _referencia.text.trim().isEmpty ? null : _referencia.text.trim(),
        ),
      );
      _monto.clear();
      _referencia.clear();
      _metodo = null;
    });

    HapticFeedback.selectionClick();
    FocusScope.of(context).unfocus();
  }

  void _quitarPago(int indice) {
    setState(() => _pagos.removeAt(indice));
    HapticFeedback.lightImpact();
  }

  void _confirmar() {
    if (!_cuadra) return;
    setState(() => _cobrando = true);
    final conCredito = _pagos.any((p) => p.metodoTipo == 'CREDITO');
    final nombre = _clienteNombre.text.trim();
    final documento = _clienteDocumento.text.trim();
    Navigator.pop(
      context,
      ResultadoCobro(
        pagos: List.unmodifiable(_pagos),
        clienteNombre: conCredito && nombre.isNotEmpty ? nombre : null,
        clienteDocumento: conCredito && documento.isNotEmpty ? documento : null,
      ),
    );
  }

  Future<void> _mostrarQr(MetodoPago metodo) {
    return showDialog<void>(
      context: context,
      builder: (_) => QrCobro(metodo: metodo, monto: _pendiente),
    );
  }

  // ── Construcción ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final permiteCredito = ref.watch(permiteCreditoProvider);
    final metodos = (ref.watch(metodosPagoActivosProvider).value ?? const <MetodoPago>[])
        // El fiado sólo aparece si el negocio lo habilitó: una tienda que no
        // fía no debería ver esa opción al cobrar.
        .where((m) => permiteCredito || !m.esCredito)
        .toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        // Tocar cualquier zona muerta cierra el teclado. Con la hoja casi a
        // pantalla completa y scroll dentro, el gesto de bajar se lo come el
        // scroll y el asa queda fuera de alcance.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Encabezado(total: widget.total),
                      const SizedBox(height: 16),

                      _Marcador(
                        total: widget.total,
                        pagado: _yaPagado,
                        pendiente: _pendiente,
                        cuadra: _cuadra,
                      ),

                      if (_pagos.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        for (var i = 0; i < _pagos.length; i++)
                          _FilaPago(pago: _pagos[i], onQuitar: () => _quitarPago(i)),
                      ],

                      if (!_cuadra) ...[
                        const SizedBox(height: 20),
                        Text(
                          _pagos.isEmpty ? '¿Con qué paga?' : '¿Y el resto?',
                          style: context.textos.titleSmall,
                        ),
                        const SizedBox(height: 10),
                        if (metodos.isEmpty)
                          const _SinMetodos()
                        else
                          _SelectorMetodo(
                            metodos: metodos,
                            elegido: _metodo,
                            onElegir: (m) => setState(() {
                              _metodo = m;
                              _referencia.clear();
                            }),
                          ),

                        if (_metodo != null) ...[
                          const SizedBox(height: 16),
                          _CamposDelPago(
                            metodo: _metodo!,
                            monto: _monto,
                            referencia: _referencia,
                            clienteNombre: _clienteNombre,
                            clienteDocumento: _clienteDocumento,
                            pendiente: _pendiente,
                            cambio: _cambio,
                            onCambio: () => setState(() {}),
                            onVerQr: () => _mostrarQr(_metodo!),
                          ),
                          const SizedBox(height: 14),
                          FilledButton.tonalIcon(
                            onPressed: _puedeAgregar ? _agregarPago : null,
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: Text(
                              _aplicado >= _pendiente
                                  ? 'Pagar el total con ${_metodo!.nombre}'
                                  : 'Añadir ${_aplicado.format()} en ${_metodo!.nombre}',
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(50),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: FilledButton.icon(
                  onPressed: _cuadra && !_cobrando ? _confirmar : null,
                  icon: const Icon(Icons.check_circle_outline_rounded),
                  label: Text(
                    _cuadra
                        ? 'Confirmar venta'
                        : 'Faltan ${_pendiente.format()} por cobrar',
                  ),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Piezas ─────────────────────────────────────────────────────────────────

class _Encabezado extends StatelessWidget {
  const _Encabezado({required this.total});

  final Money total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.pop(context, SalidaCobro.volverAlCarrito),
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Volver al carrito',
        ),
        Expanded(
          child: Text('Cobrar', textAlign: TextAlign.center, style: context.textos.titleMedium),
        ),
        IconButton(
          onPressed: () => Navigator.pop(context, SalidaCobro.seguirAgregando),
          icon: const Icon(Icons.add_shopping_cart_rounded),
          tooltip: 'Seguir agregando',
        ),
      ],
    );
  }
}

/// Total, cubierto y pendiente.
///
/// El pendiente es el número que gobierna la pantalla: mientras no sea cero no
/// se puede confirmar, y por eso va grande y con color.
class _Marcador extends StatelessWidget {
  const _Marcador({
    required this.total,
    required this.pagado,
    required this.pendiente,
    required this.cuadra,
  });

  final Money total;
  final Money pagado;
  final Money pendiente;
  final bool cuadra;

  @override
  Widget build(BuildContext context) {
    final color = cuadra ? context.dominio.exito : context.colores.primary;
    final fondo = cuadra ? context.dominio.exitoContenedor : context.colores.surfaceContainerHighest;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
      decoration: BoxDecoration(color: fondo, borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          Text(
            cuadra ? 'Cobro completo' : 'Falta por cobrar',
            style: context.textos.labelLarge?.copyWith(color: color),
          ),
          const SizedBox(height: 4),
          Text(
            cuadra ? total.format() : pendiente.format(),
            style: context.textos.displaySmall?.copyWith(color: color),
          ),
          if (!pagado.esCero && !cuadra) ...[
            const SizedBox(height: 6),
            Text(
              'Total ${total.format()} · cubierto ${pagado.format()}',
              style: context.textos.bodySmall?.copyWith(
                color: context.colores.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilaPago extends StatelessWidget {
  const _FilaPago({required this.pago, required this.onQuitar});

  final PagoDeVenta pago;
  final VoidCallback onQuitar;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        leading: Icon(_icono(pago.metodoTipo), color: context.colores.primary),
        title: Text(pago.metodoNombre, style: context.textos.titleSmall),
        subtitle: pago.cambio.esCero && pago.referencia == null
            ? null
            : Text(
                [
                  if (!pago.cambio.esCero) 'cambio ${pago.cambio.format()}',
                  if (pago.referencia != null) 'ref. ${pago.referencia}',
                ].join(' · '),
                style: context.textos.bodySmall,
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(pago.monto.format(), style: context.textos.titleSmall),
            IconButton(
              onPressed: onQuitar,
              icon: const Icon(Icons.close_rounded, size: 18),
              tooltip: 'Quitar',
            ),
          ],
        ),
      ),
    );
  }

  static IconData _icono(String tipo) => switch (tipo) {
        'EFECTIVO' => Icons.payments_outlined,
        'TARJETA' => Icons.credit_card_rounded,
        'TRANSFERENCIA' => Icons.smartphone_rounded,
        'CREDITO' => Icons.schedule_rounded,
        _ => Icons.account_balance_wallet_outlined,
      };
}

class _SelectorMetodo extends StatelessWidget {
  const _SelectorMetodo({
    required this.metodos,
    required this.elegido,
    required this.onElegir,
  });

  final List<MetodoPago> metodos;
  final MetodoPago? elegido;
  final ValueChanged<MetodoPago> onElegir;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final m in metodos)
          ChoiceChip(
            label: Text(m.nombre),
            avatar: m.tieneQr ? const Icon(Icons.qr_code_2_rounded, size: 16) : null,
            selected: elegido?.uuid == m.uuid,
            onSelected: (_) => onElegir(m),
          ),
      ],
    );
  }
}

class _CamposDelPago extends StatelessWidget {
  const _CamposDelPago({
    required this.metodo,
    required this.monto,
    required this.referencia,
    required this.clienteNombre,
    required this.clienteDocumento,
    required this.pendiente,
    required this.cambio,
    required this.onCambio,
    required this.onVerQr,
  });

  final MetodoPago metodo;
  final TextEditingController monto;
  final TextEditingController referencia;
  final TextEditingController clienteNombre;
  final TextEditingController clienteDocumento;
  final Money pendiente;
  final Money cambio;
  final VoidCallback onCambio;
  final VoidCallback onVerQr;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: monto,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => onCambio(),
          decoration: InputDecoration(
            labelText: metodo.esEfectivo ? 'Con cuánto paga' : 'Cuánto pone con este medio',
            prefixText: r'$ ',
            // Vacío = «el resto con esto»: lo normal es pagar todo con un medio,
            // y así no hay que teclear el importe exacto.
            helperText: 'Vacío = ${pendiente.format()} (todo lo pendiente)',
            suffixIcon: monto.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      monto.clear();
                      onCambio();
                    },
                    icon: const Icon(Icons.backspace_outlined, size: 18),
                    tooltip: 'Borrar el importe',
                  ),
          ),
        ),
        const SizedBox(height: 10),
        _Rapidos(
          pendiente: pendiente,
          esEfectivo: metodo.esEfectivo,
          onElegir: (m) {
            monto.text = textoDeMonto(m);
            monto.selection = TextSelection.collapsed(offset: monto.text.length);
            onCambio();
          },
        ),

        if (metodo.esEfectivo && !cambio.esCero) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: context.dominio.exitoContenedor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Text(
                  'Cambio',
                  style: context.textos.titleSmall?.copyWith(color: context.dominio.exito),
                ),
                const Spacer(),
                Text(
                  cambio.format(),
                  style: context.textos.titleMedium?.copyWith(color: context.dominio.exito),
                ),
              ],
            ),
          ),
        ],

        if (metodo.tieneQr) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onVerQr,
            icon: const Icon(Icons.qr_code_2_rounded, size: 18),
            label: const Text('Mostrar QR al cliente'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ],

        if (metodo.esCredito) ...[
          const SizedBox(height: 10),
          Text(
            '${metodo.nombre} le paga al negocio después. Estos datos son los que '
            'permiten reclamarle cada venta.',
            style: context.textos.bodySmall?.copyWith(color: context.colores.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: clienteNombre,
            onChanged: (_) => onCambio(),
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Nombre del cliente *',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: clienteDocumento,
            onChanged: (_) => onCambio(),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Documento del cliente *',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
        ],

        if (metodo.requiereReferencia || metodo.esCredito) ...[
          const SizedBox(height: 10),
          TextField(
            controller: referencia,
            onChanged: (_) => onCambio(),
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: metodo.esCredito ? 'Número de aprobación *' : 'Referencia *',
              helperText: metodo.esCredito
                  ? 'El que da ${metodo.nombre} al aprobar el crédito'
                  : 'Aprobación del datáfono o número de la transferencia',
              prefixIcon: const Icon(Icons.tag_rounded),
            ),
          ),
        ],
      ],
    );
  }
}

class _SinMetodos extends StatelessWidget {
  const _SinMetodos();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.dominio.advertenciaContenedor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: context.dominio.advertencia),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No hay medios de pago configurados. Un administrador puede '
              'añadirlos en Ajustes → Medios de pago.',
              style: context.textos.bodySmall?.copyWith(color: context.dominio.advertencia),
            ),
          ),
        ],
      ),
    );
  }
}

/// Importes de un toque.
///
/// Teclear «23.400» con el cliente esperando es lento y se presta a errores de
/// un dígito, que luego aparecen como descuadre de caja. Aquí se ofrece:
///
/// * **Todo el resto**: lo que falte por cobrar. Es el caso normal —un solo
///   medio, o el último tramo de un pago repartido— y en un pago mixto es
///   justo el «poner automáticamente el restante»: tras 1.000 en efectivo,
///   Transferencia ya propone la diferencia exacta.
/// * **Billetes** (sólo efectivo): los que el cliente puede entregar por encima
///   del pendiente, para que el cambio salga calculado sin teclear nada.
class _Rapidos extends StatelessWidget {
  const _Rapidos({
    required this.pendiente,
    required this.esEfectivo,
    required this.onElegir,
  });

  final Money pendiente;
  final bool esEfectivo;
  final ValueChanged<Money> onElegir;

  /// Billetes en circulación por encima del pendiente, más el redondeo al mil
  /// siguiente, que es como suele pagarse en efectivo.
  List<Money> get _billetes {
    if (!esEfectivo || pendiente.esCero) return const [];

    final propuestas = <int>{};

    // Siguiente múltiplo de 1.000 (100.000 centavos).
    const mil = 100000;
    final redondeo = ((pendiente.centavos ~/ mil) + 1) * mil;
    if (redondeo > pendiente.centavos) propuestas.add(redondeo);

    for (final billete in const [
      500000, 1000000, 2000000, 5000000, 10000000, // 5k, 10k, 20k, 50k, 100k
    ]) {
      if (billete > pendiente.centavos) propuestas.add(billete);
    }

    final lista = propuestas.toList()..sort();
    // Más de tres opciones convierte el atajo en otra decisión.
    return lista.take(3).map(Money.new).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (pendiente.esCero) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ActionChip(
          avatar: const Icon(Icons.done_all_rounded, size: 16),
          label: Text('Todo el resto · ${pendiente.format()}'),
          onPressed: () => onElegir(pendiente),
        ),
        for (final b in _billetes)
          ActionChip(
            avatar: const Icon(Icons.payments_outlined, size: 16),
            label: Text(b.format()),
            onPressed: () => onElegir(b),
          ),
      ],
    );
  }
}

/// Pasa un [Money] al texto que espera el campo de importe.
///
/// El campo se lee quitando separadores de miles, así que aquí se escribe sin
/// ellos; los decimales sólo aparecen si los hay.
String textoDeMonto(Money valor) {
  final centavos = valor.centavos;
  if (centavos % 100 == 0) return (centavos ~/ 100).toString();
  return (centavos / 100).toStringAsFixed(2);
}
