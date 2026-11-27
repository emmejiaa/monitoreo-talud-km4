import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alertas.dart';
import 'enlace.dart';
import 'enlace_simulado.dart';
import 'pantalla_monitor.dart';
import 'tema.dart';

const claveDireccion = 'hc05_direccion';
const claveNombre = 'hc05_nombre';
const claveTipo = 'hc05_tipo';

PantallaMonitor crearPantallaMonitor(String direccion, String nombre, {bool ble = false}) =>
    PantallaMonitor(
      nombre: nombre,
      crearEnlace: () => EnlaceBluetooth(direccion, ble: ble),
      alertas: AlertasAndroid(),
    );

class Emparejado {
  const Emparejado(this.direccion, this.nombre, this.tipo);
  final String direccion;
  final String? nombre;
  final String tipo;

  String get nombreVisible => (nombre ?? '').trim().isEmpty ? direccion : nombre!;
  bool get esBle => tipo == 'le';
}

const _canalBluetooth = MethodChannel('km4/bluetooth');

Future<List<Emparejado>> _leerEmparejados(FlutterClassicBluetooth bt) async {
  try {
    final lista = await _canalBluetooth.invokeListMethod<Map>('emparejados') ?? [];
    return [
      for (final m in lista)
        Emparejado(m['direccion'] as String, m['nombre'] as String?, m['tipo'] as String? ?? ''),
    ];
  } on MissingPluginException {
    final lista = await bt.getPairedDevices();
    return [for (final d in lista) Emparejado(d.address, d.name, 'clasico')];
  }
}

enum _Problema { noSoportado, permiso, permisoBloqueado, apagado, error }

class PantallaDispositivos extends StatefulWidget {
  const PantallaDispositivos({super.key});

  @override
  State<PantallaDispositivos> createState() => _PantallaDispositivosState();
}

class _PantallaDispositivosState extends State<PantallaDispositivos> with WidgetsBindingObserver {
  final _bt = FlutterClassicBluetooth();
  StreamSubscription<BtcAdapterState>? _subAdaptador;
  bool _cargando = true;
  _Problema? _problema;
  String? _detalleError;
  List<Emparejado> _dispositivos = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subAdaptador = _bt.adapterState.listen(
      (s) {
        if (s == BtcAdapterState.on || s == BtcAdapterState.off) _cargar();
      },
      onError: (_) {},
    );
    _cargar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subAdaptador?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _cargar();
  }

  bool _ocupado = false;

  Future<void> _cargar() async {
    if (_ocupado) return;
    _ocupado = true;
    try {
      await _cargarLista();
    } finally {
      _ocupado = false;
    }
  }

  Future<void> _cargarLista() async {
    setState(() => _cargando = true);
    _Problema? problema;
    String? detalle;
    var lista = <Emparejado>[];
    try {
      if (!await _bt.isSupported()) {
        problema = _Problema.noSoportado;
      } else {
        const permisos = {BtcPermission.connect};
        var p = await _bt.checkPermissions(permissions: permisos);
        if (p == BtcPermissionStatus.denied) {
          p = await _bt.requestPermissions(permissions: permisos);
        }
        if (p == BtcPermissionStatus.permanentlyDenied) {
          problema = _Problema.permisoBloqueado;
        } else if (p == BtcPermissionStatus.denied) {
          problema = _Problema.permiso;
        } else if (!await _bt.isEnabled()) {
          problema = _Problema.apagado;
        } else {
          lista = await _leerEmparejados(_bt);
          lista.sort((a, b) {
            final ha = _esHc(a) ? 0 : 1;
            final hb = _esHc(b) ? 0 : 1;
            if (ha != hb) return ha - hb;
            return a.nombreVisible.toLowerCase().compareTo(b.nombreVisible.toLowerCase());
          });
        }
      }
    } on BtcException catch (e) {
      problema = _Problema.error;
      detalle = e.message;
    } on PlatformException catch (e) {
      problema = _Problema.error;
      detalle = e.message;
    } catch (e) {
      problema = _Problema.error;
      detalle = '$e';
    }
    if (!mounted) return;
    setState(() {
      _cargando = false;
      _problema = problema;
      _detalleError = detalle;
      _dispositivos = lista;
    });
  }

  static bool _esHc(Emparejado d) => (d.nombre ?? '').toUpperCase().contains('HC-0');

  Future<void> _elegir(Emparejado d) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString(claveDireccion, d.direccion);
    await prefs.setString(claveNombre, d.nombreVisible);
    await prefs.setString(claveTipo, d.tipo);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => crearPantallaMonitor(d.direccion, d.nombreVisible, ble: d.esBle),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Elegir módulo Bluetooth'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: SafeArea(child: _cuerpo()),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.science_outlined),
            label: const Text('Probar en modo simulado'),
            onPressed: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => PantallaMonitor(
                  nombre: 'Simulador',
                  crearEnlace: EnlaceSimulado.new,
                  alertas: AlertasAndroid(),
                  simulado: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando && _dispositivos.isEmpty && _problema == null) {
      return const Center(child: CircularProgressIndicator());
    }
    switch (_problema) {
      case _Problema.noSoportado:
        return const _Aviso(
          icono: Icons.bluetooth_disabled,
          titulo: 'Este celular no tiene Bluetooth clásico',
          texto: 'La app necesita un celular Android con Bluetooth para hablar con el HC-05.',
        );
      case _Problema.permiso:
        return _Aviso(
          icono: Icons.lock_outline,
          titulo: 'Falta el permiso de Bluetooth',
          texto: 'La app lo necesita para conectarse al HC-05 del prototipo.',
          boton: 'Dar permiso',
          alPulsar: _cargar,
        );
      case _Problema.permisoBloqueado:
        return _Aviso(
          icono: Icons.lock_outline,
          titulo: 'Permiso de Bluetooth bloqueado',
          texto: 'Active el permiso "Dispositivos cercanos" en los ajustes de la app y vuelva aquí.',
          boton: 'Abrir ajustes',
          alPulsar: _bt.openAppSettings,
        );
      case _Problema.apagado:
        return _Aviso(
          icono: Icons.bluetooth_disabled,
          titulo: 'El Bluetooth está apagado',
          texto: 'Enciéndalo para ver el módulo HC-05.',
          boton: 'Encender Bluetooth',
          alPulsar: () async {
            await _bt.enableBluetooth().catchError((_) => false);
            await _cargar();
          },
        );
      case _Problema.error:
        return _Aviso(
          icono: Icons.error_outline,
          titulo: 'No se pudo leer el Bluetooth',
          texto: _detalleError ?? '',
          boton: 'Reintentar',
          alPulsar: _cargar,
        );
      case null:
        break;
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        const Text(
          'Toque el módulo HC-05 del prototipo. La app lo recordará y se conectará sola la próxima vez.',
          style: TextStyle(fontSize: 14, color: Colores.textoSuave),
        ),
        const SizedBox(height: 14),
        if (_dispositivos.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No hay dispositivos emparejados con este celular.'),
            ),
          ),
        for (final d in _dispositivos) ...[
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              leading: CircleAvatar(
                backgroundColor: _esHc(d) ? Colores.primario : Colores.fondo,
                foregroundColor: _esHc(d) ? Colors.white : Colores.textoSuave,
                child: const Icon(Icons.bluetooth),
              ),
              title: Text(d.nombreVisible, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(d.esBle ? '${d.direccion}  ·  Bluetooth LE' : d.direccion),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _elegir(d),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 12),
        const Card(
          color: Color(0xFFE8EEF2),
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('¿No aparece el HC-05?', style: TextStyle(fontWeight: FontWeight.w700)),
                SizedBox(height: 6),
                Text(
                  '1. Encienda el Arduino (el LED del HC-05 parpadea rápido).\n'
                  '2. En el celular vaya a Ajustes → Bluetooth y busque "HC-05".\n'
                  '3. Emparéjelo con el PIN 1234 (o 0000).\n'
                  '4. Vuelva a esta pantalla: la lista se actualiza sola.',
                  style: TextStyle(height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso({
    required this.icono,
    required this.titulo,
    required this.texto,
    this.boton,
    this.alPulsar,
  });

  final IconData icono;
  final String titulo;
  final String texto;
  final String? boton;
  final FutureOr<void> Function()? alPulsar;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 56, color: Colores.gris),
            const SizedBox(height: 16),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(texto, textAlign: TextAlign.center, style: const TextStyle(color: Colores.textoSuave)),
            if (boton != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: alPulsar == null ? null : () => alPulsar!(),
                child: Text(boton!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
