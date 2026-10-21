import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lo usado y el máximo de un recurso del plan (`maximo` null = sin límite).
@immutable
class RecursoPlan {
  const RecursoPlan({required this.usados, this.maximo});

  final int usados;
  final int? maximo;

  bool get ilimitado => maximo == null;
  bool get lleno => maximo != null && usados >= maximo!;

  /// Cuántos caben todavía (null = sin límite).
  int? get disponibles => maximo == null ? null : (maximo! - usados).clamp(0, maximo!);

  RecursoPlan conUsados(int n) => RecursoPlan(usados: n, maximo: maximo);

  factory RecursoPlan.desdeJson(Object? j) {
    final m = j is Map ? j : const {};
    return RecursoPlan(
      usados: ((m['usados'] as num?) ?? 0).toInt(),
      maximo: (m['maximo'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> aJson() => {'usados': usados, 'maximo': maximo};
}

/// Recursos que limita un plan, con sus palabras para los mensajes.
enum RecursoLimitado {
  sedes('sedes', 'Sedes', 'sede', 'sedes'),
  personas('personas', 'Personas', 'persona', 'personas'),
  productos('productos', 'Productos', 'producto', 'productos');

  const RecursoLimitado(this.api, this.titulo, this.singular, this.plural);
  final String api;
  final String titulo;
  final String singular;
  final String plural;

  static RecursoLimitado? desdeApi(Object? v) => values.where((r) => r.api == v).firstOrNull;
}

/// Plan vigente de una app de la empresa y su uso, tal como lo mandan los
/// backends (docs/PLATAFORMA.md). Cada app tiene el suyo: pagar Presente no
/// cambia el de Ventario.
@immutable
class PlanEmpresa {
  const PlanEmpresa({
    required this.codigo,
    required this.nombre,
    required this.sedes,
    required this.personas,
    required this.productos,
    this.vence,
    this.vencido = false,
    this.aplicativo = 'INVENTARIO',
  });

  /// INVENTARIO (Ventario) o ASISTENCIA (Presente).
  final String aplicativo;
  final String codigo;
  final String nombre;
  final DateTime? vence;
  final bool vencido;
  final RecursoPlan sedes;
  final RecursoPlan personas;
  final RecursoPlan productos;

  bool get esGratis => codigo == 'GRATIS';
  bool get esVentario => aplicativo == 'INVENTARIO';
  String get nombreApp => esVentario ? 'Ventario' : 'Presente';

  /// Los productos solo existen en Ventario.
  List<RecursoLimitado> get recursos =>
      esVentario ? RecursoLimitado.values : const [RecursoLimitado.sedes, RecursoLimitado.personas];

  RecursoPlan de(RecursoLimitado r) => switch (r) {
        RecursoLimitado.sedes => sedes,
        RecursoLimitado.personas => personas,
        RecursoLimitado.productos => productos,
      };

  static PlanEmpresa? desdeJson(Object? j) {
    if (j is! Map) return null;
    return PlanEmpresa(
      aplicativo: j['aplicativo'] as String? ?? 'INVENTARIO',
      codigo: j['codigo'] as String? ?? 'GRATIS',
      nombre: j['nombre'] as String? ?? 'Gratis',
      vence: DateTime.tryParse(j['vence'] as String? ?? ''),
      vencido: j['vencido'] == true,
      sedes: RecursoPlan.desdeJson(j['sedes']),
      personas: RecursoPlan.desdeJson(j['personas']),
      productos: RecursoPlan.desdeJson(j['productos']),
    );
  }

  Map<String, dynamic> aJson() => {
        'aplicativo': aplicativo,
        'codigo': codigo,
        'nombre': nombre,
        'vence': vence?.toIso8601String().substring(0, 10),
        'vencido': vencido,
        'sedes': sedes.aJson(),
        'personas': personas.aJson(),
        'productos': productos.aJson(),
      };
}

/// Datos de la empresa, su plan y las apps que tiene habilitadas.
@immutable
class EmpresaInfo {
  const EmpresaInfo({
    required this.uuid,
    required this.nombre,
    this.nit,
    this.telefono,
    this.email,
    this.plan,
    this.planPresente,
    this.aplicativos = const [],
  });

  final String uuid;
  final String nombre;
  final String? nit;
  final String? telefono;
  final String? email;

  /// Plan de Ventario (esta app) y de Presente: cada app tiene el suyo.
  final PlanEmpresa? plan;
  final PlanEmpresa? planPresente;
  final List<String> aplicativos;

  bool get tieneAsistencia => aplicativos.contains('ASISTENCIA');

  factory EmpresaInfo.desdeJson(Map<String, dynamic> j) {
    final e = j['empresa'] as Map<String, dynamic>;
    final planes = j['planes'];
    return EmpresaInfo(
      planPresente: planes is Map ? PlanEmpresa.desdeJson(planes['ASISTENCIA']) : null,
      uuid: e['uuid'] as String,
      nombre: e['nombre'] as String,
      nit: e['nit'] as String?,
      telefono: e['telefono'] as String?,
      email: e['email_contacto'] as String?,
      plan: PlanEmpresa.desdeJson(j['plan']),
      aplicativos: [for (final a in (j['aplicativos'] as List? ?? const [])) a as String],
    );
  }
}

/// Último plan conocido, guardado en el teléfono: con él se avisa del límite
/// ANTES de abrir un formulario, también sin red. Lo actualiza cada bajada
/// (`/sync/pull` trae el plan) y la pantalla «Mi empresa».
class PlanLocal {
  PlanLocal._();

  static const _clave = 'plan_empresa';

  /// Cambia cada vez que llega un plan nuevo; la UI lo escucha.
  static final ValueNotifier<PlanEmpresa?> actual = ValueNotifier(null);

  static Future<PlanEmpresa?> cargar() async {
    try {
      final texto = (await SharedPreferences.getInstance()).getString(_clave);
      actual.value = texto == null ? null : PlanEmpresa.desdeJson(jsonDecode(texto));
    } catch (_) {
      actual.value = null;
    }
    return actual.value;
  }

  static Future<void> guardar(Object? json) async {
    final plan = PlanEmpresa.desdeJson(json);
    if (plan == null) return;
    actual.value = plan;
    await (await SharedPreferences.getInstance()).setString(_clave, jsonEncode(plan.aJson()));
  }

  static Future<void> olvidar() async {
    actual.value = null;
    await (await SharedPreferences.getInstance()).remove(_clave);
  }
}
