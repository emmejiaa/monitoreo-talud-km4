import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monitoreo_km4/enlace.dart';
import 'package:monitoreo_km4/enlace_ble.dart';

void main() {
  late List<MethodCall> llamadas;
  MockStreamHandlerEventSink? sink;

  setUp(() {
    llamadas = [];
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(EnlaceBle.canal, (c) async {
      llamadas.add(c);
      return c.method == 'enviar' ? true : null;
    });
    m.setMockStreamHandler(
      EnlaceBle.canalEventos,
      MockStreamHandler.inline(onListen: (_, s) {
        sink = s;
      }),
    );
  });

  List<MethodCall> de(String metodo) => llamadas.where((c) => c.method == metodo).toList();
  int idDe(EnlaceBle e) => (de('conectar').last.arguments as Map)['id'] as int;
  void avisar(int id, String tipo, {String? detalle, List<int>? datos}) => sink!.success({
        'id': id,
        'tipo': tipo,
        'detalle': detalle,
        'datos': datos == null ? null : Uint8List.fromList(datos),
      });

  // Los mensajes del canal simulado llegan en una vuelta real del ciclo de
  // eventos, fuera del tiempo simulado de la prueba
  Future<void> asentar(WidgetTester t, [Duration tiempo = Duration.zero]) async {
    await t.pump(tiempo);
    for (var i = 0; i < 3; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
      await t.pump();
    }
  }

  testWidgets('arma las líneas que llegan en paquetes de 20 bytes y envía comandos', (t) async {
    final enlace = EnlaceBle('AA:BB:CC:DD:EE:FF');
    final estados = <EstadoEnlace>[];
    final lineas = <String>[];
    enlace.estados.listen(estados.add);
    enlace.lineas.listen(lineas.add);
    await asentar(t);
    expect((de('conectar').single.arguments as Map)['direccion'], 'AA:BB:CC:DD:EE:FF');
    expect(estados, [EstadoEnlace.conectando]);

    final id = idDe(enlace);
    avisar(id, 'conectado');
    await asentar(t);
    expect(estados.last, EstadoEnlace.conectado);

    const json = '{"hum":54.00,"inc":0.00,"dis":30.12,"dhum":0.00,"dinc":0.00,"ddis":0.00,"a":0}';
    final bytes = utf8.encode('[OK] Linea base\r\n$json\r\n{"hum":5');
    for (var i = 0; i < bytes.length; i += 20) {
      avisar(id, 'datos', datos: bytes.sublist(i, i + 20 > bytes.length ? bytes.length : i + 20));
    }
    avisar(id + 99, 'datos', datos: utf8.encode('de otra conexion\n'));
    await asentar(t);
    expect(lineas, ['[OK] Linea base', json]);

    await enlace.enviar('umb hum 15.00 25.00\n');
    final datos = (de('enviar').single.arguments as Map)['datos'] as Uint8List;
    expect(utf8.decode(datos), 'umb hum 15.00 25.00\n');

    await enlace.cerrar();
    expect(de('desconectar'), isNotEmpty);
  });

  testWidgets('si se pierde la conexión explica el motivo y reintenta solo', (t) async {
    final enlace = EnlaceBle('AA:BB:CC:DD:EE:FF');
    final estados = <EstadoEnlace>[];
    enlace.estados.listen(estados.add);
    await asentar(t);
    final id = idDe(enlace);

    avisar(id, 'desconectado', detalle: 'sin_servicio:1800, 1801');
    await asentar(t);
    expect(estados.last, EstadoEnlace.reconectando);
    expect(enlace.motivoFallo, contains('canal serial'));
    expect(enlace.motivoFallo, contains('1800, 1801'));
    await expectLater(enlace.enviar('r\n'), throwsStateError);

    await asentar(t, const Duration(seconds: 1));
    expect(de('conectar'), hasLength(2));
    avisar(id, 'conectado');
    await asentar(t);
    expect(estados.last, EstadoEnlace.conectado);
    expect(enlace.motivoFallo, isNull);

    await enlace.cerrar();
  });

  testWidgets('si no conecta en 12 s corta el intento y vuelve a probar', (t) async {
    final enlace = EnlaceBle('AA:BB:CC:DD:EE:FF');
    await asentar(t);
    await asentar(t, const Duration(seconds: 12));
    expect(de('desconectar'), hasLength(1));
    expect(enlace.motivoFallo, contains('¿Está encendido el Arduino?'));
    await asentar(t, const Duration(seconds: 1));
    expect(de('conectar'), hasLength(2));

    await enlace.cerrar();
    final intentos = de('conectar').length;
    await asentar(t, const Duration(seconds: 30));
    expect(de('conectar'), hasLength(intentos));
  });

  testWidgets('el Bluetooth apagado se informa como tal', (t) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(EnlaceBle.canal, (c) async {
      llamadas.add(c);
      return c.method == 'conectar' ? 'apagado' : null;
    });
    final enlace = EnlaceBle('AA:BB:CC:DD:EE:FF');
    await asentar(t);
    expect(enlace.motivoFallo, 'El Bluetooth del celular está apagado');
    await enlace.cerrar();
  });
}
