import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../../core/database/daos/ventas_dao.dart';
import '../../../core/providers/providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/estados.dart';
import '../data/ticket_pdf.dart';

/// Previsualización del ticket.
///
/// Antes sólo existía `Printing.layoutPdf`, que abre el diálogo de impresión
/// del sistema: para *mirar* el ticket había que entrar en un flujo que ya está
/// preguntando por impresora y copias, y salirse de él sin imprimir. Aquí se ve
/// tal cual va a salir, y sólo entonces se decide.
///
/// Sirve además para comprobar los datos del negocio en el encabezado antes de
/// entregarle un papel a un cliente.
class VistaTicketPage extends ConsumerWidget {
  const VistaTicketPage({super.key, required this.venta});

  final VentaCompleta venta;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final negocio = ref.watch(nombreNegocioProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ticket'),
        // El número identifica el documento; el total dice si es el correcto
        // antes de gastar papel.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${venta.venta.numero} · ${venta.total.format()}',
                style: context.textos.bodySmall?.copyWith(
                  color: context.colores.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      body: PdfPreview(
        build: (formato) => TicketPdf.generar(venta, nombreNegocio: negocio),

        // Rollo de 80 mm: es el formato real de una térmica de mostrador.
        // Dejar cambiarlo a A4 sólo invita a desperdiciar media hoja por ticket.
        initialPageFormat: PdfPageFormat.roll80,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,

        // El ticket es angosto: sin este tope se estira hasta el ancho de la
        // pantalla y el texto queda gigante y borroso.
        maxPageWidth: 380,

        pdfFileName: 'ticket-${venta.venta.numero}.pdf',
        loadingWidget: const Center(child: CircularProgressIndicator()),
        onError: (context, error) => EstadoError(mensaje: '$error'),
      ),
    );
  }
}

/// Abre la previsualización. Se expone como función para llamarla igual desde
/// la confirmación de la venta y desde su detalle.
void abrirVistaTicket(BuildContext context, VentaCompleta venta) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => VistaTicketPage(venta: venta)),
  );
}
