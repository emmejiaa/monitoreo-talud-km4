import 'package:material_ui/material_ui.dart';

import 'lectura.dart';
import 'monitor.dart';
import 'tema.dart';

class _Sensor {
  const _Sensor(this.clave, this.nombre, this.unidad, this.maximo);
  final String clave;
  final String nombre;
  final String unidad;
  final double maximo;
}

const _sensores = [
  _Sensor('hum', 'Humedad (cuánto sube)', '%', 100),
  _Sensor('inc', 'Inclinación', '°', 45),
  _Sensor('dis', 'Desplazamiento', 'mm', 60),
];

class PantallaAjustes extends StatefulWidget {
  const PantallaAjustes({super.key, required this.monitor});

  final Monitor monitor;

  @override
  State<PantallaAjustes> createState() => _PantallaAjustesState();
}

class _PantallaAjustesState extends State<PantallaAjustes> {
  final _amarillo = {for (final s in _sensores) s.clave: TextEditingController()};
  final _rojo = {for (final s in _sensores) s.clave: TextEditingController()};
  final _editado = {for (final s in _sensores) s.clave: false};
  final _errores = <String, String?>{};
  Configuracion? _cfgMostrada;
  bool _leyendo = false;

  Monitor get _m => widget.monitor;

  @override
  void initState() {
    super.initState();
    _m.addListener(_sincronizar);
    _sincronizar();
    if (_m.config == null) _leer();
  }

  @override
  void dispose() {
    _m.removeListener(_sincronizar);
    for (final c in [..._amarillo.values, ..._rojo.values]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _leer() async {
    setState(() => _leyendo = true);
    await _m.pedirConfig();
    if (mounted) setState(() => _leyendo = false);
  }

  void _sincronizar() {
    final c = _m.config;
    if (c == null || identical(c, _cfgMostrada)) return;
    _cfgMostrada = c;
    for (final s in _sensores) {
      if (_editado[s.clave]!) continue;
      final l = c.limitesDe(s.clave);
      _amarillo[s.clave]!.text = _fmt(l.amarillo);
      _rojo[s.clave]!.text = _fmt(l.rojo);
    }
  }

  static String _fmt(double v) {
    var s = v.toStringAsFixed(2);
    if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s;
  }

  static double? _numero(String texto) => double.tryParse(texto.trim().replaceAll(',', '.'));

  void _avisar(Resultado r) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(r.mensaje),
        backgroundColor: r.ok ? null : Colores.rojo,
      ));
  }

  Future<bool> _confirmar(String titulo, String texto, String accion) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: Text(texto),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(accion)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _calibrar(bool seco) async {
    final ok = await _confirmar(
      seco ? 'Medir seco' : 'Medir mojado',
      seco
          ? 'Saque el sensor de la tierra, límpielo y déjelo al aire, seco.'
          : 'Meta el sensor en un vaso de agua hasta la línea marcada, sin mojar la parte electrónica.',
      'Medir',
    );
    if (!ok) return;
    _avisar(await _m.calibrar(seco: seco));
  }

  Future<void> _guardarLimites() async {
    FocusScope.of(context).unfocus();
    final c = _m.config;
    if (c == null) return;
    final cambios = <(String, double, double)>[];
    final errores = <String, String?>{};
    for (final s in _sensores) {
      final am = _numero(_amarillo[s.clave]!.text);
      final ro = _numero(_rojo[s.clave]!.text);
      if (am == null || ro == null) {
        errores[s.clave] = 'Escriba los dos números';
      } else if (am <= 0 || ro <= am) {
        errores[s.clave] = 'La roja debe ser mayor que la amarilla, y ambas mayores que 0';
      } else if (ro > s.maximo) {
        errores[s.clave] = 'Máximo ${_fmt(s.maximo)} ${s.unidad}';
      } else if (!c.limitesDe(s.clave).igualA(am, ro)) {
        cambios.add((s.clave, am, ro));
      }
    }
    setState(() {
      _errores
        ..clear()
        ..addAll(errores);
    });
    if (errores.isNotEmpty) return;
    if (cambios.isEmpty) {
      _avisar(const Resultado(true, 'No hay cambios para guardar'));
      return;
    }
    for (final (clave, am, ro) in cambios) {
      final r = await _m.cambiarLimites(clave, am, ro);
      if (!r.ok) {
        _avisar(r);
        return;
      }
      _editado[clave] = false;
    }
    _cfgMostrada = null;
    _sincronizar();
    _avisar(const Resultado(true, 'Límites guardados en el Arduino'));
  }

  Future<void> _fabrica() async {
    final ok = await _confirmar(
      'Restaurar valores de fábrica',
      'La calibración vuelve a seco 800 / mojado 350 y los límites a los originales '
          '(humedad 15/25 %, inclinación 2,5/5°, desplazamiento 3/6 mm).',
      'Restaurar',
    );
    if (!ok) return;
    for (final s in _sensores) {
      _editado[s.clave] = false;
    }
    _errores.clear();
    _avisar(await _m.restaurarFabrica());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _m,
      builder: (context, _) {
        final c = _m.config;
        final habilitado = _m.conectado && !_m.ocupado && c != null;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Calibración y límites'),
            bottom: _m.ocupado
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(3),
                    child: LinearProgressIndicator(minHeight: 3),
                  )
                : null,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                if (!_m.conectado)
                  const _Nota(
                    icono: Icons.bluetooth_disabled,
                    texto: 'Sin conexión con el Arduino. Los cambios se pueden hacer cuando vuelva a conectar.',
                  )
                else if (c == null)
                  _Nota(
                    icono: Icons.hourglass_top,
                    texto: _leyendo
                        ? 'Leyendo los ajustes del Arduino…'
                        : 'El Arduino no envió sus ajustes. Revise que tenga el firmware nuevo.',
                    accion: _leyendo ? null : 'Volver a leer',
                    alPulsar: _leer,
                  ),
                if (!_m.conectado || c == null) const SizedBox(height: 12),
                _tarjetaCalibracion(c, habilitado),
                const SizedBox(height: 12),
                _tarjetaLimites(habilitado),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: habilitado ? _fabrica : null,
                  style: TextButton.styleFrom(foregroundColor: Colores.rojo),
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Restaurar valores de fábrica'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tarjetaCalibracion(Configuracion? c, bool habilitado) {
    final l = _m.lectura;
    final crudo = _m.datosVigentes ? l?.crudoHumedad : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Titulo('Calibración del sensor de humedad'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colores.fondo,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Lectura cruda ahora', style: TextStyle(color: Colores.textoSuave)),
                  ),
                  Text(
                    crudo == null ? '--' : '$crudo',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colores.primario),
                  ),
                  if (crudo != null && l != null && l.humedad.isFinite)
                    Text('  (${l.humedad.toStringAsFixed(0)} %)',
                        style: const TextStyle(color: Colores.textoSuave)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _filaCalibracion('Seco (al aire)', c?.humSeco, 'Medir seco',
                habilitado ? () => _calibrar(true) : null),
            const Divider(height: 20),
            _filaCalibracion('Mojado (en agua)', c?.humMojado, 'Medir mojado',
                habilitado ? () => _calibrar(false) : null),
            const SizedBox(height: 12),
            const Text(
              '1. Saque el sensor, séquelo y toque "Medir seco".\n'
              '2. Métalo en un vaso de agua y toque "Medir mojado".\n'
              '3. Vuelva a enterrarlo y reinicie la línea base.\n'
              'Todo queda guardado en el Arduino aunque se apague.',
              style: TextStyle(fontSize: 13, height: 1.5, color: Colores.textoSuave),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filaCalibracion(String nombre, int? valor, String boton, VoidCallback? alPulsar) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(nombre, style: const TextStyle(color: Colores.textoSuave, fontSize: 13)),
              Text(
                valor == null ? '--' : '$valor',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        FilledButton.tonal(onPressed: alPulsar, child: Text(boton)),
      ],
    );
  }

  Widget _tarjetaLimites(bool habilitado) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Titulo('Límites de alerta'),
            const SizedBox(height: 4),
            const Text(
              'Cuánto tiene que cambiar cada sensor, respecto a la línea base, para dar alerta.',
              style: TextStyle(fontSize: 13, color: Colores.textoSuave),
            ),
            for (final s in _sensores) ...[
              const SizedBox(height: 16),
              Text(s.nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _campo(s, _amarillo[s.clave]!, 'Amarilla', Colores.amarillo)),
                  const SizedBox(width: 12),
                  Expanded(child: _campo(s, _rojo[s.clave]!, 'Roja', Colores.rojo)),
                ],
              ),
              if (_errores[s.clave] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_errores[s.clave]!,
                      style: const TextStyle(color: Colores.rojo, fontSize: 12)),
                ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: habilitado ? _guardarLimites : null,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Guardar límites'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _campo(_Sensor s, TextEditingController ctl, String etiqueta, Color color) {
    return TextField(
      controller: ctl,
      enabled: _m.config != null,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => _editado[s.clave] = true,
      decoration: InputDecoration(
        labelText: etiqueta,
        suffixText: s.unidad,
        isDense: true,
        prefixIcon: Icon(Icons.circle, size: 12, color: color),
        prefixIconConstraints: const BoxConstraints(minWidth: 32),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) => Text(
        texto,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colores.primario),
      );
}

class _Nota extends StatelessWidget {
  const _Nota({required this.icono, required this.texto, this.accion, this.alPulsar});

  final IconData icono;
  final String texto;
  final String? accion;
  final VoidCallback? alPulsar;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4D6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5C46B)),
      ),
      child: Row(
        children: [
          Icon(icono, color: const Color(0xFF8A6A00)),
          const SizedBox(width: 10),
          Expanded(child: Text(texto, style: const TextStyle(color: Color(0xFF5E4800)))),
          if (accion != null) TextButton(onPressed: alPulsar, child: Text(accion!)),
        ],
      ),
    );
  }
}
