import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:monitoreo_km4/alertas.dart';
import 'package:monitoreo_km4/enlace.dart';
import 'package:monitoreo_km4/enlace_simulado.dart';
import 'package:monitoreo_km4/lectura.dart';
import 'package:monitoreo_km4/monitor.dart';
import 'package:monitoreo_km4/pantalla_monitor.dart';
import 'package:monitoreo_km4/tema.dart';

const lineaNormal =
    '{"hum":54.00,"inc":0.00,"dis":30.12,"dhum":0.00,"dinc":0.00,"ddis":0.00,"a":0,"inc_ok":false,"hum_raw":557,"dis_raw":513}';
const lineaRoja =
    '{"hum":82.00,"inc":0.00,"dis":30.12,"dhum":28.00,"dinc":0.00,"ddis":0.00,"a":2,"inc_ok":false,"hum_raw":300,"dis_raw":513}';
const lineaAmarilla =
    '{"hum":70.00,"inc":1.10,"dis":30.12,"dhum":16.00,"dinc":0.40,"ddis":0.00,"a":1,"inc_ok":true,"hum_raw":420,"dis_raw":513}';

String lineaConfig({int seco = 800, int mojado = 350, double humAm = 15, double humRo = 25}) =>
    '{"cfg":1,"hum_seco":$seco,"hum_mojado":$mojado,"hum_am":${humAm.toStringAsFixed(2)},'
    '"hum_ro":${humRo.toStringAsFixed(2)},"inc_am":2.50,"inc_ro":5.00,"dis_am":3.00,"dis_ro":6.00}';

// Responde como el firmware nuevo; con responder = false imita un comando perdido
class EnlaceFalso implements Enlace {
  final lineasCtl = StreamController<String>();
  final estadosCtl = StreamController<EstadoEnlace>();
  final enviados = <String>[];
  bool responder = true;
  bool cerrado = false;
  double humAm = 15, humRo = 25;

  @override
  Stream<String> get lineas => lineasCtl.stream;
  @override
  Stream<EstadoEnlace> get estados => estadosCtl.stream;
  @override
  String? get motivoFallo => null;

  void _decir(String l) => scheduleMicrotask(() => lineasCtl.add(l));

  @override
  Future<void> enviar(String texto) async {
    enviados.add(texto);
    if (!responder) return;
    final p = texto.trim().split(' ');
    switch (p.first) {
      case 'r':
        _decir('>> Linea base reiniciada');
      case 'cfg':
        _decir(lineaConfig(humAm: humAm, humRo: humRo));
      case 'cal':
        _decir('>> Calibracion guardada');
        _decir(lineaConfig(seco: 812, humAm: humAm, humRo: humRo));
      case 'umb':
        final am = double.parse(p[2]), ro = double.parse(p[3]);
        if (ro <= am) {
          _decir('>> Error: limites fuera de rango (0 < amarilla < roja)');
        } else {
          humAm = am;
          humRo = ro;
          _decir('>> Limites guardados');
          _decir(lineaConfig(humAm: humAm, humRo: humRo));
        }
    }
  }

  @override
  Future<void> cerrar() async => cerrado = true;
}

class AlertasFalsas implements Alertas {
  final eventos = <String>[];
  @override
  void sonar(String tipo) => eventos.add(tipo);
  @override
  void vibrar() => eventos.add('vibrar');
}

void main() {
  group('Lectura y Configuracion', () {
    test('lee la línea JSON del Arduino', () {
      final l = Lectura.desdeLinea(lineaNormal)!;
      expect(l.humedad, 54.0);
      expect(l.desplazamiento, 30.12);
      expect(l.alerta, 0);
      expect(l.inclinometroOk, false);
      expect(l.crudoHumedad, 557);
      expect(l.crudoDesplazamiento, 513);
    });

    test('dis_ok: sin el campo (firmware viejo) cuenta como conectado', () {
      expect(Lectura.desdeLinea(lineaNormal)!.extensometroOk, true);
      final sinExt = lineaNormal.replaceFirst('"inc_ok":false', '"inc_ok":false,"dis_ok":false');
      expect(Lectura.desdeLinea(sinExt)!.extensometroOk, false);
    });

    test('ignora mensajes de texto, líneas cortadas y la línea de ajustes', () {
      expect(Lectura.desdeLinea('[OK] Linea base inicial establecida'), isNull);
      expect(Lectura.desdeLinea('{"hum":54.00,"inc":0.0'), isNull);
      expect(Lectura.desdeLinea(''), isNull);
      expect(Lectura.desdeLinea(lineaNormal.replaceFirst('"a":0', '"a":7')), isNull);
      expect(Lectura.desdeLinea(lineaConfig()), isNull);
    });

    test('tolera nan del Arduino', () {
      final l = Lectura.desdeLinea(lineaNormal.replaceFirst('"inc":0.00', '"inc":nan'))!;
      expect(l.inclinacion.isNaN, true);
      expect(l.humedad, 54.0);
    });

    test('lee la línea de ajustes', () {
      final c = Configuracion.desdeLinea(lineaConfig(seco: 820, mojado: 340))!;
      expect(c.humSeco, 820);
      expect(c.humMojado, 340);
      expect(c.humedad.igualA(15, 25), true);
      expect(c.limitesDe('inc').amarillo, 2.5);
      expect(c.limitesDe('dis').rojo, 6);
      expect(Configuracion.desdeLinea(lineaNormal), isNull);
    });
  });

  group('Monitor', () {
    late List<EnlaceFalso> enlaces;
    late AlertasFalsas alertas;
    late DateTime ahora;
    late Monitor m;

    void crear() {
      enlaces = [];
      alertas = AlertasFalsas();
      ahora = DateTime(2026, 11, 23, 10);
      m = Monitor(
        crearEnlace: () {
          final e = EnlaceFalso();
          enlaces.add(e);
          return e;
        },
        alertas: alertas,
        reloj: () => ahora,
      );
    }

    Future<void> conectar(WidgetTester t) async {
      enlaces.last.estadosCtl.add(EstadoEnlace.conectado);
      await t.pump();
    }

    Future<void> avanzar(WidgetTester t, Duration d) async {
      const paso = Duration(milliseconds: 250);
      var hecho = Duration.zero;
      while (hecho < d) {
        ahora = ahora.add(paso);
        await t.pump(paso);
        hecho += paso;
      }
    }

    testWidgets('pasa de conectando a normal y alerta roja con sonido repetido', (t) async {
      crear();
      expect(m.vista, Vista.conectando);

      await conectar(t);
      expect(m.vista, Vista.esperando);

      enlaces.last.lineasCtl.add(lineaNormal);
      await t.pump();
      expect(m.vista, Vista.normal);
      expect(alertas.eventos, isEmpty);

      enlaces.last.lineasCtl.add(lineaRoja);
      await t.pump();
      expect(m.vista, Vista.roja);
      expect(alertas.eventos, ['roja', 'vibrar']);

      for (var i = 0; i < 5; i++) {
        ahora = ahora.add(const Duration(milliseconds: 500));
        enlaces.last.lineasCtl.add(lineaRoja);
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(alertas.eventos.where((e) => e == 'roja').length, 2);

      enlaces.last.lineasCtl.add(lineaNormal);
      await t.pump();
      alertas.eventos.clear();
      await t.pump(const Duration(seconds: 3));
      expect(alertas.eventos, isEmpty);
      m.dispose();
    });

    testWidgets('amarilla suena una sola vez', (t) async {
      crear();
      await conectar(t);
      enlaces.last.lineasCtl.add(lineaNormal);
      await t.pump();
      for (var i = 0; i < 4; i++) {
        enlaces.last.lineasCtl.add(lineaAmarilla);
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(alertas.eventos, ['amarilla']);
      m.dispose();
    });

    testWidgets('pide los ajustes al conectar', (t) async {
      crear();
      await conectar(t);
      expect(m.config, isNull);
      enlaces.last.lineasCtl.add(lineaNormal);
      await t.pump();
      await t.pump();
      expect(enlaces.last.enviados, ['cfg\n']);
      expect(m.config!.humSeco, 800);
      m.dispose();
    });

    testWidgets('marca SIN DATOS, calla la alarma y reconecta si no llega nada', (t) async {
      crear();
      await conectar(t);
      enlaces.last.lineasCtl.add(lineaRoja);
      await t.pump();
      expect(m.vista, Vista.roja);

      await avanzar(t, const Duration(milliseconds: 3500));
      expect(m.vista, Vista.sinDatos);
      alertas.eventos.clear();
      await avanzar(t, const Duration(seconds: 3));
      expect(alertas.eventos, isEmpty);

      await avanzar(t, const Duration(seconds: 6));
      await t.pump();
      expect(enlaces.length, 2);
      expect(enlaces.first.cerrado, true);
      expect(m.vista, Vista.conectando);

      await conectar(t);
      expect(m.vista, Vista.esperando);
      m.dispose();
    });

    testWidgets('reinicio de línea base con confirmación', (t) async {
      crear();
      await conectar(t);
      final r = await m.reiniciarLineaBase();
      expect(r.ok, true);
      expect(enlaces.last.enviados, ['r\n']);
      m.dispose();
    });

    testWidgets('reenvía el comando si el Arduino no confirma', (t) async {
      crear();
      await conectar(t);
      enlaces.last.responder = false;
      Resultado? r;
      m.reiniciarLineaBase().then((v) => r = v);
      await t.pump(const Duration(seconds: 5));
      expect(r!.ok, false);
      expect(enlaces.last.enviados, ['r\n', 'r\n', 'r\n']);
      m.dispose();
    });

    testWidgets('cambia límites y espera a que el Arduino los confirme', (t) async {
      crear();
      await conectar(t);
      final r = await m.cambiarLimites('hum', 10, 20);
      expect(r.ok, true);
      expect(enlaces.last.enviados, ['umb hum 10.00 20.00\n']);
      expect(m.config!.humedad.igualA(10, 20), true);
      m.dispose();
    });

    testWidgets('muestra el error que devuelve el Arduino', (t) async {
      crear();
      await conectar(t);
      final r = await m.cambiarLimites('hum', 20, 10);
      expect(r.ok, false);
      expect(r.mensaje, 'limites fuera de rango (0 < amarilla < roja)');
      expect(enlaces.last.enviados.length, 1);
      m.dispose();
    });

    testWidgets('calibra y guarda el valor nuevo', (t) async {
      crear();
      await conectar(t);
      final r = await m.calibrar(seco: true);
      expect(r.ok, true);
      expect(enlaces.last.enviados, ['cal seco\n']);
      expect(m.config!.humSeco, 812);
      m.dispose();
    });

    testWidgets('la bitácora registra conexión, alertas con su causa, reinicio y ajustes', (t) async {
      crear();
      await conectar(t);
      enlaces.last.lineasCtl.add(lineaNormal);
      await t.pump();
      await t.pump();
      enlaces.last.lineasCtl.add(lineaAmarilla);
      await t.pump();
      enlaces.last.lineasCtl.add(lineaRoja);
      await t.pump();
      enlaces.last.lineasCtl.add(lineaNormal);
      await t.pump();
      await m.reiniciarLineaBase();
      await m.cambiarLimites('hum', 10, 20);
      final textos = m.eventos.map((e) => e.texto).toList();
      expect(textos, [
        'Conectado al Arduino',
        'Alerta amarilla — humedad +16.0 %',
        'Alerta roja — humedad +28.0 %',
        'Volvió a estado normal',
        'Línea base reiniciada',
        'Límites de humedad: 15/25 → 10/20 %',
      ]);
      expect(m.eventos[1].tipo, TipoEvento.amarilla);
      m.borrarBitacora();
      expect(m.eventos, isEmpty);
      m.dispose();
    });

    testWidgets('la gráfica guarda solo los últimos 3 minutos', (t) async {
      crear();
      await conectar(t);
      for (var i = 0; i < 200; i++) {
        ahora = ahora.add(const Duration(seconds: 1));
        enlaces.last.lineasCtl.add(lineaNormal);
        await t.pump(const Duration(seconds: 1));
      }
      expect(m.historial.length, inInclusiveRange(180, 181));
      expect(m.historial.first.dInclinacion, isNull);
      expect(ahora.difference(m.historial.first.hora), lessThanOrEqualTo(Monitor.ventanaGrafica));
      m.dispose();
    });

    testWidgets('sin conexión no manda comandos', (t) async {
      crear();
      final r = await m.cambiarLimites('hum', 10, 20);
      expect(r.ok, false);
      expect(enlaces.last.enviados, isEmpty);
      m.dispose();
    });
  });

  testWidgets('el simulador entiende los comandos', (t) async {
    final sim = EnlaceSimulado();
    final lineas = <String>[];
    final sub = sim.lineas.listen(lineas.add);
    await t.pump(const Duration(seconds: 3));
    expect(lineas.any((l) => Lectura.desdeLinea(l) != null), true);

    await sim.enviar('umb hum 10.00 20.00\n');
    await t.pump(const Duration(milliseconds: 300));
    expect(lineas.map(Configuracion.desdeLinea).whereType<Configuracion>().last.humedad.igualA(10, 20),
        true);

    await sim.enviar('umb hum 20 10\n');
    await t.pump(const Duration(milliseconds: 300));
    expect(lineas.last, startsWith('>> Error'));

    await sim.enviar('r\n');
    await t.pump(const Duration(milliseconds: 300));
    expect(lineas.last, '>> Linea base reiniciada');

    sub.cancel();
    sim.cerrar();
    await t.pump();
  });

  testWidgets('la pantalla muestra estado y sensores', (t) async {
    final enlace = EnlaceFalso();
    await t.pumpWidget(MaterialApp(
      theme: crearTema(),
      home: PantallaMonitor(
        nombre: 'HC-05',
        crearEnlace: () => enlace,
        alertas: AlertasFalsas(),
      ),
    ));
    expect(find.text('CONECTANDO…'), findsOneWidget);

    enlace.estadosCtl.add(EstadoEnlace.conectado);
    enlace.lineasCtl.add(lineaNormal);
    await t.pump();
    expect(find.text('ESTADO NORMAL'), findsOneWidget);
    expect(find.text('N/D'), findsOneWidget);
    expect(find.textContaining('54.0'), findsOneWidget);
    expect(find.text('crudo: 557'), findsOneWidget);

    expect(find.text('EVOLUCIÓN — ÚLTIMOS 3 MINUTOS'), findsOneWidget);
    await t.tap(find.text('Inclinación'));
    await t.pump();
    expect(find.text('Sensor de inclinación no conectado'), findsOneWidget);

    enlace.lineasCtl.add(lineaNormal.replaceFirst('"inc_ok":false', '"inc_ok":false,"dis_ok":false'));
    await t.pump();
    expect(find.text('N/D'), findsNWidgets(2));
    expect(find.text('crudo: 513'), findsNothing);
    await t.tap(find.text('Desplaz.'));
    await t.pump();
    expect(find.text('Extensómetro no conectado'), findsOneWidget);

    await t.tap(find.byTooltip('Calibración y límites'));
    await t.pumpAndSettle();
    expect(find.text('Calibración del sensor de humedad'), findsOneWidget);
    expect(find.text('800'), findsOneWidget);
    expect(find.text('350'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();

    await t.tap(find.byTooltip('Bitácora de eventos'));
    await t.pumpAndSettle();
    expect(find.text('Conectado al Arduino'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
  });
}
