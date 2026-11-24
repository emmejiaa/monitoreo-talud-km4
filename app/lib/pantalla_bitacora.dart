import 'package:material_ui/material_ui.dart';

import 'monitor.dart';
import 'tema.dart';

class PantallaBitacora extends StatelessWidget {
  const PantallaBitacora({super.key, required this.monitor});

  final Monitor monitor;

  static String _hora(DateTime t) =>
      [t.hour, t.minute, t.second].map((n) => n.toString().padLeft(2, '0')).join(':');

  static (IconData, Color) _estilo(TipoEvento tipo) => switch (tipo) {
        TipoEvento.roja => (Icons.error, Colores.rojo),
        TipoEvento.amarilla => (Icons.warning_rounded, Colores.amarillo),
        TipoEvento.normal => (Icons.check_circle, Colores.verde),
        TipoEvento.base => (Icons.restart_alt, Colores.primario),
        TipoEvento.ajuste => (Icons.tune, Colores.primario),
        TipoEvento.conexion => (Icons.bluetooth, Colores.gris),
      };

  Future<void> _borrar(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar bitácora'),
        content: const Text('Se borran todos los eventos registrados en esta sesión.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok ?? false) monitor.borrarBitacora();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final eventos = monitor.eventos.reversed.toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Bitácora de eventos'),
            actions: [
              IconButton(
                tooltip: 'Borrar bitácora',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: eventos.isEmpty ? null : () => _borrar(context),
              ),
            ],
          ),
          body: SafeArea(
            child: eventos.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Aún no hay eventos. Aquí aparecen las alertas, los reinicios de línea base, '
                        'los cambios de ajustes y la conexión con el Arduino.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colores.textoSuave),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: eventos.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
                    itemBuilder: (context, i) {
                      final e = eventos[i];
                      final (icono, color) = _estilo(e.tipo);
                      return ListTile(
                        leading: Icon(icono, color: color),
                        title: Text(e.texto),
                        trailing: Text(
                          _hora(e.hora),
                          style: const TextStyle(
                            color: Colores.textoSuave,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}
