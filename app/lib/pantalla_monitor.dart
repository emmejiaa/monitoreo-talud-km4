import 'package:material_ui/material_ui.dart';

import 'alertas.dart';
import 'enlace.dart';
import 'grafica.dart';
import 'monitor.dart';
import 'pantalla_ajustes.dart';
import 'pantalla_bitacora.dart';
import 'pantalla_dispositivos.dart';
import 'tema.dart';

class PantallaMonitor extends StatefulWidget {
  const PantallaMonitor({
    super.key,
    required this.nombre,
    required this.crearEnlace,
    required this.alertas,
    this.simulado = false,
  });

  final String nombre;
  final Enlace Function() crearEnlace;
  final Alertas alertas;
  final bool simulado;

  @override
  State<PantallaMonitor> createState() => _PantallaMonitorState();
}

class _PantallaMonitorState extends State<PantallaMonitor> {
  late final Monitor _monitor =
      Monitor(crearEnlace: widget.crearEnlace, alertas: widget.alertas);

  @override
  void dispose() {
    _monitor.dispose();
    super.dispose();
  }

  Future<void> _reiniciar() async {
    final r = await _monitor.reiniciarLineaBase();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(r.mensaje)));
  }

  void _abrirAjustes() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PantallaAjustes(monitor: _monitor)),
    );
  }

  void _abrirBitacora() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PantallaBitacora(monitor: _monitor)),
    );
  }

  String _sensorGrafica = 'hum';

  Widget _tarjetaGrafica(Monitor m) {
    final l = m.lectura;
    final sinSensor = switch (_sensorGrafica) {
      'inc' when l != null && !l.inclinometroOk => 'Sensor de inclinación no conectado',
      'dis' when l != null && !l.extensometroOk => 'Extensómetro no conectado',
      _ => null,
    };
    final (valor, texto) = switch (_sensorGrafica) {
      'hum' => ((Punto p) => p.dHumedad, 'Cuánto subió la humedad respecto a la línea base (%)'),
      'inc' => ((Punto p) => p.dInclinacion?.abs(), 'Cambio de inclinación respecto a la línea base (°)'),
      _ => ((Punto p) => p.dDesplazamiento?.abs(), 'Desplazamiento respecto a la línea base (mm)'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Text(
                'EVOLUCIÓN — ÚLTIMOS 3 MINUTOS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: Colores.textoSuave,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: 'hum', label: Text('Humedad')),
                  ButtonSegment(value: 'inc', label: Text('Inclinación')),
                  ButtonSegment(value: 'dis', label: Text('Desplaz.')),
                ],
                selected: {_sensorGrafica},
                onSelectionChanged: (s) => setState(() => _sensorGrafica = s.first),
              ),
            ),
            const SizedBox(height: 12),
            if (sinSensor != null)
              SizedBox(
                height: 190,
                child: Center(
                  child: Text(sinSensor, style: const TextStyle(color: Colores.textoSuave)),
                ),
              )
            else
              GraficaSensor(
                puntos: m.historial,
                valor: valor,
                limites: m.limites.limitesDe(_sensorGrafica),
                ahora: DateTime.now(),
              ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(texto, style: const TextStyle(fontSize: 12, color: Colores.textoSuave)),
            ),
          ],
        ),
      ),
    );
  }

  void _cambiarDispositivo() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const PantallaDispositivos()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _monitor,
      builder: (context, _) {
        final m = _monitor;
        final l = m.lectura;
        final vigente = m.datosVigentes;
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Monitoreo Km 4'),
                Row(
                  children: [
                    Icon(Icons.circle, size: 9, color: _colorEnlace(m.estadoEnlace)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${widget.nombre} · ${_textoEnlace(m.estadoEnlace)}',
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Bitácora de eventos',
                icon: const Icon(Icons.history),
                onPressed: _abrirBitacora,
              ),
              IconButton(
                tooltip: 'Calibración y límites',
                icon: const Icon(Icons.tune),
                onPressed: _abrirAjustes,
              ),
              IconButton(
                tooltip: 'Cambiar dispositivo',
                icon: const Icon(Icons.bluetooth_searching),
                onPressed: _cambiarDispositivo,
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                if (widget.simulado) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF4D6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5C46B)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.science_outlined, size: 18, color: Color(0xFF8A6A00)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'MODO SIMULADO — datos de prueba, sin Arduino',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF8A6A00)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                BannerEstado(vista: m.vista, motivo: m.motivoFallo),
                const SizedBox(height: 16),
                TarjetaSensor(
                  titulo: 'Humedad del suelo',
                  icono: Icons.water_drop_outlined,
                  valor: _num(l?.humedad, 1),
                  unidad: '%',
                  detalle: 'Δ ${_delta(l?.dHumedad, 1)} %',
                  crudo: l?.crudoHumedad,
                  vigente: vigente,
                ),
                const SizedBox(height: 10),
                if (l != null && !l.inclinometroOk)
                  TarjetaSensor(
                    titulo: 'Inclinación del talud',
                    icono: Icons.screen_rotation_alt_outlined,
                    valor: 'N/D',
                    unidad: '',
                    detalle: 'Sensor no conectado',
                    vigente: false,
                  )
                else
                  TarjetaSensor(
                    titulo: 'Inclinación del talud',
                    icono: Icons.screen_rotation_alt_outlined,
                    valor: _num(l?.inclinacion, 2),
                    unidad: '°',
                    detalle: 'Δ ${_delta(l?.dInclinacion, 2)} °',
                    vigente: vigente,
                  ),
                const SizedBox(height: 10),
                if (l != null && !l.extensometroOk)
                  const TarjetaSensor(
                    titulo: 'Desplazamiento',
                    icono: Icons.straighten,
                    valor: 'N/D',
                    unidad: '',
                    detalle: 'Sensor no conectado',
                    vigente: false,
                  )
                else
                  TarjetaSensor(
                    titulo: 'Desplazamiento',
                    icono: Icons.straighten,
                    valor: _num(l?.desplazamiento, 2),
                    unidad: 'mm',
                    detalle: 'Δ ${_delta(l?.dDesplazamiento, 2)} mm',
                    crudo: l?.crudoDesplazamiento,
                    vigente: vigente,
                  ),
                const SizedBox(height: 10),
                _tarjetaGrafica(m),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: m.conectado && !m.ocupado ? _reiniciar : null,
                  icon: m.reiniciando
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.restart_alt),
                  label: Text(m.reiniciando ? 'Reiniciando…' : 'Reiniciar línea base'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: m.alternarSonido,
                  icon: Icon(m.sonidoActivo ? Icons.volume_up : Icons.volume_off),
                  label: Text('Sonido de alertas: ${m.sonidoActivo ? 'activado' : 'silenciado'}'),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: m.reconectar,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconectar'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Prototipo Km 4 — Proyecto Integrado en Ingeniería',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colores.textoSuave),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _num(double? v, int dec) =>
      v == null || !v.isFinite ? '--' : v.toStringAsFixed(dec);

  static String _delta(double? v, int dec) {
    if (v == null || !v.isFinite) return '--';
    final s = v.toStringAsFixed(dec);
    final r = double.parse(s);
    if (r == 0) return 0.0.toStringAsFixed(dec);
    return r > 0 ? '+$s' : s;
  }

  static Color _colorEnlace(EstadoEnlace e) => switch (e) {
        EstadoEnlace.conectado => const Color(0xFF7CE0A3),
        EstadoEnlace.conectando || EstadoEnlace.reconectando => const Color(0xFFFFD166),
        EstadoEnlace.cerrado => const Color(0xFFFF8A8A),
      };

  static String _textoEnlace(EstadoEnlace e) => switch (e) {
        EstadoEnlace.conectado => 'Conectado',
        EstadoEnlace.conectando => 'Conectando…',
        EstadoEnlace.reconectando => 'Reconectando…',
        EstadoEnlace.cerrado => 'Desconectado',
      };
}

class BannerEstado extends StatefulWidget {
  const BannerEstado({super.key, required this.vista, this.motivo});

  final Vista vista;
  final String? motivo;

  @override
  State<BannerEstado> createState() => _BannerEstadoState();
}

class _BannerEstadoState extends State<BannerEstado> with SingleTickerProviderStateMixin {
  late final AnimationController _pulso = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
    lowerBound: 0.7,
    upperBound: 1,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    _ajustarPulso();
  }

  @override
  void didUpdateWidget(BannerEstado old) {
    super.didUpdateWidget(old);
    if (old.vista != widget.vista) _ajustarPulso();
  }

  void _ajustarPulso() {
    if (widget.vista == Vista.roja) {
      _pulso.repeat(reverse: true);
    } else {
      _pulso.stop();
      _pulso.value = 1;
    }
  }

  @override
  void dispose() {
    _pulso.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (color, icono, titulo, subtitulo) = switch (widget.vista) {
      Vista.normal => (Colores.verde, Icons.check_circle_outline, 'ESTADO NORMAL', 'Sin cambios importantes en el talud'),
      Vista.amarilla => (Colores.amarillo, Icons.warning_amber_rounded, 'ALERTA AMARILLA', 'Vigilar el talud'),
      Vista.roja => (Colores.rojo, Icons.error_outline, 'ALERTA ROJA', 'Riesgo inminente'),
      Vista.conectando => (Colores.gris, Icons.bluetooth_searching, 'CONECTANDO…', 'Buscando el módulo HC-05'),
      Vista.reconectando => (Colores.gris, Icons.bluetooth_disabled, 'SIN CONEXIÓN', widget.motivo ?? 'Intentando reconectar…'),
      Vista.esperando => (Colores.gris, Icons.hourglass_top, 'CONECTADO', 'Esperando datos del Arduino…'),
      Vista.sinDatos => (Colores.gris, Icons.sensors_off, 'SIN DATOS', 'El Arduino dejó de enviar lecturas'),
    };
    return FadeTransition(
      opacity: _pulso,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Icon(icono, color: Colors.white, size: 44),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitulo, style: const TextStyle(color: Colors.white, fontSize: 14)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TarjetaSensor extends StatelessWidget {
  const TarjetaSensor({
    super.key,
    required this.titulo,
    required this.icono,
    required this.valor,
    required this.unidad,
    required this.detalle,
    required this.vigente,
    this.crudo,
  });

  final String titulo;
  final IconData icono;
  final String valor;
  final String unidad;
  final String detalle;
  final bool vigente;
  final int? crudo;

  @override
  Widget build(BuildContext context) {
    final colorValor = vigente ? Colores.primario : Colores.apagado;
    final colorTexto = vigente ? Colores.textoSuave : Colores.apagado;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icono, color: colorValor, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: Colores.textoSuave,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: valor,
                        style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: colorValor),
                      ),
                      if (unidad.isNotEmpty)
                        TextSpan(
                          text: ' $unidad',
                          style: TextStyle(fontSize: 15, color: colorTexto),
                        ),
                    ]),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(detalle, style: TextStyle(fontSize: 13, color: colorTexto)),
                if (crudo != null)
                  Text(
                    'crudo: $crudo',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colores.apagado,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
