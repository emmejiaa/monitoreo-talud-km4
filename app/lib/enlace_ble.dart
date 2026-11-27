import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'enlace.dart';

// Enlace con módulos Bluetooth LE (HM-10, AT-09, JDY, HC-08...). La conexión
// la hace el código nativo de MainActivity; aquí se arma cada línea de texto
// y se reintenta solo si se pierde, igual que el enlace clásico.
class EnlaceBle implements Enlace {
  EnlaceBle(this.direccion) : _id = _siguienteId++ {
    _sub = flujoEventos.listen(_alEvento, onError: (_) {});
    // Después de que quien lo creó alcance a escuchar los estados
    scheduleMicrotask(_conectar);
  }

  static const canal = MethodChannel('km4/ble');
  static const canalEventos = EventChannel('km4/ble/eventos');
  // Un solo flujo para toda la app: si cada enlace escuchara el canal por su
  // cuenta, cerrar uno viejo cortaría los avisos del nuevo
  static final Stream<dynamic> flujoEventos = canalEventos.receiveBroadcastStream();
  static int _siguienteId = 1;
  static const _tiempoConexion = Duration(seconds: 12);
  static const _maxLinea = 512;

  final String direccion;
  final int _id;
  late final StreamSubscription<dynamic> _sub;
  final _lineas = StreamController<String>.broadcast();
  final _estados = StreamController<EstadoEnlace>.broadcast();
  final _buffer = <int>[];
  Timer? _limite;
  Timer? _reintento;
  EstadoEnlace? _estado;
  bool _conectado = false;
  bool _cerrado = false;
  int _intentos = 0;
  int _fallosSeguidos = 0;
  String? _motivo;

  @override
  Stream<String> get lineas => _lineas.stream;

  @override
  Stream<EstadoEnlace> get estados => _estados.stream;

  @override
  String? get motivoFallo => _motivo;

  void _cambiar(EstadoEnlace e) {
    if (e == _estado || _estados.isClosed) return;
    _estado = e;
    _estados.add(e);
  }

  Future<void> _conectar() async {
    if (_cerrado) return;
    _intentos++;
    _cambiar(_intentos == 1 ? EstadoEnlace.conectando : EstadoEnlace.reconectando);
    _limite?.cancel();
    _limite = Timer(_tiempoConexion, () => _perder('tiempo'));
    try {
      final error = await canal.invokeMethod<String>('conectar', {'id': _id, 'direccion': direccion});
      if (error != null) _perder(error);
    } on PlatformException catch (e) {
      _perder(e.code);
    } on MissingPluginException {
      _perder('sin_ble');
    }
  }

  void _alEvento(dynamic e) {
    if (_cerrado || e is! Map || e['id'] != _id) return;
    switch (e['tipo']) {
      case 'conectado':
        _limite?.cancel();
        _fallosSeguidos = 0;
        _motivo = null;
        _conectado = true;
        _cambiar(EstadoEnlace.conectado);
      case 'datos':
        final datos = e['datos'];
        if (datos is Uint8List) _recibir(datos);
      case 'desconectado':
        _perder(e['detalle'] as String? ?? '');
    }
  }

  void _recibir(Uint8List datos) {
    for (final b in datos) {
      if (b == 10) {
        final linea = utf8.decode(_buffer, allowMalformed: true).trim();
        _buffer.clear();
        if (linea.isNotEmpty && !_lineas.isClosed) _lineas.add(linea);
      } else if (b != 13) {
        _buffer.add(b);
        if (_buffer.length > _maxLinea) _buffer.clear();
      }
    }
  }

  void _perder(String detalle) {
    if (_cerrado) return;
    _limite?.cancel();
    _conectado = false;
    _buffer.clear();
    _motivo = explicar(detalle);
    if (detalle == 'tiempo') {
      canal.invokeMethod('desconectar', {'id': _id}).catchError((_) => null);
    }
    _cambiar(EstadoEnlace.reconectando);
    _reintento?.cancel();
    final segundos = min(5, 1 << min(_fallosSeguidos, 3));
    _fallosSeguidos++;
    _reintento = Timer(Duration(seconds: segundos), _conectar);
  }

  static String explicar(String detalle) {
    if (detalle == 'permiso') return 'Falta el permiso de Bluetooth';
    if (detalle == 'apagado' || detalle == 'sin_bluetooth') return 'El Bluetooth del celular está apagado';
    if (detalle == 'sin_ble') return 'Este celular no permite Bluetooth LE';
    if (detalle.startsWith('sin_servicio:')) {
      return 'El módulo responde, pero no tiene un canal serial BLE conocido '
          '(servicios: ${detalle.substring(13)})';
    }
    return 'No se encuentra el módulo Bluetooth. ¿Está encendido el Arduino?';
  }

  @override
  Future<void> enviar(String texto) async {
    if (!_conectado) throw StateError('Sin conexión');
    final ok = await canal.invokeMethod<bool>(
      'enviar',
      {'id': _id, 'datos': Uint8List.fromList(utf8.encode(texto))},
    );
    if (ok != true) throw StateError('No se pudo enviar');
  }

  @override
  Future<void> cerrar() async {
    if (_cerrado) return;
    _cerrado = true;
    _conectado = false;
    _limite?.cancel();
    _reintento?.cancel();
    _sub.cancel();
    _cambiar(EstadoEnlace.cerrado);
    _lineas.close();
    _estados.close();
    await canal.invokeMethod('desconectar', {'id': _id}).catchError((_) => null);
  }
}
