import 'dart:convert';

class Lectura {
  const Lectura({
    required this.humedad,
    required this.inclinacion,
    required this.desplazamiento,
    required this.dHumedad,
    required this.dInclinacion,
    required this.dDesplazamiento,
    required this.alerta,
    required this.inclinometroOk,
    this.crudoHumedad,
    this.crudoDesplazamiento,
  });

  final double humedad;
  final double inclinacion;
  final double desplazamiento;
  final double dHumedad;
  final double dInclinacion;
  final double dDesplazamiento;
  final int alerta;
  final bool inclinometroOk;
  final int? crudoHumedad;
  final int? crudoDesplazamiento;

  // El Arduino imprime "nan"/"inf"/"ovf" cuando un float no es válido, y eso no es JSON
  static final _noNumerico = RegExp(r'(?<=:)\s*-?(nan|inf|ovf)\b');

  static Lectura? desdeLinea(String linea) {
    linea = linea.trim();
    if (!linea.startsWith('{')) return null;
    try {
      final m = jsonDecode(linea.replaceAll(_noNumerico, 'null'));
      if (m is! Map<String, dynamic>) return null;
      double n(String k) => (m[k] as num?)?.toDouble() ?? double.nan;
      final alerta = (m['a'] as num).toInt();
      if (alerta < 0 || alerta > 2) return null;
      return Lectura(
        humedad: n('hum'),
        inclinacion: n('inc'),
        desplazamiento: n('dis'),
        dHumedad: n('dhum'),
        dInclinacion: n('dinc'),
        dDesplazamiento: n('ddis'),
        alerta: alerta,
        inclinometroOk: m['inc_ok'] == true,
        crudoHumedad: (m['hum_raw'] as num?)?.toInt(),
        crudoDesplazamiento: (m['dis_raw'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

class Limites {
  const Limites(this.amarillo, this.rojo);
  final double amarillo;
  final double rojo;

  bool igualA(double am, double ro) =>
      (amarillo - am).abs() < 0.006 && (rojo - ro).abs() < 0.006;
}

class Configuracion {
  const Configuracion({
    required this.humSeco,
    required this.humMojado,
    required this.humedad,
    required this.inclinacion,
    required this.desplazamiento,
  });

  static const fabrica = Configuracion(
    humSeco: 800,
    humMojado: 350,
    humedad: Limites(15, 25),
    inclinacion: Limites(2.5, 5),
    desplazamiento: Limites(3, 6),
  );

  final int humSeco;
  final int humMojado;
  final Limites humedad;
  final Limites inclinacion;
  final Limites desplazamiento;

  Limites limitesDe(String sensor) => switch (sensor) {
        'hum' => humedad,
        'inc' => inclinacion,
        _ => desplazamiento,
      };

  static Configuracion? desdeLinea(String linea) {
    linea = linea.trim();
    if (!linea.startsWith('{') || !linea.contains('"cfg"')) return null;
    try {
      final m = jsonDecode(linea);
      if (m is! Map<String, dynamic>) return null;
      double n(String k) => (m[k] as num).toDouble();
      return Configuracion(
        humSeco: (m['hum_seco'] as num).toInt(),
        humMojado: (m['hum_mojado'] as num).toInt(),
        humedad: Limites(n('hum_am'), n('hum_ro')),
        inclinacion: Limites(n('inc_am'), n('inc_ro')),
        desplazamiento: Limites(n('dis_am'), n('dis_ro')),
      );
    } catch (_) {
      return null;
    }
  }
}
