import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';

enum EstadoEnlace { conectando, conectado, reconectando, cerrado }

abstract class Enlace {
  Stream<String> get lineas;
  Stream<EstadoEnlace> get estados;
  String? get motivoFallo;
  Future<void> enviar(String texto);
  Future<void> cerrar();
}

class EnlaceBluetooth implements Enlace {
  EnlaceBluetooth(String direccion) {
    _link = FlutterClassicBluetooth().connectWithReconnect(
      address: direccion,
      policy: const BtcReconnectPolicy(
        initialBackoff: Duration(seconds: 1),
        maxBackoff: Duration(seconds: 5),
        connectTimeout: Duration(seconds: 10),
      ),
    );
  }

  late final BtcReconnectingConnection _link;

  @override
  Stream<String> get lineas => _link.input
      .frames(maxFrameLength: 512)
      .handleError((_) {})
      .map((f) => utf8.decode(f, allowMalformed: true).trim());

  @override
  Stream<EstadoEnlace> get estados => _link.state.map((s) => switch (s) {
        BtcReconnectState.connecting => EstadoEnlace.conectando,
        BtcReconnectState.connected => EstadoEnlace.conectado,
        BtcReconnectState.reconnecting => EstadoEnlace.reconectando,
        BtcReconnectState.failed || BtcReconnectState.closed => EstadoEnlace.cerrado,
      });

  @override
  String? get motivoFallo {
    final e = _link.lastError;
    if (e == null) return null;
    if (e is BtcDisabledException) return 'El Bluetooth del celular está apagado';
    if (e is BtcPermissionException) return 'Falta el permiso de Bluetooth';
    if (e is BtcConnectionException) {
      return switch (e.cause) {
        BtcConnectFailure.adapterOff => 'El Bluetooth del celular está apagado',
        BtcConnectFailure.notPaired => 'El HC-05 no está emparejado con este celular',
        BtcConnectFailure.permissionDenied => 'Falta el permiso de Bluetooth',
        BtcConnectFailure.busy => 'El HC-05 está conectado a otro celular',
        _ => 'No se encuentra el HC-05. ¿Está encendido el Arduino?',
      };
    }
    return 'No se encuentra el HC-05. ¿Está encendido el Arduino?';
  }

  @override
  Future<void> enviar(String texto) =>
      _link.send(Uint8List.fromList(utf8.encode(texto)));

  @override
  Future<void> cerrar() => _link.close();
}
