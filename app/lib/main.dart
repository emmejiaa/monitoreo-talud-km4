import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pantalla_dispositivos.dart';
import 'tema.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? direccion;
  String? nombre;
  try {
    final prefs = SharedPreferencesAsync();
    direccion = await prefs.getString(claveDireccion);
    nombre = await prefs.getString(claveNombre);
  } catch (_) {}
  runApp(AppKm4(
    inicio: direccion == null
        ? const PantallaDispositivos()
        : crearPantallaMonitor(direccion, nombre ?? direccion),
  ));
}

class AppKm4 extends StatelessWidget {
  const AppKm4({super.key, required this.inicio});

  final Widget inicio;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monitoreo Km 4',
      debugShowCheckedModeBanner: false,
      theme: crearTema(),
      home: inicio,
    );
  }
}
