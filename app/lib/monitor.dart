import 'dart:async';

import 'package:flutter/foundation.dart';

import 'alertas.dart';
import 'enlace.dart';
import 'lectura.dart';

enum Vista { conectando, reconectando, esperando, sinDatos, normal, amarilla, roja }

enum Tarea { reinicio, calibracion, limites, fabrica }

class Resultado {
  const Resultado(this.ok, this.mensaje);
  final bool ok;
  final String mensaje;
}

class Punto {
  const Punto(this.hora, this.dHumedad, this.dInclinacion, this.dDesplazamiento);
  final DateTime hora;
  final double dHumedad;
  final double? dInclinacion;
  final double? dDesplazamiento;
}

enum TipoEvento { conexion, normal, amarilla, roja, base, ajuste }

class Evento {
  const Evento(this.hora, this.tipo, this.texto);
  final DateTime hora;
  final TipoEvento tipo;
  final String texto;
}

class _Espera {
  _Espera(this.acepta);
  final bool Function(String linea) acepta;
  final completer = Completer<String>();
}

class Monitor extends ChangeNotifier {
  Monitor({
    required this._crearEnlace,
    required this.alertas,
    DateTime Function()? reloj,
  }) : _ahora = reloj ?? DateTime.now {
    _abrirEnlace();
    _vigilante = Timer.periodic(const Duration(milliseconds: 500), (_) => _vigilar());
  }

  static const limiteSinDatos = Duration(seconds: 3);
  static const limitePrimerDato = Duration(seconds: 8);
  // Si el enlace parece conectado pero no llega nada, se cierra y se abre de nuevo
  static const limiteReconexion = Duration(seconds: 12);
  static const intervaloRoja = Duration(milliseconds: 2500);
  static const esperaRespuesta = Duration(milliseconds: 1500);
  static const intentosComando = 3;
  static const ventanaGrafica = Duration(minutes: 3);
  static const maxEventos = 300;

  final Enlace Function() _crearEnlace;
  final Alertas alertas;
  final DateTime Function() _ahora;

  late Enlace _enlace;
  StreamSubscription<String>? _subLineas;
  StreamSubscription<EstadoEnlace>? _subEstados;
  late final Timer _vigilante;
  Timer? _timerRoja;
  final _esperas = <_Espera>[];

  EstadoEnlace _estadoEnlace = EstadoEnlace.conectando;
  DateTime? _conectadoDesde;
  DateTime? _ultimoDato;
  bool _sinDatos = false;
  int _nivelSonando = 0;
  bool _cerrado = false;
  bool _reabriendo = false;
  bool _configPedida = false;
  int? _nivelRegistrado;

  Lectura? lectura;
  Configuracion? config;
  final historial = <Punto>[];
  final eventos = <Evento>[];
  bool sonidoActivo = true;
  Tarea? tarea;

  EstadoEnlace get estadoEnlace => _estadoEnlace;
  bool get conectado => _estadoEnlace == EstadoEnlace.conectado;
  bool get ocupado => tarea != null;
  bool get reiniciando => tarea == Tarea.reinicio;
  String? get motivoFallo => _enlace.motivoFallo;
  Configuracion get limites => config ?? Configuracion.fabrica;

  Vista get vista {
    switch (_estadoEnlace) {
      case EstadoEnlace.conectando:
        return Vista.conectando;
      case EstadoEnlace.reconectando:
      case EstadoEnlace.cerrado:
        return Vista.reconectando;
      case EstadoEnlace.conectado:
        if (_sinDatos) return Vista.sinDatos;
        if (_ultimoDato == null || lectura == null) return Vista.esperando;
        return [Vista.normal, Vista.amarilla, Vista.roja][lectura!.alerta];
    }
  }

  bool get datosVigentes =>
      conectado && _ultimoDato != null && lectura != null && !_sinDatos;

  void _abrirEnlace() {
    _enlace = _crearEnlace();
    _subLineas = _enlace.lineas.listen(_alRecibir);
    _subEstados = _enlace.estados.listen(_alCambiarEstado);
  }

  Future<void> _cerrarEnlace() async {
    _subLineas?.cancel();
    _subEstados?.cancel();
    _subLineas = null;
    _subEstados = null;
    await _enlace.cerrar().timeout(const Duration(seconds: 3)).catchError((_) {});
  }

  Future<void> reconectar() async {
    if (_cerrado || _reabriendo) return;
    _reabriendo = true;
    _detenerAlertas();
    _estadoEnlace = EstadoEnlace.conectando;
    _conectadoDesde = null;
    _ultimoDato = null;
    _sinDatos = false;
    _configPedida = false;
    notifyListeners();
    await _cerrarEnlace();
    _reabriendo = false;
    if (_cerrado) return;
    _abrirEnlace();
  }

  void _alCambiarEstado(EstadoEnlace e) {
    if (e == _estadoEnlace) return;
    final estabaConectado = conectado;
    _estadoEnlace = e;
    if (e == EstadoEnlace.conectado) {
      _conectadoDesde = _ahora();
      _ultimoDato = null;
      _sinDatos = false;
      _registrar(TipoEvento.conexion, 'Conectado al Arduino');
    } else {
      if (estabaConectado) _registrar(TipoEvento.conexion, 'Se perdió la conexión con el Arduino');
      _configPedida = false;
      _nivelRegistrado = null;
      _detenerAlertas();
    }
    notifyListeners();
  }

  void _registrar(TipoEvento tipo, String texto) {
    eventos.add(Evento(_ahora(), tipo, texto));
    if (eventos.length > maxEventos) eventos.removeAt(0);
  }

  void borrarBitacora() {
    eventos.clear();
    notifyListeners();
  }

  static String _num(double v, int dec) => v.toStringAsFixed(dec);
  static String _signo(double v, int dec) => v > 0 ? '+${_num(v, dec)}' : _num(v, dec);

  String _causas(Lectura l) {
    final c = limites;
    final causas = <String>[
      if (l.dHumedad >= c.humedad.amarillo) 'humedad ${_signo(l.dHumedad, 1)} %',
      if (l.inclinometroOk && l.dInclinacion.abs() >= c.inclinacion.amarillo)
        'inclinación ${_signo(l.dInclinacion, 2)}°',
      if (l.extensometroOk && l.dDesplazamiento.abs() >= c.desplazamiento.amarillo)
        'desplazamiento ${_signo(l.dDesplazamiento, 2)} mm',
    ];
    return causas.isEmpty ? '' : ' — ${causas.join(', ')}';
  }

  void _registrarNivel(Lectura l) {
    if (l.alerta == _nivelRegistrado) return;
    final anterior = _nivelRegistrado;
    _nivelRegistrado = l.alerta;
    if (anterior == null && l.alerta == 0) return;
    switch (l.alerta) {
      case 1:
        _registrar(TipoEvento.amarilla, 'Alerta amarilla${_causas(l)}');
      case 2:
        _registrar(TipoEvento.roja, 'Alerta roja${_causas(l)}');
      default:
        _registrar(TipoEvento.normal, 'Volvió a estado normal');
    }
  }

  void _registrarCambiosConfig(Configuracion antes, Configuracion despues) {
    if (antes.humSeco != despues.humSeco) {
      _registrar(TipoEvento.ajuste, 'Calibración: seco ${antes.humSeco} → ${despues.humSeco}');
    }
    if (antes.humMojado != despues.humMojado) {
      _registrar(TipoEvento.ajuste, 'Calibración: mojado ${antes.humMojado} → ${despues.humMojado}');
    }
    for (final (clave, nombre, unidad) in [
      ('hum', 'humedad', '%'),
      ('inc', 'inclinación', '°'),
      ('dis', 'desplazamiento', 'mm'),
    ]) {
      final a = antes.limitesDe(clave), d = despues.limitesDe(clave);
      if (!a.igualA(d.amarillo, d.rojo)) {
        String f(Limites l) => '${_corto(l.amarillo)}/${_corto(l.rojo)}';
        _registrar(TipoEvento.ajuste, 'Límites de $nombre: ${f(a)} → ${f(d)} $unidad');
      }
    }
  }

  static String _corto(double v) =>
      v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  void _alRecibir(String linea) {
    for (final e in List.of(_esperas)) {
      if (!e.completer.isCompleted && e.acepta(linea)) e.completer.complete(linea);
    }

    if (linea.contains('Linea base reiniciada')) {
      _registrar(TipoEvento.base, 'Línea base reiniciada');
      notifyListeners();
      return;
    }

    final cfg = Configuracion.desdeLinea(linea);
    if (cfg != null) {
      final antes = config;
      if (antes != null) _registrarCambiosConfig(antes, cfg);
      config = cfg;
      notifyListeners();
      return;
    }

    final l = Lectura.desdeLinea(linea);
    if (l == null) return;
    lectura = l;
    final ahora = _ahora();
    _ultimoDato = ahora;
    _sinDatos = false;
    if (_estadoEnlace != EstadoEnlace.conectado) {
      _estadoEnlace = EstadoEnlace.conectado;
      _conectadoDesde ??= _ultimoDato;
      _registrar(TipoEvento.conexion, 'Conectado al Arduino');
    }
    historial.add(Punto(
      ahora,
      l.dHumedad,
      l.inclinometroOk ? l.dInclinacion : null,
      l.extensometroOk ? l.dDesplazamiento : null,
    ));
    while (historial.isNotEmpty && ahora.difference(historial.first.hora) > ventanaGrafica) {
      historial.removeAt(0);
    }
    _registrarNivel(l);
    _actualizarAlertas(l.alerta);
    notifyListeners();
    if (!_configPedida) {
      _configPedida = true;
      pedirConfig();
    }
  }

  void _vigilar() {
    if (!conectado || _conectadoDesde == null) return;
    final ref = _ultimoDato ?? _conectadoDesde!;
    final transcurrido = _ahora().difference(ref);
    final limite = _ultimoDato != null ? limiteSinDatos : limitePrimerDato;
    if (transcurrido > limiteReconexion) {
      reconectar();
      return;
    }
    if (transcurrido > limite && !_sinDatos) {
      _sinDatos = true;
      _nivelRegistrado = null;
      _registrar(TipoEvento.conexion, 'El Arduino dejó de enviar datos');
      _detenerAlertas();
      notifyListeners();
    }
  }

  void _actualizarAlertas(int nivel) {
    if (nivel == _nivelSonando) return;
    _timerRoja?.cancel();
    _timerRoja = null;
    if (nivel == 2) {
      _sonarRoja();
      _timerRoja = Timer.periodic(intervaloRoja, (_) => _sonarRoja());
    } else if (nivel == 1 && _nivelSonando == 0) {
      if (sonidoActivo) alertas.sonar('amarilla');
    }
    _nivelSonando = nivel;
  }

  void _sonarRoja() {
    if (sonidoActivo) alertas.sonar('roja');
    alertas.vibrar();
  }

  void _detenerAlertas() {
    _timerRoja?.cancel();
    _timerRoja = null;
    _nivelSonando = 0;
  }

  void alternarSonido() {
    sonidoActivo = !sonidoActivo;
    if (sonidoActivo) alertas.sonar('amarilla');
    notifyListeners();
  }

  // SoftwareSerial en el UNO no recibe mientras transmite, así que un comando
  // se puede perder: se reenvía hasta que llegue la respuesta del Arduino
  Future<String?> _pedir(String comando, bool Function(String linea) acepta) async {
    for (var i = 0; i < intentosComando && !_cerrado; i++) {
      if (!conectado) return null;
      final espera = _Espera(acepta);
      _esperas.add(espera);
      try {
        await _enlace.enviar('$comando\n');
        return await espera.completer.future.timeout(esperaRespuesta);
      } catch (_) {
      } finally {
        _esperas.remove(espera);
      }
    }
    return null;
  }

  static bool _esError(String linea) => linea.startsWith('>> Error');

  static String _textoError(String linea) =>
      linea.replaceFirst('>> Error:', '').trim();

  Future<Resultado> _ejecutar(Tarea t, Future<Resultado> Function() accion) async {
    if (ocupado) return const Resultado(false, 'Espere a que termine la acción anterior');
    if (!conectado) return const Resultado(false, 'No hay conexión con el Arduino');
    tarea = t;
    notifyListeners();
    try {
      return await accion();
    } finally {
      tarea = null;
      if (!_cerrado) notifyListeners();
    }
  }

  Future<Resultado> reiniciarLineaBase() => _ejecutar(Tarea.reinicio, () async {
        final r = await _pedir('r', (l) => l.contains('Linea base reiniciada'));
        return r == null
            ? const Resultado(false, 'El Arduino no confirmó el reinicio. Intente de nuevo.')
            : const Resultado(true, 'Línea base reiniciada');
      });

  Future<void> pedirConfig() async {
    if (!conectado) return;
    await _pedir('cfg', (l) => Configuracion.desdeLinea(l) != null);
  }

  Future<Resultado> _ajuste(Tarea t, String comando, bool Function(Configuracion c) aplicado,
      String exito) {
    return _ejecutar(t, () async {
      final r = await _pedir(comando, (l) {
        if (_esError(l)) return true;
        final c = Configuracion.desdeLinea(l);
        return c != null && aplicado(c);
      });
      if (r == null) {
        return const Resultado(false,
            'El Arduino no respondió. Revise que tenga el firmware nuevo e intente otra vez.');
      }
      if (_esError(r)) return Resultado(false, _textoError(r));
      return Resultado(true, exito);
    });
  }

  Future<Resultado> calibrar({required bool seco}) => _ajuste(
        Tarea.calibracion,
        seco ? 'cal seco' : 'cal mojado',
        (_) => true,
        seco ? 'Valor seco guardado' : 'Valor mojado guardado',
      );

  Future<Resultado> cambiarLimites(String sensor, double amarillo, double rojo) => _ajuste(
        Tarea.limites,
        'umb $sensor ${amarillo.toStringAsFixed(2)} ${rojo.toStringAsFixed(2)}',
        (c) => c.limitesDe(sensor).igualA(amarillo, rojo),
        'Límites guardados',
      );

  Future<Resultado> restaurarFabrica() => _ajuste(
        Tarea.fabrica,
        'fabrica',
        (c) =>
            c.humSeco == Configuracion.fabrica.humSeco &&
            c.humMojado == Configuracion.fabrica.humMojado &&
            c.humedad.igualA(Configuracion.fabrica.humedad.amarillo, Configuracion.fabrica.humedad.rojo),
        'Valores de fábrica restaurados',
      );

  @override
  void dispose() {
    _cerrado = true;
    _vigilante.cancel();
    _detenerAlertas();
    _cerrarEnlace();
    super.dispose();
  }
}
