import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import 'api_exception.dart';
import 'token_store.dart';

/// Cliente HTTP.
///
/// Toda la red de la app pasa por aquí. La UI **no** lo usa nunca de forma
/// directa: sólo lo usa el motor de sincronización y el login. Si una pantalla
/// necesitara llamar a la API para pintarse, sería señal de que el modelo
/// offline se rompió.
class ApiClient {
  ApiClient({required TokenStore tokenStore, String? urlBase, Dio? dio})
      : _tokens = tokenStore,
        _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = urlBase ?? AppConfig.urlPorDefecto
      ..connectTimeout = AppConfig.timeoutConexion
      ..receiveTimeout = AppConfig.timeoutRespuesta
      ..sendTimeout = AppConfig.timeoutRespuesta
      ..contentType = Headers.jsonContentType
      // Se aceptan todos los códigos y se decide aquí: así un 401 llega al
      // interceptor de refresco en lugar de convertirse en excepción antes.
      ..validateStatus = (s) => s != null && s < 500;

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (opciones, handler) async {
          if (opciones.extra['sinAuth'] != true) {
            final token = await _tokens.accessToken;
            if (token != null) opciones.headers['Authorization'] = 'Bearer $token';
          }
          if (dispositivoUuid != null) {
            opciones.headers['X-Dispositivo'] = dispositivoUuid;
          }
          handler.next(opciones);
        },
      ),
    );

    if (kDebugMode) {
      _dio.interceptors.add(
        LogInterceptor(requestBody: false, responseBody: false, request: false),
      );
    }
  }

  final Dio _dio;
  final TokenStore _tokens;

  String? dispositivoUuid;

  /// Se invoca cuando el refresco falla de forma definitiva: la sesión murió y
  /// hay que llevar al usuario al login.
  /// Se llama cuando el servidor dice que esta sesión ya no vale: cuenta
  /// inhabilitada, fuera de turno, sesión revocada. Lo escucha la guardia de
  /// sesión, que cierra la sesión en el teléfono y muestra el motivo.
  ///
  /// Antes este callback existía pero nadie lo asignaba, y además un 403 no lo
  /// disparaba: un empleado inhabilitado seguía trabajando en su teléfono.
  void Function(String codigo, String mensaje)? alPerderSesion;

  /// Códigos con los que el servidor expulsa una sesión. Cualquier otro 401/403
  /// (un permiso concreto, una sede ajena) es un error de esa operación y no
  /// cierra la sesión.
  static const codigosDeExpulsion = {
    'CUENTA_DESACTIVADA',
    'FUERA_DE_HORARIO',
    'USUARIO_INEXISTENTE',
    'SIN_SEDE',
    'REFRESH_INVALIDO',
    'REFRESH_REUTILIZADO',
    'REFRESH_EXPIRADO',
  };

  /// Motivo del último refresco rechazado, para informarlo al expulsar.
  ({String codigo, String mensaje})? _rechazoRefresco;

  static ({String codigo, String mensaje})? _errorDe(dynamic cuerpo) {
    if (cuerpo is Map && cuerpo['error'] is Map) {
      final e = cuerpo['error'] as Map;
      return (codigo: (e['codigo'] as String?) ?? '', mensaje: (e['mensaje'] as String?) ?? '');
    }
    return null;
  }

  String get urlBase => _dio.options.baseUrl;

  set urlBase(String url) => _dio.options.baseUrl = url.replaceAll(RegExp(r'/+$'), '');

  /// Refresco en curso. Si diez peticiones reciben 401 a la vez, sólo una
  /// refresca y las demás esperan a ese mismo futuro; sin esto se dispararían
  /// diez rotaciones y la detección de reúso del servidor revocaría la familia
  /// entera, echando al usuario.
  Future<bool>? _refrescoEnCurso;

  // ── Métodos ───────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> get(
    String ruta, {
    Map<String, dynamic>? query,
    bool sinAuth = false,
  }) =>
      _ejecutar(() => _dio.get<dynamic>(
            '${AppConfig.versionApi}$ruta',
            queryParameters: query,
            options: Options(extra: {'sinAuth': sinAuth}),
          ));

  Future<Map<String, dynamic>> post(
    String ruta, {
    Object? cuerpo,
    bool sinAuth = false,
    Duration? timeout,
  }) =>
      _ejecutar(() => _dio.post<dynamic>(
            '${AppConfig.versionApi}$ruta',
            data: cuerpo,
            options: Options(
              extra: {'sinAuth': sinAuth},
              receiveTimeout: timeout,
            ),
          ));

  Future<Map<String, dynamic>> patch(String ruta, {Object? cuerpo}) => _ejecutar(
      () => _dio.patch<dynamic>('${AppConfig.versionApi}$ruta', data: cuerpo));

  Future<Map<String, dynamic>> put(String ruta, {Object? cuerpo}) => _ejecutar(
      () => _dio.put<dynamic>('${AppConfig.versionApi}$ruta', data: cuerpo));

  Future<Map<String, dynamic>> delete(String ruta) =>
      _ejecutar(() => _dio.delete<dynamic>('${AppConfig.versionApi}$ruta'));

  /// Sube la foto de un producto. La UI no llama esto: lo hace el SyncEngine
  /// cuando hay red, para que un alta offline no quede bloqueada.
  Future<Map<String, dynamic>> subirImagen(File archivo) {
    final form = FormData.fromMap({
      'imagen': MultipartFile.fromFileSync(
        archivo.path,
        filename: archivo.uri.pathSegments.isEmpty
            ? 'producto.jpg'
            : archivo.uri.pathSegments.last,
      ),
    });
    return _ejecutar(
      () => _dio.post<dynamic>(
        '${AppConfig.versionApi}/uploads/imagen',
        data: form,
        options: Options(
          contentType: 'multipart/form-data',
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 60),
        ),
      ),
    );
  }

  /// Sondeo de conectividad REAL.
  ///
  /// `connectivity_plus` sólo sabe si hay una interfaz de red activa. Estar
  /// conectado al wifi de una cafetería con portal cautivo da «conectado» y
  /// ninguna petición funciona. Esto confirma que la API responde de verdad.
  Future<bool> hayServidor() async {
    try {
      final r = await _dio.get<dynamic>(
        '/health',
        options: Options(
          extra: {'sinAuth': true},
          receiveTimeout: AppConfig.timeoutSalud,
          sendTimeout: AppConfig.timeoutSalud,
        ),
      );
      return r.statusCode == 200 && (r.data is Map) && (r.data as Map)['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _ejecutar(
    Future<Response<dynamic>> Function() peticion, {
    bool esReintento = false,
  }) async {
    late Response<dynamic> respuesta;
    try {
      respuesta = await peticion();
    } on DioException catch (e) {
      throw ApiException.desdeDio(e);
    }

    final conSesion = respuesta.requestOptions.extra['sinAuth'] != true;
    if (conSesion && (respuesta.statusCode == 401 || respuesta.statusCode == 403)) {
      final error = _errorDe(respuesta.data);
      if (respuesta.statusCode == 401 && !esReintento && error?.codigo != 'CUENTA_DESACTIVADA') {
        final refrescado = await _refrescarToken();
        if (refrescado) return _ejecutar(peticion, esReintento: true);
        final rechazo = _rechazoRefresco;
        if (rechazo != null && codigosDeExpulsion.contains(rechazo.codigo)) {
          alPerderSesion?.call(rechazo.codigo, rechazo.mensaje);
        }
      } else if (error != null && codigosDeExpulsion.contains(error.codigo)) {
        alPerderSesion?.call(error.codigo, error.mensaje);
      }
    }

    if (respuesta.statusCode! >= 400) {
      throw ApiException.desdeDio(
        DioException.badResponse(
          statusCode: respuesta.statusCode!,
          requestOptions: respuesta.requestOptions,
          response: respuesta,
        ),
      );
    }

    final datos = respuesta.data;
    if (datos is Map<String, dynamic>) return datos;
    return {'data': datos};
  }

  Future<bool> _refrescarToken() {
    return _refrescoEnCurso ??= _hacerRefresco().whenComplete(() {
      _refrescoEnCurso = null;
    });
  }

  Future<bool> _hacerRefresco() async {
    final refresh = await _tokens.refreshToken;
    if (refresh == null) return false;

    try {
      final r = await _dio.post<dynamic>(
        '${AppConfig.versionApi}/auth/refresh',
        data: {'refresh_token': refresh},
        options: Options(extra: {'sinAuth': true}),
      );
      if (r.statusCode != 200) {
        // El servidor rechazó la sesión (no es un problema de red): se guarda
        // el motivo para que quien expulse pueda explicarlo.
        _rechazoRefresco = _errorDe(r.data);
        await _tokens.limpiar();
        return false;
      }
      _rechazoRefresco = null;
      final datos = (r.data as Map)['data'] as Map;
      await _tokens.guardarTokens(
        accessToken: datos['access_token'] as String,
        refreshToken: datos['refresh_token'] as String,
        refreshExpira: DateTime.tryParse(datos['refresh_expira'] as String? ?? ''),
      );
      return true;
    } catch (_) {
      // Un fallo de red al refrescar NO debe borrar los tokens: el usuario
      // sigue autenticado, simplemente no hay señal ahora mismo.
      return false;
    }
  }
}
