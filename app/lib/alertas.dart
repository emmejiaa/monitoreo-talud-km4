import 'package:flutter/services.dart';

abstract class Alertas {
  void sonar(String tipo);
  void vibrar();
}

class AlertasAndroid implements Alertas {
  static const _canal = MethodChannel('km4/alertas');

  @override
  void sonar(String tipo) =>
      _canal.invokeMethod('sonar', {'tipo': tipo}).catchError((_) {});

  @override
  void vibrar() => _canal.invokeMethod('vibrar').catchError((_) {});
}
