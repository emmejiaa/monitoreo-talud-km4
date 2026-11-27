import 'dart:async';
import 'dart:math';

import 'enlace.dart';

// Imita al Arduino (incluidos los comandos): un ciclo de 50 s en el que la
// humedad sube como en una lluvia (normal → amarilla → roja) y luego baja
class EnlaceSimulado implements Enlace {
  EnlaceSimulado() {
    _arranque = Timer(const Duration(milliseconds: 1200), () {
      _estados.add(EstadoEnlace.conectado);
      _lineas.add('Prototipo Km 4 (Arduino UNO) - iniciando');
      _lineas.add('[OK] Linea base inicial establecida');
      _medir();
      _reiniciarBase();
      _envio = Timer.periodic(const Duration(seconds: 1), (_) => _enviarLectura());
    });
  }

  final _lineas = StreamController<String>.broadcast();
  final _estados = StreamController<EstadoEnlace>.broadcast();
  final _azar = Random();
  late final Timer _arranque;
  Timer? _envio;
  int _segundos = 0;

  int _seco = 800, _mojado = 350;
  final _limites = <String, List<double>>{
    'hum': [15, 25],
    'inc': [2.5, 5],
    'dis': [3, 6],
  };

  int _crudoHum = 557;
  int _baseCrudoHum = 557;
  int _crudoDis = 513;
  List<double> _actual = [54, 1.2, 30.12];
  List<double> _base = [54, 1.2, 30.12];

  @override
  Stream<String> get lineas => _lineas.stream;
  @override
  Stream<EstadoEnlace> get estados => _estados.stream;
  @override
  String? get motivoFallo => null;

  double _lluvia() {
    final f = _segundos % 50;
    if (f < 10) return 0;
    if (f < 20) return 0.6 * (f - 10) / 10;
    if (f < 30) return 0.6 + 0.4 * (f - 20) / 10;
    if (f < 38) return 1;
    return 1 - (f - 38) / 12;
  }

  double _ruido(double amp) => (_azar.nextDouble() * 2 - 1) * amp;

  double _humedad(int crudo) =>
      (100 * (_seco - crudo) / (_seco - _mojado)).clamp(0, 100).toDouble();

  void _medir() {
    final l = _lluvia();
    final mov = max(0.0, l - 0.6) / 0.4;
    _crudoHum = (557 - 135 * l + _ruido(1.5)).round();
    final dis = 30.12 + 7 * mov + _ruido(0.04);
    _crudoDis = (dis / 60 * 1023).round();
    _actual = [_humedad(_crudoHum), 1.2 + 5.5 * mov + _ruido(0.05), dis];
  }

  int _nivelPorDelta(double d, String sensor) {
    final [am, ro] = _limites[sensor]!;
    if (d >= ro) return 2;
    if (d >= am) return 1;
    return 0;
  }

  void _enviarLectura() {
    _segundos++;
    _medir();
    final [hum, inc, dis] = _actual;
    final dHum = hum - _humedad(_baseCrudoHum), dInc = inc - _base[1], dDis = dis - _base[2];
    final nivel = [
      _nivelPorDelta(dHum, 'hum'),
      _nivelPorDelta(dInc.abs(), 'inc'),
      _nivelPorDelta(dDis.abs(), 'dis'),
    ].reduce(max);
    String f(double v) => v.toStringAsFixed(2);
    _lineas.add('{"hum":${f(hum)},"inc":${f(inc)},"dis":${f(dis)},'
        '"dhum":${f(dHum)},"dinc":${f(dInc)},"ddis":${f(dDis)},'
        '"a":$nivel,"inc_ok":true,"dis_ok":true,'
        '"hum_raw":$_crudoHum,"dis_raw":$_crudoDis}');
  }

  String _config() {
    String f(double v) => v.toStringAsFixed(2);
    final h = _limites['hum']!, i = _limites['inc']!, d = _limites['dis']!;
    return '{"cfg":1,"hum_seco":$_seco,"hum_mojado":$_mojado,'
        '"hum_am":${f(h[0])},"hum_ro":${f(h[1])},'
        '"inc_am":${f(i[0])},"inc_ro":${f(i[1])},'
        '"dis_am":${f(d[0])},"dis_ro":${f(d[1])}}';
  }

  void _responder(List<String> lineas) {
    Timer(const Duration(milliseconds: 150), () {
      for (final l in lineas) {
        if (!_lineas.isClosed) _lineas.add(l);
      }
    });
  }

  void _reiniciarBase() {
    _baseCrudoHum = _crudoHum;
    _base = List.of(_actual);
  }

  @override
  Future<void> enviar(String texto) async {
    for (final linea in texto.toLowerCase().split(RegExp(r'[\r\n]+'))) {
      final p = linea.trim().split(RegExp(r'\s+'));
      if (p.first.isEmpty) continue;
      _responder(_ejecutar(p));
    }
  }

  List<String> _ejecutar(List<String> p) {
    switch (p.first) {
      case 'r':
        _reiniciarBase();
        return ['>> Linea base reiniciada'];
      case 'cfg':
        return [_config()];
      case 'fabrica':
        _seco = 800;
        _mojado = 350;
        _limites
          ..['hum'] = [15, 25]
          ..['inc'] = [2.5, 5]
          ..['dis'] = [3, 6];
        return ['>> Valores de fabrica restaurados', _config()];
      case 'cal':
        var seco = _seco, mojado = _mojado;
        if (p.length == 2 && p[1] == 'seco') {
          seco = _crudoHum;
        } else if (p.length == 2 && p[1] == 'mojado') {
          mojado = _crudoHum;
        } else {
          return ['>> Error: use cal seco, cal mojado o cal <seco> <mojado>'];
        }
        if ((seco - mojado).abs() < 50) {
          return ['>> Error: seco y mojado deben diferir al menos 50 (rango 0-1023)'];
        }
        _seco = seco;
        _mojado = mojado;
        return ['>> Calibracion guardada', _config()];
      case 'umb':
        final maximo = {'hum': 100.0, 'inc': 45.0, 'dis': 60.0};
        final am = p.length == 4 ? double.tryParse(p[2]) : null;
        final ro = p.length == 4 ? double.tryParse(p[3]) : null;
        if (am == null || ro == null || !maximo.containsKey(p[1])) {
          return ['>> Error: use umb hum|inc|dis <amarilla> <roja>'];
        }
        if (am <= 0 || ro <= am || ro > maximo[p[1]]!) {
          return ['>> Error: limites fuera de rango (0 < amarilla < roja)'];
        }
        _limites[p[1]] = [am, ro];
        return ['>> Limites guardados', _config()];
      default:
        return ['>> Error: comando no reconocido'];
    }
  }

  @override
  Future<void> cerrar() async {
    _arranque.cancel();
    _envio?.cancel();
    _lineas.close();
    _estados.close();
  }
}
